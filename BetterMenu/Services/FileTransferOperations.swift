import Darwin
import Foundation

struct FileTransferCopyFailure: Equatable, Sendable {
  let fileName: String
  let message: String
}

struct FileTransferCopyResult: Equatable, Sendable {
  let copiedUrls: [URL]
  let failures: [FileTransferCopyFailure]
  let wasCancelled: Bool
}

struct FileTransferProgressSnapshot: Equatable, Sendable {
  let currentFileName: String
  let completedBytes: Int64
  let totalBytes: Int64
  let completedItemCount: Int
  let totalItemCount: Int
}

final class FileTransferCancellationToken: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}

enum FileTransferOperations {
  typealias ProgressHandler = @Sendable (FileTransferProgressSnapshot) -> Void

  private final class TargetReservationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var reservedPaths: Set<String> = []

    func reserveTargetUrl(
      for sourceUrl: URL,
      in destinationUrl: URL,
      fileManager: FileManager
    ) -> URL {
      lock.lock()
      defer { lock.unlock() }

      let targetUrl = availableTargetUrl(
        for: sourceUrl,
        in: destinationUrl,
        fileManager: fileManager,
        excluding: reservedPaths
      )
      reservedPaths.insert(targetUrl.path)
      return targetUrl
    }

    func release(_ targetUrl: URL) {
      lock.lock()
      reservedPaths.remove(targetUrl.path)
      lock.unlock()
    }
  }

  private final class CopyProgressContext: @unchecked Sendable {
    let baseCompletedBytes: Int64
    let currentFileName: String
    let totalBytes: Int64
    let completedItemCount: Int
    let totalItemCount: Int
    let cancellationToken: FileTransferCancellationToken
    let progressHandler: ProgressHandler

    private let lock = NSLock()
    private var copiedBytesBySourcePath: [String: Int64] = [:]
    private var lastReportedTotalBytes: Int64 = 0

    init(
      baseCompletedBytes: Int64,
      currentFileName: String,
      totalBytes: Int64,
      completedItemCount: Int,
      totalItemCount: Int,
      cancellationToken: FileTransferCancellationToken,
      progressHandler: @escaping ProgressHandler
    ) {
      self.baseCompletedBytes = baseCompletedBytes
      self.currentFileName = currentFileName
      self.totalBytes = totalBytes
      self.completedItemCount = completedItemCount
      self.totalItemCount = totalItemCount
      self.cancellationToken = cancellationToken
      self.progressHandler = progressHandler
    }

    func handleProgress(
      state: copyfile_state_t,
      sourcePath: String
    ) -> Int32 {
      guard !cancellationToken.isCancelled else {
        return COPYFILE_QUIT
      }

      var copiedBytes: off_t = 0
      guard
        copyfile_state_get(
          state,
          UInt32(COPYFILE_STATE_COPIED),
          &copiedBytes
        ) == 0
      else {
        return COPYFILE_CONTINUE
      }

      let currentCopiedBytes = max(0, Int64(copiedBytes))
      let minimumUpdateInterval = max(524_288, totalBytes / 200)

      lock.lock()
      copiedBytesBySourcePath[sourcePath] = max(
        copiedBytesBySourcePath[sourcePath] ?? 0,
        currentCopiedBytes
      )
      let totalCopiedBytes = copiedBytesBySourcePath.values.reduce(0, +)
      let shouldReport =
        totalCopiedBytes == 0
        || totalCopiedBytes - lastReportedTotalBytes >= minimumUpdateInterval
      if shouldReport {
        lastReportedTotalBytes = totalCopiedBytes
      }
      lock.unlock()

      if shouldReport {
        progressHandler(
          FileTransferProgressSnapshot(
            currentFileName: currentFileName,
            completedBytes: min(baseCompletedBytes + totalCopiedBytes, totalBytes),
            totalBytes: totalBytes,
            completedItemCount: completedItemCount,
            totalItemCount: totalItemCount
          )
        )
      }

      return COPYFILE_CONTINUE
    }
  }

  private static let targetReservationRegistry = TargetReservationRegistry()

  static func copyItems(
    _ sourceUrls: [URL],
    to requestedDestinationUrl: URL,
    cancellationToken: FileTransferCancellationToken = FileTransferCancellationToken(),
    progressHandler: @escaping ProgressHandler = { _ in },
    copyAttemptWillStart: @escaping @Sendable (URL) -> Void = { _ in }
  ) -> FileTransferCopyResult {
    let fileManager = FileManager()
    let destinationUrl = requestedDestinationUrl.standardizedFileURL
    let standardizedSourceUrls = sourceUrls.map(\.standardizedFileURL)
    let totalItemCount = standardizedSourceUrls.count

    // 统计体积需要完整枚举目录树，包含数万文件的目录会耗时很久，
    // 因此这一阶段也必须响应取消，否则进度窗口会长时间停在“正在计算传输大小…”且点取消无反应。
    var sourceByteCounts: [Int64] = []
    sourceByteCounts.reserveCapacity(totalItemCount)
    for sourceUrl in standardizedSourceUrls {
      guard !cancellationToken.isCancelled else {
        return FileTransferCopyResult(copiedUrls: [], failures: [], wasCancelled: true)
      }
      sourceByteCounts.append(
        byteCount(
          for: sourceUrl,
          fileManager: fileManager,
          cancellationToken: cancellationToken
        )
      )
    }
    guard !cancellationToken.isCancelled else {
      return FileTransferCopyResult(copiedUrls: [], failures: [], wasCancelled: true)
    }
    let totalBytes = sourceByteCounts.reduce(0, +)

    var copiedUrls: [URL] = []
    var failures: [FileTransferCopyFailure] = []
    var completedBytes: Int64 = 0

    // 无论成功还是失败，项目都已处理完毕，因此进度的分子必须一并推进。
    // 否则分母含全部项目、分子只含成功项，部分失败时进度条会永远停在中途。
    func finishItem(at index: Int, fileName: String) {
      completedBytes += sourceByteCounts[index]
      progressHandler(
        FileTransferProgressSnapshot(
          currentFileName: fileName,
          completedBytes: min(completedBytes, totalBytes),
          totalBytes: totalBytes,
          completedItemCount: index + 1,
          totalItemCount: totalItemCount
        )
      )
    }

    for (index, sourceUrl) in standardizedSourceUrls.enumerated() {
      guard !cancellationToken.isCancelled else {
        return FileTransferCopyResult(
          copiedUrls: copiedUrls,
          failures: failures,
          wasCancelled: true
        )
      }

      guard !destinationIsInsideSource(destinationUrl, sourceUrl: sourceUrl) else {
        failures.append(
          FileTransferCopyFailure(
            fileName: sourceUrl.lastPathComponent,
            message: "不能将项目复制到其自身内部。"
          )
        )
        finishItem(at: index, fileName: sourceUrl.lastPathComponent)
        continue
      }

      let snapshot = FileTransferProgressSnapshot(
        currentFileName: sourceUrl.lastPathComponent,
        completedBytes: completedBytes,
        totalBytes: totalBytes,
        completedItemCount: index,
        totalItemCount: totalItemCount
      )
      progressHandler(snapshot)

      let context = CopyProgressContext(
        baseCompletedBytes: completedBytes,
        currentFileName: sourceUrl.lastPathComponent,
        totalBytes: totalBytes,
        completedItemCount: index,
        totalItemCount: totalItemCount,
        cancellationToken: cancellationToken,
        progressHandler: progressHandler
      )

      var targetUrl: URL
      var copyErrorNumber: Int32
      repeat {
        guard !cancellationToken.isCancelled else {
          return FileTransferCopyResult(
            copiedUrls: copiedUrls,
            failures: failures,
            wasCancelled: true
          )
        }
        targetUrl = targetReservationRegistry.reserveTargetUrl(
          for: sourceUrl,
          in: destinationUrl,
          fileManager: fileManager
        )
        copyAttemptWillStart(targetUrl)
        copyErrorNumber = copyItem(
          at: sourceUrl,
          to: targetUrl,
          context: context
        )
        targetReservationRegistry.release(targetUrl)
      } while copyErrorNumber == EEXIST

      if copyErrorNumber == 0 {
        copiedUrls.append(targetUrl)
        finishItem(at: index, fileName: sourceUrl.lastPathComponent)
        continue
      }

      let wasCancelled =
        cancellationToken.isCancelled || copyErrorNumber == ECANCELED
      if copyErrorNumber != EEXIST, fileManager.fileExists(atPath: targetUrl.path) {
        try? fileManager.removeItem(at: targetUrl)
      }
      if wasCancelled {
        return FileTransferCopyResult(
          copiedUrls: copiedUrls,
          failures: failures,
          wasCancelled: true
        )
      }

      failures.append(
        FileTransferCopyFailure(
          fileName: sourceUrl.lastPathComponent,
          message: errorMessage(for: copyErrorNumber)
        )
      )
      finishItem(at: index, fileName: sourceUrl.lastPathComponent)
    }

    return FileTransferCopyResult(
      copiedUrls: copiedUrls,
      failures: failures,
      wasCancelled: false
    )
  }

  static func availableTargetUrl(
    for sourceUrl: URL,
    in destinationUrl: URL,
    fileManager: FileManager,
    excluding reservedPaths: Set<String> = []
  ) -> URL {
    let originalTargetUrl = destinationUrl.appendingPathComponent(sourceUrl.lastPathComponent)
    guard
      fileManager.fileExists(atPath: originalTargetUrl.path)
        || reservedPaths.contains(originalTargetUrl.path)
    else {
      return originalTargetUrl
    }

    let pathExtension = sourceUrl.pathExtension
    let baseName =
      pathExtension.isEmpty
      ? sourceUrl.lastPathComponent
      : sourceUrl.deletingPathExtension().lastPathComponent
    var copyIndex = 2
    while true {
      let candidateName =
        pathExtension.isEmpty
        ? "\(baseName) \(copyIndex)"
        : "\(baseName) \(copyIndex).\(pathExtension)"
      let candidateUrl = destinationUrl.appendingPathComponent(candidateName)
      if !fileManager.fileExists(atPath: candidateUrl.path)
        && !reservedPaths.contains(candidateUrl.path)
      {
        return candidateUrl
      }
      copyIndex += 1
    }
  }

  private static func copyItem(
    at sourceUrl: URL,
    to targetUrl: URL,
    context: CopyProgressContext
  ) -> Int32 {
    guard let state = copyfile_state_alloc() else {
      return ENOMEM
    }
    defer {
      copyfile_state_free(state)
    }

    let callback: copyfile_callback_t = {
      what,
      stage,
      callbackState,
      sourcePath,
      _,
      rawContext in
      guard
        what == COPYFILE_COPY_DATA,
        stage == COPYFILE_PROGRESS,
        let callbackState,
        let rawContext
      else {
        if let rawContext {
          let context = Unmanaged<CopyProgressContext>
            .fromOpaque(rawContext)
            .takeUnretainedValue()
          return context.cancellationToken.isCancelled
            ? COPYFILE_QUIT
            : COPYFILE_CONTINUE
        }
        return COPYFILE_CONTINUE
      }

      let context = Unmanaged<CopyProgressContext>
        .fromOpaque(rawContext)
        .takeUnretainedValue()
      return context.handleProgress(
        state: callbackState,
        sourcePath: sourcePath.map { String(cString: $0) } ?? context.currentFileName
      )
    }

    let callbackPointer = unsafeBitCast(callback, to: UnsafeRawPointer.self)
    let callbackResult = copyfile_state_set(
      state,
      UInt32(COPYFILE_STATE_STATUS_CB),
      callbackPointer
    )
    guard callbackResult == 0 else {
      return errno
    }

    let contextPointer = Unmanaged.passUnretained(context).toOpaque()
    guard
      copyfile_state_set(
        state,
        UInt32(COPYFILE_STATE_STATUS_CTX),
        contextPointer
      ) == 0
    else {
      return errno
    }

    let flags =
      copyfile_flags_t(COPYFILE_ALL)
      | copyfile_flags_t(COPYFILE_RECURSIVE)
      | copyfile_flags_t(COPYFILE_EXCL)
      | copyfile_flags_t(COPYFILE_NOFOLLOW_SRC)
    let result = copyfile(sourceUrl.path, targetUrl.path, state, flags)
    return result == 0 ? 0 : errno
  }

  private static func destinationIsInsideSource(
    _ destinationUrl: URL,
    sourceUrl: URL
  ) -> Bool {
    let sourcePath = sourceUrl.standardizedFileURL.path
    let destinationPath = destinationUrl.standardizedFileURL.path
    return destinationPath == sourcePath || destinationPath.hasPrefix(sourcePath + "/")
  }

  /// 统计单个项目的字节数。目录会被递归枚举，枚举过程中定期检查取消标记，
  /// 一旦取消立即返回已累计的数值（调用方会据此终止整个任务，该数值不会被使用）。
  private static func byteCount(
    for sourceUrl: URL,
    fileManager: FileManager,
    cancellationToken: FileTransferCancellationToken
  ) -> Int64 {
    let resourceKeys: Set<URLResourceKey> = [
      .fileSizeKey,
      .isDirectoryKey,
      .isRegularFileKey,
      .isSymbolicLinkKey,
    ]
    guard
      let sourceValues = try? sourceUrl.resourceValues(forKeys: resourceKeys)
    else {
      return 0
    }

    if sourceValues.isRegularFile == true {
      return Int64(sourceValues.fileSize ?? 0)
    }
    guard sourceValues.isDirectory == true else {
      return 0
    }

    let enumerator = fileManager.enumerator(
      at: sourceUrl,
      includingPropertiesForKeys: Array(resourceKeys),
      options: [],
      errorHandler: { _, _ in true }
    )
    var totalBytes: Int64 = 0
    var visitedItemCount = 0
    while let itemUrl = enumerator?.nextObject() as? URL {
      // 取消标记的读取会加锁，按批检查以免在大目录上带来额外开销。
      visitedItemCount += 1
      if visitedItemCount % 256 == 0, cancellationToken.isCancelled {
        return totalBytes
      }
      guard
        let values = try? itemUrl.resourceValues(forKeys: resourceKeys),
        values.isRegularFile == true
      else {
        continue
      }
      totalBytes += Int64(values.fileSize ?? 0)
    }
    return totalBytes
  }

  /// 把复制失败的 errno 翻译成中文提示。
  ///
  /// `strerror` 只返回英文（"No space left on device" 等），在全中文界面里很突兀，
  /// 因此常见错误单独给出可操作的中文说明；其余错误回落到系统描述并附带错误码便于排查。
  static func errorMessage(for errorNumber: Int32) -> String {
    switch errorNumber {
    case ENOSPC:
      return "目标磁盘空间不足。"
    case EACCES, EPERM:
      return "没有写入目标位置的权限。"
    case EEXIST:
      return "目标位置已存在同名项目。"
    case EROFS:
      return "目标磁盘为只读，无法写入。"
    case EIO:
      return "读写磁盘时发生输入输出错误，设备可能已断开或损坏。"
    case ENOENT:
      return "源项目或目标位置已不存在。"
    case EDQUOT:
      return "已超出目标磁盘的配额限制。"
    case EFBIG:
      return "文件体积超出目标磁盘文件系统的上限。"
    case ENAMETOOLONG:
      return "文件路径过长，目标文件系统无法接受。"
    case ENOTDIR:
      return "目标位置不是文件夹。"
    case ENOMEM:
      return "可用内存不足，无法完成复制。"
    default:
      guard let message = strerror(errorNumber) else {
        return "复制失败，错误码 \(errorNumber)。"
      }
      return "复制失败：\(String(cString: message))（错误码 \(errorNumber)）。"
    }
  }
}

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

  static func copyItems(
    _ sourceUrls: [URL],
    to requestedDestinationUrl: URL,
    cancellationToken: FileTransferCancellationToken = FileTransferCancellationToken(),
    progressHandler: @escaping ProgressHandler = { _ in }
  ) -> FileTransferCopyResult {
    let fileManager = FileManager()
    let destinationUrl = requestedDestinationUrl.standardizedFileURL
    let standardizedSourceUrls = sourceUrls.map(\.standardizedFileURL)
    let sourceByteCounts = standardizedSourceUrls.map {
      byteCount(for: $0, fileManager: fileManager)
    }
    let totalBytes = sourceByteCounts.reduce(0, +)
    let totalItemCount = standardizedSourceUrls.count

    var copiedUrls: [URL] = []
    var failures: [FileTransferCopyFailure] = []
    var completedBytes: Int64 = 0

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
        continue
      }

      let targetUrl = availableTargetUrl(
        for: sourceUrl,
        in: destinationUrl,
        fileManager: fileManager
      )
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

      let copyErrorNumber = copyItem(
        at: sourceUrl,
        to: targetUrl,
        context: context
      )
      if copyErrorNumber == 0 {
        copiedUrls.append(targetUrl)
        completedBytes += sourceByteCounts[index]
        progressHandler(
          FileTransferProgressSnapshot(
            currentFileName: sourceUrl.lastPathComponent,
            completedBytes: min(completedBytes, totalBytes),
            totalBytes: totalBytes,
            completedItemCount: index + 1,
            totalItemCount: totalItemCount
          )
        )
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
    fileManager: FileManager
  ) -> URL {
    let originalTargetUrl = destinationUrl.appendingPathComponent(sourceUrl.lastPathComponent)
    guard fileManager.fileExists(atPath: originalTargetUrl.path) else {
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
      if !fileManager.fileExists(atPath: candidateUrl.path) {
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

  private static func byteCount(
    for sourceUrl: URL,
    fileManager: FileManager
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
    while let itemUrl = enumerator?.nextObject() as? URL {
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

  private static func errorMessage(for errorNumber: Int32) -> String {
    guard let message = strerror(errorNumber) else {
      return "复制失败，错误码 \(errorNumber)。"
    }
    return String(cString: message)
  }
}

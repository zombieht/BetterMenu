import Darwin
import Foundation

// MARK: - Finder 扩展与主应用之间的一次性安全请求
//
// 扩展不得通过 URL Scheme 明文传递动作 ID 或文件路径，只能传递不透明 UUID。
// 请求本体以 0600 权限原子写入 `~/Library/Application Support/BetterMenu/Requests/`，
// 由主应用校验所有者、权限位、文件类型、体积、协议版本、路径格式与有效期后一次性消费。
// 该文件同时编译进主 App、FinderSync 扩展与测试三个 Target，是三者共享的安全边界，
// 因此从 `BetterMenuShared.swift` 中独立出来单独维护与审查。

/// Finder 扩展可以委托给主应用执行的请求类型。
enum BetterMenuRequestOperation: String, Codable, Sendable {
  case runAction
  case fileTransfer
}

/// 文件传输请求的执行方式。
enum BetterMenuFileTransferMode: String, Codable, Sendable {
  case airDrop
  case copy
}

/// Finder 扩展写入磁盘、由主应用一次性消费的安全请求。
struct BetterMenuSecureRequest: Codable, Equatable, Sendable {
  static let currentVersion = 1

  let version: Int
  let id: UUID
  let createdAt: TimeInterval
  let operation: BetterMenuRequestOperation
  let actionId: String?
  let sourcePaths: [String]
  let transferMode: BetterMenuFileTransferMode?
  let destinationPath: String?

  static func runAction(
    actionId: String,
    path: String,
    id: UUID = UUID(),
    createdAt: TimeInterval = Date().timeIntervalSince1970
  ) -> BetterMenuSecureRequest {
    BetterMenuSecureRequest(
      version: currentVersion,
      id: id,
      createdAt: createdAt,
      operation: .runAction,
      actionId: actionId,
      sourcePaths: [path],
      transferMode: nil,
      destinationPath: nil
    )
  }

  static func fileTransfer(
    sourcePaths: [String],
    mode: BetterMenuFileTransferMode,
    destinationPath: String?,
    id: UUID = UUID(),
    createdAt: TimeInterval = Date().timeIntervalSince1970
  ) -> BetterMenuSecureRequest {
    BetterMenuSecureRequest(
      version: currentVersion,
      id: id,
      createdAt: createdAt,
      operation: .fileTransfer,
      actionId: nil,
      sourcePaths: sourcePaths,
      transferMode: mode,
      destinationPath: destinationPath
    )
  }
}

/// 一次性请求文件的写入、URL 生成和安全消费错误。
enum BetterMenuSecureRequestError: LocalizedError {
  case invalidLaunchUrl
  case invalidRequest
  case requestExpired
  case requestFileUnavailable
  case insecureRequestFile

  var errorDescription: String? {
    switch self {
    case .invalidLaunchUrl:
      return "请求链接无效。"
    case .invalidRequest:
      return "请求内容无效。"
    case .requestExpired:
      return "请求已过期。"
    case .requestFileUnavailable:
      return "请求文件不存在或无法读取。"
    case .insecureRequestFile:
      return "请求文件未通过安全检查。"
    }
  }
}

/// 通过仅包含不透明 UUID 的 URL Scheme，在 Finder 扩展与主应用间传递一次性请求。
enum BetterMenuSecureRequestStore {
  private static let maximumRequestAge: TimeInterval = 30
  private static let maximumFutureClockSkew: TimeInterval = 5
  private static let maximumRequestFileSize: off_t = 1_048_576
  private static let requestFileExtension = "plist"
  private static let launchScheme = "bettermenu"
  private static let launchHost = "request"

  static func submit(
    _ request: BetterMenuSecureRequest,
    directoryUrl: URL = BetterMenuShared.secureRequestDirectoryUrl
  ) throws {
    try validateStructure(request)
    try prepareRequestDirectory(directoryUrl)
    removeExpiredFiles(in: directoryUrl)

    let data = try PropertyListEncoder().encode(request)
    let requestUrl = fileUrl(for: request.id, directoryUrl: directoryUrl)
    try writeSecurely(data, to: requestUrl)
  }

  static func launchUrl(for requestId: UUID) throws -> URL {
    var components = URLComponents()
    components.scheme = launchScheme
    components.host = launchHost
    components.queryItems = [
      URLQueryItem(name: "id", value: requestId.uuidString.lowercased())
    ]
    guard let url = components.url else {
      throw BetterMenuSecureRequestError.invalidLaunchUrl
    }
    return url
  }

  static func requestId(from launchUrl: URL) throws -> UUID {
    guard
      launchUrl.scheme?.lowercased() == launchScheme,
      launchUrl.host?.lowercased() == launchHost,
      let components = URLComponents(url: launchUrl, resolvingAgainstBaseURL: false),
      components.user == nil,
      components.password == nil,
      components.port == nil,
      components.path.isEmpty,
      components.fragment == nil,
      let queryItems = components.queryItems,
      queryItems.count == 1,
      queryItems[0].name == "id",
      let value = queryItems[0].value,
      let requestId = UUID(uuidString: value)
    else {
      throw BetterMenuSecureRequestError.invalidLaunchUrl
    }
    return requestId
  }

  static func consume(
    requestId: UUID,
    directoryUrl: URL = BetterMenuShared.secureRequestDirectoryUrl,
    now: TimeInterval = Date().timeIntervalSince1970
  ) throws -> BetterMenuSecureRequest {
    try validateRequestDirectory(directoryUrl)
    let requestUrl = fileUrl(for: requestId, directoryUrl: directoryUrl)
    let fileDescriptor = open(requestUrl.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fileDescriptor >= 0 else {
      throw BetterMenuSecureRequestError.requestFileUnavailable
    }

    var shouldCloseDescriptor = true
    defer {
      if shouldCloseDescriptor {
        close(fileDescriptor)
      }
    }

    var fileStatus = stat()
    guard fstat(fileDescriptor, &fileStatus) == 0 else {
      throw BetterMenuSecureRequestError.requestFileUnavailable
    }

    let isRegularFile = (fileStatus.st_mode & S_IFMT) == S_IFREG
    let hasRestrictedPermissions = (fileStatus.st_mode & 0o077) == 0
    guard
      isRegularFile,
      fileStatus.st_uid == getuid(),
      hasRestrictedPermissions,
      fileStatus.st_size > 0,
      fileStatus.st_size <= maximumRequestFileSize
    else {
      throw BetterMenuSecureRequestError.insecureRequestFile
    }

    guard unlink(requestUrl.path) == 0 else {
      throw BetterMenuSecureRequestError.requestFileUnavailable
    }

    let fileHandle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
    shouldCloseDescriptor = false
    let data = try fileHandle.readToEnd() ?? Data()
    try fileHandle.close()

    let request = try PropertyListDecoder().decode(BetterMenuSecureRequest.self, from: data)
    guard request.id == requestId else {
      throw BetterMenuSecureRequestError.invalidRequest
    }
    try validateStructure(request)

    let requestAge = now - request.createdAt
    guard
      requestAge >= -maximumFutureClockSkew,
      requestAge <= maximumRequestAge
    else {
      throw BetterMenuSecureRequestError.requestExpired
    }

    return request
  }

  static func discard(
    requestId: UUID,
    directoryUrl: URL = BetterMenuShared.secureRequestDirectoryUrl
  ) {
    try? FileManager.default.removeItem(at: fileUrl(for: requestId, directoryUrl: directoryUrl))
  }

  private static func prepareRequestDirectory(_ directoryUrl: URL) throws {
    try FileManager.default.createDirectory(
      at: directoryUrl,
      withIntermediateDirectories: true
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directoryUrl.path
    )
    try validateRequestDirectory(directoryUrl)
  }

  private static func validateRequestDirectory(_ directoryUrl: URL) throws {
    var directoryStatus = stat()
    guard
      lstat(directoryUrl.path, &directoryStatus) == 0,
      (directoryStatus.st_mode & S_IFMT) == S_IFDIR,
      directoryStatus.st_uid == getuid(),
      (directoryStatus.st_mode & 0o077) == 0
    else {
      throw BetterMenuSecureRequestError.insecureRequestFile
    }
  }

  private static func writeSecurely(_ data: Data, to requestUrl: URL) throws {
    let fileDescriptor = open(
      requestUrl.path,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      mode_t(0o600)
    )
    guard fileDescriptor >= 0 else {
      throw BetterMenuSecureRequestError.requestFileUnavailable
    }

    var didFinishWriting = false
    defer {
      close(fileDescriptor)
      if !didFinishWriting {
        unlink(requestUrl.path)
      }
    }

    try data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else {
        throw BetterMenuSecureRequestError.invalidRequest
      }

      var totalBytesWritten = 0
      while totalBytesWritten < rawBuffer.count {
        let bytesWritten = Darwin.write(
          fileDescriptor,
          baseAddress.advanced(by: totalBytesWritten),
          rawBuffer.count - totalBytesWritten
        )
        if bytesWritten < 0, errno == EINTR {
          continue
        }
        guard bytesWritten > 0 else {
          throw BetterMenuSecureRequestError.requestFileUnavailable
        }
        totalBytesWritten += bytesWritten
      }
    }

    guard fsync(fileDescriptor) == 0 else {
      throw BetterMenuSecureRequestError.requestFileUnavailable
    }
    didFinishWriting = true
  }

  private static func fileUrl(for requestId: UUID, directoryUrl: URL) -> URL {
    directoryUrl
      .appendingPathComponent(requestId.uuidString.lowercased())
      .appendingPathExtension(requestFileExtension)
  }

  private static func validateStructure(_ request: BetterMenuSecureRequest) throws {
    guard
      request.version == BetterMenuSecureRequest.currentVersion,
      request.sourcePaths.allSatisfy(isStandardAbsolutePath(_:))
    else {
      throw BetterMenuSecureRequestError.invalidRequest
    }

    switch request.operation {
    case .runAction:
      guard
        let actionId = request.actionId,
        !actionId.isEmpty,
        request.sourcePaths.count == 1,
        request.transferMode == nil,
        request.destinationPath == nil
      else {
        throw BetterMenuSecureRequestError.invalidRequest
      }
    case .fileTransfer:
      guard
        request.actionId == nil,
        !request.sourcePaths.isEmpty,
        let transferMode = request.transferMode
      else {
        throw BetterMenuSecureRequestError.invalidRequest
      }

      switch transferMode {
      case .airDrop:
        guard request.destinationPath == nil else {
          throw BetterMenuSecureRequestError.invalidRequest
        }
      case .copy:
        guard
          let destinationPath = request.destinationPath,
          isStandardAbsolutePath(destinationPath)
        else {
          throw BetterMenuSecureRequestError.invalidRequest
        }
      }
    }
  }

  private static func isStandardAbsolutePath(_ path: String) -> Bool {
    guard path.hasPrefix("/") else { return false }
    return URL(fileURLWithPath: path).standardizedFileURL.path == path
  }

  private static func removeExpiredFiles(in directoryUrl: URL) {
    let expirationDate = Date().addingTimeInterval(-maximumRequestAge * 2)
    guard
      let fileUrls = try? FileManager.default.contentsOfDirectory(
        at: directoryUrl,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return
    }

    for fileUrl in fileUrls where fileUrl.pathExtension == requestFileExtension {
      guard
        let values = try? fileUrl.resourceValues(
          forKeys: [.contentModificationDateKey, .isRegularFileKey]),
        values.isRegularFile == true,
        let modificationDate = values.contentModificationDate,
        modificationDate < expirationDate
      else {
        continue
      }
      try? FileManager.default.removeItem(at: fileUrl)
    }
  }
}

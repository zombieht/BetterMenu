import Cocoa
import Darwin

// MARK: - 共享常量与路径定义

/// 提供 BetterMenu 主应用与 FinderSync 插件共享的常量与系统路径计算。
enum BetterMenuShared {
  static let enabledFileTypesKey = "enabledFileTypes"
  static let customExtensionsKey = "customExtensions"
  static let menuOrderKey = "menuOrder"

  // 兼容旧版本的偏好设置键名。
  static let oldTerminalDirectEnabledKey = "terminalDirectEnabled"
  static let oldPathCopyEnabledKey = "pathCopyEnabled"
  static let terminalTypeKey = "terminalType"
  static let customMenuIdPrefix = "custom."

  /// 获取用户真正的 Home 目录 URL。
  ///
  /// FinderSync 插件运行在沙盒中，直接调用
  /// `FileManager.default.homeDirectoryForCurrentUser` 会返回沙盒容器路径。这里通过
  /// `getpwuid` 或环境用户名获取不受沙盒限制的真实用户目录。
  static var realHomeDirectoryUrl: URL {
    let uid = getuid()
    if let pw = getpwuid(uid), let pwDir = pw.pointee.pw_dir {
      let path = FileManager.default.string(
        withFileSystemRepresentation: pwDir,
        length: strlen(pwDir)
      )
      if !path.isEmpty {
        return URL(fileURLWithPath: path, isDirectory: true)
      }
    }

    let userName = NSUserName()
    if !userName.isEmpty {
      return URL(fileURLWithPath: "/Users/\(userName)", isDirectory: true)
    }

    return FileManager.default.homeDirectoryForCurrentUser
  }

  /// 共享偏好设置 plist 文件的存储路径。
  static var sharedSettingsUrl: URL {
    realHomeDirectoryUrl
      .appendingPathComponent("Library/Application Support/BetterMenu/settings.plist")
  }

  /// 文件类型图标磁盘缓存文件存储路径。
  static var iconCacheUrl: URL {
    realHomeDirectoryUrl
      .appendingPathComponent("Library/Caches/BetterMenu/icon_cache.plist")
  }

  /// Finder 扩展向主应用提交一次性请求时使用的受限目录。
  static var secureRequestDirectoryUrl: URL {
    realHomeDirectoryUrl
      .appendingPathComponent("Library/Application Support/BetterMenu/Requests", isDirectory: true)
  }

  /// 返回当前已挂载、可写且不位于 Mac 内部磁盘上的文件传输目标。
  static func availableFileTransferVolumes(
    fileManager: FileManager = .default
  ) -> [FileTransferVolume] {
    let resourceKeys: Set<URLResourceKey> = [
      .volumeIsBrowsableKey,
      .volumeIsEjectableKey,
      .volumeIsInternalKey,
      .volumeIsLocalKey,
      .volumeIsReadOnlyKey,
      .volumeIsRemovableKey,
      .volumeLocalizedNameKey,
    ]
    let mountedVolumeUrls =
      fileManager.mountedVolumeURLs(
        includingResourceValuesForKeys: Array(resourceKeys),
        options: [.skipHiddenVolumes]
      ) ?? []

    return mountedVolumeUrls.compactMap { volumeUrl in
      guard let values = try? volumeUrl.resourceValues(forKeys: resourceKeys) else {
        return nil
      }
      let isSupportedTarget =
        values.volumeIsInternal == false
        || values.volumeIsRemovable == true
        || values.volumeIsEjectable == true
        || values.volumeIsLocal == false
      guard
        values.volumeIsBrowsable != false,
        isSupportedTarget,
        values.volumeIsReadOnly != true,
        fileManager.isWritableFile(atPath: volumeUrl.path)
      else {
        return nil
      }

      let name = values.volumeLocalizedName ?? volumeUrl.lastPathComponent
      return FileTransferVolume(name: name, url: volumeUrl.standardizedFileURL)
    }
    .sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  // MARK: - 支持的第三方编辑器信息

  /// 表示支持的第三方编辑器的元数据。
  struct EditorAppInfo: Identifiable, Codable, Hashable, Sendable {
    var id: String { idString }
    let idString: String
    let name: String
    let title: String
    let bundleIds: [String]
    let iconName: String

    init(id: String, name: String, title: String, bundleIds: [String], iconName: String) {
      self.idString = id
      self.name = name
      self.title = title
      self.bundleIds = bundleIds
      self.iconName = iconName
    }
  }

  /// 支持的常用开发编辑器配置列表。
  static let supportedEditors: [EditorAppInfo] = [
    EditorAppInfo(
      id: "vscode",
      name: "VS Code",
      title: "在 VS Code 中打开",
      bundleIds: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"],
      iconName: "square.and.arrow.up"
    ),
    EditorAppInfo(
      id: "cursor",
      name: "Cursor",
      title: "在 Cursor 中打开",
      bundleIds: ["anysphere.cursor", "com.todesktop.230313mptn472d6"],
      iconName: "sparkles"
    ),
    EditorAppInfo(
      id: "antigravity",
      name: "Antigravity",
      title: "在 Antigravity 中打开",
      bundleIds: ["com.google.antigravity", "com.google.antigravity-ide"],
      iconName: "sparkles"
    ),
    EditorAppInfo(
      id: "xcode",
      name: "Xcode",
      title: "在 Xcode 中打开",
      bundleIds: ["com.apple.dt.Xcode"],
      iconName: "hammer"
    ),
    EditorAppInfo(
      id: "sublime",
      name: "Sublime Text",
      title: "在 Sublime Text 中打开",
      bundleIds: ["com.sublimetext.4", "com.sublimetext.3"],
      iconName: "doc.text"
    ),
    EditorAppInfo(
      id: "intellij",
      name: "IntelliJ IDEA",
      title: "在 IntelliJ IDEA 中打开",
      bundleIds: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"],
      iconName: "terminal"
    ),
    EditorAppInfo(
      id: "webstorm",
      name: "WebStorm",
      title: "在 WebStorm 中打开",
      bundleIds: ["com.jetbrains.WebStorm", "com.jetbrains.WebStorm-EAP"],
      iconName: "globe"
    ),
    EditorAppInfo(
      id: "pycharm",
      name: "PyCharm",
      title: "在 PyCharm 中打开",
      bundleIds: ["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce"],
      iconName: "doc.plaintext"
    ),
    EditorAppInfo(
      id: "androidstudio",
      name: "Android Studio",
      title: "在 Android Studio 中打开",
      bundleIds: ["com.google.android.studio"],
      iconName: "play.circle"
    ),
    EditorAppInfo(
      id: "coteditor",
      name: "CotEditor",
      title: "在 CotEditor 中打开",
      bundleIds: ["com.coteditor.CotEditor"],
      iconName: "square.and.pencil"
    ),
    EditorAppInfo(
      id: "codex",
      name: "Codex",
      title: "在 Codex 中打开",
      bundleIds: ["com.openai.codex"],
      iconName: "sparkles"
    ),
  ]

  /// 全局支持的内置文件类型与模板定义。
  static let supportedFileTypes: [FileDefinition] = [
    FileDefinition(
      id: "docx",
      title: "Word",
      menuTitle: "新建 Word 文档",
      baseName: "新建 Word 文档",
      pathExtension: "docx",
      bundledTemplateExtension: "docx",
      enabledByDefault: true
    ),
    FileDefinition(
      id: "xlsx",
      title: "Excel",
      menuTitle: "新建 Excel 表格",
      baseName: "新建 Excel 表格",
      pathExtension: "xlsx",
      bundledTemplateExtension: "xlsx",
      enabledByDefault: true
    ),
    FileDefinition(
      id: "pptx",
      title: "PowerPoint",
      menuTitle: "新建 PowerPoint 演示文稿",
      baseName: "新建 PowerPoint 演示文稿",
      pathExtension: "pptx",
      bundledTemplateExtension: "pptx",
      enabledByDefault: true
    ),
    FileDefinition(
      id: "txt",
      title: "TXT",
      menuTitle: "新建 TXT 文件",
      baseName: "新建 TXT 文件",
      pathExtension: "txt",
      enabledByDefault: true
    ),
    FileDefinition(
      id: "md",
      title: "Markdown",
      menuTitle: "新建 Markdown 文件",
      baseName: "新建 Markdown 文件",
      pathExtension: "md",
      enabledByDefault: true
    ),
    FileDefinition(
      id: "blank",
      title: "空白文件",
      menuTitle: "新建空白文件",
      baseName: "新建文件",
      pathExtension: nil,
      enabledByDefault: true
    ),
    FileDefinition(
      id: "py",
      title: "Python",
      menuTitle: "新建 Python 文件",
      baseName: "新建 Python 文件",
      pathExtension: "py",
      text: "#!/usr/bin/env python3\n\n",
      enabledByDefault: false
    ),
    FileDefinition(
      id: "html",
      title: "HTML",
      menuTitle: "新建 HTML 文件",
      baseName: "新建 HTML 文件",
      pathExtension: "html",
      text: """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <title></title>
        </head>
        <body>

        </body>
        </html>

        """,
      enabledByDefault: false
    ),
    FileDefinition(
      id: "sh",
      title: "Shell",
      menuTitle: "新建 Shell 文件",
      baseName: "新建 Shell 文件",
      pathExtension: "sh",
      text: "#!/usr/bin/env bash\n\n",
      shouldBeExecutable: true,
      enabledByDefault: false
    )
  ]
}

// MARK: - 共享数据结构定义

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

/// 表示可以从 Finder 右键菜单创建的文件类型及其模板定义。
struct FileDefinition: Identifiable, Codable, Hashable, Sendable {
  let id: String
  /// 在设置面板中显示的标题
  let title: String
  /// 在右键菜单中显示的标题
  let menuTitle: String
  /// 文件默认的基准名称 (如 "新建 Word 文档")
  let baseName: String
  /// 文件后缀名
  let pathExtension: String?
  /// 内置于 Bundle 中的模板文件后缀名 (如 "docx", "xlsx")
  let bundledTemplateExtension: String?
  /// 新建文件时的初始文本内容
  let text: String?
  /// 文件是否需要被设置为可执行权限
  let shouldBeExecutable: Bool
  /// 是否默认在菜单中启用
  let enabledByDefault: Bool

  init(
    id: String,
    title: String,
    menuTitle: String,
    baseName: String,
    pathExtension: String?,
    bundledTemplateExtension: String? = nil,
    text: String? = nil,
    shouldBeExecutable: Bool = false,
    enabledByDefault: Bool
  ) {
    self.id = id
    self.title = title
    self.menuTitle = menuTitle
    self.baseName = baseName
    self.pathExtension = pathExtension
    self.bundledTemplateExtension = bundledTemplateExtension
    self.text = text
    self.shouldBeExecutable = shouldBeExecutable
    self.enabledByDefault = enabledByDefault
  }

  /// 获取文件模板的二进制数据。
  /// - Parameter bundle: 包含资源的 Bundle 实例。
  /// - Returns: 文件数据的 Data 表现形式。
  func contents(in bundle: Bundle) throws -> Data {
    if let bundledTemplateExtension = bundledTemplateExtension {
      guard
        let url = bundle.url(forResource: "blank", withExtension: bundledTemplateExtension)
      else {
        throw CocoaError(.fileReadNoSuchFile)
      }
      return try Data(contentsOf: url)
    }
    return text?.data(using: .utf8) ?? Data()
  }
}

/// 表示一个访达快捷右键操作数据结构，由主 App 的 SwiftUI 面板和 FinderSync 菜单共用。
struct FinderAction: Identifiable, Codable, Hashable, Sendable {
  let id: String
  let title: String
  let iconName: String
  var isEnabled: Bool
}

/// 表示“发送文件到”菜单中的一个已挂载文件系统目标。
struct FileTransferVolume: Identifiable, Hashable, Sendable {
  var id: URL { url }
  let name: String
  let url: URL
}

/// 始终保留在设置页中的内置 Finder 快捷操作。
let requiredSharedActions: [FinderAction] = [
  FinderAction(id: "terminal", title: "在终端中打开", iconName: "terminal", isEnabled: true),
  FinderAction(id: "copyPath", title: "复制当前路径", iconName: "doc.on.doc", isEnabled: true),
  FinderAction(id: "sendFile", title: "发送文件到", iconName: "paperplane", isEnabled: true),
]

/// 默认提供的快捷操作列表。
let defaultSharedActions: [FinderAction] = requiredSharedActions + [
  FinderAction(
    id: "vscode",
    title: "在 VS Code 中打开",
    iconName: "square.and.arrow.up",
    isEnabled: true
  ),
]

/// 为旧版配置补齐后来新增的必备内置操作，同时保留用户原有的启用状态和排序。
func actionsAddingMissingRequiredActions(_ actions: [FinderAction]) -> [FinderAction] {
  var normalizedActions = actions

  for requiredAction in requiredSharedActions
  where !normalizedActions.contains(where: { $0.id == requiredAction.id }) {
    if requiredAction.id == "sendFile",
      let copyPathIndex = normalizedActions.firstIndex(where: { $0.id == "copyPath" })
    {
      normalizedActions.insert(requiredAction, at: copyPathIndex + 1)
    } else {
      normalizedActions.append(requiredAction)
    }
  }

  return normalizedActions
}

// MARK: - 公共映射函数

/// 根据传入的文件类型 ID 映射并提取标准的路径扩展名。
/// "blank" 对应空字符串（无扩展名文件），其余 ID 直接作为扩展名使用。
func cleanExtension(for id: String) -> String {
  let cleanID =
    id.hasPrefix(BetterMenuShared.customMenuIdPrefix)
    ? String(id.dropFirst(BetterMenuShared.customMenuIdPrefix.count))
    : id
  return cleanID == "blank" ? "" : cleanID
}

// MARK: - 统一设置读取封装

/// 共享偏好设置的承载结构。
struct SharedSettingsPayload {
  let enabledFileTypes: [String]?
  let customExtensions: [String]?
  let menuOrder: [String]?
  let oldTerminalDirectEnabled: Bool?
  let oldPathCopyEnabled: Bool?
  let terminalType: String?
  let actions: [FinderAction]?
}

/// 统一从共享 plist 读取并序列化当前配置。
func readSharedSettings() -> SharedSettingsPayload {
  let emptyPayload = SharedSettingsPayload(
    enabledFileTypes: nil,
    customExtensions: nil,
    menuOrder: nil,
    oldTerminalDirectEnabled: nil,
    oldPathCopyEnabled: nil,
    terminalType: nil,
    actions: nil
  )

  let url = BetterMenuShared.sharedSettingsUrl
  guard
    let data = try? Data(contentsOf: url),
    let payload = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
      as? [String: Any]
  else {
    return emptyPayload
  }

  let parsedActions: [FinderAction]? = (payload["actions"] as? [[String: Any]])?.compactMap {
    dict in
    guard
      let id = dict["id"] as? String,
      let title = dict["title"] as? String,
      let iconName = dict["iconName"] as? String,
      let isEnabled = dict["isEnabled"] as? Bool
    else {
      return nil
    }
    return FinderAction(id: id, title: title, iconName: iconName, isEnabled: isEnabled)
  }

  return SharedSettingsPayload(
    enabledFileTypes: payload[BetterMenuShared.enabledFileTypesKey] as? [String],
    customExtensions: payload[BetterMenuShared.customExtensionsKey] as? [String],
    menuOrder: payload[BetterMenuShared.menuOrderKey] as? [String],
    oldTerminalDirectEnabled: payload[BetterMenuShared.oldTerminalDirectEnabledKey] as? Bool,
    oldPathCopyEnabled: payload[BetterMenuShared.oldPathCopyEnabledKey] as? Bool,
    terminalType: payload[BetterMenuShared.terminalTypeKey] as? String,
    actions: parsedActions
  )
}

// MARK: - 图片像素重绘扩展

extension NSImage {
  /// 将系统图标重绘到 Retina PNG，避免保存完整 TIFF 造成缓存膨胀。
  func exportToPngData(targetSize: NSSize = NSSize(width: 18, height: 18)) -> Data? {
    let scale: CGFloat = 2.0
    let pixelSize = NSSize(width: targetSize.width * scale, height: targetSize.height * scale)

    guard
      let bitmapRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(pixelSize.width),
        pixelsHigh: Int(pixelSize.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    else {
      return nil
    }

    bitmapRep.size = targetSize
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(in: NSRect(origin: .zero, size: targetSize))
    NSGraphicsContext.restoreGraphicsState()

    return bitmapRep.representation(using: .png, properties: [:])
  }
}

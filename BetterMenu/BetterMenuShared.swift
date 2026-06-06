import Cocoa

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

/// 默认提供的快捷操作列表。
let defaultSharedActions: [FinderAction] = [
  FinderAction(id: "terminal", title: "在终端中打开", iconName: "terminal", isEnabled: true),
  FinderAction(id: "copyPath", title: "复制当前路径", iconName: "doc.on.doc", isEnabled: true),
  FinderAction(
    id: "vscode",
    title: "在 VS Code 中打开",
    iconName: "square.and.arrow.up",
    isEnabled: true
  ),
]

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

import Cocoa
import FinderSync
import UserNotifications
import os

/// 访达扩展插件主类，负责动态向 Finder 插入右键菜单
final class FinderSync: FIFinderSync {
  private let logger = Logger(subsystem: "com.zombie.BetterMenu", category: "FinderSync")
  
  // 偏好设置监控与图标管理器实例
  private let settingsMonitor = SettingsMonitor()
  private let iconManager = MenuIconManager()
  
  // Tag 路由映射，每次构建菜单时更新，以保证点击回调可以找到对应数据
  private var menuDefinitionsByTag: [Int: FileDefinition] = [:]
  private var actionDefinitionsByTag: [Int: FinderAction] = [:]
  private static let dynamicActionTagBase = 1000

  // MARK: - 基础图标加载

  /// 主菜单图标，自适应系统深浅色外观并使用内存缓存
  private var menuIcon: NSImage {
    MenuIconManager.finderMenuSymbol(named: "doc.badge.plus", accessibilityDescription: "新建文件")
  }
  
  /// 工具栏图标，自适应系统外观并强制单色
  private lazy var toolbarIcon: NSImage = {
    let symbolImage = MenuIconManager.finderMenuSymbol(named: "doc.badge.plus", accessibilityDescription: "BetterMenu")
    symbolImage.isTemplate = true
    return symbolImage
  }()

  // MARK: - 监视目录

  /// 计算并返回 FinderSync 需要监视的系统及用户目录列表
  private static func monitoredDirectoryUrls() -> [URL] {
    let fileManager = FileManager.default
    let userHomeUrl = BetterMenuShared.realHomeDirectoryUrl
    var urls = [
      userHomeUrl,
      URL(fileURLWithPath: "/Volumes", isDirectory: true),
    ]

    let iCloudCandidateUrls = [
      userHomeUrl
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Mobile Documents", isDirectory: true)
        .appendingPathComponent("com~apple~CloudDocs", isDirectory: true),
      userHomeUrl
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Mobile Documents", isDirectory: true),
    ]
    urls.append(contentsOf: iCloudCandidateUrls)

    var seenPaths: Set<String> = []
    return urls.filter { url in
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
        isDirectory.boolValue,
        !seenPaths.contains(url.path)
      else {
        return false
      }
      seenPaths.insert(url.path)
      return true
    }
  }

  // MARK: - 构造与析构

  override init() {
    super.init()
    let monitoredUrls = Self.monitoredDirectoryUrls()
    FIFinderSyncController.default().directoryURLs = Set(monitoredUrls)
    logger.info("BetterMenu Finder Sync extension loaded")
    
    // 设置监控失效回调：当 settings.plist 发生改变时，自动清理图标管理器中的缓存
    settingsMonitor.onSettingsChanged = { [weak self] in
      self?.iconManager.clearCache()
    }
  }

  override var toolbarItemName: String {
    return "BetterMenu"
  }

  override var toolbarItemToolTip: String {
    return "新建文件"
  }

  override var toolbarItemImage: NSImage {
    return toolbarIcon
  }

  // MARK: - 访达菜单渲染入口

  override func menu(for menuKind: FIMenuKind) -> NSMenu? {
    logger.info("Finder requested menu kind: \(menuKind.rawValue)")
    switch menuKind {
    case .contextualMenuForContainer, .contextualMenuForItems, .toolbarItemMenu:
      let snapshot = settingsMonitor.getCurrentSnapshot()
      return assembleFinderMenu(from: snapshot)
    default:
      return nil
    }
  }

  /// 装配完整的右键上下文菜单
  private func assembleFinderMenu(from snapshot: SettingsMonitor.SettingsSnapshot) -> NSMenu {
    let menu = NSMenu(title: "BetterMenu")
    menuDefinitionsByTag.removeAll()
    actionDefinitionsByTag.removeAll()

    menu.addItem(makeFileCreationMenuItem(from: snapshot))
    for item in makeEnabledShortcutItems(from: snapshot) {
      menu.addItem(item)
    }

    return menu
  }

  /// 构建“新建文件”二级菜单
  private func makeFileCreationMenuItem(from snapshot: SettingsMonitor.SettingsSnapshot) -> NSMenuItem {
    let parent = NSMenuItem(title: "新建文件", action: nil, keyEquivalent: "")
    parent.image = menuIcon

    let submenu = NSMenu(title: "新建文件")
    for (tag, definition) in enabledDefinitions(with: snapshot).enumerated() {
      submenu.addItem(makeFileTypeItem(definition: definition, tag: tag))
    }
    if submenu.items.isEmpty {
      submenu.addItem(makeDisabledPlaceholderItem())
    }

    parent.submenu = submenu
    return parent
  }

  private func makeFileTypeItem(definition: FileDefinition, tag: Int) -> NSMenuItem {
    let item = NSMenuItem(
      title: definition.title, action: #selector(createConfiguredFile(_:)), keyEquivalent: "")
    item.target = self
    item.tag = tag
    configureIcon(for: item, definition: definition)
    menuDefinitionsByTag[tag] = definition
    return item
  }

  private func makeDisabledPlaceholderItem() -> NSMenuItem {
    let item = NSMenuItem(title: "未启用新建文件类型", action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  /// 构建终端、复制路径、编辑器等一级右键快捷操作
  private func makeEnabledShortcutItems(from snapshot: SettingsMonitor.SettingsSnapshot) -> [NSMenuItem] {
    var nextTag = Self.dynamicActionTagBase
    return snapshot.actions.filter(\.isEnabled).map { action in
      let tag = nextTag
      nextTag += 1
      actionDefinitionsByTag[tag] = action
      return makeShortcutItem(action: action, tag: tag)
    }
  }

  private func makeShortcutItem(action: FinderAction, tag: Int) -> NSMenuItem {
    let item = NSMenuItem(
      title: action.title, action: #selector(runDynamicAction(_:)), keyEquivalent: "")
    item.target = self
    item.tag = tag
    item.image =
      iconManager.getCachedIcon(for: action.id)
      ?? MenuIconManager.finderMenuSymbol(named: action.iconName, accessibilityDescription: action.title)
    return item
  }

  /// 针对菜单项进行图标装配
  private func configureIcon(for item: NSMenuItem, definition: FileDefinition) {
    if let icon = iconManager.getCachedIcon(for: definition.id) {
      item.image = icon
    } else {
      item.image = MenuIconManager.finderMenuSymbol(
        named: fallbackSymbolIconName(for: definition), accessibilityDescription: definition.title)
    }
  }

  /// 返回真实文件类型图标尚未预热完成或缺失时的占位 SF Symbol 名称。
  private func fallbackSymbolIconName(for definition: FileDefinition) -> String {
    switch definition.id {
    case "txt", "md":
      return "doc.text"
    case "json":
      return "curlybraces"
    case "py", "html", "sh":
      return "chevron.left.forwardslash.chevron.right"
    case "blank":
      return "doc"
    default:
      let pathExtension = cleanExtension(for: definition.id)
      let codeExtensions: Set<String> = [
        "c", "cc", "cpp", "css", "go", "h", "hpp", "java", "js", "jsx",
        "kt", "php", "rb", "rs", "scss", "swift", "ts", "tsx", "vue",
      ]
      return codeExtensions.contains(pathExtension)
        ? "chevron.left.forwardslash.chevron.right" : "doc"
    }
  }

  /// 获取当前已启用的文件类型列表并进行排序
  private func enabledDefinitions(with snapshot: SettingsMonitor.SettingsSnapshot) -> [FileDefinition] {
    let builtIns = BetterMenuShared.supportedFileTypes.filter { snapshot.enabledFileTypes.contains($0.id) }
    let customDefinitions = snapshot.customExtensions.map { fileExtension in
      FileDefinition(
        id: "custom.\(fileExtension)",
        title: "新建 \(fileExtension.uppercased()) 文件",
        menuTitle: "新建 \(fileExtension.uppercased()) 文件",
        baseName: "新建 \(fileExtension.uppercased()) 文件",
        pathExtension: fileExtension,
        enabledByDefault: false
      )
    }

    return orderedDefinitions(builtIns + customDefinitions, menuOrder: snapshot.menuOrder)
  }

  private func orderedDefinitions(_ definitions: [FileDefinition], menuOrder: [String]?)
    -> [FileDefinition]
  {
    guard let menuOrder = menuOrder else { return definitions }

    let definitionsById = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
    let orderedDefinitions = menuOrder.compactMap { definitionsById[$0] }
    let orderedIds = Set(orderedDefinitions.map(\.id))
    let remainingDefinitions = definitions.filter { !orderedIds.contains($0.id) }

    return orderedDefinitions + remainingDefinitions
  }

  // MARK: - 点击菜单响应

  @objc private func createConfiguredFile(_ sender: NSMenuItem) {
    guard let definition = menuDefinitionsByTag[sender.tag] else {
      logger.error("Create file action invoked without a file definition for tag \(sender.tag)")
      return
    }
    createFile(from: definition)
  }

  /// 执行动态 Action 点击响应
  @objc private func runDynamicAction(_ sender: NSMenuItem) {
    guard let action = actionDefinitionsByTag[sender.tag] else { return }

    // 复制路径操作可以直接在 FinderSync 进程中无缝执行，无需唤醒主 App，体验更佳
    if action.id == "copyPath" {
      executeCopyPath()
    } else {
      // 其它操作（如终端打开、VS Code 打开）需要系统级交互权限或 AppKit 窗口唤起，委托给主应用执行
      executeDelegatedAction(action)
    }
  }

  private func executeCopyPath() {
    guard let pathUrl = resolveFinderLocation(for: .copyCurrentPath) else {
      showError(message: "无法确定目标路径。")
      return
    }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(pathUrl.path, forType: .string)
  }

  private func executeDelegatedAction(_ action: FinderAction) {
    guard let directory = resolveFinderLocation(for: .openSelectionContainer) else {
      showError(message: "无法确定目标文件夹。")
      return
    }

    var components = URLComponents()
    components.scheme = "BetterMenu"
    components.host = "run-action"
    components.queryItems = [
      URLQueryItem(name: "id", value: action.id),
      URLQueryItem(name: "path", value: directory.path),
    ]

    guard let requestUrl = components.url else {
      showError(message: "无法生成请求指令。")
      return
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.promptsUserIfNeeded = true

    NSWorkspace.shared.open(requestUrl, configuration: configuration) { [weak self] _, error in
      if let error = error {
        self?.showError(message: "唤起 BetterMenu 失败：\(error.localizedDescription)")
        return
      }
    }
  }

  // MARK: - 文件与目录处理辅助

  private func createFile(from definition: FileDefinition) {
    guard let directory = resolveFinderLocation(for: .createFileInContainer) else {
      logger.error("Unable to resolve target directory")
      showError(message: "无法确定目标文件夹。")
      return
    }

    do {
      let createdFileUrl = try FileCreator.createFile(from: definition, at: directory)
      revealCreatedFileIfNeeded(createdFileUrl, in: directory)
    } catch {
      logger.error("Create file failed: \(error.localizedDescription, privacy: .public)")
      showError(message: "创建文件失败：\(error.localizedDescription)")
    }
  }

  private func resolveFinderLocation(for intent: FinderLocationIntent) -> URL? {
    let finderController = FIFinderSyncController.default()
    let selectedUrl = finderController.selectedItemURLs()?.first
    let targetedUrl = finderController.targetedURL()
    let desktopUrl = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first

    switch intent {
    case .copyCurrentPath:
      if let selectedUrl {
        return selectedUrl
      }
      return targetedUrl ?? desktopUrl
    case .createFileInContainer:
      return (targetedUrl ?? selectedUrl)?.directoryForFinderAction() ?? desktopUrl
    case .openSelectionContainer:
      return (selectedUrl ?? targetedUrl)?.directoryForFinderAction() ?? desktopUrl
    }
  }

  private func revealCreatedFileIfNeeded(_ fileUrl: URL, in directory: URL) {
    guard !directory.isDesktopDirectory else {
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([fileUrl])
  }

  // MARK: - 本地通知与日志

  private func showError(message: String) {
    showNotification(title: "BetterMenu 访达效率扩展提示", body: message)
  }

  private func showNotification(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default

    let request = UNNotificationRequest(
      identifier: UUID().uuidString,
      content: content,
      trigger: nil
    )

    UNUserNotificationCenter.current().add(request) { [weak self] error in
      if let error = error {
        self?.logger.error("Failed to post notification: \(error.localizedDescription, privacy: .public)")
      }
    }
  }
}

// FinderSync 由系统按扩展生命周期管理；由于涉及跨队列访问，此处符合 Unchecked 传值特征
extension FinderSync: @unchecked Sendable {}

// MARK: - 路径判断扩展

private enum FinderLocationIntent {
  case createFileInContainer
  case copyCurrentPath
  case openSelectionContainer
}

extension URL {
  fileprivate var isDesktopDirectory: Bool {
    let realDesktopPath = "/Users/\(NSUserName())/Desktop"
    return path == realDesktopPath
  }

  /// 如果 URL 指向文件，则返回其父目录；如果指向目录或路径不存在，则保留原 URL。
  fileprivate func directoryForFinderAction(fileManager: FileManager = .default) -> URL {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
      return self
    }
    return isDirectory.boolValue ? self : deletingLastPathComponent()
  }
}

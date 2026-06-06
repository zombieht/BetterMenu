import Cocoa
import FinderSync
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import os

// MARK: - 数据模型定义

/// 菜单预览中每一项的数据表示
struct MenuPreviewItem: Identifiable, Hashable {
  let id: String
  let title: String
}

/// 菜单显示模式的枚举
enum BetterMenuDisplayMode: String, CaseIterable, Identifiable {
  case menuBarOnly
  case hiddenBoth
  case dockOnly
  case menuBarAndDock

  var id: String { rawValue }

  var title: String {
    switch self {
    case .menuBarOnly: return "仅在菜单栏显示"
    case .hiddenBoth: return "隐藏菜单栏和 Dock"
    case .dockOnly: return "仅在 Dock 栏显示"
    case .menuBarAndDock: return "菜单栏和 Dock 同时显示"
    }
  }

  var activationPolicy: NSApplication.ActivationPolicy {
    switch self {
    case .menuBarOnly, .hiddenBoth: return .accessory
    case .dockOnly, .menuBarAndDock: return .regular
    }
  }

}

// MARK: - 图标管理器

/// 用于为主应用界面提供合适尺寸的 PNG 或 SF Symbol 图标
enum BetterMenuIcon {
  @MainActor
  static func icon(for id: String, size: NSSize) -> NSImage? {
    let pathExtension = cleanExtension(for: id)

    // 使用 macOS 15+ 推荐的 UTType 现代化获取图标方法
    let type = UTType(filenameExtension: pathExtension) ?? .item
    let image = NSWorkspace.shared.icon(for: type)
    image.size = size
    image.isTemplate = false
    return image
  }
}

// MARK: - 内置常量

/// 内置的文件类型列表
let betterMenuFileTypes: [FileDefinition] = BetterMenuShared.supportedFileTypes

// MARK: - ViewModel

/// 应用的设置与业务逻辑 ViewModel，负责数据读写、服务状态监控与进程通信
@MainActor
final class BetterMenuSettingsModel: ObservableObject {
  private let logger = Logger(
    subsystem: "com.zombie.BetterMenu", category: "BetterMenuSettingsModel")

  /// 设置页弹窗的统一描述，避免业务流程直接拼装 NSAlert。
  struct UserFacingAlert {
    let title: String
    let message: String
    let style: NSAlert.Style
  }

  /// Finder Sync 扩展在设置页展示的权限状态。
  struct ExtensionStatus {
    enum State {
      case enabled
      case needsManualEnable
    }

    let state: State

    init(isConfirmed: Bool) {
      state = isConfirmed ? .enabled : .needsManualEnable
    }

    var isConfirmed: Bool {
      state == .enabled
    }

    var badgeTitle: String {
      switch state {
      case .enabled:
        return "扩展已启用"
      case .needsManualEnable:
        return "待启用"
      }
    }

    var description: String {
      switch state {
      case .enabled:
        return "扩展已启用，可正常使用 Finder 右键菜单。"
      case .needsManualEnable:
        return "请在“系统设置 > 登录项与扩展”中启用 BetterMenu 扩展。"
      }
    }

    var tint: Color {
      switch state {
      case .enabled:
        return .green
      case .needsManualEnable:
        return .red
      }
    }

    var backgroundTint: Color {
      tint.opacity(0.12)
    }
  }

  // MARK: - 发布属性

  @Published var launchAtLogin: Bool {
    didSet {
      guard !isSynchronizingLaunchAtLogin else { return }
      updateLaunchAtLoginPreference(to: launchAtLogin)
    }
  }

  @Published private(set) var displayMode: BetterMenuDisplayMode {
    didSet {
      UserDefaults.standard.set(displayMode.rawValue, forKey: Self.displayModeKey)
      onDisplayModeDidChange?(displayMode)
    }
  }

  @Published private(set) var extensionStatus = ExtensionStatus(isConfirmed: false)
  @Published private(set) var isRestartingFinder = false

  @Published var enabledFileTypes: Set<String> {
    didSet {
      persistEnabledFileTypes()
    }
  }

  @Published var customExtensions: [String] {
    didSet {
      persistCustomExtensions()
    }
  }

  @Published var actions: [FinderAction] {
    didSet {
      scheduleWriteSharedSettings()
    }
  }

  @Published var terminalType: String {
    didSet {
      UserDefaults.standard.set(terminalType, forKey: Self.terminalTypeKey)
      scheduleWriteSharedSettings()
    }
  }

  @Published private var menuOrder: [String] {
    didSet {
      UserDefaults.standard.set(menuOrder, forKey: Self.menuOrderKey)
      scheduleWriteSharedSettings()
    }
  }

  let appVersion: String
  var onDisplayModeDidChange: ((BetterMenuDisplayMode) -> Void)?
  nonisolated(unsafe) private var notificationObservers: [NSObjectProtocol] = []
  private var isSynchronizingLaunchAtLogin = false
  private var writeDebounceWorkItem: DispatchWorkItem?

  // MARK: - 存储 Keys

  private static let displayModeKey = "displayMode"
  private static let terminalTypeKey = BetterMenuShared.terminalTypeKey
  private static let enabledFileTypesKey = BetterMenuShared.enabledFileTypesKey
  private static let customExtensionsKey = BetterMenuShared.customExtensionsKey
  private static let menuOrderKey = BetterMenuShared.menuOrderKey

  // 向后兼容保留老版本的键
  private static let oldTerminalDirectEnabledKey = BetterMenuShared.oldTerminalDirectEnabledKey
  private static let oldPathCopyEnabledKey = BetterMenuShared.oldPathCopyEnabledKey
  private static let didMigrateTerminalBundleIdsKey = "didMigrateTerminalBundleIds"

  // MARK: - 初始化

  init() {
    let defaultTypes = betterMenuFileTypes.filter(\.enabledByDefault).map(\.id)
    UserDefaults.standard.register(defaults: [
      Self.displayModeKey: BetterMenuDisplayMode.menuBarOnly.rawValue,
      Self.enabledFileTypesKey: defaultTypes,
      Self.customExtensionsKey: [],
      Self.menuOrderKey: defaultTypes,
      Self.terminalTypeKey: "com.apple.Terminal",
      Self.oldTerminalDirectEnabledKey: true,
      Self.oldPathCopyEnabledKey: true,
    ])

    let sharedSettings = readSharedSettings()

    launchAtLogin = SMAppService.mainApp.status == .enabled
    displayMode =
      BetterMenuDisplayMode(
        rawValue: UserDefaults.standard.string(forKey: Self.displayModeKey)
          ?? BetterMenuDisplayMode.menuBarOnly.rawValue
      ) ?? .menuBarOnly

    if let storedActions = sharedSettings.actions {
      self.actions = storedActions
    } else {
      // 兼容以前的硬编码布尔值
      var acts = defaultSharedActions
      let oldTerminalEnabled =
        sharedSettings.oldTerminalDirectEnabled
        ?? (UserDefaults.standard.object(forKey: Self.oldTerminalDirectEnabledKey) as? Bool ?? true)
      let oldPathEnabled =
        sharedSettings.oldPathCopyEnabled
        ?? (UserDefaults.standard.object(forKey: Self.oldPathCopyEnabledKey) as? Bool ?? true)

      if let idx = acts.firstIndex(where: { $0.id == "terminal" }) {
        acts[idx].isEnabled = oldTerminalEnabled
      }
      if let idx = acts.firstIndex(where: { $0.id == "copyPath" }) {
        acts[idx].isEnabled = oldPathEnabled
      }
      // vscode 默认启用
      self.actions = acts
    }

    let storedTerminalType =
      sharedSettings.terminalType ?? UserDefaults.standard.string(forKey: Self.terminalTypeKey)
      ?? "com.apple.Terminal"
    terminalType = Self.migrateTerminalTypeIfNeeded(storedTerminalType)

    let storedCustomExtensions =
      sharedSettings.customExtensions ?? UserDefaults.standard.stringArray(
        forKey: Self.customExtensionsKey) ?? []
    enabledFileTypes = Set(
      sharedSettings.enabledFileTypes ?? UserDefaults.standard.stringArray(
        forKey: Self.enabledFileTypesKey) ?? defaultTypes)
    customExtensions = storedCustomExtensions

    let finalDefaultOrder = defaultTypes + storedCustomExtensions.map { Self.customMenuId(for: $0) }
    menuOrder = Self.normalizedMenuOrder(
      sharedSettings.menuOrder ?? UserDefaults.standard.stringArray(forKey: Self.menuOrderKey)
        ?? finalDefaultOrder,
      customExtensions: storedCustomExtensions
    )

    appVersion =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    reconcileMenuOrder()
    writeSharedSettings()
    refreshExtensionStatus()
    observeAppActivation()
  }

  deinit {
    for observer in notificationObservers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  // MARK: - 终端支持列表

  var installedTerminals: [TerminalApp] {
    TerminalApp.knownTerminals.filter { terminal in
      if terminal.bundleId == "com.apple.Terminal" {
        return true
      }
      return NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleId) != nil
    }
  }

  // MARK: - 菜单预览

  var menuPreviewItems: [MenuPreviewItem] {
    menuOrder.compactMap { id in
      guard enabledFileTypes.contains(id) || id.hasPrefix(Self.customMenuIdPrefix) else {
        return nil
      }
      return menuItem(for: id)
    }
  }

  // MARK: - 业务操作方法

  func setFileType(_ id: String, enabled: Bool) {
    if enabled {
      enabledFileTypes.insert(id)
    } else {
      enabledFileTypes.remove(id)
    }
    reconcileMenuOrder()
  }

  /// 一次性启用全部内置新建文件类型，避免用户逐个勾选造成重复操作。
  func enableAllFileTypes() {
    enabledFileTypes = Set(betterMenuFileTypes.map(\.id))
    reconcileMenuOrder()
  }

  /// 一次性关闭全部内置新建文件类型，自定义后缀仍保留在配置中便于后续恢复。
  func disableAllFileTypes() {
    enabledFileTypes.removeAll()
    reconcileMenuOrder()
  }

  /// 恢复内置文件类型的默认启用状态，常用于用户试错后快速回到推荐配置。
  func restoreDefaultFileTypes() {
    enabledFileTypes = Set(betterMenuFileTypes.filter(\.enabledByDefault).map(\.id))
    reconcileMenuOrder()
  }

  func addCustomExtension(_ value: String) -> Bool {
    let normalized = normalizeExtension(value)
    if let rejection = customExtensionRejectionReason(for: normalized) {
      showAlert(title: rejection.title, message: rejection.message)
      return false
    }

    customExtensions.append(normalized)
    return true
  }

  func removeCustomExtension(_ value: String) {
    customExtensions.removeAll { $0 == value }
  }

  /// 在设置界面的菜单预览列表中进行拖拽排序时，更新完整的菜单排布顺序
  /// - Parameters:
  ///   - source: 被移动的预览项源索引集合
  ///   - destination: 目标插入位置索引
  func moveMenuPreviewItem(from source: IndexSet, to destination: Int) {
    // 1. 获取当前可见（已启用）的预览项 ID 列表
    var currentPreviewIds = menuPreviewItems.map(\.id)

    // 2. 在可见项列表中执行移动操作
    currentPreviewIds.move(fromOffsets: source, toOffset: destination)

    // 3. 将移动后的新顺序应用到完整的菜单顺序中
    // 保持未启用的项在后面，已启用的项排在前面并应用新顺序
    let visibleIDSet = Set(currentPreviewIds)
    let hiddenOrderedIDs = menuOrder.filter { !visibleIDSet.contains($0) }

    // 4. 重构并保存排序
    menuOrder = Self.normalizedMenuOrder(
      currentPreviewIds + hiddenOrderedIDs, customExtensions: customExtensions)
  }

  /// 调整 Finder 一级菜单中快捷操作的显示顺序。
  /// - Parameters:
  ///   - source: 被移动的快捷操作源索引集合
  ///   - destination: 目标插入位置索引
  func moveAction(from source: IndexSet, to destination: Int) {
    actions.move(fromOffsets: source, toOffset: destination)
  }

  func openExtensionSettings() {
    refreshExtensionStatus()

    guard
      let preferencesUrl = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")
    else {
      showAlert(title: "无法打开系统设置", message: "未能生成扩展设置页面链接。")
      return
    }

    NSWorkspace.shared.open(preferencesUrl)
  }

  func refreshExtensionStatus() {
    let isEnabled = FIFinderSyncController.isExtensionEnabled
    extensionStatus = ExtensionStatus(isConfirmed: isEnabled)
  }

  func requestDisplayModeChange(_ newMode: BetterMenuDisplayMode) {
    guard newMode != displayMode else { return }
    guard alertForDisplayModeChange(newMode) else { return }

    displayMode = newMode
  }

  func restartFinder() {
    guard !isRestartingFinder else { return }
    isRestartingFinder = true

    Task {
      let alert = await makeFinderRestartAlert()
      isRestartingFinder = false
      showAlert(alert)
    }
  }

  func showTerminalAppNotInstalled(appName: String) {
    showAlert(
      title: "未检测到应用",
      message: "系统未检测到已配置的 \(appName)，请检查是否已正常安装该应用。"
    )
  }

  // MARK: - 外部应用调用

  /// 在选定终端中打开目录
  func openTerminal(atPath path: String) {
    makeExternalAppLauncher().openTerminal(atPath: path)
  }

  /// 在 VS Code 中打开目标目录
  func openInVSCode(atPath path: String) {
    makeExternalAppLauncher().openInVSCode(atPath: path)
  }

  /// 获取系统中尚未添加到 actions 中的编辑器列表
  var availableEditorsToImport: [BetterMenuShared.EditorAppInfo] {
    BetterMenuShared.supportedEditors.filter { editor in
      return !actions.contains { $0.id == editor.idString }
    }
  }

  /// 当前系统已安装、且尚未添加到 Finder 右键操作中的推荐编辑器。
  var installedEditorsToImport: [BetterMenuShared.EditorAppInfo] {
    availableEditorsToImport.filter { editor in
      isActionInstalled(editor.idString)
    }
  }

  /// 尚未检测到安装，但可以先加入菜单配置中的推荐编辑器。
  var uninstalledEditorsToImport: [BetterMenuShared.EditorAppInfo] {
    availableEditorsToImport.filter { editor in
      !isActionInstalled(editor.idString)
    }
  }

  /// 检查某一个 action 是否在系统中已安装
  func isActionInstalled(_ actionId: String) -> Bool {
    if actionId == "terminal" || actionId == "copyPath" {
      return true
    }
    if let editor = BetterMenuShared.supportedEditors.first(where: { $0.idString == actionId }) {
      return editor.bundleIds.contains { bid in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) != nil
      }
    }
    // 对于自定义的 actionId（即 bundleId），直接查询系统
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: actionId) != nil
  }

  /// 添加一个编辑器的 FinderAction
  func addEditorAction(_ editor: BetterMenuShared.EditorAppInfo) {
    guard !actions.contains(where: { $0.id == editor.idString }) else { return }
    let newAction = FinderAction(
      id: editor.idString,
      title: editor.title,
      iconName: editor.iconName,
      isEnabled: true
    )
    actions.append(newAction)
  }

  /// 移除一个编辑器的 FinderAction
  func removeEditorAction(id: String) {
    actions.removeAll { $0.id == id }
  }

  /// 在外部编辑器中打开目录
  func openInEditor(actionId: String, atPath path: String) {
    if let editor = BetterMenuShared.supportedEditors.first(where: { $0.idString == actionId }) {
      makeExternalAppLauncher().openInApplication(
        atPath: path,
        bundleIdentifiers: editor.bundleIds,
        appName: editor.name,
        cliRelativePath: editor.cliRelativePath,
        cliArgs: editor.cliArgs,
        forceDirectoryOpen: editor.forceDirectoryOpen
      )
    } else {
      // 检查 actionId 是否是已安装应用程序的 Bundle ID
      if let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: actionId) {
        // 动态读取应用程序名称
        var appName = "外部应用程序"
        if let bundle = Bundle(url: appUrl) {
          appName =
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? appUrl.deletingPathExtension().lastPathComponent
        }
        makeExternalAppLauncher().openInApplication(
          atPath: path, bundleIdentifiers: [actionId], appName: appName)
      } else {
        logger.error("Unknown editor action ID: \(actionId)")
      }
    }
  }

  private func makeExternalAppLauncher() -> ExternalAppLauncher {
    ExternalAppLauncher(
      terminalType: terminalType,
      missingApplicationHandler: { [weak self] appName in
        self?.showTerminalAppNotInstalled(appName: appName)
      }
    )
  }

  /// 导入用户从文件选择器选择的自定义应用程序
  func addCustomApplicationAction(fromUrl url: URL) -> Bool {
    guard let bundle = Bundle(url: url),
      let bundleId = bundle.bundleIdentifier
    else {
      showAlert(title: "无效的应用程序", message: "无法读取选中的应用程序信息。")
      return false
    }

    let name =
      bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
      ?? url.deletingPathExtension().lastPathComponent

    guard !actions.contains(where: { $0.id == bundleId }) else {
      showAlert(title: "程序已添加", message: "\(name) 已经存在于列表中。")
      return false
    }

    let newAction = FinderAction(
      id: bundleId,
      title: "在 \(name) 中打开",
      iconName: "square.and.arrow.up",
      isEnabled: true
    )
    actions.append(newAction)
    return true
  }

  // MARK: - 内部私有处理方法

  private func persistEnabledFileTypes() {
    UserDefaults.standard.set(Array(enabledFileTypes), forKey: Self.enabledFileTypesKey)
    scheduleWriteSharedSettings()
  }

  private func persistCustomExtensions() {
    UserDefaults.standard.set(customExtensions, forKey: Self.customExtensionsKey)
    reconcileMenuOrder()
    scheduleWriteSharedSettings()
  }

  private func updateLaunchAtLoginPreference(to enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      synchronizeLaunchAtLoginFromSystem()
      showAlert(title: "开机自启动设置失败", message: error.localizedDescription)
    }
  }

  /// 从系统服务状态回填开机启动开关，避免注册失败后 UI 与系统状态不一致。
  private func synchronizeLaunchAtLoginFromSystem() {
    isSynchronizingLaunchAtLogin = true
    launchAtLogin = SMAppService.mainApp.status == .enabled
    isSynchronizingLaunchAtLogin = false
  }

  private func observeAppActivation() {
    let notificationCenter = NotificationCenter.default
    let observer = notificationCenter.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: NSApp,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.refreshExtensionStatus()
      }
    }
    notificationObservers.append(observer)
  }

  /// 重新加载 Finder 进程，并将每一步的执行结果转换成设置页可直接展示的弹窗文案。
  private func makeFinderRestartAlert() async -> UserFacingAlert {
    let finderBundleId = "com.apple.finder"
    let shouldWaitForRelaunch = isRunningApplication(bundleIdentifier: finderBundleId)

    let killallResult = await SystemCommand.run(path: "/usr/bin/killall", arguments: ["Finder"])
    guard killallResult.succeeded else {
      return UserFacingAlert(
        title: "重启 Finder 失败",
        message: killallResult.userMessage
          ?? "Finder 进程结束命令返回了退出码 \(killallResult.exitCode)。",
        style: .warning
      )
    }

    if shouldWaitForRelaunch {
      try? await Task.sleep(for: .milliseconds(250))
    }

    guard await waitUntilApplicationRuns(bundleIdentifier: finderBundleId) else {
      return UserFacingAlert(
        title: "重启 Finder 失败",
        message: "Finder 已退出，但未能自动重新启动，请手动打开访达后重试。",
        style: .warning
      )
    }

    return UserFacingAlert(
      title: "重启 Finder 成功",
      message: "访达已经重新启动，扩展刷新应已生效。",
      style: .informational
    )
  }

  /// 按固定短间隔轮询应用运行状态，用于等待 Finder 被系统自动拉起。
  private func waitUntilApplicationRuns(bundleIdentifier: String) async -> Bool {
    let maximumChecks = 40
    for _ in 0..<maximumChecks {
      if isRunningApplication(bundleIdentifier: bundleIdentifier) {
        return true
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  private func isRunningApplication(bundleIdentifier: String) -> Bool {
    let runningApplications = NSRunningApplication.runningApplications(
      withBundleIdentifier: bundleIdentifier)
    return !runningApplications.isEmpty
  }

  private func alertForDisplayModeChange(_ newMode: BetterMenuDisplayMode) -> Bool {
    guard newMode == .hiddenBoth else { return true }

    let alert = NSAlert()
    alert.messageText = "确认隐藏菜单栏与 Dock"
    alert.informativeText = "切换后 BetterMenu 将不在菜单栏和 Dock 中显示，只会在后台运行。你仍可通过再次启动应用重新打开设置界面。"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "继续切换")
    alert.addButton(withTitle: "取消")

    return alert.runModal() == .alertFirstButtonReturn
  }

  private func normalizeExtension(_ value: String) -> String {
    var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    while normalized.hasPrefix(".") {
      normalized.removeFirst()
    }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-+")
    normalized = String(normalized.unicodeScalars.filter { allowed.contains($0) })
    return String(normalized.prefix(24))
  }

  private func customExtensionRejectionReason(for normalized: String) -> UserFacingAlert? {
    if normalized.isEmpty {
      return UserFacingAlert(
        title: "无法添加后缀",
        message: "请输入文件后缀，例如 yaml 或 .log。",
        style: .informational
      )
    }

    if betterMenuFileTypes.contains(where: { $0.pathExtension == normalized }) {
      return UserFacingAlert(
        title: "后缀已存在",
        message: ".\(normalized) 已在内置文件类型中。",
        style: .informational
      )
    }

    if customExtensions.contains(normalized) {
      return UserFacingAlert(
        title: "后缀已存在",
        message: ".\(normalized) 已经添加。",
        style: .informational
      )
    }

    return nil
  }

  /// 节流写入共享设置，合并 300ms 内的多次调用为一次实际磁盘写入，
  /// 避免批量操作时的重复 I/O 和图标预热。
  private func scheduleWriteSharedSettings() {
    writeDebounceWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.writeSharedSettings()
    }
    writeDebounceWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
  }

  private func writeSharedSettings() {
    // 构建包含 actions 数据结构的配置 payload
    let actionsPayload = actions.map {
      [
        "id": $0.id,
        "title": $0.title,
        "iconName": $0.iconName,
        "isEnabled": $0.isEnabled,
      ]
    }

    let payload: [String: Any] = [
      Self.enabledFileTypesKey: Array(enabledFileTypes),
      Self.customExtensionsKey: customExtensions,
      Self.menuOrderKey: menuOrder,
      Self.terminalTypeKey: terminalType,
      "actions": actionsPayload,
    ]

    do {
      let directory = BetterMenuShared.sharedSettingsUrl.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let data = try PropertyListSerialization.data(
        fromPropertyList: payload, format: .xml, options: 0)
      try data.write(to: BetterMenuShared.sharedSettingsUrl, options: .atomic)
      // 异步预热图标缓存
      prewarmIconCache()
    } catch {
      NSLog("BetterMenu shared settings write failed: \(error.localizedDescription)")
    }
  }

  /// 异步预热并缓存文件类型图标与已启用操作的 App 图标到磁盘
  private func prewarmIconCache() {
    IconCacheManager.prewarm(
      fileTypes: betterMenuFileTypes,
      customExtensions: customExtensions,
      activeActions: actions.filter(\.isEnabled)
    )
  }

  private static let customMenuIdPrefix = "custom."

  private static var defaultMenuOrder: [String] {
    betterMenuFileTypes.map(\.id)
  }

  private static func customMenuId(for fileExtension: String) -> String {
    "\(customMenuIdPrefix)\(fileExtension)"
  }

  private static func normalizedMenuOrder(_ order: [String], customExtensions: [String]) -> [String]
  {
    let allIDs = defaultMenuOrder + customExtensions.map(customMenuId(for:))
    let allowedIDs = Set(allIDs)
    let orderedKnownIDs = uniqueMenuIds(from: order.filter { allowedIDs.contains($0) })
    let missingIDs = allIDs.filter { !orderedKnownIDs.contains($0) }
    return orderedKnownIDs + missingIDs
  }

  private static func uniqueMenuIds(from ids: [String]) -> [String] {
    var acceptedIDs: [String] = []
    var acceptedSet: Set<String> = []
    for id in ids where !acceptedSet.contains(id) {
      acceptedIDs.append(id)
      acceptedSet.insert(id)
    }
    return acceptedIDs
  }

  private func reconcileMenuOrder() {
    let normalized = Self.normalizedMenuOrder(menuOrder, customExtensions: customExtensions)
    if normalized != menuOrder {
      menuOrder = normalized
    }
  }

  private func menuItem(for id: String) -> MenuPreviewItem? {
    if let builtIn = betterMenuFileTypes.first(where: { $0.id == id }) {
      return MenuPreviewItem(id: id, title: builtIn.menuTitle)
    }

    guard id.hasPrefix(Self.customMenuIdPrefix) else { return nil }
    let fileExtension = String(id.dropFirst(Self.customMenuIdPrefix.count))
    guard customExtensions.contains(fileExtension) else { return nil }
    return MenuPreviewItem(id: id, title: "新建 \(fileExtension.uppercased()) 文件")
  }

  private func showAlert(_ content: UserFacingAlert) {
    let alert = NSAlert()
    alert.messageText = content.title
    alert.informativeText = content.message
    alert.alertStyle = content.style
    alert.runModal()
  }

  private func showAlert(title: String, message: String) {
    showAlert(UserFacingAlert(title: title, message: message, style: .informational))
  }

  // MARK: - 一次性数据迁移

  /// 旧版本使用短名称（如 "terminal"、"iterm2"）保存终端偏好，
  /// 新版本统一使用 Bundle Identifier。此方法在首次启动时将旧值映射为新值，
  /// 并写入迁移标记避免后续重复执行。
  private static func migrateTerminalTypeIfNeeded(_ stored: String) -> String {
    guard !UserDefaults.standard.bool(forKey: didMigrateTerminalBundleIdsKey) else {
      return stored
    }

    let legacyMapping: [String: String] = [
      "terminal": "com.apple.Terminal",
      "iterm2": "com.googlecode.iterm2",
      "ghostty": "com.mitchellh.ghostty",
      "cmux": "com.cmuxterm.app",
      "cmux-nightly": "com.cmuxterm.app.nightly",
    ]

    let migrated = legacyMapping[stored] ?? stored
    UserDefaults.standard.set(true, forKey: didMigrateTerminalBundleIdsKey)
    return migrated
  }
}



import Cocoa
import SwiftUI
import os
import Sparkle

/// 状态栏菜单的 SwiftUI 视图定义
struct BetterMenuBarView: View {
  @ObservedObject var settingsModel: BetterMenuSettingsModel

  var body: some View {
    Button("打开设置") {
      AppDelegate.shared?.showMainWindow()
    }

    Divider()

    Menu("显示方式") {
      ForEach(BetterMenuDisplayMode.allCases) { mode in
        Button {
          settingsModel.requestDisplayModeChange(mode)
        } label: {
          HStack {
            Text(mode.title)
            if settingsModel.displayMode == mode {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    }

    Button {
      settingsModel.launchAtLogin.toggle()
    } label: {
      HStack {
        Text("开机自启动")
        if settingsModel.launchAtLogin {
          Image(systemName: "checkmark")
        }
      }
    }

    Divider()

    Button("重启访达") {
      settingsModel.restartFinder()
    }

    Button("打开扩展设置") {
      settingsModel.openExtensionSettings()
    }

    Divider()

    Button("退出 BetterMenu") {
      NSApp.terminate(nil)
    }
  }
}

/// SwiftUI App 生命周期的接管入口
struct BetterMenuApp: App {
  // 适配现有的 AppKit 应用程序代理类，确保接收生命周期及系统事件
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    // 使用辅助 Scene 传递并观察 SettingsModel，确保在显示模式切换时动态刷新 MenuBarExtra 状态
    BetterMenuBarExtraScene(settingsModel: appDelegate.settingsModel)

    // 仅用于维持生命周期的占位设置场景
    Settings {
      EmptyView()
    }
  }
}

/// 辅助 Scene 用于监听 settingsModel 的发布属性变更，解决 MenuBarExtra.isInserted 刷新不及时的问题
struct BetterMenuBarExtraScene: Scene {
  @ObservedObject var settingsModel: BetterMenuSettingsModel

  var body: some Scene {
    MenuBarExtra(
      "BetterMenu",
      systemImage: "doc.badge.plus",
      isInserted: Binding(
        get: {
          settingsModel.displayMode == .menuBarOnly
            || settingsModel.displayMode == .menuBarAndDock
        },
        set: { _ in }
      )
    ) {
      BetterMenuBarView(settingsModel: settingsModel)
    }
    .menuBarExtraStyle(.menu)
  }
}

/// 主应用代理类，继承自 NSObject 并遵循 NSApplicationDelegate 和 NSWindowDelegate 协议
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  static private(set) var shared: AppDelegate?

  private let logger = Logger(subsystem: "com.zombie.BetterMenu", category: "AppDelegate")
  let settingsModel = BetterMenuSettingsModel()
  var window: NSWindow?
  private var initialWindowWorkItem: DispatchWorkItem?
  private var shouldSuppressInitialWindow = false
  var updaterController: SPUStandardUpdaterController?

  override init() {
    super.init()
    AppDelegate.shared = self
    // SwiftUI App 生命周期会自动通过 application(_:open:) 分发 URL Scheme 事件，
    // 无需再手动注册 NSAppleEventManager 监听器（否则 URL 会被处理两次）。
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // 初始化 Sparkle 自动更新组件
    updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    settingsModel.onDisplayModeDidChange = { [weak self] mode in
      self?.applyDisplayMode(mode)
    }
    applyDisplayMode(settingsModel.displayMode)
    scheduleInitialWindowPresentation()
  }

  // MARK: - 软件更新

  /// 触发 Sparkle 检查更新
  @objc func checkForUpdates() {
    updaterController?.checkForUpdates(nil)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !flag {
      showMainWindow()
    }
    return true
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    urls.forEach(handleIncomingUrl(_:))
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    // 窗口关闭后，还原为后台模式所对应的激活策略
    applyDisplayMode(settingsModel.displayMode)
    return false
  }

  // MARK: - 窗口管理

  func showMainWindow() {
    cancelInitialWindowPresentation()
    shouldSuppressInitialWindow = false

    if window == nil {
      window = makeMainWindow()
    }

    guard let window = window else { return }

    // 在显示窗口前临时将激活策略提升为 .regular
    // 以确保窗口具有完整的键盘焦点，并支持复制粘贴快捷键
    if NSApp.activationPolicy() != .regular {
      NSApp.setActivationPolicy(.regular)
    }

    if window.isMiniaturized {
      window.deminiaturize(nil)
    }

    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    // 使用 macOS 14.0+ 推荐的 activate() 现代化激活前台焦点方法
    NSApp.activate()
  }

  private func makeMainWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "BetterMenu"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.minSize = NSSize(width: 750, height: 550)
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
    window.contentView = NSHostingView(rootView: BetterMenuSettingsView(model: settingsModel))
    return window
  }

  // MARK: - 激活策略管理

  private func applyDisplayMode(_ mode: BetterMenuDisplayMode) {
    // 如果当前窗口正在显示，为保留其前台焦点和菜单栏，我们暂不将其降级为 .accessory
    if window?.isVisible == true {
      if NSApp.activationPolicy() != .regular {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
      }
      return
    }

    let targetPolicy = mode.activationPolicy
    if NSApp.activationPolicy() != targetPolicy {
      NSApp.setActivationPolicy(targetPolicy)
      if targetPolicy == .regular {
        NSApp.activate(ignoringOtherApps: true)
      }
    }
  }

  // MARK: - URL Scheme 请求路由派发

  private func handleIncomingUrl(_ url: URL) {
    shouldSuppressInitialWindow = true
    cancelInitialWindowPresentation()

    guard url.scheme?.lowercased() == "bettermenu" else {
      logger.error("Ignored unsupported URL scheme: \(url.absoluteString, privacy: .public)")
      return
    }

    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }

    // URLComponents.queryItems 会自动对参数值做百分号解码。
    // 这里不能再次调用 removingPercentEncoding，否则文件名中真实存在的 "%20"
    // 会被误还原为空格，导致外部应用打开错误路径。
    guard let path = components.queryItems?.first(where: { $0.name == "path" })?.value else {
      logger.error("Missing path query parameter in URL: \(url.absoluteString, privacy: .public)")
      return
    }

    // 统一处理 run-action 指令
    if url.host == "run-action" {
      guard let actionId = components.queryItems?.first(where: { $0.name == "id" })?.value else {
        logger.error("Missing action ID in URL: \(url.absoluteString, privacy: .public)")
        return
      }

      logger.info("Routing action '\(actionId)' for path: \(path, privacy: .public)")
      dispatchAction(id: actionId, path: path)
    } else if url.host == "open-terminal" {
      // 兼容可能遗留的老版本直接调用
      logger.info("Routing legacy open-terminal for path: \(path, privacy: .public)")
      settingsModel.openTerminal(atPath: path)
    } else {
      logger.error("Unknown route host: \(url.host ?? "", privacy: .public)")
    }
  }

  /// 分发具体 Action 到对应的业务逻辑执行器中
  private func dispatchAction(id: String, path: String) {
    switch id {
    case "terminal":
      settingsModel.openTerminal(atPath: path)
    case "vscode":
      settingsModel.openInVSCode(atPath: path)
    default:
      // 允许使用硬编码的编辑器标识，或者任意已安装的系统应用程序 Bundle ID
      if BetterMenuShared.supportedEditors.contains(where: { $0.idString == id })
        || NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
      {
        settingsModel.openInEditor(actionId: id, atPath: path)
      } else {
        logger.error("Unsupported action ID: \(id, privacy: .public)")
      }
    }
  }

  private func scheduleInitialWindowPresentation() {
    cancelInitialWindowPresentation()
    let workItem = DispatchWorkItem { [weak self] in
      guard let self = self, !self.shouldSuppressInitialWindow else { return }
      self.showMainWindow()
    }
    initialWindowWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
  }

  private func cancelInitialWindowPresentation() {
    initialWindowWorkItem?.cancel()
    initialWindowWorkItem = nil
  }
}

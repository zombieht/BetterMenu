import Cocoa
import os

/// 负责启动终端、VS Code 等外部应用，避免设置 ViewModel 直接承载系统调用细节。
@MainActor
struct ExternalAppLauncher {
  var terminalType: String
  var missingApplicationHandler: (String) -> Void

  private let logger = Logger(subsystem: "com.zombie.BetterMenu", category: "ExternalAppLauncher")

  /// 在用户配置的终端应用中打开目标目录。
  func openTerminal(atPath path: String) {
    let directoryUrl = URL(fileURLWithPath: path, isDirectory: true)
    guard FileManager.default.fileExists(atPath: directoryUrl.path) else {
      logger.error("Terminal open path does not exist: \(path, privacy: .public)")
      return
    }

    switch terminalType {
    case "com.apple.Terminal":
      fallbackToNativeTerminal(directoryUrl: directoryUrl)

    case "com.googlecode.iterm2":
      openInITerm2(path: path, directoryUrl: directoryUrl)

    default:
      openConfiguredTerminal(directoryUrl: directoryUrl)
    }
  }

  /// 在指定的应用程序中打开目标路径（支持文件和目录）。
  func openInApplication(
    atPath path: String,
    bundleIdentifiers: [String],
    appName: String,
    cliRelativePath: String? = nil,
    cliArgs: [String]? = nil,
    forceDirectoryOpen: Bool = false
  ) {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
      logger.error(
        "\(appName, privacy: .public) open path does not exist: \(path, privacy: .public)")
      return
    }

    // 计算实际要打开的路径和 URL。若指定了强制以目录打开，且当前目标是个文件，则定位到其父目录。
    let resolvedPath: String
    let resolvedIsDirectory: Bool
    if forceDirectoryOpen && !isDirectory.boolValue {
      resolvedPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
      resolvedIsDirectory = true
    } else {
      resolvedPath = path
      resolvedIsDirectory = isDirectory.boolValue
    }

    let targetUrl = URL(fileURLWithPath: resolvedPath, isDirectory: resolvedIsDirectory)

    var appUrl: URL? = nil
    var usedBundleId: String? = nil
    for bid in bundleIdentifiers {
      if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
        appUrl = url
        usedBundleId = bid
        break
      }
    }

    if let appUrl = appUrl, let bundleId = usedBundleId {
      // 如果指定了 CLI 并且 CLI 文件确实存在，则优先使用 CLI 工具启动
      if let cliRelPath = cliRelativePath {
        let cliUrl = appUrl.appendingPathComponent(cliRelPath)
        if FileManager.default.fileExists(atPath: cliUrl.path) {
          let args = cliArgs ?? []
          if openUsingCli(cliUrl: cliUrl, args: args, targetPath: resolvedPath) {
            return
          }
        }
      }

      // 如果未配置 CLI 或 CLI 执行失败，退回到 NSWorkspace 原生方式
      openDirectoryUsingWorkspace(targetUrl, bundleIdentifier: bundleId)
    } else {
      logger.warning("\(appName, privacy: .public) is not installed on this machine")
      missingApplicationHandler(appName)
    }
  }

  /// 使用命令行工具直接启动并打开目标路径。
  private func openUsingCli(cliUrl: URL, args: [String], targetPath: String) -> Bool {
    let process = Process()
    process.executableURL = cliUrl
    process.arguments = args + [targetPath]

    do {
      try process.run()
      return true
    } catch {
      logger.error("Failed to launch application via CLI at \(cliUrl.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
      return false
    }
  }

  /// 在 VS Code 中打开目标目录。
  func openInVSCode(atPath path: String) {
    openInApplication(
      atPath: path, bundleIdentifiers: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"],
      appName: "VS Code")
  }

  private func openInITerm2(path: String, directoryUrl: URL) {
    let iTermBundleId = "com.googlecode.iterm2"
    guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: iTermBundleId) != nil else {
      logger.warning("iTerm2 is not installed, fallback to Terminal.app")
      missingApplicationHandler("iTerm2")
      fallbackToNativeTerminal(directoryUrl: directoryUrl)
      return
    }

    let scriptText = """
      tell application "iTerm"
          activate
          if (count of windows) is 0 then
              set newWindow to (create window with default profile)
              tell current session of newWindow
                  write text "cd " & quoted form of "\(path)"
              end tell
          else
              tell current window
                  create tab with default profile
                  tell current session
                      write text "cd " & quoted form of "\(path)"
                  end tell
              end tell
          end if
      end tell
      """
    let success = runAppleScript(scriptText)
    if !success {
      logger.warning("iTerm2 AppleScript failed, fallback to workspace open")
      openDirectoryUsingWorkspace(directoryUrl, bundleIdentifier: iTermBundleId)
    }
  }

  private func openConfiguredTerminal(directoryUrl: URL) {
    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalType) != nil {
      openDirectoryUsingWorkspace(directoryUrl, bundleIdentifier: terminalType)
      return
    }

    let appName = TerminalApp.knownTerminals.first(where: { $0.id == terminalType })?.name ?? "所选终端"
    logger.warning("\(appName) is not installed, fallback to Terminal.app")
    missingApplicationHandler(appName)
    fallbackToNativeTerminal(directoryUrl: directoryUrl)
  }

  private func fallbackToNativeTerminal(directoryUrl: URL) {
    let isRunning =
      NSRunningApplication
      .runningApplications(withBundleIdentifier: "com.apple.Terminal")
      .first != nil

    if isRunning {
      // Terminal 已运行时使用 AppleScript 在当前窗口新建 tab，体验更佳
      let success = runTerminalNewTabScript(path: directoryUrl.path)
      if !success {
        logger.warning("Terminal AppleScript failed, fallback to open command")
        openTerminalViaOpenCommand(directoryUrl: directoryUrl)
      }
    } else {
      // Terminal 未运行时，直接使用 `open -a Terminal /path` 命令启动。
      // 不走 AppleScript 是因为 `tell application "Terminal"` 会隐式启动 Terminal
      // 并创建默认窗口，随后 `do script` 又可能创建第二个窗口，时序不稳定导致偶发两个终端。
      // `open -a Terminal /path` 始终只创建一个窗口，行为确定可靠。
      openTerminalViaOpenCommand(directoryUrl: directoryUrl)
    }
  }

  /// Terminal 已运行时，通过 AppleScript 在前台窗口新建 tab 并 cd 到目标路径。
  private func runTerminalNewTabScript(path: String) -> Bool {
    let scriptText = """
      tell application "Terminal"
          if (count of windows) > 0 then
              tell front window
                  set newTab to do script "cd " & quoted form of "\(path)"
              end tell
          else
              do script "cd " & quoted form of "\(path)"
          end if
          activate
      end tell
      """
    return runAppleScript(scriptText)
  }

  /// 使用 `open -a Terminal /path` 命令打开终端，始终只创建一个窗口。
  private func openTerminalViaOpenCommand(directoryUrl: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", "Terminal", directoryUrl.path]
    do {
      try process.run()
    } catch {
      logger.error("open command failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  @discardableResult
  private func runAppleScript(_ scriptText: String) -> Bool {
    guard let script = NSAppleScript(source: scriptText) else {
      logger.error("Failed to create NSAppleScript instance")
      return false
    }

    var error: NSDictionary?
    script.executeAndReturnError(&error)
    if let error = error {
      logger.error("AppleScript execution failed: \(error.description, privacy: .public)")
      return false
    }
    return true
  }

  private func openDirectoryUsingWorkspace(_ directoryUrl: URL, bundleIdentifier: String) {
    guard let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    else {
      return
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.promptsUserIfNeeded = true

    // 完成回调在后台队列 (com.apple.launchservices.open-queue) 执行，
    // 不能直接访问 @MainActor 隔离成员，需用 @Sendable 标记并手动派发回主线程。
    nonisolated(unsafe) let log = logger
    NSWorkspace.shared.open([directoryUrl], withApplicationAt: appUrl, configuration: configuration)
    { @Sendable runningApplication, error in
      if let error = error {
        let message = error.localizedDescription
        log.error(
          "Workspace open failed for \(bundleIdentifier): \(message, privacy: .public)"
        )
        return
      }
      DispatchQueue.main.async {
        runningApplication?.activate()
      }
    }
  }
}

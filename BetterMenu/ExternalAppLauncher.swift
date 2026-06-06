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
  func openInApplication(atPath path: String, bundleIdentifiers: [String], appName: String) {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
      logger.error(
        "\(appName, privacy: .public) open path does not exist: \(path, privacy: .public)")
      return
    }

    let targetUrl = URL(fileURLWithPath: path, isDirectory: isDirectory.boolValue)

    var appUrl: URL? = nil
    var usedBundleId: String? = nil
    for bid in bundleIdentifiers {
      if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
        appUrl = url
        usedBundleId = bid
        break
      }
    }

    if appUrl != nil, let bundleId = usedBundleId {
      openDirectoryUsingWorkspace(targetUrl, bundleIdentifier: bundleId)
    } else {
      logger.warning("\(appName, privacy: .public) is not installed on this machine")
      missingApplicationHandler(appName)
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
    let success = runTerminalAppleScript(path: directoryUrl.path)
    if !success {
      logger.warning("Terminal AppleScript failed, fallback to open command")
      // NSWorkspace.open([directoryUrl], withApplicationAt:) 在 Terminal 未运行时
      // 会创建两个窗口（启动默认窗口 + 打开目录窗口）。
      // 使用 `open -a Terminal /path` 命令则始终只创建一个窗口。
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      process.arguments = ["-a", "Terminal", directoryUrl.path]
      do {
        try process.run()
      } catch {
        logger.error("open command failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  private func runTerminalAppleScript(path: String) -> Bool {
    // Terminal 已运行时新开 tab；未运行时复用启动后自动创建的默认窗口。
    let isRunning =
      NSRunningApplication
      .runningApplications(withBundleIdentifier: "com.apple.Terminal")
      .first != nil

    let scriptText: String
    if isRunning {
      scriptText = """
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
    } else {
      // Terminal 未运行时，直接用 do script（不带 in 参数），
      // 它会隐式启动 Terminal 并创建唯一的窗口来执行命令。
      // 不能先 activate，否则 Terminal 会先创建默认窗口，
      // do script 再创建一个窗口，导致出现两个终端。
      scriptText = """
        tell application "Terminal"
            do script "cd " & quoted form of "\(path)"
            activate
        end tell
        """
    }
    return runAppleScript(scriptText)
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

    NSWorkspace.shared.open([directoryUrl], withApplicationAt: appUrl, configuration: configuration)
    {
      runningApplication,
      error in
      if let error = error {
        let message = error.localizedDescription
        logger.error(
          "Workspace open failed for \(bundleIdentifier): \(message, privacy: .public)"
        )
        return
      }
      runningApplication?.activate(options: [.activateAllWindows])
    }
  }
}

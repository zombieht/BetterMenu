/// 表示支持的第三方或系统终端应用。
struct TerminalApp: Identifiable, Hashable {
  let id: String
  let name: String
  let bundleId: String

  /// 预定义终端列表。`id` 与 `bundleId` 保持一致，便于直接写入用户偏好。
  static let knownTerminals: [TerminalApp] = [
    TerminalApp(id: "com.apple.Terminal", name: "终端 (Terminal)", bundleId: "com.apple.Terminal"),
    TerminalApp(id: "com.googlecode.iterm2", name: "iTerm2", bundleId: "com.googlecode.iterm2"),
    TerminalApp(id: "com.mitchellh.ghostty", name: "Ghostty", bundleId: "com.mitchellh.ghostty"),
    TerminalApp(id: "com.cmuxterm.app", name: "cmux", bundleId: "com.cmuxterm.app"),
    TerminalApp(
      id: "com.cmuxterm.app.nightly", name: "cmux (Nightly)", bundleId: "com.cmuxterm.app.nightly"),
    TerminalApp(id: "dev.warp.Warp-Stable", name: "Warp", bundleId: "dev.warp.Warp-Stable"),
    TerminalApp(id: "com.github.wez.wezterm", name: "WezTerm", bundleId: "com.github.wez.wezterm"),
    TerminalApp(id: "org.alacritty", name: "Alacritty", bundleId: "org.alacritty"),
    TerminalApp(id: "co.zeit.hyper", name: "Hyper", bundleId: "co.zeit.hyper"),
    TerminalApp(id: "net.kovidgoyal.kitty", name: "Kitty", bundleId: "net.kovidgoyal.kitty"),
  ]
}

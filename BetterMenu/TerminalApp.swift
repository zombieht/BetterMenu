/// 表示支持的第三方或系统终端应用。`id` 即为应用的 Bundle Identifier。
struct TerminalApp: Identifiable, Hashable {
  let id: String
  let name: String

  /// 便于语义明确的别名访问
  var bundleId: String { id }

  /// 预定义终端列表。`id` 直接使用 Bundle Identifier，便于直接写入用户偏好。
  static let knownTerminals: [TerminalApp] = [
    TerminalApp(id: "com.apple.Terminal", name: "终端 (Terminal)"),
    TerminalApp(id: "com.googlecode.iterm2", name: "iTerm2"),
    TerminalApp(id: "com.mitchellh.ghostty", name: "Ghostty"),
    TerminalApp(id: "com.cmuxterm.app", name: "cmux"),
    TerminalApp(id: "com.cmuxterm.app.nightly", name: "cmux (Nightly)"),
    TerminalApp(id: "dev.warp.Warp-Stable", name: "Warp"),
    TerminalApp(id: "com.github.wez.wezterm", name: "WezTerm"),
    TerminalApp(id: "org.alacritty", name: "Alacritty"),
    TerminalApp(id: "co.zeit.hyper", name: "Hyper"),
    TerminalApp(id: "net.kovidgoyal.kitty", name: "Kitty"),
  ]
}

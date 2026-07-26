import Foundation

/// 将任意合法文件路径编码为不会改变 AppleScript 语法结构的字符串表达式。
enum AppleScriptPathArgument {
  static func sourceLiteral(for value: String) -> String {
    var expressions: [String] = []
    var currentText = ""

    func appendCurrentTextIfNeeded() {
      guard !currentText.isEmpty else { return }
      expressions.append("\"\(currentText)\"")
      currentText.removeAll(keepingCapacity: true)
    }

    for scalar in value.unicodeScalars {
      switch scalar.value {
      case 0x09:
        appendCurrentTextIfNeeded()
        expressions.append("tab")
      case 0x0A:
        appendCurrentTextIfNeeded()
        expressions.append("linefeed")
      case 0x0D:
        appendCurrentTextIfNeeded()
        expressions.append("return")
      case 0x00...0x1F, 0x7F:
        appendCurrentTextIfNeeded()
        expressions.append("character id \(scalar.value)")
      case 0x22:
        currentText.append(contentsOf: "\\\"")
      case 0x5C:
        currentText.append(contentsOf: "\\\\")
      default:
        currentText.append(contentsOf: String(scalar))
      }
    }

    appendCurrentTextIfNeeded()
    return expressions.isEmpty ? "\"\"" : expressions.joined(separator: " & ")
  }
}

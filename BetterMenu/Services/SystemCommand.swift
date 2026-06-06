import Foundation

/// 轻量命令执行结果，只暴露设置页需要的退出状态和用户可读信息。
struct CommandResult: Sendable {
  /// 进程退出的状态码
  let exitCode: Int32
  /// 进程的标准输出内容
  let standardOutput: String
  /// 进程的标准错误输出内容
  let standardError: String

  /// 判断进程是否成功退出 (退出码为 0)
  var succeeded: Bool {
    exitCode == 0
  }

  /// 提取用于展示给用户的消息，优先返回标准错误，其次返回标准输出
  var userMessage: String? {
    if !standardError.isEmpty { return standardError }
    if !standardOutput.isEmpty { return standardOutput }
    return nil
  }
}

/// 对 Process 进行轻量级封装，集中管理系统命令行调用与管道数据读取。
enum SystemCommand {
  /// 异步执行系统命令并返回执行结果
  /// - Parameters:
  ///   - path: 可执行程序的绝对路径
  ///   - arguments: 传递给命令的参数数组
  /// - Returns: CommandResult 包含退出状态及输出
  static func run(path: String, arguments: [String]) async -> CommandResult {
    await withCheckedContinuation { continuation in
      let command = Process()
      let outputPipe = Pipe()
      let errorPipe = Pipe()

      command.executableURL = URL(fileURLWithPath: path)
      command.arguments = arguments
      command.standardOutput = outputPipe
      command.standardError = errorPipe
      command.terminationHandler = { process in
        continuation.resume(
          returning: CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: readText(from: outputPipe),
            standardError: readText(from: errorPipe)
          ))
      }

      do {
        try command.run()
      } catch {
        continuation.resume(
          returning: CommandResult(
            exitCode: -1,
            standardOutput: "",
            standardError: error.localizedDescription
          ))
      }
    }
  }

  /// 从 Pipe 管道中读取文本数据并去除首尾空白
  private static func readText(from pipe: Pipe) -> String {
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }
}

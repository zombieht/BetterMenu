import Foundation
import Cocoa

/// 负责实际物理文件的创建、防文件名冲突算法计算以及 POSIX 执行权限设置。
enum FileCreator {
  /// 封装一次 Finder 新建文件动作，集中处理文件名冲突、模板内容和执行权限。
  struct FileCreationRequest {
    let directory: URL
    let definition: FileDefinition
    private let fileManager = FileManager.default

    /// 执行物理文件的创建
    /// - Returns: 返回最终成功创建的文件路径 URL
    func create() throws -> URL {
      let destination = try makeAvailableDestination()
      
      // 将 FinderSync.self 所在得 bundle 作为参数传递，以定位扩展包中的模板文件
      try definition.contents(in: Bundle(for: FinderSync.self)).write(to: destination, options: .withoutOverwriting)
      if definition.shouldBeExecutable {
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
      }
      return destination
    }

    /// 迭代替代计算出当前目录下不冲突的可用文件名 (如 "新建文件 2", "新建文件 3")
    private func makeAvailableDestination() throws -> URL {
      for attempt in 1...999 {
        let suffix = attempt == 1 ? "" : " \(attempt)"
        let candidate = makeDestinationUrl(fileName: "\(definition.baseName)\(suffix)")
        if !fileManager.fileExists(atPath: candidate.path) {
          return candidate
        }
      }
      throw CocoaError(.fileWriteFileExists)
    }

    private func makeDestinationUrl(fileName: String) -> URL {
      var url = directory.appendingPathComponent(fileName)
      if let pathExtension = definition.pathExtension {
        url.appendPathExtension(pathExtension)
      }
      return url
    }
  }

  /// 创建物理文件的静态便利方法
  /// - Parameters:
  ///   - definition: 新建文件类型的具体定义描述
  ///   - directory: 新建文件要存放的所在目录 URL
  /// - Returns: 返回创建完成后的文件路径 URL
  static func createFile(from definition: FileDefinition, at directory: URL) throws -> URL {
    let request = FileCreationRequest(directory: directory, definition: definition)
    return try request.create()
  }
}

import Cocoa
import UniformTypeIdentifiers
import os

/// 负责在后台异步预热文件类型图标及外部应用程序图标，并将渲染好的 Retina PNG 数据序列化写入磁盘缓存。
enum IconCacheManager {
  private static let logger = Logger(subsystem: "com.zombie.BetterMenu", category: "IconCacheManager")
  /// 执行图标的异步预热与磁盘缓存写入
  /// - Parameters:
  ///   - fileTypes: 当前配置的全部内置文件类型定义
  ///   - customExtensions: 用户自定义的文件扩展名列表
  ///   - activeActions: 当前启用的 Finder 右键快捷操作列表
  static func prewarm(
    fileTypes: [FileDefinition],
    customExtensions: [String],
    activeActions: [FinderAction]
  ) {
    let builtInItems = fileTypes.map { type -> (id: String, fileExtension: String) in
      let fileExtension = type.pathExtension ?? ""
      return (type.id, fileExtension)
    }
    let customItems = customExtensions.map { fileExtension in
      (id: "custom.\(fileExtension)", fileExtension: fileExtension)
    }
    let iconItems = builtInItems + customItems

    DispatchQueue.global(qos: .utility).async {
      let targetSize = NSSize(width: 18, height: 18)
      var dict: [String: Data] = [:]

      // 1. 预热并绘制所有可能用到得新建文件类型图标
      for item in iconItems {
        // 使用 macOS 15+ 推荐的 UTType 现代化获取图标方法
        let type = UTType(filenameExtension: item.fileExtension) ?? .item
        let image = NSWorkspace.shared.icon(for: type)
        image.size = targetSize
        image.isTemplate = false
        if let pngData = image.exportToPngData(targetSize: targetSize) {
          dict[item.id] = pngData
        }
      }

      // 2. 预热并缓存外部操作的 App 真实图标到共享缓存中，以便 FinderSync 进程直接读取
      for action in activeActions {
        if action.id == "terminal" || action.id == "copyPath" {
          continue
        }

        var appUrl: URL? = nil
        if let editor = BetterMenuShared.supportedEditors.first(where: { $0.idString == action.id }) {
          for bid in editor.bundleIds {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
              appUrl = url
              break
            }
          }
        } else {
          appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: action.id)
        }

        if let appUrl = appUrl {
          let image = NSWorkspace.shared.icon(forFile: appUrl.path)
          image.size = targetSize
          image.isTemplate = false
          if let pngData = image.exportToPngData(targetSize: targetSize) {
            dict[action.id] = pngData
          }
        }
      }

      guard !dict.isEmpty else { return }

      // 3. 将序列化后的二进制图标数据写入共享 Caches 目录
      do {
        let cacheUrl = BetterMenuShared.iconCacheUrl
        try FileManager.default.createDirectory(
          at: cacheUrl.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
          fromPropertyList: dict, format: .binary, options: 0
        )
        try data.write(to: cacheUrl, options: .atomic)
      } catch {
        logger.error("Failed to write icon cache to disk: \(error.localizedDescription, privacy: .public)")
      }
    }
  }
}

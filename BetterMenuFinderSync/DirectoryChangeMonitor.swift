import Foundation
import os

/// 监听单个目录的写入事件，用于在主应用更新共享文件后及时作废扩展进程内的缓存。
///
/// 主应用写入 `settings.plist` 与 `icon_cache.plist` 时都使用原子写（临时文件 + rename），
/// 文件 inode 会被整体替换，因此必须监听父目录而不是文件本身。
final class DirectoryChangeMonitor: @unchecked Sendable {
  private let logger = Logger(
    subsystem: "com.zombie.BetterMenu", category: "DirectoryChangeMonitor")
  private let directoryUrl: URL
  private let queue: DispatchQueue

  private let stateLock = NSLock()
  private var source: DispatchSourceFileSystemObject?

  init(directoryUrl: URL, queueLabel: String) {
    self.directoryUrl = directoryUrl
    self.queue = DispatchQueue(label: queueLabel, qos: .utility)
  }

  deinit {
    stop()
  }

  /// 开始监听目录写入事件。目录不存在时会尝试创建，创建失败则放弃监听并保持缓存原样。
  /// - Parameter onChange: 目录内容变化时在内部串行队列上触发的回调。
  func start(onChange: @escaping @Sendable () -> Void) {
    do {
      try FileManager.default.createDirectory(at: directoryUrl, withIntermediateDirectories: true)
    } catch {
      logger.error(
        "Failed to create monitored directory \(self.directoryUrl.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }

    let fileDescriptor = open(directoryUrl.path, O_EVTONLY)
    guard fileDescriptor >= 0 else {
      logger.error(
        "Failed to open directory descriptor for monitoring: \(self.directoryUrl.path, privacy: .public)"
      )
      return
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fileDescriptor,
      eventMask: .write,
      queue: queue
    )
    source.setEventHandler(handler: onChange)
    source.setCancelHandler {
      close(fileDescriptor)
    }

    stateLock.lock()
    let previousSource = source === self.source ? nil : self.source
    self.source = source
    stateLock.unlock()
    previousSource?.cancel()

    source.resume()
    logger.info("Started monitoring directory: \(self.directoryUrl.path, privacy: .public)")
  }

  /// 停止监听并释放文件描述符。可重复调用。
  func stop() {
    stateLock.lock()
    let currentSource = source
    source = nil
    stateLock.unlock()
    currentSource?.cancel()
  }
}

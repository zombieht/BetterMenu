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

  private struct State {
    var source: DispatchSourceFileSystemObject?
    var onChange: (@Sendable () -> Void)?
    var isRunning = false
    var retryScheduled = false
    var retryAttempt = 0
    var generation: UInt64 = 0
  }

  private let stateLock = NSLock()
  private var state = State()

  init(directoryUrl: URL, queueLabel: String) {
    self.directoryUrl = directoryUrl
    self.queue = DispatchQueue(label: queueLabel, qos: .utility)
  }

  deinit {
    stop()
  }

  /// 开始监听目录写入事件。目录不存在时会尝试创建，创建失败则稍后重试。
  /// - Parameter onChange: 目录内容变化时在内部串行队列上触发的回调。
  func start(onChange: @escaping @Sendable () -> Void) {
    stateLock.lock()
    let previousSource = state.source
    state.source = nil
    state.onChange = onChange
    state.isRunning = true
    state.retryScheduled = false
    state.retryAttempt = 0
    state.generation &+= 1
    stateLock.unlock()
    previousSource?.cancel()

    installSource()
  }

  /// 停止监听并释放文件描述符。可重复调用。
  func stop() {
    stateLock.lock()
    let currentSource = state.source
    state.source = nil
    state.onChange = nil
    state.isRunning = false
    state.retryScheduled = false
    state.retryAttempt = 0
    state.generation &+= 1
    stateLock.unlock()
    currentSource?.cancel()
  }

  private func installSource() {
    stateLock.lock()
    guard state.isRunning, state.source == nil else {
      stateLock.unlock()
      return
    }
    let generation = state.generation
    stateLock.unlock()

    do {
      try FileManager.default.createDirectory(at: directoryUrl, withIntermediateDirectories: true)
    } catch {
      logger.error(
        "Failed to create monitored directory \(self.directoryUrl.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      scheduleRetry()
      return
    }

    let fileDescriptor = open(directoryUrl.path, O_EVTONLY)
    guard fileDescriptor >= 0 else {
      logger.error(
        "Failed to open directory descriptor for monitoring: \(self.directoryUrl.path, privacy: .public)"
      )
      scheduleRetry()
      return
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fileDescriptor,
      eventMask: [.write, .delete, .rename, .revoke],
      queue: queue
    )
    source.setEventHandler { [weak self] in
      self?.handleEvent(for: generation)
    }
    source.setCancelHandler {
      close(fileDescriptor)
    }

    stateLock.lock()
    let shouldInstall =
      state.isRunning
      && state.generation == generation
      && state.source == nil
    if shouldInstall {
      state.source = source
      state.retryAttempt = 0
    }
    stateLock.unlock()

    guard shouldInstall else {
      source.cancel()
      source.resume()
      return
    }
    source.resume()
    logger.info("Started monitoring directory: \(self.directoryUrl.path, privacy: .public)")
  }

  private func handleEvent(for generation: UInt64) {
    stateLock.lock()
    guard
      state.isRunning,
      state.generation == generation,
      let currentSource = state.source
    else {
      stateLock.unlock()
      return
    }

    let events = currentSource.data
    let onChange = state.onChange
    let requiresReattachment =
      events.contains(.delete)
      || events.contains(.rename)
      || events.contains(.revoke)
    if requiresReattachment {
      state.source = nil
      state.retryAttempt = 0
      state.generation &+= 1
    }
    stateLock.unlock()

    onChange?()

    guard requiresReattachment else { return }
    currentSource.cancel()
    logger.info(
      "Monitored directory was replaced or removed, scheduling reattachment: \(self.directoryUrl.path, privacy: .public)"
    )
    scheduleRetry()
  }

  private func scheduleRetry() {
    stateLock.lock()
    guard
      state.isRunning,
      state.source == nil,
      !state.retryScheduled
    else {
      stateLock.unlock()
      return
    }
    state.retryScheduled = true
    let retryAttempt = state.retryAttempt
    state.retryAttempt = min(retryAttempt + 1, 5)
    let generation = state.generation
    stateLock.unlock()

    let retryDelayMilliseconds = 250 * (1 << min(retryAttempt, 4))
    queue.asyncAfter(deadline: .now() + .milliseconds(retryDelayMilliseconds)) { [weak self] in
      guard let self else { return }

      self.stateLock.lock()
      guard
        self.state.isRunning,
        self.state.generation == generation,
        self.state.source == nil
      else {
        self.stateLock.unlock()
        return
      }
      self.state.retryScheduled = false
      self.stateLock.unlock()

      self.installSource()
    }
  }
}

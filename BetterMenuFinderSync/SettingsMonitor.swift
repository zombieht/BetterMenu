import Foundation
import os

/// 负责从共享存储中加载 BetterMenu 偏好设置快照，并监控设置 plist 目录变化以自动刷新缓存。
final class SettingsMonitor: @unchecked Sendable {
  private let logger = Logger(subsystem: "com.zombie.BetterMenu", category: "SettingsMonitor")
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "com.zombie.BetterMenu.settingsMonitorQueue", qos: .utility)
  
  // 跨线程读写的缓存状态用 lock 保护
  private struct State {
    var cachedSnapshot: SettingsSnapshot?
    var fileMonitorSource: DispatchSourceFileSystemObject?
    var fileDescriptor: Int32 = -1
  }
  private let stateLock = NSLock()
  private var state = State()

  /// 偏好设置快照定义，代表某一时点下的只读配置 Snap
  struct SettingsSnapshot: Sendable {
    let enabledFileTypes: Set<String>
    let customExtensions: [String]
    let menuOrder: [String]?
    let actions: [FinderAction]
  }

  /// 偏好设置发生变化时的回调
  var onSettingsChanged: (@Sendable () -> Void)?

  init() {
    startMonitoring()
  }

  deinit {
    stopMonitoring()
  }

  /// 获取最新的偏好设置快照，如果缓存有效直接返回，否则重新读取。
  /// 使用 double-checked locking 确保多线程下只采纳一次加载结果。
  func getCurrentSnapshot() -> SettingsSnapshot {
    // 快速路径：检查缓存
    stateLock.lock()
    if let cached = state.cachedSnapshot {
      stateLock.unlock()
      return cached
    }
    stateLock.unlock()

    // 慢速路径：加载配置
    let snapshot = loadSnapshot()

    // 在锁内二次检查：另一线程可能已抢先完成加载
    stateLock.lock()
    if let cached = state.cachedSnapshot {
      stateLock.unlock()
      return cached
    }
    state.cachedSnapshot = snapshot
    stateLock.unlock()

    return snapshot
  }

  /// 从共享 plist 加载并组装一份完整的偏好设置快照。
  private func loadSnapshot() -> SettingsSnapshot {
    let shared = readSharedSettings()

    // 默认启用列表从共享定义中动态计算，确保与主程序保持一致
    let defaultEnabledFileTypeIds = Set(BetterMenuShared.supportedFileTypes.filter(\.enabledByDefault).map(\.id))
    let enabledIds = Set(shared.enabledFileTypes ?? UserDefaults.standard.stringArray(forKey: BetterMenuShared.enabledFileTypesKey) ?? Array(defaultEnabledFileTypeIds))
    let customExts = shared.customExtensions ?? UserDefaults.standard.stringArray(forKey: BetterMenuShared.customExtensionsKey) ?? []

    let finalActions: [FinderAction]
    if let actionsList = shared.actions {
      finalActions = actionsList
    } else {
      // 兼容以前的布尔设置键
      var acts = defaultSharedActions
      let terminalVal = shared.oldTerminalDirectEnabled ?? (UserDefaults.standard.object(forKey: BetterMenuShared.oldTerminalDirectEnabledKey) as? Bool ?? true)
      let pathVal = shared.oldPathCopyEnabled ?? (UserDefaults.standard.object(forKey: BetterMenuShared.oldPathCopyEnabledKey) as? Bool ?? true)

      if let idx = acts.firstIndex(where: { $0.id == "terminal" }) {
        acts[idx] = FinderAction(id: "terminal", title: "在终端中打开", iconName: "terminal", isEnabled: terminalVal)
      }
      if let idx = acts.firstIndex(where: { $0.id == "copyPath" }) {
        acts[idx] = FinderAction(id: "copyPath", title: "复制当前路径", iconName: "doc.on.doc", isEnabled: pathVal)
      }
      finalActions = acts
    }

    return SettingsSnapshot(
      enabledFileTypes: enabledIds,
      customExtensions: customExts,
      menuOrder: shared.menuOrder,
      actions: finalActions
    )
  }

  /// 开始监控偏好设置所在的目录变化
  private func startMonitoring() {
    let fileUrl = BetterMenuShared.sharedSettingsUrl
    let directoryUrl = fileUrl.deletingLastPathComponent()

    do {
      try FileManager.default.createDirectory(at: directoryUrl, withIntermediateDirectories: true)
    } catch {
      logger.error("Failed to create settings directory for monitoring: \(error.localizedDescription, privacy: .public)")
    }

    let dirPath = directoryUrl.path
    let fd = open(dirPath, O_EVTONLY)
    guard fd >= 0 else {
      logger.error("Failed to open settings directory descriptor for monitoring")
      return
    }

    stateLock.lock()
    state.fileDescriptor = fd
    
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: .write,
      queue: queue
    )

    source.setEventHandler { [weak self] in
      guard let self = self else { return }
      self.logger.info("Settings directory changed, invalidating cached configuration")
      
      self.stateLock.lock()
      self.state.cachedSnapshot = nil
      self.stateLock.unlock()

      // 触发外部无效化通知
      self.onSettingsChanged?()
    }

    source.setCancelHandler {
      close(fd)
    }

    state.fileMonitorSource = source
    stateLock.unlock()
    
    source.resume()
    logger.info("Started monitoring settings directory: \(dirPath, privacy: .public)")
  }

  /// 停止文件监听
  private func stopMonitoring() {
    stateLock.lock()
    state.fileMonitorSource?.cancel()
    state.fileMonitorSource = nil
    stateLock.unlock()
  }
}

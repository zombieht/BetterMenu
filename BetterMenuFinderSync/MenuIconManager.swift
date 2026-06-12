import Cocoa
import os

/// 负责从磁盘读取预热好的 App 与文件类型图标，并提供系统 SF Symbol 图标深浅色高品质重绘与缓存服务。
final class MenuIconManager: @unchecked Sendable {
  private let logger = Logger(subsystem: "com.zombie.BetterMenu", category: "MenuIconManager")
  private let lock = NSLock()
  private var menuItemIconsById: [String: NSImage] = [:]
  private var didLoadDiskCache = false

  // 静态 SF Symbol 渲染缓存与锁
  private struct SymbolCacheState {
    var symbolCache: [String: NSImage] = [:]
    var lastAppearanceIsDark: Bool? = nil
  }
  private static let symbolCacheLock = OSAllocatedUnfairLock(initialState: SymbolCacheState())

  /// 清除全部内存缓存（在偏好设置或系统外观模式发生改变时调用）
  func clearCache() {
    lock.lock()
    menuItemIconsById.removeAll()
    didLoadDiskCache = false
    lock.unlock()

    Self.symbolCacheLock.withLock { state in
      state.symbolCache.removeAll()
      state.lastAppearanceIsDark = nil
    }
  }

  /// 获取在磁盘中预热缓存的图标。若未加载，则在此处触发加载。
  /// - Parameter id: 文件类型 ID 或 action ID
  /// - Returns: 预热成功的 NSImage 实例
  func getCachedIcon(for id: String) -> NSImage? {
    lock.lock()
    if !didLoadDiskCache {
      lock.unlock()
      loadDiskCache()
      lock.lock()
    }
    let icon = menuItemIconsById[id]
    lock.unlock()
    return icon
  }

  /// 从磁盘加载 App 预热好的图标数据缓存文件到内存
  private func loadDiskCache() {
    guard let data = try? Data(contentsOf: BetterMenuShared.iconCacheUrl),
          let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data]
    else {
      logger.info("No icon disk cache found or failed to load")
      lock.lock()
      didLoadDiskCache = true
      lock.unlock()
      return
    }

    var loadedIcons: [String: NSImage] = [:]
    var loadedCount = 0
    for (id, imageData) in dict {
      if let image = NSImage(data: imageData) {
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        loadedIcons[id] = image
        loadedCount += 1
      }
    }

    lock.lock()
    for (id, icon) in loadedIcons {
      menuItemIconsById[id] = icon
    }
    didLoadDiskCache = true
    lock.unlock()

    logger.info("Loaded \(loadedCount) icons from disk cache")
  }

  /// 创建 Finder 菜单专用 SF Symbol 图像，自适应系统深浅色外观，并且借助内存缓存优化性能。
  static func finderMenuSymbol(named symbolName: String, accessibilityDescription: String) -> NSImage {
    let isDark = systemUsesDarkAppearance()

    return symbolCacheLock.withLock { state in
      // 动态检测系统深浅色外观变化，若发生变化清空内存缓存重新生成
      if state.lastAppearanceIsDark != isDark {
        state.symbolCache.removeAll()
        state.lastAppearanceIsDark = isDark
      }

      if let cached = state.symbolCache[symbolName] {
        return cached
      }

      let targetSize = NSSize(width: 18, height: 18)
      guard let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)
              ?? NSImage(systemSymbolName: "doc", accessibilityDescription: accessibilityDescription)
      else {
        return NSImage()
      }
      symbolImage.size = targetSize

      // 使用 NSImage(size:flipped:drawingHandler:) 替代已弃用的 lockFocus/unlockFocus
      let image = NSImage(size: targetSize, flipped: false) { drawRect in
        NSGraphicsContext.current?.imageInterpolation = .high
        symbolImage.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)

        // 深色模式使用系统高对比淡白色，浅色模式使用系统高对比深灰色
        let tintColor = isDark
          ? NSColor(calibratedWhite: 0.85, alpha: 1.0)
          : NSColor(calibratedWhite: 0.17, alpha: 1.0)
        tintColor.setFill()
        drawRect.fill(using: .sourceAtop)
        return true
      }
      image.isTemplate = false // 禁用 template 模式，防止系统自动二次涂色

      state.symbolCache[symbolName] = image
      return image
    }
  }

  /// 无 API 警告地通过系统全局 UserDefaults 快速读取系统深浅色外观状态
  private static func systemUsesDarkAppearance() -> Bool {
    if let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") {
      return style.caseInsensitiveCompare("Dark") == .orderedSame
    }
    if let style = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String {
      return style.caseInsensitiveCompare("Dark") == .orderedSame
    }
    return false
  }
}

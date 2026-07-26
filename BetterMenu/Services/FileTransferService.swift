import Cocoa
import os

/// 承接 Finder 扩展发起的文件传输任务，确保大文件复制不依赖扩展进程生命周期。
@MainActor
final class FileTransferService {
  private struct CopyFailure: Sendable {
    let fileName: String
    let message: String
  }

  private struct CopyResult: Sendable {
    let copiedUrls: [URL]
    let failures: [CopyFailure]
  }

  private let logger = Logger(
    subsystem: "com.zombie.BetterMenu", category: "FileTransferService")
  private var activeAirDropService: NSSharingService?
  private var copyTasks: [UUID: Task<Void, Never>] = [:]

  /// 使用系统隔空投送面板发送选中的文件或文件夹。
  func sendViaAirDrop(sourceUrls: [URL]) {
    let existingUrls = existingSourceUrls(from: sourceUrls)
    guard !existingUrls.isEmpty else {
      showError(title: "无法发送文件", message: "选中的文件或文件夹已不存在。")
      return
    }
    guard
      let service = NSSharingService(named: .sendViaAirDrop),
      service.canPerform(withItems: existingUrls)
    else {
      showError(title: "隔空投送不可用", message: "请确认隔空投送已开启后再试。")
      return
    }

    activeAirDropService = service
    service.perform(withItems: existingUrls)
  }

  /// 将选中的文件或文件夹异步复制到外置磁盘、U 盘或网络共享卷根目录。
  func copy(sourceUrls: [URL], to destinationUrl: URL) {
    let existingUrls = existingSourceUrls(from: sourceUrls)
    guard !existingUrls.isEmpty else {
      showError(title: "无法发送文件", message: "选中的文件或文件夹已不存在。")
      return
    }

    let taskId = UUID()
    let task = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        Self.copyItems(existingUrls, to: destinationUrl)
      }.value

      guard let self else { return }
      self.copyTasks.removeValue(forKey: taskId)
      self.handleCopyResult(result, destinationUrl: destinationUrl)
    }
    copyTasks[taskId] = task
  }

  private func existingSourceUrls(from urls: [URL]) -> [URL] {
    let fileManager = FileManager.default
    var acceptedPaths: Set<String> = []
    return urls.compactMap { url in
      let standardizedUrl = url.standardizedFileURL
      guard
        fileManager.fileExists(atPath: standardizedUrl.path),
        acceptedPaths.insert(standardizedUrl.path).inserted
      else {
        return nil
      }
      return standardizedUrl
    }
  }

  private func handleCopyResult(_ result: CopyResult, destinationUrl: URL) {
    if !result.copiedUrls.isEmpty {
      NSWorkspace.shared.activateFileViewerSelecting(result.copiedUrls)
    }

    guard !result.failures.isEmpty else { return }

    let maximumDisplayedFailures = 3
    var detailLines = result.failures.prefix(maximumDisplayedFailures).map {
      "\($0.fileName)：\($0.message)"
    }
    if result.failures.count > maximumDisplayedFailures {
      detailLines.append("另有 \(result.failures.count - maximumDisplayedFailures) 个项目失败。")
    }

    let destinationName = destinationUrl.lastPathComponent
    showError(
      title: result.copiedUrls.isEmpty ? "发送文件失败" : "部分文件发送失败",
      message: "目标：\(destinationName)\n\n\(detailLines.joined(separator: "\n"))"
    )
  }

  private func showError(title: String, message: String) {
    logger.error("\(title, privacy: .public): \(message, privacy: .public)")
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    NSApp.activate()
    alert.runModal()
  }

  nonisolated private static func copyItems(
    _ sourceUrls: [URL],
    to requestedDestinationUrl: URL
  ) -> CopyResult {
    let fileManager = FileManager()
    let destinationUrl = requestedDestinationUrl.standardizedFileURL
    guard
      BetterMenuShared.availableFileTransferVolumes(fileManager: fileManager)
        .contains(where: { $0.url.path == destinationUrl.path })
    else {
      return CopyResult(
        copiedUrls: [],
        failures: [
          CopyFailure(
            fileName: destinationUrl.lastPathComponent,
            message: "目标设备已断开、只读或不可写。"
          )
        ]
      )
    }

    var copiedUrls: [URL] = []
    var failures: [CopyFailure] = []
    for sourceUrl in sourceUrls {
      guard !destinationIsInsideSource(destinationUrl, sourceUrl: sourceUrl) else {
        failures.append(
          CopyFailure(fileName: sourceUrl.lastPathComponent, message: "不能将项目复制到其自身内部。"))
        continue
      }

      let targetUrl = availableTargetUrl(
        for: sourceUrl,
        in: destinationUrl,
        fileManager: fileManager
      )
      do {
        try fileManager.copyItem(at: sourceUrl, to: targetUrl)
        copiedUrls.append(targetUrl)
      } catch {
        if fileManager.fileExists(atPath: targetUrl.path) {
          try? fileManager.removeItem(at: targetUrl)
        }
        failures.append(
          CopyFailure(fileName: sourceUrl.lastPathComponent, message: error.localizedDescription))
      }
    }

    return CopyResult(copiedUrls: copiedUrls, failures: failures)
  }

  nonisolated private static func destinationIsInsideSource(
    _ destinationUrl: URL,
    sourceUrl: URL
  ) -> Bool {
    let sourcePath = sourceUrl.standardizedFileURL.path
    let destinationPath = destinationUrl.standardizedFileURL.path
    return destinationPath == sourcePath || destinationPath.hasPrefix(sourcePath + "/")
  }

  nonisolated private static func availableTargetUrl(
    for sourceUrl: URL,
    in destinationUrl: URL,
    fileManager: FileManager
  ) -> URL {
    let originalTargetUrl = destinationUrl.appendingPathComponent(sourceUrl.lastPathComponent)
    guard fileManager.fileExists(atPath: originalTargetUrl.path) else {
      return originalTargetUrl
    }

    let pathExtension = sourceUrl.pathExtension
    let baseName =
      pathExtension.isEmpty
      ? sourceUrl.lastPathComponent
      : sourceUrl.deletingPathExtension().lastPathComponent
    var copyIndex = 2
    while true {
      let candidateName =
        pathExtension.isEmpty
        ? "\(baseName) \(copyIndex)"
        : "\(baseName) \(copyIndex).\(pathExtension)"
      let candidateUrl = destinationUrl.appendingPathComponent(candidateName)
      if !fileManager.fileExists(atPath: candidateUrl.path) {
        return candidateUrl
      }
      copyIndex += 1
    }
  }
}

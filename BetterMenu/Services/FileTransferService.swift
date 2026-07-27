import Cocoa
import os

/// 承接 Finder 扩展发起的文件传输任务，确保大文件复制不依赖扩展进程生命周期。
@MainActor
final class FileTransferService {
  private struct ActiveCopyTask {
    let task: Task<Void, Never>
    let cancellationToken: FileTransferCancellationToken
    let progressWindowController: FileTransferProgressWindowController
    let cascadeIndex: Int
  }

  /// `NSSharingService.delegate` 是弱引用，因此需要与 service 一起被持有。
  private struct ActiveAirDropTask {
    let service: NSSharingService
    let delegate: AirDropCompletionDelegate
  }

  /// 在隔空投送成功或失败后通知调用方释放对应的 service 强引用。
  @MainActor
  final class AirDropCompletionDelegate: NSObject, NSSharingServiceDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
      self.onFinish = onFinish
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
      onFinish()
    }

    func sharingService(
      _ sharingService: NSSharingService,
      didFailToShareItems items: [Any],
      error: any Error
    ) {
      onFinish()
    }
  }

  private let logger = Logger(
    subsystem: "com.zombie.BetterMenu", category: "FileTransferService")
  /// 正在进行的隔空投送。`perform(withItems:)` 是异步的，面板关闭前必须保持强引用；
  /// 用单值保存会让第二次投送顶掉第一次的引用，因此按任务 id 分别持有，结束回调里再移除。
  private var activeAirDropTasks: [UUID: ActiveAirDropTask] = [:]
  private var copyTasks: [UUID: ActiveCopyTask] = [:]

  /// 使用系统隔空投送面板发送选中的文件或文件夹。
  func sendViaAirDrop(sourceUrls: [URL]) {
    let existingUrls = existingSourceUrls(from: sourceUrls)
    guard !existingUrls.isEmpty else {
      showError(title: "无法发送文件", message: "选中的文件或文件夹已不存在。")
      return
    }
    guard let service = NSSharingService(named: .sendViaAirDrop) else {
      showError(title: "隔空投送不可用", message: "请确认隔空投送已开启后再试。")
      return
    }

    let taskId = UUID()
    let delegate = AirDropCompletionDelegate { [weak self] in
      self?.activeAirDropTasks.removeValue(forKey: taskId)
    }
    service.delegate = delegate
    activeAirDropTasks[taskId] = ActiveAirDropTask(service: service, delegate: delegate)
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
    let cancellationToken = FileTransferCancellationToken()
    let progressModel = FileTransferProgressModel()
    let progressWindowController = FileTransferProgressWindowController(model: progressModel)
    progressModel.onCancel = { [weak self] in
      self?.cancelCopyTask(taskId)
    }
    let cascadeIndex = nextAvailableCascadeIndex()
    // 已有传输任务时把新窗口阶梯式错开，避免多个进度窗口完全重叠。
    progressWindowController.show(cascadeIndex: cascadeIndex)

    let task = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        let standardizedDestinationUrl = destinationUrl.standardizedFileURL
        guard
          BetterMenuShared.availableFileTransferVolumes()
            .contains(where: { $0.url.path == standardizedDestinationUrl.path })
        else {
          return FileTransferCopyResult(
            copiedUrls: [],
            failures: [
              FileTransferCopyFailure(
                fileName: standardizedDestinationUrl.lastPathComponent,
                message: "目标设备已断开、只读或不可写。"
              )
            ],
            wasCancelled: false
          )
        }

        return FileTransferOperations.copyItems(
          existingUrls,
          to: standardizedDestinationUrl,
          cancellationToken: cancellationToken,
          progressHandler: { snapshot in
            Task { @MainActor [weak progressModel] in
              progressModel?.update(with: snapshot)
            }
          }
        )
      }.value

      guard let self else { return }
      self.copyTasks.removeValue(forKey: taskId)
      progressWindowController.close()
      self.handleCopyResult(result, destinationUrl: destinationUrl)
    }
    copyTasks[taskId] = ActiveCopyTask(
      task: task,
      cancellationToken: cancellationToken,
      progressWindowController: progressWindowController,
      cascadeIndex: cascadeIndex
    )
  }

  /// 返回当前未被传输窗口占用的最小层叠位置，任务完成后该位置会自然释放并复用。
  private func nextAvailableCascadeIndex() -> Int {
    let occupiedIndexes = Set(copyTasks.values.map(\.cascadeIndex))
    return (0...).first(where: { !occupiedIndexes.contains($0) }) ?? 0
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

  private func cancelCopyTask(_ taskId: UUID) {
    guard let activeTask = copyTasks[taskId] else { return }
    activeTask.cancellationToken.cancel()
    activeTask.task.cancel()
  }

  private func handleCopyResult(
    _ result: FileTransferCopyResult,
    destinationUrl: URL
  ) {
    if !result.copiedUrls.isEmpty {
      NSWorkspace.shared.activateFileViewerSelecting(result.copiedUrls)
    }

    guard !result.wasCancelled, !result.failures.isEmpty else { return }

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
}

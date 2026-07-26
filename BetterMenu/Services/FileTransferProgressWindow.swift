import Cocoa
import SwiftUI

@MainActor
final class FileTransferProgressModel: ObservableObject {
  @Published private(set) var currentFileName = ""
  @Published private(set) var completedBytes: Int64 = 0
  @Published private(set) var totalBytes: Int64 = 0
  @Published private(set) var completedItemCount = 0
  @Published private(set) var totalItemCount = 0
  @Published private(set) var isCancelling = false

  var onCancel: (() -> Void)?

  var progressValue: Double? {
    if totalBytes > 0 {
      return min(1, Double(completedBytes) / Double(totalBytes))
    }
    guard totalItemCount > 0 else { return nil }
    return min(1, Double(completedItemCount) / Double(totalItemCount))
  }

  var statusText: String {
    if isCancelling {
      return "正在取消传输…"
    }
    if currentFileName.isEmpty {
      return "正在计算传输大小…"
    }
    return "正在复制“\(currentFileName)”"
  }

  var detailText: String {
    let itemProgress = "\(completedItemCount)/\(totalItemCount) 项"
    guard totalBytes > 0 else {
      return itemProgress
    }

    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useAll]
    formatter.countStyle = .file
    let completedText = formatter.string(fromByteCount: completedBytes)
    let totalText = formatter.string(fromByteCount: totalBytes)
    return "\(itemProgress) · \(completedText)/\(totalText)"
  }

  func update(with snapshot: FileTransferProgressSnapshot) {
    guard !isCancelling else { return }
    currentFileName = snapshot.currentFileName
    completedBytes = snapshot.completedBytes
    totalBytes = snapshot.totalBytes
    completedItemCount = snapshot.completedItemCount
    totalItemCount = snapshot.totalItemCount
  }

  func requestCancellation() {
    guard !isCancelling else { return }
    isCancelling = true
    onCancel?()
  }
}

private struct FileTransferProgressView: View {
  @ObservedObject var model: FileTransferProgressModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("发送文件")
        .font(.headline)

      Text(model.statusText)
        .font(.callout)
        .lineLimit(1)

      if let progressValue = model.progressValue {
        ProgressView(value: progressValue)
          .progressViewStyle(.linear)
      } else {
        ProgressView()
          .progressViewStyle(.linear)
      }

      HStack {
        Text(model.detailText)
          .font(.caption)
          .foregroundStyle(.secondary)

        Spacer()

        Button("取消") {
          model.requestCancellation()
        }
        .disabled(model.isCancelling)
        .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .frame(width: 430)
  }
}

@MainActor
final class FileTransferProgressWindowController: NSWindowController {
  let model: FileTransferProgressModel

  init(model: FileTransferProgressModel) {
    self.model = model

    let contentViewController = NSHostingController(
      rootView: FileTransferProgressView(model: model)
    )
    let window = NSWindow(contentViewController: contentViewController)
    window.title = "BetterMenu 文件传输"
    window.styleMask = [.titled]
    window.isReleasedWhenClosed = false
    window.standardWindowButton(.zoomButton)?.isHidden = true
    window.standardWindowButton(.miniaturizeButton)?.isHidden = true

    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func show() {
    window?.center()
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }
}

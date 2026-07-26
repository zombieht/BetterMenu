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

  /// 显示进度窗口。
  ///
  /// 复制任务是由访达右键菜单以 `activates: false` 唤起的，用户预期停留在访达继续操作，
  /// 因此这里只把窗口置于前面而不激活 BetterMenu，避免抵消扩展侧刻意的不抢焦点设计。
  /// 用户点击窗口（例如“取消”按钮）时系统会自然地将其变为 key window。
  ///
  /// - Parameter cascadeIndex: 同时进行的第几个传输任务。传输任务支持并发，
  ///   若每个窗口都居中显示会完全重叠、用户无法分辨与操作，因此按序号阶梯式偏移。
  func show(cascadeIndex: Int = 0) {
    guard let window else { return }
    window.center()

    if cascadeIndex > 0 {
      let offset = Self.cascadeStep * CGFloat(cascadeIndex)
      var origin = window.frame.origin
      origin.x += offset
      origin.y -= offset

      // 偏移后若超出屏幕可见范围就回到居中位置，避免窗口跑到屏幕外。
      // 窗口尚未上屏时 `window.screen` 为 nil，此时以主屏为准。
      if let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame {
        let shiftedFrame = CGRect(origin: origin, size: window.frame.size)
        if visibleFrame.contains(shiftedFrame) {
          window.setFrameOrigin(origin)
        }
      } else {
        window.setFrameOrigin(origin)
      }
    }

    window.orderFrontRegardless()
  }

  /// 相邻两个并发传输窗口的偏移量。
  private static let cascadeStep: CGFloat = 28
}

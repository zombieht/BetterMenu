import SwiftUI

// MARK: - 设置页共享组件

struct PageHeader: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.title2.weight(.bold))
      if !subtitle.isEmpty {
        Text(subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }
}

struct SettingsRowHeader: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.headline)
      Text(subtitle)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct GlassSection<Content: View>: View {
  var maxHeight: CGFloat? = nil
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      content
    }
    .padding(13)
    .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .topLeading)
    .liquidGlassCard()
  }
}

struct GlassBackground: View {
  var body: some View {
    LinearGradient(
      colors: [
        Color(nsColor: .windowBackgroundColor),
        Color.blue.opacity(0.07),
        Color(nsColor: .windowBackgroundColor),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
    .ignoresSafeArea()
  }
}

// MARK: - 样式扩展

extension View {
  @ViewBuilder
  func liquidGlassCard() -> some View {
    self
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(.quaternary, lineWidth: 1)
      }
  }

  @ViewBuilder
  func glassButtonStyle(prominent: Bool = false) -> some View {
    if prominent {
      self.buttonStyle(.borderedProminent)
    } else {
      self.buttonStyle(.bordered)
    }
  }
}

// MARK: - 自适应水平流式布局

/// 让自定义后缀标签以紧凑间距自动折行排布，避免传统网格布局造成过大间距。
struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
    return result.size
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
    for (index, subview) in subviews.enumerated() {
      let point = result.positions[index]
      subview.place(
        at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
        proposal: .unspecified
      )
    }
  }

  /// 内部辅助计算结构体，用于编排元素位置与换行高度。
  private struct FlowResult {
    var size: CGSize = .zero
    var positions: [CGPoint] = []

    init(in maxWidth: CGFloat, subviews: LayoutSubviews, spacing: CGFloat) {
      var currentX: CGFloat = 0
      var currentY: CGFloat = 0
      var lineHeight: CGFloat = 0
      var width: CGFloat = 0

      for subview in subviews {
        let size = subview.sizeThatFits(.unspecified)
        if currentX + size.width > maxWidth && currentX > 0 {
          currentX = 0
          currentY += lineHeight + spacing
          lineHeight = 0
        }
        positions.append(CGPoint(x: currentX, y: currentY))
        lineHeight = max(lineHeight, size.height)
        currentX += size.width + spacing
        width = max(width, currentX)
      }
      size = CGSize(width: max(0, width - spacing), height: currentY + lineHeight)
    }
  }
}

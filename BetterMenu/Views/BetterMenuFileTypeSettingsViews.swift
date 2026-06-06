import Cocoa
import SwiftUI

// MARK: - 新建文件类型页面

struct FileTypesPage: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      PageHeader(title: "新建文件类型", subtitle: "")
      FileTypesCard()
      MenuPreviewCard()
    }
  }
}

struct FileTypesCard: View {
  @EnvironmentObject private var model: BetterMenuSettingsModel
  @State private var customExtension = ""

  var body: some View {
    GlassSection {
      VStack(alignment: .leading, spacing: 14) {
        FileTypeGroupView(
          title: "常用文件",
          icon: "doc.on.doc",
          iconColor: .blue,
          fileTypes: betterMenuFileTypes,
          model: model
        )

        Divider()

        HStack(spacing: 12) {
          Text("自定义后缀")
            .font(.callout.weight(.medium))
          TextField("输入扩展名，例如 js", text: $customExtension)
            .textFieldStyle(.roundedBorder)
            .onSubmit(addCustomExtension)
          Button("添加") {
            addCustomExtension()
          }
          .glassButtonStyle()
        }

        if !model.customExtensions.isEmpty {
          FlowLayout(spacing: 8) {
            ForEach(model.customExtensions, id: \.self) { fileExtension in
              CustomExtensionTag(fileExtension: fileExtension) {
                model.removeCustomExtension(fileExtension)
              }
            }
          }
          .transition(.opacity)
        }

        Text("勾选或添加的后缀将显示在 Finder 右键新建菜单中。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func addCustomExtension() {
    guard model.addCustomExtension(customExtension) else { return }
    customExtension = ""
  }
}

// MARK: - 文件类型分组视图

struct FileTypeGroupView: View {
  let title: String
  let icon: String
  let iconColor: Color
  let fileTypes: [FileDefinition]
  @ObservedObject var model: BetterMenuSettingsModel
  private let columns = [
    GridItem(.adaptive(minimum: 120), spacing: 10)
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: icon)
          .foregroundStyle(iconColor)
          .font(.system(size: 13, weight: .bold))
        Text(title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
      }

      LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
        ForEach(fileTypes) { type in
          FileTypeGridItem(
            type: type,
            isEnabled: Binding(
              get: { model.enabledFileTypes.contains(type.id) },
              set: { model.setFileType(type.id, enabled: $0) }
            )
          )
        }
      }
    }
  }
}

// MARK: - 文件类型紧凑网格项

struct FileTypeGridItem: View {
  let type: FileDefinition
  @Binding var isEnabled: Bool

  var body: some View {
    HStack(spacing: 8) {
      FileTypeIconView(fileTypeId: type.id)
        .frame(width: 18, height: 18)

      Toggle(isOn: $isEnabled) {
        Text(type.title)
          .font(.system(size: 12))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
      }
      .toggleStyle(.checkbox)
    }
    .padding(.horizontal, 10)
    .frame(height: 32)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color.secondary.opacity(0.04),
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
  }
}

// MARK: - 文件类型图标视图

struct FileTypeIconView: View {
  let fileTypeId: String

  var body: some View {
    if let image = BetterMenuIcon.icon(for: fileTypeId, size: NSSize(width: 18, height: 18)) {
      Image(nsImage: image)
        .resizable()
        .aspectRatio(contentMode: .fit)
    } else {
      Image(systemName: "doc")
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - 自定义后缀标签

struct CustomExtensionTag: View {
  let fileExtension: String
  let onRemove: () -> Void
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 6) {
      FileTypeIconView(fileTypeId: "custom.\(fileExtension)")
        .frame(width: 14, height: 14)

      Text(".\(fileExtension)")
        .font(.callout.weight(.medium))

      if isHovered {
        Button(action: onRemove) {
          Image(systemName: "xmark")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(3)
            .background(Color.red.opacity(0.8), in: Circle())
        }
        .buttonStyle(.plain)
        .transition(
          .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.8)), removal: .opacity)
        )
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      isHovered ? Color.secondary.opacity(0.10) : Color.secondary.opacity(0.05), in: Capsule()
    )
    .overlay {
      Capsule()
        .stroke(
          isHovered ? Color.secondary.opacity(0.18) : Color.secondary.opacity(0.08), lineWidth: 1
        )
    }
    .onHover { hover in
      withAnimation(.snappy(duration: 0.15)) {
        isHovered = hover
      }
    }
  }
}

// MARK: - 菜单预览

struct MenuPreviewCard: View {
  @EnvironmentObject private var model: BetterMenuSettingsModel

  var body: some View {
    GlassSection {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 6) {
          Text("菜单预览与排序")
            .font(.headline)
          Text("已启用 \(model.menuPreviewItems.count) 项。按住并拖动下列文件类型可以微调其在 Finder 一级菜单中的显示顺序。")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        if model.menuPreviewItems.isEmpty {
          emptyPreview
        } else {
          previewList
        }
      }
    }
  }

  private var emptyPreview: some View {
    HStack {
      Spacer()
      VStack(spacing: 8) {
        Image(systemName: "doc.badge.plus")
          .font(.system(size: 24))
          .foregroundStyle(.secondary)
        Text("暂无启用的新建类型")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .frame(minHeight: 180)
  }

  private var previewList: some View {
    List {
      ForEach(model.menuPreviewItems) { item in
        PreviewMenuRow(item: item)
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
          .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
      }
      .onMove { source, destination in
        model.moveMenuPreviewItem(from: source, to: destination)
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .frame(height: CGFloat(model.menuPreviewItems.count) * 48)
  }
}

struct PreviewMenuRow: View {
  let item: MenuPreviewItem

  var body: some View {
    HStack(spacing: 12) {
      FileTypeIconView(fileTypeId: item.id)
        .frame(width: 18, height: 18)

      Text(item.title)
        .font(.callout)
        .lineLimit(1)
        .foregroundStyle(.primary)

      Spacer()

      Image(systemName: "line.3.horizontal")
        .font(.caption)
        .foregroundStyle(.secondary.opacity(0.6))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: 36)
    .padding(.horizontal, 14)
    .background(
      Color.secondary.opacity(0.04),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
  }
}

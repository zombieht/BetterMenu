import Cocoa
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 通用设置页面

struct GeneralSettingsPage: View {
  @EnvironmentObject private var model: BetterMenuSettingsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      PageHeader(title: "通用设置", subtitle: "")

      GlassSection {
        HStack(alignment: .center) {
          VStack(alignment: .leading, spacing: 4) {
            Text("开机自启动")
              .font(.headline)
            Text("登录 macOS 时自动启动 BetterMenu，在后台持续提供访达右键增强服务。")
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
          Toggle("", isOn: $model.launchAtLogin)
            .toggleStyle(.switch)
            .controlSize(.small)
        }
      }

      GlassSection {
        DisplayModeSettingsRow()
      }

      GlassSection {
        QuickAccessSettingsCard()
      }
    }
  }
}

// MARK: - 显示模式设置行

struct DisplayModeSettingsRow: View {
  @EnvironmentObject private var model: BetterMenuSettingsModel

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("显示方式")
          .font(.headline)
        Text("选择应用图标在系统中的呈现位置。")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      Picker("", selection: displayModeBinding) {
        ForEach(BetterMenuDisplayMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: 200)
    }
  }

  private var displayModeBinding: Binding<BetterMenuDisplayMode> {
    Binding(
      get: { model.displayMode },
      set: { model.requestDisplayModeChange($0) }
    )
  }
}

// MARK: - 右键快捷操作设置

struct QuickAccessSettingsCard: View {
  @EnvironmentObject private var model: BetterMenuSettingsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center) {
        SettingsRowHeader(
          title: "右键操作",
          subtitle: "拖动可调整顺序。"
        )

        Spacer(minLength: 16)
        addActionMenu
      }

      List {
        ForEach(model.actions) { action in
          FinderActionSettingsRow(
            action: action,
            isEnabled: actionEnabledBinding(for: action),
            isInstalled: model.isActionInstalled(action.id),
            onRemove: canRemove(action)
              ? {
                model.removeEditorAction(id: action.id)
              } : nil
          )
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
          .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
        }
        .onMove { source, destination in
          model.moveAction(from: source, to: destination)
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .scrollDisabled(true)
      .frame(height: CGFloat(model.actions.count) * 64)
    }
  }

  private var addActionMenu: some View {
    Menu {
      if !model.installedEditorsToImport.isEmpty {
        Section("推荐工具（已安装）") {
          ForEach(model.installedEditorsToImport, id: \.idString) { editor in
            Button(editor.name) {
              model.addEditorAction(editor)
            }
          }
        }
      }

      if !model.uninstalledEditorsToImport.isEmpty {
        Section("推荐工具（未检测到）") {
          ForEach(model.uninstalledEditorsToImport, id: \.idString) { editor in
            Button("\(editor.name) (未检测到)") {
              model.addEditorAction(editor)
            }
          }
        }
      }

      Divider()

      Button {
        selectCustomAppFromDisk()
      } label: {
        Label("从磁盘手动选择...", systemImage: "folder")
      }
    } label: {
      Label("添加软件", systemImage: "plus.circle")
        .font(.callout.weight(.medium))
    }
    .menuStyle(.button)
    .buttonStyle(.bordered)
  }

  private func actionEnabledBinding(for action: FinderAction) -> Binding<Bool> {
    Binding(
      get: { model.actions.first(where: { $0.id == action.id })?.isEnabled ?? false },
      set: { newValue in
        guard let index = model.actions.firstIndex(where: { $0.id == action.id }) else { return }
        model.actions[index].isEnabled = newValue
      }
    )
  }

  private func canRemove(_ action: FinderAction) -> Bool {
    action.id != "terminal" && action.id != "copyPath"
  }

  /// 弹出原生打开面板让用户手动选择可添加到 Finder 右键菜单的应用程序。
  private func selectCustomAppFromDisk() {
    let openPanel = NSOpenPanel()
    openPanel.title = "选择应用程序"
    openPanel.allowedContentTypes = [.application]
    openPanel.allowsMultipleSelection = false
    openPanel.canChooseDirectories = false
    openPanel.canChooseFiles = true
    openPanel.directoryURL = URL(fileURLWithPath: "/Applications")

    openPanel.begin { response in
      guard response == .OK, let url = openPanel.url else { return }
      _ = model.addCustomApplicationAction(fromUrl: url)
    }
  }
}

// MARK: - 动态快捷操作图标组件

struct ActionIconView: View {
  let action: FinderAction
  let isInstalled: Bool

  var body: some View {
    if action.id == "terminal" || action.id == "copyPath" {
      Image(systemName: action.iconName)
        .font(.system(size: 15, weight: .regular))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(isInstalled ? .primary : .secondary)
        .frame(width: 24, height: 30)
    } else if let image = getAppIcon(for: action.id) {
      Image(nsImage: image)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 22, height: 22)
        .opacity(isInstalled ? 1.0 : 0.5)
        .frame(width: 24, height: 30)
    } else {
      Image(systemName: action.iconName)
        .font(.system(size: 15, weight: .regular))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(isInstalled ? .primary : .secondary)
        .frame(width: 24, height: 30)
    }
  }

  private func getAppIcon(for id: String) -> NSImage? {
    let appUrl: URL?
    if let editor = BetterMenuShared.supportedEditors.first(where: { $0.idString == id }) {
      appUrl =
        editor.bundleIds.lazy.compactMap {
          NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }.first
    } else {
      appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    guard let appUrl else { return nil }
    return NSWorkspace.shared.icon(forFile: appUrl.path)
  }
}

// MARK: - Finder 快捷操作行

struct FinderActionSettingsRow: View {
  @EnvironmentObject private var model: BetterMenuSettingsModel
  let action: FinderAction
  @Binding var isEnabled: Bool
  let isInstalled: Bool
  var onRemove: (() -> Void)? = nil

  @State private var isHovered = false

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      ActionIconView(action: action, isInstalled: isInstalled)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(action.title)
            .font(.callout.weight(.medium))
            .foregroundStyle(isInstalled ? .primary : .secondary)
            .lineLimit(1)
          if !isInstalled {
            Text("未检测到")
              .font(.system(size: 10))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
          }
        }
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 12)

      if let onRemove, isHovered {
        Button(action: onRemove) {
          Image(systemName: "trash")
            .font(.system(size: 12))
            .foregroundStyle(.red)
            .padding(6)
            .background(Color.red.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
      }

      if action.id == "terminal" && isEnabled {
        Picker("", selection: $model.terminalType) {
          ForEach(model.installedTerminals) { app in
            Text(app.name).tag(app.id)
          }
        }
        .pickerStyle(.menu)
        .frame(width: 150)
        .labelsHidden()
      }

      Toggle("", isOn: $isEnabled)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)

      Image(systemName: "line.3.horizontal")
        .font(.caption)
        .foregroundStyle(.secondary.opacity(0.55))
    }
    .frame(height: 46)
    .padding(.horizontal, 12)
    .background(
      Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .onHover { hover in
      withAnimation(.snappy(duration: 0.15)) {
        isHovered = hover
      }
    }
  }

  private var description: String {
    switch action.id {
    case "terminal":
      return "在当前 Finder 目录启动终端。"
    case "copyPath":
      return "复制当前目录或选中项目路径。"
    default:
      return editorDescription ?? "在当前 Finder 目录中打开。"
    }
  }

  private var editorDescription: String? {
    if let editor = BetterMenuShared.supportedEditors.first(where: { $0.idString == action.id }) {
      return "用 \(editor.name) 打开当前位置。"
    }

    guard
      let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: action.id),
      let bundle = Bundle(url: appUrl)
    else {
      return nil
    }

    let name =
      bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
      ?? appUrl.deletingPathExtension().lastPathComponent
    return "用 \(name) 打开当前位置。"
  }
}

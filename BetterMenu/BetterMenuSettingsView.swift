import SwiftUI

// MARK: - 设置页分类

enum SettingsPage: String, CaseIterable, Identifiable {
  case general
  case permissions
  case fileTypes
  case about

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: return "通用"
    case .permissions: return "权限与扩展"
    case .fileTypes: return "新建文件类型"
    case .about: return "关于"
    }
  }

  var systemImage: String {
    switch self {
    case .general: return "gearshape"
    case .permissions: return "puzzlepiece.extension"
    case .fileTypes: return "doc.text"
    case .about: return "info.circle"
    }
  }
}

// MARK: - 设置主界面

struct BetterMenuSettingsView: View {
  @ObservedObject private var model: BetterMenuSettingsModel
  @State private var selection: SettingsPage? = .general
  private let sidebarWidth: CGFloat = 210
  private let detailMinWidth: CGFloat = 540
  private let detailMaxWidth: CGFloat = 920

  init(model: BetterMenuSettingsModel) {
    _model = ObservedObject(wrappedValue: model)
  }

  var body: some View {
    HStack(spacing: 0) {
      sidebar
        .frame(width: sidebarWidth)
        .fixedSize(horizontal: true, vertical: false)
      Divider()
      ScrollView {
        selectedPage
          .padding(.horizontal, 22)
          .padding(.vertical, 18)
          .frame(maxWidth: detailMaxWidth, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .center)
      }
      .scrollIndicators(.automatic)
      .frame(
        minWidth: detailMinWidth,
        maxWidth: .infinity,
        maxHeight: .infinity,
        alignment: .topLeading
      )
      .scrollContentBackground(.hidden)
      .background(
        GlassBackground()
          .gesture(WindowDragGesture())
      )
    }
    .frame(minWidth: sidebarWidth + detailMinWidth + 1, minHeight: 550)
    .environmentObject(model)
  }

  private var sidebar: some View {
    ZStack {
      GlassBackground()
        .gesture(WindowDragGesture())

      // 顶部留空以避开窗口控制按钮区域。
      List(SettingsPage.allCases, selection: $selection) { page in
        Label(page.title, systemImage: page.systemImage)
          .font(.body.weight(.regular))
          .tag(page)
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .padding(.top, 52)
      .padding(.horizontal, 10)
      .padding(.bottom, 10)
    }
  }

  @ViewBuilder
  private var selectedPage: some View {
    switch selection ?? .general {
    case .general:
      GeneralSettingsPage()
    case .permissions:
      PermissionsPage()
    case .fileTypes:
      FileTypesPage()
    case .about:
      AboutPage()
    }
  }
}

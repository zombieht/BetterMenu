import SwiftUI

// MARK: - 权限与扩展管理页面

struct PermissionsPage: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      PageHeader(title: "权限与扩展", subtitle: "")
      PermissionStatusCard()
      FinderRestartCard()
    }
  }
}

struct PermissionStatusCard: View {
  @EnvironmentObject private var model: BetterMenuSettingsModel

  var body: some View {
    let status = model.extensionStatus

    GlassSection {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .center, spacing: 16) {
          SettingsStatusRow(
            title: "系统扩展权限",
            message: status.description,
            badgeTitle: status.badgeTitle,
            badgeTint: status.tint
          )

          Button("重新检查") {
            model.refreshExtensionStatus()
          }
          .glassButtonStyle()

          Button("打开扩展设置") {
            model.openExtensionSettings()
          }
          .glassButtonStyle()
        }
      }
    }
  }
}

// MARK: - 设置状态行

struct SettingsStatusRow: View {
  let title: String
  let message: String
  let badgeTitle: String
  let badgeTint: Color

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.headline)
        Text(message)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)

      Text(badgeTitle)
        .font(.caption.weight(.semibold))
        .foregroundStyle(badgeTint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(badgeTint.opacity(0.12), in: Capsule())
    }
  }
}

struct FinderRestartCard: View {
  @EnvironmentObject private var model: BetterMenuSettingsModel

  var body: some View {
    GlassSection {
      HStack(alignment: .center, spacing: 16) {
        VStack(alignment: .leading, spacing: 5) {
          Text("重启访达")
            .font(.headline)
          Text("仅刷新 Finder 进程以重新加载右键菜单，不会重启 BetterMenu 应用。")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer()

        Button(model.isRestartingFinder ? "正在重启" : "重启访达") {
          model.restartFinder()
        }
        .disabled(model.isRestartingFinder)
        .glassButtonStyle(prominent: true)
      }
    }
  }
}

// MARK: - 关于页面

struct AboutPage: View {
  @EnvironmentObject private var model: BetterMenuSettingsModel
  private let projectUrl = URL(string: "https://github.com/zombieht/BetterMenu")

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      PageHeader(title: "关于", subtitle: "BetterMenu 让 Finder 右键功能更加实用、更顺手。")

      GlassSection {
        HStack(alignment: .center, spacing: 18) {
          Image("AppLogo")
            .resizable()
            .frame(width: 64, height: 64)
            .shadow(radius: 6, y: 3)

          VStack(alignment: .leading, spacing: 8) {
            Text("BetterMenu")
              .font(.title2.weight(.bold))
            Text("版本 v\(model.appVersion)")
              .font(.callout.weight(.medium))
              .foregroundStyle(.secondary)
          }

          Spacer()

          HStack(spacing: 12) {
            Button {
              AppDelegate.shared?.checkForUpdates()
            } label: {
              Label("检查更新", systemImage: "arrow.down.circle")
            }
            .glassButtonStyle()

            if let projectUrl {
              Link(destination: projectUrl) {
                Label("开源主页", systemImage: "arrow.up.right")
              }
              .glassButtonStyle(prominent: true)
            }
          }
        }
      }

      GlassSection {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: "info.circle")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.blue)
            .padding(.top, 2)

          VStack(alignment: .leading, spacing: 4) {
            Text("声明")
              .font(.headline)
            Text("BetterMenu 是免费开源项目，请在遵守相关法律法规与开源协议的前提下使用。")
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }
}

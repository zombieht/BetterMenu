# BetterMenu 开发与架构指南

本页面详细记录了 **BetterMenu** 项目的系统架构、目录结构和开发维护规范。在您开始编写代码或提交 Pull Request 之前，请务必阅读本指南。

👈 [返回用户使用说明 (README.md)](./README.md)

---

## 🏗 开发与架构规范

为了保持项目的可维护性，开发时请遵循以下规范：

### 项目结构

```text
BetterMenu/
  AppDelegate.swift              # 主应用生命周期、窗口和 URL Scheme 路由
  BetterMenuSettingsModel.swift  # 设置页 UI 状态绑定与业务分发
  BetterMenuSettingsView.swift   # SwiftUI 设置界面容器与侧边栏导航
  BetterMenuGeneralSettingsViews.swift    # 通用设置与右键快捷操作页面
  BetterMenuFileTypeSettingsViews.swift   # 新建文件类型、后缀标签与菜单预览
  BetterMenuPermissionAboutViews.swift    # 权限、Finder 重启与关于页面
  BetterMenuSettingsComponents.swift      # 设置页共享 UI 组件与流式布局
  BetterMenuShared.swift         # 共享核心：统一 FileDefinition、全局 constants 与公共映射函数
  ExternalAppLauncher.swift      # 终端、VS Code 等外部应用一键拉起服务
  TerminalApp.swift              # 可选终端应用定义列表
  SystemCommand.swift            # 底层命令行调用 Process 进程运行封装
  IconCacheManager.swift         # 专职后台图标渲染、预热与序列化磁盘缓存服务

BetterMenuFinderSync/
  FinderSync.swift               # Finder Sync 扩展入口、上下文交互与菜单组装（极简 Controller）
  SettingsMonitor.swift          # 共享偏好 plist 文件的加载、只读配置快照维护与 DispatchSource 监听
  MenuIconManager.swift          # 磁盘缓存图标加载、SF Symbol 深浅色重绘与内存渲染二级缓存
  FileCreator.swift              # 物理文件落盘、防文件名冲突算法计算与可执行权限设置
  Resources/Templates/           # Word/Excel/PPTX 内置空白二进制模板文件
```

### 共享配置机制

主 App 与 FinderSync 扩展运行在不同的进程中，二者通过用户主目录下的 plist 文件共享偏好配置：
- **偏好设置路径**：`~/Library/Application Support/BetterMenu/settings.plist`
- **图标缓存路径**：`~/Library/Caches/BetterMenu/icon_cache.plist`

共享数据模型 `FileDefinition`、`FinderAction` 和键名统一在 `BetterMenuShared.swift` 中管理。新增需要两个 Target 同时读取的数据定义时，必须直接归入共享层。

### 结构维护规范

- **主应用入口保持轻量**：`AppDelegate` 仅处理生命周期分发、AppKit 激活策略以及 URL Scheme 路由。
- **ViewModel 高度内聚**：`BetterMenuSettingsModel` 只做数据和 UI 绑定，底层任务（如图标预热、System 进程命令）一律剥离成独立业务服务（如 `IconCacheManager`，`SystemCommand`）。
- **FinderSync 扩展轻量化**：`FinderSync` 类仅扮演控制器角色。偏好读取与目录监听由 `SettingsMonitor` 托管，图标解析与渲染由 `MenuIconManager` 托管，文件生成由 `FileCreator` 托管。
- **Swift 6 Concurrency 并发安全**：编写异步或跨 Target 通信的工具类时，必须按照 Swift 6 安全规范进行严格类型隔离，或使用锁机制辅以 `nonisolated(unsafe)` 消除编译警告。
- **Xcode 项目同步**：新增 Swift 源文件后，必须同步注册在 `BetterMenu.xcodeproj/project.pbxproj` 对应的 Target 编译阶段。
- **文档维护**：更改项目行为、扩展逻辑或业务边界时，必须同步修改本指南及 `README.md`。

---

## 🔁 软件更新与自动化发布 (Sparkle)

本项目集成了 **Sparkle 2** 自动更新框架。在您正式发布软件前，需要在本地生成一对 Ed25519 密钥：

### 1. 零依赖生成密钥对
您可以使用以下任意一种无需下载额外依赖包的命令在终端生成密钥：

* **使用 Swift & CryptoKit（推荐，macOS 自带）**：
  ```bash
  swift -e '
  import CryptoKit
  import Foundation
  let privateKey = Curve25519.Signing.PrivateKey()
  print("SUPublicEDKey (写入 Info.plist):\n\(privateKey.publicKey.rawRepresentation.base64EncodedString())")
  print("\nSUPrivateEDKey (写入 GitHub Secrets):\n\(privateKey.rawRepresentation.base64EncodedString())")
  '
  ```
* **使用 OpenSSL（macOS 自带）**：
  ```bash
  openssl genpkey -algorithm ED25519 -out private.pem && \
  echo "SUPublicEDKey (写入 Info.plist):" && \
  openssl pkey -in private.pem -pubout -outform DER | tail -c 32 | base64 && \
  echo "SUPrivateEDKey (写入 GitHub Secrets):" && \
  openssl pkey -in private.pem -outform DER | tail -c 32 | base64 && \
  rm private.pem
  ```

### 2. 配置与发布步骤
1. **配置公钥**：将生成的 **`SUPublicEDKey`（公钥）** 填入项目中的 `BetterMenu/Info.plist` 的 `SUPublicEDKey` 键值中。
2. **配置私钥**：将生成的 **`SUPrivateEDKey`（私钥）** 配置到您的 GitHub 仓库的 Secrets 中，变量名设置为 `SPARKLE_PRIVATE_KEY`。
3. **触发自动化部署**：每次推送以 `v` 开头的 Tag（如 `v1.0.1`），GitHub Actions 工作流将自动使用此私钥对应用包进行签名，生成描述文件 `appcast.xml`，并随 Release 一同分发。客户端将通过 `https://github.com/zombieht/BetterMenu/releases/latest/download/appcast.xml` 获取最新的更新信息并下载安全的更新包。


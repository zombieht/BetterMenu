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
  main.swift                     # 主应用入口点
  BetterMenuShared.swift         # 共享核心：统一 FileDefinition、全局 constants 与公共映射函数
  BetterMenuSecureRequest.swift  # 一次性安全请求的数据模型、原子写入、校验与消费（三 Target 共享的安全边界）
  Models/
    BetterMenuSettingsModel.swift  # 设置页 UI 状态绑定与业务分发
  Views/
    BetterMenuSettingsView.swift   # SwiftUI 设置界面容器与侧边栏导航
    BetterMenuGeneralSettingsViews.swift    # 通用设置与右键快捷操作页面
    BetterMenuFileTypeSettingsViews.swift   # 新建文件类型、后缀标签与菜单预览
    BetterMenuPermissionAboutViews.swift    # 权限、Finder 重启与关于页面
    BetterMenuSettingsComponents.swift      # 设置页共享 UI 组件与流式布局
  Services/
    AppleScriptPathArgument.swift  # AppleScript 文件路径安全编码，防止路径改变脚本语法
    ExternalAppLauncher.swift      # 终端、VS Code 等外部应用一键拉起服务
    FileTransferService.swift      # 隔空投送与后台复制任务生命周期调度
    FileTransferOperations.swift   # copyfile 复制、字节进度、取消、重名与失败清理
    FileTransferProgressWindow.swift  # 文件传输进度和取消窗口
    TerminalApp.swift              # 可选终端应用定义列表
    SystemCommand.swift            # 底层命令行调用 Process 进程运行封装
    IconCacheManager.swift         # 专职后台图标渲染、预热与序列化磁盘缓存服务

BetterMenuFinderSync/
  FinderSync.swift               # Finder Sync 扩展入口、上下文交互与菜单组装（极简 Controller）
  SettingsMonitor.swift          # 共享偏好 plist 文件的加载、只读配置快照维护与变更作废
  MenuIconManager.swift          # 磁盘缓存图标加载、SF Symbol 深浅色重绘与内存渲染二级缓存
  DirectoryChangeMonitor.swift   # 目录级 DispatchSource 监听封装，供设置与图标缓存复用
  FileCreator.swift              # 物理文件落盘、防文件名冲突算法计算与可执行权限设置
  Resources/Templates/           # Word/Excel/PPTX 内置空白二进制模板文件

BetterMenuTests/
  BetterMenuSecurityTests.swift  # 一次性请求、URL 路由、AppleScript 路径与设置迁移测试
  BetterMenuCoreServiceTests.swift  # 文件创建、复制进度、取消与路径边界测试
```

### 共享配置机制

主 App 与 FinderSync 扩展运行在不同的进程中，二者通过用户主目录下的 plist 文件共享偏好配置：
- **偏好设置路径**：`~/Library/Application Support/BetterMenu/settings.plist`
- **图标缓存路径**：`~/Library/Caches/BetterMenu/icon_cache.plist`
- **一次性请求目录**：`~/Library/Application Support/BetterMenu/Requests/`

共享数据模型 `FileDefinition`、`FinderAction` 和键名统一在 `BetterMenuShared.swift` 中管理。新增需要两个 Target 同时读取的数据定义时，必须直接归入共享层，禁止在调用方重复定义常量或硬编码字面量。自定义菜单 ID 只能通过 `BetterMenuShared.customMenuId(for:)` 与 `customExtension(fromMenuId:)` 构造与解析，菜单图标尺寸统一取 `BetterMenuShared.menuIconSize`（图标缓存按此尺寸预渲染，两侧取值不一致会导致缓存图标被系统再次缩放而模糊）。

### Finder 扩展安全请求机制

Finder 扩展不得通过 URL Scheme 直接传递动作 ID、源文件路径或目标路径。扩展会先将请求写入权限为 `0600` 的一次性 plist 文件，再使用仅包含随机 UUID 的 `bettermenu://request?id=...` 链接唤起主应用。

主应用消费请求前会验证请求目录与文件所有者、POSIX 权限、文件类型、大小、协议版本、路径格式和 30 秒有效期。请求文件在读取时立即从目录移除，防止重放。旧版 `run-action`、`send-files` 和 `open-terminal` 明文参数路由不再接受。

该机制的数据模型与实现集中在 `BetterMenu/BetterMenuSecureRequest.swift`，与其余共享定义分离，便于单独审查这条安全边界。

### 结构维护规范

- **主应用入口保持轻量**：`AppDelegate` 仅处理生命周期分发、AppKit 激活策略以及 URL Scheme 路由。
- **ViewModel 高度内聚**：`BetterMenuSettingsModel` 只做数据和 UI 绑定，底层任务（如图标预热、System 进程命令）一律剥离成独立业务服务（如 `IconCacheManager`，`SystemCommand`）。
- **FinderSync 扩展轻量化**：`FinderSync` 类仅扮演控制器角色。偏好读取由 `SettingsMonitor` 托管，图标解析与渲染由 `MenuIconManager` 托管，文件生成由 `FileCreator` 托管。两者的目录监听统一复用 `DirectoryChangeMonitor`：主应用是先同步写 `settings.plist`、再异步预热 `icon_cache.plist`，因此设置目录与缓存目录必须各自独立监听，否则扩展会在新图标落盘前就重新加载缓存，菜单里持续显示 SF Symbol 占位图。共享文件均为原子写（临时文件 + rename），监听对象只能是父目录而非文件本身；缓存目录可能被系统或清理脚本删除，监听器必须在目录重建后自动恢复订阅。
- **文件发送链路**：FinderSync 只负责读取当前选择、发现已挂载可写卷并构造菜单；隔空投送与文件复制通过 URL Scheme 交给主应用的 `FileTransferService` 执行，避免大文件任务依赖扩展进程生命周期。`FileTransferOperations` 使用系统 `copyfile` 回调提供字节进度和复制中取消，复制目标仅允许已挂载的非内部可写卷，发生重名时生成递增后缀，取消或失败时清理未完成项目，任务完成后由访达定位结果。统计目录体积同样必须响应取消（大目录枚举耗时很久），失败项目也要计入进度分子（否则部分失败时进度条永远到不了 100%），失败原因需经 `errorMessage(for:)` 转成中文。传输任务支持并发：`FileTransferService` 按任务 id 分别持有隔空投送的 `NSSharingService` 与其 delegate（面板异步关闭前不能提前释放），进度窗口按 `show(cascadeIndex:)` 阶梯错开。复制任务由扩展以 `activates: false` 唤起，进度窗口只能 `orderFrontRegardless()`，不得调用 `NSApp.activate()` 抢占前台。
- **Swift 6 Concurrency 并发安全**：编写异步或跨 Target 通信的工具类时，必须按照 Swift 6 安全规范进行严格类型隔离，或使用锁机制辅以 `nonisolated(unsafe)` 消除编译警告。
- **Xcode 项目同步**：新增 Swift 源文件后，必须同步注册在 `BetterMenu.xcodeproj/project.pbxproj` 对应的 Target 编译阶段。
- **代码风格由 `swift-format` 门禁**：规则见仓库根目录 `.swift-format`（2 空格缩进、100 列、导入按字典序）。`swift-format` 随 Xcode 提供，无需额外安装依赖。提交前执行 `./script/build_and_run.sh format` 自动修正，或用 `lint` 动作只做检查；CI 会以 `--strict` 校验，任何风格告警都会让流水线失败。
- **文档维护**：更改项目行为、扩展逻辑或业务边界时，必须同步修改本指南及 `README.md`。

---

## ✅ 自动化测试

运行全部单元测试：

```bash
xcodebuild \
  -project BetterMenu.xcodeproj \
  -scheme BetterMenu \
  -configuration Debug \
  -destination 'platform=macOS' \
  test
```

`BetterMenuTests` 是无宿主单元测试 Target。共享 Scheme 在测试动作中只构建测试 Target，不构建或注册 `BetterMenu.app` 与 Finder Sync 扩展。不要重新启用主 App 或扩展的 `buildForTesting`，否则本地测试产物会出现在“登录项与扩展”中。

构建主 App 或 Finder Sync 扩展时必须固定复用项目 `DerivedData` 或 Xcode 默认路径中的一种，不得混用或为同一工作区创建多个临时 DerivedData 路径。`build_and_run.sh` 默认增量编译以复用该 `DerivedData`，需要全量重建时显式传入 `--clean`（`--clean-cache` 另行清空运行缓存）。`build_and_run.sh clean` 会在清理构建产物前注销开发扩展，`package.sh` 会在打包结束后注销临时 Release 产物。

GitHub Actions 会在打包前执行代码风格检查与同一组测试，并检查测试产物中没有 `BetterMenu.app` 或 `BetterMenuFinderSync.appex`，防止 Scheme 配置回退。安全通信或 AppleScript 路径处理发生变化时，必须同步补充 `BetterMenuSecurityTests`；文件创建、复制、进度或取消逻辑发生变化时，必须同步补充 `BetterMenuCoreServiceTests`。

测试结果会以 `.xcresult` 包上传为 `BetterMenu-TestResults` 工件（无论成败），打包日志上传为 `BetterMenu-BuildLog`，均保留 14 天。排查 CI 失败时优先下载这两个工件，而不是只看日志尾部输出。


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

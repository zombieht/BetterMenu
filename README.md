# BetterMenu

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS-blue.svg" alt="Platform: macOS" />
  <img src="https://img.shields.io/badge/Swift-6.0+-orange.svg" alt="Swift: 6.0+" />
  <img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License: MIT" />
</p>

BetterMenu 是一款功能强大的 macOS 右键菜单增强工具，让macOS的右键菜单像windows一样好用。

---
## 安装说明
安装完成后遇到“无法打开，因为无法确认开发者身份”：
- 常规方法：前往 系统设置 -> 隐私与安全性，滑动到最下方，找到安全性提示并点击 仍要打开 (Open Anyway)。
- 快捷命令：直接在终端运行以下命令移除隔离属性：
xattr -cr /Applications/BetterMenu.app

## ✨ 核心功能

- 📂 **快速新建文件**：
  - 支持快捷新建 `txt`、`md`、`docx`、`xlsx`、`pptx`、`json`、`py`、`html`、`sh` 等文件。
  - 支持自定义新建文件的后缀扩展名，灵活扩展。
- 💻 **快速在终端/编辑器中打开**：
  - 支持系统自带终端（Terminal）。
  - 支持主流代码编辑器一键拉起：**VS Code**、**Cursor**、**OpenAI Codex**、**Xcode**、**Sublime Text**、**IntelliJ IDEA**、**WebStorm**、**PyCharm**、**Android Studio**、**CotEditor**。
- 📋 **一键复制路径**：
  - 快速复制当前访达目录或选中文件的绝对路径。
- ⚙️ **SwiftUI 设置面板**：
  - 现代化、清爽的设置界面，支持调整右键菜单项的启用状态与排序，即时同步生效。

---

## 📦 系统要求

- **操作系统**：macOS 15.0 或更高版本
- **开发工具**：Xcode 16.0+
- **Swift 语言模式**：Swift 6.0+

---

## 🚀 构建与运行

在本地克隆代码后，可通过项目内提供的脚本进行便捷的构建与管理。

### 本地开发运行
编译、运行主 App 并自动注册 Finder Sync 扩展：
```bash
./script/build_and_run.sh run
```

### 仅构建并注册扩展
如果只需重新注册 Finder Sync 扩展，可执行：
```bash
./script/build_and_run.sh register
```

### Release 打包
生成生产环境发布包（DMG/ZIP）：
```bash
./script/package.sh
```


---

## 🛠 开发与架构规范

为了保持项目的可维护性，开发时请遵循以下规范：

### 项目结构

```text
BetterMenu/
  AppDelegate.swift              # 主应用生命周期、窗口和 URL Scheme 路由
  BetterMenuSettingsModel.swift  # 设置页 UI 状态绑定与业务分发（已瘦身）
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
- 偏好设置路径：`~/Library/Application Support/BetterMenu/settings.plist`
- 图标缓存路径：`~/Library/Caches/BetterMenu/icon_cache.plist`

共享数据模型 `FileDefinition`、`FinderAction` 和键名统一在 `BetterMenuShared.swift` 中管理。新增需要两个 target 同时读取的数据定义时，必须直接归入共享层。

### 结构维护规范
- **主应用入口保持轻量**：`AppDelegate` 仅处理生命周期分发、AppKit 激活策略以及 URL Scheme 路由。
- **ViewModel 高度内聚**：`BetterMenuSettingsModel` 只做数据和 UI 绑定，底层任务（如图标预热、System 进程命令）一律剥离成独立业务服务（如 `IconCacheManager`，`SystemCommand`）。
- **FinderSync 扩展轻量化**：`FinderSync` 类仅扮演控制器角色。偏好读取与目录监听由 `SettingsMonitor` 托管，图标解析与渲染由 `MenuIconManager` 托管，文件生成由 `FileCreator` 托管。
- **Swift 6 Concurrency 并发安全**：编写异步或跨 Target 通信的工具类时，必须按照 Swift 6 安全规范进行严格类型隔离，或使用锁机制辅以 `nonisolated(unsafe)` 消除编译警告。
- **Xcode 项目同步**：新增 Swift 源文件后，必须同步注册在 `BetterMenu.xcodeproj/project.pbxproj` 对应的 target 编译阶段。
- **文档维护**：更改项目行为、扩展逻辑或业务边界时，必须同步修改本文档。

---

## 🤝 鸣谢

本项目在设计与开发过程中借鉴了以下优秀开源项目，在此表示衷心的感谢：

- [QuickDoc](https://github.com/SkyImplied/QuickDoc)：为本项目提供了菜单构建与功能设计上的灵感与借鉴。

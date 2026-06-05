#!/usr/bin/env bash
# ==============================================================================
# BetterMenu 构建、注册与运行脚本
# Google Shell 编程规范
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. 默认配置与路径定义
# ------------------------------------------------------------------------------
APP_NAME="BetterMenu"
EXTENSION_NAME="BetterMenuFinderSync"
BUNDLE_ID="com.zombie.BetterMenu"
EXTENSION_BUNDLE_ID="$BUNDLE_ID.FinderSync"
PROJECT_NAME="BetterMenu.xcodeproj"
SCHEME_NAME="BetterMenu"
CONFIGURATION="Debug"

# 获取项目根目录 (绝对路径)
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 注册扩展工具的常用路径
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

# 构建产物存放路径
DERIVED_DATA_PATH="$ROOT_DIR/DerivedData"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
APP_EXTENSION="$APP_BUNDLE/Contents/PlugIns/$EXTENSION_NAME.appex"

# 命令行标志默认值
NO_BUILD=false
NO_RESTART_FINDER=false
CLEAN=true
CLEAN_CACHE=true

# ------------------------------------------------------------------------------
# 2. 日志输出工具函数 (ANSI 颜色支持)
# ------------------------------------------------------------------------------
log_info() {
  echo -e "\033[34mℹ️  [INFO]\033[0m $*"
}

log_success() {
  echo -e "\033[32m✅ [SUCCESS]\033[0m $*"
}

log_warn() {
  echo -e "\033[33m⚠️  [WARN]\033[0m $*" >&2
}

log_error() {
  echo -e "\033[31m❌ [ERROR]\033[0m $*" >&2
}

# ------------------------------------------------------------------------------
# 3. 帮助与用法说明
# ------------------------------------------------------------------------------
usage() {
  cat <<EOF
用法: $0 [选项] [动作]

选项:
  -n, --no-build           跳过构建阶段 (使用已构建的 App 产物)
  -f, --no-restart-finder  跳过重启 Finder 步骤 (开发调试非扩展功能时推荐)
  --no-clean               构建前跳过清理 DerivedData 构建缓存 (默认自动清理)
  --no-clean-cache         构建前跳过清理 App 运行时缓存 (默认自动清理)
  -h, --help               显示当前帮助信息

动作 (默认: run):
  run                      编译、注册并启动应用程序
  register                 仅执行 FinderSync 扩展注册并重启 Finder
  debug                    编译并在 lldb 调试器中启动应用程序
  logs                     启动应用程序并实时流式查看其系统日志
  telemetry                启动应用程序并过滤 subsystem == "$BUNDLE_ID" 的遥测日志
  verify                   校验应用程序运行状态以及 FinderSync 扩展激活状态
  clean                    仅清理 DerivedData 构建缓存和 App 运行时缓存
EOF
  exit "${1:-0}"
}

# ------------------------------------------------------------------------------
# 4. 命令行参数解析
# ------------------------------------------------------------------------------
# 循环解析所有以 '-' 开头的 Flags 选项
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--no-build)
      NO_BUILD=true
      shift
      ;;
    -f|--no-restart-finder)
      NO_RESTART_FINDER=true
      shift
      ;;
    --no-clean)
      CLEAN=false
      shift
      ;;
    --no-clean-cache)
      CLEAN_CACHE=false
      shift
      ;;
    -h|--help)
      usage 0
      ;;
    -*)
      log_error "未知选项: $1"
      usage 1
      ;;
    *)
      # 遇到非 '-' 开头的参数，视为具体的动作 (Action)，停止 Flags 解析
      break
      ;;
  esac
done

# 解析剩余的位置参数作为动作 (Action)，兼容旧版本的 '--action' 格式
ACTION="${1:-run}"
case "$ACTION" in
  --run) ACTION="run" ;;
  --debug) ACTION="debug" ;;
  --logs) ACTION="logs" ;;
  --telemetry) ACTION="telemetry" ;;
  --verify) ACTION="verify" ;;
  --clean) ACTION="clean" ;;
esac

# ------------------------------------------------------------------------------
# 5. 执行环境校验与步骤函数
# ------------------------------------------------------------------------------

# 校验 Xcode 开发环境
require_xcode() {
  if /usr/bin/xcodebuild -version >/dev/null 2>&1; then
    return
  fi

  # 尝试补全开发者目录环境变量
  if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  fi

  if ! /usr/bin/xcodebuild -version >/dev/null 2>&1; then
    log_error "编译 Finder Sync 插件需要完整的 Xcode。"
    echo "" >&2
    echo "如果 Xcode 已安装，请接受许可并选择它：" >&2
    echo "  sudo xcodebuild -license" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
  fi
}

# 安全地清理编译缓存，避免危险删除
clean_derived_data() {
  # 安全审计：确保路径不为空，且父目录属于该项目，防止 rm -rf 误伤系统根目录或用户主目录
  if [[ -n "${DERIVED_DATA_PATH:-}" && "$DERIVED_DATA_PATH" == *"/DerivedData" && "$DERIVED_DATA_PATH" == "$ROOT_DIR/DerivedData" ]]; then
    log_info "正在清理构建缓存: $DERIVED_DATA_PATH"
    rm -rf "$DERIVED_DATA_PATH"
  else
    log_error "未通过安全审计：拒绝清理无效路径 '${DERIVED_DATA_PATH:-}'"
    exit 1
  fi
}

# 安全地清理应用程序运行缓存，包括普通缓存和沙盒容器缓存
clean_app_cache() {
  log_info "正在清理 App 运行缓存..."
  # 定义需要清理的缓存路径列表
  local cache_paths=(
    "$HOME/Library/Caches/BetterMenu"
    "$HOME/Library/Containers/com.zombie.BetterMenu/Data/Library/Caches"
    "$HOME/Library/Containers/com.zombie.BetterMenu.FinderSync/Data/Library/Caches"
  )

  for path in "${cache_paths[@]}"; do
    if [[ -d "$path" ]]; then
      log_info "删除缓存目录: $path"
      # 安全审计：确保路径不为空，以用户主目录开头，且包含 BetterMenu 相关名称，防范误删
      if [[ -n "$path" && "$path" == "$HOME/Library/"* && "$path" == *"BetterMenu"* ]]; then
        rm -rf "$path"
      else
        log_warn "未通过安全审计，跳过删除路径: $path"
      fi
    fi
  done
  log_success "App 运行缓存清理完成"
}

# 执行 xcode 编译
build_app() {
  # 如果用户指定了跳过构建，验证已有产物后直接退出本函数
  if [[ "$NO_BUILD" == "true" ]]; then
    log_info "跳过构建阶段 (--no-build)"
    if [[ ! -d "$APP_BUNDLE" ]]; then
      log_error "找不到已构建的 App 产物: $APP_BUNDLE"
      log_error "请移除 --no-build 选项以进行首次构建。"
      exit 1
    fi
    return
  fi

  require_xcode

  # 安全地在当前用户会话中清理旧进程
  log_info "正在清理正在运行的旧进程..."
  pkill -u "$USER" -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -u "$USER" -x "$EXTENSION_NAME" >/dev/null 2>&1 || true

  log_info "开始编译项目 BetterMenu (Configuration: $CONFIGURATION)..."
  local start_time=$SECONDS

  if ! /usr/bin/xcodebuild \
    -project "$ROOT_DIR/$PROJECT_NAME" \
    -scheme "$SCHEME_NAME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build; then
    log_error "构建失败！请检查 Xcode 编译器输出。"
    exit 1
  fi

  local duration=$((SECONDS - start_time))
  log_success "构建成功！耗时: ${duration}s"
}

# 注册 FinderSync 插件到系统 LaunchServices 中
refresh_extension_registration() {
  if [[ ! -d "$APP_EXTENSION" ]]; then
    log_warn "找不到 Finder Sync 插件产物: $APP_EXTENSION，跳过注册。"
    return
  fi

  log_info "正在注册 Finder Sync 插件..."

  # 使用 lsregister 建立关联
  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f -R -trusted "$APP_BUNDLE" >/dev/null 2>&1 || true
  else
    log_warn "lsregister 未找到或不可执行，跳过 LaunchServices 关联步骤。"
  fi

  # 使用 pluginkit 进行强制更新
  /usr/bin/pluginkit -r "$APP_EXTENSION" >/dev/null 2>&1 || true
  /usr/bin/pluginkit -a "$APP_EXTENSION" >/dev/null 2>&1 || true
  
  if /usr/bin/pluginkit -e use -i "$EXTENSION_BUNDLE_ID" >/dev/null 2>&1; then
    log_success "扩展已成功激活 ($EXTENSION_BUNDLE_ID)"
  else
    log_warn "未能激活扩展 ($EXTENSION_BUNDLE_ID)，可能需要在 '系统设置 -> 延伸功能' 中手动勾选。"
  fi
}

# 重启 Finder 以应用注册信息
restart_finder() {
  if [[ "$NO_RESTART_FINDER" == "true" ]]; then
    log_info "跳过重启 Finder 步骤 (--no-restart-finder)"
    return
  fi

  log_info "正在重启 Finder..."
  /usr/bin/killall Finder >/dev/null 2>&1 || true
  log_success "Finder 已重启"
}

# 启动应用程序主程序
open_app() {
  log_info "正在启动 $APP_NAME.app..."
  if /usr/bin/open -n "$APP_BUNDLE"; then
    log_success "$APP_NAME 启动成功"
  else
    log_error "$APP_NAME 启动失败"
    exit 1
  fi
}

# ------------------------------------------------------------------------------
# 6. 主逻辑执行控制
# ------------------------------------------------------------------------------

# 步骤 A: 如果指定了 --clean，优先清理构建缓存；若指定了 -c 或动作为 clean，清理 App 运行缓存
if [[ "$CLEAN" == "true" ]]; then
  clean_derived_data
fi

if [[ "$CLEAN_CACHE" == "true" || "$ACTION" == "clean" ]]; then
  clean_app_cache
fi

# 如果动作是 clean，完成清理后直接退出，避免运行后续步骤
if [[ "$ACTION" == "clean" ]]; then
  log_success "清理操作全部完成。"
  exit 0
fi

# 步骤 B: 编译阶段
build_app

# 步骤 C: 插件注册与 Finder 重启
# 仅在非跳过构建时（代码变更需要重新注入），或者用户显式调用 register 动作时才触发，避免重复重启 Finder
if [[ "$NO_BUILD" == "false" || "$ACTION" == "register" ]]; then
  refresh_extension_registration
  restart_finder
fi

# ------------------------------------------------------------------------------
# 7. 根据动作执行后续流程
# ------------------------------------------------------------------------------
case "$ACTION" in
  run)
    open_app
    ;;
  register)
    log_success "FinderSync 扩展注册与重启流程完成。"
    ;;
  debug)
    log_info "正在启动 LLDB 调试器..."
    if [[ ! -x "$APP_BINARY" ]]; then
      log_error "找不到二进制文件: $APP_BINARY"
      exit 1
    fi
    /usr/bin/lldb -- "$APP_BINARY"
    ;;
  logs)
    open_app
    log_info "开始实时监听 App 日志 (按下 Ctrl+C 退出)..."
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\" OR process == \"$EXTENSION_NAME\""
    ;;
  telemetry)
    open_app
    log_info "开始实时监听遥测日志 (subsystem: $BUNDLE_ID，按下 Ctrl+C 退出)..."
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  verify)
    open_app
    sleep 1
    log_info "正在验证组件状态..."
    if pgrep -x "$APP_NAME" >/dev/null; then
      log_success "主程序运行状态: 正常运行中 (PID: $(pgrep -x "$APP_NAME"))"
    else
      log_error "主程序运行状态: 未运行"
    fi
    
    echo "FinderSync 扩展激活状态："
    /usr/bin/pluginkit -m -i "$EXTENSION_BUNDLE_ID" || true
    ;;
  clean)
    # 已在步骤 A 中执行并退出，此处为防万一的占位
    exit 0
    ;;
  *)
    log_error "未知的动作名称: $ACTION"
    usage
    ;;
esac

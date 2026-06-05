#!/usr/bin/env bash
# ==============================================================================
# BetterMenu 生产环境打包发布脚本
# Google Shell 编程规范
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. 默认配置与路径定义
# ------------------------------------------------------------------------------
APP_NAME="BetterMenu"
SCHEME_NAME="BetterMenu"
PROJECT_NAME="BetterMenu.xcodeproj"
CONFIGURATION="Release"

# 获取项目根目录 (绝对路径)
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="$ROOT_DIR/DerivedData"
DIST_DIR="$ROOT_DIR/dist"
STAGE_DIR="$DIST_DIR/dmg-root"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"

# ------------------------------------------------------------------------------
# 2. 终端彩色日志输出工具函数
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
# 3. 自动垃圾回收 (无论成功或异常出错退出，均安全擦除临时打包目录)
# ------------------------------------------------------------------------------
cleanup() {
  if [[ -d "$STAGE_DIR" ]]; then
    rm -rf "$STAGE_DIR"
  fi
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# 4. 获取项目构建版本号
# ------------------------------------------------------------------------------
log_info "正在提取项目构建版本号..."
VERSION="$(
  /usr/bin/xcodebuild \
    -project "$ROOT_DIR/$PROJECT_NAME" \
    -scheme "$SCHEME_NAME" \
    -configuration "$CONFIGURATION" \
    -showBuildSettings 2>/dev/null \
    | awk '/MARKETING_VERSION = / { print $3; exit }'
)"

if [[ -z "${VERSION:-}" ]]; then
  log_error "未能获取到 MARKETING_VERSION，请检查 Xcode 项目配置。"
  exit 1
fi

DMG_NAME="$APP_NAME-$VERSION.dmg"
ZIP_NAME="$APP_NAME-$VERSION.zip"
VOLUME_NAME="$APP_NAME"

# ------------------------------------------------------------------------------
# 5. 执行环境校验与步骤函数
# ------------------------------------------------------------------------------

# 校验 Xcode 环境
require_xcode() {
  if /usr/bin/xcodebuild -version >/dev/null 2>&1; then
    return
  fi

  if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  fi

  if ! /usr/bin/xcodebuild -version >/dev/null 2>&1; then
    log_error "打包 BetterMenu 需要完整的 Xcode 环境。"
    exit 1
  fi
}

# 清理并重建 dist 导出目录
clean_output() {
  log_info "正在初始化 dist 输出目录..."
  rm -rf "$DIST_DIR"
  mkdir -p "$DIST_DIR" "$STAGE_DIR"
}

# 编译 Release 配置
build_release() {
  log_info "正在使用 xcodebuild 编译 Release 产物..."
  local start_time=$SECONDS
  
  if ! /usr/bin/xcodebuild \
    -project "$ROOT_DIR/$PROJECT_NAME" \
    -scheme "$SCHEME_NAME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build; then
    log_error "编译 Release 失败！"
    exit 1
  fi
  
  local duration=$((SECONDS - start_time))
  log_success "编译成功！耗时: ${duration}s"
}

# 将编译产物拷贝到临时打包目录
stage_app() {
  if [[ ! -d "$APP_BUNDLE" ]]; then
    log_error "找不到已构建的 App 产物: $APP_BUNDLE"
    exit 1
  fi

  log_info "正在准备临时打包资源..."
  /usr/bin/rsync -a "$APP_BUNDLE" "$STAGE_DIR/"
}

# 创建通用 ZIP 压缩发布包
create_zip() {
  log_info "正在创建 ZIP 压缩包 ($ZIP_NAME)..."
  (
    cd "$STAGE_DIR"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$DIST_DIR/$ZIP_NAME"
  )
  log_success "ZIP 压缩包创建成功"
}

# 创建精美 DMG 安装包
create_dmg() {
  if command -v create-dmg >/dev/null 2>&1; then
    log_info "检测到 create-dmg，开始进行高级 DMG 界面美化定制..."
    rm -f "$DIST_DIR/$DMG_NAME"
    
    local -a volicon_args=()
    if [[ -f "$STAGE_DIR/$APP_NAME.app/Contents/Resources/AppIcon.icns" ]]; then
      volicon_args=(
        --volicon
        "$STAGE_DIR/$APP_NAME.app/Contents/Resources/AppIcon.icns"
      )
    fi

    # 清除潜在的软链接，防止与 create-dmg 自带的 --app-drop-link 重名冲突
    rm -f "$STAGE_DIR/Applications"

    create-dmg \
      --volname "$VOLUME_NAME" \
      "${volicon_args[@]}" \
      --window-pos 200 120 \
      --window-size 600 400 \
      --icon-size 100 \
      --icon "$APP_NAME.app" 150 190 \
      --hide-extension "$APP_NAME.app" \
      --app-drop-link 450 190 \
      "$DIST_DIR/$DMG_NAME" \
      "$STAGE_DIR"
  else
    log_warn "未检测到 create-dmg，将使用系统默认 hdiutil 降级打包。"
    log_info "提示: 可运行 'brew install create-dmg' 以启用精美打包布局。"
    
    rm -f "$STAGE_DIR/Applications"
    ln -s /Applications "$STAGE_DIR/Applications"

    /usr/bin/hdiutil create \
      -volname "$VOLUME_NAME" \
      -srcfolder "$STAGE_DIR" \
      -ov \
      -format UDZO \
      "$DIST_DIR/$DMG_NAME"
  fi
  log_success "DMG 映像打包成功"
}

# 打印最终成果汇总
summarize() {
  cat <<EOF

================================================================================
🎉 BetterMenu 打包发布流程成功结束！
================================================================================
已在 dist/ 目录下创建以下生产发布件：
  📁 ZIP 压缩包: $DIST_DIR/$ZIP_NAME
  💿 DMG 映像包: $DIST_DIR/$DMG_NAME

注意:
  此版本为本地未签名版。如需公开发布并避免 macOS Gatekeeper 的“恶意软件”拦截警告，
  请使用您的 Apple 开发者账号对打包产物进行 Developer ID 签名与公证 (Notarization)。
================================================================================
EOF
}

# ------------------------------------------------------------------------------
# 6. 主执行流程
# ------------------------------------------------------------------------------
require_xcode
clean_output
build_release
stage_app
create_zip
create_dmg
summarize

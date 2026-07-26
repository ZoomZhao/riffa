#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export DEVELOPER_DIR

if [[ $(uname -m) != arm64 ]]; then
    print -u2 "Riffa 只支持在 Apple Silicon Mac 上构建。"
    exit 1
fi

cd "$PROJECT_DIR"

zsh "$PROJECT_DIR/Scripts/check-localization.sh"

MODULE_CACHE_DIR="$PROJECT_DIR/.build/ModuleCache"
mkdir -p "$MODULE_CACHE_DIR"
export CLANG_MODULE_CACHE_PATH=${CLANG_MODULE_CACHE_PATH:-$MODULE_CACHE_DIR}
export SWIFTPM_MODULECACHE_OVERRIDE=${SWIFTPM_MODULECACHE_OVERRIDE:-$MODULE_CACHE_DIR}

build_arguments=(-c release --arch arm64)
if [[ ${RIFFA_DISABLE_SWIFTPM_SANDBOX:-0} == 1 ]]; then
    build_arguments+=(--disable-sandbox)
fi
swift build "${build_arguments[@]}" --product RiffaDesktop
swift build "${build_arguments[@]}" --product riffa

OUTPUT_DIR="$PROJECT_DIR/dist"
APP_DIR="$OUTPUT_DIR/Riffa.app"
CLI_OUTPUT="$OUTPUT_DIR/riffa"
PACKAGE_TEMP_DIR=$(mktemp -d "$PROJECT_DIR/.build/riffa-package.XXXXXX")
trap 'rm -rf "$PACKAGE_TEMP_DIR"' EXIT
STAGING_APP_DIR="$PACKAGE_TEMP_DIR/Riffa.app"
STAGING_CLI="$PACKAGE_TEMP_DIR/riffa"
CONTENTS_DIR="$STAGING_APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$PACKAGE_TEMP_DIR/Riffa.iconset"
EXECUTABLE="$PROJECT_DIR/.build/arm64-apple-macosx/release/RiffaDesktop"
CLI_EXECUTABLE="$PROJECT_DIR/.build/arm64-apple-macosx/release/riffa"
ICON_MASTER="$PROJECT_DIR/Sources/RiffaApp/Resources/AppIcon-1024-v2.png"
ENTITLEMENTS="$PROJECT_DIR/Sources/RiffaApp/Resources/Riffa.entitlements"
LOCALIZATION_CATALOGS=(
    "$PROJECT_DIR/Sources/RiffaApp/Resources/Localizable.xcstrings"
    "$PROJECT_DIR/Sources/RiffaApp/Resources/InfoPlist.xcstrings"
    "$PROJECT_DIR/Sources/RiffaApp/Resources/ServicesMenu.xcstrings"
)

if [[ ! -x "$EXECUTABLE" ]]; then
    print -u2 "找不到构建产物：$EXECUTABLE"
    exit 1
fi
if [[ ! -x "$CLI_EXECUTABLE" ]]; then
    print -u2 "找不到 CLI 构建产物：$CLI_EXECUTABLE"
    exit 1
fi

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ICONSET_DIR"
install -m 755 "$EXECUTABLE" "$MACOS_DIR/Riffa"
install -m 755 "$CLI_EXECUTABLE" "$STAGING_CLI"
install -m 644 "$PROJECT_DIR/Sources/RiffaApp/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
for catalog in "${LOCALIZATION_CATALOGS[@]}"; do
    xcrun xcstringstool compile "$catalog" --output-directory "$RESOURCES_DIR"
done
for language in en zh-Hans; do
    for table in Localizable InfoPlist ServicesMenu; do
        localized_table="$RESOURCES_DIR/$language.lproj/$table.strings"
        if [[ ! -f "$localized_table" ]]; then
            print -u2 "缺少已编译的本地化资源：$localized_table"
            exit 1
        fi
    done
done

for spec in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"
do
    size=${spec%% *}
    filename=${spec#* }
    sips -z "$size" "$size" "$ICON_MASTER" --out "$ICONSET_DIR/$filename" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
codesign --force --deep --sign - --options runtime --timestamp=none \
    --entitlements "$ENTITLEMENTS" "$STAGING_APP_DIR"
codesign --force --sign - --options runtime --timestamp=none "$STAGING_CLI"

# Validate the exact staged artifacts before touching the previous release.
# This makes architecture, plist drift, and signature failures transactional
# packaging failures instead of partially published output.
plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
if ! cmp -s "$PROJECT_DIR/Sources/RiffaApp/Resources/Info.plist" \
    "$CONTENTS_DIR/Info.plist"; then
    print -u2 "暂存 App 的 Info.plist 与源码不一致。"
    exit 1
fi
if [[ $(/usr/bin/lipo -archs "$MACOS_DIR/Riffa") != arm64 ]]; then
    print -u2 "Riffa.app 主程序不是纯 arm64。"
    exit 1
fi
if [[ $(/usr/bin/lipo -archs "$STAGING_CLI") != arm64 ]]; then
    print -u2 "riffa CLI 不是纯 arm64。"
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "$STAGING_APP_DIR"
codesign --verify --strict --verbose=2 "$STAGING_CLI"

# Assemble in an isolated directory so stale files from a previous package can
# never leak into the signed bundle. Move existing outputs aside until both new
# artifacts are ready, allowing a failed replacement to restore them.
mkdir -p "$OUTPUT_DIR"
PREVIOUS_APP="$PACKAGE_TEMP_DIR/Previous-Riffa.app"
PREVIOUS_CLI="$PACKAGE_TEMP_DIR/previous-riffa"
if [[ -e "$APP_DIR" ]]; then
    mv "$APP_DIR" "$PREVIOUS_APP"
fi
if [[ -e "$CLI_OUTPUT" ]]; then
    mv "$CLI_OUTPUT" "$PREVIOUS_CLI"
fi
if ! mv "$STAGING_APP_DIR" "$APP_DIR"; then
    [[ ! -e "$PREVIOUS_APP" ]] || mv "$PREVIOUS_APP" "$APP_DIR"
    [[ ! -e "$PREVIOUS_CLI" ]] || mv "$PREVIOUS_CLI" "$CLI_OUTPUT"
    exit 1
fi
if ! mv "$STAGING_CLI" "$CLI_OUTPUT"; then
    mv "$APP_DIR" "$STAGING_APP_DIR"
    [[ ! -e "$PREVIOUS_APP" ]] || mv "$PREVIOUS_APP" "$APP_DIR"
    [[ ! -e "$PREVIOUS_CLI" ]] || mv "$PREVIOUS_CLI" "$CLI_OUTPUT"
    exit 1
fi

print "$APP_DIR"
print "$CLI_OUTPUT"

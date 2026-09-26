#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
DIST_DIR="${PROJECT_DIR}/dist"
APP_PATH="${DIST_DIR}/拾响.app"
BUILD_SCRATCH="${PROJECT_DIR}/.build-app/dmg-staging"
BACKGROUND_GENERATOR="${BUILD_SCRATCH}/generate_dmg_background"

[[ -d "${APP_PATH}" ]] || { print -u2 "Build the app before packaging a DMG."; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP_PATH}/Contents/Info.plist")"
DMG_PATH="${DIST_DIR}/拾响-${VERSION}-Build${BUILD}.dmg"
STAGING_PATH="${BUILD_SCRATCH}/拾响"
BACKGROUND_DIR="${STAGING_PATH}/.background"
BACKGROUND_PATH="${BACKGROUND_DIR}/background.png"
RW_DMG_PATH="${BUILD_SCRATCH}/拾响-${VERSION}-Build${BUILD}.rw.dmg"

rm -rf "${BUILD_SCRATCH}" "${DMG_PATH}" "${DMG_PATH}.sha256"
mkdir -p "${STAGING_PATH}" "${BACKGROUND_DIR}"
ditto --noqtn --norsrc "${APP_PATH}" "${STAGING_PATH}/拾响.app"
ln -s /Applications "${STAGING_PATH}/Applications"

swiftc "${PROJECT_DIR}/Support/generate_dmg_background.swift" \
    -o "${BACKGROUND_GENERATOR}"
"${BACKGROUND_GENERATOR}" "${BACKGROUND_PATH}"

# Build a writable image first so Finder can store a polished, immediately understandable
# icon layout. The final artifact is converted to compressed read-only UDZO afterwards.
hdiutil create \
    -volname "拾响 ${VERSION} Build ${BUILD}" \
    -srcfolder "${STAGING_PATH}" \
    -ov \
    -format UDRW \
    "${RW_DMG_PATH}"

ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen "${RW_DMG_PATH}")"
DEVICE="$(print -r -- "${ATTACH_OUTPUT}" | awk '/Apple_HFS|Apple_APFS/ { print $1; exit }')"
MOUNT_POINT="$(print -r -- "${ATTACH_OUTPUT}" | awk -F '\t' '/\/Volumes\// { print $NF; exit }')"
[[ -n "${DEVICE}" && -d "${MOUNT_POINT}" ]] || {
    print -u2 "无法挂载 DMG 布局镜像。"
    exit 3
}

cleanup_mount() {
    hdiutil detach "${DEVICE}" -quiet 2>/dev/null || true
}
trap cleanup_mount EXIT

osascript <<EOF
tell application "Finder"
    tell disk "拾响 ${VERSION} Build ${BUILD}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        # Finder's title/tab chrome and optional status bar consume part of the outer bounds on
        # recent macOS releases. Leave enough vertical room for the full 760×480 background so
        # the minimum-system requirement remains visible without scrolling.
        set the bounds of container window to {120, 80, 880, 700}
        set arrangement of icon view options of container window to not arranged
        set icon size of icon view options of container window to 128
        set text size of icon view options of container window to 13
        set background picture of icon view options of container window to file ".background:background.png"
        set position of item "拾响.app" of container window to {190, 255}
        set position of item "Applications" of container window to {570, 255}
        close
        open
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF

sync
hdiutil detach "${DEVICE}" -quiet
trap - EXIT

hdiutil convert "${RW_DMG_PATH}" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "${DMG_PATH}"
PACKAGE_FORMAT="UDZO compressed · Finder drag-to-install layout"

(cd "${DIST_DIR}" && shasum -a 256 "${DMG_PATH:t}") > "${DMG_PATH}.sha256"
print "DMG 完成：${DMG_PATH}"
print "格式：${PACKAGE_FORMAT}"
cat "${DMG_PATH}.sha256"

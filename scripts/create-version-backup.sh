#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
VERSIONS_DIR="${SHIXIANG_VERSIONS_DIR:-${PROJECT_DIR}/versions}"
BACKUP_NAME="${1:-}"

if [[ -z "${BACKUP_NAME}" ]]; then
    print -u2 "Usage: scripts/create-version-backup.sh v0.5.0-build25-name"
    exit 2
fi
if [[ "${BACKUP_NAME}" != v* ]]; then
    print -u2 "Backup name must start with v."
    exit 2
fi

APP_PATH="${PROJECT_DIR}/dist/拾响.app"
DESTINATION="${VERSIONS_DIR}/${BACKUP_NAME}"
SOURCE_DESTINATION="${DESTINATION}/source"
DIST_DESTINATION="${DESTINATION}/dist"

[[ -d "${APP_PATH}" ]] || { print -u2 "Build the app before archiving it."; exit 1; }
[[ ! -e "${DESTINATION}" ]] || { print -u2 "Backup already exists: ${DESTINATION}"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP_PATH}/Contents/Info.plist")"
DMG_PATH="${PROJECT_DIR}/dist/拾响-${VERSION}-Build${BUILD}.dmg"

mkdir -p "${SOURCE_DESTINATION}" "${DIST_DESTINATION}"

# Source backups stay small and reproducible. SwiftPM build caches, ad-hoc build scratch,
# Git internals and the separately copied app bundle can all be recreated from the commit.
rsync -a --exclude '.build/' --exclude '.build-app/' --exclude '.git/' --exclude 'dist/' --exclude 'versions/' \
    --exclude '.DS_Store' --exclude '._*' \
    "${PROJECT_DIR}/" "${SOURCE_DESTINATION}/"
# Keep each archive focused on the exact runnable release. Older DMGs remain in
# their own version folders instead of being copied into every newer backup.
rsync -a "${APP_PATH}" "${DIST_DESTINATION}/"
if [[ -f "${DMG_PATH}" ]]; then
    rsync -a "${DMG_PATH}" "${DIST_DESTINATION}/"
    [[ ! -f "${DMG_PATH}.sha256" ]] || rsync -a "${DMG_PATH}.sha256" "${DIST_DESTINATION}/"
fi

git -C "${PROJECT_DIR}" rev-parse HEAD > "${DESTINATION}/GIT_COMMIT.txt"
shasum -a 256 "${APP_PATH}/Contents/MacOS/Shixiang" \
    | sed "s#${PROJECT_DIR}/##" > "${DESTINATION}/BUILD_SHA256.txt"

cat > "${DESTINATION}/BACKUP_MANIFEST.txt" <<EOF
拾响版本归档
版本：${VERSION} · Build ${BUILD}
Git：$(<"${DESTINATION}/GIT_COMMIT.txt")
源码备份：排除 .build、.build-app、.git、dist 及 Finder 元数据等可重建内容
应用备份：dist/拾响.app
交付包：$(if [[ -f "${DMG_PATH}" ]]; then print "dist/$(basename "${DMG_PATH}")"; else print "未生成 DMG"; fi)
原始音频：未复制、未移动、未改名
EOF

codesign --verify --deep --strict "${DIST_DESTINATION}/拾响.app"
print "归档完成：${DESTINATION}"
du -sh "${DESTINATION}"

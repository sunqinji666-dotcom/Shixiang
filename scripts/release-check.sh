#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_PATH="${PROJECT_DIR}/dist/拾响.app"
INFO_PATH="${APP_PATH}/Contents/Info.plist"
EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/Shixiang"
PRIVACY_PATH="${APP_PATH}/Contents/Resources/PRIVACY.md"

if [[ -n "$(git -C "${PROJECT_DIR}" status --porcelain --untracked-files=no)" \
      && "${SHIXIANG_ALLOW_DIRTY_RELEASE:-0}" != "1" ]]; then
    print -u2 "Source tree has uncommitted changes; release check stopped."
    print -u2 "For a reviewed local handoff that intentionally preserves working changes, set SHIXIANG_ALLOW_DIRTY_RELEASE=1."
    exit 1
fi
if [[ "${SHIXIANG_ALLOW_DIRTY_RELEASE:-0}" == "1" ]]; then
    print "本地交付模式：保留已复核的未提交修改，继续核验成品。"
fi

[[ -d "${APP_PATH}" ]] || { print -u2 "Missing app: ${APP_PATH}"; exit 1; }
[[ -f "${INFO_PATH}" ]] || { print -u2 "Missing Info.plist"; exit 1; }
[[ -f "${EXECUTABLE_PATH}" ]] || { print -u2 "Missing executable"; exit 1; }
[[ -f "${PRIVACY_PATH}" ]] || { print -u2 "Missing in-app privacy policy resource"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PATH}")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PATH}")"
HASH="$(shasum -a 256 "${EXECUTABLE_PATH}" | awk '{print $1}')"
DMG_PATH="${PROJECT_DIR}/dist/拾响-${VERSION}-Build${BUILD}.dmg"
DMG_SHA_PATH="${DMG_PATH}.sha256"

README_BUILD="$(awk 'match($0, /Build [0-9]+/) { print substr($0, RSTART + 6, RLENGTH - 6); exit }' "${PROJECT_DIR}/README.md")"
RELEASE_NOTES_BUILD="$(awk 'match($0, /Build [0-9]+/) { print substr($0, RSTART + 6, RLENGTH - 6); exit }' "${PROJECT_DIR}/RELEASE_NOTES.md")"
[[ -n "${README_BUILD}" && "${README_BUILD}" == "${BUILD}" ]] || {
    print -u2 "README version does not match App Build ${BUILD}."
    exit 1
}
[[ -n "${RELEASE_NOTES_BUILD}" && "${RELEASE_NOTES_BUILD}" == "${BUILD}" ]] || {
    print -u2 "RELEASE_NOTES version does not match App Build ${BUILD}."
    exit 1
}

codesign --verify --deep --strict "${APP_PATH}"
print "拾响 Release 检查通过"
print "版本：${VERSION} · Build ${BUILD}"
print "可执行文件 SHA-256：${HASH}"
print "签名：codesign verify passed"
print "文档版本：README / RELEASE_NOTES matched"

if [[ -f "${DMG_PATH}" ]]; then
    [[ -f "${DMG_SHA_PATH}" ]] || { print -u2 "DMG exists without SHA-256: ${DMG_SHA_PATH}"; exit 1; }
    (cd "${DMG_PATH:h}" && shasum -a 256 -c "${DMG_SHA_PATH:t}")
    print "DMG SHA-256：verified"
else
    print "DMG：未生成（本次为 App-only 检查）"
fi

#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_PATH="${PROJECT_DIR}/dist/拾响.app"
INFO_PATH="${APP_PATH}/Contents/Info.plist"
EXTERNAL_RELEASE_ROOT="${SHIXIANG_RELEASE_ROOT:-/Volumes/2t/拾响发布}"
ASSISTANT_APP="${SHIXIANG_ASSISTANT_APP:-/Applications/macOS Assistant.app}"

[[ -d "${APP_PATH}" ]] || { print -u2 "缺少已构建 App：${APP_PATH}"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PATH}")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PATH}")"
DMG_PATH="${PROJECT_DIR}/dist/拾响-${VERSION}-Build${BUILD}.dmg"
DMG_SHA_PATH="${DMG_PATH}.sha256"
RELEASE_DIR="${EXTERNAL_RELEASE_ROOT}/拾响-${VERSION}-Build${BUILD}"
DMG_BACKGROUND="${PROJECT_DIR}/.build-app/dmg-staging/拾响/.background/background.png"

export COPYFILE_DISABLE=1

[[ -f "${DMG_PATH}" && -f "${DMG_SHA_PATH}" ]] || {
    print -u2 "缺少 Build ${BUILD} DMG 或 SHA-256 文件。"
    exit 2
}
[[ ! -e "${RELEASE_DIR}" ]] || {
    print -u2 "交付目录已存在，为避免覆盖已停止：${RELEASE_DIR}"
    exit 3
}

mkdir -p "${RELEASE_DIR}"
ditto --noqtn --norsrc "${APP_PATH}" "${RELEASE_DIR}/拾响.app"
cp "${DMG_PATH}" "${DMG_SHA_PATH}" "${RELEASE_DIR}/"
cp "${PROJECT_DIR}/Docs/RELEASE_1.0.0_MANIFEST.md" "${RELEASE_DIR}/1.0正式版交付清单.md"
cp "${PROJECT_DIR}/Docs/DELIVERY_AI_HANDOFF.md" "${RELEASE_DIR}/交付与AI启动说明.md"
cp "${PROJECT_DIR}/Docs/PRIVACY.md" "${RELEASE_DIR}/隐私说明.md"
cp "${PROJECT_DIR}/Support/安装说明.txt" "${RELEASE_DIR}/安装说明.txt"
cp "${PROJECT_DIR}/Support/附加音效库来源与授权说明.txt" "${RELEASE_DIR}/附加音效库来源与授权说明.txt"
if [[ -f "${DMG_BACKGROUND}" ]]; then
    cp "${DMG_BACKGROUND}" "${RELEASE_DIR}/DMG安装画面.png"
fi

if [[ -d "${ASSISTANT_APP}" ]]; then
    ditto --noqtn --norsrc "${ASSISTANT_APP}" "${RELEASE_DIR}/macOS Assistant.app"
fi

(
    cd "${RELEASE_DIR}"
    find . -type f ! -name '交付目录SHA256.txt' ! -name '._*' -print0 \
        | sort -z \
        | xargs -0 shasum -a 256 \
        > 交付目录SHA256.txt
)

print "交付文件夹完成：${RELEASE_DIR}"

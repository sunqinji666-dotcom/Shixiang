#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_PATH="${PROJECT_DIR}/dist/拾响.app"
PROFILE="${SHIXIANG_NOTARY_PROFILE:-}"

[[ -d "${APP_PATH}" ]] || { print -u2 "Missing app: ${APP_PATH}"; exit 1; }
[[ -n "${PROFILE}" ]] || {
    print -u2 "Set SHIXIANG_NOTARY_PROFILE to an xcrun notarytool keychain profile."
    exit 2
}

codesign --verify --deep --strict "${APP_PATH}"
xcrun notarytool submit "${APP_PATH}" --keychain-profile "${PROFILE}" --wait
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"
codesign --verify --deep --strict "${APP_PATH}"
print "拾响公证与 Staple 完成"

#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"

"${SCRIPT_DIR}/release-check.sh"

IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if ! print -r -- "${IDENTITIES}" | rg -q 'Developer ID Application:'; then
    print -u2 "未找到 Developer ID Application 证书。当前只能交付本机临时签名版本。"
    print -u2 "配置 SHIXIANG_CODESIGN_IDENTITY 后重新运行构建。"
    exit 2
fi

if [[ -z "${SHIXIANG_NOTARY_PROFILE:-}" ]]; then
    print -u2 "未配置 SHIXIANG_NOTARY_PROFILE，无法提交 Apple 公证。"
    print -u2 "先用 xcrun notarytool store-credentials 保存 Profile，再重试。"
    exit 2
fi

print "售卖发布前置检查通过：Developer ID + 公证 Profile 已配置。"
print "下一步：运行 scripts/notarize-app.sh，再重新执行 scripts/release-check.sh。"

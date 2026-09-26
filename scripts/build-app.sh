#!/bin/zsh

set -euo pipefail

LOCK_DIR="${TMPDIR:-/private/tmp}/shixiang-build.lock"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    print -u2 "已有拾响构建正在进行，停止本次重复构建。"
    exit 4
fi
trap 'rmdir "${LOCK_DIR}" 2>/dev/null || true' EXIT

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
BUILD_DIR="${PROJECT_DIR}/.build-app"
DIST_DIR="${PROJECT_DIR}/dist"
APP_PATH="${DIST_DIR}/拾响.app"
CONTENTS_DIR="${APP_PATH}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
ICONSET_DIR="${BUILD_DIR}/Shixiang.iconset"
AI_SOURCE_DIR="${SHIXIANG_AI_SOURCE_DIR:-${HOME}/Library/Application Support/ShixiangAIStudio/AudioTagging}"
AI_BUNDLE_DIR="${RESOURCES_DIR}/AI/AudioTagging"

export CLANG_MODULE_CACHE_PATH="${BUILD_DIR}/module-cache/clang"
export SWIFT_MODULECACHE_PATH="${BUILD_DIR}/module-cache/swift"

# SwiftPM's Xcode 27 build engine writes a dSYM during Release builds. On
# some macOS setups that generated bundle inherits a provenance attribute that
# the build engine cannot update inside the project directory. Keep the
# compiler scratch in a disposable system temp location and explicitly disable
# dSYM generation for this unsigned/ad-hoc distributable build. Developer ID
# signing and notarization still happen on the finished app bundle below.
SWIFT_SCRATCH_PATH="${SHIXIANG_SWIFT_SCRATCH_PATH:-$(mktemp -d /private/tmp/shixiang-swift.XXXXXX)}"
export SWIFT_SCRATCH_PATH

mkdir -p "${BUILD_DIR}" "${DIST_DIR}" \
    "${CLANG_MODULE_CACHE_PATH}" "${SWIFT_MODULECACHE_PATH}"
rm -rf "${APP_PATH}" "${ICONSET_DIR}"

swift build \
    --package-path "${PROJECT_DIR}" \
    --scratch-path "${SWIFT_SCRATCH_PATH}" \
    --disable-sandbox \
    -c release \
    -debug-info-format none

BIN_DIR="$(swift build \
    --package-path "${PROJECT_DIR}" \
    --scratch-path "${SWIFT_SCRATCH_PATH}" \
    --disable-sandbox \
    -c release \
    -debug-info-format none \
    --show-bin-path)"

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${ICONSET_DIR}"
cp "${BIN_DIR}/Shixiang" "${MACOS_DIR}/Shixiang"
cp "${PROJECT_DIR}/Support/Info.plist" "${CONTENTS_DIR}/Info.plist"
cp "${PROJECT_DIR}/Docs/PRIVACY.md" "${RESOURCES_DIR}/PRIVACY.md"
cp "${PROJECT_DIR}/Support/qwen_search_planner.py" "${RESOURCES_DIR}/qwen_search_planner.py"
cp "${PROJECT_DIR}/Support/wechat-sponsor-qr.png" "${RESOURCES_DIR}/WechatSponsorQR.png"

if [[ ! -d "${AI_SOURCE_DIR}" || ! -d "${AI_SOURCE_DIR}/.venv" || ! -d "${AI_SOURCE_DIR}/hf-cache/models--mlx-community--Qwen3-1.7B-4bit" ]]; then
    print -u2 "未找到本地 AI 运行时：${AI_SOURCE_DIR}"
    print -u2 "设置 SHIXIANG_AI_SOURCE_DIR 指向包含 .venv、runtime 和 hf-cache 的目录后重试。"
    exit 2
fi
mkdir -p "${AI_BUNDLE_DIR:h}"
# Preserve the relative Python/model links while copying only what the planner needs. A plain
# directory copy expands Hugging Face snapshot links and can multiply the bundle size severalfold.
mkdir -p "${AI_BUNDLE_DIR}"
tar -cf - \
    -C "${AI_SOURCE_DIR}" \
    .venv hf-cache/models--mlx-community--Qwen3-1.7B-4bit \
    | tar -xf - -C "${AI_BUNDLE_DIR}"

# A development virtualenv may contain an absolute link to Codex's shared Python runtime.
# Resolve links inside the app bundle so the signed bundle is self-contained and macOS does
# not reject it as having an invalid destination. Relative model-cache links remain internal
# to the copied Hugging Face cache and are valid bundle resources.
for runtime_link in "${AI_BUNDLE_DIR}/.venv/bin/python3" \
                    "${AI_BUNDLE_DIR}/.venv/bin/python" \
                    "${AI_BUNDLE_DIR}/.venv/bin/python3.12"; do
    if [[ -L "${runtime_link}" ]]; then
        runtime_target="$(readlink "${runtime_link}")"
        if [[ "${runtime_target}" == /* && -f "${runtime_target}" ]]; then
            rm "${runtime_link}"
            cp "${runtime_target}" "${runtime_link}"
        fi
    fi
done
PYTHON_RUNTIME_SOURCE="$(readlink "${AI_SOURCE_DIR}/.venv/bin/python3" 2>/dev/null || true)"
if [[ "${PYTHON_RUNTIME_SOURCE}" != /* ]]; then
    PYTHON_RUNTIME_SOURCE="${AI_SOURCE_DIR}/.venv/bin/${PYTHON_RUNTIME_SOURCE}"
fi
PYTHON_RUNTIME_PREFIX="${PYTHON_RUNTIME_SOURCE:A:h:h}"
PYTHON_RUNTIME_LIB="${PYTHON_RUNTIME_SOURCE:A:h:h}/lib/libpython3.12.dylib"
if [[ -f "${PYTHON_RUNTIME_LIB}" ]]; then
    mkdir -p "${AI_BUNDLE_DIR}/.venv/lib"
    cp "${PYTHON_RUNTIME_LIB}" "${AI_BUNDLE_DIR}/.venv/lib/libpython3.12.dylib"
fi
if [[ -d "${PYTHON_RUNTIME_PREFIX}/lib/python3.12" ]]; then
    mkdir -p "${AI_BUNDLE_DIR}/.venv"
    tar -cf - \
        -C "${PYTHON_RUNTIME_PREFIX}" \
        --exclude='lib/python3.12/site-packages' \
        lib/python3.12 \
        | tar -xf - -C "${AI_BUNDLE_DIR}/.venv"
fi
if [[ -f "${PYTHON_RUNTIME_PREFIX}/lib/python312.zip" ]]; then
    cp "${PYTHON_RUNTIME_PREFIX}/lib/python312.zip" "${AI_BUNDLE_DIR}/.venv/lib/python312.zip"
fi
if [[ -f "${AI_BUNDLE_DIR}/.venv/pyvenv.cfg" ]]; then
    sed -i '' -E \
        -e "s#^home = .*#home = bin#" \
        -e "s#^executable = .*#executable = bin/python3#" \
        -e "s#^command = .*#command = bundled by Shixiang#" \
        "${AI_BUNDLE_DIR}/.venv/pyvenv.cfg"
fi

swiftc "${PROJECT_DIR}/Support/generate_icon.swift" \
    -o "${BUILD_DIR}/generate_icon"
"${BUILD_DIR}/generate_icon" \
    "${ICONSET_DIR}" \
    "${RESOURCES_DIR}/Shixiang.icns"

# Keep the development app's designated requirement stable across rebuilds. An ad-hoc
# signature gets a new CDHash every time the binary changes, so macOS treats every build as a
# different process and asks for Documents/Desktop access again. Prefer Jacksun's stable local
# signing identity when it is installed; CI/release builds can override it explicitly (or use
# `-` for a deliberately ad-hoc artifact).
if [[ -n "${SHIXIANG_CODESIGN_IDENTITY:-}" ]]; then
    SIGNING_IDENTITY="${SHIXIANG_CODESIGN_IDENTITY}"
elif security find-identity -v -p codesigning 2>/dev/null | grep -F '20EEEF9024611CD717A8F068544E7D8E3372A002' >/dev/null; then
    # Use the stable certificate hash so localized Keychain output cannot accidentally cause
    # a fallback to ad-hoc signing and trigger a new macOS file-access identity.
    SIGNING_IDENTITY="20EEEF9024611CD717A8F068544E7D8E3372A002"
else
    print -u2 "未找到固定开发签名 Xiangqi Pilot Local Signing，拒绝生成临时签名 App。"
    print -u2 "请检查钥匙串证书，或显式设置 SHIXIANG_CODESIGN_IDENTITY。"
    exit 5
fi
print "Signing ${SIGNING_IDENTITY}"
codesign --force --deep --options runtime --timestamp --sign "${SIGNING_IDENTITY}" "${APP_PATH}"
codesign --verify --deep --strict "${APP_PATH}"

# Development handoff: launch the newly signed bundle first, verify that this exact binary is
# alive, then retire the previous process. This avoids leaving the user with a blank/"未启动"
# state when macOS is still presenting a file-access consent sheet.
OLD_PIDS=("${(@f)$(pgrep -f -- "${APP_PATH}/Contents/MacOS/Shixiang" || true)}")
# Retire only the old binary after the new bundle has been fully signed. `open -n` ensures
# LaunchServices does not simply focus an existing process and fool the readiness check.
for pid in "${OLD_PIDS[@]}"; do
    [[ "${pid}" == <-> ]] || continue
    kill "${pid}" 2>/dev/null || true
done
sleep 0.35
open -n "${APP_PATH}"
NEW_PID=""
for _ in {1..30}; do
    NEW_PID="$(pgrep -f -- "${APP_PATH}/Contents/MacOS/Shixiang" | tail -n 1 || true)"
    [[ -n "${NEW_PID}" && ! " ${OLD_PIDS[*]} " == *" ${NEW_PID} "* ]] && break
    sleep 0.2
done
if [[ -z "${NEW_PID}" ]]; then
    print -u2 "新版拾响未能启动，保留旧进程不退出。"
    exit 3
fi
for pid in "${OLD_PIDS[@]}"; do
    [[ "${pid}" == <-> && "${pid}" != "${NEW_PID}" ]] || continue
    kill "${pid}" 2>/dev/null || true
done

echo "Built ${APP_PATH}"
echo "Swift scratch: ${SWIFT_SCRATCH_PATH}"

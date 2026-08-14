#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
BUILD_DIR=".build-app"

cd "${PROJECT_DIR}"

export CLANG_MODULE_CACHE_PATH="${BUILD_DIR}/module-cache/clang"
export SWIFT_MODULECACHE_PATH="${BUILD_DIR}/module-cache/swift"
mkdir -p "${CLANG_MODULE_CACHE_PATH}" "${SWIFT_MODULECACHE_PATH}" "${BUILD_DIR}/swift"

print "[0/7] Test build"
swift build --package-path . --scratch-path "${BUILD_DIR}/swift" \
    --disable-sandbox --build-tests
print "[1/7] CoreTests"
swift test --package-path . --scratch-path "${BUILD_DIR}/swift" \
    --disable-sandbox --skip-build --filter CoreTests
print "[2/7] AudioTests"
swift test --package-path . --scratch-path "${BUILD_DIR}/swift" \
    --disable-sandbox --skip-build --filter AudioTests
print "[3/7] KeyAnalyzerTests"
swift test --package-path . --scratch-path "${BUILD_DIR}/swift" \
    --disable-sandbox --skip-build --filter KeyAnalyzerTests
print "[4/7] PitchShiftTests"
swift test --package-path . --scratch-path "${BUILD_DIR}/swift" \
    --disable-sandbox --skip-build --filter PitchShiftTests
print "[5/7] Release build"
"${SCRIPT_DIR}/build-app.sh"
print "[6/7] DMG package"
"${SCRIPT_DIR}/package-dmg.sh"
print "[7/7] Release check"
"${SCRIPT_DIR}/release-check.sh"
print "拾响产品检查全部通过"

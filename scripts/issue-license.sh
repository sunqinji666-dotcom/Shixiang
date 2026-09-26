#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SCRATCH_DIR="${SHIXIANG_LICENSE_SCRATCH_PATH:-$(mktemp -d /private/tmp/shixiang-license.XXXXXX)}"
export CLANG_MODULE_CACHE_PATH="${SCRATCH_DIR}/clang"
export SWIFT_MODULECACHE_PATH="${SCRATCH_DIR}/swift"
mkdir -p "${CLANG_MODULE_CACHE_PATH}" "${SWIFT_MODULECACHE_PATH}"
trap 'if [[ -z "${SHIXIANG_LICENSE_SCRATCH_PATH:-}" ]]; then rm -rf "${SCRATCH_DIR}"; fi' EXIT
exec swift "${SCRIPT_DIR}/issue-license.swift" "$@"

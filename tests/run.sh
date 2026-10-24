#!/usr/bin/env bash
# Single entry for the gnu-cross contract suite.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "${root}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_clean_layout() {
    local hits
    hits=$(find "${root}" -maxdepth 3 \( -name docs -o -name '*superpowers*' \) -print)
    [[ -z "${hits}" ]] || fail "unexpected docs or superpowers path: ${hits}"
    if [[ -d "${root}/builder" ]]; then
        hits=$(find "${root}/builder" -mindepth 1 -print)
        [[ -z "${hits}" ]] || fail "builder submodule must stay unchecked: ${hits}"
    fi
    [[ ! -e "${root}/tests/test-alinux3-package-config.sh" ]] || fail "old alinux3 package test remains"
    [[ ! -e "${root}/tests/test-linux-kernel-mirror-fallback.sh" ]] || fail "old kernel mirror test remains"
    [[ ! -e "${root}/tests/test-release.sh" ]] || fail "old release test remains"
}

assert_clean_layout
bash "${root}/tests/test_config_and_patches.sh"
bash "${root}/tests/test_scripts_contract.sh"
bash "${root}/tests/test_upstream_sync.sh"
bash "${root}/tests/test_release_workflow.sh"
PYTHONDONTWRITEBYTECODE=1 python3 "${root}/tests/test_regressions.py"
PYTHONDONTWRITEBYTECODE=1 python3 "${root}/tests/test_runtime_guards.py"
assert_clean_layout
echo "gnu-cross tests: PASS"

#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
patch_file="${project_root}/targets/x86_64-unknown-linux-gnu/0001-linux-kernel-mirror-fallback.patch"
test_tree="$(mktemp -d)"

cleanup() {
    rm -rf "${test_tree}"
}
trap cleanup EXIT

if [ ! -f "${patch_file}" ]; then
    echo "FAIL: missing Linux kernel mirror fallback patch" >&2
    exit 1
fi

mkdir -p "${test_tree}/scripts"
cp "${project_root}/builder/scripts/functions" "${test_tree}/scripts/functions"
patch --silent --forward -Np1 -d "${test_tree}" < "${patch_file}"

functions_file="${test_tree}/scripts/functions"
for expected_mirror in \
    'https://mirrors.edge.kernel.org/pub/linux/kernel/v${version%%.*}.x' \
    'https://mirrors.aliyun.com/linux-kernel/v${version%%.*}.x' \
    'https://mirrors.tuna.tsinghua.edu.cn/kernel/v${version%%.*}.x'; do
    if ! grep -Fq "${expected_mirror}" "${functions_file}"; then
        echo "FAIL: missing kernel fallback ${expected_mirror}" >&2
        exit 1
    fi
done

echo "PASS: Linux kernel downloads have independent mirror fallbacks"

#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
probe_log="$(mktemp)"

cleanup() {
    rm -f "${probe_log}"
}
trap cleanup EXIT

# Make package-manager discovery deterministic without touching the host.
dnf() {
    return 0
}

yum() {
    return 0
}

# Sourcing a package configuration must be declarative. Record any attempted
# runtime probe so the test catches commands that can leave lock holders behind.
timeout() {
    printf '%s\n' "$*" >> "${probe_log}"
    return 124
}

# shellcheck source=/dev/null
source "${project_root}/scripts/packages/alinux3.conf"

if [ -s "${probe_log}" ]; then
    echo "FAIL: sourcing alinux3.conf executed a package-manager probe:" >&2
    cat "${probe_log}" >&2
    exit 1
fi

if [ "${USE_GCC10}" != false ]; then
    echo "FAIL: Alibaba Linux 3 must use its native GCC package" >&2
    exit 1
fi

for expected_package in gcc gcc-c++ libstdc++-static; do
    found=false
    for package in "${PACKAGES[@]}"; do
        if [ "${package}" = "${expected_package}" ]; then
            found=true
            break
        fi
    done
    if [ "${found}" != true ]; then
        echo "FAIL: missing native package ${expected_package}" >&2
        exit 1
    fi
done

echo "PASS: alinux3 package configuration is declarative"

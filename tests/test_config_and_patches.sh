#!/usr/bin/env bash
# Versions, defconfig selectors, and the kernel mirror patch against a temp builder tree.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
target_dir="${root}/targets/x86_64-unknown-linux-gnu"
versions="${target_dir}/versions"
config="${target_dir}/config"
patch_file="${target_dir}/0001-linux-kernel-mirror-fallback.patch"
source "${root}/tests/fixture.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/gnu-cross-config.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -f "${versions}" ]] || fail "versions file missing"
[[ -f "${config}" ]] || fail "config missing"
[[ -f "${patch_file}" ]] || fail "kernel mirror patch missing"

# shellcheck disable=SC1090
source "${versions}"
[[ "${CTNG_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || fail "ct-ng commit is not a SHA"

[[ "${CTNG_RELEASE_TAG}" =~ ^[A-Za-z0-9._+-]+$ ]] || fail "invalid ct-ng tag"
for value in "${EXPECTED_GCC_VERSION}" "${EXPECTED_MOLD_VERSION}" "${EXPECTED_BINUTILS_VERSION}" "${EXPECTED_LINUX_VERSION}"; do
    [[ "${value}" =~ ^[0-9]+(\.[0-9]+)+$ ]] || fail "invalid version: ${value}"
done
gcc_symbol="CT_GCC_V_${EXPECTED_GCC_VERSION%%.*}"
mold_symbol="CT_MOLD_V_${EXPECTED_MOLD_VERSION//./_}"
grep -qx "${gcc_symbol}=y" "${config}" || fail "config missing ${gcc_symbol}"
grep -qx "${mold_symbol}=y" "${config}" || fail "config missing ${mold_symbol}"
linux_series=${EXPECTED_LINUX_VERSION%.*}
grep -qx "CT_LINUX_V_${linux_series//./_}=y" "${config}" || fail "linux 5.4 selector missing"
grep -qx 'CT_LIBC_GLIBC=y' "${config}" || fail "glibc libc selector missing"
grep -qx 'CT_LINKER_MOLD=y' "${config}" || fail "mold linker selector missing"
[[ $(grep -cE '^CT_GCC_V_.*=y$' "${config}") -eq 1 ]] || fail "multiple GCC selectors"
[[ $(grep -cE '^CT_MOLD_V_.*=y$' "${config}") -eq 1 ]] || fail "multiple mold selectors"
! grep -qi musl "${config}" || fail "config mentions musl"
! grep -q '2\.44' "${config}" || fail "config promotes glibc 2.44"
! grep -q '^CT_GLIBC_V_' "${config}" || fail "checked-in config must not pin a host glibc selector"

readme="${root}/README.md"
readme_lines=$(wc -l < "${readme}")
[[ "${readme_lines}" -ge 110 && "${readme_lines}" -le 145 ]] || fail "README line count ${readme_lines} outside 110-145"
for heading in \
    "Overview" \
    "Targets & Component Matrix" \
    "Install" \
    "Usage" \
    "Build & Automated Release" \
    "Repository Layout" \
    "License"; do
    grep -qx "## ${heading}" "${readme}" || fail "README missing section ${heading}"
done
grep -q 'sha256sum --check' "${readme}" || fail "README install example lacks sha256sum --check"
grep -q 'targets/x86_64-unknown-linux-gnu/versions' "${readme}" || fail "README does not point at versions"
grep -q 'centos7' "${readme}" && grep -q '2\.17' "${readme}" || fail "README missing centos7 glibc 2.17"
grep -q 'amazonlinux2' "${readme}" && grep -q '2\.26' "${readme}" || fail "README missing amazonlinux2 glibc 2.26"
grep -q 'alinux3' "${readme}" && grep -q '2\.32' "${readme}" || fail "README missing alinux3 glibc 2.32"
grep -q 'ubuntu22' "${readme}" && grep -q '2\.34' "${readme}" || fail "README missing ubuntu22 glibc 2.34"
grep -q '2\.47' "${readme}" || fail "README missing binutils 2.47"
grep -q '5\.4\.302' "${readme}" || fail "README missing Linux 5.4.302"
grep -q '\./scripts/build-with-docker\.sh' "${readme}" || fail "README missing docker build command"
grep -q '\./scripts/make' "${readme}" || fail "README missing make command"
grep -q 'v0\.0\.1' "${readme}" || fail "README missing v0.0.1"
! grep -Eiq '(^|[^[:alnum:]_])docs([^[:alnum:]_]|$)|superpowers' "${readme}" || fail "README mentions docs or superpowers"
for entry in 'builder/' 'scripts/' 'targets/' 'tests/' '.github/workflows/'; do
    grep -F -q "${entry}" "${readme}" || fail "README layout missing ${entry}"
done

mkdir -p "${work}/scripts"
write_builder_functions "${work}/scripts/functions"
patch --fuzz=0 --batch --dry-run -Np1 -d "${work}" -i "${patch_file}" >/dev/null
patch --fuzz=0 --batch -Np1 -d "${work}" -i "${patch_file}" >/dev/null
grep -F -q 'https://mirrors.edge.kernel.org/pub/linux/kernel/v${version%%.*}.x' "${work}/scripts/functions" || fail "edge mirror missing"
grep -F -q 'https://mirrors.aliyun.com/linux-kernel/v${version%%.*}.x' "${work}/scripts/functions" || fail "aliyun mirror missing"
grep -F -q 'https://mirrors.tuna.tsinghua.edu.cn/kernel/v${version%%.*}.x' "${work}/scripts/functions" || fail "tuna mirror missing"

if [[ -d "${root}/builder" ]]; then
    builder_hits=$(find "${root}/builder" -mindepth 1 -print)
    [[ -z "${builder_hits}" ]] || fail "patch test wrote into gnu-cross/builder"
fi

echo "config and patches: PASS"

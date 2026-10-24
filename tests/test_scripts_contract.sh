#!/usr/bin/env bash
# Shell syntax, declarative package configs, verifier isolation, and make argument checks.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/gnu-cross-scripts.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

while IFS= read -r -d '' file; do
    bash -n "${file}" || fail "bash -n failed: ${file}"
done < <(find "${root}/scripts" "${root}/tests" -type f \
    \( -name '*.sh' -o -name '*.conf' -o -name 'make' \) -print0)

conf_dir="${root}/scripts/packages"
mapfile -t confs < <(find "${conf_dir}" -maxdepth 1 -name '*.conf' | sort)
[[ ${#confs[@]} -eq 8 ]] || fail "expected 8 package configs, found ${#confs[@]}"

stub="${work}/stub"
mkdir -p "${stub}"
cat > "${stub}/record" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >> "${STUB_LOG}"
exit 99
EOF
chmod +x "${stub}/record"
for name in timeout yum dnf apt-get pacman apk pip curl wget python3 bash sudo; do
    ln -s record "${stub}/${name}"
done

for conf in "${confs[@]}"; do
    log="${work}/$(basename "${conf}").log"
    : > "${log}"
    (
        set -euo pipefail
        export PATH="${stub}:${PATH}"
        export STUB_LOG="${log}"
        # shellcheck disable=SC1090
        source "${conf}"
        [[ ${#MIRROR_SETUP_COMMANDS[@]} -eq 0 ]]
        [[ ${#EXTRA_SETUP_COMMANDS[@]} -eq 0 ]]
        [[ -n "${PKG_MANAGER}" ]]
        case "$(basename "${conf}")" in
            amazonlinux2.conf|alinux3.conf|centos7.conf|ubuntu22.conf)
                printf '%s\n' "${PACKAGES[@]}" | grep -qx 'util-linux'
                ;;
        esac
    ) || fail "declarative source failed: ${conf}"
    [[ ! -s "${log}" ]] || fail "sourcing $(basename "${conf}") invoked external commands: $(cat "${log}")"
done

grep -qx 'USE_GCC10=false' "${conf_dir}/alinux3.conf" || fail "alinux3 must keep native GCC"
! grep -q 'gcc10-gcc' "${conf_dir}/alinux3.conf" || fail "alinux3 still carries the GCC 10 alternatives branch"
grep -qx 'USE_PIP_CMAKE=false' "${conf_dir}/rhel.conf" || fail "rhel pip cmake must be gated off"
grep -F -q '$basearch' "${conf_dir}/centos7.conf" || fail "centos7 SCL repo lost the literal \$basearch"
! grep -q 'check-update || true' "${conf_dir}"/*.conf || fail "package configs swallow check-update failures"

make_script="${root}/scripts/make"
grep -q 'set -euo pipefail' "${make_script}" || fail "make lacks strict mode"
grep -q 'git rev-parse --is-inside-work-tree' "${make_script}" || fail "make lacks worktree guard"
grep -q 'git rev-parse --show-toplevel' "${make_script}" || fail "make lacks toplevel guard"
grep -q 'patch --fuzz=0 --batch -Np1' "${make_script}" || fail "make patch command is loose"
grep -q 'verify-toolchain.sh' "${make_script}" || fail "make does not call the verifier"
grep -q 'tar -C /opt/x-tools' "${make_script}" || fail "make does not archive from /opt/x-tools"
grep -q 'x86_64-unknown-linux-gnu' "${make_script}" || fail "make usage lost the gnu triple"
! grep -q 'alias grep' "${make_script}" || fail "make still aliases grep"
! grep -Eq '(^|[^[:alnum:]_])eval([^[:alnum:]_]|$)' "${make_script}" || fail "make still evals shell"
! grep -q 'chmod 0777 /opt' "${make_script}" || fail "make still relaxes /opt"
! grep -q 'mv /opt/x-tools' "${make_script}" || fail "make still moves the install tree into the repo"
! grep -qi musl "${make_script}" || fail "make mentions musl"

set +e
bash "${make_script}" >"${work}/make-none.out" 2>"${work}/make-none.err"
status=$?
set -e
[[ ${status} -eq 64 ]] || fail "make with no args exited ${status}"

set +e
bash "${make_script}" not-a-target >"${work}/make-bad.out" 2>"${work}/make-bad.err"
status=$?
set -e
[[ ${status} -eq 1 ]] || fail "make bad target exited ${status}"

set +e
bash "${make_script}" x86_64-unknown-linux-gnu --bogus >"${work}/make-flag.out" 2>"${work}/make-flag.err"
status=$?
set -e
[[ ${status} -eq 64 ]] || fail "make unknown flag exited ${status}"

docker_script="${root}/scripts/build-with-docker.sh"
grep -q 'set -euo pipefail' "${docker_script}" || fail "docker script lacks strict mode"
grep -q 'seccomp=unconfined' "${docker_script}" || fail "docker script lacks seccomp=unconfined"
grep -q '\[alinux3-module\]' "${docker_script}" || fail "alinux3 module repo missing"
grep -q 'OS_LABEL' "${docker_script}" || fail "docker script ignores OS_LABEL"
grep -q 'BUILD_TARGET' "${docker_script}" || fail "docker script does not pass BUILD_TARGET"
grep -q 'BUILD_OS_LABEL' "${docker_script}" || fail "docker script does not pass BUILD_OS_LABEL"
grep -q 'Checksum verification passed' "${docker_script}" || fail "docker script lacks checksum confirmation"
set +e
bash "${docker_script}" >"${work}/docker-none.out" 2>"${work}/docker-none.err"
status=$?
set -e
[[ ${status} -eq 64 ]] || fail "docker script with no args exited ${status}"

verify="${root}/scripts/verify-toolchain.sh"
set +e
bash "${verify}" >"${work}/verify-none.out" 2>"${work}/verify-none.err"
status=$?
set -e
[[ ${status} -eq 64 ]] || fail "verifier with no args exited ${status}"
grep -q 'Usage:' "${work}/verify-none.err" || fail "verifier usage missing"

set +e
bash "${verify}" only-one >"${work}/verify-one.out" 2>"${work}/verify-one.err"
status=$?
set -e
[[ ${status} -eq 64 ]] || fail "verifier with one arg exited ${status}"

target=x86_64-unknown-linux-gnu
tool="${work}/tool"
sysroot="${tool}/sysroot"
leak="${work}/host-leak/libgcc_s.so.1"
mkdir -p "${tool}/bin" "${tool}/${target}/bin" "${sysroot}/lib" "$(dirname "${leak}")"
printf 'placeholder\n' > "${sysroot}/lib/libc.so.6"
printf 'leaked\n' > "${leak}"
cat > "${tool}/bin/${target}-gcc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    -dumpfullversion)
        printf '%s\n' "${FAKE_GCC_VERSION}"
        ;;
    -print-sysroot)
        printf '%s\n' "${FAKE_SYSROOT}"
        ;;
    -print-file-name=*)
        name=${1#*=}
        if [[ "${name}" == "libgcc_s.so.1" ]]; then
            printf '%s\n' "${LEAK_PATH}"
        else
            printf '%s\n' "${FAKE_TOOLCHAIN}/lib/${name}"
        fi
        ;;
    *)
        printf 'unexpected compiler args: %s\n' "$*" >&2
        exit 1
        ;;
esac
EOF
cp "${tool}/bin/${target}-gcc" "${tool}/bin/${target}-g++"
printf '#!/bin/sh\nexit 0\n' > "${tool}/${target}/bin/ld.mold"
chmod +x "${tool}/bin/${target}-gcc" "${tool}/bin/${target}-g++" "${tool}/${target}/bin/ld.mold"

set +e
FAKE_GCC_VERSION=16.2.0 \
    FAKE_SYSROOT="${sysroot}" \
    FAKE_TOOLCHAIN="${tool}" \
    LEAK_PATH="${leak}" \
    bash "${verify}" "${target}" "${tool}" 16.2.0 >"${work}/verify-leak.out" 2>"${work}/verify-leak.err"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "host library leak was accepted"
grep -q 'host runtime leak' "${work}/verify-leak.err" || fail "leak diagnostic missing: $(cat "${work}/verify-leak.err")"
! grep -q 'toolchain runtime verification: PASS' "${work}/verify-leak.out" || fail "verifier passed after a host leak"

echo "scripts contract: PASS"

#!/usr/bin/env bash
# Runtime checks for an installed x86_64 glibc toolchain.
set -euo pipefail

usage() {
    echo "Usage: $0 <target> <toolchain-dir> <gcc-version> [expected-glibc-version]" >&2
    exit 64
}

[[ $# -eq 3 || $# -eq 4 ]] || usage

target=$1
toolchain_root=$(realpath -e -- "$2")
[[ -d "${toolchain_root}" ]] || { echo "toolchain directory missing" >&2; exit 1; }
toolchain_dir=${toolchain_root}
contained_path() {
    local resolved
    resolved=$(realpath -e -- "$1") || return 1
    case "${resolved}" in "${toolchain_root}"|"${toolchain_root}"/*) ;;
        *) echo "host runtime leak: $1 -> ${resolved}" >&2; return 1;; esac
    [[ "${resolved}" != *:* && "${resolved}" != *$'\n'* ]] || return 1
    printf '%s\n' "${resolved}"
}
expected_gcc=$3
expected_glibc=${4:-}
cc="${toolchain_dir}/bin/${target}-gcc"
cxx="${toolchain_dir}/bin/${target}-g++"
mold="${toolchain_dir}/${target}/bin/ld.mold"
verify_cflags=(-Wall -Wextra -Werror)

[[ -x "${cc}" ]] || { echo "compiler not found: ${cc}" >&2; exit 1; }
[[ -x "${cxx}" ]] || { echo "C++ compiler not found: ${cxx}" >&2; exit 1; }
[[ -x "${mold}" ]] || { echo "mold linker not found: ${mold}" >&2; exit 1; }

cc=$(contained_path "${cc}")
cxx=$(contained_path "${cxx}")
mold=$(contained_path "${mold}")
actual_gcc=$("${cc}" -dumpfullversion)
[[ "${actual_gcc}" == "${expected_gcc}" ]] || {
    echo "GCC version mismatch: ${actual_gcc} != ${expected_gcc}" >&2
    exit 1
}

sysroot=$(contained_path "$("${cc}" -print-sysroot)")
[[ -n "${sysroot}" && -d "${sysroot}" ]] || {
    echo "sysroot not found: ${sysroot}" >&2
    exit 1
}

libc=""
for candidate in \
    "${sysroot}/lib/libc.so.6" \
    "${sysroot}/lib64/libc.so.6" \
    "${sysroot}/usr/lib/libc.so.6" \
    "${sysroot}/usr/lib64/libc.so.6"; do
    if [[ -e "${candidate}" ]]; then
        libc=${candidate}
        break
    fi
done
if [[ -z "${libc}" ]]; then
    libc=$(find "${sysroot}" -name 'libc.so.6' -print -quit 2>/dev/null || true)
fi
[[ -n "${libc}" && -e "${libc}" ]] || {
    echo "libc.so.6 not found under ${sysroot}" >&2
    exit 1
}

libc=$(contained_path "${libc}")

glibc_header_matches() {
    local header=$1 major="" minor="" combined
    [[ -f "${header}" ]] || return 1
    major=$(sed -n 's/^[[:space:]]*#[[:space:]]*define[[:space:]]\+__GLIBC__[[:space:]]\+\([0-9][0-9]*\).*/\1/p' "${header}" | head -n 1)
    minor=$(sed -n 's/^[[:space:]]*#[[:space:]]*define[[:space:]]\+__GLIBC_MINOR__[[:space:]]\+\([0-9][0-9]*\).*/\1/p' "${header}" | head -n 1)
    if [[ -n "${major}" && -n "${minor}" ]]; then
        combined="${major}.${minor}"
        [[ "${combined}" == "${expected_glibc}" ]]
        return
    fi
    grep -Eq "(^|[^0-9])${expected_glibc}([^0-9]|$)" "${header}"
}


runtime_dirs=()
for runtime_dir in "${sysroot}/lib" "${sysroot}/lib64" "${sysroot}/usr/lib" "${sysroot}/usr/lib64"; do
    if [[ -d "${runtime_dir}" ]]; then
        runtime_dirs+=("$(contained_path "${runtime_dir}")")
    fi
done

for runtime in libgcc_s.so.1 libstdc++.so.6 libgomp.so.1 libquadmath.so.0 \
               libasan.so libubsan.so liblsan.so libtsan.so; do
    runtime_path=$("${cc}" -print-file-name="${runtime}")
    [[ -n "${runtime_path}" && "${runtime_path}" != "${runtime}" && -e "${runtime_path}" ]] || {
        echo "target runtime not found: ${runtime}" >&2
        exit 1
    }
    resolved=$(contained_path "${runtime_path}")
    case "${resolved}" in
        "${toolchain_root}" | "${toolchain_root}"/*) ;;
        *)
            echo "host runtime leak: ${runtime} -> ${resolved}" >&2
            exit 1
            ;;
    esac
    runtime_dirs+=("$(dirname "${resolved}")")
done

loader=""
for candidate in \
    "${sysroot}/lib/ld-linux-x86-64.so.2" \
    "${sysroot}/lib64/ld-linux-x86-64.so.2" \
    "${sysroot}/usr/lib64/ld-linux-x86-64.so.2"; do
    if [[ -e "${candidate}" && -x "${candidate}" ]]; then
        loader=${candidate}
        break
    fi
done
if [[ -z "${loader}" ]]; then
    loader=$(find "${sysroot}" -name 'ld-linux-x86-64.so.2' -print -quit 2>/dev/null || true)
fi
[[ -n "${loader}" && -x "${loader}" ]] || {
    echo "glibc loader not found under ${sysroot}" >&2
    exit 1
}
loader_resolved=$(contained_path "${loader}")
loader=${loader_resolved}
case "${loader_resolved}" in
    "${toolchain_root}" | "${toolchain_root}"/*) ;;
    *)
        echo "host runtime leak: ld-linux-x86-64.so.2 -> ${loader_resolved}" >&2
        exit 1
        ;;
esac

runtime_library_path=$(IFS=:; echo "${runtime_dirs[*]}")
if [[ -n "${expected_glibc}" ]]; then
    matched=false
    header=$(find "${sysroot}" -path '*/gnu/libc-version.h' -print -quit 2>/dev/null || true)
    if [[ -n "${header}" ]]; then header=$(contained_path "${header}"); fi
    if [[ -n "${header}" ]] && glibc_header_matches "${header}"; then
        matched=true
    fi
    if [[ "${matched}" == false ]]; then
        banner=$("${loader}" --library-path "${runtime_library_path}" "${libc}" 2>&1 || true)
        if grep -Eq "version ${expected_glibc}([^0-9]|$)" <<<"${banner}"; then
            matched=true
        fi
    fi
    [[ "${matched}" == true ]] || {
        echo "glibc version mismatch: expected ${expected_glibc}" >&2
        exit 1
    }
fi

verify_tmp=$(mktemp -d "${TMPDIR:-/tmp}/gnu-cross-verify.XXXXXX")
cleanup() { rm -rf -- "${verify_tmp}"; }
trap cleanup EXIT

run_dynamic() {
    timeout 30 "${loader}" --library-path "${runtime_library_path}" "$@"
}

expect_failure() {
    local name=$1 pattern=$2 program=$3 output status
    set +e
    output=$(ASAN_OPTIONS=halt_on_error=1:exitcode=86 UBSAN_OPTIONS=halt_on_error=1:exitcode=86 LSAN_OPTIONS=use_tls=0:use_ld_allocations=0:exitcode=86 timeout 30 "${loader}" --library-path "${runtime_library_path}" "${program}" 2>&1)
    status=$?
    set -e
    [[ ${status} -ne 124 && ${status} -ne 137 ]] || { echo "${name} timed out or was killed (${status})" >&2; exit 1; }
    [[ ${status} -eq 86 ]] || { echo "${name} unexpected sanitizer exit ${status}: ${output}" >&2; exit 1; }
    grep -Eq "${pattern}" <<<"${output}" || {
        echo "${name} diagnostic missing: ${output}" >&2
        exit 1
    }
}

expect_tsan_failure() {
    local program=$1 output status
    command -v setarch >/dev/null || {
        echo "setarch is required for the TSan no-ASLR runtime check" >&2
        exit 1
    }
    set +e
    output=$(TSAN_OPTIONS=halt_on_error=1:exitcode=66 timeout 30 setarch x86_64 -R "${loader}" \
        --library-path "${runtime_library_path}" "${program}" 2>&1)
    status=$?
    set -e
    [[ ${status} -ne 124 && ${status} -ne 137 ]] || { echo "TSan timed out or was killed (${status})" >&2; exit 1; }
    [[ ${status} -eq 66 ]] || { echo "TSan unexpected sanitizer exit ${status}" >&2; exit 1; }
    grep -Eq 'ThreadSanitizer: data race' <<<"${output}" || {
        echo "TSan data race diagnostic missing: ${output}" >&2
        exit 1
    }
}

cat >"${verify_tmp}/hello.c" <<'EOF'
#include <stdio.h>
int main(void) { puts("C PASS"); return 0; }
EOF
timeout 30 "${cc}" "${verify_cflags[@]}" -static "${verify_tmp}/hello.c" -o "${verify_tmp}/hello-c"
[[ "$(timeout 30 "${verify_tmp}/hello-c")" == "C PASS" ]]

cat >"${verify_tmp}/hello.cc" <<'EOF'
#include <iostream>
int main() { std::cout << "C++ PASS\n"; }
EOF
timeout 30 "${cxx}" "${verify_cflags[@]}" -static "${verify_tmp}/hello.cc" -o "${verify_tmp}/hello-cxx"
[[ "$(timeout 30 "${verify_tmp}/hello-cxx")" == "C++ PASS" ]]

timeout 30 "${cc}" "${verify_cflags[@]}" "${verify_tmp}/hello.c" -o "${verify_tmp}/hello-dynamic"
[[ "$(run_dynamic "${verify_tmp}/hello-dynamic")" == "C PASS" ]]

timeout 30 "${cxx}" "${verify_cflags[@]}" "${verify_tmp}/hello.cc" -o "${verify_tmp}/hello-cxx-dynamic"
[[ "$(run_dynamic "${verify_tmp}/hello-cxx-dynamic")" == "C++ PASS" ]]

cat >"${verify_tmp}/openmp.c" <<'EOF'
#include <omp.h>
#include <stdio.h>
int main(void) { int n = 0;
#pragma omp parallel reduction(+:n) num_threads(2)
n += 1; printf("%d\n", n); return n == 2 ? 0 : 1; }
EOF
timeout 30 "${cc}" "${verify_cflags[@]}" -fopenmp "${verify_tmp}/openmp.c" -o "${verify_tmp}/openmp"
[[ "$(run_dynamic "${verify_tmp}/openmp")" == 2 ]]

cat >"${verify_tmp}/quadmath.c" <<'EOF'
#include <quadmath.h>
#include <stdio.h>
int main(void) { char s[32]; quadmath_snprintf(s,sizeof s,"%.2Qf",(__float128)1.25); puts(s); }
EOF
timeout 30 "${cc}" "${verify_cflags[@]}" "${verify_tmp}/quadmath.c" -lquadmath -o "${verify_tmp}/quadmath"
[[ "$(run_dynamic "${verify_tmp}/quadmath")" == 1.25 ]]

timeout 30 "${mold}" --version | grep -qi mold
timeout 30 "${cc}" "${verify_cflags[@]}" -static -fuse-ld=mold "${verify_tmp}/hello.c" -o "${verify_tmp}/hello-mold"
[[ "$(timeout 30 "${verify_tmp}/hello-mold")" == "C PASS" ]]

cat >"${verify_tmp}/asan.c" <<'EOF'
#include <stdlib.h>
int main(void) { char *p=malloc(4); p[8]=1; return p[8]; }
EOF
timeout 30 "${cc}" "${verify_cflags[@]}" -O0 -g -fsanitize=address -fno-omit-frame-pointer "${verify_tmp}/asan.c" -o "${verify_tmp}/asan"
expect_failure ASan AddressSanitizer "${verify_tmp}/asan"

cat >"${verify_tmp}/ubsan.c" <<'EOF'
#include <limits.h>
int main(void) { volatile int v=INT_MAX; return v+1; }
EOF
timeout 30 "${cc}" "${verify_cflags[@]}" -O0 -g -fsanitize=undefined -fno-sanitize-recover=undefined "${verify_tmp}/ubsan.c" -o "${verify_tmp}/ubsan"
expect_failure UBSan 'runtime error|signed integer overflow' "${verify_tmp}/ubsan"

cat >"${verify_tmp}/lsan.c" <<'EOF'
#include <stdlib.h>
int main(void) {
    void *leaked = malloc(128);
    if (!leaked) return 1;
    ((volatile unsigned char *)leaked)[0] = 1;
    leaked = NULL;
    return leaked != NULL;
}
EOF
timeout 30 "${cc}" "${verify_cflags[@]}" -fPIE -pie -O0 -g -fsanitize=leak "${verify_tmp}/lsan.c" -o "${verify_tmp}/lsan"
expect_failure LSan 'LeakSanitizer|detected memory leaks' "${verify_tmp}/lsan"

cat >"${verify_tmp}/tsan.c" <<'EOF'
#include <pthread.h>
static pthread_barrier_t gate;
static volatile int shared;
static void *write_shared(void *unused) {
    (void)unused;
    pthread_barrier_wait(&gate);
    for (int i = 0; i < 100000; ++i) shared++;
    return NULL;
}
int main(void) {
    pthread_t thread;
    if (pthread_barrier_init(&gate, NULL, 2) != 0) return 1;
    if (pthread_create(&thread, NULL, write_shared, NULL) != 0) return 2;
    pthread_barrier_wait(&gate);
    for (int i = 0; i < 100000; ++i) shared++;
    if (pthread_join(thread, NULL) != 0) return 3;
    pthread_barrier_destroy(&gate);
    return 0;
}
EOF
timeout 30 "${cc}" "${verify_cflags[@]}" -O0 -g -fsanitize=thread -pthread "${verify_tmp}/tsan.c" -o "${verify_tmp}/tsan"
expect_tsan_failure "${verify_tmp}/tsan"

echo "toolchain runtime verification: PASS"

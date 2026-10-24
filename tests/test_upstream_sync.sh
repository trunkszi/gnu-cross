#!/usr/bin/env bash
# Offline sync-upstream scenarios: no change, gcc/mold upgrade, and patch conflict.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
origin_script="${root}/scripts/sync-upstream.sh"
origin_targets="${root}/targets"
work=$(mktemp -d "${TMPDIR:-/tmp}/gnu-cross-upstream.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

source "${root}/targets/x86_64-unknown-linux-gnu/versions"
pin_commit=${CTNG_COMMIT}
pin_tag=${CTNG_RELEASE_TAG}
pin_binutils=${EXPECTED_BINUTILS_VERSION}
pin_linux=${EXPECTED_LINUX_VERSION}
pin_release=${EXPECTED_RELEASE_TAG}
tag_object=8aec57150c5ff359eda68f6986c74b7465f922b7
new_commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
[[ "${new_commit}" != "${pin_commit}" ]] || new_commit=cccccccccccccccccccccccccccccccccccccccc
source "${root}/tests/fixture.sh"

stub="${work}/stub"
mkdir -p "${stub}"
cat > "${stub}/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "${STUB_LOG}"
exit 1
EOF
cat > "${stub}/git" <<'EOF'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "${STUB_LOG}"
exit 1
EOF
chmod +x "${stub}/curl" "${stub}/git"

new_sandbox() {
    local dest=$1
    mkdir -p "${dest}/scripts"
    cp "${origin_script}" "${dest}/scripts/sync-upstream.sh"
    chmod +x "${dest}/scripts/sync-upstream.sh"
    cp -a "${origin_targets}" "${dest}/targets"
}

write_release() {
    local path=$1 tag=$2
    cat > "${path}" <<EOF
{"tag_name":"${tag}","draft":false,"prerelease":false,"target_commitish":"master"}
EOF
}

write_ref() {
    local path=$1 type=$2 sha=$3
    cat > "${path}" <<EOF
{"object":{"type":"${type}","sha":"${sha}"}}
EOF
}

make_builder() {
    local dest=$1 functions_mode=$2
    mkdir -p \
        "${dest}/packages/gcc/17.1.0/experimental" \
        "${dest}/packages/gcc/18.0.0" \
        "${dest}/packages/mold/2.9.0" \
        "${dest}/packages/mold/2.42.0" \
        "${dest}/scripts"
    printf "relevantpattern='4.*|. *|.'\n" > "${dest}/packages/gcc/package.desc"
    printf 'origin=git\n' > "${dest}/packages/gcc/17.1.0/version.desc"
    printf 'patch-dir\n' > "${dest}/packages/gcc/17.1.0/experimental/README"
    printf 'experimental=yes\n' > "${dest}/packages/gcc/18.0.0/version.desc"
    printf 'origin=git\n' > "${dest}/packages/mold/package.desc"
    printf 'origin=git\n' > "${dest}/packages/mold/2.9.0/version.desc"
    printf 'origin=git\n' > "${dest}/packages/mold/2.42.0/version.desc"
    if [[ "${functions_mode}" == "conflict" ]]; then
        printf 'this is not the crosstool-NG functions file\n' > "${dest}/scripts/functions"
    else
        write_builder_functions "${dest}/scripts/functions"
    fi
}

run_sync() {
    local sandbox=$1 mode=$2 summary=$3
    shift 3
    local log="${work}/stub.log"
    : > "${log}"
    set +e
    STUB_LOG="${log}" PATH="${stub}:${PATH}" \
        UPSTREAM_RELEASE_JSON_FILE="${release_json}" \
        UPSTREAM_REF_JSON_FILE="${ref_json}" \
        UPSTREAM_TAG_JSON_FILE="${tag_json}" \
        UPSTREAM_BUILDER_DIR="${builder_dir}" \
        bash "${sandbox}/scripts/sync-upstream.sh" "${mode}" --summary-file "${summary}" \
        >"${work}/sync.out" 2>"${work}/sync.err"
    sync_status=$?
    set -e
}

field() {
    sed -n "s/^$1=//p" "${work}/sync.out" | tail -n 1
}

digest() {
    sha256sum "$1" | awk '{ print $1 }'
}

release_json="${work}/release.json"
ref_json="${work}/ref.json"
tag_json="${work}/tag.json"
builder_dir="${work}/builder-fixture"
summary="${work}/summary.md"

# Discovery failures never look like "no change".
sandbox="${work}/discover"
new_sandbox "${sandbox}"
: > "${summary}"
release_json="${work}/missing-release.json"
rm -f "${release_json}"
run_sync "${sandbox}" --check "${summary}"
[[ ${sync_status} -ne 0 ]] || fail "missing release JSON exited 0"
grep -q 'DISCOVERY_FAILED' "${work}/sync.err" || fail "missing release JSON lacked DISCOVERY_FAILED"
grep -q '::error title=DISCOVERY_FAILED::' "${work}/sync.out" || fail "missing release JSON lacked annotation"

write_release "${work}/release.json" "${CTNG_RELEASE_TAG}"
release_json="${work}/release.json"
ref_json="${work}/missing-ref.json"
rm -f "${ref_json}"
run_sync "${sandbox}" --check "${summary}"
[[ ${sync_status} -ne 0 ]] || fail "missing ref JSON exited 0"
grep -q 'DISCOVERY_FAILED' "${work}/sync.err" || fail "missing ref JSON lacked DISCOVERY_FAILED"

cat > "${work}/draft.json" <<'EOF'
{"tag_name":"crosstool-ng-9.9.9","draft":true,"prerelease":false,"target_commitish":"master"}
EOF
release_json="${work}/draft.json"
run_sync "${sandbox}" --check "${summary}"
[[ ${sync_status} -ne 0 ]] || fail "draft release exited 0"
grep -q 'DISCOVERY_FAILED' "${work}/sync.err" || fail "draft release lacked DISCOVERY_FAILED"

set +e
bash "${origin_script}" >"${work}/usage.out" 2>"${work}/usage.err"
usage_status=$?
set -e
[[ ${usage_status} -eq 64 ]] || fail "sync usage exited ${usage_status}"
set +e
bash "${origin_script}" --check --apply >"${work}/usage.out" 2>"${work}/usage.err"
usage_status=$?
set -e
[[ ${usage_status} -eq 64 ]] || fail "sync with both modes exited ${usage_status}"

# Annotated tag peels to the accepted commit even when target_commitish is master.
sandbox="${work}/same"
new_sandbox "${sandbox}"
versions_before=$(digest "${sandbox}/targets/x86_64-unknown-linux-gnu/versions")
config_before=$(digest "${sandbox}/targets/x86_64-unknown-linux-gnu/config")
write_release "${work}/release.json" "${CTNG_RELEASE_TAG}"
write_ref "${work}/ref.json" tag "${tag_object}"
write_ref "${work}/tag.json" commit "${pin_commit}"
release_json="${work}/release.json"
ref_json="${work}/ref.json"
tag_json="${work}/tag.json"
builder_dir="${work}/unused-builder"
run_sync "${sandbox}" --check "${summary}"
[[ ${sync_status} -eq 0 ]] || fail "no_update exited ${sync_status}: $(cat "${work}/sync.err")"
[[ "$(field status)" == "no_update" ]] || fail "expected no_update, got $(field status)"
[[ "$(field should_build)" == "false" ]] || fail "no_update should_build was $(field should_build)"
[[ "$(field upstream_updated)" == "false" ]] || fail "no_update upstream_updated was $(field upstream_updated)"
[[ "$(digest "${sandbox}/targets/x86_64-unknown-linux-gnu/versions")" == "${versions_before}" ]] || fail "no_update rewrote versions"
[[ "$(digest "${sandbox}/targets/x86_64-unknown-linux-gnu/config")" == "${config_before}" ]] || fail "no_update rewrote config"
[[ ! -s "${work}/stub.log" ]] || fail "no_update called the network: $(cat "${work}/stub.log")"

# A newer release selects GCC 17.1.0 and mold 2.42.0 without moving glibc or Linux.
sandbox="${work}/upgrade"
new_sandbox "${sandbox}"
make_builder "${work}/builder-ok" apply
builder_dir="${work}/builder-ok"
write_release "${work}/release.json" "crosstool-ng-1.30.0"
write_ref "${work}/ref.json" commit "${new_commit}"
printf '{}\n' > "${work}/tag.json"
versions_before=$(digest "${sandbox}/targets/x86_64-unknown-linux-gnu/versions")
config_before=$(digest "${sandbox}/targets/x86_64-unknown-linux-gnu/config")
run_sync "${sandbox}" --check "${summary}"
[[ ${sync_status} -eq 0 ]] || fail "check update exited ${sync_status}: $(cat "${work}/sync.err") $(cat "${work}/sync.out")"
[[ "$(field status)" == "update_available" ]] || fail "check status was $(field status)"
[[ "$(field should_build)" == "true" ]] || fail "check should_build was $(field should_build)"
[[ "$(field upstream_updated)" == "false" ]] || fail "check upstream_updated was $(field upstream_updated)"
[[ "$(field latest_gcc)" == "17.1.0" ]] || fail "latest gcc was $(field latest_gcc)"
[[ "$(field latest_mold)" == "2.42.0" ]] || fail "latest mold was $(field latest_mold)"
[[ "$(field gcc_selector)" == "CT_GCC_V_17" ]] || fail "gcc selector was $(field gcc_selector)"
[[ "$(field mold_selector)" == "CT_MOLD_V_2_42_0" ]] || fail "mold selector was $(field mold_selector)"
[[ "$(digest "${sandbox}/targets/x86_64-unknown-linux-gnu/versions")" == "${versions_before}" ]] || fail "--check wrote versions"
[[ "$(digest "${sandbox}/targets/x86_64-unknown-linux-gnu/config")" == "${config_before}" ]] || fail "--check wrote config"
[[ ! -s "${work}/stub.log" ]] || fail "offline update called the network: $(cat "${work}/stub.log")"

run_sync "${sandbox}" --apply "${summary}"
[[ ${sync_status} -eq 0 ]] || fail "apply exited ${sync_status}: $(cat "${work}/sync.err") $(cat "${work}/sync.out")"
[[ "$(field status)" == "updated" ]] || fail "apply status was $(field status)"
[[ "$(field should_build)" == "true" ]] || fail "apply should_build was $(field should_build)"
[[ "$(field upstream_updated)" == "true" ]] || fail "apply upstream_updated was $(field upstream_updated)"
# shellcheck disable=SC1090
source "${sandbox}/targets/x86_64-unknown-linux-gnu/versions"
[[ "${CTNG_RELEASE_TAG}" == "crosstool-ng-1.30.0" ]] || fail "tag not updated"
[[ "${CTNG_COMMIT}" == "${new_commit}" ]] || fail "commit not updated"
[[ "${EXPECTED_GCC_VERSION}" == "17.1.0" ]] || fail "gcc not updated"
[[ "${EXPECTED_MOLD_VERSION}" == "2.42.0" ]] || fail "mold not updated"
[[ "${EXPECTED_BINUTILS_VERSION}" == "${pin_binutils}" ]] || fail "binutils changed"
[[ "${EXPECTED_LINUX_VERSION}" == "${pin_linux}" ]] || fail "linux changed"
[[ "${EXPECTED_RELEASE_TAG}" == "${pin_release}" ]] || fail "release tag changed"
applied_config="${sandbox}/targets/x86_64-unknown-linux-gnu/config"
grep -qx 'CT_GCC_V_17=y' "${applied_config}" || fail "applied config missing CT_GCC_V_17"
grep -qx 'CT_MOLD_V_2_42_0=y' "${applied_config}" || fail "applied config missing CT_MOLD_V_2_42_0"
! grep -q '^CT_GCC_V_16=' "${applied_config}" || fail "old GCC selector remains"
! grep -q '^CT_MOLD_V_2_41_0=' "${applied_config}" || fail "old mold selector remains"
grep -qx 'CT_LINUX_V_5_4=y' "${applied_config}" || fail "linux selector lost"
grep -qx 'CT_LIBC_GLIBC=y' "${applied_config}" || fail "glibc selector lost"
! grep -qi musl "${applied_config}" || fail "apply introduced musl"
! grep -q '2\.44' "${applied_config}" || fail "apply promoted glibc"

# A conflicting patch blocks publication and leaves the lock untouched.
sandbox="${work}/conflict"
new_sandbox "${sandbox}"
make_builder "${work}/builder-bad" conflict
builder_dir="${work}/builder-bad"
versions_before=$(digest "${sandbox}/targets/x86_64-unknown-linux-gnu/versions")
config_before=$(digest "${sandbox}/targets/x86_64-unknown-linux-gnu/config")
: > "${summary}"
run_sync "${sandbox}" --apply "${summary}"
[[ ${sync_status} -ne 0 ]] || fail "patch conflict exited 0"
grep -q '::error title=UPSTREAM_PATCH_CONFLICT::' "${work}/sync.out" || fail "conflict annotation missing: $(cat "${work}/sync.out")"
grep -q 'UPSTREAM_PATCH_CONFLICT' "${summary}" || fail "summary heading missing"
grep -q 'Published v0.0.1 Release: UNTOUCHED' "${summary}" || fail "summary did not say the release is untouched"
grep -F -q "${pin_tag}" "${summary}" || fail "summary missing accepted tag"
grep -q 'crosstool-ng-1.30.0' "${summary}" || fail "summary missing candidate tag"
grep -q "${pin_commit}" "${summary}" || fail "summary missing accepted commit"
grep -q "${new_commit}" "${summary}" || fail "summary missing candidate commit"
grep -q '0001-linux-kernel-mirror-fallback.patch' "${summary}" || fail "summary missing patch name"
grep -q '17.1.0' "${summary}" || fail "summary missing candidate gcc"
grep -q '2.42.0' "${summary}" || fail "summary missing candidate mold"
grep -q 'sync-upstream.sh --apply' "${summary}" || fail "summary missing the repair command"
[[ "$(digest "${sandbox}/targets/x86_64-unknown-linux-gnu/versions")" == "${versions_before}" ]] || fail "conflict rewrote versions"
[[ "$(digest "${sandbox}/targets/x86_64-unknown-linux-gnu/config")" == "${config_before}" ]] || fail "conflict rewrote config"
[[ "$(digest "${origin_targets}/x86_64-unknown-linux-gnu/versions")" == "$(digest "${sandbox}/targets/x86_64-unknown-linux-gnu/versions")" ]] || fail "real versions file changed"
[[ "$(digest "${origin_targets}/x86_64-unknown-linux-gnu/config")" == "$(digest "${sandbox}/targets/x86_64-unknown-linux-gnu/config")" ]] || fail "real config file changed"

echo "upstream sync: PASS"

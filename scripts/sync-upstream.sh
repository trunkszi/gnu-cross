#!/usr/bin/env bash
# Compare the accepted crosstool-NG pin with the latest stable release.
set -euo pipefail

usage() {
    echo "Usage: $0 --check|--apply [--summary-file PATH]" >&2
    exit 64
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
TARGET_DIR="${PROJECT_ROOT}/targets/x86_64-unknown-linux-gnu"
VERSIONS_FILE="${TARGET_DIR}/versions"
CONFIG_FILE="${TARGET_DIR}/config"
API_ROOT=${UPSTREAM_API_ROOT:-https://api.github.com}
REPO_PATH=${UPSTREAM_REPOSITORY:-crosstool-ng/crosstool-ng}

mode=""
summary_file=${UPSTREAM_SUMMARY_FILE:-}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check|--apply)
            [[ -z "${mode}" ]] || usage
            mode=${1#--}
            ;;
        --summary-file)
            [[ $# -ge 2 ]] || usage
            summary_file=$2
            shift
            ;;
        *)
            usage
            ;;
    esac
    shift
done
[[ -n "${mode}" ]] || usage

die_discovery() {
    echo "DISCOVERY_FAILED: $*" >&2
    emit_annotation DISCOVERY_FAILED "$*"
    exit 1
}

emit_annotation() {
    local title=$1 body=$2
    body=${body//%/%25}
    body=${body//$'\r'/%0D}
    body=${body//$'\n'/%0A}
    echo "::error title=${title}::${body}"
}

json_get() {
    local path=$1 expr=$2 value
    if ! value=$(python3 - "${path}" "${expr}" <<'PYJSON'
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        current = json.load(handle)
    if not isinstance(current, dict):
        raise ValueError("response must be an object")
    for part in sys.argv[2].split("."):
        current = current[part]
    if sys.argv[2] in ("draft", "prerelease"):
        if type(current) is not bool:
            raise ValueError("release flags must be booleans")
        print("true" if current else "false")
    else:
        if not isinstance(current, str) or not current.strip():
            raise ValueError("required field must be a nonempty string")
        print(current)
except (OSError, ValueError, KeyError, TypeError, RecursionError) as exc:
    print(f"invalid upstream response: {exc}", file=sys.stderr)
    sys.exit(1)
PYJSON
    ); then
        die_discovery "invalid JSON or required field ${expr} in ${path}"
    fi
    printf '%s\n' "${value}"
}

fetch_json() {
    local url=$1 dest=$2
    if ! curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
        --max-time 60 -H "Accept: application/vnd.github+json" \
        -H "User-Agent: gnu-cross-sync" "${url}" -o "${dest}"; then
        die_discovery "request failed for ${url}"
    fi
}

load_release_json() {
    local dest=$1
    if [[ -n "${UPSTREAM_RELEASE_JSON_FILE:-}" ]]; then
        [[ -f "${UPSTREAM_RELEASE_JSON_FILE}" ]] || die_discovery "release JSON file is missing"
        cp "${UPSTREAM_RELEASE_JSON_FILE}" "${dest}"
        return
    fi
    fetch_json "${API_ROOT}/repos/${REPO_PATH}/releases/latest" "${dest}"
}

load_named_json() {
    local env_name=$1 url=$2 dest=$3
    local configured=${!env_name:-}
    if [[ -n "${UPSTREAM_RELEASE_JSON_FILE:-}" ]]; then
        [[ -n "${configured}" && -f "${configured}" ]] || die_discovery "${env_name} is required for offline tag resolution"
        cp "${configured}" "${dest}"
        return
    fi
    if [[ -n "${configured}" ]]; then
        [[ -f "${configured}" ]] || die_discovery "${env_name} does not exist"
        cp "${configured}" "${dest}"
        return
    fi
    fetch_json "${url}" "${dest}"
}

relevantize() {
    local version=$1
    shift
    local pattern prefix suffix remainder
    for pattern in "$@"; do
        prefix=${pattern%|*}
        suffix=${pattern#*|}
        # shellcheck disable=SC2295
        eval "remainder=\${version#${prefix}${suffix}}"
        if [[ "${version%${suffix}${remainder}}" != "${version}" ]]; then
            version=${version%${suffix}${remainder}}
            break
        fi
    done
    printf '%s\n' "${version}"
}

read_relevant_pattern() {
    local desc=$1 line
    relevant_pattern=""
    [[ -f "${desc}" ]] || return 0
    line=$(grep -E '^relevantpattern=' "${desc}" | head -n 1 || true)
    line=${line#relevantpattern=}
    line=${line#\'}
    line=${line%\'}
    line=${line#\"}
    line=${line%\"}
    relevant_pattern=${line}
}

selector_symbol() {
    local component=$1 version=$2 pattern=$3 relevant symbol
    if [[ -n "${pattern}" ]]; then
        # shellcheck disable=SC2086
        relevant=$(relevantize "${version}" ${pattern})
    else
        relevant=${version}
    fi
    symbol=$(printf '%s' "${relevant}" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/_/g')
    printf 'CT_%s_V_%s\n' "${component}" "${symbol}"
}

latest_stable_version() {
    local package_dir=$1 entry base versions=()
    [[ -d "${package_dir}" ]] || die_discovery "package directory missing: ${package_dir}"
    for entry in "${package_dir}"/*; do
        [[ -d "${entry}" ]] || continue
        base=$(basename "${entry}")
        [[ -f "${entry}/version.desc" ]] || continue
        [[ "${base}" =~ ^[0-9]+(\.[0-9]+)+$ ]] || continue
        if grep -Eq '^(experimental|obsolete)=yes$' "${entry}/version.desc"; then
            continue
        fi
        versions+=("${base}")
    done
    [[ ${#versions[@]} -gt 0 ]] || die_discovery "no stable version in ${package_dir}"
    printf '%s\n' "${versions[@]}" | sort -V | tail -n 1
}

cloned_builder=""
cleanup() {
    if [[ -n "${work:-}" ]]; then
        rm -rf -- "${work}"
    fi
    if [[ -n "${cloned_builder}" ]]; then
        rm -rf -- "${cloned_builder}"
    fi
    return 0
}

prepare_builder() {
    local commit=$1
    if [[ -n "${UPSTREAM_BUILDER_DIR:-}" ]]; then
        [[ -d "${UPSTREAM_BUILDER_DIR}" ]] || die_discovery "UPSTREAM_BUILDER_DIR is not a directory"
        builder_dir=${UPSTREAM_BUILDER_DIR}
        return
    fi
    cloned_builder=$(mktemp -d "${TMPDIR:-/tmp}/gnu-cross-upstream.XXXXXX")
    builder_dir=${cloned_builder}
    if ! git clone --quiet https://github.com/crosstool-ng/crosstool-ng "${builder_dir}" >&2; then
        die_discovery "unable to clone crosstool-ng"
    fi
    if ! git -C "${builder_dir}" checkout --quiet --detach "${commit}" >&2; then
        die_discovery "unable to checkout ${commit}"
    fi
}

write_summary() {
    local text=$1
    local destination=${summary_file:-${GITHUB_STEP_SUMMARY:-}}
    [[ -n "${destination}" ]] || return 0
    printf '%s\n' "${text}" >> "${destination}"
}

emit_status() {
    local line
    for line in "$@"; do
        printf '%s\n' "${line}"
        if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
            printf '%s\n' "${line}" >> "${GITHUB_OUTPUT}"
        fi
    done
}

resolve_commit() {
    local release_json=$1 tag ref_json object_type object_sha tag_json peeled_type
    tag=$(json_get "${release_json}" tag_name)
    [[ "${tag}" =~ ^[A-Za-z0-9._+-]+$ ]] || die_discovery "release JSON has an unsafe tag_name"
    draft=$(json_get "${release_json}" draft)
    prerelease=$(json_get "${release_json}" prerelease)
    if [[ "${draft}" == "true" || "${prerelease}" == "true" ]]; then
        die_discovery "latest release ${tag} is draft or prerelease"
    fi
    ref_json="${work}/ref.json"
    load_named_json UPSTREAM_REF_JSON_FILE \
        "${API_ROOT}/repos/${REPO_PATH}/git/ref/tags/${tag}" "${ref_json}"
    object_type=$(json_get "${ref_json}" object.type)
    object_sha=$(json_get "${ref_json}" object.sha)
    [[ "${object_sha}" =~ ^[0-9a-f]{40}$ ]] || die_discovery "tag ${tag} did not resolve to a SHA"
    local depth=0
    while [[ "${object_type}" == "tag" ]]; do
        depth=$((depth + 1))
        [[ ${depth} -le 5 ]] || die_discovery "annotated tag ${tag} peeled too deeply"
        tag_json="${work}/tag-${depth}.json"
        if [[ ${depth} -eq 1 ]]; then
            load_named_json UPSTREAM_TAG_JSON_FILE \
                "${API_ROOT}/repos/${REPO_PATH}/git/tags/${object_sha}" "${tag_json}"
        else
            fetch_json "${API_ROOT}/repos/${REPO_PATH}/git/tags/${object_sha}" "${tag_json}"
        fi
        peeled_type=$(json_get "${tag_json}" object.type)
        object_sha=$(json_get "${tag_json}" object.sha)
        object_type=${peeled_type}
        [[ "${object_sha}" =~ ^[0-9a-f]{40}$ ]] || die_discovery "annotated tag ${tag} has no commit"
    done
    [[ "${object_type}" == "commit" ]] || die_discovery "tag ${tag} resolved to ${object_type}"
    new_tag=${tag}
    new_commit=${object_sha}
}

report_patch_conflict() {
    local patch_file=$1 detail_file=$2 old_tag=$3 old_commit=$4 new_tag=$5 new_commit=$6 \
        old_gcc=$7 new_gcc=$8 old_mold=$9 new_mold=${10}
    local patch_name detail
    patch_name=$(basename "${patch_file}")
    detail=$(sed 's/[[:cntrl:]]/ /g' "${detail_file}" | tail -n 40)
    emit_annotation UPSTREAM_PATCH_CONFLICT \
        "patch ${patch_name} failed; old ${old_tag} ${old_commit}; new ${new_tag} ${new_commit}; Published v0.0.1 Release: UNTOUCHED"
    write_summary "$(cat <<EOF
## UPSTREAM_PATCH_CONFLICT

Published v0.0.1 Release: UNTOUCHED

| Field | Accepted | Candidate |
|---|---|---|
| crosstool-NG tag | ${old_tag} | ${new_tag} |
| crosstool-NG commit | ${old_commit} | ${new_commit} |
| GCC | ${old_gcc} | ${new_gcc} |
| mold | ${old_mold} | ${new_mold} |

glibc profiles stay 2.17, 2.26, 2.32, and 2.34. Linux headers stay 5.4.302.

Conflict patch: \`${patch_name}\`

\`\`\`
${detail}
\`\`\`

Repair the patch locally, then rerun:

\`\`\`sh
patch --fuzz=0 --batch --dry-run -Np1 -d /path/to/builder -i targets/x86_64-unknown-linux-gnu/${patch_name}
./scripts/sync-upstream.sh --check
./scripts/sync-upstream.sh --apply
\`\`\`
EOF
)"
}

preflight_patches() {
    local builder_dir=$1 old_tag=$2 old_commit=$3 new_tag=$4 new_commit=$5 \
        old_gcc=$6 new_gcc=$7 old_mold=$8 new_mold=$9
    local patch_file log_file
    shopt -s nullglob
    for patch_file in "${TARGET_DIR}"/*.patch; do
        log_file=$(mktemp)
        if ! patch --fuzz=0 --batch --dry-run -Np1 -d "${builder_dir}" -i "${patch_file}" >"${log_file}" 2>&1; then
            report_patch_conflict "${patch_file}" "${log_file}" \
                "${old_tag}" "${old_commit}" "${new_tag}" "${new_commit}" \
                "${old_gcc}" "${new_gcc}" "${old_mold}" "${new_mold}"
            rm -f "${log_file}"
            exit 1
        fi
        rm -f "${log_file}"
    done
    shopt -u nullglob
}

update_locked_files() {
    local new_tag=$1 new_commit=$2 new_gcc=$3 new_mold=$4 gcc_symbol=$5 mold_symbol=$6
    local tmp_versions tmp_config
    tmp_versions=$(mktemp)
    cat > "${tmp_versions}" <<EOF
CTNG_RELEASE_TAG=${new_tag}
CTNG_COMMIT=${new_commit}
EXPECTED_GCC_VERSION=${new_gcc}
EXPECTED_MOLD_VERSION=${new_mold}
EXPECTED_BINUTILS_VERSION=${EXPECTED_BINUTILS_VERSION}
EXPECTED_LINUX_VERSION=${EXPECTED_LINUX_VERSION}
EXPECTED_RELEASE_TAG=${EXPECTED_RELEASE_TAG}
EOF
    mv "${tmp_versions}" "${VERSIONS_FILE}"
    tmp_config=$(mktemp)
    grep -Ev '^(# )?CT_GCC_V_|(# )?CT_MOLD_V_' "${CONFIG_FILE}" > "${tmp_config}" || true
    printf '%s=y\n' "${gcc_symbol}" >> "${tmp_config}"
    printf '%s=y\n' "${mold_symbol}" >> "${tmp_config}"
    mv "${tmp_config}" "${CONFIG_FILE}"
}

[[ -f "${VERSIONS_FILE}" && -f "${CONFIG_FILE}" ]] || die_discovery "target versions or config is missing"
# shellcheck disable=SC1090
source "${VERSIONS_FILE}"
: "${CTNG_RELEASE_TAG:?}"
: "${CTNG_COMMIT:?}"
: "${EXPECTED_GCC_VERSION:?}"
: "${EXPECTED_MOLD_VERSION:?}"
: "${EXPECTED_BINUTILS_VERSION:?}"
: "${EXPECTED_LINUX_VERSION:?}"
: "${EXPECTED_RELEASE_TAG:?}"

work=$(mktemp -d "${TMPDIR:-/tmp}/gnu-cross-sync.XXXXXX")
trap cleanup EXIT
release_json="${work}/release.json"
load_release_json "${release_json}"
resolve_commit "${release_json}"

if [[ "${new_commit}" == "${CTNG_COMMIT}" ]]; then
    emit_status "status=no_update" "should_build=false" "upstream_updated=false" \
        "tag=${new_tag}" "commit=${new_commit}"
    exit 0
fi

prepare_builder "${new_commit}"
latest_gcc=$(latest_stable_version "${builder_dir}/packages/gcc")
latest_mold=$(latest_stable_version "${builder_dir}/packages/mold")
[[ "${new_tag}" =~ ^[A-Za-z0-9._+-]+$ ]] || die_discovery "refusing unsafe release tag"
[[ "${latest_gcc}" =~ ^[0-9]+(\.[0-9]+)+$ ]] || die_discovery "refusing unsafe GCC version"
[[ "${latest_mold}" =~ ^[0-9]+(\.[0-9]+)+$ ]] || die_discovery "refusing unsafe mold version"
read_relevant_pattern "${builder_dir}/packages/gcc/package.desc"
gcc_pattern=${relevant_pattern}
read_relevant_pattern "${builder_dir}/packages/mold/package.desc"
mold_pattern=${relevant_pattern}
gcc_symbol=$(selector_symbol GCC "${latest_gcc}" "${gcc_pattern}")
mold_symbol=$(selector_symbol MOLD "${latest_mold}" "${mold_pattern}")

preflight_patches "${builder_dir}" "${CTNG_RELEASE_TAG}" "${CTNG_COMMIT}" \
    "${new_tag}" "${new_commit}" "${EXPECTED_GCC_VERSION}" "${latest_gcc}" \
    "${EXPECTED_MOLD_VERSION}" "${latest_mold}"

if [[ "${mode}" == "apply" ]]; then
    update_locked_files "${new_tag}" "${new_commit}" "${latest_gcc}" "${latest_mold}" \
        "${gcc_symbol}" "${mold_symbol}"
    emit_status "status=updated" "should_build=true" "upstream_updated=true"
else
    emit_status "status=update_available" "should_build=true" "upstream_updated=false"
fi
emit_status \
    "old_tag=${CTNG_RELEASE_TAG}" "new_tag=${new_tag}" \
    "old_commit=${CTNG_COMMIT}" "new_commit=${new_commit}" \
    "old_gcc=${EXPECTED_GCC_VERSION}" "latest_gcc=${latest_gcc}" \
    "old_mold=${EXPECTED_MOLD_VERSION}" "latest_mold=${latest_mold}" \
    "gcc_selector=${gcc_symbol}" "mold_selector=${mold_symbol}"

#!/usr/bin/env bash
# Validate the candidate before replacing assets; promote only uploaded, verified bytes.
set -euo pipefail
[[ ${TAG:-} =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'Invalid release tag' >&2; exit 1; }
[[ ${ARTIFACT_SHA:-} =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid artifact source SHA' >&2; exit 1; }
python3 scripts/release-artifacts.py verify release
candidate_sha=$(python3 -c 'import json; print(json.load(open(".candidate-source/source.json"))["source_sha"])')
[[ ${candidate_sha} =~ ^[0-9a-f]{40}$ ]]
[[ $(git rev-parse HEAD) == "${candidate_sha}" ]] || { echo 'Candidate was not restored' >&2; exit 1; }
git cat-file -e "${candidate_sha}^{commit}"
upstream_updated=$(python3 -c 'import json; print(str(json.load(open(".candidate-source/source.json"))["upstream_updated"]).lower())')
if [[ ${upstream_updated} == true && -z ${SOURCE_RUN_ID:-} ]]; then
    remote_main=$(git ls-remote origin refs/heads/main | awk '{print $1}')
    [[ ${remote_main} == "${ARTIFACT_SHA}" || ${remote_main} == "${candidate_sha}" ]] || {
        echo 'Main advanced since candidate preparation' >&2; exit 1;
    }
fi
assets=()
for host in amazonlinux2 alinux3 centos7 ubuntu22; do
    archive="release/x86_64-unknown-linux-gnu-${host}.tar.xz"
    assets+=("${archive}" "${archive}.sha256" "${archive}.manifest.json")
done
journal() {
    if [[ -n ${GITHUB_OUTPUT:-} ]]; then printf 'assets_touched=%s\n' "$1" >> "${GITHUB_OUTPUT}"; fi
}
journal false
# This marker precedes the first operation that may replace online assets.
journal true
if gh release view "${TAG}" >/dev/null 2>&1; then
    gh release upload "${TAG}" "${assets[@]}" --clobber
    gh release edit "${TAG}" --notes-file RELEASE.md
else
    gh release create "${TAG}" --target "${ARTIFACT_SHA}" --title "Release ${TAG}" --notes-file RELEASE.md "${assets[@]}"
fi
remote=$(mktemp -d)
trap 'rm -rf -- "${remote}"' EXIT
gh release download "${TAG}" --pattern '*.tar.xz' --pattern '*.sha256' --pattern '*.manifest.json' --dir "${remote}"
for asset in "${assets[@]}"; do cmp -- "${asset}" "${remote}/$(basename "${asset}")"; done
# Git push transfers the object as well as updating refs; REST ref PATCH cannot do this.
if [[ ${upstream_updated} == true && -z ${SOURCE_RUN_ID:-} ]]; then
    git push "--force-with-lease=refs/heads/main:${remote_main}" origin "${candidate_sha}:refs/heads/main"
fi
git push --force origin "${candidate_sha}:refs/tags/${TAG}"

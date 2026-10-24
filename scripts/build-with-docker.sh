#!/usr/bin/env bash
# Build one host variant inside a container and rename the verified archive.
set -euo pipefail

TARGET=${1:-}
CONTAINER_IMAGE=${2:-}
OS_LABEL=${3:-}

[[ $# -eq 3 && "${TARGET}" == x86_64-unknown-linux-gnu ]] || {
    echo "Usage: $0 x86_64-unknown-linux-gnu <approved-image> <host-label>" >&2
    exit 64
}
case "${OS_LABEL}:${CONTAINER_IMAGE}" in
    amazonlinux2:public.ecr.aws/amazonlinux/amazonlinux:2|alinux3:alibaba-cloud-linux-3-registry.cn-hangzhou.cr.aliyuncs.com/alinux3/alinux3:latest|centos7:centos:7.9.2009|ubuntu22:ubuntu:22.04) ;;
    *) echo "Unsupported host/image pair: ${OS_LABEL}:${CONTAINER_IMAGE}" >&2; exit 64;;
esac
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
CONTAINER_NAME="gnu-cross-build-${OS_LABEL}-${BASHPID}-${RANDOM}${RANDOM}"
cleanup() {
    local status=$?
    trap - EXIT
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    exit "${status}"
}
trap cleanup EXIT

echo "Target architecture: ${TARGET}"
echo "Container image: ${CONTAINER_IMAGE}"
echo "OS label: ${OS_LABEL}"

docker run -d \
    --security-opt seccomp=unconfined \
    --name "${CONTAINER_NAME}" \
    -v "${PROJECT_ROOT}:/workspace/gnu-cross" \
    -w /workspace/gnu-cross \
    "${CONTAINER_IMAGE}" \
    tail -f /dev/null

if [[ "${OS_LABEL}" == "alinux3" || "${CONTAINER_IMAGE}" == *"alinux3"* ]]; then
    echo "Configuring Alibaba Cloud Linux 3 mirror..."
    docker exec "${CONTAINER_NAME}" bash -c 'set -euo pipefail
        pkill -9 dnf || true
        pkill -9 yum || true
        pkill -9 packagekitd || true
        rm -f /var/run/yum.pid /var/run/dnf.pid
        rm -f /var/cache/dnf/*pid /var/cache/yum/*pid

        mkdir -p /etc/yum.repos.d/backup
        cp /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ 2>/dev/null || true
        rm -f /etc/yum.repos.d/*.repo

        cat > /etc/yum.repos.d/alinux3.repo <<EOF
[alinux3-os]
name=Alibaba Cloud Linux 3 - Os
baseurl=https://mirrors.aliyun.com/alinux/\$releasever/os/\$basearch/
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/alinux/3/RPM-GPG-KEY-ALINUX-3

[alinux3-updates]
name=Alibaba Cloud Linux 3 - Updates
baseurl=https://mirrors.aliyun.com/alinux/\$releasever/updates/\$basearch/
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/alinux/3/RPM-GPG-KEY-ALINUX-3

[alinux3-module]
name=Alibaba Cloud Linux 3 - Module
baseurl=https://mirrors.aliyun.com/alinux/3/module/\$basearch/
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/alinux/3/RPM-GPG-KEY-ALINUX-3

[alinux3-plus]
name=Alibaba Cloud Linux 3 - Plus
baseurl=https://mirrors.aliyun.com/alinux/\$releasever/plus/\$basearch/
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/alinux/3/RPM-GPG-KEY-ALINUX-3

[alinux3-powertools]
name=Alibaba Cloud Linux 3 - PowerTools
baseurl=https://mirrors.aliyun.com/alinux/\$releasever/powertools/\$basearch/
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/alinux/3/RPM-GPG-KEY-ALINUX-3
EOF

        (dnf clean all || yum clean all)
        echo "Mirror configuration completed"
    '
elif [[ "${CONTAINER_IMAGE}" == *"centos"* || "${OS_LABEL}" == "centos7" ]]; then
    echo "Configuring CentOS 7 mirror..."
    docker exec "${CONTAINER_NAME}" bash -c 'set -euo pipefail
        sed -i -e "s|mirrorlist=|#mirrorlist=|g" \
               -e "s|#baseurl=http://mirror.centos.org|baseurl=https://mirrors.aliyun.com|g" \
               /etc/yum.repos.d/CentOS-*.repo
        yum clean all
        yum makecache
        echo "Mirror configuration completed"
    '
fi

echo "Starting build..."
docker exec -e BUILD_TARGET="${TARGET}" "${CONTAINER_NAME}" bash -c 'set -euo pipefail
    cd /workspace/gnu-cross
    ./scripts/make "${BUILD_TARGET}"
'

echo "Adding OS label to output files..."
docker exec \
    -e BUILD_TARGET="${TARGET}" \
    -e BUILD_OS_LABEL="${OS_LABEL}" \
    "${CONTAINER_NAME}" bash -c 'set -euo pipefail
    cd /workspace/gnu-cross
    source_archive="${BUILD_TARGET}.tar.xz"
    source_checksum="${source_archive}.sha256"
    artifact="${BUILD_TARGET}-${BUILD_OS_LABEL}.tar.xz"
    checksum="${artifact}.sha256"
    if [[ ! -f "${source_archive}" || ! -f "${source_checksum}" ]]; then
        echo "Error: build artifact or checksum does not exist" >&2
        exit 1
    fi
    mv "${source_archive}" "${artifact}"
    mv "${source_checksum}" "${checksum}"
    read -r actual_hash _ < <(sha256sum "${artifact}")
    read -r expected_hash _ < "${checksum}"
    if [[ -z "${actual_hash}" || -z "${expected_hash}" || "${actual_hash}" != "${expected_hash}" ]]; then
        echo "Error: renamed artifact checksum mismatch" >&2
        exit 1
    fi
    if [[ ! "${expected_hash}" =~ ^[0-9a-f]{64}$ ]]; then
        echo "Error: checksum is not 64 hexadecimal characters" >&2
        exit 1
    fi
    echo "Checksum verification passed"
'

echo "Build completed"
echo "  - ${TARGET}-${OS_LABEL}.tar.xz"
echo "  - ${TARGET}-${OS_LABEL}.tar.xz.sha256"

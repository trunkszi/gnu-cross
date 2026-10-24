#!/usr/bin/env bash
# Copy an available upstream function file, or generate a standalone mirror fixture.
write_builder_functions() {
    local destination=$1 source=${MUSL_BUILDER_DIR:-/root/worktrees-rs/musl-cross/builder}/scripts/functions
    mkdir -p "$(dirname "${destination}")"
    if [[ -f "${source}" ]]; then cp "${source}" "${destination}"; return; fi
    cat > "${destination}" <<'FUNCTIONS'
#!/usr/bin/env bash
CT_Mirrors() {
    local package=$1 version=$2
    case "${package}" in
        linux)
            case "${version}" in
            2.4.*)
                echo "https://cdn.kernel.org/pub/linux/kernel/v2.4"
                ;;
            [34567].*)
                echo "https://cdn.kernel.org/pub/linux/kernel/v${version%%.*}.x"
                ;;
            2.6.*)
                echo "https://cdn.kernel.org/pub/linux/kernel/v2.6"
                ;;
            esac
            ;;
    esac
}
FUNCTIONS
}

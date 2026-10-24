# Executed by an independent strict Bash with the declared package hooks and state.
[[ ${#MIRROR_SETUP_COMMANDS[@]} -eq 0 && ${#EXTRA_SETUP_COMMANDS[@]} -eq 0 ]] || {
    echo 'Error: package configuration must not carry shell command strings' >&2
    exit 1
}
if declare -F pkg_prepare >/dev/null; then pkg_prepare; fi
run_package_update
run_package_install
if declare -F pkg_extra >/dev/null; then pkg_extra; fi
# Return prepare-time package selection and successful PATH changes to the caller.
for name in PACKAGES PKG_MANAGER USE_PIP_CMAKE USE_GCC10 USE_DEVTOOLSET PATH; do
    if declare -p "${name}" >/dev/null 2>&1; then
        declare -p "${name}" | sed 's/^declare /declare -g /' >> "$1"
    fi
done

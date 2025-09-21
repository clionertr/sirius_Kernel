#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${REPO_ROOT}/out"
LOG_DIR="${REPO_ROOT}/logs"
mkdir -p "${LOG_DIR}"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/build_${TIMESTAMP}.log"

exec > >(tee -a "${LOG_FILE}" | awk 'BEGIN { IGNORECASE = 1 } /error/ { print; fflush(stdout); }')
exec 2> >(tee -a "${LOG_FILE}" | awk 'BEGIN { IGNORECASE = 1 } /error/ { print > "/dev/stderr"; fflush("/dev/stderr"); }')

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

on_exit() {
    local exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
        printf 'ERROR: Build failed with exit code %s\n' "${exit_code}" >&2
        if [[ -f "${LOG_FILE}" ]]; then
            grep -n -i --color=never 'error' "${LOG_FILE}" >&2 || true
            printf 'ERROR: Full log available at %s\n' "${LOG_FILE}" >&2
        fi
    else
        log "Build finished successfully."
    fi
}

trap on_exit EXIT

# -----------------------------------------------------------------------------
# Options
# -----------------------------------------------------------------------------
CLEAN_OUT=false
MENUCONFIG=false
EXTRA_MAKE_TARGETS=()

while (($#)); do
    case "$1" in
        --clean)
            CLEAN_OUT=true
            ;;
        --menuconfig)
            MENUCONFIG=true
            ;;
        *)
            EXTRA_MAKE_TARGETS+=("$1")
            ;;
    esac
    shift
done

# -----------------------------------------------------------------------------
# Toolchain setup
# -----------------------------------------------------------------------------
CLANG="${REPO_ROOT}/android_prebuilts_clang_kernel_linux-x86_clang-r416183b/bin"
GCC64="${REPO_ROOT}/aarch64-linux-android-4.9/bin"
GCC32="${REPO_ROOT}/arm-linux-androideabi-4.9/bin"

for toolchain_dir in "${CLANG}" "${GCC64}" "${GCC32}"; do
    if [[ ! -d "${toolchain_dir}" ]]; then
        log "ERROR: Missing toolchain directory ${toolchain_dir}"
        exit 1
    fi
    PATH="${toolchain_dir}:${PATH}"
done
export PATH

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------
ensure_kernelsu() {
    local kernelsu_dir="${SCRIPT_DIR}/KernelSU"
    local expected_config="${kernelsu_dir}/kernel/Kconfig"
    local remote="${KERNELSU_REMOTE:-https://github.com/SukiSU-Ultra/SukiSU-Ultra.git}"
    local ref="${KERNELSU_REF:-nongki}"

    if ! command -v git >/dev/null 2>&1; then
        log "ERROR: git is required to fetch KernelSU."
        exit 1
    fi

    if [[ -f "${expected_config}" && -d "${kernelsu_dir}/.git" ]]; then
        if [[ -n "$(git -C "${kernelsu_dir}" status --porcelain 2>/dev/null)" ]]; then
            log "KernelSU repository has local changes; skipping auto-update."
            return
        fi
        local current_remote
        current_remote="$(git -C "${kernelsu_dir}" config --get remote.origin.url 2>/dev/null || true)"
        if [[ "${current_remote}" == "${remote}" ]]; then
            log "Updating KernelSU checkout (${ref})."
            git -C "${kernelsu_dir}" fetch --depth=1 origin "${ref}"
            if ! git -C "${kernelsu_dir}" show-ref --verify --quiet "refs/heads/${ref}"; then
                git -C "${kernelsu_dir}" checkout -B "${ref}" "origin/${ref}" >/dev/null 2>&1 || true
            fi
            git -C "${kernelsu_dir}" checkout "${ref}" >/dev/null 2>&1
            git -C "${kernelsu_dir}" reset --hard "origin/${ref}" >/dev/null 2>&1
            return
        fi
        log "KernelSU remote differs; refreshing contents."
    elif [[ -d "${kernelsu_dir}" && -n "$(ls -A "${kernelsu_dir}" 2>/dev/null)" ]]; then
        log "WARNING: KernelSU directory exists but missing git metadata; refreshing contents."
    fi

    log "Cloning KernelSU ${ref} from ${remote}"
    rm -rf "${kernelsu_dir}"
    git clone --depth=1 --branch "${ref}" "${remote}" "${kernelsu_dir}"

    if [[ ! -f "${expected_config}" ]]; then
        log "ERROR: Unable to locate KernelSU kernel/Kconfig after fetch."
        exit 1
    fi
}

apply_susfs_config() {
    if [[ ! -s "${OUT_DIR}/.config" ]]; then
        log "ERROR: .config not found in ${OUT_DIR}; defconfig must run first."
        exit 1
    fi

    if [[ ! -x "${SCRIPT_DIR}/scripts/kconfig/merge_config.sh" ]]; then
        chmod +x "${SCRIPT_DIR}/scripts/kconfig/merge_config.sh"
    fi

    local fragment
    fragment="$(mktemp)"
    cat <<'EOF' > "${fragment}"
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_OVERLAYFS=y
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
EOF

    log "Merging SUSFS configuration fragment"
    ARCH=arm64 SUBARCH=arm64 \
    KCONFIG_CONFIG="${OUT_DIR}/.config" \
    "${SCRIPT_DIR}/scripts/kconfig/merge_config.sh" -m -O "${OUT_DIR}" "${OUT_DIR}/.config" "${fragment}"

    make "${MAKE_ARGS[@]}" olddefconfig
    rm -f "${fragment}"
}

# -----------------------------------------------------------------------------
# Build preparation
# -----------------------------------------------------------------------------
log "Starting kernel build"
log "Logs stored at ${LOG_FILE}"

if ${CLEAN_OUT}; then
    log "Cleaning output directory ${OUT_DIR}"
    rm -rf "${OUT_DIR}"
fi

ensure_kernelsu

if [[ ! -L "${SCRIPT_DIR}/drivers/kernelsu" ]]; then
    log "Creating KernelSU drivers symlink"
    ln -s ../KernelSU/kernel "${SCRIPT_DIR}/drivers/kernelsu"
elif [[ ! -e "${SCRIPT_DIR}/drivers/kernelsu" ]]; then
    log "Refreshing broken KernelSU drivers symlink"
    rm "${SCRIPT_DIR}/drivers/kernelsu"
    ln -s ../KernelSU/kernel "${SCRIPT_DIR}/drivers/kernelsu"
fi

NPROC=${NPROC:-$(nproc --all)}
MAKE_ARGS=("-j${NPROC}" ARCH=arm64 SUBARCH=arm64 O="${OUT_DIR}" CC=clang CROSS_COMPILE=aarch64-linux-android- CROSS_COMPILE_ARM32=arm-linux-androideabi- CLANG_TRIPLE=aarch64-linux-gnu- LLVM=1)

pushd "${SCRIPT_DIR}" >/dev/null

log "Running defconfig"
make "${MAKE_ARGS[@]}" sirius_zhong_defconfig

apply_susfs_config

if ${MENUCONFIG}; then
    log "Launching menuconfig"
    make "${MAKE_ARGS[@]}" menuconfig
fi

log "Building kernel"
if ((${#EXTRA_MAKE_TARGETS[@]})); then
    make "${MAKE_ARGS[@]}" "${EXTRA_MAKE_TARGETS[@]}"
else
    make "${MAKE_ARGS[@]}"
fi

popd >/dev/null

log "Kernel build complete"

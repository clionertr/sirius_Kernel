#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${REPO_ROOT}/logs"
mkdir -p "${LOG_DIR}"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/build_${TIMESTAMP}.log"

exec > >(tee -a "${LOG_FILE}") 2>&1

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

on_exit() {
    local exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
        log "Build failed with exit code ${exit_code}."
    else
        log "Build finished successfully."
    fi
}

trap on_exit EXIT

log "Starting kernel build"
log "Logs stored at ${LOG_FILE}"

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

ARGS=("-j$(nproc --all)" ARCH=arm64 SUBARCH=arm64 O="${REPO_ROOT}/out" CC=clang CROSS_COMPILE=aarch64-linux-android- CROSS_COMPILE_ARM32=arm-linux-androideabi- CLANG_TRIPLE=aarch64-linux-gnu- LLVM=1)

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
        local current_remote
        current_remote="$(git -C "${kernelsu_dir}" config --get remote.origin.url 2>/dev/null || true)"
        if [[ "${current_remote}" == "${remote}" ]]; then
            log "Updating KernelSU checkout to ${ref}."
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

    log "Fetching KernelSU ${ref} from ${remote}"
    rm -rf "${kernelsu_dir}"
    git clone --depth=1 --branch "${ref}" "${remote}" "${kernelsu_dir}"

    if [[ ! -f "${expected_config}" ]]; then
        log "ERROR: Unable to locate KernelSU kernel/Kconfig after fetch."
        exit 1
    fi
}

ensure_kernelsu

if [[ ! -L "${SCRIPT_DIR}/drivers/kernelsu" ]]; then
    log "Creating KernelSU drivers symlink"
    ln -s ../KernelSU/kernel "${SCRIPT_DIR}/drivers/kernelsu"
elif [[ ! -e "${SCRIPT_DIR}/drivers/kernelsu" ]]; then
    log "Refreshing broken KernelSU drivers symlink"
    rm "${SCRIPT_DIR}/drivers/kernelsu"
    ln -s ../KernelSU/kernel "${SCRIPT_DIR}/drivers/kernelsu"
fi

pushd "${SCRIPT_DIR}" >/dev/null

log "Running defconfig"
make "${ARGS[@]}" sirius_zhong_defconfig

log "Building kernel"
make "${ARGS[@]}"

popd >/dev/null
log "Kernel build complete"

#!/bin/bash
# =============================================================================
# ImmortalWrt IPK编译函数库 —— GitHub Action Ubuntu‑22.04专用
# 模式：逐个包 make package/xxx/install；单包失败继续编译剩余包
# 【无交互函数库，不会自动执行；source后调用 run_build】
# =============================================================================
set -uo pipefail

# -------------------------- 可配置参数（Workflow注入环境变量） --------------------------
: "${IMMORTALWRT_VERSION:=24.10.4}"
: "${GCC_VERSION:=13.3.0}"
: "${LIBC:=musl}"
: "${CUSTOM_FEED_REPO:=https://github.com/TW20022/openwrt-24-printing-packages.git}"
: "${CUSTOM_FEED_NAME:=printing}"
# TARGET_PACKAGES_STR 空字符串=编译feed全部包；空格分隔指定包例 "cups hplip"
: "${TARGET_PACKAGES_STR:=}"
# 目标组合 arch:subtarget
: "${TARGET_COMBO:=x86:64}"
: "${MAX_JOBS:=16}"

# GitHub Workspace目录
WORKDIR="${GITHUB_WORKSPACE}/immortalwrt_build"
SDK_DIR=""
OUTPUT_DIR="${GITHUB_WORKSPACE}/ipk_output"
LOG_DIR="${WORKDIR}/build_logs"

# CI环境关闭ANSI颜色，避免日志乱码
if [[ "${CI:-false}" == "true" ]]; then
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
fi

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fatal() { echo -e "${RED}[FATAL]${NC} $*"; exit 1; }

# 解析 TARGET_COMBO 拆分为 ARCH / SUBTARGET
parse_target_combo() {
    TARGET_ARCH="${TARGET_COMBO%%:*}"
    TARGET_SUBTARGET="${TARGET_COMBO#*:}"
    if [[ "${TARGET_ARCH}" == "${TARGET_SUBTARGET}" ]]; then
        fatal "TARGET_COMBO格式错误，需要 arch:subtarget ，输入值：${TARGET_COMBO}"
    fi
    info "解析目标组合: ARCH=${TARGET_ARCH} SUBTARGET=${TARGET_SUBTARGET}"
}

# 解析空格分隔包字符串转为bash数组
parse_packages() {
    read -ra TARGET_PACKAGES <<< "${TARGET_PACKAGES_STR}"
    info "用户指定编译包数量: ${#TARGET_PACKAGES[@]}"
}

download_sdk() {
    parse_target_combo
    local sdk_tarname="immortalwrt-sdk-${IMMORTALWRT_VERSION}-${TARGET_ARCH}-${TARGET_SUBTARGET}_gcc-${GCC_VERSION}_${LIBC}.Linux-x86_64.tar.zst"
    local sdk_url="https://downloads.immortalwrt.org/releases/${IMMORTALWRT_VERSION}/targets/${TARGET_ARCH}/${TARGET_SUBTARGET}/${sdk_tarname}"
    mkdir -p "$WORKDIR"
    SDK_DIR="${WORKDIR}/sdk-${TARGET_ARCH}-${TARGET_SUBTARGET}"

    if [[ ! -f "${WORKDIR}/${sdk_tarname}" ]]; then
        info "下载SDK: ${sdk_url}"
        wget --no-verbose -P "$WORKDIR" "$sdk_url" || fatal "SDK下载失败 ${sdk_url}"
    else
        info "SDK压缩包已存在(缓存复用): ${sdk_tarname}"
    fi

    local tar_size
    tar_size=$(stat -c%s "${WORKDIR}/${sdk_tarname}")
    if [[ $tar_size -lt 1000000 ]]; then
        fatal "SDK压缩包过小疑似损坏 ${WORKDIR}/${sdk_tarname}"
    fi

    if [[ ! -d "$SDK_DIR" ]]; then
        info "解压SDK"
        local temp_extract_dir="${WORKDIR}/temp_extract_${RANDOM}"
        mkdir -p "$temp_extract_dir"
        if tar --zstd -xf "${WORKDIR}/${sdk_tarname}" -C "$temp_extract_dir" 2>/dev/null; then
            :
        else
            tar -I zstd -xf "${WORKDIR}/${sdk_tarname}" -C "$temp_extract_dir" || fatal "SDK解压失败"
        fi

        shopt -s nullglob
        extracted_files=( "${temp_extract_dir}"/* )
        if [[ ${#extracted_files[@]} -ne 1 ]];then
            fatal "SDK解压异常，顶层条目数量=${#extracted_files[@]}"
        fi
        local extracted_name
        extracted_name=$(basename "${extracted_files[0]}")
        shopt -u nullglob

        mv "${temp_extract_dir}/${extracted_name}" "$SDK_DIR"
        rm -rf "$temp_extract_dir"
    else
        info "复用已解压SDK目录 ${SDK_DIR}"
    fi
    info "SDK_DIR=${SDK_DIR}"
}

add_custom_feed() {
    cd "$SDK_DIR" || fatal "进入SDK目录失败"
    rm -rf "${LOG_DIR}"
    mkdir -p "${LOG_DIR}" "${WORKDIR}/dl"

    rm -rf "${SDK_DIR}/dl"
    ln -s "${WORKDIR}/dl" "${SDK_DIR}/dl"

    # 只匹配非注释的src‑git行，避免注释行误判
    if ! grep -E "^src-git[[:space:]]+${CUSTOM_FEED_NAME}[[:space:]]" feeds.conf.default; then
        info "添加自定义feed ${CUSTOM_FEED_REPO}"
        echo "src-git ${CUSTOM_FEED_NAME} ${CUSTOM_FEED_REPO}" >> "feeds.conf.default"
    fi

    info "feeds update -a"
    ./scripts/feeds update -a || fatal "feeds update失败"

    if [ -d feeds/packages/utils/hplip ]; then
        info "移除官方hplip"
        rm -rf feeds/packages/utils/hplip
    fi

    parse_packages
    # 空包列表，自动获取feed全部包
    if [[ ${#TARGET_PACKAGES[@]} -eq 0 ]]; then
        info "TARGET_PACKAGES_STR为空，获取feed全部包"
        feed_list_out=$(./scripts/feeds list -r "${CUSTOM_FEED_NAME}")
        if [[ -z "${feed_list_out}" ]]; then
            fatal "feeds list返回空，无法获取包列表"
        fi
        mapfile -t TARGET_PACKAGES < <(echo "${feed_list_out}" | awk '{print $1}')
    fi
    if [[ ${#TARGET_PACKAGES[@]} -eq 0 ]]; then
        fatal "获取不到任何待编译包"
    fi
    info "待编译总包数: ${#TARGET_PACKAGES[@]}"

    info "feeds install -p ${CUSTOM_FEED_NAME} -a -f"
    ./scripts/feeds install -p "${CUSTOM_FEED_NAME}" -a -f || fatal "feeds install失败"

    [[ -x ./scripts/config ]] || fatal "SDK缺失 ./scripts/config"

    make defconfig > "${LOG_DIR}/defconfig1.log" 2>&1

    for pkg in "${TARGET_PACKAGES[@]}"; do
        ./scripts/config --set-val "CONFIG_PACKAGE_${pkg}" m
    done

    make defconfig > "${LOG_DIR}/defconfig2.log" 2>&1

    # 预检查config是否生效
    warn_cnt=0
    for pkg in "${TARGET_PACKAGES[@]}"; do
        if ! grep -q "^CONFIG_PACKAGE_${pkg}=m" .config; then
            warn "包 ${pkg} 未设置CONFIG_PACKAGE_${pkg}=m"
            ((warn_cnt++))
        fi
    done
    if (( warn_cnt > 0 )); then
        warn "存在 ${warn_cnt} 个包配置未生效，编译可能失败"
    fi
}

compile_packages() {
    cd "$SDK_DIR" || fatal "进入SDK目录失败"
    rm -rf bin

    info "包列表:"
    for pkg in "${TARGET_PACKAGES[@]}"; do echo " - ${pkg}"; done

    info "make download，实时输出控制台，同时保存日志: ${LOG_DIR}/download.log"
    if ! make download V=s -j"${MAX_JOBS}" 2>&1 | tee "${LOG_DIR}/download.log"; then
        warn "download失败，重试一次"
        if ! make download V=s -j"${MAX_JOBS}" 2>&1 | tee "${LOG_DIR}/download_retry.log"; then
            fatal "源码下载多次失败"
        fi
    fi

    local success_list=()
    local failed_list=()

    info "开始逐个编译软件包，单包失败不会终止整体任务"
    for pkg in "${TARGET_PACKAGES[@]}"; do
        echo ""
        info "--------------------------------------------------"
        info ">>> [开始编译] 软件包: ${pkg}"
        info "--------------------------------------------------"
        local pkg_log="${LOG_DIR}/pkg_${pkg}.log"
        # 使用 package/$pkg/install：自动递归构建全部依赖；单包使用 -j1 规避并发编译race
        if make "package/${pkg}/install" V=s -j1 2>&1 | tee "${pkg_log}"; then
            info "<<< [编译成功] 软件包: ${pkg}"
            success_list+=("${pkg}")
        else
            warn "<<< [编译失败] 软件包: ${pkg}，跳过，继续下一个包；日志：${pkg_log}"
            failed_list+=("${pkg}")
        fi
    done

    info "==== 编译统计 ===="
    info "总包: ${#TARGET_PACKAGES[@]}"
    info "成功: ${#success_list[@]}"
    info "失败: ${#failed_list[@]}"

    mkdir -p "${OUTPUT_DIR}"
    local report_file="${OUTPUT_DIR}/build_report.txt"
    {
        echo "ImmortalWrt Build Report"
        echo "Version: ${IMMORTALWRT_VERSION}"
        echo "Target: ${TARGET_COMBO}"
        echo "Total: ${#TARGET_PACKAGES[@]}"
        echo "Success: ${#success_list[@]}"
        echo "Failed: ${#failed_list[@]}"
        echo ""
        echo "Success packages:"
        for p in "${success_list[@]}"; do echo "  - $p"; done
        echo ""
        echo "Failed packages:"
        for p in "${failed_list[@]}"; do echo "  - $p"; done
    } > "${report_file}"

    if [[ ${#failed_list[@]} -gt 0 ]]; then
        warn "存在编译失败包，详情看build_report.txt以及各个pkg_*.log"
    fi
}

collect_ipks() {
    cd "$SDK_DIR" || fatal "进入SDK目录失败"
    mkdir -p "${OUTPUT_DIR}"
    if [[ -d "${OUTPUT_DIR}" ]]; then
        find "${OUTPUT_DIR}" -mindepth 1 -delete
    fi
    find bin/packages -type f -name "*.ipk" -exec cp {} "${OUTPUT_DIR}/" \;
    info "IPK收集完成，输出目录 ${OUTPUT_DIR}"
    ls -1 "${OUTPUT_DIR}"/*.ipk 2>/dev/null || warn "未产出ipk文件"
}

# ========== 对外主入口函数，Workflow中调用 run_build ==========
run_build() {
    info "===== ImmortalWrt SDK Build Start ====="
    download_sdk
    add_custom_feed
    compile_packages
    collect_ipks
    info "===== Build Finished ====="
}

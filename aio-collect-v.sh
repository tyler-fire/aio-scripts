#!/bin/bash
# 版本: 1.1.0
# ======================================================
# AIO 工具版本收集脚本
# 用法: ./aio-collect-v.sh [IP1 IP2 ...]
# 无参数: 自动从配置和数据库获取本机+Worker IP
# 有参数: 使用指定 IP（跳过自动获取）
# ======================================================

set -euo pipefail

# 配置
TOOLS_PATH="/opt/aio/airflow/tools"
RPC_PORT="6611"
AIO_ENV="/opt/aio/cfg/aio.env"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

LOCAL_ARCH=$(uname -m)
RPC_BIN="${TOOLS_PATH}/rpc/${LOCAL_ARCH}/rpc"

# 工具定义: 名称|本地命令|远程命令
TOOL_DEFS=(
    "aio-speed|${TOOLS_PATH}/rpc/${LOCAL_ARCH}/aio-speed --version|${TOOLS_PATH}/rpc/{arch}/aio-speed --version"
    "aio-speedd|${TOOLS_PATH}/rpc/${LOCAL_ARCH}/aio-speedd --version|${TOOLS_PATH}/rpc/{arch}/aio-speedd --version"
    "zfsdeamon|cd ${TOOLS_PATH}/s3-tools/${LOCAL_ARCH}/zfsdeamon && ./zfsdeamon --version|cd ${TOOLS_PATH}/s3-tools/{arch}/zfsdeamon && ./zfsdeamon --version"
    "afs-cli|cd ${TOOLS_PATH}/s3-tools/${LOCAL_ARCH}/afs && ./afs-cli --version 2>&1|cd ${TOOLS_PATH}/s3-tools/{arch}/afs && ./afs-cli --version 2>&1"
    "afsd|cd ${TOOLS_PATH}/s3-tools/${LOCAL_ARCH}/afs && ./afsd --version x 2>&1|cd ${TOOLS_PATH}/s3-tools/{arch}/afs && ./afsd --version x 2>&1"
    "s3-tool|cd ${TOOLS_PATH}/s3-tools/${LOCAL_ARCH}/s3-tool && ./s3-tool --version|cd ${TOOLS_PATH}/s3-tools/{arch}/s3-tool && ./s3-tool --version"
    "fsdeamon|cd ${TOOLS_PATH}/fs-tools/${LOCAL_ARCH}/fsdeamon && ./fsdeamon -V 2>&1|cd ${TOOLS_PATH}/fs-tools/{arch}/fsdeamon && ./fsdeamon -V 2>&1"
    "fs-cli|cd ${TOOLS_PATH}/fs-tools/${LOCAL_ARCH}/fsclient && ./fs-cli --version|cd ${TOOLS_PATH}/fs-tools/{arch}/fsclient && ./fs-cli --version"
)

# 从 aio.env 读取配置
read_env() {
    grep -E "^$1=" "${AIO_ENV}" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]'
}

# 从 MySQL 查询 Worker IP（去重）
get_worker_ips() {
    local db_host="$1"
    local db_user db_pass db_port
    db_user=$(read_env AIO_DB_USERNAME)
    db_pass=$(read_env AIO_DB_PASSWORD)
    db_port=$(read_env AIO_DB_PORT)
    db_port=${db_port:-3306}

    mysql -h "${db_host}" -P "${db_port}" -u "${db_user}" -p"${db_pass}" aio \
        -N -e "SELECT DISTINCT sys_dn_ipaddr FROM aio_data_nodes WHERE sys_dn_is_delete = 0;" 2>/dev/null
}

# 获取本机单个工具版本
get_local_version() {
    local cmd="$1"
    local ver
    ver=$(eval "${cmd}" 2>&1) || true
    # 清理版本号（去掉前缀文字，只保留数字和点）
    echo "${ver}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || echo "未安装"
}

# 获取远程单个工具版本
get_remote_version() {
    local host="$1"
    local cmd="$2"
    local arch="$3"
    local real_cmd="${cmd//\{arch\}/${arch}}"
    local ver
    ver=$("${RPC_BIN}" -h "${host}" -p "${RPC_PORT}" -c "${real_cmd}" 2>&1) || true
    echo "${ver}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || echo "未安装"
}

# 获取远程主机架构
get_remote_arch() {
    local host="$1"
    "${RPC_BIN}" -h "${host}" -p "${RPC_PORT}" -c "uname -m" 2>/dev/null || echo "unknown"
}

# 主流程
main() {
    local local_ip
    local all_ips=()
    local ip_labels=()
    declare -A versions  # versions[ip,tool]=version

    # 获取 IP 列表
    if [[ $# -gt 0 ]]; then
        all_ips=("$@")
        for ip in "${all_ips[@]}"; do
            ip_labels+=("${ip}")
        done
    else
        local_ip=$(read_env AIO_WEBSRV_HOST)
        if [[ -z "${local_ip}" ]]; then
            echo -e "${RED}错误: 无法从 ${AIO_ENV} 读取 AIO_WEBSRV_HOST${NC}"
            exit 1
        fi

        local worker_ips
        worker_ips=$(get_worker_ips "${local_ip}")
        if [[ -n "${worker_ips}" ]]; then
            while IFS= read -r ip; do
                [[ -n "${ip}" ]] && all_ips+=("${ip}") && ip_labels+=("Worker(${ip})")
            done <<< "${worker_ips}"
        fi

        all_ips+=("${local_ip}")
        ip_labels+=("Server(${local_ip})")
    fi

    # 检查 RPC 工具
    if [[ ! -f "${RPC_BIN}" ]]; then
        echo -e "${RED}错误: RPC 工具不存在 ${RPC_BIN}${NC}"
        exit 1
    fi

    # 收集所有版本
    echo -e "${YELLOW}正在收集版本信息...${NC}"

    for idx in "${!all_ips[@]}"; do
        local ip="${all_ips[$idx]}"
        local is_local=false
        [[ "${ip}" == "${local_ip}" ]] && is_local=true

        # 获取架构
        local arch="${LOCAL_ARCH}"
        if [[ "${is_local}" == false ]]; then
            arch=$(get_remote_arch "${ip}")
        fi

        # 收集每个工具版本
        for tool_def in "${TOOL_DEFS[@]}"; do
            IFS='|' read -r name local_cmd remote_cmd <<< "${tool_def}"
            local ver
            if [[ "${is_local}" == true ]]; then
                ver=$(get_local_version "${local_cmd}")
            else
                ver=$(get_remote_version "${ip}" "${remote_cmd}" "${arch}")
            fi
            versions["${ip},${name}"]="${ver}"
        done
    done

    # 输出表格
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}       AIO 工具版本对比${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""

    # 计算列宽
    local col_width=15
    for label in "${ip_labels[@]}"; do
        [[ ${#label} -gt ${col_width} ]] && col_width=${#label}
    done
    col_width=$((col_width + 2))

    # 表头
    printf "  ${BOLD}%-16s${NC}" "工具"
    for label in "${ip_labels[@]}"; do
        printf "${BOLD}%-${col_width}s${NC}" "${label}"
    done
    echo ""

    # 分隔线
    printf "  %-16s" "────────────────"
    for _ in "${ip_labels[@]}"; do
        printf "%-${col_width}s" "$(printf '%0.s─' $(seq 1 ${col_width}))"
    done
    echo ""

    # 数据行
    for tool_def in "${TOOL_DEFS[@]}"; do
        IFS='|' read -r name _ _ <<< "${tool_def}"
        printf "  %-16s" "${name}"

        # 获取所有版本用于对比
        local first_ver=""
        local all_same=true
        for ip in "${all_ips[@]}"; do
            local ver="${versions[${ip},${name}]}"
            if [[ -z "${first_ver}" ]]; then
                first_ver="${ver}"
            elif [[ "${ver}" != "${first_ver}" ]]; then
                all_same=false
            fi
        done

        # 输出版本（不一致时高亮）
        for ip in "${all_ips[@]}"; do
            local ver="${versions[${ip},${name}]}"
            if [[ "${all_same}" == false ]]; then
                printf "${YELLOW}%-${col_width}s${NC}" "${ver}"
            else
                printf "%-${col_width}s" "${ver}"
            fi
        done
        echo ""
    done

    echo ""
    echo -e "${GREEN}========================================${NC}"
}

main "$@"

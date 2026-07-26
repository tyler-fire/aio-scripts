#!/bin/bash
# 版本: 1.6.0
# AIO 工具版本收集脚本
# 用法:
#   ./aio-collect-v.sh              # 自动从数据库获取 Server / Worker / Agent 主机
#   ./aio-collect-v.sh IP1 IP2 ...  # 手动指定多个主机，自动识别 Worker / Agent
#   ./aio-collect-v.sh 'IP1,IP2'    # 也支持逗号分隔
#
# 环境变量:
#   COLLECT_PAR        主机并行度，默认 8
#   RPC_TIMEOUT        单条 RPC 超时（探测/取架构），默认 10 秒
#   RPC_BATCH_TIMEOUT  批量版本命令 RPC 超时，默认 120 秒
#
# v1.6.0: 收集并行化。主机间按 COLLECT_PAR 并行；主机内全部版本命令合并为
#         一次 RPC 批量执行（原来每主机 18 次 RPC 往返，多主机时非常慢）。
#         aio.env/ENC/mysql/RPC 封装统一走 lib/common.sh。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
    echo "错误: 缺少公共库 ${SCRIPT_DIR}/lib/common.sh（请重新安装 aio-scripts）" >&2
    exit 1
fi
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TOOLS_PATH="/opt/aio/airflow/tools"
RPC_TIMEOUT="${RPC_TIMEOUT:-10}"
COLLECT_PAR="${COLLECT_PAR:-8}"
RPC_BATCH_TIMEOUT="${RPC_BATCH_TIMEOUT:-120}"
BATCH_SEP="__AIO_VSEP__"

LOCAL_ARCH=$(uname -m)
RPC_BIN="$(aio_rpc_bin)"
RESULT_DIR=""

TOOL_NAMES=(
    "aio-oss"
    "aio-speed"
    "aio-speedd"
    "fs-cli"
    "fsdeamon"
    "gmssl"
    "obk_ftp"
    "zfsdeamon"
    "afs-cli"
    "afsd"
    "s3fs"
    "s3-tool"
    "lsof"
    "rdbcomm"
    "rdbcommd"
    "xtrabackup2.4"
    "xtrabackup8.0"
    "fsbackup"
)

TOOL_CMDS=(
    "${TOOLS_PATH}/aio-oss/{arch}/aio-oss --version"
    "${TOOLS_PATH}/rpc/{arch}/aio-speed --version"
    "${TOOLS_PATH}/rpc/{arch}/aio-speedd --version"
    "cd ${TOOLS_PATH}/fs-tools/{arch}/fsclient && ./fs-cli -v"
    "cd ${TOOLS_PATH}/fs-tools/{arch}/fsdeamon && ./fsdeamon -V 2>&1"
    "${TOOLS_PATH}/gmssl/{arch}/gmssl version"
    "${TOOLS_PATH}/obk_ftp/{arch}/FileTransferAgent --version"
    "cd ${TOOLS_PATH}/s3-tools/{arch}/zfsdeamon && ./zfsdeamon --version"
    "cd ${TOOLS_PATH}/s3-tools/{arch}/afs && ./afs-cli --version 2>&1"
    "cd ${TOOLS_PATH}/s3-tools/{arch}/afs && ./afsd --version x 2>&1 | grep -iEv 'usage|endpoint|access-key|secret-key|verify-ssl'"
    "${TOOLS_PATH}/s3-tools/{arch}/s3fs --version 2>&1"
    "cd ${TOOLS_PATH}/s3-tools/{arch}/s3-tool && ./s3-tool --version"
    "/usr/bin/lsof -v 2>&1"
    "${TOOLS_PATH}/rdbcomm/{arch}/rdbcomm --version 2>&1"
    "${TOOLS_PATH}/rdbcomm/{arch}/rdbcommd --version 2>&1"
    "/opt/aio/airflow/percona-xtrabackup-2.4.17-Linux-x86_64/bin/xtrabackup --version 2>&1"
    "/opt/aio/airflow/percona-xtrabackup-8.0.26-Linux-x86_64/bin/xtrabackup --version 2>&1"
    "cat /sys/module/fsbackup/version 2>/dev/null"
)

AGENT_SKIP_TOOLS=(
    "gmssl"
    "obk_ftp"
    "afs-cli"
    "afsd"
    "s3fs"
    "s3-tool"
    "lsof"
)

HOSTS=()
ROLES=()
LOCAL_IP=""
declare -A VERSIONS
declare -A ARCHS
declare -A STATUS
declare -A DB_ROLES
declare -A ROLE_PROBE_ERRORS

skip_agent_tool() {
    local tool="$1"
    local item

    for item in "${AGENT_SKIP_TOOLS[@]}"; do
        [[ "${item}" == "${tool}" ]] && return 0
    done
    return 1
}

run_sql() {
    aio_mysql_query "$1" 2>/dev/null
}

cleanup_on_exit() {
    aio_mysql_cleanup
    if [[ -n "${RESULT_DIR}" && -d "${RESULT_DIR}" ]]; then
        rm -rf "${RESULT_DIR}"
    fi
}

role_priority() {
    case "$1" in
        server) echo 3 ;;
        worker) echo 2 ;;
        agent) echo 1 ;;
        *) echo 0 ;;
    esac
}

normalize_role() {
    case "$1" in
        rdb|server) echo "server" ;;
        storage|worker) echo "worker" ;;
        unknown) echo "unknown" ;;
        *) echo "agent" ;;
    esac
}

add_host() {
    local host="$1"
    local role
    local idx
    local old_pri new_pri

    host=$(echo "${host}" | tr -d '[:space:]')
    [[ -z "${host}" ]] && return

    role=$(normalize_role "$2")
    new_pri=$(role_priority "${role}")

    for idx in "${!HOSTS[@]}"; do
        if [[ "${HOSTS[$idx]}" == "${host}" ]]; then
            old_pri=$(role_priority "${ROLES[$idx]}")
            if [[ "${new_pri}" -gt "${old_pri}" ]]; then
                ROLES[$idx]="${role}"
            fi
            return
        fi
    done

    HOSTS+=("${host}")
    ROLES+=("${role}")
}

connector_roles_sql() {
    cat <<'SQL'
SELECT c.remote_host,
       CASE MAX(CASE r.role
           WHEN 'rdb' THEN 3
           WHEN 'storage' THEN 2
           ELSE 1
       END)
           WHEN 3 THEN 'server'
           WHEN 2 THEN 'worker'
           ELSE 'agent'
       END
FROM rdb_connector c
LEFT JOIN rdb_connector_role r ON r.connector_id = c.id
WHERE c.remote_host IS NOT NULL AND c.remote_host <> ''
GROUP BY c.id, c.remote_host;
SQL
}

query_db_host_roles() {
    local has_connector

    has_connector=$(run_sql \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='rdb_connector';")

    if [[ "${has_connector}" == "1" ]]; then
        run_sql "$(connector_roles_sql)"
    else
        run_sql "SELECT DISTINCT sys_dn_ipaddr, 'worker' FROM aio_data_nodes WHERE sys_dn_is_delete = 0;"
    fi
}

load_hosts_from_db() {
    local db_host="$1"
    local rows

    add_host "${db_host}" "server"
    rows=$(query_db_host_roles)
    while IFS=$'\t' read -r host role || [[ -n "${host}" ]]; do
        add_host "${host}" "${role}"
    done <<< "${rows}"
}

load_role_map_from_db() {
    local db_host="$1"
    local rows host role

    DB_ROLES["${db_host}"]="server"
    rows=$(query_db_host_roles || true)

    while IFS=$'\t' read -r host role || [[ -n "${host}" ]]; do
        host=$(echo "${host}" | tr -d '[:space:]')
        [[ -z "${host}" ]] && continue
        DB_ROLES["${host}"]=$(normalize_role "${role}")
    done <<< "${rows}"
}

rpc_exec() {
    local host="$1"
    local cmd="$2"
    local run_timeout="${3:-${RPC_TIMEOUT}}"
    timeout "${run_timeout}" "${RPC_BIN}" -h "${host}" -p "${AIO_RPC_PORT}" -c "${cmd}" 2>&1
}

probe_rpc() {
    local host="$1"
    rpc_exec "${host}" "/bin/date"
}

detect_remote_role() {
    local host="$1"
    local detected

    if ! detected=$(rpc_exec "${host}" \
        "if [ -d /opt/aio/cdm ]; then echo server; elif [ -x /opt/aio/airflow/bin/airflow ] || [ -f /opt/aio/cfg/airflow.cfg ]; then echo worker; else echo agent; fi"); then
        ROLE_PROBE_ERRORS["${host}"]=$(echo "${detected}" | head -1)
        echo "unknown"
        return
    fi
    detected=$(echo "${detected}" | tr -d '[:space:]')
    case "${detected}" in
        server|worker|agent) echo "${detected}" ;;
        *) echo "unknown" ;;
    esac
}

resolve_manual_role() {
    local host="$1"

    if [[ -n "${DB_ROLES[${host}]:-}" ]]; then
        echo "${DB_ROLES[${host}]}"
    else
        detect_remote_role "${host}"
    fi
}

add_manual_hosts() {
    local db_host="$1"
    shift
    local input host role

    load_role_map_from_db "${db_host}"
    for input in "$@"; do
        input=${input//,/ }
        for host in ${input}; do
            if ! aio_valid_host "${host}"; then
                echo "警告: 忽略无效主机: ${host}" >&2
                continue
            fi
            role=$(resolve_manual_role "${host}")
            add_host "${host}" "${role}"
        done
    done
}

get_arch() {
    local host="$1"
    local role="$2"
    local arch

    if [[ "${host}" == "${LOCAL_IP}" && "${role}" == "server" ]]; then
        echo "${LOCAL_ARCH}"
        return
    fi

    arch=$(rpc_exec "${host}" "uname -m" || true)
    arch=$(echo "${arch}" | tr -d '[:space:]')
    echo "${arch:-unknown}"
}

clean_version() {
    local output="$1"
    local ver

    ver=$(echo "${output}" | grep -oE '[0-9]+(\.[0-9]+){1,4}' | head -1)
    if [[ -n "${ver}" ]]; then
        echo "${ver}"
    else
        echo "未安装"
    fi
}

# 把该主机需要执行的全部版本命令拼成一个批量脚本，段与段之间用 BATCH_SEP 分隔。
# 被跳过的工具输出 __SKIP__ 占位，保证段序号与 TOOL_NAMES 下标一一对应。
build_batch_script() {
    local role="$1"
    local arch="$2"
    local tool_idx cmd script=""

    for tool_idx in "${!TOOL_NAMES[@]}"; do
        if [[ "${role}" == "agent" ]] && skip_agent_tool "${TOOL_NAMES[$tool_idx]}"; then
            script+="echo __SKIP__; echo ${BATCH_SEP}; "
            continue
        fi
        cmd="${TOOL_CMDS[$tool_idx]//\{arch\}/${arch}}"
        script+="( ${cmd} ) 2>&1; echo ${BATCH_SEP}; "
    done
    printf '%s' "${script}"
}

# 解析批量输出，按段落顺序输出 "TOOL\t工具名\t版本" 行
parse_batch_output() {
    local output="$1"
    local tool_idx=0
    local section=""
    local line

    while IFS= read -r line; do
        if [[ "${line}" == "${BATCH_SEP}" ]]; then
            if [[ "${tool_idx}" -lt "${#TOOL_NAMES[@]}" && "${section}" != __SKIP__* ]]; then
                printf 'TOOL\t%s\t%s\n' "${TOOL_NAMES[$tool_idx]}" "$(clean_version "${section}")"
            fi
            tool_idx=$((tool_idx + 1))
            section=""
        else
            section+="${line}"$'\n'
        fi
    done <<< "${output}"
}

# 收集单个主机的全部版本信息，结果写入独立文件（在后台子进程中运行，
# 不能修改父进程的关联数组）
collect_host() {
    local host="$1"
    local role="$2"
    local outfile="$3"
    local arch probe_output batch output rc
    local is_local_server=false

    if [[ "${role}" == "unknown" && -n "${ROLE_PROBE_ERRORS[${host}]:-}" ]]; then
        printf 'STATUS\tRPC 不可达: %s\n' "${ROLE_PROBE_ERRORS[${host}]}" > "${outfile}"
        return
    fi

    [[ "${host}" == "${LOCAL_IP}" && "${role}" == "server" ]] && is_local_server=true

    if [[ "${is_local_server}" == false ]]; then
        if ! probe_output=$(probe_rpc "${host}" 2>&1); then
            printf 'STATUS\tRPC 不可达: %s\n' "$(echo "${probe_output}" | head -1)" > "${outfile}"
            return
        fi
    fi

    arch=$(get_arch "${host}" "${role}")
    batch=$(build_batch_script "${role}" "${arch}")

    if [[ "${is_local_server}" == true ]]; then
        output=$(bash -c "${batch}" 2>&1)
        rc=0
    else
        output=$(rpc_exec "${host}" "${batch}" "${RPC_BATCH_TIMEOUT}")
        rc=$?
    fi

    if [[ "${rc}" -ne 0 && -z "${output}" ]]; then
        printf 'STATUS\t批量执行失败或超时\n' > "${outfile}"
        return
    fi

    {
        printf 'STATUS\tok\n'
        printf 'ARCH\t%s\n' "${arch}"
        parse_batch_output "${output}"
    } > "${outfile}"
}

collect_versions() {
    local idx host role outfile kind a b

    RESULT_DIR=$(mktemp -d /tmp/aio_collect_v.XXXXXX)

    for idx in "${!HOSTS[@]}"; do
        host="${HOSTS[$idx]}"
        role="${ROLES[$idx]}"
        outfile="${RESULT_DIR}/${idx}.result"
        # 并行度限流：同时最多 COLLECT_PAR 个主机在收集
        while [[ $(jobs -rp | wc -l) -ge ${COLLECT_PAR} ]]; do
            sleep 0.2
        done
        collect_host "${host}" "${role}" "${outfile}" &
    done
    wait

    for idx in "${!HOSTS[@]}"; do
        host="${HOSTS[$idx]}"
        outfile="${RESULT_DIR}/${idx}.result"
        STATUS["${host}"]="RPC 不可达"
        [[ -f "${outfile}" ]] || continue
        while IFS=$'\t' read -r kind a b; do
            case "${kind}" in
                STATUS) STATUS["${host}"]="${a}" ;;
                ARCH)   ARCHS["${host}"]="${a}" ;;
                TOOL)   VERSIONS["${host}|${a}"]="${b}" ;;
            esac
        done < "${outfile}"
    done

    rm -rf "${RESULT_DIR}"
    RESULT_DIR=""
}

show_host_list() {
    local role="$1"
    local title="$2"
    local idx
    local found=false

    printf "  %-8s" "${title}:"
    for idx in "${!HOSTS[@]}"; do
        if [[ "${ROLES[$idx]}" == "${role}" ]]; then
            printf " %s" "${HOSTS[$idx]}"
            found=true
        fi
    done
    [[ "${found}" == false ]] && printf " 无"
    echo ""
}

print_unknown_summary() {
    local idx host

    has_role "unknown" || return

    echo ""
    echo "========================================"
    echo " Unknown"
    echo "========================================"
    for idx in "${!HOSTS[@]}"; do
        [[ "${ROLES[$idx]}" == "unknown" ]] || continue
        host="${HOSTS[$idx]}"
        echo "  ${host}: ${STATUS[${host}]:-无法识别主机角色}"
    done
}

has_role() {
    local role="$1"
    local idx
    for idx in "${!HOSTS[@]}"; do
        [[ "${ROLES[$idx]}" == "${role}" ]] && return 0
    done
    return 1
}

print_core_table() {
    local core_hosts=()
    local core_labels=()
    local idx host role label tool_idx tool version

    for idx in "${!HOSTS[@]}"; do
        role="${ROLES[$idx]}"
        if [[ "${role}" == "server" || "${role}" == "worker" ]]; then
            host="${HOSTS[$idx]}"
            [[ "${role}" == "server" ]] && label="Server(${host})" || label="Worker(${host})"
            core_hosts+=("${host}")
            core_labels+=("${label}")
        fi
    done

    [[ ${#core_hosts[@]} -eq 0 ]] && return

    echo ""
    echo "========================================"
    echo " Server / Worker"
    echo "========================================"

    printf "  %-16s" "工具"
    for label in "${core_labels[@]}"; do
        printf " %-22s" "${label}"
    done
    echo ""

    printf "  %-16s" "────────────────"
    for _ in "${core_hosts[@]}"; do
        printf " %-22s" "──────────────────────"
    done
    echo ""

    printf "  %-16s" "arch"
    for host in "${core_hosts[@]}"; do
        if [[ "${STATUS[${host}]}" == "ok" ]]; then
            printf " %-22s" "${ARCHS[${host}]:-unknown}"
        else
            printf " %-22s" "RPC 不可达"
        fi
    done
    echo ""

    for tool_idx in "${!TOOL_NAMES[@]}"; do
        tool="${TOOL_NAMES[$tool_idx]}"
        printf "  %-16s" "${tool}"
        for host in "${core_hosts[@]}"; do
            if [[ "${STATUS[${host}]}" == "ok" ]]; then
                version="${VERSIONS[${host}|${tool}]:-N/A}"
            else
                version="超时"
            fi
            printf " %-22s" "${version}"
        done
        echo ""
    done
}

contains_value() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [[ "${item}" == "${needle}" ]] && return 0
    done
    return 1
}

join_hosts() {
    local first=true
    local host
    for host in "$@"; do
        if [[ "${first}" == true ]]; then
            printf "%s" "${host}"
            first=false
        else
            printf ", %s" "${host}"
        fi
    done
}

print_agent_summary() {
    local agent_hosts=()
    local idx host tool_idx tool version unique_versions=()
    local hosts_for_version=()

    for idx in "${!HOSTS[@]}"; do
        if [[ "${ROLES[$idx]}" == "agent" ]]; then
            agent_hosts+=("${HOSTS[$idx]}")
        fi
    done

    [[ ${#agent_hosts[@]} -eq 0 ]] && return

    echo ""
    echo "========================================"
    echo " Agent"
    echo "========================================"

    echo ""
    echo "主机:"
    join_hosts "${agent_hosts[@]}"
    echo ""

    for host in "${agent_hosts[@]}"; do
        if [[ "${STATUS[${host}]}" != "ok" ]]; then
            echo "  ${host}: ${STATUS[${host}]}"
        fi
    done

    echo ""
    for tool_idx in "${!TOOL_NAMES[@]}"; do
        tool="${TOOL_NAMES[$tool_idx]}"
        skip_agent_tool "${tool}" && continue
        unique_versions=()

        for host in "${agent_hosts[@]}"; do
            if [[ "${STATUS[${host}]}" == "ok" ]]; then
                version="${VERSIONS[${host}|${tool}]:-N/A}"
            else
                version="RPC 不可达"
            fi
            contains_value "${version}" "${unique_versions[@]}" || unique_versions+=("${version}")
        done

        echo "[${tool}]"
        for version in "${unique_versions[@]}"; do
            hosts_for_version=()
            for host in "${agent_hosts[@]}"; do
                if [[ "${STATUS[${host}]}" == "ok" ]]; then
                    [[ "${VERSIONS[${host}|${tool}]:-N/A}" == "${version}" ]] && hosts_for_version+=("${host}")
                else
                    [[ "${version}" == "RPC 不可达" ]] && hosts_for_version+=("${host}")
                fi
            done
            printf "  %-14s " "${version}:"
            join_hosts "${hosts_for_version[@]}"
            echo ""
        done
        echo ""
    done
}

main() {
    trap cleanup_on_exit EXIT

    if [[ ! -f "${RPC_BIN}" ]]; then
        echo "错误: RPC 工具不存在 ${RPC_BIN}"
        exit 1
    fi

    LOCAL_IP=$(aio_env_get AIO_WEBSRV_HOST)

    if [[ -z "${LOCAL_IP}" ]]; then
        echo "错误: 无法从 ${AIO_ENV_FILE} 读取 AIO_WEBSRV_HOST"
        exit 1
    fi

    if [[ $# -gt 0 ]]; then
        add_manual_hosts "${LOCAL_IP}" "$@"
    else
        load_hosts_from_db "${LOCAL_IP}"
    fi

    if [[ ${#HOSTS[@]} -eq 0 ]]; then
        echo "错误: 未找到任何主机"
        exit 1
    fi

    echo "正在收集版本信息（并行度 ${COLLECT_PAR}）..."
    echo ""
    echo "主机清单"
    show_host_list "server" "Server"
    show_host_list "worker" "Worker"
    show_host_list "agent" "Agent"
    show_host_list "unknown" "Unknown"

    collect_versions
    print_core_table
    print_agent_summary
    print_unknown_summary
}

main "$@"

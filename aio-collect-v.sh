#!/bin/bash
# 版本: 1.5.0
# AIO 工具版本收集脚本
# 用法:
#   ./aio-collect-v.sh              # 自动从数据库获取 Server / Worker / Agent 主机
#   ./aio-collect-v.sh IP1 IP2 ...  # 手动指定多个主机，自动识别 Worker / Agent
#   ./aio-collect-v.sh 'IP1,IP2'    # 也支持逗号分隔

set -uo pipefail

TOOLS_PATH="/opt/aio/airflow/tools"
RPC_PORT="${RPC_PORT:-6611}"
RPC_TIMEOUT="${RPC_TIMEOUT:-10}"
AIO_ENV="/opt/aio/cfg/aio.env"

if [[ -x /usr/local/mysql/bin/mysql ]]; then
    MYSQL_BIN="/usr/local/mysql/bin/mysql"
else
    MYSQL_BIN="mysql"
fi

LOCAL_ARCH=$(uname -m)
RPC_BIN="${TOOLS_PATH}/rpc/${LOCAL_ARCH}/rpc"
MYSQL_DEFAULTS_FILE=""

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

read_env() {
    local key="$1"
    grep -E "^${key}=" "${AIO_ENV}" 2>/dev/null | sed "s/^${key}=//;s/['\"]//g" | tr -d '[:space:]'
}

decrypt_enc() {
    local enc_str="$1"
    enc_str="${enc_str#ENC(}"
    enc_str="${enc_str%)}"
    AIO_ENC_DATA="${enc_str}" /opt/aio/cdm/bin/python3 -c "
import sys, base64, os
sys.path.insert(0, '/opt/aio/cdm/lib/python3.6/site-packages')
from Crypto.Cipher import AES
from Crypto.Util.Padding import unpad
from aio.config.key import AES_KEY_BASE_64
key = base64.b64decode(AES_KEY_BASE_64)
data = base64.b64decode(os.environ['AIO_ENC_DATA'])
plain = unpad(AES.new(key, AES.MODE_CBC, IV=b'0000000000000000').decrypt(data), AES.block_size)
sys.stdout.buffer.write(plain)
" 2>/dev/null
}

read_env_value() {
    local val
    val=$(read_env "$1")
    if [[ "${val}" =~ ^ENC\( ]]; then
        decrypt_enc "${val}"
    else
        echo "${val}"
    fi
}

run_sql() {
    local db_host="$1"
    local sql="$2"
    local db_user db_pass db_port defaults_file

    db_user=$(read_env AIO_DB_USERNAME)
    db_pass=$(read_env_value AIO_DB_PASSWORD)
    db_port=$(read_env AIO_DB_PORT)
    db_port=${db_port:-3306}

    defaults_file=$(mktemp /tmp/aio_collect_v_mysql.XXXXXX.cnf)
    chmod 600 "${defaults_file}"
    printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword=%s\n' \
        "${db_host}" "${db_port}" "${db_user}" "${db_pass}" > "${defaults_file}"
    MYSQL_DEFAULTS_FILE="${defaults_file}"

    "${MYSQL_BIN}" --defaults-extra-file="${defaults_file}" aio -N -e "${sql}" 2>/dev/null
    rm -f "${defaults_file}"
    MYSQL_DEFAULTS_FILE=""
}

cleanup_mysql_defaults_file() {
    if [[ -n "${MYSQL_DEFAULTS_FILE}" && -f "${MYSQL_DEFAULTS_FILE}" ]]; then
        rm -f "${MYSQL_DEFAULTS_FILE}"
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

valid_host() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
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

load_hosts_from_db() {
    local db_host="$1"
    local has_connector rows

    add_host "${db_host}" "server"

    has_connector=$(run_sql "${db_host}" \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='rdb_connector';")

    if [[ "${has_connector}" == "1" ]]; then
        rows=$(run_sql "${db_host}" \
            "SELECT c.remote_host,
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
             GROUP BY c.id, c.remote_host;")
        while IFS=$'\t' read -r host role || [[ -n "${host}" ]]; do
            add_host "${host}" "${role}"
        done <<< "${rows}"
        return
    fi

    rows=$(run_sql "${db_host}" \
        "SELECT DISTINCT sys_dn_ipaddr, 'worker' FROM aio_data_nodes WHERE sys_dn_is_delete = 0;")
    while IFS=$'\t' read -r host role || [[ -n "${host}" ]]; do
        add_host "${host}" "${role}"
    done <<< "${rows}"
}

load_role_map_from_db() {
    local db_host="$1"
    local has_connector rows host role

    DB_ROLES["${db_host}"]="server"
    has_connector=$(run_sql "${db_host}" \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='rdb_connector';" || true)

    if [[ "${has_connector}" == "1" ]]; then
        rows=$(run_sql "${db_host}" \
            "SELECT c.remote_host,
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
             GROUP BY c.id, c.remote_host;" || true)
    else
        rows=$(run_sql "${db_host}" \
            "SELECT DISTINCT sys_dn_ipaddr, 'worker' FROM aio_data_nodes WHERE sys_dn_is_delete = 0;" || true)
    fi

    while IFS=$'\t' read -r host role || [[ -n "${host}" ]]; do
        host=$(echo "${host}" | tr -d '[:space:]')
        [[ -z "${host}" ]] && continue
        DB_ROLES["${host}"]=$(normalize_role "${role}")
    done <<< "${rows}"
}

rpc_exec() {
    local host="$1"
    local cmd="$2"
    timeout "${RPC_TIMEOUT}" "${RPC_BIN}" -h "${host}" -p "${RPC_PORT}" -c "${cmd}" 2>&1
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
            if ! valid_host "${host}"; then
                echo "警告: 忽略无效主机: ${host}" >&2
                continue
            fi
            role=$(resolve_manual_role "${host}")
            add_host "${host}" "${role}"
        done
    done
}

local_exec() {
    local cmd="$1"
    eval "${cmd}" 2>&1
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

get_version() {
    local host="$1"
    local role="$2"
    local cmd_template="$3"
    local arch="$4"
    local cmd output

    cmd="${cmd_template//\{arch\}/${arch}}"

    if [[ "${host}" == "${LOCAL_IP}" && "${role}" == "server" ]]; then
        output=$(local_exec "${cmd}" || true)
    else
        output=$(rpc_exec "${host}" "${cmd}" || true)
    fi

    clean_version "${output}"
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

collect_versions() {
    local idx tool_idx host role arch version probe_output

    for idx in "${!HOSTS[@]}"; do
        host="${HOSTS[$idx]}"
        role="${ROLES[$idx]}"
        STATUS["${host}"]="ok"

        if [[ "${role}" == "unknown" && -n "${ROLE_PROBE_ERRORS[${host}]:-}" ]]; then
            STATUS["${host}"]="RPC 不可达: ${ROLE_PROBE_ERRORS[${host}]}"
            continue
        fi

        if [[ "${host}" != "${LOCAL_IP}" || "${role}" != "server" ]]; then
            if ! probe_output=$(probe_rpc "${host}" 2>&1); then
                STATUS["${host}"]="RPC 不可达: $(echo "${probe_output}" | head -1)"
                continue
            fi
        fi

        arch=$(get_arch "${host}" "${role}")
        ARCHS["${host}"]="${arch}"

        for tool_idx in "${!TOOL_NAMES[@]}"; do
            if [[ "${role}" == "agent" ]] && skip_agent_tool "${TOOL_NAMES[$tool_idx]}"; then
                continue
            fi
            version=$(get_version "${host}" "${role}" "${TOOL_CMDS[$tool_idx]}" "${arch}")
            VERSIONS["${host}|${TOOL_NAMES[$tool_idx]}"]="${version}"
        done
    done
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
    trap cleanup_mysql_defaults_file EXIT

    if [[ ! -f "${RPC_BIN}" ]]; then
        echo "错误: RPC 工具不存在 ${RPC_BIN}"
        exit 1
    fi

    LOCAL_IP=$(read_env AIO_WEBSRV_HOST)

    if [[ $# -gt 0 ]]; then
        if [[ -z "${LOCAL_IP}" ]]; then
            echo "错误: 无法从 ${AIO_ENV} 读取 AIO_WEBSRV_HOST"
            exit 1
        fi
        add_manual_hosts "${LOCAL_IP}" "$@"
    else
        if [[ -z "${LOCAL_IP}" ]]; then
            echo "错误: 无法从 ${AIO_ENV} 读取 AIO_WEBSRV_HOST"
            exit 1
        fi
        load_hosts_from_db "${LOCAL_IP}"
    fi

    if [[ ${#HOSTS[@]} -eq 0 ]]; then
        echo "错误: 未找到任何主机"
        exit 1
    fi

    echo "正在收集版本信息..."
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

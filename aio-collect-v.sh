#!/bin/bash
# 版本: 1.3.0
# ======================================================
# AIO 工具版本收集脚本
# 用法: ./aio-collect-v.sh [IP1 IP2 ...]
# 无参数: 自动从 rdb_connector 表获取所有纳管主机
#         (Server / Worker / 所有 connector 资源主机)
# 有参数: 使用指定 IP（跳过自动获取）
#
# 说明:
#   - 除本机外, 所有版本均通过 RPC(端口 6611) 远程采集
#   - connector 主机额外采集 fsbackup 内核模块版本
#     (cat /sys/module/fsbackup/version)
#   - RPC 不可达(rpc 服务未启动) 时快速判超时, 该主机所有工具标记"超时"
# ======================================================

set -euo pipefail

# 配置
TOOLS_PATH="/opt/aio/airflow/tools"
RPC_PORT="6611"
RPC_TIMEOUT="5"        # 单次 RPC 调用最大等待秒数(rpc 服务未启动时快速失败)
AIO_ENV="/opt/aio/cfg/aio.env"

# mysql 客户端: AIO 自带在 /usr/local/mysql/bin, 非交互 SSH 的 PATH 里常没有,
# 故优先用绝对路径, 找不到再回退到 PATH 中的 mysql
if [[ -x /usr/local/mysql/bin/mysql ]]; then
    MYSQL_BIN="/usr/local/mysql/bin/mysql"
else
    MYSQL_BIN="mysql"
fi

# fsbackup 内核模块版本采集命令(connector 主机专用)
FSBACKUP_VER_CMD="cat /sys/module/fsbackup/version 2>/dev/null"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

LOCAL_ARCH=$(uname -m)
RPC_BIN="${TOOLS_PATH}/rpc/${LOCAL_ARCH}/rpc"

# 工具定义: 名称<TAB>本地命令<TAB>远程命令
# 字段分隔符用制表符(TAB), 不能用 '|' —— 命令里含管道符会与字段分隔冲突,
# 导致 read 把 local_cmd 在第一个管道处截断(afsd 的过滤就是这么丢失的)。
TOOL_DEFS=(
    "aio-oss	${TOOLS_PATH}/aio-oss/${LOCAL_ARCH}/aio-oss --version	${TOOLS_PATH}/aio-oss/{arch}/aio-oss --version"
    "aio-speed	${TOOLS_PATH}/rpc/${LOCAL_ARCH}/aio-speed --version	${TOOLS_PATH}/rpc/{arch}/aio-speed --version"
    "aio-speedd	${TOOLS_PATH}/rpc/${LOCAL_ARCH}/aio-speedd --version	${TOOLS_PATH}/rpc/{arch}/aio-speedd --version"
    "fs-cli	cd ${TOOLS_PATH}/fs-tools/${LOCAL_ARCH}/fsclient && ./fs-cli -v	cd ${TOOLS_PATH}/fs-tools/{arch}/fsclient && ./fs-cli -v"
    "fsdeamon	cd ${TOOLS_PATH}/fs-tools/${LOCAL_ARCH}/fsdeamon && ./fsdeamon -V 2>&1	cd ${TOOLS_PATH}/fs-tools/{arch}/fsdeamon && ./fsdeamon -V 2>&1"
    "gmssl	${TOOLS_PATH}/gmssl/${LOCAL_ARCH}/gmssl version	${TOOLS_PATH}/gmssl/{arch}/gmssl version"
    "obk_ftp	${TOOLS_PATH}/obk_ftp/${LOCAL_ARCH}/FileTransferAgent --version	${TOOLS_PATH}/obk_ftp/{arch}/FileTransferAgent --version"
    "zfsdeamon	cd ${TOOLS_PATH}/s3-tools/${LOCAL_ARCH}/zfsdeamon && ./zfsdeamon --version	cd ${TOOLS_PATH}/s3-tools/{arch}/zfsdeamon && ./zfsdeamon --version"
    "afs-cli	cd ${TOOLS_PATH}/s3-tools/${LOCAL_ARCH}/afs && ./afs-cli --version 2>&1	cd ${TOOLS_PATH}/s3-tools/{arch}/afs && ./afs-cli --version 2>&1"
    "afsd	cd ${TOOLS_PATH}/s3-tools/${LOCAL_ARCH}/afs && ./afsd --version x 2>&1 | grep -iEv 'usage|endpoint|access-key|secret-key|verify-ssl'	cd ${TOOLS_PATH}/s3-tools/{arch}/afs && ./afsd --version x 2>&1 | grep -iEv 'usage|endpoint|access-key|secret-key|verify-ssl'"
    "s3fs	${TOOLS_PATH}/s3-tools/${LOCAL_ARCH}/s3fs --version 2>&1 | grep -oE 'V[0-9]+\.[0-9]+' | head -1	${TOOLS_PATH}/s3-tools/{arch}/s3fs --version 2>&1 | grep -oE 'V[0-9]+\.[0-9]+' | head -1"
    "s3-tool	cd ${TOOLS_PATH}/s3-tools/${LOCAL_ARCH}/s3-tool && ./s3-tool --version	cd ${TOOLS_PATH}/s3-tools/{arch}/s3-tool && ./s3-tool --version"
    "lsof	/usr/bin/lsof -v 2>&1 | grep -oE 'revision: [0-9]+\.[0-9]+\.[0-9]+' | head -1	/usr/bin/lsof -v 2>&1 | grep -oE 'revision: [0-9]+\.[0-9]+\.[0-9]+' | head -1"
    "rdbcomm	${TOOLS_PATH}/rdbcomm/${LOCAL_ARCH}/rdbcomm --version 2>&1	${TOOLS_PATH}/rdbcomm/{arch}/rdbcomm --version 2>&1"
    "rdbcommd	${TOOLS_PATH}/rdbcomm/${LOCAL_ARCH}/rdbcommd --version 2>&1	${TOOLS_PATH}/rdbcomm/{arch}/rdbcommd --version 2>&1"
    "xtrabackup2.4	/opt/aio/airflow/percona-xtrabackup-2.4.17-Linux-x86_64/bin/xtrabackup --version 2>&1 | grep -oE 'version [0-9]+\.[0-9]+\.[0-9]+' | head -1	/opt/aio/airflow/percona-xtrabackup-2.4.17-Linux-x86_64/bin/xtrabackup --version 2>&1 | grep -oE 'version [0-9]+\.[0-9]+\.[0-9]+' | head -1"
    "xtrabackup8.0	/opt/aio/airflow/percona-xtrabackup-8.0.26-Linux-x86_64/bin/xtrabackup --version 2>&1 | grep -oE 'version [0-9]+\.[0-9]+\.[0-9]+' | head -1	/opt/aio/airflow/percona-xtrabackup-8.0.26-Linux-x86_64/bin/xtrabackup --version 2>&1 | grep -oE 'version [0-9]+\.[0-9]+\.[0-9]+' | head -1"
)

# 从 aio.env 读取配置
read_env() {
    grep -E "^$1=" "${AIO_ENV}" 2>/dev/null | sed "s/^$1=//;s/['\"]//g" | tr -d '[:space:]'
}

# 解密ENC格式的密码
decrypt_enc() {
    local enc_str="$1"
    # 去掉ENC()包装
    enc_str="${enc_str#ENC(}"
    enc_str="${enc_str%)}"
    # 使用CDM的Python3.6解密, CBC模式+零IV
    AIO_ENC_DATA="${enc_str}" /opt/aio/cdm/bin/python3 -c "
import sys, base64, os
sys.path.insert(0, '/opt/aio/cdm/lib/python3.6/site-packages')
from Crypto.Cipher import AES
from Crypto.Util.Padding import unpad
from aio.config.key import AES_KEY_BASE_64
key = base64.b64decode(AES_KEY_BASE_64)
data = base64.b64decode(os.environ['AIO_ENC_DATA'])
decrypted = unpad(AES.new(key, AES.MODE_CBC, IV=b'0000000000000000').decrypt(data), AES.block_size)
sys.stdout.buffer.write(decrypted)
" 2>/dev/null
}

# 读取配置值，自动解密ENC格式
read_env_value() {
    local val
    val=$(read_env "$1")
    # 检测ENC格式并解密
    if [[ "${val}" =~ ^ENC\( ]]; then
        decrypt_enc "${val}"
    else
        echo "${val}"
    fi
}

# 执行一条 SQL, 返回结果(无表头)
run_sql() {
    local db_host="$1" sql="$2"
    local db_user db_pass db_port
    db_user=$(read_env AIO_DB_USERNAME)
    db_pass=$(read_env_value AIO_DB_PASSWORD)
    db_port=$(read_env AIO_DB_PORT)
    db_port=${db_port:-3306}
    "${MYSQL_BIN}" -h "${db_host}" -P "${db_port}" -u "${db_user}" -p"${db_pass}" aio \
        -N -e "${sql}" 2>/dev/null
}

# 查询所有纳管主机, 输出每行: <ip>\t<role>
#   role: rdb=Server / storage=Worker / resource=资源主机
# 兼容两种 schema:
#   新版: rdb_connector 端点表(覆盖 Server+Worker+所有资源主机)
#   旧版: 无 rdb_connector, 回退到 aio_data_nodes(Worker) + 本机(Server)
get_connector_hosts() {
    local db_host="$1"

    # 新版: rdb_connector 是否存在
    local has_conn
    has_conn=$(run_sql "${db_host}" \
        "SELECT COUNT(*) FROM information_schema.tables \
         WHERE table_schema=DATABASE() AND table_name='rdb_connector';")

    if [[ "${has_conn}" == "1" ]]; then
        # 关联 rdb_connector_role 取角色; 同一端点可能多角色, MIN 取其一仅用于打标签
        run_sql "${db_host}" \
            "SELECT c.remote_host, COALESCE(MIN(r.role), 'resource') \
             FROM rdb_connector c \
             LEFT JOIN rdb_connector_role r ON r.connector_id = c.id \
             GROUP BY c.id, c.remote_host;"
        return
    fi

    # 旧版回退: 本机作 Server, aio_data_nodes 里的存储节点作 Worker
    echo -e "${db_host}\trdb"
    run_sql "${db_host}" \
        "SELECT DISTINCT sys_dn_ipaddr, 'storage' \
         FROM aio_data_nodes WHERE sys_dn_is_delete = 0;"
}

# 获取本机单个工具版本
get_local_version() {
    local cmd="$1"
    local ver
    ver=$(eval "${cmd}" 2>&1) || true
    # 清理版本号（去掉前缀文字，只保留数字和点）
    echo "${ver}" | grep -oE '[0-9]+\.[0-9]+\.?[0-9]*\.?[0-9]*' | head -1 || echo "未安装"
}

# 探测 RPC 是否可达(rpc 服务未启动时快速失败, 不空等)
# 返回 0 可达; 非 0 不可达
probe_rpc() {
    local host="$1"
    timeout "${RPC_TIMEOUT}" "${RPC_BIN}" -h "${host}" -p "${RPC_PORT}" -c "echo ok" \
        >/dev/null 2>&1
}

# 获取远程单个工具版本
get_remote_version() {
    local host="$1"
    local cmd="$2"
    local arch="$3"
    local real_cmd="${cmd//\{arch\}/${arch}}"
    local ver
    ver=$(timeout "${RPC_TIMEOUT}" "${RPC_BIN}" -h "${host}" -p "${RPC_PORT}" -c "${real_cmd}" 2>&1) || true
    # 清理版本号（去掉前缀文字，只保留数字和点）
    echo "${ver}" | grep -oE '[0-9]+\.[0-9]+\.?[0-9]*\.?[0-9]*' | head -1 || echo "未安装"
}

# 获取远程 fsbackup 内核模块版本(connector 资源主机专用)
get_remote_fsbackup() {
    local host="$1"
    local ver
    ver=$(timeout "${RPC_TIMEOUT}" "${RPC_BIN}" -h "${host}" -p "${RPC_PORT}" -c "${FSBACKUP_VER_CMD}" 2>&1) || true
    ver=$(echo "${ver}" | grep -oE '[0-9]+\.[0-9]+\.?[0-9]*\.?[0-9]*' | head -1) || true
    # 模块未加载/无此模块时为空, 标记"未安装"
    echo "${ver:-未安装}"
}

# 获取远程主机架构
get_remote_arch() {
    local host="$1"
    timeout "${RPC_TIMEOUT}" "${RPC_BIN}" -h "${host}" -p "${RPC_PORT}" -c "uname -m" 2>/dev/null || echo "unknown"
}

# 主流程
main() {
    local local_ip=""
    local all_ips=()
    local ip_labels=()
    declare -A versions  # versions[ip,tool]=version

    # is_connector[ip]=1 表示该主机需采集 fsbackup(资源主机)
    declare -A is_connector

    # 获取 IP 列表
    if [[ $# -gt 0 ]]; then
        # 手动指定 IP: 一律按 connector 主机处理(采集 fsbackup)
        all_ips=("$@")
        for ip in "${all_ips[@]}"; do
            ip_labels+=("${ip}")
            is_connector["${ip}"]=1
        done
    else
        local_ip=$(read_env AIO_WEBSRV_HOST)
        if [[ -z "${local_ip}" ]]; then
            echo -e "${RED}错误: 无法从 ${AIO_ENV} 读取 AIO_WEBSRV_HOST${NC}"
            exit 1
        fi

        # 从 rdb_connector 取所有纳管主机及角色
        local rows
        rows=$(get_connector_hosts "${local_ip}")
        if [[ -z "${rows}" ]]; then
            echo -e "${RED}错误: 从 rdb_connector 未读取到任何主机${NC}"
            exit 1
        fi

        # 角色 -> 标签前缀; resource 主机需采集 fsbackup
        while IFS=$'\t' read -r ip role || [[ -n "$ip" ]]; do
            [[ -z "${ip}" ]] && continue
            local label
            case "${role}" in
                rdb)     label="Server(${ip})" ;;
                storage) label="Worker(${ip})" ;;
                *)       label="资源(${ip})"; is_connector["${ip}"]=1 ;;
            esac
            all_ips+=("${ip}")
            ip_labels+=("${label}")
        done <<< "${rows}"
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

        # 远程主机先探测 RPC 是否可达; 不可达(rpc 服务未启动)则该主机
        # 所有工具直接标"超时", 不再逐项空等
        if [[ "${is_local}" == false ]] && ! probe_rpc "${ip}"; then
            echo -e "  ${RED}${ip} RPC 不可达(服务未启动?), 跳过${NC}"
            for tool_def in "${TOOL_DEFS[@]}"; do
                IFS=$'\t' read -r name _ _ <<< "${tool_def}"
                versions["${ip},${name}"]="超时"
            done
            [[ -n "${is_connector[${ip}]:-}" ]] && versions["${ip},fsbackup"]="超时"
            continue
        fi

        # 获取架构
        local arch="${LOCAL_ARCH}"
        if [[ "${is_local}" == false ]]; then
            arch=$(get_remote_arch "${ip}")
        fi

        # 收集每个工具版本
        for tool_def in "${TOOL_DEFS[@]}"; do
            IFS=$'\t' read -r name local_cmd remote_cmd <<< "${tool_def}"
            local ver
            if [[ "${is_local}" == true ]]; then
                ver=$(get_local_version "${local_cmd}")
            else
                ver=$(get_remote_version "${ip}" "${remote_cmd}" "${arch}")
            fi
            versions["${ip},${name}"]="${ver}"
        done

        # connector 资源主机额外采集 fsbackup 内核模块版本
        if [[ -n "${is_connector[${ip}]:-}" ]]; then
            if [[ "${is_local}" == true ]]; then
                local fsv
                fsv=$(eval "${FSBACKUP_VER_CMD}" | grep -oE '[0-9]+\.[0-9]+\.?[0-9]*\.?[0-9]*' | head -1) || true
                versions["${ip},fsbackup"]="${fsv:-未安装}"
            else
                versions["${ip},fsbackup"]=$(get_remote_fsbackup "${ip}")
            fi
        fi
    done

    # 行名列表: 所有工具 + fsbackup(内核模块, connector 资源主机专有)
    local row_names=()
    for tool_def in "${TOOL_DEFS[@]}"; do
        IFS=$'\t' read -r name _ _ <<< "${tool_def}"
        row_names+=("${name}")
    done
    row_names+=("fsbackup")

    # 分离 Server/Worker 和 资源主机
    local core_ips=()      # Server + Worker
    local core_labels=()
    local resource_ips=()  # 资源主机
    local resource_labels=()
    for idx in "${!all_ips[@]}"; do
        local lbl="${ip_labels[$idx]}"
        if [[ "${lbl}" == 资源\(* ]]; then
            resource_ips+=("${all_ips[$idx]}")
            resource_labels+=("${lbl}")
        else
            core_ips+=("${all_ips[$idx]}")
            core_labels+=("${lbl}")
        fi
    done

    # 视为"无效/缺失"的占位值
    is_placeholder() {
        case "$1" in
            未安装|超时|N/A|unknown|"") return 0 ;;
            *) return 1 ;;
        esac
    }

    # ===== Server/Worker: 每个 IP 一列 =====
    if [[ ${#core_ips[@]} -gt 0 ]]; then
        echo ""
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}       AIO 工具版本 (Server/Worker)${NC}"
        echo -e "${GREEN}========================================${NC}"

        # 表头
        printf "  ${BOLD}%-16s${NC}" "工具"
        for lbl in "${core_labels[@]}"; do
            printf " ${BOLD}%-20s${NC}" "${lbl}"
        done
        echo ""
        printf "  %-16s" "────────────────"
        for _ in "${core_ips[@]}"; do
            printf " %-20s" "────────────────────"
        done
        echo ""

        for name in "${row_names[@]}"; do
            printf "  %-16s" "${name}"
            for ip in "${core_ips[@]}"; do
                local ver="${versions[${ip},${name}]:-N/A}"
                if is_placeholder "${ver}"; then
                    printf " ${CYAN}%-20s${NC}" "${ver}"
                else
                    printf " %-20s" "${ver}"
                fi
            done
            echo ""
        done
        echo ""
    fi

    # ===== 资源主机: 按工具分组对比 =====
    if [[ ${#resource_ips[@]} -gt 0 ]]; then
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}       AIO 工具版本 (资源主机)${NC}"
        echo -e "${GREEN}  (✓=全部一致  ${YELLOW}!${GREEN}=版本不一致)${NC}"
        echo -e "${GREEN}========================================${NC}"

        local diff_tools=()

        for name in "${row_names[@]}"; do
            local real_vers=()
            local ip
            for ip in "${resource_ips[@]}"; do
                local ver="${versions[${ip},${name}]:-N/A}"
                is_placeholder "${ver}" && continue
                real_vers+=("${ver}")
            done

            local uniq_cnt
            uniq_cnt=$(printf '%s\n' "${real_vers[@]:-}" | grep -v '^$' | sort -u | wc -l) || true

            if [[ "${uniq_cnt}" -le 1 ]]; then
                local shown="${real_vers[0]:-未安装}"
                printf "  ${BOLD}%-16s${NC} ${GREEN}✓${NC} %s\n" "${name}" "${shown}"
            else
                diff_tools+=("${name}")
                printf "  ${BOLD}%-16s${NC} ${YELLOW}!${NC}\n" "${name}"
                local seen_vers=()
                local v
                for ip in "${resource_ips[@]}"; do
                    v="${versions[${ip},${name}]:-N/A}"
                    local found=false
                    local sv
                    for sv in "${seen_vers[@]:-}"; do
                        [[ "${sv}" == "${v}" ]] && found=true && break
                    done
                    [[ "${found}" == false ]] && seen_vers+=("${v}")
                done
                for v in "${seen_vers[@]}"; do
                    local hosts=()
                    for ip in "${resource_ips[@]}"; do
                        [[ "${versions[${ip},${name}]:-N/A}" == "${v}" ]] && hosts+=("${ip}")
                    done
                    if is_placeholder "${v}"; then
                        printf "       ${CYAN}%-12s${NC} %s\n" "${v}" "${hosts[*]}"
                    else
                        printf "       ${YELLOW}%-12s${NC} %s\n" "${v}" "${hosts[*]}"
                    fi
                done
            fi
        done

        echo ""
        if [[ ${#diff_tools[@]} -eq 0 ]]; then
            echo -e "  ${GREEN}所有工具版本一致${NC}"
        else
            echo -e "  ${YELLOW}版本不一致的工具(${#diff_tools[@]}): ${diff_tools[*]}${NC}"
        fi
        echo -e "${GREEN}========================================${NC}"
    fi
}

main "$@"

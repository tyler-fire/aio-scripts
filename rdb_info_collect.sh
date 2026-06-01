#!/bin/bash
# ======================================================
# AIO RDB 多机信息采集脚本（显式命令，函数式解耦，无批处理）
# ======================================================

set -euo pipefail

# === 基本参数 ===
TOOLS_PATH="/opt/aio/airflow/tools"
COLLECT_PATH="/opt/aio/logs/envlogs"

DATE=$(date +%Y%m%d%H%M%S)
LOCAL_IPS=$(hostname -I | xargs)
DEFAULT_PORT="6611"
SKIP_CURRENT=false
ARCH=$(uname -m)
RPC_BIN="${TOOLS_PATH}/rpc/${ARCH}/rpc"

# === 使用帮助 ===
show_help() {
cat << EOF
用法:
  $0 ROLE:IP[,IP2,...] [ROLE:IP[,IP2,...] ...] [PORT]

示例:
  $0 worker:10.6.66.78,10.6.66.79 cdm:10.6.66.77 6611

说明:
  ROLE 支持: cdm, worker, source
  IP 多个用逗号分隔
  PORT 可选，默认 6611
  Ctrl+C 可跳过当前命令继续执行

【脚本说明】
rdb_info_collect.sh 是一个环境信息收集脚本，支持收集RDB/源端/目标端主机环境信息，供工程师或者研发分析异常问题时使用。

【使用说明】
1.  脚本位置：默认rdb_info_collect.sh 放在cdm主机/opt/aio/scripts目录
2.  信息收集存储位置：/opt/aio/logs/envlogs
    1.1.  每台主机存在一个单独目录，目录名组成：host+role+date，单独打包压缩, 例如：10.6.66.66_worker_20251101101112
3.  支持多对多和一对多等方式采集。
EOF
exit 0
}
SKIP_CURRENT=false

handle_interrupt() {
    # SKIP_CURRENT=true
    echo -e "\n[INFO] Ctrl+C 捕获到，即将跳过当前命令..."
    # 恢复默认的 Ctrl+C 处理行为，以便后续命令可以正常响应
    trap - INT
}
# === 工具列表 ===
declare -A TOOL_COMMANDS
TOOL_COMMANDS["kernel_version"]="uname -r"
TOOL_COMMANDS["aio-speed"]="${TOOLS_PATH}/rpc/\$(arch)/aio-speed --version"
TOOL_COMMANDS["aio-speedd"]="${TOOLS_PATH}/rpc/\$(arch)/aio-speedd --version"
TOOL_COMMANDS["fsbackup"]="modinfo --field=version ${TOOLS_PATH}/fs-tools/\$(arch)/kernel/\`uname -r\`/fsbackup.ko"
TOOL_COMMANDS["fs-cli"]="cd ${TOOLS_PATH}/fs-tools/\$(arch)/fsclient && ./fs-cli --version"
TOOL_COMMANDS["fsdeamon"]="cd ${TOOLS_PATH}/fs-tools/\$(arch)/fsdeamon && ./fsdeamon -V 2>&1 | awk '{print \$NF}'"
TOOL_COMMANDS["zfsdeamon"]="cd ${TOOLS_PATH}/s3-tools/\$(arch)/zfsdeamon && ./zfsdeamon --version"
TOOL_COMMANDS["afs-cli"]="cd ${TOOLS_PATH}/s3-tools/\$(arch)/afs && ./afs-cli --version 2>&1 | awk '{print \$NF}'"
TOOL_COMMANDS["afsd"]="cd ${TOOLS_PATH}/s3-tools/\$(arch)/afs && ./afsd --version x 2>&1 | awk '/version:/{print \$1}' | head -1 | cut -d: -f2"

BASE_TOOL_LIST=("kernel_version" "aio-speed" "aio-speedd")
RDB_TOOL_LIST=("${BASE_TOOL_LIST[@]}")
STORAGE_TOOL_LIST=("${BASE_TOOL_LIST[@]}" "fs-cli" "fsdeamon" "afs-cli" "zfsdeamon")
RESOURCE_TOOL_LIST=("${BASE_TOOL_LIST[@]}" "fsbackup" "afsd")

get_tool_list() {
  local role="$1"
  case "$role" in
    cdm) echo "${RDB_TOOL_LIST[@]}" ;;
    worker) echo "${STORAGE_TOOL_LIST[@]}" ;;
    source|mount|convert) echo "${RESOURCE_TOOL_LIST[@]}" ;;
    *) echo "[ERROR] 未知 ROLE: ${role}"; exit 1 ;;
  esac
}

# === 核心执行 ===
run_cmd() {
  local cmd="$1"
  local outfile="$2"
  local use_local="$3"
  local host="$4"
  local port="$5"
  local outdir="$6"
  # echo "[INFO] 执行: ${cmd} -> ${outfile}"
  trap handle_interrupt INT

  if [[ "${use_local}" == "true" ]]; then
    bash -c "${cmd}" > "${outdir}/${outfile}" 2>&1 || true
  else
    "${RPC_BIN}" -h "${host}" -p "${port}" -c "${cmd}" > "${outdir}/${outfile}" 2>&1 || true
  fi
  trap - INT
}

# === 显式块：OS 信息 ===
collect_os_info() {
  run_cmd "hostname" "hostname.txt" "$@"
  echo "执行: hostname 完成"
  run_cmd "ifconfig -a" "ifconfig.txt" "$@"
  echo "执行: ifconfig 完成"
  run_cmd "netstat -in" "netstat-in.txt" "$@"
  echo "执行: netstat 完成"
  run_cmd "uptime" "uptime.txt" "$@"
  echo "执行: uptime 完成"
  run_cmd "dmesg" "dmesg.txt" "$@"
  echo "执行: dmesg 完成"
  run_cmd "tar -zcvf /tmp/messages.tar.gz /var/log/messages* && cat /tmp/messages.tar.gz | base64" "messages.tar.b64" "$@"
  echo "执行: messages 完成"
  run_cmd "ps -ef" "process.txt" "$@"
  echo "执行: ps  完成"
  run_cmd "free -ml" "memory.txt" "$@"
  echo "执行: free 完成"
  run_cmd "df -h" "diskfree.txt" "$@"
  echo "执行: df -h 完成"
  run_cmd "df -k /opt/aio" "diskusage_aio.txt" "$@"
  echo "执行: df -k 完成"
  run_cmd "df -k /opt/aio/logs" "diskusage_aiologs.txt" "$@"
  echo "执行: df -k logs 完成"
}

# === 显式块：服务状态 ===
collect_service_status() {
  local role="$1"; shift
  [[ "${role}" == "cdm" || "${role}" == "worker" ]] && run_cmd "rdb status" "rdb_status.txt" "$@"
  [[ "${role}" == "worker" ]] && run_cmd "systemctl status aio.zfsdaemon.service" "fsdaemon_status.txt" "$@"
  [[ "${role}" == "cdm" ]] && run_cmd "systemctl status mysql" "mysql_status.txt" "$@"
  [[ "${role}" == "cdm" ]] && run_cmd "systemctl status redis" "redis_status.txt" "$@"
  run_cmd "${TOOLS_PATH}/rpc/${ARCH}/aio-speed.sh status" "rpc_status.txt" "$@"
}

# === 显式块：软件版本 ===
collect_software_versions() {
  local role="$1"; shift
  # 先保存 IFS
  local host="$2"
  local port="$3"
  local outdir="$4"
  local IFS_BAK=$IFS
  IFS=' ' read -r -a tool_list <<< "$(get_tool_list "${role}")"
  IFS=$IFS_BAK
  local arch_type=$("${RPC_BIN}" -h "${host}" -p "${port}" -c "uname -m")

  for tool in "${tool_list[@]}"; do
    if [[ -z "${TOOL_COMMANDS[$tool]+isset}" ]]; then
      echo "[ERROR] 工具 ${tool} 未定义!"
      exit 1
    fi
    local cmd_template="${TOOL_COMMANDS[$tool]}"
    # 这里把 \$(arch) 替换成实际架构名
    local cmd="${cmd_template//\$(arch)/${arch_type}}"
    run_cmd "${cmd}" "${tool}.txt" "$@"
    local oneline
    local output_file="${outdir}/tools_version.txt"
    oneline="$(tr '\n' ' ' < "${outdir}/${tool}.txt" | sed 's/[[:space:]]\+/ /g')"
    echo "${tool}: ${oneline}" >> "${output_file}"

    # 清理单文件
    rm -f "${outdir}/${tool}.txt"
    echo "执行: ${tool} 完成"
  done
}

# === 显式块：MySQL导出 ===
collect_mysql_dump() {
  local role="$1"; shift
  local use_local="$1"
  local host="$2"
  local port="$3"
  # 只对 cdm 执行
  if [[ "${role}" == "cdm" ]]; then
    # === 配置文件路径 ===
    local ENV_FILE="/opt/aio/cfg/aio.env"
    local AIO_DB_PASSWORD=""

    if [[ "${use_local}" == "true" ]]; then
      # === 本地读 ===
      if [[ ! -f "${ENV_FILE}" ]]; then
        echo "[ERROR] 本地配置文件不存在: ${ENV_FILE}"
        return 1
      fi
      AIO_DB_PASSWORD=$(grep -E '^AIO_DB_PASSWORD=' "${ENV_FILE}" | sed -E 's/^AIO_DB_PASSWORD=//')
    else
      # === 远程读 ===
      # 用 RPC 远程执行 cat，然后直接捕获结果
      AIO_DB_PASSWORD=$("${RPC_BIN}" -h "${host}" -p "${port}" -c "grep -E '^AIO_DB_PASSWORD=' ${ENV_FILE} | sed -E 's/^AIO_DB_PASSWORD=//'") || true
    fi
    if [[ -z "${AIO_DB_PASSWORD}" ]]; then
      echo "[ERROR] AIO_DB_PASSWORD 未在 ${ENV_FILE} 中找到"
      return 1
    fi

    # === 执行 mysqldump ===
    local CMD=(mysqldump -uroot -p"${AIO_DB_PASSWORD}" --databases aio airflow --single-transaction --quick --lock-tables=false)

    run_cmd "${CMD}" "alldatabases.sql" "$@"
  fi
}


# === 单机执行 ===
run_one_target() {
  local ROLE="$1"
  local HOST="$2"
  local PORT="$3"

  local USE_LOCAL="false"
  IFS=' '  # 显式声明按空格拆分
  if [[ "${ROLE}" == "cdm" ]]; then
    for ip in ${LOCAL_IPS}; do
        if [[ "${HOST}" == "${ip}" ]]; then
        USE_LOCAL="true"
        break
        fi
    done
  fi

  local OUTPUT_DIR="${COLLECT_PATH}/${HOST}_${ROLE}_${DATE}"
  mkdir -p "${OUTPUT_DIR}"


  collect_os_info "${USE_LOCAL}" "${HOST}" "${PORT}" "${OUTPUT_DIR}"
  collect_service_status "${ROLE}" "${USE_LOCAL}" "${HOST}" "${PORT}" "${OUTPUT_DIR}"
  collect_software_versions "${ROLE}" "${USE_LOCAL}" "${HOST}" "${PORT}" "${OUTPUT_DIR}"
  collect_mysql_dump "${ROLE}" "${USE_LOCAL}" "${HOST}" "${PORT}" "${OUTPUT_DIR}"
  local TAR_NAME="${HOST}_${ROLE}_${DATE}.tar.gz"
  (cd "$OUTPUT_DIR/.." && tar -zcf "${TAR_NAME}" "$(basename $OUTPUT_DIR)" && rm -rf $OUTPUT_DIR)

}

# === 主流程 ===
main() {
  [[ $# -lt 1 ]] && show_help
  local PORT="$DEFAULT_PORT"
  local ROLE_HOST_PAIRS=()
  # rm -rf ${COLLECT_PATH}
  for arg in "$@"; do
    if [[ "$arg" =~ ^[0-9]+$ ]]; then
      PORT="$arg"
    elif [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
      show_help
    else
      ROLE_HOST_PAIRS+=("$arg")
    fi
  done


  for pair in "${ROLE_HOST_PAIRS[@]}"; do
    ROLE="${pair%%:*}"
    HOSTS_CSV="${pair#*:}"

    IFS=','
    for HOST in $HOSTS_CSV; do
    if "${RPC_BIN}" -h "${HOST}" -p "${PORT}" -c "echo pong" >/dev/null 2>&1; then
      echo -e "\033[32m开始收集${HOST}主机环境信息\033[0m"
      run_one_target "$ROLE" "$HOST" "$PORT"
      echo -e "\033[34m${HOST}主机环境信息收集完成\033[0m"
    else
      echo -e "\033[31m${HOST}主机连接失败\033[0m"
    fi
    done
  done

  # 3. 输出最终路径
  echo -e "--------------------------------------------------"
  echo -e "\033[32m所有主机信息采集完成！\033[0m"
  echo -e "\033[32m采集下来的文件存放在该路径下: \033[36m${COLLECT_PATH}\033[0m"
  echo -e "--------------------------------------------------"
 
  
}

main "$@"
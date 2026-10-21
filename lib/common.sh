#!/bin/bash
# 版本: 1.0.1
# AIO 运维工具集公共库（shell）
#
# 用法（在各工具脚本开头）:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "$SCRIPT_DIR/lib/common.sh"
#
# 提供能力（此前每个脚本各写一份，行为不一致，现统一到这里）:
#   - aio.env 读取（含引号剥离）        aio_env_get / aio_env_get_secret
#   - ENC() 密码解密                    aio_decrypt_enc
#   - mysql defaults-extra-file 管理    aio_mysql_query / aio_mysql_cleanup
#   - RPC 二进制定位（含架构 fallback） aio_rpc_bin
#   - RPC 远端执行（stdout+stderr 合并）aio_rpc_exec
#   - Worker 发现                       aio_discover_workers
#   - 交互输入（readline + 控制符清理） aio_read / aio_scrub_input
#
# 约定:
#   - 本库不使用 set -e/-u 之外不兼容的写法，可被 set -euo pipefail 的脚本 source。
#   - 所有函数只写 stdout 返回数据，诊断信息写 stderr。

AIO_HOME="${AIO_HOME:-/opt/aio}"
AIO_ENV_FILE="${AIO_ENV_FILE:-$AIO_HOME/cfg/aio.env}"
AIO_RPC_PORT="${RPC_PORT:-6611}"
AIO_RPC_TIMEOUT="${RPC_TIMEOUT:-15}"
AIO_RPC_KILL_AFTER="${RPC_KILL_AFTER:-5}"
AIO_MYSQL_DEFAULTS_FILE="${AIO_MYSQL_DEFAULTS_FILE:-}"

if [[ -x /usr/local/mysql/bin/mysql ]]; then
    AIO_MYSQL_BIN="/usr/local/mysql/bin/mysql"
else
    AIO_MYSQL_BIN="mysql"
fi

# ---------- aio.env 读取 ----------

aio_strip_quotes() {
    local value="$1"
    if [[ ${#value} -ge 2 ]]; then
        if [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]] || \
           [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
            printf '%s\n' "${value:1:${#value}-2}"
            return
        fi
    fi
    printf '%s\n' "$value"
}

# aio_env_get KEY -> 打印 aio.env 中该 KEY 的值（剥引号、去首尾空白），不存在时输出空
aio_env_get() {
    local key="$1"
    local value
    [[ -f "$AIO_ENV_FILE" ]] || return 0
    value=$(awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$AIO_ENV_FILE")
    value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    aio_strip_quotes "$value"
}

# aio_decrypt_enc 'ENC(xxx)' -> 打印明文；解密失败时原样返回
aio_decrypt_enc() {
    local value="$1"
    local enc_data python_bin plain

    if [[ ! "$value" =~ ^ENC\(.*\)$ ]]; then
        printf '%s\n' "$value"
        return
    fi

    enc_data="${value:4:${#value}-5}"
    python_bin="$AIO_HOME/cdm/bin/python3"
    [[ -x "$python_bin" ]] || python_bin="python3"

    plain=$(AIO_ENC_DATA="$enc_data" "$python_bin" -c "
import sys, base64, os
sys.path.insert(0, '$AIO_HOME/cdm/lib/python3.6/site-packages')
from Crypto.Cipher import AES
from Crypto.Util.Padding import unpad
from aio.config.key import AES_KEY_BASE_64
key = base64.b64decode(AES_KEY_BASE_64)
data = base64.b64decode(os.environ['AIO_ENC_DATA'])
plain = unpad(AES.new(key, AES.MODE_CBC, IV=b'0000000000000000').decrypt(data), AES.block_size)
sys.stdout.buffer.write(plain)
" 2>/dev/null) || { printf '%s\n' "$value"; return; }
    printf '%s\n' "$plain"
}

# aio_env_get_secret KEY -> 读取并自动解密 ENC() 值
aio_env_get_secret() {
    local value
    value="$(aio_env_get "$1")"
    aio_decrypt_enc "$value"
}

# ---------- mysql ----------

# 创建（或复用）0600 权限的 defaults-extra-file，路径写入 AIO_MYSQL_DEFAULTS_FILE
aio_mysql_defaults_file() {
    local db_host db_port db_user db_pass

    if [[ -n "$AIO_MYSQL_DEFAULTS_FILE" && -f "$AIO_MYSQL_DEFAULTS_FILE" ]]; then
        printf '%s\n' "$AIO_MYSQL_DEFAULTS_FILE"
        return
    fi

    db_host="$(aio_env_get AIO_DB_HOSTNAME)"
    db_port="$(aio_env_get AIO_DB_PORT)"
    db_user="$(aio_env_get AIO_DB_USERNAME)"
    db_pass="$(aio_env_get_secret AIO_DB_PASSWORD)"
    [[ -n "$db_host" ]] || db_host="127.0.0.1"
    [[ -n "$db_port" ]] || db_port="3306"
    [[ -n "$db_user" ]] || db_user="root"

    AIO_MYSQL_DEFAULTS_FILE="$(mktemp /tmp/aio_mysql.XXXXXX.cnf)"
    chmod 600 "$AIO_MYSQL_DEFAULTS_FILE"
    printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword=%s\n' \
        "$db_host" "$db_port" "$db_user" "$db_pass" > "$AIO_MYSQL_DEFAULTS_FILE"
    printf '%s\n' "$AIO_MYSQL_DEFAULTS_FILE"
}

aio_mysql_cleanup() {
    if [[ -n "$AIO_MYSQL_DEFAULTS_FILE" && -f "$AIO_MYSQL_DEFAULTS_FILE" ]]; then
        rm -f "$AIO_MYSQL_DEFAULTS_FILE"
    fi
    AIO_MYSQL_DEFAULTS_FILE=""
}

# aio_mysql_query SQL [DB] -> 打印 -N -B 结果；失败返回非 0，错误在 stderr（不静默吞掉）
# 注意：本函数经常在 $(...) 子 shell 里被调用，缓存变量传不回父进程，
# 所以临时创建的 defaults 文件在查询后立即删除，避免 /tmp 残留。
# 需要复用时可在父进程先显式调用 aio_mysql_defaults_file。
aio_mysql_query() {
    local sql="$1"
    local db_name="${2:-}"
    local defaults_file created=false rc

    if [[ -z "$AIO_MYSQL_DEFAULTS_FILE" || ! -f "$AIO_MYSQL_DEFAULTS_FILE" ]]; then
        created=true
    fi
    defaults_file="$(aio_mysql_defaults_file)"
    if [[ -z "$db_name" ]]; then
        db_name="$(aio_env_get AIO_DB_NAME)"
        [[ -n "$db_name" ]] || db_name="aio"
    fi
    "$AIO_MYSQL_BIN" --defaults-extra-file="$defaults_file" "$db_name" -N -B -e "$sql"
    rc=$?
    if [[ "$created" == true ]]; then
        rm -f "$defaults_file"
    fi
    return "$rc"
}

# aio_discover_workers -> 每行一个 Worker IP（去重、去空）
aio_discover_workers() {
    aio_mysql_query "SELECT DISTINCT sys_dn_ipaddr FROM aio_data_nodes WHERE sys_dn_is_delete = 0 AND sys_dn_ipaddr IS NOT NULL AND sys_dn_ipaddr <> '' ORDER BY sys_dn_ipaddr;" 2>/dev/null | awk 'NF && !seen[$0]++'
}

# ---------- RPC ----------

# aio_rpc_bin -> 打印 rpc 二进制路径；优先 uname -m 原始值，找不到时 amd64->x86_64、arm64->aarch64
aio_rpc_bin() {
    local raw_arch bin
    raw_arch="$(uname -m)"
    bin="$AIO_HOME/airflow/tools/rpc/$raw_arch/rpc"
    if [[ ! -x "$bin" && "$raw_arch" == "amd64" && -x "$AIO_HOME/airflow/tools/rpc/x86_64/rpc" ]]; then
        bin="$AIO_HOME/airflow/tools/rpc/x86_64/rpc"
    elif [[ ! -x "$bin" && "$raw_arch" == "arm64" && -x "$AIO_HOME/airflow/tools/rpc/aarch64/rpc" ]]; then
        bin="$AIO_HOME/airflow/tools/rpc/aarch64/rpc"
    fi
    printf '%s\n' "$bin"
}

# aio_rpc_exec HOST CMD [TIMEOUT] -> 远端执行，stdout+stderr 合并输出（统一 2>&1，
# 避免各脚本有的收 stderr 有的丢 stderr 导致版本号等信息丢失）
aio_rpc_exec() {
    local host="$1"
    local cmd="$2"
    local run_timeout="${3:-$AIO_RPC_TIMEOUT}"
    local rpc_bin
    rpc_bin="$(aio_rpc_bin)"
    # --foreground 让终端 Ctrl-C 直达 rpc，而不是等到 timeout 到期；
    # --kill-after 兜底处理忽略 SIGTERM 的 rpc 进程。
    timeout --foreground --kill-after="$AIO_RPC_KILL_AFTER" "$run_timeout" \
        "$rpc_bin" -h "$host" -p "$AIO_RPC_PORT" -c "$cmd" 2>&1
}

# ---------- 交互输入 ----------

# 清理输入中的 Backspace/DEL 控制字符（跳板机会把退格原样透传）并去首尾空白
aio_scrub_input() {
    local value="$1"
    local next
    while [[ "$value" == *$'\b'* || "$value" == *$'\177'* ]]; do
        next="$(printf '%s' "$value" | sed $'s/.[\b\177]//g;s/[\b\177]//g')"
        [[ "$next" == "$value" ]] && break
        value="$next"
    done
    printf '%s' "$value" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# aio_read VAR "提示语" -> 启用 readline（-e）读取一行，退格/中文编辑不再乱码，
# 读完再做一次控制符清理，结果存入 VAR
aio_read() {
    local __var="$1"
    local __prompt="$2"
    local __value=""
    if [[ -t 0 ]]; then
        read -rep "$__prompt" __value
    else
        read -rp "$__prompt" __value
    fi
    printf -v "$__var" '%s' "$(aio_scrub_input "$__value")"
}

# 各主机名/IP 的统一校验
aio_valid_host() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

aio_shell_quote() {
    printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

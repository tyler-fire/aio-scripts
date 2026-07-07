#!/bin/bash
# 版本: 1.0.1

if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    fi
    echo "ERROR: bash is required" >&2
    exit 1
fi

set -euo pipefail

AIO_HOME="${AIO_HOME:-/opt/aio}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PS_ROOT="/opt/aio/ps_scripts"
REMOTE_DIR="$PS_ROOT/goldendb"
RPC_PORT="${RPC_PORT:-6611}"
RPC_TIMEOUT="${RPC_TIMEOUT:-30}"
RPC_BIN="${RPC_BIN:-$AIO_HOME/airflow/tools/rpc/$(uname -m)/rpc}"
MYSQL_BIN="/usr/local/mysql/bin/mysql"
LOCAL_TMP_ROOT="$AIO_HOME/user_tmp"
MYSQL_DEFAULTS_FILE=""
CURRENT_UID="$(id -u)"
CURRENT_GID="$(id -g)"

GOLDENDB_FILES=(
    "goldendb_snapshot_list.sh"
    "goldendb_snapshot_clean.sh"
    "goldendb_log_clean.sh"
)

usage() {
    cat <<'EOF'
Usage:
  goldendb_distribute_scripts.sh [options]

Options:
  -w  Worker IP/host list, comma separated. If omitted, query workers from MySQL.
  -a  Distribute to all discovered workers without selection.
  -h  Show this help.

Examples:
  goldendb_distribute_scripts.sh
  goldendb_distribute_scripts.sh -w 10.7.16.217,10.7.16.167
  goldendb_distribute_scripts.sh -a
EOF
}

strip_quotes() {
    local value="$1"
    if [[ ${#value} -ge 2 ]]; then
        if [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]] || [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
            printf '%s\n' "${value:1:${#value}-2}"
            return
        fi
    fi
    printf '%s\n' "$value"
}

read_env_value() {
    local key="$1"
    local file="$AIO_HOME/cfg/aio.env"
    [[ -f "$file" ]] || return 0
    awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$file" | while IFS= read -r value; do
        strip_quotes "$value"
    done
}

decrypt_password() {
    local value="$1"
    if [[ ! "$value" =~ ^ENC\(.*\)$ ]]; then
        printf '%s\n' "$value"
        return
    fi

    local enc_data="${value:4:${#value}-5}"
    local python_bin="$AIO_HOME/cdm/bin/python3"
    [[ -x "$python_bin" ]] || python_bin="python3"

    AIO_ENC_DATA="$enc_data" "$python_bin" -c "
import sys, base64, os
sys.path.insert(0, '$AIO_HOME/cdm/lib/python3.6/site-packages')
from Crypto.Cipher import AES
from Crypto.Util.Padding import unpad
from aio.config.key import AES_KEY_BASE_64
key = base64.b64decode(AES_KEY_BASE_64)
data = base64.b64decode(os.environ['AIO_ENC_DATA'])
plain = unpad(AES.new(key, AES.MODE_CBC, IV=b'0000000000000000').decrypt(data), AES.block_size)
sys.stdout.write(plain.decode('utf-8'))
" 2>/dev/null || printf '%s\n' "$value"
}

validate_host() {
    local host="$1"
    [[ "$host" =~ ^[A-Za-z0-9._-]+$ ]]
}

ensure_local_tmp() {
    mkdir -p "$LOCAL_TMP_ROOT" 2>/dev/null || true
    chmod 700 "$LOCAL_TMP_ROOT" 2>/dev/null || true

    if [[ -d "$LOCAL_TMP_ROOT" && -w "$LOCAL_TMP_ROOT" ]]; then
        return 0
    fi

    if [[ ! -x "$RPC_BIN" ]]; then
        echo "ERROR: cannot write local temp dir and RPC binary is unavailable: $LOCAL_TMP_ROOT" >&2
        return 1
    fi

    local cmd out
    cmd="mkdir -p $(shell_quote "$LOCAL_TMP_ROOT") && chown $(shell_quote "${CURRENT_UID}:${CURRENT_GID}") $(shell_quote "$LOCAL_TMP_ROOT") && chmod 700 $(shell_quote "$LOCAL_TMP_ROOT")"
    set +e
    out="$(timeout "$RPC_TIMEOUT" "$RPC_BIN" -h 127.0.0.1 -p "$RPC_PORT" -c "$cmd" 2>&1)"
    local rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
        echo "ERROR: failed to prepare local temp dir by local RPC: $LOCAL_TMP_ROOT" >&2
        echo "$out" >&2
        return 1
    fi

    if [[ ! -d "$LOCAL_TMP_ROOT" || ! -w "$LOCAL_TMP_ROOT" ]]; then
        echo "ERROR: local temp dir is still not writable after RPC prepare: $LOCAL_TMP_ROOT" >&2
        return 1
    fi
}

cleanup_mysql_defaults_file() {
    if [[ -n "${MYSQL_DEFAULTS_FILE:-}" && -f "$MYSQL_DEFAULTS_FILE" ]]; then
        rm -f "$MYSQL_DEFAULTS_FILE"
    fi
}

create_mysql_defaults_file() {
    ensure_local_tmp
    local db_host db_port db_user db_password
    db_host="$(read_env_value AIO_DB_HOSTNAME)"
    db_port="$(read_env_value AIO_DB_PORT)"
    db_user="$(read_env_value AIO_DB_USERNAME)"
    db_password="$(read_env_value AIO_DB_PASSWORD)"
    db_password="$(decrypt_password "$db_password")"

    [[ -n "$db_host" ]] || db_host="127.0.0.1"
    [[ -n "$db_port" ]] || db_port="3306"
    [[ -n "$db_user" ]] || db_user="root"

    MYSQL_DEFAULTS_FILE="$(mktemp "$LOCAL_TMP_ROOT/aio_mysql.XXXXXX.cnf")"
    chmod 600 "$MYSQL_DEFAULTS_FILE"
    {
        echo "[client]"
        echo "host=$db_host"
        echo "port=$db_port"
        echo "user=$db_user"
        echo "password=$db_password"
    } > "$MYSQL_DEFAULTS_FILE"
}

run_mysql_query() {
    local sql="$1"
    local db_name
    [[ -x "$MYSQL_BIN" ]] || MYSQL_BIN="mysql"
    create_mysql_defaults_file
    db_name="$(read_env_value AIO_DB_NAME)"
    [[ -n "$db_name" ]] || db_name="aio"
    "$MYSQL_BIN" --defaults-extra-file="$MYSQL_DEFAULTS_FILE" "$db_name" -N -B -e "$sql" 2>/dev/null || true
}

discover_workers() {
    run_mysql_query "SELECT DISTINCT sys_dn_ipaddr FROM aio_data_nodes WHERE sys_dn_is_delete = 0 AND sys_dn_ipaddr IS NOT NULL AND sys_dn_ipaddr <> '' ORDER BY sys_dn_ipaddr;"
}

dedupe_lines() {
    awk 'NF && !seen[$0]++'
}

split_hosts() {
    tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | dedupe_lines
}

shell_quote() {
    printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

rpc_cmd() {
    local host="$1"
    local cmd="$2"
    timeout "$RPC_TIMEOUT" "$RPC_BIN" -h "$host" -p "$RPC_PORT" -c "$cmd" 2>&1
}

rpc_upload() {
    local host="$1"
    local local_file="$2"
    local remote_file="$3"
    timeout 120 "$RPC_BIN" -h "$host" -p "$RPC_PORT" --upload 1 --local "$local_file" --remote "$remote_file" 2>&1
}

require_local_files() {
    local file
    for file in "${GOLDENDB_FILES[@]}"; do
        if [[ ! -f "$SCRIPT_DIR/$file" ]]; then
            echo "ERROR: local script not found: $SCRIPT_DIR/$file" >&2
            exit 1
        fi
    done
}

probe_worker() {
    local host="$1"
    local out rc
    set +e
    out="$(rpc_cmd "$host" "echo aio-rpc-ok")"
    rc=$?
    set -e
    if [[ "$rc" -eq 0 && "$out" == *"aio-rpc-ok"* ]]; then
        printf 'OK\t%s\t-\n' "$host"
    else
        printf 'FAIL\t%s\t%s\n' "$host" "$(echo "$out" | tr '\n' ' ' | cut -c1-100)"
    fi
}

choose_workers_interactive() {
    local workers_file="$1"
    local selected
    echo >&2
    echo "Worker list" >&2
    printf "  %-4s %-18s %-8s %s\n" "NO" "WORKER" "STATUS" "MESSAGE" >&2
    awk -F '\t' '{printf "  [%d]  %-18s %-8s %s\n", NR, $2, $1, $3}' "$workers_file" >&2
    echo >&2
    echo "Enter worker numbers separated by comma, or 'all'." >&2
    while true; do
        read -r -p "Select workers: " selected
        selected="$(echo "$selected" | tr -d '[:space:]')"
        [[ -n "$selected" ]] || { echo "ERROR: selection is required" >&2; continue; }
        if [[ "$selected" == "all" || "$selected" == "ALL" ]]; then
            awk -F '\t' '$1 == "OK" {print $2}' "$workers_file"
            return
        fi
        valid=true
        : > "$LOCAL_TMP_ROOT/goldendb_selected_workers.$$"
        IFS=',' read -r -a nums <<< "$selected"
        for num in "${nums[@]}"; do
            if ! [[ "$num" =~ ^[0-9]+$ ]] || (( num < 1 || num > $(wc -l < "$workers_file") )); then
                valid=false
                break
            fi
            if [[ "$(awk -F '\t' -v n="$num" 'NR == n {print $1}' "$workers_file")" != "OK" ]]; then
                echo "ERROR: worker [$num] is not reachable" >&2
                valid=false
                break
            fi
            awk -F '\t' -v n="$num" 'NR == n {print $2}' "$workers_file" >> "$LOCAL_TMP_ROOT/goldendb_selected_workers.$$"
        done
        if [[ "$valid" == true ]]; then
            dedupe_lines < "$LOCAL_TMP_ROOT/goldendb_selected_workers.$$"
            rm -f "$LOCAL_TMP_ROOT/goldendb_selected_workers.$$"
            return
        fi
        rm -f "$LOCAL_TMP_ROOT/goldendb_selected_workers.$$"
        echo "ERROR: invalid selection" >&2
    done
}

collect_target_workers() {
    local explicit_hosts="$1"
    local distribute_all="$2"
    local workers probe_file host

    if [[ -n "$explicit_hosts" ]]; then
        echo "$explicit_hosts" | split_hosts
        return
    fi

    workers="$(discover_workers || true)"
    read -r -p "Extra worker IP/host not in MySQL, comma separated (Enter=none): " manual_workers
    {
        printf '%s\n' "$workers"
        if [[ -n "${manual_workers:-}" ]]; then
            echo "$manual_workers" | split_hosts
        fi
    } | dedupe_lines > "$LOCAL_TMP_ROOT/goldendb_workers.$$"

    if [[ ! -s "$LOCAL_TMP_ROOT/goldendb_workers.$$" ]]; then
        rm -f "$LOCAL_TMP_ROOT/goldendb_workers.$$"
        echo "ERROR: no workers found. Use -w WORKER to specify one." >&2
        exit 1
    fi

    probe_file="$LOCAL_TMP_ROOT/goldendb_worker_probe.$$"
    : > "$probe_file"
    while IFS= read -r host; do
        [[ -n "$host" ]] || continue
        if ! validate_host "$host"; then
            printf 'FAIL\t%s\tinvalid host format\n' "$host" >> "$probe_file"
            continue
        fi
        probe_worker "$host" >> "$probe_file"
    done < "$LOCAL_TMP_ROOT/goldendb_workers.$$"
    rm -f "$LOCAL_TMP_ROOT/goldendb_workers.$$"

    if [[ "$distribute_all" == true ]]; then
        awk -F '\t' '$1 == "OK" {print $2}' "$probe_file"
        rm -f "$probe_file"
        return
    fi

    choose_workers_interactive "$probe_file"
    rm -f "$probe_file"
}

local_hashes() {
    (cd "$SCRIPT_DIR" && sha256sum "${GOLDENDB_FILES[@]}" | awk '{print $1 "  " $2}')
}

distribute_to_worker() {
    local host="$1"
    local file remote_hash local_hash

    if ! validate_host "$host"; then
        echo "[$host] ERROR: invalid host format"
        return 1
    fi

    echo
    echo "[$host] Preparing $REMOTE_DIR ..."
    rpc_cmd "$host" "mkdir -p $(shell_quote "$REMOTE_DIR") && chmod 755 $(shell_quote "$PS_ROOT") 2>/dev/null || true && chmod 755 $(shell_quote "$REMOTE_DIR")" >/dev/null

    for file in "${GOLDENDB_FILES[@]}"; do
        echo "[$host] Uploading $file ..."
        rpc_upload "$host" "$SCRIPT_DIR/$file" "$REMOTE_DIR/$file" >/dev/null
    done

    rpc_cmd "$host" "chmod +x $(shell_quote "$REMOTE_DIR")/*.sh" >/dev/null
    local_hash="$(local_hashes)"
    remote_hash="$(rpc_cmd "$host" "cd $(shell_quote "$REMOTE_DIR") && sha256sum ${GOLDENDB_FILES[*]} 2>/dev/null | awk '{print \$1 \"  \" \$2}'" || true)"
    if [[ "$local_hash" != "$remote_hash" ]]; then
        echo "[$host] ERROR: checksum mismatch"
        echo "Local:"
        echo "$local_hash"
        echo "Remote:"
        echo "$remote_hash"
        return 1
    fi

    echo "[$host] OK: installed to $REMOTE_DIR"
}

EXPLICIT_WORKERS=""
DISTRIBUTE_ALL=false

while getopts "w:ah" opt; do
    case "$opt" in
        w) EXPLICIT_WORKERS="$OPTARG" ;;
        a) DISTRIBUTE_ALL=true ;;
        h)
            usage
            exit 0
            ;;
        \?)
            usage >&2
            exit 1
            ;;
    esac
done

trap cleanup_mysql_defaults_file EXIT

if [[ ! -x "$RPC_BIN" ]]; then
    echo "ERROR: RPC binary not found or not executable: $RPC_BIN" >&2
    exit 1
fi

require_local_files
ensure_local_tmp

mapfile -t TARGETS < <(collect_target_workers "$EXPLICIT_WORKERS" "$DISTRIBUTE_ALL")
if (( ${#TARGETS[@]} == 0 )); then
    echo "ERROR: no reachable workers selected" >&2
    exit 1
fi

echo
echo "GoldenDB script distribution"
echo "Destination: $REMOTE_DIR"
echo "Scripts:"
printf "  %s\n" "${GOLDENDB_FILES[@]}"
echo

failed=0
for host in "${TARGETS[@]}"; do
    if ! distribute_to_worker "$host"; then
        failed=$((failed + 1))
    fi
done

echo
if (( failed > 0 )); then
    echo "Distribution completed with failures: $failed"
    exit 1
fi

echo "Distribution completed successfully."

#!/bin/bash
# 版本: 1.0.2

if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    fi
    echo "ERROR: bash is required" >&2
    exit 1
fi

set -euo pipefail

AIO_HOME="${AIO_HOME:-/opt/aio}"
PATCH_DIR="/opt/aio/ps_scripts/patchfiles"
RPC_PORT="${RPC_PORT:-6611}"
RPC_TIMEOUT="${RPC_TIMEOUT:-30}"
RPC_UPLOAD_TIMEOUT="${RPC_UPLOAD_TIMEOUT:-7200}"
MYSQL_BIN="/usr/local/mysql/bin/mysql"
LOCAL_TMP_ROOT="$AIO_HOME/user_tmp"
MYSQL_DEFAULTS_FILE=""
EXPLICIT_WORKERS=""
PUSH_ALL=false
PATCH_INPUTS=()
CURRENT_UID="$(id -u)"
CURRENT_GID="$(id -g)"

RAW_ARCH="$(uname -m)"
RPC_BIN="${RPC_BIN:-$AIO_HOME/airflow/tools/rpc/$RAW_ARCH/rpc}"
if [[ ! -x "$RPC_BIN" && "$RAW_ARCH" == "amd64" && -x "$AIO_HOME/airflow/tools/rpc/x86_64/rpc" ]]; then
    RPC_BIN="$AIO_HOME/airflow/tools/rpc/x86_64/rpc"
elif [[ ! -x "$RPC_BIN" && "$RAW_ARCH" == "arm64" && -x "$AIO_HOME/airflow/tools/rpc/aarch64/rpc" ]]; then
    RPC_BIN="$AIO_HOME/airflow/tools/rpc/aarch64/rpc"
fi

usage() {
    cat <<'EOF'
Usage:
  aio-file-push.sh [options] [file_or_glob ...]

Options:
  -f  Local file path or glob. Can be specified multiple times.
  -w  Worker IP/host list, comma separated. If omitted, query workers from MySQL.
  -a  Push to all reachable workers without selection.
  -h  Show this help.

Destination:
  /opt/aio/ps_scripts/patchfiles/

Examples:
  aio-file-push.sh
  aio-file-push.sh -f '/opt/aio/user_tmp/*.enc'
  aio-file-push.sh -f /opt/aio/user_tmp/patch.tar.gz -w 10.7.16.217
EOF
}

shell_quote() {
    printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
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

trim_value() {
    local value="$1"
    local next

    # Some jump hosts pass Backspace/DEL through to read instead of editing the line.
    while [[ "$value" == *$'\b'* || "$value" == *$'\177'* ]]; do
        next="$(printf '%s' "$value" | sed $'s/.[\b\177]//g;s/[\b\177]//g')"
        [[ "$next" == "$value" ]] && break
        value="$next"
    done

    printf '%s' "$value" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
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

    local cmd out rc
    cmd="mkdir -p $(shell_quote "$LOCAL_TMP_ROOT") && chown $(shell_quote "${CURRENT_UID}:${CURRENT_GID}") $(shell_quote "$LOCAL_TMP_ROOT") && chmod 700 $(shell_quote "$LOCAL_TMP_ROOT")"
    set +e
    out="$(timeout "$RPC_TIMEOUT" "$RPC_BIN" -h 127.0.0.1 -p "$RPC_PORT" -c "$cmd" 2>&1)"
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
        echo "ERROR: failed to prepare local temp dir by local RPC: $LOCAL_TMP_ROOT" >&2
        echo "$out" >&2
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

validate_host() {
    local host="$1"
    [[ "$host" =~ ^[A-Za-z0-9._-]+$ ]]
}

validate_remote_basename() {
    local name="$1"
    [[ "$name" =~ ^[A-Za-z0-9._@%+=:-]+$ ]]
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
    timeout "$RPC_UPLOAD_TIMEOUT" "$RPC_BIN" -h "$host" -p "$RPC_PORT" --upload 1 --local "$local_file" --remote "$remote_file" 2>&1
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
    local selected valid num
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
        : > "$LOCAL_TMP_ROOT/patch_selected_workers.$$"
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
            awk -F '\t' -v n="$num" 'NR == n {print $2}' "$workers_file" >> "$LOCAL_TMP_ROOT/patch_selected_workers.$$"
        done
        if [[ "$valid" == true ]]; then
            dedupe_lines < "$LOCAL_TMP_ROOT/patch_selected_workers.$$"
            rm -f "$LOCAL_TMP_ROOT/patch_selected_workers.$$"
            return
        fi
        rm -f "$LOCAL_TMP_ROOT/patch_selected_workers.$$"
        echo "ERROR: invalid selection" >&2
    done
}

collect_target_workers() {
    local explicit_hosts="$1"
    local push_all="$2"
    local workers manual_workers probe_file host

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
    } | dedupe_lines > "$LOCAL_TMP_ROOT/patch_workers.$$"

    if [[ ! -s "$LOCAL_TMP_ROOT/patch_workers.$$" ]]; then
        rm -f "$LOCAL_TMP_ROOT/patch_workers.$$"
        echo "ERROR: no workers found. Use -w WORKER to specify one." >&2
        exit 1
    fi

    probe_file="$LOCAL_TMP_ROOT/patch_worker_probe.$$"
    : > "$probe_file"
    while IFS= read -r host; do
        [[ -n "$host" ]] || continue
        if ! validate_host "$host"; then
            printf 'FAIL\t%s\tinvalid host format\n' "$host" >> "$probe_file"
            continue
        fi
        probe_worker "$host" >> "$probe_file"
    done < "$LOCAL_TMP_ROOT/patch_workers.$$"
    rm -f "$LOCAL_TMP_ROOT/patch_workers.$$"

    if [[ "$push_all" == true ]]; then
        awk -F '\t' '$1 == "OK" {print $2}' "$probe_file"
        rm -f "$probe_file"
        return
    fi

    choose_workers_interactive "$probe_file"
    rm -f "$probe_file"
}

absolute_path() {
    local path="$1"
    local dir base
    dir="$(dirname -- "$path")"
    base="$(basename -- "$path")"
    (cd "$dir" 2>/dev/null && printf '%s/%s\n' "$PWD" "$base")
}

resolve_pattern() {
    local pattern="$1"
    local match

    if [[ -f "$pattern" ]]; then
        absolute_path "$pattern"
        return
    fi

    while IFS= read -r match; do
        [[ -f "$match" ]] || continue
        absolute_path "$match"
    done < <(compgen -G "$pattern" | sort)
}

collect_patch_files() {
    local input pattern file
    : > "$LOCAL_TMP_ROOT/patch_files.$$"
    for input in "${PATCH_INPUTS[@]}"; do
        [[ -n "$input" ]] || continue
        while IFS= read -r file; do
            [[ -n "$file" ]] && echo "$file" >> "$LOCAL_TMP_ROOT/patch_files.$$"
        done < <(resolve_pattern "$input")
    done

    if [[ ! -s "$LOCAL_TMP_ROOT/patch_files.$$" ]]; then
        echo "ERROR: no local files matched." >&2
        rm -f "$LOCAL_TMP_ROOT/patch_files.$$"
        exit 1
    fi

    while IFS= read -r file; do
        if [[ ! -f "$file" ]]; then
            echo "ERROR: not a regular file: $file" >&2
            rm -f "$LOCAL_TMP_ROOT/patch_files.$$"
            exit 1
        fi
        if ! validate_remote_basename "$(basename "$file")"; then
            echo "ERROR: unsupported filename for remote upload: $(basename "$file")" >&2
            echo "Allowed characters: letters, digits, dot, underscore, dash, @, %, +, =, colon" >&2
            rm -f "$LOCAL_TMP_ROOT/patch_files.$$"
            exit 1
        fi
    done < "$LOCAL_TMP_ROOT/patch_files.$$"

    dedupe_lines < "$LOCAL_TMP_ROOT/patch_files.$$"
    rm -f "$LOCAL_TMP_ROOT/patch_files.$$"
}

print_local_files() {
    local file size
    printf "  %-4s %-10s %s\n" "NO" "SIZE" "FILE"
    local i=0
    for file in "${PATCH_FILES[@]}"; do
        i=$((i + 1))
        size="$(ls -lh "$file" | awk '{print $5}')"
        printf "  [%d]  %-10s %s\n" "$i" "$size" "$file"
    done
}

prepare_remote_dir() {
    local host="$1"
    rpc_cmd "$host" "mkdir -p $(shell_quote "$PATCH_DIR") && chmod 755 $(shell_quote "$PATCH_DIR")" >/dev/null
}

push_file_to_worker() {
    local host="$1"
    local file="$2"
    local base remote local_sha remote_sha out rc
    base="$(basename "$file")"
    remote="$PATCH_DIR/$base"

    local_sha="$(sha256sum "$file" | awk '{print $1}')"

    set +e
    out="$(rpc_upload "$host" "$file" "$remote")"
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
        printf 'FAIL\t%s\t%s\tupload failed: %s\n' "$host" "$base" "$(echo "$out" | tr '\n' ' ' | cut -c1-120)"
        return 1
    fi

    rpc_cmd "$host" "chmod 644 $(shell_quote "$remote")" >/dev/null || true
    remote_sha="$(rpc_cmd "$host" "sha256sum $(shell_quote "$remote") 2>/dev/null | awk '{print \$1}'" | tail -1 | tr -d '\r')"
    if [[ "$remote_sha" != "$local_sha" ]]; then
        printf 'FAIL\t%s\t%s\tchecksum mismatch local=%s remote=%s\n' "$host" "$base" "$local_sha" "$remote_sha"
        return 1
    fi

    printf 'OK\t%s\t%s\t%s\n' "$host" "$base" "$remote"
}

while getopts "f:w:ah" opt; do
    case "$opt" in
        f) PATCH_INPUTS+=("$OPTARG") ;;
        w) EXPLICIT_WORKERS="$OPTARG" ;;
        a) PUSH_ALL=true ;;
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
shift $((OPTIND - 1))

while [[ $# -gt 0 ]]; do
    PATCH_INPUTS+=("$1")
    shift
done

trap cleanup_mysql_defaults_file EXIT

if [[ ! -x "$RPC_BIN" ]]; then
    echo "ERROR: RPC binary not found or not executable: $RPC_BIN" >&2
    exit 1
fi

ensure_local_tmp

if (( ${#PATCH_INPUTS[@]} == 0 )); then
    read -r -p "Local file path or glob, separated by spaces: " input_line
    read -r -a PATCH_INPUTS <<< "$input_line"
fi

mapfile -t PATCH_FILES < <(collect_patch_files)
if (( ${#PATCH_FILES[@]} == 0 )); then
    echo "ERROR: no local files matched." >&2
    exit 1
fi

mapfile -t TARGETS < <(collect_target_workers "$EXPLICIT_WORKERS" "$PUSH_ALL")
if (( ${#TARGETS[@]} == 0 )); then
    echo "ERROR: no reachable workers selected" >&2
    exit 1
fi

echo
echo "AIO file push"
echo "Destination: $PATCH_DIR"
echo "Overwrite:   yes"
echo "Files:"
print_local_files
echo
echo "Workers:"
printf "  %s\n" "${TARGETS[@]}"
echo
read -r -p "Type yes to upload these files: " confirm
confirm="$(trim_value "$confirm")"
if [[ "$confirm" != "yes" ]]; then
    echo "Cancelled. No files uploaded."
    exit 0
fi

result_file="$LOCAL_TMP_ROOT/patch_push_result.$$"
: > "$result_file"
failed=0

for host in "${TARGETS[@]}"; do
    echo
    echo "[$host] Preparing $PATCH_DIR ..."
    if ! prepare_remote_dir "$host"; then
        echo "[$host] ERROR: failed to prepare remote file directory"
        for file in "${PATCH_FILES[@]}"; do
            printf 'FAIL\t%s\t%s\tprepare remote dir failed\n' "$host" "$(basename "$file")" >> "$result_file"
        done
        failed=$((failed + ${#PATCH_FILES[@]}))
        continue
    fi

    for file in "${PATCH_FILES[@]}"; do
        echo "[$host] Uploading $(basename "$file") ..."
        if ! push_file_to_worker "$host" "$file" >> "$result_file"; then
            failed=$((failed + 1))
        fi
    done
done

echo
echo "File push result"
printf "  %-6s %-18s %-32s %s\n" "STATUS" "WORKER" "FILE" "MESSAGE"
awk -F '\t' '{printf "  %-6s %-18s %-32s %s\n", $1, $2, $3, $4}' "$result_file"
rm -f "$result_file"

echo
if (( failed > 0 )); then
    echo "File push completed with failures: $failed"
    exit 1
fi

echo "File push completed successfully."

#!/bin/bash

if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    fi
    echo "ERROR: bash is required" >&2
    exit 1
fi
if set -o | grep -q '^posix[[:space:]]*on'; then
    exec bash "$0" "$@"
fi

set -euo pipefail

END_DATE=""
PATTERN=""
EXECUTE=false
POOL_NAME="aiopool"

usage() {
    cat <<'EOF'
Usage:
  goldendb_log_clean.sh -e END_DATE [options]

Options:
  -e  Delete log files up to this date, format: YYYY-MM-DD. Required.
      The matched files have mtime earlier than or equal to END_DATE 00:00:00.
  -p  Extra mountpoint pattern, such as 192.168.1.56 or 419.
      The script always processes GoldenDB log and gtmlog files together.
  -x  Execute deletion. Without -x, this script only previews candidates.
  -h  Show this help.

Examples:
  goldendb_log_clean.sh -e 2026-05-07
  goldendb_log_clean.sh -e 2026-05-07 -p 192.168.1.56
  goldendb_log_clean.sh -e 2026-05-07 -x
EOF
}

validate_date() {
    local value="$1"
    if ! [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "ERROR: invalid date '$value', expected YYYY-MM-DD" >&2
        exit 1
    fi

    if [[ "$(date -d "$value" "+%Y-%m-%d" 2>/dev/null || true)" != "$value" ]]; then
        echo "ERROR: invalid calendar date '$value'" >&2
        exit 1
    fi
}

is_future_date() {
    local value="$1"
    local today_epoch
    local value_epoch
    today_epoch=$(date -d "$(date '+%Y-%m-%d') 00:00:00" +%s)
    value_epoch=$(date -d "$value 00:00:00" +%s)
    (( value_epoch > today_epoch ))
}

format_bytes() {
    local bytes="$1"
    awk -v bytes="$bytes" '
        BEGIN {
            split("B K M G T P E", units, " ")
            value = bytes + 0
            unit_index = 1
            while (value >= 1024 && unit_index < 7) {
                value = value / 1024
                unit_index++
            }
            if (unit_index == 1) printf "%.0fB\n", value
            else printf "%.2f%s\n", value, units[unit_index]
        }'
}

highlight() {
    local text="$1"
    if [[ -t 1 ]]; then
        printf '\033[1;32m%s\033[0m\n' "$text"
    else
        printf '%s\n' "$text"
    fi
}

bold() {
    local text="$1"
    if [[ -t 1 ]]; then
        printf '\033[1m%s\033[0m\n' "$text"
    else
        printf '%s\n' "$text"
    fi
}

get_pool_usage() {
    if ! command -v zpool >/dev/null 2>&1; then
        echo "unavailable: zpool command not found"
        return
    fi

    if ! zpool list -H -o size,alloc,free,cap "$POOL_NAME" 2>/dev/null | awk '{printf "size=%s alloc=%s free=%s cap=%s", $1, $2, $3, $4}'; then
        echo "unavailable: failed to read zpool $POOL_NAME"
    fi
}

is_goldendb_log_mountpoint() {
    local mountpoint="$1"
    local base
    local regex='^([0-9]{1,3}\.){3}[0-9]{1,3}_[0-9]+_goldendb_(log|gtmlog)$'

    [[ "$mountpoint" == /volmountpoint/aiopool/* ]] || return 1
    base=$(basename "$mountpoint")
    [[ "$base" =~ $regex ]]
}

match_mountpoint() {
    local mountpoint="$1"

    is_goldendb_log_mountpoint "$mountpoint" || return 1
    [[ "$mountpoint" == /volmountpoint/aiopool/*_goldendb_log || "$mountpoint" == /volmountpoint/aiopool/*_goldendb_gtmlog ]]
}

print_candidates() {
    local dir="$1"

    if [[ "$dir" == *_goldendb_log ]]; then
        find "$dir" -xdev -path "$dir/binlog_*/*" -type f -name 'mysql-bin.*' ! -newermt "$END_DATE" -printf '%s\t%p\n'
    elif [[ "$dir" == *_goldendb_gtmlog ]]; then
        find "$dir" -xdev -path "$dir/active_trans/Active_TX_Archive/*" -type f \
            -name 'DBCluster_*_Active_TX_info.*' ! -name '*.index' ! -newermt "$END_DATE" -printf '%s\t%p\n'
    fi
}

while getopts "e:p:xh" opt; do
    case "$opt" in
        e) END_DATE="$OPTARG" ;;
        p) PATTERN="$OPTARG" ;;
        x) EXECUTE=true ;;
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

if [[ -z "$END_DATE" ]]; then
    usage >&2
    echo "ERROR: -e is required" >&2
    exit 1
fi

validate_date "$END_DATE"

if is_future_date "$END_DATE"; then
    echo "ERROR: future END_DATE is not allowed: $END_DATE" >&2
    exit 1
fi

if ! df_rows=$(df -P); then
    echo "ERROR: failed to list mounted filesystems" >&2
    exit 1
fi

mapfile -t dirs < <(
    awk '$6 ~ /^\/volmountpoint\// {print $6}' <<< "$df_rows" | while IFS= read -r mountpoint; do
        if match_mountpoint "$mountpoint"; then
            if [[ -z "$PATTERN" || "$mountpoint" == *"$PATTERN"* ]]; then
                printf '%s\n' "$mountpoint"
            fi
        fi
    done
)

if (( ${#dirs[@]} == 0 )); then
    echo "No GoldenDB log mountpoints found"
    echo "Pattern: ${PATTERN:-<none>}"
    exit 0
fi

echo
echo "GoldenDB log cleanup"
echo "Range:       <= $END_DATE 00:00:00"
echo "Pattern:     ${PATTERN:-<none>}"
echo "Mode:        $([[ "$EXECUTE" == true ]] && echo execute || echo preview)"
echo

echo "Matched mountpoints:"
for dir in "${dirs[@]}"; do
    echo "  $dir"
done

echo
echo "Counting cleanup candidates up to $END_DATE 00:00:00..."
echo "Scope:"
echo "  *_goldendb_log:    binlog_* / mysql-bin.* only"
echo "  *_goldendb_gtmlog: active_trans/Active_TX_Archive / DBCluster_*_Active_TX_info.* except *.index"
echo

tmp_candidates=$(mktemp "/tmp/goldendb_log_cleanup.XXXXXX")
trap 'rm -f "$tmp_candidates"' EXIT

total_files=0
total_bytes=0
for dir in "${dirs[@]}"; do
    before_count=$(wc -l < "$tmp_candidates")
    before_bytes=$(awk -F '\t' '{sum += $3} END {printf "%.0f\n", sum + 0}' "$tmp_candidates")
    while IFS=$'\t' read -r file_size file_path; do
        printf "%s\t%s\t%s\n" "$dir" "$file_path" "$file_size" >> "$tmp_candidates"
    done < <(print_candidates "$dir")
    after_count=$(wc -l < "$tmp_candidates")
    after_bytes=$(awk -F '\t' '{sum += $3} END {printf "%.0f\n", sum + 0}' "$tmp_candidates")
    file_count=$((after_count - before_count))
    file_bytes=$((after_bytes - before_bytes))
    total_files=$((total_files + file_count))
    total_bytes=$((total_bytes + file_bytes))
    printf "%-80s %10s files %12s\n" "$dir" "$file_count" "$(format_bytes "$file_bytes")"
done

echo
echo "Total matched files: $total_files"
bold "Pool $POOL_NAME: $(get_pool_usage)"
highlight "Estimated reclaim by WILL_DELETE: $(format_bytes "$total_bytes")"

if (( total_files == 0 )); then
    exit 0
fi

if [[ "$EXECUTE" != true ]]; then
    echo
    echo "Preview only. To delete these files, run again with -x."
    exit 0
fi

echo
echo "This will delete $total_files files under the matched GoldenDB log mountpoints."
echo "This operation can make older backup points unrecoverable if END_DATE is wrong."
read -r -p "Type END_DATE ${END_DATE} to continue: " confirm
if [[ "$confirm" != "$END_DATE" ]]; then
    echo "Cancelled"
    exit 1
fi

deleted_count=0
for dir in "${dirs[@]}"; do
    echo "Cleaning: $dir"
    deleted_in_dir=0
    while IFS=$'\t' read -r candidate_dir file_path _file_size; do
        [[ "$candidate_dir" == "$dir" ]] || continue
        if rm -- "$file_path"; then
            deleted_in_dir=$((deleted_in_dir + 1))
        else
            echo "ERROR: failed to delete $file_path" >&2
            exit 1
        fi
    done < "$tmp_candidates"
    deleted_count=$((deleted_count + deleted_in_dir))
    printf "%-80s %10s deleted\n" "$dir" "$deleted_in_dir"
done

echo
echo "Cleanup completed. Deleted files: $deleted_count"

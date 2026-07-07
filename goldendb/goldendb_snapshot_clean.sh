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
RECURSIVE=false
POOL_NAME="aiopool"

usage() {
    cat <<'EOF'
Usage:
  goldendb_snapshot_clean.sh -e END_DATE [options]

Options:
  -e  Delete snapshots up to this date, format: YYYY-MM-DD. Required.
  -p  Extra snapshot name pattern, such as 192.168.1.56 or 419.
      The script always processes GoldenDB data, log, and gtmlog ZFS snapshots together.
  -x  Execute deletion after printing candidates and typing YES.
      Without -x, this script only previews candidates.
  -d  Preview only. Kept for compatibility; same as omitting -x.
  -R  Use "zfs destroy -R" and include snapshots with clones.
      Dangerous: -R can destroy dependent clones, such as mounted copies.
  -h  Show this help.

Examples:
  goldendb_snapshot_clean.sh -e 2026-06-30
  goldendb_snapshot_clean.sh -e 2026-06-30 -p 192.168.1.56
  goldendb_snapshot_clean.sh -e 2026-06-30 -x
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

human_to_bytes() {
    local value="$1"
    awk -v value="$value" '
        BEGIN {
            if (value == "-" || value == "") { print 0; exit }
            number = value
            unit = value
            sub(/[KMGTPE]?$/, "", number)
            sub(/^[0-9.]+/, "", unit)
            multiplier = 1
            if (unit == "K") multiplier = 1024
            else if (unit == "M") multiplier = 1024^2
            else if (unit == "G") multiplier = 1024^3
            else if (unit == "T") multiplier = 1024^4
            else if (unit == "P") multiplier = 1024^5
            else if (unit == "E") multiplier = 1024^6
            printf "%.0f\n", number * multiplier
        }'
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

is_goldendb_snapshot() {
    local snapshot_name="$1"
    local regex='^aiopool/([0-9]{1,3}\.){3}[0-9]{1,3}_[0-9]+_goldendb(_log|_gtmlog)?@([0-9]{10}|[0-9]{13})$'
    [[ "$snapshot_name" =~ $regex ]]
}

while getopts "e:p:xdRh" opt; do
    case "$opt" in
        e) END_DATE="$OPTARG" ;;
        p) PATTERN="$OPTARG" ;;
        x) EXECUTE=true ;;
        d) EXECUTE=false ;;
        R) RECURSIVE=true ;;
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

end_epoch=$(date -d "$END_DATE 23:59:59" +%s)

if ! command -v zfs >/dev/null 2>&1; then
    echo "ERROR: zfs command not found" >&2
    exit 1
fi

tmp_candidates=$(mktemp "/tmp/goldendb_snapshot_destroy.XXXXXX")
trap 'rm -f "$tmp_candidates"' EXIT

if ! snapshot_rows=$(zfs list -H -t snapshot -o name,used,refer); then
    echo "ERROR: failed to list ZFS snapshots" >&2
    exit 1
fi

while IFS=$'\t' read -r snapshot_name used refer; do
    [[ -n "$snapshot_name" ]] || continue

    if ! is_goldendb_snapshot "$snapshot_name"; then
        continue
    fi

    if [[ -n "$PATTERN" && "$snapshot_name" != *"$PATTERN"* ]]; then
        continue
    fi

    sec_ts=""
    if [[ "$snapshot_name" =~ @([0-9]{13})$ ]]; then
        timestamp="${BASH_REMATCH[1]}"
        sec_ts="${timestamp:0:10}"
    elif [[ "$snapshot_name" =~ @([0-9]{10})$ ]]; then
        sec_ts="${BASH_REMATCH[1]}"
    else
        continue
    fi

    snapshot_epoch=$(date -d "@$sec_ts" +%s 2>/dev/null || true)
    if [[ -z "$snapshot_epoch" ]]; then
        continue
    fi

    if (( snapshot_epoch > end_epoch )); then
        continue
    fi

    datetime=$(date -d "@$sec_ts" "+%Y-%m-%d %H:%M")
    if ! clones=$(zfs get -H -o value clones "$snapshot_name"); then
        printf "SKIP_ERROR\t%s\t%s\t%s\t%s\t%s\n" "$snapshot_name" "$used" "$refer" "$datetime" "failed to read clones" >> "$tmp_candidates"
        continue
    fi

    if [[ -z "$clones" || "$clones" == "-" ]]; then
        clones="-"
    fi

    if [[ "$clones" != "-" && "$RECURSIVE" != true ]]; then
        printf "SKIP_CLONE\t%s\t%s\t%s\t%s\t%s\n" "$snapshot_name" "$used" "$refer" "$datetime" "$clones" >> "$tmp_candidates"
        continue
    fi

    used_bytes=$(human_to_bytes "$used")
    printf "DELETE\t%s\t%s\t%s\t%s\t%s\t%s\n" "$snapshot_name" "$used" "$refer" "$datetime" "$clones" "$used_bytes" >> "$tmp_candidates"
done <<< "$snapshot_rows"

delete_count=$(awk -F '\t' '$1 == "DELETE" {count++} END {print count + 0}' "$tmp_candidates")
skip_count=$(awk -F '\t' '$1 == "SKIP_CLONE" {count++} END {print count + 0}' "$tmp_candidates")
error_count=$(awk -F '\t' '$1 == "SKIP_ERROR" {count++} END {print count + 0}' "$tmp_candidates")
reclaim_bytes=$(awk -F '\t' '$1 == "DELETE" {sum += $7} END {printf "%.0f\n", sum + 0}' "$tmp_candidates")
reclaim_human=$(format_bytes "$reclaim_bytes")

echo
echo "GoldenDB snapshot destroy candidates"
echo "Scope:   data, log, and gtmlog ZFS snapshots"
echo "Pattern: ${PATTERN:-<none>}"
echo "Range:   <= $END_DATE 23:59:59"
echo "Mode:    $([[ "$EXECUTE" == true ]] && echo execute || echo preview)"
echo "Delete:  $delete_count"
echo "Skipped snapshots with clones: $skip_count"
echo "Skipped snapshots with errors: $error_count"
bold "Pool $POOL_NAME: $(get_pool_usage)"
highlight "Estimated reclaim by WILL_DELETE: $reclaim_human"
echo

if (( delete_count > 0 )); then
    printf "%-11s %-70s %-10s %-10s %s\n" "ACTION" "SNAPSHOT" "USED" "REFER" "TIME"
    awk -F '\t' '$1 == "DELETE" {printf "%-11s %-70s %-10s %-10s #%s\n", "WILL_DELETE", $2, $3, $4, $5}' "$tmp_candidates"
fi

if (( skip_count > 0 )); then
    echo
    echo "Skipped because these snapshots have clones. Use -R only after confirming the clones can be removed:"
    awk -F '\t' '$1 == "SKIP_CLONE" {printf "%-70s #%s clones=%s\n", $2, $5, $6}' "$tmp_candidates"
fi

if (( error_count > 0 )); then
    echo
    echo "Skipped because clone status could not be verified:"
    awk -F '\t' '$1 == "SKIP_ERROR" {printf "%-70s #%s error=%s\n", $2, $5, $6}' "$tmp_candidates"
fi

if (( delete_count == 0 )); then
    exit 0
fi

if [[ "$EXECUTE" != true ]]; then
    echo
    echo "Preview only. To destroy these snapshots, run again with -x."
    exit 0
fi

echo
echo "The snapshots listed under WILL_DELETE will be destroyed."
echo "This operation can make older backup points unrecoverable if END_DATE is wrong."
read -r -p "Type END_DATE ${END_DATE} to continue: " confirm
if [[ "$confirm" != "$END_DATE" ]]; then
    echo "Cancelled"
    exit 1
fi

if [[ "$RECURSIVE" == true ]]; then
    read -r -p "This uses zfs destroy -R and can delete dependent clones. Type DESTROY_CLONES_YES to continue: " clone_confirm
    if [[ "$clone_confirm" != "DESTROY_CLONES_YES" ]]; then
        echo "Cancelled"
        exit 1
    fi
fi

echo "Start destroying snapshots..."
destroyed_count=0
while IFS=$'\t' read -r action snapshot_name _used _refer datetime _clones _used_bytes; do
    [[ "$action" == "DELETE" ]] || continue
    if [[ "$RECURSIVE" == true ]]; then
        zfs destroy -R "$snapshot_name"
    else
        zfs destroy "$snapshot_name"
    fi
    destroyed_count=$((destroyed_count + 1))
    echo "DESTROYED $snapshot_name #$datetime"
done < "$tmp_candidates"

echo "Snapshot destroy completed. Destroyed snapshots: $destroyed_count"

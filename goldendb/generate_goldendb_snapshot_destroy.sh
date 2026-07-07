#!/bin/bash

set -euo pipefail

START_DATE=""
END_DATE=""
KIND="data"
PATTERN=""
EXECUTE=false
RECURSIVE=false
ALLOW_ALL=false

usage() {
    cat <<'EOF'
Usage:
  generate_goldendb_snapshot_destroy.sh -s START_DATE -e END_DATE [options]

Options:
  -s  Start date, format: YYYY-MM-DD. Required.
  -e  End date, format: YYYY-MM-DD. Required.
  -k  Snapshot kind: data, log, gtmlog, all. Default: data.
      all matches GoldenDB data, log, and gtmlog snapshots and requires -A.
  -p  Extra snapshot name pattern, such as 192.168.1.56 or 419.
  -x  Execute deletion after printing candidates and typing YES.
      Without -x, this script only previews candidates.
  -d  Preview only. Kept for compatibility; same as omitting -x.
  -R  Use "zfs destroy -R" and include snapshots with clones.
      Dangerous: -R can destroy dependent clones, such as mounted copies.
  -A  Allow -k all. Dangerous: this can target all GoldenDB snapshot types.
  -h  Show this help.

Examples:
  generate_goldendb_snapshot_destroy.sh -s 2026-06-01 -e 2026-06-30
  generate_goldendb_snapshot_destroy.sh -s 2026-06-01 -e 2026-06-30 -k log
  generate_goldendb_snapshot_destroy.sh -s 2026-06-01 -e 2026-06-30 -k gtmlog -p 192.168.1.56
  generate_goldendb_snapshot_destroy.sh -s 2026-06-01 -e 2026-06-30 -x
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

is_goldendb_snapshot() {
    local snapshot_name="$1"
    local regex='^aiopool/([0-9]{1,3}\.){3}[0-9]{1,3}_[0-9]+_goldendb(_log|_gtmlog)?@([0-9]{10}|[0-9]{13})$'
    [[ "$snapshot_name" =~ $regex ]]
}

snapshot_kind_matches() {
    local snapshot_name="$1"
    local data_regex='^aiopool/([0-9]{1,3}\.){3}[0-9]{1,3}_[0-9]+_goldendb@'
    local log_regex='^aiopool/([0-9]{1,3}\.){3}[0-9]{1,3}_[0-9]+_goldendb_log@'
    local gtmlog_regex='^aiopool/([0-9]{1,3}\.){3}[0-9]{1,3}_[0-9]+_goldendb_gtmlog@'

    case "$KIND" in
        data) [[ "$snapshot_name" =~ $data_regex ]] ;;
        log) [[ "$snapshot_name" =~ $log_regex ]] ;;
        gtmlog) [[ "$snapshot_name" =~ $gtmlog_regex ]] ;;
        all) is_goldendb_snapshot "$snapshot_name" ;;
        *)
            echo "ERROR: invalid kind '$KIND', expected data, log, gtmlog, or all" >&2
            exit 1
            ;;
    esac
}

while getopts "s:e:k:p:xdRAh" opt; do
    case "$opt" in
        s) START_DATE="$OPTARG" ;;
        e) END_DATE="$OPTARG" ;;
        k) KIND="$OPTARG" ;;
        p) PATTERN="$OPTARG" ;;
        x) EXECUTE=true ;;
        d) EXECUTE=false ;;
        R) RECURSIVE=true ;;
        A) ALLOW_ALL=true ;;
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

if [[ -z "$START_DATE" || -z "$END_DATE" ]]; then
    usage >&2
    echo "ERROR: -s and -e are required" >&2
    exit 1
fi

validate_date "$START_DATE"
validate_date "$END_DATE"

case "$KIND" in
    data|log|gtmlog|all) ;;
    *)
        echo "ERROR: invalid kind '$KIND', expected data, log, gtmlog, or all" >&2
        exit 1
        ;;
esac

if [[ "$KIND" == "all" && "$ALLOW_ALL" != true ]]; then
    echo "ERROR: -k all requires -A because it targets all GoldenDB snapshot types" >&2
    exit 1
fi

start_epoch=$(date -d "$START_DATE 00:00:00" +%s)
end_epoch=$(date -d "$END_DATE 23:59:59" +%s)
if (( start_epoch > end_epoch )); then
    echo "ERROR: START_DATE must not be later than END_DATE" >&2
    exit 1
fi

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

    if ! snapshot_kind_matches "$snapshot_name"; then
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

    if (( snapshot_epoch < start_epoch || snapshot_epoch > end_epoch )); then
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

    printf "DELETE\t%s\t%s\t%s\t%s\t%s\n" "$snapshot_name" "$used" "$refer" "$datetime" "$clones" >> "$tmp_candidates"
done <<< "$snapshot_rows"

delete_count=$(awk -F '\t' '$1 == "DELETE" {count++} END {print count + 0}' "$tmp_candidates")
skip_count=$(awk -F '\t' '$1 == "SKIP_CLONE" {count++} END {print count + 0}' "$tmp_candidates")
error_count=$(awk -F '\t' '$1 == "SKIP_ERROR" {count++} END {print count + 0}' "$tmp_candidates")

echo
echo "GoldenDB snapshot destroy candidates"
echo "Kind:    $KIND"
echo "Pattern: ${PATTERN:-<none>}"
echo "Range:   $START_DATE 00:00:00 to $END_DATE 23:59:59"
echo "Mode:    $([[ "$EXECUTE" == true ]] && echo execute || echo preview)"
echo "Delete:  $delete_count"
echo "Skipped snapshots with clones: $skip_count"
echo "Skipped snapshots with errors: $error_count"
echo

if (( delete_count > 0 )); then
    printf "%-8s %-70s %-10s %-10s %s\n" "ACTION" "SNAPSHOT" "USED" "REFER" "TIME"
    awk -F '\t' '$1 == "DELETE" {printf "%-8s %-70s %-10s %-10s #%s\n", $1, $2, $3, $4, $5}' "$tmp_candidates"
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
echo "The snapshots listed under DELETE will be destroyed."
read -r -p "Type YES to continue: " confirm
if [[ "$confirm" != "YES" ]]; then
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
while IFS=$'\t' read -r action snapshot_name _used _refer datetime _clones; do
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

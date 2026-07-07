#!/bin/bash

set -o pipefail

usage() {
    cat <<'EOF'
Usage:
  goldendb_snapshot_list.sh [pattern]

Examples:
  goldendb_snapshot_list.sh             # show snapshots with "goldendb"
  goldendb_snapshot_list.sh all         # show all snapshots
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if ! command -v zfs >/dev/null 2>&1; then
    echo "ERROR: zfs command not found" >&2
    exit 1
fi

pattern="${1:-goldendb}"
show_all=false
if [[ "$pattern" == "all" || "$pattern" == "*" ]]; then
    show_all=true
fi

printf "%-70s %-10s %-10s %s\n" "SNAPSHOT" "USED" "REFER" "TIME"

if ! snapshot_rows=$(zfs list -H -t snapshot -o name,used,refer); then
    echo "ERROR: failed to list ZFS snapshots" >&2
    exit 1
fi

matched_count=0
tmp_rows=$(mktemp "/tmp/goldendb_snapshot_list.XXXXXX")
trap 'rm -f "$tmp_rows"' EXIT

while IFS=$'\t' read -r snapshot_name used refer; do
    [[ -n "$snapshot_name" ]] || continue

    if [[ "$show_all" != true && "$snapshot_name" != *"$pattern"* ]]; then
        continue
    fi

    sec_ts=""
    if [[ "$snapshot_name" =~ @([0-9]{13})($|[^0-9]) ]]; then
        timestamp="${BASH_REMATCH[1]}"
        sec_ts="${timestamp:0:10}"
    elif [[ "$snapshot_name" =~ @([0-9]{10})($|[^0-9]) ]]; then
        sec_ts="${BASH_REMATCH[1]}"
    fi

    if [[ -n "$sec_ts" ]]; then
        datetime=$(date -d "@$sec_ts" "+%Y-%m-%d %H:%M" 2>/dev/null)
    else
        datetime=""
    fi

    if [[ -z "$datetime" ]]; then
        datetime="-"
    fi

    sort_key="${sec_ts:-9999999999}"
    printf "%s\t%s\t%s\t%s\t%s\n" "$sort_key" "$snapshot_name" "$used" "$refer" "$datetime" >> "$tmp_rows"
    matched_count=$((matched_count + 1))
done <<< "$snapshot_rows"

if (( matched_count == 0 )); then
    echo "No matching snapshots found. Pattern: $pattern"
else
    sort -n -k1,1 -k2,2 "$tmp_rows" | while IFS=$'\t' read -r _ snapshot_name used refer datetime; do
        printf "%-70s %-10s %-10s #%s\n" "$snapshot_name" "$used" "$refer" "$datetime"
    done
    echo "Matched snapshots: $matched_count"
fi

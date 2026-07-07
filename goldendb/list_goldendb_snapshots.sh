#!/bin/bash

set -o pipefail

usage() {
    cat <<'EOF'
Usage:
  list_goldendb_snapshots.sh [pattern]

Examples:
  list_goldendb_snapshots.sh            # show snapshots with "goldendb"
  list_goldendb_snapshots.sh goldendb_log
  list_goldendb_snapshots.sh 192.168.1.56
  list_goldendb_snapshots.sh all        # show all snapshots
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

zfs list -H -t snapshot -o name,used,refer 2>/dev/null | while IFS=$'\t' read -r snapshot_name used refer; do
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

    printf "%-70s %-10s %-10s #%s\n" "$snapshot_name" "$used" "$refer" "$datetime"
done

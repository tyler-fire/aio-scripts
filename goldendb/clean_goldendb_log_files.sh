#!/bin/bash

set -euo pipefail

BEFORE_DATE=""
KIND="all"
PATTERN=""
EXECUTE=false

usage() {
    cat <<'EOF'
Usage:
  clean_goldendb_log_files.sh -b BEFORE_DATE [options]

Options:
  -b  Delete files older than this date, format: YYYY-MM-DD. Required.
      The matched files are strictly earlier than BEFORE_DATE 00:00:00.
  -k  Log kind: all, log, gtmlog. Default: all.
      all    matches *_goldendb_log and *_goldendb_gtmlog
      log    matches *_goldendb_log
      gtmlog matches *_goldendb_gtmlog
  -p  Extra mountpoint pattern, such as 192.168.1.56 or 419.
  -x  Execute deletion. Without -x, this script only previews candidates.
  -h  Show this help.

Examples:
  clean_goldendb_log_files.sh -b 2026-05-07
  clean_goldendb_log_files.sh -b 2026-05-07 -k log
  clean_goldendb_log_files.sh -b 2026-05-07 -k gtmlog -p 192.168.1.56
  clean_goldendb_log_files.sh -b 2026-05-07 -x
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

match_mountpoint() {
    local mountpoint="$1"

    case "$KIND" in
        all)
            [[ "$mountpoint" == /volmountpoint/*_goldendb_log || "$mountpoint" == /volmountpoint/*_goldendb_gtmlog ]]
            ;;
        log)
            [[ "$mountpoint" == /volmountpoint/*_goldendb_log ]]
            ;;
        gtmlog)
            [[ "$mountpoint" == /volmountpoint/*_goldendb_gtmlog ]]
            ;;
        *)
            echo "ERROR: invalid kind '$KIND', expected all, log, or gtmlog" >&2
            exit 1
            ;;
    esac
}

while getopts "b:k:p:xh" opt; do
    case "$opt" in
        b) BEFORE_DATE="$OPTARG" ;;
        k) KIND="$OPTARG" ;;
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

if [[ -z "$BEFORE_DATE" ]]; then
    usage >&2
    echo "ERROR: -b BEFORE_DATE is required" >&2
    exit 1
fi

validate_date "$BEFORE_DATE"

mapfile -t dirs < <(
    df -P | awk '$6 ~ /^\/volmountpoint\// {print $6}' | while IFS= read -r mountpoint; do
        if match_mountpoint "$mountpoint"; then
            if [[ -z "$PATTERN" || "$mountpoint" == *"$PATTERN"* ]]; then
                printf '%s\n' "$mountpoint"
            fi
        fi
    done
)

if (( ${#dirs[@]} == 0 )); then
    echo "No GoldenDB log mountpoints found"
    echo "Kind: $KIND"
    echo "Pattern: ${PATTERN:-<none>}"
    exit 0
fi

echo
echo "GoldenDB log cleanup"
echo "Before date: $BEFORE_DATE 00:00:00"
echo "Kind:        $KIND"
echo "Pattern:     ${PATTERN:-<none>}"
echo "Mode:        $([[ "$EXECUTE" == true ]] && echo execute || echo preview)"
echo

echo "Matched mountpoints:"
for dir in "${dirs[@]}"; do
    echo "  $dir"
done

echo
echo "Counting files older than $BEFORE_DATE..."

total_files=0
for dir in "${dirs[@]}"; do
    file_count=$(find "$dir" -xdev -type f ! -newermt "$BEFORE_DATE" -printf '.' 2>/dev/null | wc -c)
    total_files=$((total_files + file_count))
    printf "%-80s %10s files\n" "$dir" "$file_count"
done

echo
echo "Total matched files: $total_files"

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
read -r -p "Type YES to continue: " confirm
if [[ "$confirm" != "YES" ]]; then
    echo "Cancelled"
    exit 1
fi

deleted_count=0
for dir in "${dirs[@]}"; do
    echo "Cleaning: $dir"
    deleted_in_dir=$(find "$dir" -xdev -type f ! -newermt "$BEFORE_DATE" -print -delete 2>/dev/null | wc -l)
    deleted_count=$((deleted_count + deleted_in_dir))
    printf "%-80s %10s deleted\n" "$dir" "$deleted_in_dir"
done

echo
echo "Cleanup completed. Deleted files: $deleted_count"

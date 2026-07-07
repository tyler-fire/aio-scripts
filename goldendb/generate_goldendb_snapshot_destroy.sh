#!/bin/bash

set -euo pipefail

START_DATE=""
END_DATE=""
PATTERN="goldendb"
DATE_TAG=$(date +"%Y%m%d")
DESTROY_FILE=""
DRY_RUN=false
RECURSIVE=false

usage() {
    cat <<'EOF'
Usage:
  generate_goldendb_snapshot_destroy.sh -s START_DATE -e END_DATE [options]

Options:
  -s  Start date, format: YYYY-MM-DD. Required.
  -e  End date, format: YYYY-MM-DD. Required.
  -p  Snapshot name pattern. Default: goldendb.
      Use "goldendb_log" for log snapshots, "gtmlog" for GTM log snapshots, or "all" for all snapshots.
  -t  Date tag used in output filename. Default: today, format YYYYMMDD.
  -o  Output destroy script path. Default: destroy_goldendb_${DATE_TAG}.sh.
  -d  Dry run. Print candidates only, do not generate a destroy script.
  -R  Generate "zfs destroy -R" commands and include snapshots with clones.
      Dangerous: -R can destroy dependent clones, such as mounted copies.
  -h  Show this help.

Examples:
  generate_goldendb_snapshot_destroy.sh -s 2026-06-01 -e 2026-06-30
  generate_goldendb_snapshot_destroy.sh -s 2026-06-01 -e 2026-06-30 -p goldendb_log
  generate_goldendb_snapshot_destroy.sh -s 2026-06-01 -e 2026-06-30 -d
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

while getopts "s:e:p:t:o:dRh" opt; do
    case "$opt" in
        s) START_DATE="$OPTARG" ;;
        e) END_DATE="$OPTARG" ;;
        p) PATTERN="$OPTARG" ;;
        t) DATE_TAG="$OPTARG" ;;
        o) DESTROY_FILE="$OPTARG" ;;
        d) DRY_RUN=true ;;
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

if [[ -z "$START_DATE" || -z "$END_DATE" ]]; then
    usage >&2
    echo "ERROR: -s and -e are required" >&2
    exit 1
fi

validate_date "$START_DATE"
validate_date "$END_DATE"

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

if [[ -z "$DESTROY_FILE" ]]; then
    DESTROY_FILE="destroy_goldendb_${DATE_TAG}.sh"
fi

tmp_candidates=$(mktemp "/tmp/goldendb_snapshot_destroy.XXXXXX")
trap 'rm -f "$tmp_candidates"' EXIT

show_all=false
if [[ "$PATTERN" == "all" || "$PATTERN" == "*" ]]; then
    show_all=true
fi

while IFS=$'\t' read -r snapshot_name used refer; do
    if [[ "$show_all" != true && "$snapshot_name" != *"$PATTERN"* ]]; then
        continue
    fi

    sec_ts=""
    if [[ "$snapshot_name" =~ @([0-9]{13})($|[^0-9]) ]]; then
        timestamp="${BASH_REMATCH[1]}"
        sec_ts="${timestamp:0:10}"
    elif [[ "$snapshot_name" =~ @([0-9]{10})($|[^0-9]) ]]; then
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
    clones=$(zfs get -H -o value clones "$snapshot_name" 2>/dev/null || echo "-")
    if [[ -z "$clones" || "$clones" == "-" ]]; then
        clones="-"
    fi

    if [[ "$clones" != "-" && "$RECURSIVE" != true ]]; then
        printf "SKIP_CLONE\t%s\t%s\t%s\t%s\t%s\n" "$snapshot_name" "$used" "$refer" "$datetime" "$clones" >> "$tmp_candidates"
        continue
    fi

    printf "DELETE\t%s\t%s\t%s\t%s\t%s\n" "$snapshot_name" "$used" "$refer" "$datetime" "$clones" >> "$tmp_candidates"
done < <(zfs list -H -t snapshot -o name,used,refer)

delete_count=$(awk -F '\t' '$1 == "DELETE" {count++} END {print count + 0}' "$tmp_candidates")
skip_count=$(awk -F '\t' '$1 == "SKIP_CLONE" {count++} END {print count + 0}' "$tmp_candidates")

echo
echo "GoldenDB snapshot destroy candidates"
echo "Pattern: $PATTERN"
echo "Range:   $START_DATE 00:00:00 to $END_DATE 23:59:59"
echo "Delete:  $delete_count"
echo "Skipped snapshots with clones: $skip_count"
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

if [[ "$DRY_RUN" == true ]]; then
    exit 0
fi

{
    echo '#!/bin/bash'
    echo 'set -euo pipefail'
    echo
    echo "# Generated by generate_goldendb_snapshot_destroy.sh"
    echo "# Created at: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# Pattern: $PATTERN"
    echo "# Range: $START_DATE 00:00:00 to $END_DATE 23:59:59"
    echo "# Delete count: $delete_count"
    echo "# Skipped snapshots with clones: $skip_count"
    echo
    echo 'echo "The following GoldenDB snapshots will be destroyed:"'
    awk -F '\t' '$1 == "DELETE" {printf "echo %s\n", shell_quote($2 "  #" $5)} function shell_quote(s) {gsub(/\047/, "\047\\\047\047", s); return "\047" s "\047"}' "$tmp_candidates"
    echo
    echo 'read -r -p "Type YES to continue: " confirm'
    echo 'if [[ "$confirm" != "YES" ]]; then'
    echo '    echo "Cancelled"'
    echo '    exit 1'
    echo 'fi'
    echo
    echo 'echo "Start destroying snapshots..."'
    if [[ "$RECURSIVE" == true ]]; then
        awk -F '\t' '$1 == "DELETE" {printf "zfs destroy -R %s # %s\n", shell_quote($2), $5} function shell_quote(s) {gsub(/\047/, "\047\\\047\047", s); return "\047" s "\047"}' "$tmp_candidates"
    else
        awk -F '\t' '$1 == "DELETE" {printf "zfs destroy %s # %s\n", shell_quote($2), $5} function shell_quote(s) {gsub(/\047/, "\047\\\047\047", s); return "\047" s "\047"}' "$tmp_candidates"
    fi
    echo 'echo "Snapshot destroy completed"'
} > "$DESTROY_FILE"

chmod 700 "$DESTROY_FILE"

echo
echo "Destroy script generated: $DESTROY_FILE"
echo "Review it first, then run:"
echo "  bash $DESTROY_FILE"

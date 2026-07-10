#!/bin/bash
# 版本: 1.1.1
# 主机 hang / 断连 / 重启后的边界化日志收集工具

set -u

MAX_WINDOW_LINES="${MAX_WINDOW_LINES:-20000}"
MAX_JOURNAL_LINES="${MAX_JOURNAL_LINES:-20000}"
HOSTNAME_SHORT=$(hostname 2>/dev/null || echo unknown)
RUN_TS=$(date +%Y%m%d_%H%M%S)
RUN_ID="${RUN_TS}_$$"
BASE_DIR="/tmp/hang_collect_${HOSTNAME_SHORT}_${RUN_ID}"
COLLECT_DIR="${BASE_DIR}/hang_collect"
START_TIME=""
END_TIME=""
INCLUDE_AIO_LOGS=""
ARCHIVE_FILE=""

cleanup_on_exit() {
    local rc=$?

    if [ "$rc" -ne 0 ]; then
        rm -rf "$BASE_DIR"
        [ -n "$ARCHIVE_FILE" ] && rm -f "$ARCHIVE_FILE"
    fi
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT TERM

say() {
    echo "$@"
}

run_save() {
    local output="$1"
    shift
    "$@" > "$output" 2>&1
}

date_to_epoch() {
    date -d "$1" +%s 2>/dev/null
}

normalize_time() {
    local input="$1"
    date -d "$input" "+%Y-%m-%d %H:%M:%S" 2>/dev/null
}

show_usage() {
    cat << EOF
用法:
  bash aio-collect-hang-logs.sh
  bash aio-collect-hang-logs.sh --start "2026-07-06 18:00:00" --end "2026-07-06 18:40:00" [--include-aio]

说明:
  不带参数时进入交互模式。
  --include-aio 表示附加收集 AIO 服务日志；默认不收。
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --start)
                [ "$#" -ge 2 ] || { say "[ERROR] --start 缺少时间"; exit 1; }
                START_TIME="$2"
                shift 2
                ;;
            --end)
                [ "$#" -ge 2 ] || { say "[ERROR] --end 缺少时间"; exit 1; }
                END_TIME="$2"
                shift 2
                ;;
            --include-aio)
                INCLUDE_AIO_LOGS=1
                shift
                ;;
            --no-include-aio)
                INCLUDE_AIO_LOGS=0
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                say "[ERROR] 未知参数: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

prompt_time_range() {
    local default_start
    local default_end
    local interactive=0

    default_end=$(date "+%Y-%m-%d %H:%M:%S")
    default_start=$(date -d "2 hours ago" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "")

    say ""
    say "========================================"
    say " 主机异常日志收集"
    say "========================================"
    say "用于分析主机 hang、断连、异常重启、文件系统检查失败等问题。"
    say "请输入本次收集日志从几号几点到几号几点。"
    say "格式示例：2026-07-06 17:30:00"
    say ""

    if [ -z "$START_TIME" ] || [ -z "$END_TIME" ]; then
        interactive=1
    fi

    if [ "$interactive" -eq 1 ]; then
        while true; do
            read -rp "从几号几点开始 [默认: ${default_start}]: " START_TIME
            START_TIME=${START_TIME:-$default_start}
            START_TIME=$(normalize_time "$START_TIME" || true)
            if [ -n "$START_TIME" ]; then
                break
            fi
            say "[ERROR] 开始时间格式不正确"
        done

        while true; do
            read -rp "到几号几点结束 [默认: ${default_end}]: " END_TIME
            END_TIME=${END_TIME:-$default_end}
            END_TIME=$(normalize_time "$END_TIME" || true)
            if [ -n "$END_TIME" ]; then
                break
            fi
            say "[ERROR] 结束时间格式不正确"
        done
    else
        START_TIME=$(normalize_time "$START_TIME" || true)
        END_TIME=$(normalize_time "$END_TIME" || true)
        if [ -z "$START_TIME" ] || [ -z "$END_TIME" ]; then
            say "[ERROR] 时间格式不正确"
            exit 1
        fi
    fi

    START_EPOCH=$(date_to_epoch "$START_TIME")
    END_EPOCH=$(date_to_epoch "$END_TIME")
    if [ "$START_EPOCH" -ge "$END_EPOCH" ]; then
        say "[ERROR] 开始时间必须早于结束时间"
        exit 1
    fi

    EXPANDED_START=$(date -d "$START_TIME 2 hours ago" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$START_TIME")

    say ""
    say "收集窗口: $START_TIME 到 $END_TIME"
    say "输出目录: $COLLECT_DIR"
    say ""

    if [ -z "$INCLUDE_AIO_LOGS" ]; then
        read -rp "是否附加收集 AIO 服务日志? [y/N]: " INCLUDE_AIO_LOGS
        case "$INCLUDE_AIO_LOGS" in
            y|Y|yes|YES)
                INCLUDE_AIO_LOGS=1
                ;;
            *)
                INCLUDE_AIO_LOGS=0
                ;;
        esac
    fi
    say ""
}

prepare_dirs() {
    mkdir -p "$COLLECT_DIR"/{system,aio,sa,commands}
}

collect_basic_info() {
    say "▸ 收集基础状态..."
    run_save "$COLLECT_DIR/commands/hostname.txt" hostname
    run_save "$COLLECT_DIR/commands/date.txt" date
    run_save "$COLLECT_DIR/commands/uptime.txt" uptime
    run_save "$COLLECT_DIR/commands/who_boot.txt" who -b
    run_save "$COLLECT_DIR/commands/last_x.txt" sh -c "last -x | head -300"
    run_save "$COLLECT_DIR/commands/systemctl_failed.txt" systemctl --failed
    run_save "$COLLECT_DIR/commands/dmesg_T_tail.txt" sh -c "dmesg -T | tail -4000"
    run_save "$COLLECT_DIR/commands/lsblk_f.txt" lsblk -f
    run_save "$COLLECT_DIR/commands/blkid.txt" blkid
    run_save "$COLLECT_DIR/commands/findmnt.txt" findmnt
    run_save "$COLLECT_DIR/commands/df_hT.txt" df -hT
    run_save "$COLLECT_DIR/commands/pvs.txt" pvs
    run_save "$COLLECT_DIR/commands/vgs.txt" vgs
    run_save "$COLLECT_DIR/commands/lvs.txt" lvs -a -o +devices
    run_save "$COLLECT_DIR/commands/ip_addr.txt" ip addr
    run_save "$COLLECT_DIR/commands/ip_route.txt" ip route
    run_save "$COLLECT_DIR/commands/ip_link.txt" ip link
}

collect_journal() {
    if ! command -v journalctl >/dev/null 2>&1; then
        return
    fi

    say "▸ 收集 journal 时间窗口..."
    run_save "$COLLECT_DIR/system/journal_boots.txt" journalctl --list-boots
    run_save "$COLLECT_DIR/system/journal_window.txt" sh -c "journalctl --since '$START_TIME' --until '$END_TIME' | head -n '$MAX_JOURNAL_LINES'"
    run_save "$COLLECT_DIR/system/journal_kernel_window.txt" sh -c "journalctl -k --since '$START_TIME' --until '$END_TIME' | head -n '$MAX_JOURNAL_LINES'"
    run_save "$COLLECT_DIR/system/journal_current_boot_tail.txt" sh -c "journalctl -b | tail -5000"
    run_save "$COLLECT_DIR/system/journal_previous_boot_tail.txt" sh -c "journalctl -b -1 | tail -5000"
}

extract_syslog_window() {
    local src="$1"
    local dst="$2"
    local start_year
    local end_year
    local start_month

    start_year=$(date -d "$START_TIME" +%Y 2>/dev/null || date +%Y)
    end_year=$(date -d "$END_TIME" +%Y 2>/dev/null || date +%Y)
    start_month=$(date -d "$START_TIME" +%-m 2>/dev/null || date +%-m)
    awk -v s="$START_EPOCH" -v e="$END_EPOCH" -v sy="$start_year" -v ey="$end_year" -v sm="$start_month" -v max="$MAX_WINDOW_LINES" '
        BEGIN {
            mon["Jan"]=1; mon["Feb"]=2; mon["Mar"]=3; mon["Apr"]=4;
            mon["May"]=5; mon["Jun"]=6; mon["Jul"]=7; mon["Aug"]=8;
            mon["Sep"]=9; mon["Oct"]=10; mon["Nov"]=11; mon["Dec"]=12;
            in_window=0;
            out_count=0;
        }
        {
            if (match($0, /^([A-Z][a-z][a-z])[ ]+([0-9]+) ([0-9][0-9]):([0-9][0-9]):([0-9][0-9])/, m)) {
                y=sy;
                if (sy != ey && mon[m[1]] < sm) y=ey;
                ts=mktime(y " " mon[m[1]] " " m[2] " " m[3] " " m[4] " " m[5]);
                in_window=(ts >= s && ts <= e);
            } else if (match($0, /([0-9]{4})-([0-9]{2})-([0-9]{2})[ T]([0-9]{2}):([0-9]{2}):([0-9]{2})/, m)) {
                ts=mktime(m[1] " " m[2] " " m[3] " " m[4] " " m[5] " " m[6]);
                in_window=(ts >= s && ts <= e);
            } else if (match($0, /[A-Z][a-z][a-z] ([A-Z][a-z][a-z])[ ]+([0-9]+) ([0-9][0-9]):([0-9][0-9]):([0-9][0-9]) ([0-9]{4})/, m)) {
                ts=mktime(m[6] " " mon[m[1]] " " m[2] " " m[3] " " m[4] " " m[5]);
                in_window=(ts >= s && ts <= e);
            }
            if (in_window) {
                out_count++;
                if (out_count <= max) {
                    print;
                } else {
                    print "[TRUNCATED] hit per-file window line limit: " max;
                    exit;
                }
            }
        }
    ' "$src" > "$dst" 2>/dev/null
}

keep_nonempty_or_remove() {
    local file="$1"

    if [ ! -s "$file" ]; then
        rm -f "$file"
    fi
}

collect_flat_system_logs() {
    local base
    local dst

    say "▸ 收集 /var/log 关键日志..."
    for f in /var/log/messages /var/log/messages-* /var/log/secure /var/log/secure-* /var/log/boot.log /var/log/boot.log-* /var/log/kern.log /var/log/kern.log-* /var/log/syslog /var/log/syslog-* /var/log/auth.log /var/log/auth.log-*; do
        [ -f "$f" ] || continue
        base=$(basename "$f")

        case "$f" in
            *.gz)
                dst="$COLLECT_DIR/system/${base}.window"
                extract_syslog_window <(gzip -dc "$f" 2>/dev/null) "$dst"
                keep_nonempty_or_remove "$dst"
                ;;
            *)
                dst="$COLLECT_DIR/system/${base}.window"
                extract_syslog_window "$f" "$dst"
                keep_nonempty_or_remove "$dst"
                ;;
        esac
    done
}

collect_sar() {
    local start_day
    local end_day
    local day
    local sa_file
    local out_file

    [ -d /var/log/sa ] || return
    command -v sar >/dev/null 2>&1 || return

    say "▸ 收集 sar 性能窗口..."
    start_day=$(date -d "$START_TIME" +%Y-%m-%d)
    end_day=$(date -d "$END_TIME" +%Y-%m-%d)
    day="$start_day"

    while true; do
        sa_file="/var/log/sa/sa$(date -d "$day" +%d)"
        if [ -f "$sa_file" ]; then
            cp -a "$sa_file" "$COLLECT_DIR/sa/"
            out_file="$COLLECT_DIR/sa/sar_$(date -d "$day" +%Y%m%d).txt"
            if [ "$day" = "$start_day" ] && [ "$day" = "$end_day" ]; then
                sar -A -f "$sa_file" -s "$(date -d "$START_TIME" +%H:%M:%S)" -e "$(date -d "$END_TIME" +%H:%M:%S)" > "$out_file" 2>&1
            elif [ "$day" = "$start_day" ]; then
                sar -A -f "$sa_file" -s "$(date -d "$START_TIME" +%H:%M:%S)" > "$out_file" 2>&1
            elif [ "$day" = "$end_day" ]; then
                sar -A -f "$sa_file" -e "$(date -d "$END_TIME" +%H:%M:%S)" > "$out_file" 2>&1
            else
                sar -A -f "$sa_file" > "$out_file" 2>&1
            fi
        fi

        [ "$day" = "$end_day" ] && break
        day=$(date -d "$day +1 day" +%Y-%m-%d)
    done
}

copy_aio_log() {
    local src="$1"
    local rel
    local dst

    rel=${src#/opt/aio/}
    dst="$COLLECT_DIR/aio/${rel}.window"
    mkdir -p "$(dirname "$dst")"

    case "$src" in
        *.gz)
            extract_syslog_window <(gzip -dc "$src" 2>/dev/null) "$dst"
            ;;
        *)
            extract_syslog_window "$src" "$dst"
            ;;
    esac
    keep_nonempty_or_remove "$dst"
}

collect_aio_logs() {
    [ -d /opt/aio/logs/service ] || return

    say "▸ 收集 AIO 服务日志..."
    mkdir -p "$COLLECT_DIR/aio"
    if [ -f /opt/aio/airflow/scripts/rdb.py ]; then
        python3 /opt/aio/airflow/scripts/rdb.py status > "$COLLECT_DIR/aio/rdb_status.txt" 2>&1
    fi

    find /opt/aio/logs/service -type f \
        \( -name "*.log" -o -name "*.out" -o -name "*.err" -o -name "*.log.*" -o -name "*.gz" \) \
        -newermt "$EXPANDED_START" \
        -print 2>/dev/null | while read -r f; do
            copy_aio_log "$f"
        done
}

sanitize_text_file() {
    local file="$1"

    [ -f "$file" ] || return
    sed -E -i \
        -e 's#(://[^:/@[:space:]]+):([^@/[:space:]]+)@#\1:***REDACTED***@#g' \
        -e 's#((password|passwd|pwd|token|secret|authorization|access[_-]?key|secret[_-]?key|sys_dn_os_passwd|sys_dn_os_password|AIO_DB_PASSWORD)[^[:alnum:]_]{0,20}[=: ]+)[^,'"'"'\"[:space:],;}]+#\1***REDACTED***#Ig' \
        -e 's#((password|passwd|pwd|token|secret|authorization|access[_-]?key|secret[_-]?key|sys_dn_os_passwd|sys_dn_os_password|AIO_DB_PASSWORD)[^[:alnum:]_]{0,20}[\"'\'']:[[:space:]]*[\"'\''])[^\"'\'']*#\1***REDACTED***#Ig' \
        "$file" 2>/dev/null || true
}

sanitize_outputs() {
    say "▸ 脱敏文本日志..."
    find "$COLLECT_DIR" -type f \
        \( -name "*.txt" -o -name "*.window" -o -name "rdb_status.txt" \) \
        -print 2>/dev/null | while read -r f; do
            sanitize_text_file "$f"
        done
}

write_manifest() {
    cat > "$COLLECT_DIR/README.txt" << EOF
主机异常日志收集包

主机: $HOSTNAME_SHORT
收集时间: $(date "+%Y-%m-%d %H:%M:%S")
故障窗口: $START_TIME 到 $END_TIME

目录说明:
- commands/: 基础命令输出，如启动时间、磁盘、网络、LVM、失败服务。
- system/: journal 和 /var/log 关键系统日志。
- sa/: sar 性能数据和窗口化文本输出。
- aio/: AIO 服务状态和时间窗口内的服务日志；只有选择附加收集时才会生成。

边界:
- /var/log/messages、secure、boot.log、kern.log 只保留故障窗口内的日志行；没有命中的文件不放进包。
- journal 当前启动和上一启动只保留尾部 5000 行，另有按故障窗口提取的 journal 文件。
- AIO 服务日志只保留故障窗口内的日志行；没有命中的文件不放进包。
- 文本日志会对 password、token、secret、authorization、access key 等常见敏感字段做基础脱敏。
- 单个窗口日志最多保留 ${MAX_WINDOW_LINES} 行，journal 时间窗口最多保留 ${MAX_JOURNAL_LINES} 行。
- 不收集 cfg/aio.env 等可能包含密码的配置文件。
- 不全量收集 /opt/aio/logs/task；任务日志应按任务 ID 单独收集。
EOF
}

make_archive() {
    local archive

    archive="${BASE_DIR}.tar.gz"
    ARCHIVE_FILE="$archive"
    if ! tar -czf "$archive" -C "$BASE_DIR" hang_collect; then
        say "[ERROR] 打包失败: $archive"
        exit 1
    fi
    if [ ! -s "$archive" ] || ! tar -tzf "$archive" >/dev/null 2>&1; then
        say "[ERROR] 归档校验失败: $archive"
        exit 1
    fi
    rm -rf "$BASE_DIR"
    say ""
    say "========================================"
    say " 收集完成"
    say "========================================"
    ls -lh "$archive"
    say ""
    say "ARCHIVE_PATH=$archive"
    say "把这个包交给分析人员即可: $archive"
}

main() {
    parse_args "$@"
    prompt_time_range
    prepare_dirs
    collect_basic_info
    collect_journal
    collect_flat_system_logs
    collect_sar
    if [ "$INCLUDE_AIO_LOGS" -eq 1 ]; then
        collect_aio_logs
    else
        rmdir "$COLLECT_DIR/aio" 2>/dev/null || true
        say "▸ 跳过 AIO 服务日志。"
    fi
    write_manifest
    sanitize_outputs
    make_archive
}

main "$@"

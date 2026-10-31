#!/bin/bash
# 版本: 1.7.2
# v1.7.2: 术语统一为“失效记录”
# v1.7.1: 进程数与 2+数据源数不一致时给出具体差值，并要求确认后才允许继续
# v1.7.0: 按备份计划清理：多监控目录使用 del-trackup，单目录/整源使用 del-source；显示进程数和启动时间；提示源端核对
# v1.6.3: 失效记录残留不再显示“完成/重启会清掉”，明确由 fsdeamon 内部维护，本工具不重启 daemon
# v1.6.2: 失效记录清理优先使用 source-name + 原地址，实测仅 UUID 可能返回 true 但不移除记录
# v1.6.1: 活动源删除同时传 source-name/source；失效 child 与失效记录走 source-name；按异步状态两阶段清理
# v1.6.0: 区分活动源与 Offline 失效记录；删除后不再把失效记录误报为失败；清理前检测重复 fsdeamon 实例
# v1.5.1: 交互输入启用 readline（read -e），退格/中文编辑不再乱码；RPC 路径走公共库
#
# fsdeamon 监控数据源清理工具
#
# 用法：
#   ./aio-fsdeamon-cleanup.sh [WORKER_IP]
#
#   不带参数: 连接本地 fsdeamon (127.0.0.1)
#   带 IP 参数: 通过目标 Worker 的 RPC(6611) 在 Worker 本机调用 fs-cli 访问 127.0.0.1:8901
#
# 作用：
#   交互式列出 fsdeamon 管理的所有在线/离线数据源，允许用户按序号/范围/全部
#   选择要清理的数据源。一个数据源有多个监控目录时，按目录使用 del-trackup；
#   只有一个监控目录或用户选择删除整个数据源时，使用 del-source。
#   Offline 且没有 host/port 的记录是失效记录，不是活动数据源；残留情况单独提示。
#
# 依赖的命令：
#   rpc             — 脚本放在 server 上清理 worker 时，通过 rpc 到 worker 本机执行 fs-cli
#   fs-cli          — fsdeamon 命令行客户端，通过 --method 参数调用不同接口：
#                     list-source  : 查询所有数据源列表
#                     list         : 查询指定数据源的监控目录
#                     del-source   : 删除数据源
#   python3         — 解析 fs-cli 返回的 JSON 数据
#
# 注意：
#   del-source 仅删除 worker 侧记录，不会自动清理源端残留文件：
#     /etc/fsbackup/_<目录替换>_.conf
#     /var/fsbackup/_<目录替换>_/
#   以及源端 /var/fsbackup/ 下的工具文件，需手工清理。
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
    # shellcheck source=lib/common.sh
    source "$SCRIPT_DIR/lib/common.sh"
    RPC="$(aio_rpc_bin)"
else
    RPC="/opt/aio/airflow/tools/rpc/$(uname -m)/rpc"
fi

ARCH=$(uname -m)
FS_CLI="${AIO_FS_CLI:-/opt/aio/airflow/tools/fs-tools/$ARCH/fsclient/fs-cli}"
FS_CLI_DIR=$(dirname "$FS_CLI")
PORT="8901"
RPC_PORT="6611"

# 解析参数
if [ -n "$1" ]; then
    HOST="$1"
else
    HOST="127.0.0.1"
fi

export LD_LIBRARY_PATH="$FS_CLI_DIR/lib_x86_64:$LD_LIBRARY_PATH"

# 前置检查
if ! command -v python3 &>/dev/null; then
    echo "错误: 需要 python3，但未找到"
    exit 1
fi

USE_RPC="false"
if [ "$HOST" != "127.0.0.1" ] && [ "$HOST" != "localhost" ]; then
    USE_RPC="true"
fi

if [ "$USE_RPC" = "true" ]; then
    if [ ! -x "$RPC" ]; then
        echo "错误: $RPC 不存在或没有执行权限"
        exit 1
    fi
else
    if [ ! -x "$FS_CLI" ]; then
        echo "错误: $FS_CLI 不存在或没有执行权限"
        exit 1
    fi
fi

# shell 参数安全引用，用于拼接远端 rpc 命令
shell_quote() {
    local s="$1"
    printf "'%s'" "${s//\'/\'\\\'\'}"
}

# 在目标 Worker 本机执行普通 shell 命令（本地模式直接执行，远端模式走 RPC）
host_shell_call() {
    local cmd="$1"
    if [ "$USE_RPC" = "true" ]; then
        "$RPC" -h "$HOST" -p "$RPC_PORT" -c "$cmd" 2>&1
    else
        bash -c "$cmd" 2>&1
    fi
}

# 从 list-source 返回中判断一个 UUID 的当前状态。
# 输出：online / offline / stale / absent / unknown
source_state_from_json() {
    local uuid="$1"
    local payload="$2"
    printf '%s' "$payload" | python3 -c '
import json, sys

uuid = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    print("unknown")
    raise SystemExit(0)

for item in data.get("childDataInfoList", []) or []:
    if item.get("source_name") != uuid:
        continue
    status = item.get("status", False)
    online = str(status).strip().lower() in ("true", "1", "yes", "online")
    has_addr = item.get("host") is not None and item.get("port") is not None
    if online:
        print("online")
    elif has_addr:
        print("offline")
    else:
        print("stale")
    break
else:
    print("absent")
' "$uuid"
}

# 轮询 list-source，直到状态进入目标集合。参数：UUID、目标状态（空格分隔）、次数、间隔
poll_source_state() {
    local uuid="$1"
    local targets="$2"
    local attempts="${3:-4}"
    local delay="${4:-2}"
    local state="unknown"
    local verify
    local i
    for ((i=1; i<=attempts; i++)); do
        sleep "$delay"
        verify=$(fs_cli_call list-source 2>&1)
        state=$(source_state_from_json "$uuid" "$verify")
        case " $targets " in
            *" $state "*) printf '%s\n' "$state"; return 0 ;;
        esac
    done
    printf '%s\n' "$state"
}

# 判断 del-source 返回：ok / already_gone / failed / invalid
delete_response_state() {
    local payload="$1"
    printf '%s' "$payload" | python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    print("invalid")
    raise SystemExit(0)

result = str(data.get("result", "")).strip().lower()
msg = str(data.get("msg", "")).strip().lower()
if result == "true":
    print("ok")
elif "not exist" in msg or "not found" in msg:
    print("already_gone")
else:
    print("failed")
'
}

# 重复实例，或 fsdeamon 从 SSH 会话而不是 systemd 服务启动，都会共享 data-path，
# 导致 list-source / child.sock 状态互相污染。这里只告警并要求确认，不自动终止进程。
check_fsdeamon_instances() {
    local instances roots root_count listeners listener_pid listener_pgid listener_cgroup
    local issue="" prompt_required=false pid ppid pgid cgroup mark
    FSDEAMON_RUNNING="false"
    FSDEAMON_PROC_COUNT=0
    FSDEAMON_START=""
    instances=$(host_shell_call "ps -eo pid=,ppid=,pgid=,comm=,args= | awk '\$4 == \"fsdeamon\" {print}'")
    [ -n "$instances" ] || return 0

    FSDEAMON_RUNNING="true"
    FSDEAMON_PROC_COUNT=$(printf '%s\n' "$instances" | grep -c . 2>/dev/null || true)

    roots=$(printf '%s\n' "$instances" | awk '$2 == 1')
    root_count=$(printf '%s\n' "$roots" | grep -c . 2>/dev/null || true)

    listeners=$(host_shell_call "ss -lntp 2>/dev/null | grep ':$PORT ' || true")
    listener_pid=$(printf '%s\n' "$listeners" | sed -n 's/.*pid=\([0-9][0-9]*\),.*/\1/p' | head -1)
    listener_pgid=""
    listener_cgroup=""
    if [ -n "$listener_pid" ]; then
        listener_pgid=$(host_shell_call "ps -o pgid= -p $listener_pid 2>/dev/null | tr -d ' '")
        listener_cgroup=$(host_shell_call "cat /proc/$listener_pid/cgroup 2>/dev/null | head -1 | cut -d: -f3")
        FSDEAMON_START=$(host_shell_call "ps -o lstart= -p $listener_pid 2>/dev/null")
    fi

    if [ "${root_count:-0}" -gt 1 ]; then
        issue="检测到 $root_count 个顶层 fsdeamon 实例"
        prompt_required=true
    elif [ -z "$listener_pid" ]; then
        issue="fsdeamon 未监听 $PORT"
        prompt_required=true
    elif [ -n "$listener_cgroup" ] && [[ "$listener_cgroup" != *"/system.slice/"* ]] && [[ "$listener_cgroup" != /system.slice/* ]]; then
        echo "  ℹ fsdeamon 由 SSH 会话启动（$listener_cgroup），当前只有一套实例；可继续，但建议纳入服务管理。"
        return 0
    else
        return 0
    fi

    echo "  ⚠ $issue，数据源状态可能不可靠："
    while read -r pid ppid pgid _; do
        [ -n "$pid" ] || continue
        mark=""
        cgroup=$(host_shell_call "cat /proc/$pid/cgroup 2>/dev/null | head -1 | cut -d: -f3")
        if [ "$pid" = "$listener_pid" ] || { [ -n "$listener_pgid" ] && [ "$pgid" = "$listener_pgid" ]; }; then
            mark="  ← 监听 $PORT"
        fi
        printf '    PID %-8s PPID %-8s %s%s\n' "$pid" "$ppid" "${cgroup:--}" "$mark"
    done <<< "$roots"
    echo "    请只保留监听 $PORT 的正式实例；SSH 会话里手工启动的实例应终止。"
    echo "    实例不在 systemd 服务下，或两套实例并存时，删除可能成功但列表仍显示失效记录或僵尸进程。"
    if [ "$prompt_required" = "true" ]; then
        read -rep "    仍要继续清理数据源? [y/N]: " INSTANCE_CONFIRM
        if [ "$INSTANCE_CONFIRM" != "y" ] && [ "$INSTANCE_CONFIRM" != "Y" ]; then
            echo "  已退出，请先处理重复 fsdeamon 实例。"
            exit 1
        fi
    fi
}

# 从 fs-cli --method=list 的返回中提取监控目录。
trackup_paths_from_json() {
    printf '%s' "$1" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
for path in data.get("trackup-list", []) or []:
    print(path)
'
}

# 删除后提示到源端核对 /etc/fsbackup，并给出兜底清理命令。
print_source_cleanup_hint() {
    local addr="$1"
    shift
    local host="${addr%:*}" conf path
    [ "$addr" = "-" ] && host="未知"
    echo "    源端核对: 登录 $host 查看 /etc/fsbackup"
    for path in "$@"; do
        conf="_$(printf '%s' "${path#/}" | tr '/' '_')"
        echo "      - $conf"
        echo "        若仍存在，在源端执行: fsbackup_tools ioctl monitor del $path"
    done
}

# 在目标 worker 上调用 fs-cli。
# - 本地模式：直接调用本机 fs-cli --host=127.0.0.1 --port=8901
# - 远端模式：通过 rpc 6611 到 worker 本机执行 fs-cli --host=127.0.0.1 --port=8901
fs_cli_call() {
    local method="$1"
    local source_name="${2:-}"
    local source_addr="${3:-}"
    local bak_path="${4:-}"
    local cmd

    if [ "$USE_RPC" = "true" ]; then
        cmd="export LD_LIBRARY_PATH=/opt/aio/airflow/tools/fs-tools/\$(uname -m)/fsclient/lib_x86_64:\$LD_LIBRARY_PATH && /opt/aio/airflow/tools/fs-tools/\$(uname -m)/fsclient/fs-cli --host=127.0.0.1 --port=$PORT --method=$method"
        if [ -n "$source_name" ]; then
            cmd="$cmd --source-name=$(shell_quote "$source_name")"
        fi
        if [ -n "$source_addr" ]; then
            cmd="$cmd --source=$(shell_quote "$source_addr")"
        fi
        if [ -n "$bak_path" ]; then
            cmd="$cmd --bak-path=$(shell_quote "$bak_path")"
        fi
        "$RPC" -h "$HOST" -p "$RPC_PORT" -c "$cmd"
    else
        local args=(--host=127.0.0.1 --port="$PORT" --method="$method")
        if [ -n "$source_name" ]; then
            args+=(--source-name="$source_name")
        fi
        if [ -n "$source_addr" ]; then
            args+=(--source="$source_addr")
        fi
        if [ -n "$bak_path" ]; then
            args+=(--bak-path="$bak_path")
        fi
        "$FS_CLI" "${args[@]}"
    fi
}

json_bool_true() {
    python3 -c "
import sys
v = sys.argv[1] if len(sys.argv) > 1 else ''
print('true' if str(v).strip().lower() in ('true', '1', 'yes', 'online') else 'false')
" "$1"
}

echo

# ═══════════════ 1. 获取数据源列表 ═══════════════

check_fsdeamon_instances
if [ "$FSDEAMON_RUNNING" != "true" ]; then
    echo "  ❌ 未发现 fsdeamon 进程。请先在 Worker 启动 fsdeamon 后重试。"
    exit 1
fi

# fs-cli --method=list-source → 查询 worker 上所有已注册的数据源
SOURCE_RESPONSE=$(fs_cli_call list-source 2>&1) || {
    if [ "$USE_RPC" = "true" ]; then
        echo "  错误: 无法通过 RPC 连接 $HOST ($HOST:$RPC_PORT) 或目标 Worker 本机 fsdeamon 不可用"
        echo "  请确认目标主机 rpc 服务和 fsdeamon 服务已启动"
    else
        echo "  错误: 本地未运行 fsdeamon 服务"
        echo "  请先启动: rdb start fsdeamon"
    fi
    echo "  $SOURCE_RESPONSE"
    exit 1
}

# 解析 JSON，提取 UUID|地址|状态。部分离线失效记录没有 host/port，需要兼容。
LIST=$(echo "$SOURCE_RESPONSE" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception as e:
    raise SystemExit('invalid json: %s' % e)

result = d.get('result')
if str(result).lower() == 'false':
    raise SystemExit(d.get('msg') or 'fs-cli list-source result=false')

for item in d.get('childDataInfoList', []):
    source_name = item.get('source_name') or ''
    host = item.get('host')
    port = item.get('port')
    addr = '%s:%s' % (host, port) if host is not None and port is not None else '-'
    status = item.get('status', False)
    status_str = 'true' if str(status).lower() in ('true', '1', 'yes', 'online') else 'false'
    print('%s|%s|%s' % (source_name, addr, status_str))
") || {
    echo "  错误: 无法解析 fsdeamon 返回数据"
    echo "  $SOURCE_RESPONSE"
    exit 1
}

if [ -z "$LIST" ]; then
    echo "  当前没有监控中的数据源。"
    exit 0
fi
printf "  %-4s %-37s %-21s %s\n" "No." "UUID" "Address" "Status"
echo "  ─────────────────────────────────────────────────────────────────────"

IDX=0
declare -a UUID_LIST
declare -a ADDR_LIST
declare -a STATUS_LIST

while IFS='|' read -r uuid addr status; do
    IDX=$((IDX + 1))
    UUID_LIST[$IDX]="$uuid"
    ADDR_LIST[$IDX]="$addr"
    STATUS_LIST[$IDX]="$status"
    if [ "$status" = "true" ]; then
        s="Online"
    elif [ "$addr" = "-" ]; then
        s="Offline(失效记录)"
    else
        s="Offline"
    fi
    printf "  %-4d %-37s %-21s %s\n" "$IDX" "$uuid" "$addr" "$s"
done <<< "$LIST"

TOTAL=$IDX
echo "  ─────────────────────────────────────────────────────────────────────"
EXPECTED_PROC_COUNT=$((TOTAL + 2))
echo "  fsdeamon: 启动于 ${FSDEAMON_START:-未知}；进程 ${FSDEAMON_PROC_COUNT} 个（预期 2 + 数据源 ${TOTAL} = ${EXPECTED_PROC_COUNT}）"
if [ "$FSDEAMON_PROC_COUNT" -ne "$EXPECTED_PROC_COUNT" ]; then
    PROC_DIFF=$((FSDEAMON_PROC_COUNT - EXPECTED_PROC_COUNT))
    if [ "$PROC_DIFF" -gt 0 ]; then
        echo "  ⚠ 进程数比预期多 ${PROC_DIFF} 个，存在残留 child 或重复实例。"
    else
        echo "  ⚠ 进程数比预期少 $((0 - PROC_DIFF)) 个，可能仍在启动或 child 未就绪。"
    fi
    echo "  ℹ 若日志出现 host:-port:0 与 InitDeamonData failed，通常是 .context 中失效数据源在反复拉起 child。"
    echo "  ℹ 此状态下 del-source 往往返回 source_name not exist，建议先处理 fsdeamon 状态。"
    read -rep "  仍要继续尝试清理? [y/N]: " PROC_CONFIRM
    if [ "$PROC_CONFIRM" != "y" ] && [ "$PROC_CONFIRM" != "Y" ]; then
        echo "  已退出。请先处理 fsdeamon 残留 child/上下文后重试。"
        exit 1
    fi
fi
if [ "$TOTAL" -gt 1 ]; then
    echo "  ℹ 当前有多个数据源；请按 Address(host:port) 核对是否属于本次备份计划，不要只看 UUID。"
fi

# ═══════════════ 2. 用户选择 ═══════════════

echo "▸ 选择要删除的数据源:"
echo "    1 3 5    - 指定序号（空格分隔）"
echo "    1-5      - 连续范围"
echo "    all      - 全部删除"
echo "    q        - 退出"
read -rep "  请选择: " CHOICE

# 过滤控制字符和非打印字符
CHOICE=$(echo "$CHOICE" | tr -cd '[:alnum:]- \n')

SELECTED_IDX=""
case "$CHOICE" in
    "")
        echo "  未选择，退出。"
        exit 0
        ;;
    q|Q)
        echo "  已退出。"
        exit 0
        ;;
    [Aa][Ll][Ll])
        for ((i=1; i<=TOTAL; i++)); do
            SELECTED_IDX="$SELECTED_IDX $i"
        done
        ;;
    *-*)
        START=$(echo "$CHOICE" | cut -d- -f1)
        END=$(echo "$CHOICE" | cut -d- -f2)
        if ! [[ "$START" =~ ^[0-9]+$ ]] || ! [[ "$END" =~ ^[0-9]+$ ]]; then
            echo "  范围格式无效，退出。"
            exit 1
        fi
        if [ "$START" -gt "$END" ]; then
            echo "  范围错误（起始 > 结束），退出。"
            exit 1
        fi
        for ((i=START; i<=END; i++)); do
            SELECTED_IDX="$SELECTED_IDX $i"
        done
        ;;
    *)
        SELECTED_IDX=$(echo "$CHOICE" | tr ' ' '\n' | grep -E '^[0-9]+$' | tr '\n' ' ')
        ;;
esac

SELECTED_IDX=$(echo "$SELECTED_IDX" | xargs)
if [ -z "$SELECTED_IDX" ]; then
    echo "  输入无效，退出。"
    exit 1
fi

echo
echo "────────── 开始删除 ──────────────────────────"

# ═══════════════ 3. 逐个删除 ═══════════════

SUCCESS_COUNT=0
TRACKUP_DELETED_COUNT=0
STALE_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

for idx in $SELECTED_IDX; do
    if [ "$idx" -lt 1 ] || [ "$idx" -gt "$TOTAL" ]; then
        echo "  [跳过] 无效序号 $idx"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    uuid="${UUID_LIST[$idx]}"
    addr="${ADDR_LIST[$idx]}"
    uuid_status="${STATUS_LIST[$idx]}"

    printf "\n  ▶ %s\n" "$uuid"
    echo "    源端: $addr"
    if [ "$addr" = "-" ] && [ "$uuid_status" != "true" ]; then
        echo "    类型: Offline 失效记录（活动源已不存在）"
    else
        [ "$uuid_status" = "true" ] && echo "    类型: Online" || echo "    类型: Offline"
    fi

    TRACKUP_RESPONSE=""
    TRACKUP_LIST=""
    TRACKUP_COUNT=0
    CONN_FAIL="false"
    declare -a TRACKUP_PATHS=()
    if [ "$addr" = "-" ]; then
        echo "    监控目录: 活动源已不存在，跳过查询"
    else
        # fs-cli --method=list → 查询该源下的监控目录列表（add-trackup 注册的路径）
        TRACKUP_RESPONSE=$(fs_cli_call list "$uuid" 2>&1)
        TRACKUP_LIST=$(trackup_paths_from_json "$TRACKUP_RESPONSE")
        if [ -n "$TRACKUP_LIST" ]; then
            echo "    监控目录:"
            n=0
            while IFS= read -r p; do
                [ -n "$p" ] || continue
                n=$((n + 1))
                TRACKUP_PATHS[$n]="$p"
                printf "      %d. %s\n" "$n" "$p"
            done <<< "$TRACKUP_LIST"
            TRACKUP_COUNT=$n
        else
            CONN_FAIL=$(echo "$TRACKUP_RESPONSE" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    result = str(d.get('result', '')).lower()
    msg = str(d.get('msg', '')).lower()
    failed = result == 'false' and any(k in msg for k in ('connect error', 'connection refused', 'timed out', 'timeout', 'no route', 'connect failed'))
    print('true' if failed else 'false')
except Exception:
    print('false')
" 2>/dev/null)
            if [ "$CONN_FAIL" = "true" ]; then
                echo "    源端无法连接，仅清理 worker 侧记录"
            else
                echo "    无监控目录"
            fi
        fi
    fi

    DELETE_MODE="source"
    SELECTED_TRACKUP_IDX=""
    if [ "$TRACKUP_COUNT" -gt 1 ]; then
        echo "    ⚠ 同一数据源有 $TRACKUP_COUNT 个监控目录；直接删除数据源会清理全部目录。"
        echo "      如其他备份计划也使用该数据源，请只选择本次计划对应的目录。"
        echo "      输入 all 表示删除整个数据源。"
        read -rep "    要清理的目录序号（如 1 或 1 2）/all/q: " DIR_CHOICE
        DIR_CHOICE=$(echo "$DIR_CHOICE" | tr -cd '[:alnum:]- \n')
        case "$DIR_CHOICE" in
            q|Q)
                echo "    跳过"
                SKIP_COUNT=$((SKIP_COUNT + 1))
                continue
                ;;
            [Aa][Ll][Ll])
                DELETE_MODE="source"
                ;;
            *-*)
                START=$(echo "$DIR_CHOICE" | cut -d- -f1)
                END=$(echo "$DIR_CHOICE" | cut -d- -f2)
                if ! [[ "$START" =~ ^[0-9]+$ ]] || ! [[ "$END" =~ ^[0-9]+$ ]] || [ "$START" -gt "$END" ]; then
                    echo "    目录范围无效，跳过"
                    SKIP_COUNT=$((SKIP_COUNT + 1))
                    continue
                fi
                for ((i=START; i<=END; i++)); do
                    SELECTED_TRACKUP_IDX="$SELECTED_TRACKUP_IDX $i"
                done
                DELETE_MODE="trackup"
                ;;
            *)
                SELECTED_TRACKUP_IDX=$(echo "$DIR_CHOICE" | tr ' ' '\n' | grep -E '^[0-9]+$' | tr '\n' ' ')
                SELECTED_TRACKUP_IDX=$(echo "$SELECTED_TRACKUP_IDX" | xargs)
                if [ -n "$SELECTED_TRACKUP_IDX" ]; then
                    DELETE_MODE="trackup"
                else
                    echo "    目录选择无效，跳过"
                    SKIP_COUNT=$((SKIP_COUNT + 1))
                    continue
                fi
                ;;
        esac
        SELECTED_TRACKUP_IDX=$(echo "$SELECTED_TRACKUP_IDX" | xargs)
        if [ "$DELETE_MODE" = "trackup" ] && [ -z "$SELECTED_TRACKUP_IDX" ]; then
            echo "    未选择有效目录，跳过"
            SKIP_COUNT=$((SKIP_COUNT + 1))
            continue
        fi
    fi

    if [ "$DELETE_MODE" = "trackup" ]; then
        echo "    将按监控目录清理（不删除整个数据源）"
        read -rep "    确认删除上述目录? [y/N]: " CONFIRM
        if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
            echo "    跳过"
            SKIP_COUNT=$((SKIP_COUNT + 1))
            continue
        fi

        declare -a SUCCESS_PATHS=()
        for path_idx in $SELECTED_TRACKUP_IDX; do
            if [ "$path_idx" -lt 1 ] || [ "$path_idx" -gt "$TRACKUP_COUNT" ]; then
                echo "    [跳过] 无效目录序号 $path_idx"
                SKIP_COUNT=$((SKIP_COUNT + 1))
                continue
            fi
            trackup_path="${TRACKUP_PATHS[$path_idx]}"
            echo "    ▶ $trackup_path"
            DEL_TRACKUP_RESULT=$(fs_cli_call del-trackup "$uuid" "" "$trackup_path" 2>&1)
            DEL_TRACKUP_STATE=$(delete_response_state "$DEL_TRACKUP_RESULT")
            VERIFY_TRACKUP_RESPONSE=$(fs_cli_call list "$uuid" 2>&1)
            VERIFY_RESULT=$(printf '%s' "$VERIFY_TRACKUP_RESPONSE" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("invalid")
    raise SystemExit(0)
print("true" if str(data.get("result", "")).strip().lower() == "true" else "false")
' 2>/dev/null)
            VERIFY_PATHS=$(trackup_paths_from_json "$VERIFY_TRACKUP_RESPONSE")
            if [ "$VERIFY_RESULT" = "true" ] && ! printf '%s\n' "$VERIFY_PATHS" | grep -Fxq -- "$trackup_path"; then
                echo "      ✅ 监控目录已删除"
                SUCCESS_PATHS+=("$trackup_path")
                TRACKUP_DELETED_COUNT=$((TRACKUP_DELETED_COUNT + 1))
            else
                echo "      ❌ 监控目录删除未确认"
                [ "$DEL_TRACKUP_STATE" = "already_gone" ] && echo "      ℹ del-trackup 返回不存在，但复查目录仍在"
                echo "      原始返回: $DEL_TRACKUP_RESULT"
                echo "      复查返回: $VERIFY_TRACKUP_RESPONSE"
                FAIL_COUNT=$((FAIL_COUNT + 1))
            fi
        done
        if [ "${#SUCCESS_PATHS[@]}" -gt 0 ]; then
            print_source_cleanup_hint "$addr" "${SUCCESS_PATHS[@]}"
        fi
        continue
    fi

    if [ "$TRACKUP_COUNT" -gt 1 ]; then
        echo "    模式: 删除整个数据源（含全部 $TRACKUP_COUNT 个监控目录）"
    elif [ "$TRACKUP_COUNT" -eq 1 ]; then
        echo "    该数据源只有 1 个监控目录，按数据源删除"
    elif [ "$CONN_FAIL" = "true" ]; then
        echo "    ⚠ 无法获取监控目录；仍将删除整个 Worker 侧数据源记录"
    fi

    read -rep "    确认删除整个数据源? [y/N]: " CONFIRM
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        echo "    跳过"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    # fs-cli --method=del-source → 删除数据源（仅 worker 侧记录）
    # 正常活动源必须同时传 source-name 和 source；child 已失效时，daemon 会返回
    # source_name not exist，此时改用 source-name-only 清理残留记录。
    # 删除是异步的：Online -> Offline(失效记录) -> absent，需要轮询确认。
    DELETE_RESULT="failed"
    DELETE_REASON=""
    VERIFY_ATTEMPTS="${FSDEAMON_VERIFY_ATTEMPTS:-4}"
    VERIFY_WAIT="${FSDEAMON_VERIFY_WAIT:-2}"

    if [ "$addr" != "-" ]; then
        DEL_RESULT=$(fs_cli_call del-source "$uuid" "$addr" 2>&1)
    else
        DEL_RESULT=$(fs_cli_call del-source "$uuid" "" 2>&1)
    fi
    DEL_STATE=$(delete_response_state "$DEL_RESULT")
    CURRENT_STATE=$(poll_source_state "$uuid" "absent stale" "$VERIFY_ATTEMPTS" "$VERIFY_WAIT")

    # 有地址但 child 已失效时，source+name 会报 source_name not exist；用 UUID 再清一次。
    if [ "$CURRENT_STATE" = "online" ] || [ "$CURRENT_STATE" = "offline" ]; then
        echo "    ℹ 活动源仍未消失，尝试清理失效 child 的残留记录..."
        FALLBACK_RESULT=$(fs_cli_call del-source "$uuid" "" 2>&1)
        FALLBACK_STATE=$(delete_response_state "$FALLBACK_RESULT")
        if [ "$FALLBACK_STATE" != "invalid" ]; then
            DEL_RESULT="$FALLBACK_RESULT"
            DEL_STATE="$FALLBACK_STATE"
        fi
        CURRENT_STATE=$(poll_source_state "$uuid" "absent stale" "$VERIFY_ATTEMPTS" "$VERIFY_WAIT")
    fi

    # 失效记录再清一次，目标是从 list-source 彻底消失。
    # 实测有地址转来的失效记录必须同时带 source-name + 原地址；仅 UUID 可能返回 true 但记录仍在。
    if [ "$CURRENT_STATE" = "stale" ]; then
        echo "    ℹ 活动源已失效，继续清理 Offline 失效记录..."
        if [ "$addr" != "-" ]; then
            STALE_RESULT=$(fs_cli_call del-source "$uuid" "$addr" 2>&1)
        else
            STALE_RESULT=$(fs_cli_call del-source "$uuid" "" 2>&1)
        fi
        STALE_STATE=$(delete_response_state "$STALE_RESULT")
        if [ "$STALE_STATE" != "invalid" ]; then
            DEL_RESULT="$STALE_RESULT"
            DEL_STATE="$STALE_STATE"
        fi
        CURRENT_STATE=$(poll_source_state "$uuid" "absent" "$VERIFY_ATTEMPTS" "$VERIFY_WAIT")

        # 有地址仍清不掉时，再回退 UUID-only（兼容无 host 的纯失效记录）。
        if [ "$CURRENT_STATE" != "absent" ] && [ "$addr" != "-" ]; then
            STALE_FALLBACK=$(fs_cli_call del-source "$uuid" "" 2>&1)
            STALE_FALLBACK_STATE=$(delete_response_state "$STALE_FALLBACK")
            if [ "$STALE_FALLBACK_STATE" != "invalid" ]; then
                DEL_RESULT="$STALE_FALLBACK"
                DEL_STATE="$STALE_FALLBACK_STATE"
            fi
            CURRENT_STATE=$(poll_source_state "$uuid" "absent" "$VERIFY_ATTEMPTS" "$VERIFY_WAIT")
        fi
    fi

    case "$CURRENT_STATE" in
        absent) DELETE_RESULT="deleted" ;;
        stale) DELETE_RESULT="stale" ;;
        *)
            DELETE_RESULT="failed"
            DELETE_REASON="活动源仍在 list-source 中（状态: $CURRENT_STATE）"
            ;;
    esac

    case "$DELETE_RESULT" in
        deleted)
            echo "    ✅ 活动数据源已删除"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            ;;
        stale)
            echo "    ✅ Worker 侧活动数据源已清除"
            echo "    ⚠ list-source 仍保留 Offline 失效记录（无 host/port）"
            echo "    ℹ 该记录由 fsdeamon 内部维护；本工具不重启 daemon、不修改 .context"
            STALE_COUNT=$((STALE_COUNT + 1))
            ;;
        *)
            echo "    ❌ 数据源删除未完成：${DELETE_REASON:-未知错误}"
            [ "$DEL_STATE" = "already_gone" ] && echo "    ℹ del-source 返回 source_name not exist，但列表仍显示活动源"
            echo "    原始返回: $DEL_RESULT"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            ;;
    esac

    if [ "$DELETE_RESULT" = "deleted" ] || [ "$DELETE_RESULT" = "stale" ]; then
        if [ "$TRACKUP_COUNT" -gt 0 ]; then
            print_source_cleanup_hint "$addr" "${TRACKUP_PATHS[@]}"
        fi
    fi
done

echo
echo "────────── 处理结果 ──────────────────────────"
echo "  数据源删除: $SUCCESS_COUNT  监控目录删除: $TRACKUP_DELETED_COUNT  仅失效记录残留: $STALE_COUNT  失败: $FAIL_COUNT  跳过: $SKIP_COUNT"

echo
echo "────────── 剩余数据源 ────────────────────────"

# ═══════════════ 4. 展示剩余数据源 ═══════════════

REMAIN_RESPONSE=$(fs_cli_call list-source 2>&1)
REMAIN_LIST=$(echo "$REMAIN_RESPONSE" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
items = d.get('childDataInfoList', []) or []
for item in items:
    source_name = item.get('source_name') or ''
    host = item.get('host')
    port = item.get('port')
    addr = '%s:%s' % (host, port) if host is not None and port is not None else '-'
    status = item.get('status', False)
    s = 'true' if str(status).lower() in ('true', '1', 'yes', 'online') else 'false'
    print('%s|%s|%s' % (source_name, addr, s))
" 2>/dev/null)

if [ -z "$REMAIN_LIST" ]; then
    echo "  没有剩余的数据源。"
else
    printf "  %-4s %-37s %-21s %s\n" "No." "UUID" "Address" "Status"
    echo "  ─────────────────────────────────────────────────────────────────────"
    i=0
    while IFS='|' read -r uuid addr status; do
        i=$((i + 1))
        if [ "$status" = "true" ]; then
            s="Online"
        elif [ "$addr" = "-" ]; then
            s="Offline(失效记录)"
        else
            s="Offline"
        fi
        printf "  %-4d %-37s %-21s %s\n" "$i" "$uuid" "$addr" "$s"
    done <<< "$REMAIN_LIST"
    echo "  ─────────────────────────────────────────────────────────────────────"
fi
echo
if [ "$STALE_COUNT" -gt 0 ]; then
    echo "处理结束。仍有 $STALE_COUNT 个 Offline 失效记录；本工具未重启 fsdeamon。"
elif [ "$FAIL_COUNT" -gt 0 ]; then
    echo "处理结束。存在失败项。"
else
    echo "完成。"
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi

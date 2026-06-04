#!/bin/bash
# 版本: 1.4.0
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
#   选择要删除的数据源，对每个源确认后通过 fs-cli del-source 清理 worker 侧记录。
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

ARCH=$(uname -m)
FS_CLI="/opt/aio/airflow/tools/fs-tools/$ARCH/fsclient/fs-cli"
FS_CLI_DIR=$(dirname "$FS_CLI")
RPC="/opt/aio/airflow/tools/rpc/$ARCH/rpc"
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

# 解析 JSON，提取 UUID|地址|删除参数|状态。部分离线残留源可能没有 host/port，需要兼容。
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
    source_arg = addr if addr != '-' else source_name
    status = item.get('status', False)
    status_str = 'true' if str(status).lower() in ('true', '1', 'yes', 'online') else 'false'
    print('%s|%s|%s|%s' % (source_name, addr, source_arg, status_str))
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
declare -a SOURCE_ARG_LIST

while IFS='|' read -r uuid addr source_arg status; do
    IDX=$((IDX + 1))
    UUID_LIST[$IDX]="$uuid"
    ADDR_LIST[$IDX]="$addr"
    SOURCE_ARG_LIST[$IDX]="$source_arg"
    [ "$status" = "true" ] && s="Online" || s="Offline"
    printf "  %-4d %-37s %-21s %s\n" "$IDX" "$uuid" "$addr" "$s"
done <<< "$LIST"

TOTAL=$IDX
echo "  ─────────────────────────────────────────────────────────────────────"

# ═══════════════ 2. 用户选择 ═══════════════

echo "▸ 选择要删除的数据源:"
echo "    1 3 5    - 指定序号（空格分隔）"
echo "    1-5      - 连续范围"
echo "    all      - 全部删除"
echo "    q        - 退出"
read -rp "  请选择: " CHOICE

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

for idx in $SELECTED_IDX; do
    if [ "$idx" -lt 1 ] || [ "$idx" -gt "$TOTAL" ]; then
        echo "  [跳过] 无效序号 $idx"
        continue
    fi

    uuid="${UUID_LIST[$idx]}"
    addr="${ADDR_LIST[$idx]}"
    source_arg="${SOURCE_ARG_LIST[$idx]}"

    printf "\n  ▶ %s\n" "$uuid"
    echo "    源端: $addr"

    # fs-cli --method=list → 查询该源下的监控目录列表（add-trackup 注册的路径）
    TRACKUP_RESPONSE=$(fs_cli_call list "$uuid" 2>&1)
    TRACKUP_LIST=$(echo "$TRACKUP_RESPONSE" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
paths = d.get('trackup-list', []) or []
for p in paths:
    print(p)
" 2>/dev/null)

    TRACKUP_COUNT=$(echo "$TRACKUP_LIST" | grep -c '.' 2>/dev/null)
    [ -z "$TRACKUP_COUNT" ] && TRACKUP_COUNT=0

    if [ "$TRACKUP_COUNT" -gt 0 ]; then
        echo "    监控目录:"
        while IFS= read -r p; do
            echo "      - $p"
        done <<< "$TRACKUP_LIST"
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

    echo -n "    确认删除该数据源? [y/N]: "
    read -r CONFIRM
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        echo "    跳过"
        continue
    fi

    # fs-cli --method=del-source → 删除数据源（仅 worker 侧记录）
    # 等价于手工命令：fs-cli --host=127.0.0.1 --port=8901 --source-name=<uuid> --method=del-source --source=<host>:6611
    DEL_RESULT=$(fs_cli_call del-source "$uuid" "$source_arg" 2>&1)
    DEL_OK=$(echo "$DEL_RESULT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('true' if str(d.get('result')).lower() == 'true' else 'false')
except Exception:
    print('false')
" 2>/dev/null)

    if [ "$DEL_OK" = "true" ]; then
        echo "    ✅ 数据源删除成功"
    else
        echo "    ❌ 数据源删除失败: $DEL_RESULT"
    fi
done

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
        [ "$status" = "true" ] && s="Online" || s="Offline"
        printf "  %-4d %-37s %-21s %s\n" "$i" "$uuid" "$addr" "$s"
    done <<< "$REMAIN_LIST"
    echo "  ─────────────────────────────────────────────────────────────────────"
fi
echo
echo "完成。"

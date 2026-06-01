#!/bin/bash
# 版本: 1.0.0
# AIO 运维工具集入口
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 子工具定义（文件名|功能描述）
TOOLS=(
    "aio-collect-logs.py|日志收集"
    "aio-fsdeamon-cleanup.sh|fsdeamon清理"
    "aio-unlock-tasks.py|任务解锁"
    "aio-collect-v.sh|版本收集"
    "check_aiopool_usage.py|存储检查"
)

# 从脚本头部提取版本号
get_tool_version() {
    local file="$1"
    grep -oP '# 版本: \K[0-9.]+' "${SCRIPT_DIR}/${file}" 2>/dev/null || echo "-"
}

# 显示所有子工具版本
show_versions() {
    echo ""
    echo "========================================"
    echo " AIO 运维工具集 - 版本信息"
    echo "========================================"
    printf "  %-30s %-12s %s\n" "工具" "功能" "版本"
    echo "  ─────────────────────────────────────────────────────────────"
    for entry in "${TOOLS[@]}"; do
        IFS='|' read -r file desc <<< "$entry"
        local ver
        ver=$(get_tool_version "$file")
        printf "  %-30s %-12s %s\n" "$file" "$desc" "$ver"
    done
    echo "  ─────────────────────────────────────────────────────────────"
    echo ""
}

# 显示菜单
show_menu() {
    echo ""
    echo "========================================"
    echo " AIO 运维工具集"
    echo "========================================"
    echo "  1) 日志收集    - 根据任务ID收集Worker日志"
    echo "  2) fsdeamon清理 - 清理fsdeamon残留挂载和进程"
    echo "  3) 任务解锁    - 将卡住的running任务标记为failed"
    echo "  4) 版本收集    - 收集本机和Worker的工具版本"
    echo "  5) 存储检查    - 检查Worker的aiopool磁盘空间"
    echo "  0) 退出"
    echo "----------------------------------------"
    echo "  -v) 查看版本信息"
    echo "----------------------------------------"
}

tool_collect_logs() {
    read -rp "请输入任务ID (在Web页面任务列表查看): " task_id
    if [ -z "$task_id" ]; then
        echo "[ERROR] 任务ID不能为空"
        return 1
    fi
    read -rp "指定阶段 (在Web页面任务详情查看阶段名, 多个逗号分隔, 回车=全部): " stages
    if [ -n "$stages" ]; then
        python3 "$SCRIPT_DIR/aio-collect-logs.py" "$task_id" --stages "$stages"
    else
        python3 "$SCRIPT_DIR/aio-collect-logs.py" "$task_id"
    fi
}

tool_fsdeamon_cleanup() {
    read -rp "请输入Worker IP: " worker_ip
    if [ -z "$worker_ip" ]; then
        echo "[ERROR] Worker IP不能为空"
        return 1
    fi
    local rpc_cmd fs_cli_remote
    rpc_cmd="/opt/aio/airflow/tools/rpc/$(uname -m)/rpc"
    fs_cli_remote="export LD_LIBRARY_PATH=/opt/aio/airflow/tools/fs-tools/\$(uname -m)/fsclient/lib_x86_64:\$LD_LIBRARY_PATH && /opt/aio/airflow/tools/fs-tools/\$(uname -m)/fsclient/fs-cli --host=127.0.0.1 --port=8901"

    echo "正在查询 $worker_ip 上的数据源 ..."
    local response
    response=$("$rpc_cmd" -h "$worker_ip" -p 6611 -c "$fs_cli_remote --method=list-source" 2>&1)
    if [ $? -ne 0 ]; then
        echo "[ERROR] 无法连接 $worker_ip 上的 fsdeamon"
        echo "  $response"
        return 1
    fi

    local list
    list=$(echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for item in d.get('childDataInfoList', []):
    s = 'Online' if item['status'] else 'Offline'
    print('{}|{}:{}|{}'.format(item['source_name'], item['host'], item['port'], s))
" 2>/dev/null)

    if [ -z "$list" ]; then
        echo "  当前没有监控中的数据源。"
        return 0
    fi

    echo ""
    printf "  %-4s %-37s %-21s %s\n" "No." "UUID" "Address" "Status"
    echo "  ─────────────────────────────────────────────────────────────────────"
    local i=0
    declare -a UUID_ARR
    declare -a ADDR_ARR
    while IFS='|' read -r uuid addr status; do
        i=$((i + 1))
        UUID_ARR[$i]="$uuid"
        ADDR_ARR[$i]="$addr"
        printf "  %-4d %-37s %-21s %s\n" "$i" "$uuid" "$addr" "$status"
    done <<< "$list"
    local total=$i
    echo "  ─────────────────────────────────────────────────────────────────────"

    echo ""
    echo "  选择要删除的数据源:"
    echo "    1 3 5    - 指定序号 (空格分隔)"
    echo "    1-5      - 连续范围"
    echo "    all      - 全部删除"
    echo "    q        - 退出"
    read -rp "  请选择: " choice

    choice=$(echo "$choice" | tr -cd '[:alnum:]- \n')
    local selected=""
    case "$choice" in
        ""|q|Q)
            echo "  已退出。"
            return 0
            ;;
        [Aa][Ll][Ll])
            for ((j=1; j<=total; j++)); do selected="$selected $j"; done
            ;;
        *-*)
            local s_start s_end
            s_start=$(echo "$choice" | cut -d- -f1)
            s_end=$(echo "$choice" | cut -d- -f2)
            for ((j=s_start; j<=s_end; j++)); do selected="$selected $j"; done
            ;;
        *)
            selected=$(echo "$choice" | tr ' ' '\n' | grep -E '^[0-9]+$' | tr '\n' ' ')
            ;;
    esac

    selected=$(echo "$selected" | xargs)
    if [ -z "$selected" ]; then
        echo "  输入无效，退出。"
        return 1
    fi

    echo ""
    echo "────────── 开始删除 ──────────────────────────"
    for idx in $selected; do
        if [ "$idx" -lt 1 ] || [ "$idx" -gt "$total" ]; then
            echo "  [跳过] 无效序号 $idx"
            continue
        fi
        local uuid="${UUID_ARR[$idx]}"
        local addr="${ADDR_ARR[$idx]}"
        printf "\n  ▶ %s (%s)\n" "$uuid" "$addr"

        read -rp "    确认删除? [y/N]: " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo "    跳过"
            continue
        fi

        local del_result
        del_result=$("$rpc_cmd" -h "$worker_ip" -p 6611 -c "$fs_cli_remote --source-name=$uuid --method=del-source --source=$addr" 2>&1)
        local del_ok
        del_ok=$(echo "$del_result" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('true' if d.get('result') == 'true' else 'false')
except:
    print('false')
" 2>/dev/null)
        if [ "$del_ok" = "true" ]; then
            echo "    删除成功"
        else
            echo "    删除失败: $del_result"
        fi
    done
    echo ""
    echo "完成。"
}

tool_collect_versions() {
    bash "$SCRIPT_DIR/aio-collect-v.sh"
}

tool_check_aiopool() {
    python3 "$SCRIPT_DIR/check_aiopool_usage.py"
}

run_tool() {
    echo ""
    echo ">>> 启动: $1"
    echo "----------------------------------------"
    case "$2" in
        1) tool_collect_logs ;;
        2) tool_fsdeamon_cleanup ;;
        3) python3 "$SCRIPT_DIR/aio-unlock-tasks.py" ;;
        4) tool_collect_versions ;;
        5) tool_check_aiopool ;;
    esac
}

# 处理命令行参数
if [ "${1:-}" = "-v" ] || [ "${1:-}" = "--version" ]; then
    show_versions
    exit 0
fi

while true; do
    show_menu
    read -rp "请选择 [0-5]: " choice
    case "$choice" in
        0) echo "退出."; exit 0 ;;
        -v|--version) show_versions ;;
        1) run_tool "日志收集" 1 ;;
        2) run_tool "fsdeamon清理" 2 ;;
        3) run_tool "任务解锁" 3 ;;
        4) run_tool "版本收集" 4 ;;
        5) run_tool "存储检查" 5 ;;
        *) echo "[ERROR] 无效输入" ;;
    esac
done

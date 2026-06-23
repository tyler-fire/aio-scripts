#!/bin/bash
# 版本: 1.1.0
# AIO 运维工具集入口
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 子工具定义（文件名|功能描述）
TOOLS=(
    "aio-collect-logs.py|日志收集"
    "aio-diagnose.py|任务诊断"
    "aio-fsdeamon-cleanup.sh|fsdeamon清理"
    "aio-unlock-tasks.py|任务解锁"
    "aio-collect-v.sh|版本收集"
    "check_aiopool_usage.py|存储检查"
    "ops|加解密工具"
)

# 从脚本头部提取版本号
get_tool_version() {
    local file="$1"
    if file "${SCRIPT_DIR}/${file}" 2>/dev/null | grep -q 'ELF'; then
        "${SCRIPT_DIR}/${file}" --version 2>/dev/null | head -1 || echo "-"
    else
        grep -oP '# 版本: \K[0-9.]+' "${SCRIPT_DIR}/${file}" 2>/dev/null || echo "-"
    fi
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
    echo "  2) 任务诊断    - 完整诊断(日志+数据库+服务+系统)"
    echo "  3) fsdeamon清理 - 清理fsdeamon残留挂载和进程"
    echo "  4) 任务解锁    - 将卡住的running任务标记为failed"
    echo "  5) 版本收集    - 收集本机和Worker的工具版本"
    echo "  6) 存储检查    - 检查Worker的aiopool磁盘空间"
    echo "  7) 加解密工具  - 文件加密/解密(ops)"
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

tool_diagnose() {
    read -rp "请输入任务ID (在Web页面任务列表查看): " task_id
    if [ -z "$task_id" ]; then
        echo "[ERROR] 任务ID不能为空"
        return 1
    fi
    python3 "$SCRIPT_DIR/aio-diagnose.py" "$task_id"
}

tool_fsdeamon_cleanup() {
    read -rp "请输入Worker IP: " worker_ip
    if [ -z "$worker_ip" ]; then
        echo "[ERROR] Worker IP不能为空"
        return 1
    fi

    bash "$SCRIPT_DIR/aio-fsdeamon-cleanup.sh" "$worker_ip"
}

tool_collect_versions() {
    bash "$SCRIPT_DIR/aio-collect-v.sh"
}

tool_check_aiopool() {
    python3 "$SCRIPT_DIR/check_aiopool_usage.py"
}

tool_ops() {
    echo ""
    echo "  ops - 文件加密/解密工具"
    echo ""
    echo "  用法:"
    echo "    ops encrypt <输入文件> <输出文件> [--key 密钥]"
    echo "    ops decrypt <输入文件> <输出文件> [--key 密钥]"
    echo ""
    echo "  示例:"
    echo "    # 加密配置文件"
    echo "    ops encrypt /opt/aio/cfg/aio.env /opt/aio/cfg/aio.env.enc"
    echo ""
    echo "    # 解密配置文件"
    echo "    ops decrypt /opt/aio/cfg/aio.env.enc /opt/aio/cfg/aio.env"
    echo ""
    echo "    # 使用自定义密钥"
    echo "    ops encrypt input.txt output.bin --key my_secret_key"
    echo "    ops decrypt output.bin decrypted.txt --key my_secret_key"
    echo ""
}

run_tool() {
    echo ""
    echo ">>> 启动: $1"
    echo "----------------------------------------"
    case "$2" in
        1) tool_collect_logs ;;
        2) tool_diagnose ;;
        3) tool_fsdeamon_cleanup ;;
        4) python3 "$SCRIPT_DIR/aio-unlock-tasks.py" ;;
        5) tool_collect_versions ;;
        6) tool_check_aiopool ;;
        7) tool_ops ;;
    esac
}

# 处理命令行参数
if [ "${1:-}" = "-v" ] || [ "${1:-}" = "--version" ]; then
    show_versions
    exit 0
fi

while true; do
    show_menu
    read -rp "请选择 [0-7]: " choice
    case "$choice" in
        0) echo "退出."; exit 0 ;;
        -v|--version) show_versions ;;
        1) run_tool "日志收集" 1 ;;
        2) run_tool "任务诊断" 2 ;;
        3) run_tool "fsdeamon清理" 3 ;;
        4) run_tool "任务解锁" 4 ;;
        5) run_tool "版本收集" 5 ;;
        6) run_tool "存储检查" 6 ;;
        7) run_tool "加解密工具" 7 ;;
        *) echo "[ERROR] 无效输入" ;;
    esac
done

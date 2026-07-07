#!/bin/bash
# 版本: 1.2.3
# AIO 运维工具集入口
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RPC_PORT="${RPC_PORT:-6611}"
RPC_TIMEOUT="${RPC_TIMEOUT:-15}"
RPC_BIN="/opt/aio/airflow/tools/rpc/$(uname -m)/rpc"

# 子工具定义（文件名|功能描述）
TOOLS=(
    "aio-collect-logs.py|日志收集"
    "aio-diagnose.py|任务诊断"
    "aio-worker-performance.py|性能分析"
    "aio-fsdeamon-cleanup.sh|fsdeamon清理"
    "aio-unlock-tasks.py|任务解锁"
    "aio-collect-v.sh|版本收集"
    "aio-collect-hang-logs.sh|主机异常日志"
    "check_aiopool_usage.py|存储检查"
    "goldendb/goldendb_distribute_scripts.sh|GoldenDB脚本分发"
    "license.sh|License管理"
    "ops|加解密工具(x86_64)"
    "ops_arm|加解密工具(ARM)"
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
    echo "  1) 日志收集    - 根据任务ID收集日志(默认只收失败子任务,输入「全部」可收全部)"
    echo "  2) 任务诊断    - 完整诊断(日志+数据库+服务+系统)"
    echo "  3) 性能分析    - Worker性能趋势(基于sar数据)"
    echo "  4) fsdeamon清理 - 清理fsdeamon残留挂载和进程"
    echo "  5) 任务解锁    - 将卡住的running任务标记为failed"
    echo "  6) 版本收集    - 收集本机和Worker的工具版本"
    echo "  7) 存储检查    - 检查Worker的aiopool磁盘空间"
    echo "  8) GoldenDB脚本分发 - 复制3个本地清理脚本到Worker"
    echo "  9) 加解密工具  - 文件加密/解密(ops/ops_arm)"
    echo " 10) License管理 - 检查/激活/恢复License"
    echo " 11) 主机异常日志 - 按起止时间收集hang/断连/重启分析日志"
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

    # 默认只看失败的子任务(这是最常见的排障场景)
    # 输入「全部」才会收所有子任务
    read -rp "收集范围 [失败子任务(默认)/全部子任务]: " scope
    scope=$(echo "$scope" | tr -d '[:space:]')
    if [[ "$scope" == "全部" || "$scope" == "all" || "$scope" == "ALL" ]]; then
        extra_args=""
    else
        extra_args="--failed-only"
    fi

    read -rp "指定阶段 (在Web页面任务详情查看阶段名, 多个逗号分隔, 回车=全部): " stages
    if [ -n "$stages" ]; then
        python3 "$SCRIPT_DIR/aio-collect-logs.py" "$task_id" --stages "$stages" $extra_args
    else
        python3 "$SCRIPT_DIR/aio-collect-logs.py" "$task_id" $extra_args
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

tool_performance() {
    read -rp "请输入 Worker IP (回车=自动查询所有Worker): " worker_ip
    read -rp "分析天数 (3/7/14/30, 默认7): " days
    if [ -z "$days" ]; then
        days=7
    fi
    if [ -z "$worker_ip" ]; then
        python3 "$SCRIPT_DIR/aio-worker-performance.py" --days "$days"
    else
        python3 "$SCRIPT_DIR/aio-worker-performance.py" "$worker_ip" --days "$days"
    fi
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

normalize_time() {
    date -d "$1" "+%Y-%m-%d %H:%M:%S" 2>/dev/null
}

shell_quote() {
    printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

manual_hang_collect_hint() {
    local target_ip="$1"
    local start_time="$2"
    local end_time="$3"
    local include_flag="$4"
    local include_arg="--no-include-aio"

    if [ "$include_flag" = "1" ]; then
        include_arg="--include-aio"
    fi

    echo ""
    echo "RPC 当前不可用，不能远程自动收集。"
    echo "请把下面这个脚本拷到目标主机 ${target_ip} 上本地运行："
    echo ""
    echo "  $SCRIPT_DIR/aio-collect-hang-logs.sh"
    echo ""
    echo "目标主机上执行："
    echo ""
    echo "  bash aio-collect-hang-logs.sh --start \"${start_time}\" --end \"${end_time}\" ${include_arg}"
    echo ""
    echo "执行完成后，把输出的 tar.gz 包交给 AIO 日志分析平台。"
    echo ""
}

rpc_cmd() {
    local host="$1"
    local cmd="$2"
    timeout "$RPC_TIMEOUT" "$RPC_BIN" -h "$host" -p "$RPC_PORT" -c "$cmd" 2>&1
}

tool_collect_hang_logs() {
    local target_ip
    local start_time
    local end_time
    local include_aio
    local include_arg="--no-include-aio"
    local remote_script="/tmp/aio-collect-hang-logs.$$.sh"
    local remote_output
    local remote_archive
    local remote_rc
    local local_dir
    local local_archive
    local cmd
    local q_start
    local q_end
    local q_remote_script

    if [ ! -x "$SCRIPT_DIR/aio-collect-hang-logs.sh" ]; then
        echo "[ERROR] 收集脚本不存在或不可执行: $SCRIPT_DIR/aio-collect-hang-logs.sh"
        return 1
    fi

    read -rp "请输入目标主机 IP: " target_ip
    target_ip=$(echo "$target_ip" | tr -d '[:space:]')
    if [ -z "$target_ip" ]; then
        echo "[ERROR] 目标主机 IP 不能为空"
        return 1
    fi
    if ! [[ "$target_ip" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "[ERROR] 目标主机只能包含字母、数字、点、下划线和短横线"
        return 1
    fi

    while true; do
        read -rp "本次收集从几号几点开始 (例: 2026-07-06 18:00:00): " start_time
        start_time=$(normalize_time "$start_time" || true)
        [ -n "$start_time" ] && break
        echo "[ERROR] 开始时间格式不正确"
    done

    while true; do
        read -rp "本次收集到几号几点结束 (例: 2026-07-06 18:40:00): " end_time
        end_time=$(normalize_time "$end_time" || true)
        [ -n "$end_time" ] && break
        echo "[ERROR] 结束时间格式不正确"
    done

    if [ "$(date -d "$start_time" +%s)" -ge "$(date -d "$end_time" +%s)" ]; then
        echo "[ERROR] 开始时间必须早于结束时间"
        return 1
    fi

    read -rp "是否附加收集 AIO 服务日志? [y/N]: " include_aio
    case "$include_aio" in
        y|Y|yes|YES)
            include_aio=1
            include_arg="--include-aio"
            ;;
        *)
            include_aio=0
            include_arg="--no-include-aio"
            ;;
    esac

    if [ ! -x "$RPC_BIN" ]; then
        echo "[WARN] RPC 工具不存在: $RPC_BIN"
        manual_hang_collect_hint "$target_ip" "$start_time" "$end_time" "$include_aio"
        return 1
    fi

    echo ""
    echo "▸ 测试目标主机 RPC..."
    if ! rpc_cmd "$target_ip" "echo aio-rpc-ok" | grep -q "aio-rpc-ok"; then
        manual_hang_collect_hint "$target_ip" "$start_time" "$end_time" "$include_aio"
        return 1
    fi

    echo "▸ RPC 可用，上传收集脚本..."
    local upload_log
    local download_log

    upload_log=$(mktemp /tmp/aio_hang_upload.XXXXXX)
    download_log=$(mktemp /tmp/aio_hang_download.XXXXXX)

    if ! timeout 60 "$RPC_BIN" -h "$target_ip" -p "$RPC_PORT" --upload 1 --local "$SCRIPT_DIR/aio-collect-hang-logs.sh" --remote "$remote_script" >"$upload_log" 2>&1; then
        echo "[WARN] 上传脚本失败:"
        sed -n '1,20p' "$upload_log"
        rm -f "$upload_log" "$download_log"
        manual_hang_collect_hint "$target_ip" "$start_time" "$end_time" "$include_aio"
        return 1
    fi
    rm -f "$upload_log"

    q_remote_script=$(shell_quote "$remote_script")
    q_start=$(shell_quote "$start_time")
    q_end=$(shell_quote "$end_time")
    cmd="chmod +x $q_remote_script && bash $q_remote_script --start $q_start --end $q_end $include_arg"

    echo "▸ 在目标主机执行收集..."
    remote_output=$(timeout 900 "$RPC_BIN" -h "$target_ip" -p "$RPC_PORT" -c "$cmd" 2>&1)
    remote_rc=$?
    echo "$remote_output"
    if [ "$remote_rc" -ne 0 ]; then
        echo "[ERROR] 远端收集命令失败或超时，退出码: $remote_rc"
        rm -f "$download_log"
        manual_hang_collect_hint "$target_ip" "$start_time" "$end_time" "$include_aio"
        return 1
    fi
    remote_archive=$(echo "$remote_output" | awk -F= '/^ARCHIVE_PATH=/ {print $2}' | tail -1 | tr -d '\r')
    if [ -z "$remote_archive" ]; then
        echo "[ERROR] 未能从远端输出中识别日志包路径"
        rm -f "$download_log"
        manual_hang_collect_hint "$target_ip" "$start_time" "$end_time" "$include_aio"
        return 1
    fi
    if ! [[ "$remote_archive" =~ ^/tmp/hang_collect_[A-Za-z0-9._-]+_[0-9]{8}_[0-9]{6}_[0-9]+\.tar\.gz$ ]]; then
        echo "[ERROR] 远端日志包路径不符合预期: $remote_archive"
        rm -f "$download_log"
        return 1
    fi

    local_dir="/tmp/aio_hang_remote_${target_ip}_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$local_dir"
    local_archive="$local_dir/$(basename "$remote_archive")"

    echo "▸ 下载日志包到本机..."
    if timeout 300 "$RPC_BIN" -h "$target_ip" -p "$RPC_PORT" --download 1 --remote "$remote_archive" --local "$local_archive" >"$download_log" 2>&1; then
        if [ ! -s "$local_archive" ] || ! tar -tzf "$local_archive" >/dev/null 2>&1; then
            echo "[ERROR] 下载后的日志包为空或不是有效 tar.gz: $local_archive"
            rm -f "$download_log"
            return 1
        fi
        echo ""
        echo "收集完成，本机日志包:"
        ls -lh "$local_archive" 2>/dev/null || echo "$local_archive"
        echo ""
        rpc_cmd "$target_ip" "rm -f $(shell_quote "$remote_script") $(shell_quote "$remote_archive")" >/dev/null 2>&1 || true
    else
        echo "[WARN] 下载日志包失败:"
        sed -n '1,30p' "$download_log"
        echo ""
        echo "远端日志包已生成: $remote_archive"
        echo "可稍后从目标主机取回。"
        rm -f "$download_log"
        return 1
    fi
    rm -f "$download_log"
}

tool_license() {
    local action
    local confirm

    echo ""
    echo "  License 管理"
    echo "    1) 检查状态"
    echo "    2) 激活/重新激活"
    echo "    3) 恢复为未激活"
    echo "    0) 返回"
    read -rp "  请选择 [0-3]: " action

    case "$action" in
        1)
            bash "$SCRIPT_DIR/license.sh"
            ;;
        2)
            read -rp "  确认激活/重新激活 License? 输入 yes 继续: " confirm
            if [ "$confirm" = "yes" ]; then
                bash "$SCRIPT_DIR/license.sh" apply
            else
                echo "  已取消"
            fi
            ;;
        3)
            read -rp "  确认恢复为未激活状态? 输入 yes 继续: " confirm
            if [ "$confirm" = "yes" ]; then
                bash "$SCRIPT_DIR/license.sh" revert
            else
                echo "  已取消"
            fi
            ;;
        0)
            return 0
            ;;
        *)
            echo "[ERROR] 无效输入"
            ;;
    esac
}

tool_ops() {
    local arch
    local ops_cmd

    arch=$(uname -m)
    case "$arch" in
        aarch64|arm64)
            ops_cmd="ops_arm"
            ;;
        *)
            ops_cmd="ops"
            ;;
    esac

    echo ""
    echo "  ops - 文件加密/解密工具"
    echo "  当前架构: $arch，建议使用: $ops_cmd"
    echo ""
    echo "  用法:"
    echo "    $ops_cmd encrypt <输入文件> <输出文件> [--key 密钥]"
    echo "    $ops_cmd decrypt <输入文件> <输出文件> [--key 密钥]"
    echo ""
    echo "  说明:"
    echo "    --key 是 AES 自定义密钥，长度必须是 16、24 或 32 字节。"
    echo "    中文或特殊字符可能不等于显示字符数，建议使用 16/24/32 位英文数字。"
    echo ""
    echo "  示例:"
    echo "    # 加密配置文件"
    echo "    $ops_cmd encrypt /opt/aio/cfg/aio.env /opt/aio/cfg/aio.env.enc"
    echo ""
    echo "    # 解密配置文件"
    echo "    $ops_cmd decrypt /opt/aio/cfg/aio.env.enc /opt/aio/cfg/aio.env"
    echo ""
    echo "    # 使用自定义密钥"
    echo "    $ops_cmd encrypt input.txt output.bin --key 1234567890abcdef"
    echo "    $ops_cmd decrypt output.bin decrypted.txt --key 1234567890abcdef"
    echo ""
}

run_tool() {
    echo ""
    echo ">>> 启动: $1"
    echo "----------------------------------------"
    case "$2" in
        1) tool_collect_logs ;;
        2) tool_diagnose ;;
        3) tool_performance ;;
        4) tool_fsdeamon_cleanup ;;
        5) python3 "$SCRIPT_DIR/aio-unlock-tasks.py" ;;
        6) tool_collect_versions ;;
        7) tool_check_aiopool ;;
        8) bash "$SCRIPT_DIR/goldendb/goldendb_distribute_scripts.sh" ;;
        9) tool_ops ;;
        10) tool_license ;;
        11) tool_collect_hang_logs ;;
    esac
}

# 处理命令行参数
if [ "${1:-}" = "-v" ] || [ "${1:-}" = "--version" ]; then
    show_versions
    exit 0
fi

while true; do
    show_menu
    read -rp "请选择 [0-11]: " choice
    case "$choice" in
        0) echo "退出."; exit 0 ;;
        -v|--version) show_versions ;;
        1) run_tool "日志收集" 1 ;;
        2) run_tool "任务诊断" 2 ;;
        3) run_tool "性能分析" 3 ;;
        4) run_tool "fsdeamon清理" 4 ;;
        5) run_tool "任务解锁" 5 ;;
        6) run_tool "版本收集" 6 ;;
        7) run_tool "存储检查" 7 ;;
        8) run_tool "GoldenDB脚本分发" 8 ;;
        9) run_tool "加解密工具" 9 ;;
        10) run_tool "License管理" 10 ;;
        11) run_tool "主机异常日志收集" 11 ;;
        *) echo "[ERROR] 无效输入" ;;
    esac
done

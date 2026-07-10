#!/bin/bash
# 构建 aio-scripts.install 自解压安装包并发布到 GitHub Release
# 版本: 3.0.0

set -e

VERSION="2.1.13"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FILE="$SCRIPT_DIR/aio-scripts.install"
OUTPUT_TMP="$OUTPUT_FILE.tmp.$$"
TEMP_DIR="/tmp/aio-scripts-build-$$"
GITHUB_REPO="tyler-fire/aio-scripts"
GITHUB_TOKEN=""  # 从环境变量或配置文件读取

# 从 git config 读取 GitHub token
if [ -z "$GITHUB_TOKEN" ]; then
    GITHUB_TOKEN=$(git config --get github.token 2>/dev/null || echo "")
fi

# 从 ~/.github_token 读取
if [ -z "$GITHUB_TOKEN" ] && [ -f "$HOME/.github_token" ]; then
    GITHUB_TOKEN=$(cat "$HOME/.github_token")
fi

echo "========================================"
echo " 构建 AIO 运维工具集安装包 v${VERSION}"
echo "========================================"
echo ""

# 创建临时目录
mkdir -p "$TEMP_DIR"

# 核心工具列表
CORE_TOOLS=(
    "aio-tools.sh"
    "aio-diagnose.py"
    "aio-worker-performance.py"
    "aio-collect-logs.py"
    "aio-fsdeamon-cleanup.sh"
    "aio-unlock-tasks.py"
    "aio-collect-v.sh"
    "aio-collect-hang-logs.sh"
    "check_aiopool_usage.py"
    "aio-file-push.sh"
    "goldendb"
    "license.sh"
    "ops"
    "ops_arm"
)

echo "▸ 复制工具文件..."
for tool in "${CORE_TOOLS[@]}"; do
    if [ -f "$SCRIPT_DIR/$tool" ]; then
        cp -f "$SCRIPT_DIR/$tool" "$TEMP_DIR/"
        echo "  ✓ $tool"
    elif [ -d "$SCRIPT_DIR/$tool" ]; then
        cp -a "$SCRIPT_DIR/$tool" "$TEMP_DIR/"
        echo "  ✓ $tool/"
    else
        echo "  ✗ $tool (文件不存在，跳过)"
    fi
done

echo ""
echo "▸ 打包工具文件..."
cd "$TEMP_DIR"
tar czf tools.tar.gz *

echo "▸ 生成自解压安装脚本..."

# 生成安装脚本头部
cat > "$OUTPUT_TMP" << 'EOF'
#!/bin/bash
# AIO 运维工具集安装脚本（自解压）
# 版本: __PACKAGE_VERSION__

set -e

AIO_HOME="/opt/aio"
INSTALL_DIR="/opt/aio/ps_scripts"
AIO_USER_TMP="$AIO_HOME/user_tmp"
TEMP_DIR="/tmp/aio-scripts-install-$$"
RPC_PORT="${RPC_PORT:-6611}"
RPC_TIMEOUT="${RPC_TIMEOUT:-15}"
RAW_ARCH="$(uname -m)"
RPC_BIN="$AIO_HOME/airflow/tools/rpc/$RAW_ARCH/rpc"
if [[ ! -x "$RPC_BIN" && "$RAW_ARCH" == "amd64" && -x "$AIO_HOME/airflow/tools/rpc/x86_64/rpc" ]]; then
    RPC_BIN="$AIO_HOME/airflow/tools/rpc/x86_64/rpc"
elif [[ ! -x "$RPC_BIN" && "$RAW_ARCH" == "arm64" && -x "$AIO_HOME/airflow/tools/rpc/aarch64/rpc" ]]; then
    RPC_BIN="$AIO_HOME/airflow/tools/rpc/aarch64/rpc"
fi
CURRENT_UID="$(id -u)"
CURRENT_GID="$(id -g)"

echo "========================================"
echo " AIO 运维工具集 安装程序"
echo "========================================"
echo ""

shell_quote() {
    printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

dirs_ready() {
    [ -d "$INSTALL_DIR" ] && [ -w "$INSTALL_DIR" ] && \
    [ -d "$AIO_USER_TMP" ] && [ -w "$AIO_USER_TMP" ]
}

prepare_install_dirs() {
    if [ ! -d "$AIO_HOME" ]; then
        echo "错误: AIO目录不存在: $AIO_HOME"
        exit 1
    fi

    mkdir -p "$INSTALL_DIR" "$AIO_USER_TMP" 2>/dev/null || true
    chmod 755 "$INSTALL_DIR" 2>/dev/null || true
    chmod 700 "$AIO_USER_TMP" 2>/dev/null || true

    if dirs_ready; then
        return 0
    fi

    if [ -x "$RPC_BIN" ]; then
        echo "▸ 当前用户无法创建或写入安装目录，尝试通过本机 RPC 创建并授权..."
        local cmd
        local out
        cmd="mkdir -p $(shell_quote "$INSTALL_DIR") $(shell_quote "$AIO_USER_TMP") && chown $(shell_quote "${CURRENT_UID}:${CURRENT_GID}") $(shell_quote "$INSTALL_DIR") $(shell_quote "$AIO_USER_TMP") && chmod 755 $(shell_quote "$INSTALL_DIR") && chmod 700 $(shell_quote "$AIO_USER_TMP")"
        if ! out="$(timeout "$RPC_TIMEOUT" "$RPC_BIN" -h 127.0.0.1 -p "$RPC_PORT" -c "$cmd" 2>&1)"; then
            echo "错误: 本机 RPC 创建目录失败"
            echo "$out"
            exit 1
        fi
    fi

    if ! dirs_ready; then
        echo "错误: 当前用户不能写入安装目录或临时目录"
        echo "  安装目录: $INSTALL_DIR"
        echo "  临时目录: $AIO_USER_TMP"
        echo "请使用 root 执行，或确认本机 RPC $RPC_BIN 可用。"
        exit 1
    fi
}

prepare_install_dirs

echo "▸ 解压工具文件..."
mkdir -p "$TEMP_DIR"

# 获取脚本绝对路径（处理相对路径和绝对路径两种情况）
if [[ "$0" = /* ]]; then
    SCRIPT_PATH="$0"
else
    SCRIPT_PATH="$PWD/$0"
fi

# 提取嵌入的 tar.gz 数据
ARCHIVE_LINE=$(awk '/^__ARCHIVE_BELOW__/ {print NR + 1; exit 0; }' "$SCRIPT_PATH")
tail -n+"$ARCHIVE_LINE" "$SCRIPT_PATH" | tar xzf - -C "$TEMP_DIR"

cd "$TEMP_DIR"
echo "▸ 安装工具文件..."

# 核心工具列表
CORE_TOOLS=(
    "aio-tools.sh"
    "aio-diagnose.py"
    "aio-worker-performance.py"
    "aio-collect-logs.py"
    "aio-fsdeamon-cleanup.sh"
    "aio-unlock-tasks.py"
    "aio-collect-v.sh"
    "aio-collect-hang-logs.sh"
    "check_aiopool_usage.py"
    "aio-file-push.sh"
    "goldendb"
    "license.sh"
    "ops"
    "ops_arm"
)

# 复制核心工具
for tool in "${CORE_TOOLS[@]}"; do
    if [ -f "$tool" ]; then
        cp -f "$tool" "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/$tool"
        echo "  ✓ $tool"
    elif [ -d "$tool" ]; then
        rm -rf "$INSTALL_DIR/$tool"
        cp -a "$tool" "$INSTALL_DIR/"
        find "$INSTALL_DIR/$tool" -type f -name '*.sh' -exec chmod +x {} \;
        echo "  ✓ $tool/"
    else
        echo "  ✗ $tool (文件不存在)"
    fi
done

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)
        echo "  当前架构: $ARCH，默认使用: $INSTALL_DIR/ops"
        ;;
    aarch64|arm64)
        echo "  当前架构: $ARCH，默认使用: $INSTALL_DIR/ops_arm"
        ;;
    *)
        echo "  当前架构: $ARCH，请按平台选择 ops 或 ops_arm"
        ;;
esac

# 验证安装
echo ""
echo "▸ 验证安装..."
cd "$INSTALL_DIR"
MISSING=0
for tool in "${CORE_TOOLS[@]}"; do
    if [ ! -e "$tool" ]; then
        echo "  ✗ $tool 安装失败"
        MISSING=$((MISSING + 1))
    fi
done

# 清理临时目录
rm -rf "$TEMP_DIR"

if [ $MISSING -eq 0 ]; then
    echo ""
    echo "========================================"
    echo " ✓ 安装完成"
    echo "========================================"
    echo ""
    echo "运行工具集: $INSTALL_DIR/aio-tools.sh"
    echo "查看版本: $INSTALL_DIR/aio-tools.sh -v"
    echo ""
    exit 0
else
    echo ""
    echo "========================================"
    echo " ✗ 安装不完整 ($MISSING 个文件缺失)"
    echo "========================================"
    exit 1
fi

__ARCHIVE_BELOW__
EOF

sed -i "s/__PACKAGE_VERSION__/$VERSION/g" "$OUTPUT_TMP"

# 追加压缩包数据
cat tools.tar.gz >> "$OUTPUT_TMP"
chmod +x "$OUTPUT_TMP"
mv -f "$OUTPUT_TMP" "$OUTPUT_FILE"

# 清理临时目录
cd /
rm -rf "$TEMP_DIR"

# 显示结果
FILE_SIZE=$(ls -lh "$OUTPUT_FILE" | awk '{print $5}')
echo ""
echo "========================================"
echo " ✓ 构建完成"
echo "========================================"
echo ""
echo "输出文件: $OUTPUT_FILE"
echo "文件大小: $FILE_SIZE"
echo ""
echo "安装命令: bash $OUTPUT_FILE"
echo ""

# 是否发布到 GitHub Release
echo "----------------------------------------"
read -rp "是否发布到 GitHub Release? [y/N]: " publish
if [[ "$publish" =~ ^[Yy]$ ]]; then
    if [ -z "$GITHUB_TOKEN" ]; then
        echo ""
        echo "错误: 未找到 GitHub Token"
        echo "请设置环境变量或配置文件："
        echo "  方法1: export GITHUB_TOKEN=your_token"
        echo "  方法2: git config github.token your_token"
        echo "  方法3: echo 'your_token' > ~/.github_token"
        exit 1
    fi

    echo ""
    echo "▸ 发布到 GitHub Release v${VERSION}..."

    # 1. 检查 Release 是否已存在
    echo "  检查已有 Release..."
    RELEASE_ID=$(curl -s -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        "https://api.github.com/repos/$GITHUB_REPO/releases/tags/v${VERSION}" | \
        jq -r '.id // empty')

    if [ -n "$RELEASE_ID" ]; then
        echo "  删除旧 Release v${VERSION} (ID: $RELEASE_ID)..."
        curl -s -X DELETE \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            "https://api.github.com/repos/$GITHUB_REPO/releases/$RELEASE_ID" > /dev/null
    fi

    # 2. 创建新 Release
    echo "  创建新 Release v${VERSION}..."
RELEASE_BODY="## 本次更新

- **aio-diagnose.py 结束时间修复** - 已结束任务的 \`end_time\` 为空时使用 \`update_time\`，不再错误收集到当前时间的全部服务日志。
- **aio-diagnose.py 路径修复** - 日志收集器固定从当前 \`/opt/aio/ps_scripts\` 目录调用，不再依赖旧目录。
- **aio-diagnose.py 重跑修复** - 每次诊断前清理该任务未完成的临时目录，避免旧日志混入新诊断包。
- **安装目录调整** - 安装目标改为 \`/opt/aio/ps_scripts\`，不再依赖 \`/opt/aio/scripts\`。
- **安装权限修正** - 安装包会自动准备 \`/opt/aio/ps_scripts\` 和 \`/opt/aio/user_tmp\`；当前用户权限不足时，尝试通过本机 RPC 创建并授权。
- **GoldenDB 脚本分发** - \`aio-tools.sh\` 新增 \`GoldenDB脚本分发\`，通过 RPC 将 3 个本地清理脚本复制到 Worker 的 \`/opt/aio/ps_scripts/goldendb/\`。
- **分发安全边界** - GoldenDB 分发只上传脚本并校验 \`sha256sum\`，不远程执行快照或日志清理。
- **GoldenDB 清理脚本修正** - snapshot 清理拒绝未来日期，执行确认改为输入 \`END_DATE\`；log 清理日期语义统一为 \`<= END_DATE 23:59:59\`。
- **GoldenDB 普通用户执行** - snapshot/log 脚本在普通用户执行 \`-x\` 时，确认后通过本机 RPC 执行 root 删除动作，解决 \`zfs destroy\` 或文件删除权限不足。
- **RPC 平台兼容** - RPC 路径优先使用 \`uname -m\` 原始值，找不到时再兼容 \`amd64 -> x86_64\` 和 \`arm64 -> aarch64\`。
- **GoldenDB 日志清理自动 trim** - log/gtmlog 文件删除后，对本次实际清理过的挂载点执行 \`fstrim -v\`，让 zpool 尽快回收 zvol 空闲块。
- **File 推送工具** - \`aio-tools.sh\` 新增 \`File推送\`，支持本机文件路径和通配符，通过 RPC 上传到 Worker 的 \`/opt/aio/ps_scripts/patchfiles/\`，同名覆盖并校验 \`sha256sum\`。
- **File 推送命名调整** - \`aio-patch-push.sh\` 更名为 \`aio-file-push.sh\`，菜单入口统一显示为 \`File推送\`。
- **File 推送确认修正** - 上传确认输入会清理首尾空格和回车符，避免输入 \`yes\` 后被误判为取消。
- **File 推送退格兼容** - 上传确认输入会处理 Backspace/DEL 控制字符，兼容跳板机或终端把退格原样传给脚本的情况。
- **日志分析平台入口更新** - 统一使用 \`/opt/aio/ps_scripts/aio-tools.sh\` 作为运维/日志分析工具入口。

## 📦 安装方式

\`\`\`bash
wget https://github.com/$GITHUB_REPO/releases/download/v${VERSION}/aio-scripts.install
bash aio-scripts.install

# 安装后入口
bash /opt/aio/ps_scripts/aio-tools.sh
\`\`\`

## 包含工具

- aio-tools.sh - 运维工具菜单
- aio-diagnose.py - 任务诊断
- aio-worker-performance.py - Worker 性能分析（新增自动发现）
- aio-collect-logs.py - 日志收集（新增子任务过滤）
- aio-unlock-tasks.py - 任务解锁
- aio-fsdeamon-cleanup.sh - fsdeamon 清理
- aio-collect-hang-logs.sh - 主机异常日志收集
- aio-file-push.sh - 文件 RPC 推送
- check_aiopool_usage.py - aiopool 空间检查
- aio-collect-v.sh - 版本信息收集
- goldendb/ - GoldenDB 本地清理脚本与分发工具
- ops - 文件加解密工具

## 📝 更新日志

- aio-diagnose.py 1.0.2: 修复空 end_time、旧收集器路径和重跑残留问题
- aio-tools.sh 1.2.5: File 推送入口命名调整
- aio-tools.sh 1.2.4: 新增 File 推送入口
- aio-file-push.sh: 由 aio-patch-push.sh 更名，菜单入口统一为 File推送
- aio-file-push.sh 1.0.2: 上传确认输入兼容 Backspace/DEL 控制字符
- aio-file-push.sh 1.0.1: 修正确认输入带空格或回车符时被误判取消的问题
- aio-file-push.sh 1.0.0: 支持单文件和通配符，通过 RPC 上传到 Worker 的 /opt/aio/ps_scripts/patchfiles/，同名覆盖并校验 sha256sum
- aio-tools.sh 1.2.3: 新增 GoldenDB 脚本分发入口
- goldendb_distribute_scripts.sh 1.0.1: 分发 3 个 GoldenDB 本地脚本到 Worker；本机临时目录权限不足时使用本机 RPC 修正
- goldendb_snapshot_clean.sh: 增加未来日期保护，执行确认改为输入 END_DATE；普通用户执行删除时通过本机 RPC 执行 zfs destroy
- goldendb_log_clean.sh: 清理日期统一到 END_DATE 当天 23:59:59；普通用户执行删除时通过本机 RPC 删除文件；删除后自动 fstrim 已清理挂载点
- RPC 路径: 优先使用 uname -m 原始值，找不到时再做 amd64/arm64 fallback，避免改变已有 aarch64 ARM Worker 行为
- 安装包: 安装目录调整为 /opt/aio/ps_scripts
- 安装包: 创建 /opt/aio/ps_scripts 或 /opt/aio/user_tmp 权限不足时，使用本机 RPC fallback 授权"

    RELEASE_RESPONSE=$(curl -s -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        "https://api.github.com/repos/$GITHUB_REPO/releases" \
        -d "{
            \"tag_name\": \"v${VERSION}\",
            \"name\": \"AIO 运维工具集 v${VERSION}\",
            \"body\": $(echo "$RELEASE_BODY" | jq -Rs .),
            \"draft\": false,
            \"prerelease\": false
        }")

    NEW_RELEASE_ID=$(echo "$RELEASE_RESPONSE" | jq -r '.id')
    if [ -z "$NEW_RELEASE_ID" ] || [ "$NEW_RELEASE_ID" = "null" ]; then
        echo "  错误: 创建 Release 失败"
        echo "$RELEASE_RESPONSE" | jq .
        exit 1
    fi

    # 3. 上传安装包
    echo "  上传安装包..."
    curl -s -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@$OUTPUT_FILE" \
        "https://uploads.github.com/repos/$GITHUB_REPO/releases/$NEW_RELEASE_ID/assets?name=aio-scripts.install" > /dev/null

    echo ""
    echo "✓ 发布完成!"
    echo "  Release: https://github.com/$GITHUB_REPO/releases/tag/v${VERSION}"
    echo "  下载: https://github.com/$GITHUB_REPO/releases/download/v${VERSION}/aio-scripts.install"
    echo ""
fi

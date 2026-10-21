#!/bin/bash
# 构建 aio-scripts.install 自解压安装包并发布到 GitHub Release
# 版本: 3.0.0

set -e

VERSION="2.2.2"
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
    "lib"
    "docs"
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
    "lib"
    "docs"
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
read -rep "是否发布到 GitHub Release? [y/N]: " publish
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
RELEASE_BODY="## 本次更新（v2.2.2）

- **File 推送卡住修复（重要）** - RPC 调用改用 \`timeout --foreground --kill-after\`。此前 \`timeout\` 把 RPC 放进独立进程组，终端 Ctrl-C 无法立即打断，必须等满 30 秒；现在 Ctrl-C 立即退出，异常 RPC 进程 5 秒后被强制回收。
- **aio-file-push.sh 1.1.1** - 显式 \`-w\` 指定的 Worker 也会先做 5 秒 RPC 预检，不可达主机在上传确认前直接列失败；远程目录准备改为 10 秒超时，已存在目录只检查不 \`chmod\`，避免远端挂载点异常时卡住。
- **lib/common.sh 1.0.1** - 统一 RPC 超时中断语义，其他使用公共库的工具同样受益。

## v2.2.1 主要变更（往期）

- **日志收集「收集范围」修复（重要）** - 此前只有输入严格等于「全部」才收全部子任务，输入「全部子任务」（照抄提示词）或其它写法会被静默当成 \`--failed-only\`；任务若没有失败子任务就只报「过滤后没有匹配的子任务」，表现为「选了全部却什么都没收到」。现在输入词统一为英文关键字：回车/\`failed\` 只收失败子任务，\`all\` 收全部；无法识别时直接报错，不再静默降级，并回显实际生效的范围。
- **aio-collect-logs.py** - \`--failed-only\` 过滤后为 0 时，明确提示「该任务没有失败子任务（可能仍在运行或已全部成功）」并指引输入 \`all\`。

## v2.2.0 主要变更（往期）

- **新增公共库 lib/** - \`lib/common.sh\` + \`lib/aio_common.py\`。aio.env 解析、ENC 密码解密、mysql defaults-file、RPC 封装、Worker 发现此前在 5+ 个脚本里各写一份且行为不一致（stderr 有的合并有的丢弃），现统一收敛，一处修改处处生效。
- **aio-diagnose.py 全面脱敏（安全修复）** - 数据库快照（\`SELECT *\` 的 attribute JSON 可能带凭据）、任务日志、服务日志、系统日志切片统一按 hang-logs 同款规则脱敏（password/token/secret/authorization/access key/URL 内嵌凭据）；task_logs 内 .gz 解压为明文后脱敏。分析包传出客户环境前不再携带明文凭据。
- **aio-collect-v.sh 并行化** - 主机间按 \`COLLECT_PAR\`（默认 8）并行；主机内 18 条版本命令合并为一次 RPC 批量执行。20 台主机场景从数分钟级降到十秒级。
- **交互输入退格乱码修复** - 全部交互 \`read\` 启用 readline（\`-e\`），Python \`input()\` 启用 readline；退格、中文编辑不再乱码。关键确认输入仍保留跳板机 Backspace/DEL 透传清理。
- **aio-worker-performance.py 修复** - 删除 \`query_tasks()\` 重复函数体死代码；Worker IP 拼 SQL/远端命令前统一格式校验。
- **临时文件清理修复** - unlock-tasks / check_aiopool / 子 shell 中的 mysql defaults 临时文件不再残留 /tmp。

## 📦 安装方式

\`\`\`bash
wget https://github.com/$GITHUB_REPO/releases/download/v${VERSION}/aio-scripts.install
bash aio-scripts.install

# 安装后入口
bash /opt/aio/ps_scripts/aio-tools.sh
\`\`\`

## 包含工具

- lib/ - 公共库（common.sh / aio_common.py）
- aio-tools.sh - 运维工具菜单
- aio-diagnose.py - 任务完整分析包（已脱敏）
- aio-worker-performance.py - Worker 性能分析
- aio-collect-logs.py - 日志收集
- aio-unlock-tasks.py - 任务解锁
- aio-fsdeamon-cleanup.sh - fsdeamon 清理
- aio-collect-hang-logs.sh - 主机异常日志收集
- aio-file-push.sh - 文件 RPC 推送
- check_aiopool_usage.py - aiopool 空间检查
- aio-collect-v.sh - 版本信息收集（并行）
- goldendb/ - GoldenDB 本地清理脚本与分发工具
- ops / ops_arm - 文件加解密工具

## 📝 更新日志

- lib/common.sh 1.0.1: RPC 超时支持 Ctrl-C 立即中断，超时后强制回收
- lib/common.sh 1.0.0 / lib/aio_common.py 1.0.0: 新增公共库
- aio-diagnose.py 1.1.0: 数据库快照与全部文本日志脱敏；接入公共库
- aio-collect-v.sh 1.6.0: 主机并行 + RPC 批量执行；接入公共库
- aio-worker-performance.py 1.1.0: 删除死代码；IP 校验；接入公共库
- aio-collect-logs.py 2.2.1: 收集范围提示改英文关键字；--failed-only 空结果给出明确指引
- aio-collect-logs.py 2.2.0: 接入公共库；RPC 路径支持 amd64/arm64 fallback
- aio-unlock-tasks.py 1.1.0: input() 启用 readline；接入公共库；清理临时文件
- check_aiopool_usage.py 1.2.0: 接入公共库；退出清理临时文件
- aio-tools.sh 1.3.1: 日志收集范围提示改英文关键字(all/failed)，非法输入报错不再静默降级
- aio-tools.sh 1.3.0: 全部交互输入启用 readline；接入公共库
- aio-file-push.sh 1.1.1: RPC 可被 Ctrl-C 立即中断；显式 Worker 增加 5 秒预检
- aio-file-push.sh 1.1.0: 接入公共库；交互输入启用 readline
- aio-fsdeamon-cleanup.sh 1.5.1: 交互输入启用 readline；RPC 路径走公共库
- aio-collect-hang-logs.sh 1.2.0: 交互输入启用 readline（保持自包含）
- goldendb_distribute_scripts.sh 1.0.2 及清理脚本: 交互输入启用 readline（保持自包含）"

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

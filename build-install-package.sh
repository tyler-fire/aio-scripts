#!/bin/bash
# 构建 aio-scripts.install 自解压安装包并发布到 GitHub Release
# 版本: 3.0.0

set -e

VERSION="2.0.5"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FILE="$SCRIPT_DIR/aio-scripts.install"
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
    "check_aiopool_usage.py"
    "ops"
)

echo "▸ 复制工具文件..."
for tool in "${CORE_TOOLS[@]}"; do
    if [ -f "$SCRIPT_DIR/$tool" ]; then
        cp -f "$SCRIPT_DIR/$tool" "$TEMP_DIR/"
        echo "  ✓ $tool"
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
cat > "$OUTPUT_FILE" << 'EOF'
#!/bin/bash
# AIO 运维工具集安装脚本（自解压）
# 版本: 2.0.5

set -e

INSTALL_DIR="/opt/aio/scripts"
TEMP_DIR="/tmp/aio-scripts-install-$$"

echo "========================================"
echo " AIO 运维工具集 安装程序"
echo "========================================"
echo ""

# 检查目标目录
if [ ! -d "$INSTALL_DIR" ]; then
    echo "错误: 目标目录不存在: $INSTALL_DIR"
    exit 1
fi

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
    "check_aiopool_usage.py"
    "ops"
)

# 复制核心工具
for tool in "${CORE_TOOLS[@]}"; do
    if [ -f "$tool" ]; then
        cp -f "$tool" "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/$tool"
        echo "  ✓ $tool"
    else
        echo "  ✗ $tool (文件不存在)"
    fi
done

# 验证安装
echo ""
echo "▸ 验证安装..."
cd "$INSTALL_DIR"
MISSING=0
for tool in "${CORE_TOOLS[@]}"; do
    if [ ! -f "$tool" ]; then
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

# 追加压缩包数据
cat tools.tar.gz >> "$OUTPUT_FILE"
chmod +x "$OUTPUT_FILE"

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
    RELEASE_BODY="## 🚀 本次更新

- **aiopool 存储汇总表** - check_aiopool_usage.py 在所有 Worker 详细输出后新增汇总表，每行一个 Worker，列出总容量/已用/可用/使用率/状态，多 Worker 时一眼对比
- **使用率高亮** - 汇总表中使用率 >=80% 标记 \`!\`、>=90% 标记 \`!!\`，失败的 Worker 也会出现在表中并显示原因

## 📦 安装方式

\`\`\`bash
wget https://github.com/$GITHUB_REPO/releases/download/v${VERSION}/aio-scripts.install
bash aio-scripts.install
\`\`\`

## 🛠️ 包含工具

- aio-tools.sh - 运维工具菜单
- aio-diagnose.py - 问题诊断（AI 辅助）
- aio-worker-performance.py - Worker 性能分析（新增自动发现）
- aio-collect-logs.py - 日志收集
- aio-unlock-tasks.py - 任务解锁
- aio-fsdeamon-cleanup.sh - fsdeamon 清理
- check_aiopool_usage.py - aiopool 空间检查
- aio-collect-v.sh - 版本信息收集
- ops - 数据库专项脚本

## 📝 更新日志

- check_aiopool_usage.py 新增多 Worker 存储汇总表
- 汇总表使用率高亮 + 失败 Worker 纳入
- 此前: Worker 性能分析自动发现、表格化输出、RPC 错误提示"

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

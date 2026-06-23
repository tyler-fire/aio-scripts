#!/bin/bash
# 构建 aio-scripts.install 自解压安装包
# 版本: 2.0.4

set -e

VERSION="2.0.4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FILE="$SCRIPT_DIR/aio-scripts.install"
TEMP_DIR="/tmp/aio-scripts-build-$$"

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
# 版本: 2.0.4

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

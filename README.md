# AIO 运维工具集

AIO 数据库备份与恢复平台的运维工具集，提供问题诊断、性能分析、日志收集等功能。

## 快速安装

下载并运行安装脚本：

```bash
# 下载安装包
wget https://github.com/tyler-fire/aio-scripts/raw/main/aio-scripts.install

# 或使用 curl
curl -L -O https://github.com/tyler-fire/aio-scripts/raw/main/aio-scripts.install

# 执行安装
bash aio-scripts.install
```

## 包含工具

安装包包含以下工具：

| 工具 | 说明 |
|------|------|
| **aio-tools.sh** | 运维工具菜单（推荐使用） |
| **aio-diagnose.py** | 任务诊断工具 - 打包任务日志、数据库快照、服务日志和系统日志 |
| **aio-worker-performance.py** | Worker性能分析 - 基于sar数据的性能趋势分析 |
| **aio-collect-logs.py** | 日志收集工具 - 收集指定任务的完整日志 |
| **aio-unlock-tasks.py** | 任务解锁工具 - 解锁卡住的任务 |
| **aio-fsdeamon-cleanup.sh** | fsdeamon清理工具 - 清理未监控的备份源 |
| **check_aiopool_usage.py** | aiopool空间检查 - 统计Worker磁盘占用 |
| **aio-collect-v.sh** | 版本信息收集 - 收集环境和版本信息 |
| **ops / ops_arm** | 文件加解密工具，支持自定义密钥 |

## 使用方式

安装完成后，运行工具菜单：

```bash
bash /opt/aio/scripts/aio-tools.sh
```

或直接运行单个工具：

```bash
# Worker性能分析（自动发现所有Worker）
python3 /opt/aio/scripts/aio-worker-performance.py --days 7

# 问题诊断
python3 /opt/aio/scripts/aio-diagnose.py <task_id>

# 日志收集
python3 /opt/aio/scripts/aio-collect-logs.py <task_id>
```

## 版本信息

- 当前版本: **2.1.1**
- 发布日期: 2026-07-06

## 更新日志

### v2.1.1 (2026-07-06)
- 修复 aio-diagnose.py 服务日志路径识别，支持 `logs/service/*/*.log` 和 `.log.gz` 轮转日志
- 修复 aio-diagnose.py 服务日志时间窗口过滤
- 修复 check_aiopool_usage.py 在 Worker 快照命令超时时直接退出的问题
- 补充 ops / ops_arm 自定义密钥长度说明：16、24 或 32 字节

### v2.0.4 (2026-06-23)
- 新增 Worker 性能分析工具，支持自动发现 Worker
- 优化性能分析输出格式，改用表格展示
- 增强 RPC 连接错误提示
- 更新工具菜单，支持自动发现功能

### v2.0.3
- 优化问题诊断工具
- 改进日志收集功能

## 系统要求

- AIO 平台 5.5.x 或更高版本
- Python 3.6+
- Bash 4.0+

## 技术支持

如有问题或建议，请联系 AIO 技术支持团队。

## License

内部工具，仅供 AIO 平台运维使用。

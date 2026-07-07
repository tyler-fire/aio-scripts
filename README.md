# AIO 运维工具集

AIO 数据库备份与恢复平台的运维工具集，提供问题诊断、性能分析、日志收集、脚本分发等功能。

## 快速安装

下载并运行安装脚本：

```bash
wget https://github.com/tyler-fire/aio-scripts/raw/main/aio-scripts.install
bash aio-scripts.install
```

也可以使用 Release 包：

```bash
wget https://github.com/tyler-fire/aio-scripts/releases/download/v2.1.6/aio-scripts.install
bash aio-scripts.install
```

安装目标目录：

```bash
/opt/aio/ps_scripts
```

## 包含工具

| 工具 | 说明 |
|------|------|
| **aio-tools.sh** | 运维工具菜单（推荐使用） |
| **aio-diagnose.py** | 任务诊断工具 |
| **aio-worker-performance.py** | Worker 性能分析 |
| **aio-collect-logs.py** | 日志收集工具 |
| **aio-unlock-tasks.py** | 任务解锁工具 |
| **aio-fsdeamon-cleanup.sh** | fsdeamon 清理工具 |
| **check_aiopool_usage.py** | aiopool 空间检查 |
| **aio-collect-v.sh** | 版本信息收集 |
| **aio-collect-hang-logs.sh** | 主机异常日志收集 |
| **goldendb/** | GoldenDB 快照/日志本地清理脚本，以及脚本分发工具 |
| **ops / ops_arm** | 文件加解密工具 |

## 使用方式

安装完成后，运行工具菜单：

```bash
bash /opt/aio/ps_scripts/aio-tools.sh
```

GoldenDB 脚本分发：

```bash
bash /opt/aio/ps_scripts/aio-tools.sh
# 选择 8) GoldenDB脚本分发
```

分发到 Worker 后，在 Worker 本机执行：

```bash
cd /opt/aio/ps_scripts/goldendb

bash goldendb_snapshot_list.sh
bash goldendb_snapshot_clean.sh -e 2026-07-07
bash goldendb_log_clean.sh -e 2026-07-07
```

删除操作需要显式加 `-x`，并输入日期确认。

## 版本信息

- 当前版本: **2.1.6**
- 发布日期: 2026-07-07

## 更新日志

### v2.1.6 (2026-07-07)

- RPC 工具路径增加平台映射，兼容 `x86_64/amd64` 和 `aarch64/arm64`。
- GoldenDB 清理脚本在 ARM Worker 上会优先使用 `/opt/aio/airflow/tools/rpc/aarch64/rpc`，必要时 fallback 到 `arm64/rpc`。
- GoldenDB 分发脚本和安装包本机 RPC fallback 同步支持 ARM 平台。

### v2.1.5 (2026-07-07)

- GoldenDB 快照清理支持普通用户执行：确认后通过本机 RPC 以 root 身份执行 `zfs destroy`。
- GoldenDB 日志清理支持普通用户执行：确认后通过本机 RPC 以 root 身份删除匹配文件。
- 预览、候选列表、clone 跳过、日期二次确认逻辑不变。

### v2.1.4 (2026-07-07)

- 安装包会自动准备 `/opt/aio/ps_scripts` 和 `/opt/aio/user_tmp`。
- 当前用户权限不足时，安装包会尝试通过本机 RPC 创建目录并授权给当前用户。
- GoldenDB 脚本分发在创建 `/opt/aio/user_tmp` 失败时，也会尝试通过本机 RPC 修正权限。

### v2.1.3 (2026-07-07)

- 安装目录从 `/opt/aio/scripts` 调整为 `/opt/aio/ps_scripts`。
- 新增 GoldenDB 脚本分发入口：`aio-tools.sh` 菜单选择 `8`，将 3 个 GoldenDB 本地脚本分发到 Worker 的 `/opt/aio/ps_scripts/goldendb/`。
- GoldenDB 分发只上传脚本并校验 `sha256sum`，不远程执行清理。
- GoldenDB 快照清理脚本增加未来日期保护，执行确认改为输入 `END_DATE`。
- GoldenDB 日志清理脚本日期语义统一为 `<= END_DATE 23:59:59`。

### v2.1.2 (2026-07-06)

- 新增 `aio-collect-hang-logs.sh`，按窗口收集主机 hang、断连、异常重启分析日志。
- 工具菜单新增“主机异常日志”入口。

## 系统要求

- AIO 平台 5.5.x 或更高版本
- Python 3.6+
- Bash 4.0+

## License

内部工具，仅供 AIO 平台运维使用。

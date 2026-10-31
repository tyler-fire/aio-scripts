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
wget https://github.com/tyler-fire/aio-scripts/releases/download/v2.2.4/aio-scripts.install
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
| **lib/** | 公共库：`common.sh`（shell）、`aio_common.py`（python）。aio.env 解析、ENC 解密、mysql defaults-file、RPC 封装、Worker 发现、脱敏、交互输入统一在这里维护 |
| **aio-diagnose.py** | 任务完整分析包（数据库快照与日志已脱敏），产物上传到 AIO Log 分析平台 |
| **aio-worker-performance.py** | Worker 性能分析 |
| **aio-collect-logs.py** | 按任务 ID 定向收集阶段日志 |
| **aio-unlock-tasks.py** | 任务解锁工具 |
| **aio-fsdeamon-cleanup.sh** | fsdeamon 数据源/监控目录清理、Offline 失效记录识别、重复实例检查 |
| **check_aiopool_usage.py** | aiopool 空间检查 |
| **aio-collect-v.sh** | 版本信息收集 |
| **aio-collect-hang-logs.sh** | 按主机和时间窗口收集异常日志 |
| **aio-file-push.sh** | 文件 RPC 推送到 Worker |
| **goldendb/** | GoldenDB 快照/日志本地清理脚本，以及脚本分发工具 |
| **docs/** | 运维排障手册 |
| **ops / ops_arm** | 文件加解密工具 |

## 使用方式

安装完成后，运行工具菜单：

```bash
bash /opt/aio/ps_scripts/aio-tools.sh
```

三个日志入口保持独立：

- 菜单 `1`：定向任务日志，可筛选失败子任务和阶段。
- 菜单 `2`：任务完整分析包，输入 `aio_total_task.id`，生成的整个 tar.gz 直接上传到 AIO Log 分析平台。
- 菜单 `12`：主机异常日志，按目标主机和起止时间收集；远端脚本临时上传到 `/opt/aio/user_tmp`。

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

File 推送：

```bash
bash /opt/aio/ps_scripts/aio-tools.sh
# 选择 9) File推送

# 或直接执行，支持多个文件和通配符
bash /opt/aio/ps_scripts/aio-file-push.sh -f '/opt/aio/user_tmp/*.enc'
bash /opt/aio/ps_scripts/aio-file-push.sh -f /tmp/a.enc -f /tmp/b.tar.gz -w 10.7.16.217
bash /opt/aio/ps_scripts/aio-file-push.sh -f /opt/aio/user_tmp/patch.tar.gz -w 10.7.16.217

# 交互模式只需输入文件/通配符，多个用空格分隔；匹配后显示数量与总大小
bash /opt/aio/ps_scripts/aio-file-push.sh
```

多主机版本收集：

```bash
bash /opt/aio/ps_scripts/aio-tools.sh
# 选择 6) 版本收集
# 输入多个 IP 时使用逗号或空格分隔；直接回车自动读取数据库中的全部主机

# 也可以直接执行
bash /opt/aio/ps_scripts/aio-collect-v.sh 10.7.16.217 10.7.16.66
bash /opt/aio/ps_scripts/aio-collect-v.sh '10.7.16.217,10.7.16.66'
```

手工输入的主机优先使用 MySQL 中登记的角色。未登记主机会通过 RPC 检查远端环境并识别为 Server、Worker 或 Agent；RPC 不可达时显示为 Unknown。

## 版本信息

- 当前版本: **2.2.4**
- 发布日期: 2026-10-31

## 开发约定

- 公共逻辑（aio.env 解析、ENC 解密、mysql defaults-file、RPC 封装、Worker 发现、脱敏、交互输入）一律放 `lib/`，不要在单个脚本里复制一份。
- `aio-collect-hang-logs.sh` 和 `goldendb/` 三个清理脚本会被单独上传到远端主机执行，必须保持自包含，不允许依赖 `lib/`。
- 交互输入统一 `read -rep`（readline，退格/中文不乱码）；Python 用 `aio_common.setup_readline()`；关键确认再叠加 `aio_scrub_input` 清理跳板机透传的 Backspace/DEL。
- 会传出客户环境的产物（诊断包、日志包）必须经过 `aio_common.sanitize_text/sanitize_file`（与 hang-logs 的 sed 规则同源）。
- 远端命令/SQL 中拼接主机名前必须过 `aio_valid_host` / `aio_common.valid_host`。

## 更新日志

### v2.2.4 (2026-10-31)

- `aio-fsdeamon-cleanup.sh` 1.7.2：统一使用“失效记录”表述，不再使用旧术语。
- `aio-fsdeamon-cleanup.sh` 1.7.1：进程数与 `2 + 数据源数` 不一致时显示差值并要求确认；日志出现 `host:-port:0`/`InitDeamonData failed` 时提示 `.context` 残留。
- `aio-fsdeamon-cleanup.sh` 1.7.0：按备份计划清理；同一数据源有多个监控目录时使用 `del-trackup`，单目录或整源使用 `del-source`；显示进程数/启动时间并提示源端核对。
- `aio-fsdeamon-cleanup.sh` 1.6.3：区分活动数据源与 `Offline` 失效记录；残留不再显示“完成/重启会清掉”，明确由 fsdeamon 内部维护。
- 正常活动源删除同时传 `--source-name=UUID` 和 `--source=IP:6611`；child 已失效时回退 UUID-only 清理。
- 删除按 `Online -> Offline(失效记录) -> absent` 异步轮询；有地址的失效记录优先用 UUID+原地址清理，实测仅 UUID 可能返回 true 但不移除记录。
- 清理前检查顶层 `fsdeamon` 实例；检测到多套实例时告警并要求确认，避免两套进程共享 data-path 造成状态污染。
- 单实例但由 SSH 会话启动时给出提示；删除后复查 `online/offline/stale/absent`，不再只按 UUID 是否存在判断。
- `aio-tools.sh` 1.3.3：菜单项 4 改为“清理 Worker 侧数据源/监控目录（不删源端目录）”。

### v2.2.3 (2026-10-29)

- `aio-file-push.sh` 1.2.0：帮助和交互提示改为中文，明确支持多个文件和通配符。
- 交互输入改为“文件/通配符（多个用空格分隔）”；匹配后只显示文件数量和总大小，不再逐个列出路径，避免大量文件刷屏。
- Worker 选择提示改为“选择 Worker（逗号分隔或 all）”，确认改为 `[Y/n]`，直接回车即推送。
- 已在 Server 本机和实际 Worker 上验证单文件、通配符多文件推送及 SHA256 校验。

### v2.2.2 (2026-10-21)

- `aio-file-push.sh` 1.1.1（File 推送卡住修复）：RPC 调用改用 `timeout --foreground --kill-after`。此前 `timeout` 会把 RPC 放进独立进程组，终端 Ctrl-C 打不到 RPC，必须等满 `RPC_TIMEOUT`（默认 30 秒）才继续，多台 Worker 时表现为“卡死”；异常 RPC 进程现在会在超时后 5 秒被强制回收。
- 显式 `-w` 指定的 Worker 现在也会先做 5 秒 RPC 预检，不可达主机在输入 `yes` 前就会列出失败，不再逐台等待 30 秒。
- 远程目录准备改为 10 秒超时；`patchfiles` 已存在时只做目录检查，不再重复 `mkdir/chmod`，避免远端挂载点异常时卡住。超时会明确提示检查远端目录、网络和 `aio-speedd` 的 6611 端口。
- `lib/common.sh` 1.0.1：公共 RPC 封装同步修复，其他使用 `aio_rpc_exec` 的工具也支持 Ctrl-C 立即中断。

### v2.2.1 (2026-10-16)

- `aio-tools.sh` 1.3.1（日志收集范围提示与解析修复）：此前「收集范围」只有在输入严格等于 `全部` 时才收集全部子任务，输入 `全部子任务`（照抄提示词）或其它写法会被静默当成 `--failed-only`，任务若无可收集失败子任务就只报「过滤后没有匹配的子任务」，表现为「全部收集却什么都没收到」。现在提示改为 `[failed=仅失败子任务(回车默认) / all=全部子任务]`，输入词统一为英文关键字：回车/`failed` 只收失败子任务，`all` 收全部；解析会归一化输入（去空白、去 `子任务`/`任务` 字样、转小写），同时兼容 `all/full` 与 `failed/failed-only`；无法识别时直接报错并提示输入 `all` 或 `failed`，不再静默降级；并回显实际生效的收集范围。
- `aio-collect-logs.py` 2.2.1：`--failed-only` 过滤后为 0 时，明确提示「该任务没有失败子任务（可能仍在运行或已全部成功）」并指引「输入 all 收全部」。

### v2.2.0 (2026-07-27)

规范化重构：

- 新增 `lib/common.sh` 1.0.0 + `lib/aio_common.py` 1.0.0 公共库，收敛 5+ 个脚本各自复制的 aio.env 解析、ENC 解密、mysql defaults-file、RPC 封装、Worker 发现逻辑，统一 stderr 处理（此前有的 `2>&1` 有的 `2>/dev/null`，版本号打在 stderr 会被丢掉）。
- `aio-diagnose.py` 1.1.0（安全修复）：数据库快照（attribute JSON 可能带凭据）、任务日志、服务日志、系统日志切片全部按 hang-logs 同款规则脱敏；task_logs 内 `.gz` 解压为明文后脱敏。
- `aio-collect-v.sh` 1.6.0：主机间按 `COLLECT_PAR`（默认 8）并行，主机内 18 条版本命令合并为一次 RPC 批量执行；实测 20 台主机（含 7 台不可达）从数分钟降到约 5 秒。
- 交互输入退格/中文乱码修复：所有 `read` 启用 readline（`-e`），`aio-unlock-tasks.py` 的 `input()` 启用 readline。
- `aio-worker-performance.py` 1.1.0：删除 `query_tasks()` 重复函数体死代码；Worker IP 拼 SQL/远端命令前统一校验。
- 临时文件清理修复：`aio-unlock-tasks.py`、`check_aiopool_usage.py` 及子 shell 中创建的 mysql defaults 文件不再残留 `/tmp`。
- 其余：`aio-collect-logs.py` 2.2.0、`aio-tools.sh` 1.3.0、`aio-file-push.sh` 1.1.0、`aio-fsdeamon-cleanup.sh` 1.5.1、`aio-collect-hang-logs.sh` 1.2.0、`goldendb_distribute_scripts.sh` 1.0.2。

### v2.1.15 (2026-07-13)

- 菜单 `6` 支持一次输入多个 Worker 或 Agent IP，逗号和空格分隔均可。
- 直接回车时维持原行为，自动从 MySQL 收集全部 Server、Worker 和 Agent。
- 手工输入的 IP 优先使用 MySQL 角色；未登记主机通过 RPC 检查远端 AIO 环境并自动分类。
- RPC 不可达且无法识别角色的主机显示为 Unknown，不再误报为 Agent。
- `aio-collect-v.sh` 升级到 1.5.0，`aio-tools.sh` 升级到 1.2.8。

### v2.1.14 (2026-07-10)

- 菜单 `2` 更名为“任务完整分析包”，明确整个 tar.gz 用于上传到 AIO Log 分析平台。
- `aio-diagnose.py` 升级到 1.0.3，菜单、帮助、包内说明和完成提示统一更新。
- 菜单 `12` 远端脚本改为上传到 `/opt/aio/user_tmp`，并补充目录校验、SHA-256 校验和失败清理。
- `aio-collect-hang-logs.sh` 升级到 1.1.1，失败时清理工作目录，成功打包后删除未压缩的临时目录。

### v2.1.13 (2026-07-10)

- `aio-diagnose.py` 升级到 1.0.2。已结束任务的 `end_time` 为空时改用 `update_time`，不再把日志窗口错误延长到当前时间。
- 日志收集器从 `aio-diagnose.py` 所在目录调用，运行目录统一为 `/opt/aio/ps_scripts`。
- 重跑同一任务诊断前清理未完成的临时工作目录，避免旧日志混入新诊断包。

### v2.1.12 (2026-07-09)

- `aio-patch-push.sh` 更名为 `aio-file-push.sh`，`aio-tools.sh` 菜单入口改为 `9) File推送`。

### v2.1.11 (2026-07-09)

- `aio-file-push.sh` 升级到 1.0.2，上传确认输入会处理 Backspace/DEL 控制字符，兼容 `yea` 退格后改成 `yes` 的输入场景。

### v2.1.10 (2026-07-09)

- `aio-file-push.sh` 升级到 1.0.1，上传确认输入会清理首尾空格和回车符，避免输入 `yes` 后被误判为取消。

### v2.1.9 (2026-07-09)

- 新增 `aio-file-push.sh`，支持单文件和 `*.enc` 等通配符，通过 RPC 推送到 Worker 的 `/opt/aio/ps_scripts/patchfiles/`。
- 同名文件直接覆盖，上传后使用 `sha256sum` 校验本地和远端文件。
- `aio-tools.sh` 菜单新增 `9) File推送`。

### v2.1.8 (2026-07-07)

- GoldenDB 日志清理脚本在 `-x` 删除文件后，会自动对本次实际清理过的 log/gtmlog 挂载点执行 `fstrim -v`。
- 普通用户执行时，`fstrim` 同样通过本机 RPC 以 root 身份执行。
- `fstrim` 失败只输出告警，不回滚已经完成的文件删除。

### v2.1.7 (2026-07-07)

- RPC 工具路径恢复为优先使用 `uname -m` 原始值，例如 ARM Linux 上通常是 `aarch64`。
- 只有原始路径不存在时，才 fallback `amd64 -> x86_64`、`arm64 -> aarch64`。
- 避免改变已有 ARM Worker 的 `/opt/aio/airflow/tools/rpc/$(uname -m)/rpc` 行为。

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

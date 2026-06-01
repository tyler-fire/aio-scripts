# AIO 运维工具集

AIO 数据库备份平台的运维辅助工具集合。

## 包含工具

| 工具 | 功能 | 版本 |
|------|------|------|
| aio-tools.sh | 主入口菜单 | 1.0.0 |
| aio-collect-logs.py | 根据任务ID收集Worker日志 | 2.0.0 |
| aio-fsdeamon-cleanup.sh | 清理fsdeamon残留挂载和进程 | 1.0.0 |
| aio-unlock-tasks.py | 将卡住的running任务标记为failed | 1.0.0 |
| aio-collect-v.sh | 收集本机和Worker的工具版本 | 1.1.0 |

## 快速安装

```bash
# 下载安装包
wget https://github.com/tyler-fire/aio-scripts/releases/download/v1.0.0/aio-scripts.install

# 执行安装（自动解压到 /opt/aio/scripts）
bash aio-scripts.install
```

## 使用方式

```bash
cd /opt/aio/scripts

# 进入交互菜单
./aio-tools.sh

# 查看工具版本
./aio-tools.sh -v
```

## 工具说明

### 1. 日志收集 (aio-collect-logs.py)

根据任务ID，通过RPC从所有相关Worker节点收集各阶段日志，打包为tar.gz供下载分析。

```bash
./aio-collect-logs.py <任务ID>
./aio-collect-logs.py <任务ID> --stages "备份,恢复"
```

### 2. fsdeamon清理 (aio-fsdeamon-cleanup.sh)

交互式列出fsdeamon管理的所有在线/离线数据源，允许用户选择删除。

```bash
./aio-fsdeamon-cleanup.sh
```

### 3. 任务解锁 (aio-unlock-tasks.py)

将卡住的running任务标记为failed，用于任务状态异常时手动干预。

```bash
./aio-unlock-tasks.py
```

### 4. 版本收集 (aio-collect-v.sh)

收集本机和所有Worker节点的工具版本，横排显示方便对比差异。

```bash
# 自动发现本机和Worker
./aio-collect-v.sh

# 指定IP
./aio-collect-v.sh 10.7.16.217 10.7.16.218
```

## 环境要求

- AIO 数据库备份平台
- Python 3.6+
- MySQL 客户端
- RPC 工具（aio-speed）

## 目录结构

```
/opt/aio/scripts/
├── aio-tools.sh              # 主入口
├── aio-collect-logs.py       # 日志收集
├── aio-fsdeamon-cleanup.sh   # fsdeamon清理
├── aio-unlock-tasks.py       # 任务解锁
└── aio-collect-v.sh          # 版本收集
```

## 版本历史

- v1.0.2 - 移除系统自带工具
- v1.0.1 - 修复安装包
- v1.0.0 - 初始版本

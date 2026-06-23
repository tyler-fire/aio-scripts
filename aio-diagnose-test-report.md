# aio-diagnose.py 测试报告

## 工具信息
- **工具名称**: aio-diagnose.py
- **版本**: 1.0.0
- **功能**: AIO 任务完整诊断工具

## 功能特性

### 收集内容
1. **数据库记录快照**
   - aio_total_task（总任务表）
   - aio_sub_task（子任务表）
   - aio_log_detail（日志详情表）

2. **任务日志（所有阶段）**
   - 调用 aio-collect-logs.py 收集
   - 包含所有 Worker 节点日志
   - 包含重试日志

3. **服务日志（时间窗口过滤）**
   - cdm.log
   - scheduler.log
   - worker.log
   - apscheduler.log
   - 按关键词过滤（error/fail/timeout等）

4. **系统日志（时间窗口+关键词过滤）**
   - journalctl 日志
   - /var/log/messages
   - 关键词包括：mount/disk/network/permission/fsdeamon等

5. **诊断报告**
   - DIAGNOSIS_REPORT.txt
   - 包含任务基本信息
   - 收集内容清单
   - 使用说明

### 时间窗口策略
- 以任务 start_time 和 end_time 为基准
- 前后各扩展 5 分钟
- 避免收集无关日志

### 日志过滤策略
- 系统日志关键词：
  ```
  mount, umount, disk, volume, zfs, pool,
  network, connection, timeout, refused, ssh, rpc,
  permission, denied, forbidden,
  error, fail, panic, segfault, oom, killed,
  mysql, postgresql, oracle, gaussdb,
  fsdeamon, fsbackup, aio-speed, rdbcomm
  ```
- 减少日志体积：原始几 GB → 过滤后几 MB

## 测试环境

### 服务器配置
| 服务器 | IP | 角色 | AIO 版本 | 密码加密 |
|--------|---------|------|----------|----------|
| 216 (aiosrv5510) | 10.7.16.216 | RDB Server | 5.5.3.0 | 明文 |
| 211 (aio-pw) | 10.7.16.211 | Worker | - | 明文 |
| 166 (rdb-6100) | 10.7.16.166 | RDB Server | 6.1.0.0 | ENC() 加密 |

## 测试结果

### 1. 服务器 216 测试
**测试任务**: 19746（log_backup，失败）

```
任务 ID: 19746
任务类型: log_backup
任务状态: failed
时间窗口: 2026-06-23 09:46:49 ~ 2026-06-23 09:57:13
```

**收集结果**:
- ✓ 数据库记录（aio_total_task: 1 条，aio_sub_task: 1 条）
- ✓ 任务日志（已收集）
- ✓ 系统日志（journal.log: 21.2 KB，messages.log: 117.3 KB）
- ✓ 诊断报告生成
- **输出**: /tmp/aio_diagnosis/task_19746_diagnosis_20260623_102024.tar.gz
- **大小**: 0.01 MB

### 2. 服务器 211 测试
**测试任务**: 19746（同上，跨节点测试）

```
任务 ID: 19746
任务类型: log_backup
任务状态: failed
时间窗口: 2025-11-30 19:29:12 ~ 2025-11-30 19:39:17
```

**收集结果**:
- ✓ 数据库记录（aio_total_task: 1 条，aio_sub_task: 1 条）
- ✓ 任务日志（已收集）
- ✓ 系统日志（messages.log: 281.5 KB）
- ✓ 诊断报告生成
- **输出**: /tmp/aio_diagnosis/task_19746_diagnosis_20260623_102043.tar.gz
- **大小**: 0.02 MB

### 3. 服务器 166 测试
**测试任务**: 1012（full_backup，成功）

```
任务 ID: 1012
任务类型: full_backup
任务状态: success
时间窗口: 2026-06-23 10:04:50 ~ 2026-06-23 10:15:30
```

**收集结果**:
- ✓ 数据库记录（aio_total_task: 1 条，aio_sub_task: 1 条）
- ✓ 任务日志（已收集）
- ✓ 系统日志（messages.log: 276.0 KB）
- ✓ 诊断报告生成
- ✓ **ENC() 密码解密成功**
- **输出**: /tmp/aio_diagnosis/task_1012_diagnosis_20260623_102137.tar.gz
- **大小**: 0.03 MB

## 兼容性验证

### ✓ 密码解密支持
- 明文密码：216, 211 ✓
- ENC() 加密：166 ✓

### ✓ AIO 版本兼容
- v5.5.3.0：216, 211 ✓
- v6.1.0.0：166 ✓

### ✓ 系统日志收集
- journalctl：216 ✓
- /var/log/messages：216, 211, 166 ✓

## 工具集成

### aio-tools.sh 更新
- 版本：1.0.0 → 1.1.0
- 新增菜单项：`2) 任务诊断`
- 工具列表新增：aio-diagnose.py

### 三台服务器部署状态
| 服务器 | aio-diagnose.py | aio-tools.sh | 测试状态 |
|--------|----------------|--------------|----------|
| 216 | ✓ | ✓ v1.1.0 | ✓ 通过 |
| 211 | ✓ | ✓ v1.1.0 | ✓ 通过 |
| 166 | ✓ | ✓ v1.1.0 | ✓ 通过 |

## 使用方法

### 命令行直接使用
```bash
python3 /opt/aio/scripts/aio-diagnose.py <task_id>
```

### 通过工具集使用
```bash
/opt/aio/scripts/aio-tools.sh
# 选择: 2) 任务诊断
# 输入任务 ID
```

## 优势对比

### vs aio-collect-logs.py
| 功能 | aio-collect-logs.py | aio-diagnose.py |
|------|---------------------|-----------------|
| 任务日志 | ✓ | ✓ |
| 数据库记录 | ✗ | ✓ |
| 服务日志 | ✗ | ✓ |
| 系统日志 | ✗ | ✓ |
| 诊断报告 | ✗ | ✓ |

### 适用场景
- **aio-collect-logs.py**: 快速收集任务日志
- **aio-diagnose.py**: 完整诊断，深度分析问题

## 结论

✓ **aio-diagnose.py 在三台服务器上测试全部通过**

- 功能完整：收集日志、数据库、服务、系统日志
- 兼容性好：支持不同 AIO 版本和密码加密方式
- 输出精简：通过时间窗口和关键词过滤，避免日志体积过大
- 集成顺利：已整合到 aio-tools.sh 工具集

## 测试时间
2026-06-23 10:20 - 10:22

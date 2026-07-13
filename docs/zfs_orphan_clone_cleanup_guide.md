# ZFS 孤儿 Clone 排查与清理手册

本文用于处理 AIO 备份、恢复、挂载、删除备份过程中遇到的 ZFS snapshot 删除失败问题。问题不限定数据库类型，只要流程使用了 ZFS clone、zvol、SCST/iSCSI，都可能出现。

典型原因是：某次挂载或恢复重试前，上一轮已经创建了 clone，但后续挂载、iSCSI、远端执行或数据库拉起失败；用户重试后新一轮 clone 成功并被平台记录，上一轮 clone 没有进入成功记录，后续清挂载或删除备份时就漏清了它。

## 适用现象

常见入口有两类。

第一类：过期清理脚本预览时发现 snapshot 有 clone，被跳过：

```text
Skipped because these snapshots have clones. Use -R only after confirming the clones can be removed:
aiopool/10.0.0.10_3306_mysql@1775790798323 #2026-04-10 12:33 clones=aiopool/zd400-1775790798323-17758882754323
```

第二类：前端删除备份或手工删除 ZFS 时直接失败：

```text
cannot destroy 'aiopool/zd400-1775790798323-17758882754323': dataset is busy
cannot destroy snapshot aiopool/10.0.0.10_3306_mysql@1775790798323: snapshot is cloned
```

这两个报错含义不同：

- `snapshot is cloned`：snapshot 下面还有 clone，不能直接删除。
- `dataset is busy`：clone 自己还被挂载、进程、SCST 或 iSCSI 占用，`zfs destroy -R` 也删不掉。

## 处理原则

生产环境先排查再清理，不要直接批量执行全量命令。

禁止直接执行这类命令：

```bash
scstadmin --list_device | grep zvol | awk '{print $1}' | xargs -i scstadmin -close_dev {} -handler vdisk_blockio -noprompt -force
zfs list | grep zd | awk '{print $1}' | xargs -i zfs destroy -R {}
```

原因是它们会匹配所有 zvol 或所有名字里带 `zd` 的 ZFS 对象，可能关闭正常挂载、恢复或正在使用的 clone。

正确顺序是：

1. 确认目标 snapshot。
2. 反查引用该 snapshot 的 clone。
3. 只检查这些 clone 的占用。
4. 如果 clone 被 SCST 占用，先精确关闭对应 SCST device。
5. 如果 clone 被挂载或进程占用，先确认业务是否可以停止。
6. 删除 clone。
7. 再删除 snapshot 或重新发起平台删除备份。

## 第一步：确认目标 Snapshot

如果是脚本输出 `Skipped snapshots with clones`，直接取输出里的 snapshot：

```bash
SNAP='aiopool/10.0.0.10_3306_mysql@1775790798323'
```

如果是删除备份报错，取 `snapshot is cloned` 后面的 snapshot：

```bash
SNAP='aiopool/10.0.0.10_3306_mysql@1775790798323'
```

如果报错里有多个 snapshot，要逐个处理。不要只处理一个 data snapshot 后就认为 log、gtmlog 或其他阶段 snapshot 已经清完。

## 第二步：查找 Clone

优先使用 ZFS 的 `clones` 属性：

```bash
sudo zfs get -H -o value clones "$SNAP"
```

输出示例：

```text
aiopool/zd400-1775790798323-17758882754323,aiopool/zd400-1775790798323-17758883484560
```

如果输出是 `-`，说明这个 snapshot 当前没有 clone。此时如果删除仍失败，需要重新核对报错里的 snapshot 是否正确。

也可以从所有 dataset 的 `origin` 反查：

```bash
sudo zfs list -H -o name -t filesystem,volume \
  | while read -r ds; do
      sudo zfs get -H -o name,value origin "$ds" 2>/dev/null
    done \
  | awk -v snap="$SNAP" '$2 == snap {print $1}'
```

这个命令只输出 origin 等于目标 snapshot 的 clone。

## 第三步：查看 Clone 基本信息

对每个 clone 单独检查：

```bash
CLONE='aiopool/zd400-1775790798323-17758882754323'

sudo zfs get -H -o name,property,value type,origin,mountpoint,mounted "$CLONE"
sudo zfs list -o name,type,origin,mountpoint,mounted "$CLONE"
```

如果 clone 是 zvol，设备路径通常是：

```bash
/dev/zvol/aiopool/zd400-1775790798323-17758882754323
```

确认设备是否存在：

```bash
sudo ls -l "/dev/zvol/$CLONE"
```

## 第四步：判断 Busy 来源

### 4.1 查 SCST 占用

只按当前 clone 名精确过滤：

```bash
BASENAME="$(basename "$CLONE")"
sudo scstadmin --list_device | grep "$BASENAME"
```

示例输出可能类似：

```text
zd400-1775790798323-17758882754323 /dev/zvol/aiopool/zd400-1775790798323-17758882754323 vdisk_blockio
```

不同环境的列位置可能不同。必须先看输出，确认 SCST device 名是哪一列，再生成关闭命令。

如果 device 名是第一列：

```bash
sudo scstadmin --list_device \
  | grep "$BASENAME" \
  | awk '{print $1}' \
  | sort -u \
  | xargs -r -I{} echo "sudo scstadmin -close_dev {} -handler vdisk_blockio -noprompt -force"
```

如果 device 名是第二列，把 `awk '{print $1}'` 改成：

```bash
awk '{print $2}'
```

确认打印出来的命令只包含当前 clone 后，再去掉 `echo` 执行。

### 4.2 查挂载点

```bash
sudo findmnt | grep "$BASENAME"
sudo mount | grep "$BASENAME"
```

如果有挂载点，先确认这个挂载不是当前正在使用的恢复、挂载或业务验证环境。确认可以清理后再卸载：

```bash
sudo umount <mountpoint>
```

不要默认使用 `umount -l`。懒卸载只解除目录视图，不代表底层占用已经安全结束。

### 4.3 查进程占用

zvol 占用：

```bash
sudo fuser -vm "/dev/zvol/$CLONE"
sudo lsof "/dev/zvol/$CLONE"
```

文件系统挂载点占用：

```bash
sudo fuser -vm <mountpoint>
sudo lsof +D <mountpoint>
```

如果看到数据库进程、备份进程、恢复进程或业务验证进程，先确认任务状态和业务影响，不要直接 `kill -9`。

## 第五步：释放 SCST 占用

只有确认 SCST device 对应当前要清理的 clone 后，才执行 close。

示例：device 名是第一列时：

```bash
BASENAME="$(basename "$CLONE")"

sudo scstadmin --list_device \
  | grep "$BASENAME" \
  | awk '{print $1}' \
  | sort -u \
  | xargs -r -I{} sudo scstadmin -close_dev {} -handler vdisk_blockio -noprompt -force
```

执行后再次确认：

```bash
sudo scstadmin --list_device | grep "$BASENAME" || echo "SCST device cleared"
sudo fuser -vm "/dev/zvol/$CLONE"
```

如果仍有占用，继续查挂载点和进程，不要进入 destroy。

## 第六步：删除 Clone

确认无占用后删除 clone：

```bash
sudo zfs destroy -R "$CLONE"
```

如果有多个 clone，逐个处理：

```bash
sudo zfs destroy -R aiopool/zd400-1775790798323-17758882754323
sudo zfs destroy -R aiopool/zd400-1775790798323-17758883484560
```

删除后验证：

```bash
sudo zfs list "$CLONE"
```

正常情况下会提示 dataset 不存在。

## 第七步：删除 Snapshot 或重试平台删除

再次查看 snapshot 是否还有 clone：

```bash
sudo zfs get -H -o value clones "$SNAP"
```

如果输出是 `-`，说明 clone 已清完。

可以手工删除 snapshot：

```bash
sudo zfs destroy "$SNAP"
```

如果这次问题来自前端删除备份，更推荐先回到平台重试删除备份，让业务表状态和实际 ZFS 状态保持一致。

## 示例一：过期清理脚本提示 SKIP_CLONE

脚本预览输出：

```text
Skipped because these snapshots have clones. Use -R only after confirming the clones can be removed:
aiopool/10.0.0.10_3306_mysql@1775790798323 #2026-04-10 12:33 clones=aiopool/zd400-1775790798323-17758882754323
```

处理：

```bash
SNAP='aiopool/10.0.0.10_3306_mysql@1775790798323'
CLONE='aiopool/zd400-1775790798323-17758882754323'
BASENAME="$(basename "$CLONE")"

sudo zfs get -H -o value clones "$SNAP"
sudo scstadmin --list_device | grep "$BASENAME"
sudo fuser -vm "/dev/zvol/$CLONE"
```

如果确认只有 SCST 占用，先预览 close 命令：

```bash
sudo scstadmin --list_device \
  | grep "$BASENAME" \
  | awk '{print $1}' \
  | sort -u \
  | xargs -r -I{} echo "sudo scstadmin -close_dev {} -handler vdisk_blockio -noprompt -force"
```

确认命令只包含当前 clone 后执行：

```bash
sudo scstadmin --list_device \
  | grep "$BASENAME" \
  | awk '{print $1}' \
  | sort -u \
  | xargs -r -I{} sudo scstadmin -close_dev {} -handler vdisk_blockio -noprompt -force
```

再删除：

```bash
sudo zfs destroy -R "$CLONE"
sudo zfs get -H -o value clones "$SNAP"
sudo zfs destroy "$SNAP"
```

## 示例二：删除备份时报 dataset is busy

报错：

```text
cannot destroy 'aiopool/zd400-1775790798323-17758882754323': dataset is busy
cannot destroy snapshot aiopool/10.0.0.10_3306_mysql@1775790798323: snapshot is cloned
```

先拆成两个目标：

```bash
CLONE='aiopool/zd400-1775790798323-17758882754323'
SNAP='aiopool/10.0.0.10_3306_mysql@1775790798323'
```

确认 clone 来源：

```bash
sudo zfs get -H -o name,value origin "$CLONE"
```

确认 busy 来源：

```bash
BASENAME="$(basename "$CLONE")"
sudo scstadmin --list_device | grep "$BASENAME"
sudo findmnt | grep "$BASENAME"
sudo fuser -vm "/dev/zvol/$CLONE"
```

释放占用并删除：

```bash
sudo scstadmin --list_device \
  | grep "$BASENAME" \
  | awk '{print $1}' \
  | sort -u \
  | xargs -r -I{} sudo scstadmin -close_dev {} -handler vdisk_blockio -noprompt -force

sudo zfs destroy -R "$CLONE"
sudo zfs get -H -o value clones "$SNAP"
```

如果 `clones` 已经是 `-`，回到前端重试删除备份。

## 现场记录模板

处理前建议保存这些输出：

```bash
date
hostname -f 2>/dev/null || hostname
sudo zfs get -H -o value clones "$SNAP"
sudo zfs get -H -o name,value origin "$CLONE"
sudo zfs list -o name,type,origin,mountpoint,mounted "$CLONE"
sudo scstadmin --list_device | grep "$(basename "$CLONE")"
sudo fuser -vm "/dev/zvol/$CLONE"
```

处理后保存：

```bash
sudo scstadmin --list_device | grep "$(basename "$CLONE")" || echo "SCST cleared"
sudo zfs list "$CLONE"
sudo zfs get -H -o value clones "$SNAP"
```

## 什么时候不要继续

遇到以下情况先停止，不要继续执行 destroy：

- `fuser` 或 `lsof` 显示有当前仍在运行的数据库、恢复、挂载或校验进程。
- `scstadmin --list_device | grep <clone>` 匹配到多条，且无法确认哪条属于目标 clone。
- 同一个 snapshot 的 clone 看起来是正常挂载记录中的 clone，而不是失败重试遗留 clone。
- 前端仍显示相关挂载、恢复或删除任务正在 running。
- 无法确认当前 worker 是否就是报错 worker。

这类情况先收集任务日志、服务状态和业务表状态，再决定是否清理。

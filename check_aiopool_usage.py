#!/usr/bin/python3
# -*- coding: utf-8 -*-
# 版本: 1.0.1
"""从Server端通过RPC统计Worker节点上aiopool的磁盘空间占用"""

import sys
import subprocess
import os

AIO_HOME = "/opt/aio"
RPC_BASE = "{}/airflow/tools/rpc".format(AIO_HOME)
RPC = "{}/{}/rpc".format(RPC_BASE, os.uname().machine)

# 读取配置
SERVER_IP = None
BROKER_URL = None
DB_CONFIG = {}

# 优先从airflow.runtime.env读取broker_url(包含正确的DB号)
runtime_file = "{}/cfg/airflow.runtime.env".format(AIO_HOME)
if os.path.exists(runtime_file):
    with open(runtime_file) as f:
        for line in f:
            line = line.strip()
            if line.startswith("AIRFLOW__CELERY__BROKER_URL="):
                BROKER_URL = line.split("=", 1)[1].strip()

# 从aio.env读取Server IP和数据库配置
env_file = "{}/cfg/aio.env".format(AIO_HOME)
if os.path.exists(env_file):
    with open(env_file) as f:
        for line in f:
            line = line.strip()
            if line.startswith("AIO_DB_HOSTNAME="):
                SERVER_IP = line.split("=", 1)[1].strip()
            elif line.startswith("AIO_DB_PORT="):
                DB_CONFIG["port"] = line.split("=", 1)[1].strip()
            elif line.startswith("AIO_DB_USERNAME="):
                DB_CONFIG["user"] = line.split("=", 1)[1].strip()
            elif line.startswith("AIO_DB_PASSWORD="):
                DB_CONFIG["password"] = line.split("=", 1)[1].strip()
            elif line.startswith("AIO_DB_NAME="):
                DB_CONFIG["database"] = line.split("=", 1)[1].strip()


def rpc(host, cmd):
    # rpc 客户端始终在本机(Server)上执行, 通过 6611 端口连到 Worker 上的 agent
    # 由 agent 在远端执行命令并回传结果。因此选择哪个架构的 rpc 二进制只取决于
    # 本机(Server)架构, 与远端 Worker 架构无关。
    r = subprocess.run(
        '{} -h {} -p 6611 -c "{}"'.format(RPC, host, cmd),
        shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30
    )
    return r.returncode, r.stdout.decode().strip()


def discover_workers():
    """发现Worker节点: 优先通过Celery, 失败则直接查MySQL"""

    # 方式1: 通过Celery inspect发现活跃Worker
    if BROKER_URL:
        python_bin = "{}/airflow/bin/python3".format(AIO_HOME)
        if not os.path.exists(python_bin):
            python_bin = sys.executable

        script = (
            "from celery import Celery; "
            "app = Celery(broker='{}'); "
            "active = app.control.inspect(timeout=5).active_queues() or {{}}; "
            "print('\\n'.join(n.split('@',1)[-1] for n in sorted(active)))"
        ).format(BROKER_URL)

        queues = []
        try:
            r = subprocess.run([python_bin, "-c", script],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
            if r.returncode == 0 and r.stdout.decode().strip():
                queues = [n.strip() for n in r.stdout.decode().strip().split('\n') if n.strip()]
        except Exception:
            pass

        if queues:
            mysql_cmd = [
                "/usr/local/mysql/bin/mysql",
                "-h", DB_CONFIG.get("host", SERVER_IP),
                "-P", DB_CONFIG.get("port", "3306"),
                "-u", DB_CONFIG.get("user", "root"),
                "-p{}".format(DB_CONFIG.get("password", "")),
                "-N", DB_CONFIG.get("database", "aio"), "-e",
                "SELECT sys_dn_ipaddr FROM aio_data_nodes WHERE sys_dn_queue IN ({}) AND worker_type = 2 AND sys_dn_is_delete = 0".format(
                    ",".join("'{}'".format(q) for q in queues)
                )
            ]
            try:
                r = subprocess.run(mysql_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
                if r.returncode == 0 and r.stdout.decode().strip():
                    ips = [ip.strip() for ip in r.stdout.decode().strip().split('\n') if ip.strip()]
                    if ips:
                        return list(dict.fromkeys(ips))
            except Exception:
                pass

    # 方式2: 直接查MySQL获取所有Worker IP
    mysql_cmd = [
        "/usr/local/mysql/bin/mysql",
        "-h", DB_CONFIG.get("host", SERVER_IP),
        "-P", DB_CONFIG.get("port", "3306"),
        "-u", DB_CONFIG.get("user", "root"),
        "-p{}".format(DB_CONFIG.get("password", "")),
        "-N", DB_CONFIG.get("database", "aio"), "-e",
        "SELECT DISTINCT sys_dn_ipaddr FROM aio_data_nodes WHERE worker_type = 2 AND sys_dn_is_delete = 0"
    ]
    try:
        r = subprocess.run(mysql_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        if r.returncode == 0 and r.stdout.decode().strip():
            ips = [ip.strip() for ip in r.stdout.decode().strip().split('\n') if ip.strip()]
            return list(dict.fromkeys(ips))
    except Exception:
        pass

    return []


# ==================== 格式化工具 ====================

def fmt_size(n):
    """字节转人类可读"""
    if n is None or n == "":
        return "N/A"
    try:
        n = float(n)
    except (ValueError, TypeError):
        return str(n)
    for u in ['B', 'K', 'M', 'G', 'T', 'P']:
        if abs(n) < 1024:
            return "{:.2f}{}".format(n, u)
        n /= 1024
    return "{:.2f}E".format(n)


def fmt_pct(used, total):
    if not total:
        return "0.0%"
    return "{:.1f}%".format(float(used) / float(total) * 100)


# ==================== 数据解析 ====================

def parse_zpool(out):
    """解析zpool list -Hp输出: name size alloc free ..."""
    lines = out.strip().split('\n')
    if not lines:
        return None
    f = lines[0].split('\t')
    if len(f) < 4:
        return None
    return {
        "name": f[0],
        "size": float(f[1]),
        "alloc": float(f[2]),
        "free": float(f[3]),
        "health": f[9] if len(f) > 9 else "UNKNOWN",
    }


def parse_zfs_datasets(out):
    """解析zfs list -Hp输出"""
    datasets = []
    for line in out.strip().split('\n'):
        if not line:
            continue
        f = line.split('\t')
        if len(f) < 5:
            continue
        datasets.append({
            "name": f[0],
            "used": float(f[1]),
            "usedbydataset": float(f[2]),
            "usedbysnapshots": float(f[3]),
            "refer": float(f[4]),
        })
    return datasets


def parse_zfs_snapshots(out):
    """解析zfs list -t snapshot -Hp输出"""
    snaps = []
    for line in out.strip().split('\n'):
        if not line:
            continue
        f = line.split('\t')
        if len(f) < 3:
            continue
        snaps.append({
            "name": f[0],
            "used": float(f[1]),
            "refer": float(f[2]),
        })
    return snaps


# ==================== 分析输出 ====================

def check_worker(ip):
    """查询单个Worker的aiopool信息并输出汇总"""
    rc, _ = rpc(ip, "echo ok")
    if rc != 0:
        print("=" * 70)
        print("Worker {} - RPC不可达".format(ip))
        print("=" * 70 + "\n")
        return

    # 1. zpool
    rc, out = rpc(ip, "zpool list -Hp aiopool")
    if rc != 0:
        print("=" * 70)
        print("Worker {} - zpool命令失败: {}".format(ip, out or "未知错误"))
        print("=" * 70 + "\n")
        return

    pool = parse_zpool(out)
    if not pool:
        print("Worker {} - 解析zpool输出失败\n".format(ip))
        return

    # 2. datasets
    rc, out = rpc(ip, "zfs list -Hp -o name,used,usedbydataset,usedbysnapshots,refer -r aiopool")
    datasets = parse_zfs_datasets(out) if rc == 0 else []

    # 3. snapshots
    rc, out = rpc(ip, "zfs list -t snapshot -Hp -o name,used,refer -s used -r aiopool")
    snapshots = parse_zfs_snapshots(out) if rc == 0 else []

    # 过滤掉根池本身，只保留子dataset
    children = [d for d in datasets if d["name"] != pool["name"]]

    # 计算汇总
    total_snap_used = sum(s["used"] for s in snapshots)
    total_snap_count = len(snapshots)
    total_dataset_used = sum(d["used"] for d in children)

    # 告警
    alerts = []
    cap = pool["alloc"] / pool["size"] * 100 if pool["size"] else 0
    if cap >= 90:
        alerts.append("[严重] 池使用率 {:.1f}%，建议立即清理".format(cap))
    elif cap >= 80:
        alerts.append("[警告] 池使用率 {:.1f}%，建议规划扩容或清理".format(cap))
    if pool["health"] != "ONLINE":
        alerts.append("[异常] 池健康状态: {}".format(pool["health"]))

    # ===== 输出 =====
    print("=" * 70)
    print("Worker: {}".format(ip))
    print("=" * 70)

    # 池总览
    print("\n[池总览]")
    print("  总容量: {:>12}    健康状态: {}".format(fmt_size(pool["size"]), pool["health"]))
    print("  已使用: {:>12} ({})".format(fmt_size(pool["alloc"]), fmt_pct(pool["alloc"], pool["size"])))
    print("  可  用: {:>12} ({})".format(fmt_size(pool["free"]), fmt_pct(pool["free"], pool["size"])))

    # 告警
    if alerts:
        print("\n[告警]")
        for a in alerts:
            print("  {}".format(a))

    # 空间分布
    if children:
        print("\n[空间分布]")
        print("  数据集总数: {}    占用: {}".format(len(children), fmt_size(total_dataset_used)))
        print("  快照总数:   {}    独占: {}".format(total_snap_count, fmt_size(total_snap_used)))

        # 根池占比分解
        root = next((d for d in datasets if d["name"] == pool["name"]), None)
        if root:
            print("  根池分解: 数据本身 {} / 快照 {} / 其他 {}".format(
                fmt_size(root.get("usedbydataset", 0)),
                fmt_size(root.get("usedbysnapshots", 0)),
                fmt_size(root["used"] - root.get("usedbydataset", 0) - root.get("usedbysnapshots", 0))
            ))

        # TOP 5 数据集
        top_ds = sorted(children, key=lambda x: x["used"], reverse=True)[:5]
        print("\n[数据集 TOP 5]")
        print("  {:<4} {:<45} {:>10} {:>8}".format("排名", "名称", "已用", "占池"))
        print("  " + "-" * 66)
        for i, d in enumerate(top_ds, 1):
            print("  {:<4} {:<45} {:>10} {:>8}".format(
                i, d["name"][:45], fmt_size(d["used"]),
                fmt_pct(d["used"], pool["size"])
            ))

    # TOP 10 快照
    if snapshots:
        top_snaps = sorted(snapshots, key=lambda x: x["used"], reverse=True)[:10]
        print("\n[快照 TOP 10 (独占空间)]")
        print("  {:<4} {:<50} {:>10}".format("排名", "名称", "独占"))
        print("  " + "-" * 66)
        for i, s in enumerate(top_snaps, 1):
            name = s["name"]
            # 截断过长的快照名
            if len(name) > 50:
                name = name[:24] + "..." + name[-23:]
            print("  {:<4} {:<50} {:>10}".format(i, name, fmt_size(s["used"])))

    print()


# ==================== 主入口 ====================

if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
    print("用法: python3 check_aiopool_usage.py [worker_ip1,worker_ip2,...]")
    print("      不指定IP时自动发现Worker")
    sys.exit(0)

if len(sys.argv) > 1:
    ips = [ip.strip() for ip in sys.argv[1].split(",") if ip.strip()]
else:
    print("自动发现Worker...")
    ips = discover_workers()
    if not ips:
        print("未发现Worker节点, 可手动指定: python3 check_aiopool_usage.py 10.7.16.217")
        sys.exit(1)
    print("发现Worker: {}\n".format(", ".join(ips)))

for ip in ips:
    check_worker(ip)

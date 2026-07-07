#!/usr/bin/python3
# -*- coding: utf-8 -*-
# 版本: 1.1.1
"""从Server端通过RPC统计Worker节点上aiopool的磁盘空间占用

v1.1.1: RPC命令超时不再中断整次检查, 会在对应Worker结果中提示超时
v1.1.0: 末尾新增所有Worker的aiopool存储汇总表(每行一个Worker, 一眼对比)
"""

import sys
import subprocess
import os
import base64
import tempfile

AIO_HOME = "/opt/aio"
RPC_BASE = "{}/airflow/tools/rpc".format(AIO_HOME)
RPC = "{}/{}/rpc".format(RPC_BASE, os.uname().machine)
RPC_TIMEOUT = 30


def decrypt_enc_password(enc_str):
    """解密ENC格式的密码"""
    if not enc_str.startswith("ENC(") or not enc_str.endswith(")"):
        return enc_str
    enc_data = enc_str[4:-1]  # 去掉ENC()包装
    try:
        # 使用CDM的Python3.6解密, CBC模式+零IV
        cmd = [
            "{}/cdm/bin/python3".format(AIO_HOME), "-c",
            "import sys, base64, os; "
            "sys.path.insert(0, '{}/cdm/lib/python3.6/site-packages'); "
            "from Crypto.Cipher import AES; "
            "from Crypto.Util.Padding import unpad; "
            "from aio.config.key import AES_KEY_BASE_64; "
            "key = base64.b64decode(AES_KEY_BASE_64); "
            "data = base64.b64decode(os.environ['AIO_ENC_DATA']); "
            "decrypted = unpad(AES.new(key, AES.MODE_CBC, IV=b'0000000000000000').decrypt(data), AES.block_size); "
            "sys.stdout.buffer.write(decrypted)".format(AIO_HOME)
        ]
        env = os.environ.copy()
        env['AIO_ENC_DATA'] = enc_data
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, env=env)
        if r.returncode == 0:
            return r.stdout.decode('utf-8', errors='ignore')
    except Exception:
        pass
    return enc_str


def strip_quotes(s):
    """去除首尾单引号或双引号"""
    if len(s) >= 2 and s[0] in ("'", '"') and s[-1] == s[0]:
        return s[1:-1]
    return s


# 读取配置
SERVER_IP = None
BROKER_URL = None
DB_CONFIG = {}
MYSQL_DEFAULTS_FILE = None

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
                SERVER_IP = strip_quotes(line.split("=", 1)[1].strip())
            elif line.startswith("AIO_DB_PORT="):
                DB_CONFIG["port"] = strip_quotes(line.split("=", 1)[1].strip())
            elif line.startswith("AIO_DB_USERNAME="):
                DB_CONFIG["user"] = strip_quotes(line.split("=", 1)[1].strip())
            elif line.startswith("AIO_DB_PASSWORD="):
                DB_CONFIG["password"] = decrypt_enc_password(strip_quotes(line.split("=", 1)[1].strip()))
            elif line.startswith("AIO_DB_NAME="):
                DB_CONFIG["database"] = strip_quotes(line.split("=", 1)[1].strip())


def rpc(host, cmd):
    # rpc 客户端始终在本机(Server)上执行, 通过 6611 端口连到 Worker 上的 agent
    # 由 agent 在远端执行命令并回传结果。因此选择哪个架构的 rpc 二进制只取决于
    # 本机(Server)架构, 与远端 Worker 架构无关。
    rpc_cmd = '{} -h {} -p 6611 -c "{}"'.format(RPC, host, cmd)
    try:
        r = subprocess.run(
            rpc_cmd,
            shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=RPC_TIMEOUT
        )
    except subprocess.TimeoutExpired:
        return 124, "命令超时({}秒): {}".format(RPC_TIMEOUT, cmd)

    stdout = r.stdout.decode(errors="ignore").strip()
    stderr = r.stderr.decode(errors="ignore").strip()
    return r.returncode, stdout or stderr


def get_mysql_defaults_file():
    global MYSQL_DEFAULTS_FILE
    if MYSQL_DEFAULTS_FILE and os.path.exists(MYSQL_DEFAULTS_FILE):
        return MYSQL_DEFAULTS_FILE

    fd, path = tempfile.mkstemp(prefix="aio_mysql_", suffix=".cnf", dir="/tmp")
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write("[client]\n")
        f.write("host={}\n".format(DB_CONFIG.get("host", SERVER_IP) or "127.0.0.1"))
        f.write("port={}\n".format(DB_CONFIG.get("port", "3306")))
        f.write("user={}\n".format(DB_CONFIG.get("user", "root")))
        f.write("password={}\n".format(DB_CONFIG.get("password", "")))
    MYSQL_DEFAULTS_FILE = path
    return MYSQL_DEFAULTS_FILE


def cleanup_mysql_defaults_file():
    global MYSQL_DEFAULTS_FILE
    if MYSQL_DEFAULTS_FILE and os.path.exists(MYSQL_DEFAULTS_FILE):
        os.remove(MYSQL_DEFAULTS_FILE)
    MYSQL_DEFAULTS_FILE = None


def execute_mysql_query(sql):
    defaults_file = get_mysql_defaults_file()
    cmd = [
        "/usr/local/mysql/bin/mysql",
        "--defaults-extra-file={}".format(defaults_file),
        DB_CONFIG.get("database", "aio"), "-N", "-e", sql
    ]
    try:
        result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        if result.returncode != 0:
            return []
        output = result.stdout.decode().strip()
        if not output:
            return []
        return [line.strip() for line in output.split('\n') if line.strip()]
    except Exception:
        return []


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
            ips = execute_mysql_query(
                "SELECT sys_dn_ipaddr FROM aio_data_nodes WHERE sys_dn_queue IN ({}) AND sys_dn_is_delete = 0".format(
                    ",".join("'{}'".format(q) for q in queues)
                )
            )
            if ips:
                return list(dict.fromkeys(ips))

    # 方式2: 直接查MySQL获取所有Worker IP
    ips = execute_mysql_query("SELECT DISTINCT sys_dn_ipaddr FROM aio_data_nodes WHERE sys_dn_is_delete = 0")
    if ips:
        return list(dict.fromkeys(ips))

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
    """查询单个Worker的aiopool信息并输出汇总。返回汇总用的状态字典。"""
    rc, _ = rpc(ip, "echo ok")
    if rc != 0:
        print("=" * 70)
        print("Worker {} - RPC不可达".format(ip))
        print("=" * 70 + "\n")
        return {"ip": ip, "status": "RPC不可达", "pool": None}

    # 1. zpool
    rc, out = rpc(ip, "zpool list -Hp aiopool")
    if rc != 0:
        print("=" * 70)
        print("Worker {} - zpool命令失败: {}".format(ip, out or "未知错误"))
        print("=" * 70 + "\n")
        return {"ip": ip, "status": "zpool命令失败", "pool": None}

    pool = parse_zpool(out)
    if not pool:
        print("Worker {} - 解析zpool输出失败\n".format(ip))
        return {"ip": ip, "status": "解析失败", "pool": None}

    # 2. datasets
    rc, out = rpc(ip, "zfs list -Hp -o name,used,usedbydataset,usedbysnapshots,refer -r aiopool")
    datasets = parse_zfs_datasets(out) if rc == 0 else []
    if rc != 0:
        print("Worker {} - 数据集明细获取失败: {}".format(ip, out or "未知错误"))

    # 3. snapshots
    rc, out = rpc(ip, "zfs list -t snapshot -Hp -o name,used,refer -s used -r aiopool")
    snapshots = parse_zfs_snapshots(out) if rc == 0 else []
    if rc != 0:
        print("Worker {} - 快照明细获取失败: {}".format(ip, out or "未知错误"))

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

    return {
        "ip": ip,
        "status": "ONLINE" if pool["health"] == "ONLINE" else pool["health"],
        "pool": pool,
        "cap": cap,
    }


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

results = []
for ip in ips:
    results.append(check_worker(ip))


# ==================== 汇总表 ====================

def disp_width(s):
    """计算字符串终端显示宽度，CJK字符按2列算"""
    import unicodedata
    w = 0
    for ch in str(s):
        w += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return w


def pad(s, width, align="left"):
    """按终端显示宽度对齐填充（兼容CJK）"""
    s = str(s)
    gap = width - disp_width(s)
    if gap <= 0:
        return s
    if align == "right":
        return " " * gap + s
    return s + " " * gap


def print_summary(results):
    """末尾打印所有Worker的zpool汇总表，每行一个Worker"""
    if not results:
        return

    # 列宽（按终端显示宽度）
    W_IP, W_NUM, W_CAP, W_ST = 16, 11, 9, 10

    line = "=" * 78
    print(line)
    print("汇总: 所有 Worker aiopool 存储概览 (共 {} 个)".format(len(results)))
    print(line)

    # 表头
    print("{} {} {} {} {} {}".format(
        pad("Worker IP", W_IP),
        pad("总容量", W_NUM, "right"),
        pad("已用", W_NUM, "right"),
        pad("可用", W_NUM, "right"),
        pad("使用率", W_CAP, "right"),
        pad("状态", W_ST)))
    print("-" * 78)

    # 统计在线池的总量
    sum_size = sum_alloc = sum_free = 0.0
    online_count = 0

    for r in results:
        ip = r["ip"]
        pool = r.get("pool")
        if not pool:
            # 失败的Worker
            print("{} {} {} {} {} {}".format(
                pad(ip, W_IP),
                pad("-", W_NUM, "right"),
                pad("-", W_NUM, "right"),
                pad("-", W_NUM, "right"),
                pad("-", W_CAP, "right"),
                pad(r.get("status", "未知"), W_ST)))
            continue

        cap = r.get("cap", 0)
        # 使用率高亮标记
        cap_str = "{:.1f}%".format(cap)
        if cap >= 90:
            cap_str += "!!"
        elif cap >= 80:
            cap_str += "!"

        sum_size += pool["size"]
        sum_alloc += pool["alloc"]
        sum_free += pool["free"]
        online_count += 1

        print("{} {} {} {} {} {}".format(
            pad(ip, W_IP),
            pad(fmt_size(pool["size"]), W_NUM, "right"),
            pad(fmt_size(pool["alloc"]), W_NUM, "right"),
            pad(fmt_size(pool["free"]), W_NUM, "right"),
            pad(cap_str, W_CAP, "right"),
            pad(r.get("status", ""), W_ST)))

    # 合计行
    if online_count > 1:
        print("-" * 78)
        total_cap = "{:.1f}%".format(sum_alloc / sum_size * 100) if sum_size else "-"
        print("{} {} {} {} {} {}".format(
            pad("合计 ({} 池)".format(online_count), W_IP),
            pad(fmt_size(sum_size), W_NUM, "right"),
            pad(fmt_size(sum_alloc), W_NUM, "right"),
            pad(fmt_size(sum_free), W_NUM, "right"),
            pad(total_cap, W_CAP, "right"),
            pad("", W_ST)))

    print("-" * 78)
    print("提示: 使用率后 ! 表示 >=80%, !! 表示 >=90% 需关注")
    print()


print_summary(results)

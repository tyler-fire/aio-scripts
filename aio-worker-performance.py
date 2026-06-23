#!/usr/bin/python3
# -*- coding: utf-8 -*-
# 版本: 1.0.0
"""
AIO Worker 性能分析工具

功能：
  基于 sar 历史数据分析 Worker 性能趋势
  - CPU 使用率
  - 内存使用率
  - 磁盘 IO（速度、等待时间、队列长度）
  - 网络流量（发送/接收、错误/丢包）
  - 系统负载
  - 自动识别峰值和异常
  - 关联备份任务
  - ASCII 图表 + 可选 HTML 报告

用法：
  python3 aio-worker-performance.py <worker_ip> [--days N] [--html]

示例：
  python3 aio-worker-performance.py 10.7.16.209 --days 7
  python3 aio-worker-performance.py 10.7.16.209 --days 30 --html

输出：
  终端：性能摘要 + ASCII 图表
  HTML：详细报告（如果指定 --html）
"""

VERSION = "1.0.0"

import os
import sys
import re
import subprocess
import datetime
import tempfile
import argparse
from collections import defaultdict
import json

AIO_HOME = "/opt/aio"
DB_CONFIG = {"host": None, "port": None, "user": None, "password": None, "database": None}
MYSQL_DEFAULTS_FILE = None

# 性能阈值
THRESHOLDS = {
    'cpu': 90,          # CPU > 90% 告警
    'memory': 85,       # 内存 > 85% 告警
    'disk_await': 50,   # IO 等待 > 50ms 告警
    'disk_write_min': 50,  # 写入 < 50MB/s 告警
    'load_per_cpu': 2,  # 负载/CPU核心数 > 2 告警
}


def strip_quotes(s):
    if len(s) >= 2 and s[0] in ("'", '"') and s[-1] == s[0]:
        return s[1:-1]
    return s


def decrypt_enc_password(enc_str):
    """解密ENC格式的密码"""
    if not enc_str.startswith("ENC(") or not enc_str.endswith(")"):
        return enc_str
    enc_data = enc_str[4:-1]
    try:
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


def load_config():
    env_file = "{}/cfg/aio.env".format(AIO_HOME)
    if not os.path.exists(env_file):
        print("[ERROR] 配置文件不存在: {}".format(env_file))
        sys.exit(1)

    with open(env_file, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                key = key.strip()
                value = strip_quotes(value.strip())
                if key == "AIO_DB_HOSTNAME":
                    DB_CONFIG["host"] = value
                elif key == "AIO_DB_PORT":
                    DB_CONFIG["port"] = int(value) if value else None
                elif key == "AIO_DB_USERNAME":
                    DB_CONFIG["user"] = value
                elif key == "AIO_DB_PASSWORD":
                    DB_CONFIG["password"] = decrypt_enc_password(value)
                elif key == "AIO_DB_NAME":
                    DB_CONFIG["database"] = value

    if not DB_CONFIG["host"]:
        DB_CONFIG["host"] = "127.0.0.1"
    if not DB_CONFIG["port"]:
        DB_CONFIG["port"] = 3306
    if not DB_CONFIG["user"]:
        DB_CONFIG["user"] = "root"
    if not DB_CONFIG["database"]:
        DB_CONFIG["database"] = "aio"


def get_mysql_defaults_file():
    global MYSQL_DEFAULTS_FILE
    if MYSQL_DEFAULTS_FILE and os.path.exists(MYSQL_DEFAULTS_FILE):
        return MYSQL_DEFAULTS_FILE

    if not DB_CONFIG["password"]:
        print("[ERROR] 数据库密码未配置")
        sys.exit(1)

    fd, path = tempfile.mkstemp(prefix="aio_mysql_", suffix=".cnf", dir="/tmp")
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write("[client]\n")
        f.write("host=\n".format(DB_CONFIG["host"]))
        f.write("port={}\n".format(DB_CONFIG["port"]))
        f.write("user={}\n".format(DB_CONFIG["user"]))
        f.write("password={}\n".format(DB_CONFIG["password"]))
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
        DB_CONFIG["database"], "-N", "-e", sql
    ]
    try:
        result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        if result.returncode != 0:
            return []
        output = result.stdout.decode().strip()
        if not output:
            return []
        return [line.split('\t') for line in output.split('\n') if line]
    except Exception:
        return []


def rpc_execute(host, command, port=6611):
    """通过 RPC 执行命令"""
    try:
        rpc_path = "/opt/aio/airflow/tools/rpc/{}/rpc".format(os.uname().machine)
        cmd = [rpc_path, '-h', host, '-p', str(port), '-c', command]
        result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        if result.returncode == 0:
            return result.stdout.decode()
        return None
    except Exception as e:
        print("  [DEBUG] RPC 执行失败: {}".format(e))
        return None


def parse_sar_cpu(sar_output):
    """解析 sar CPU 数据"""
    data = []
    for line in sar_output.split('\n'):
        line = line.strip()
        if not line or line.startswith('Linux') or line.startswith('Average') or 'CPU' in line:
            continue
        parts = line.split()
        if len(parts) < 9:
            continue
        try:
            # 时间 CPU %user %nice %system %iowait %steal %idle
            time_str = parts[0]
            # 跳过 AM/PM 格式
            if parts[1] in ('AM', 'PM'):
                time_str = parts[0] + ' ' + parts[1]
                parts = parts[1:]

            idle = float(parts[-1])
            usage = 100 - idle
            data.append({
                'time': time_str,
                'usage': usage
            })
        except (ValueError, IndexError):
            continue
    return data


def parse_sar_memory(sar_output):
    """解析 sar 内存数据"""
    data = []
    for line in sar_output.split('\n'):
        line = line.strip()
        if not line or line.startswith('Linux') or line.startswith('Average') or 'kbmem' in line:
            continue
        parts = line.split()
        if len(parts) < 5:
            continue
        try:
            time_str = parts[0]
            offset = 0
            if parts[1] in ('AM', 'PM'):
                time_str = parts[0] + ' ' + parts[1]
                offset = 1

            # %memused 在 AM/PM 后的第4列
            # 12:10:24 AM kbmemfree kbavail kbmemused %memused ...
            #     0     1     2        3       4        5
            mem_used = float(parts[4 + offset])
            data.append({
                'time': time_str,
                'usage': mem_used
            })
        except (ValueError, IndexError):
            continue
    return data


def parse_sar_disk(sar_output):
    """解析 sar 磁盘 IO 数据"""
    data = []
    for line in sar_output.split('\n'):
        line = line.strip()
        if not line or line.startswith('Linux') or line.startswith('Average') or 'DEV' in line:
            continue
        parts = line.split()
        if len(parts) < 10:
            continue
        try:
            time_str = parts[0]
            if parts[1] in ('AM', 'PM'):
                time_str = parts[0] + ' ' + parts[1]
                parts = parts[1:]

            dev = parts[1]
            # 跳过 loop/dm 设备
            if 'loop' in dev or 'dm-' in dev:
                continue

            # rkB/s wkB/s await
            read_kb = float(parts[3])
            write_kb = float(parts[4])
            await_ms = float(parts[9])

            data.append({
                'time': time_str,
                'dev': dev,
                'read_mb': read_kb / 1024,
                'write_mb': write_kb / 1024,
                'await': await_ms
            })
        except (ValueError, IndexError):
            continue
    return data


def parse_sar_network(sar_output):
    """解析 sar 网络数据"""
    data = []
    for line in sar_output.split('\n'):
        line = line.strip()
        if not line or line.startswith('Linux') or line.startswith('Average') or 'IFACE' in line:
            continue
        parts = line.split()
        if len(parts) < 9:
            continue
        try:
            time_str = parts[0]
            if parts[1] in ('AM', 'PM'):
                time_str = parts[0] + ' ' + parts[1]
                parts = parts[1:]

            iface = parts[1]
            # 只关注物理网卡
            if iface == 'lo' or iface.startswith('docker') or iface.startswith('veth'):
                continue

            # rxkB/s txkB/s
            rx_kb = float(parts[4])
            tx_kb = float(parts[5])

            data.append({
                'time': time_str,
                'iface': iface,
                'rx_mb': rx_kb / 1024,
                'tx_mb': tx_kb / 1024
            })
        except (ValueError, IndexError):
            continue
    return data


def draw_ascii_chart(data, title, value_key, height=10, width=60):
    """绘制 ASCII 图表"""
    if not data:
        return ""

    values = [d[value_key] for d in data]
    max_val = max(values)
    min_val = min(values)

    if max_val == min_val:
        max_val = min_val + 1

    lines = []
    lines.append("\n" + title)
    lines.append("─" * width)

    # 绘制图表
    for i in range(height, 0, -1):
        threshold = min_val + (max_val - min_val) * i / height
        line = "{:6.1f} ┤".format(threshold)

        for j, val in enumerate(values):
            if j >= width - 10:
                break
            if val >= threshold:
                line += "█"
            else:
                line += " "
        lines.append(line)

    # X 轴
    lines.append("       └" + "─" * min(len(values), width - 10))

    # 时间标签（显示首尾）
    if len(data) > 0:
        first_time = data[0].get('time', '')
        last_time = data[-1].get('time', '')
        lines.append("        {}{}{}".format(
            first_time[:5] if len(first_time) > 5 else first_time,
            " " * max(0, width - 20),
            last_time[:5] if len(last_time) > 5 else last_time
        ))

    return "\n".join(lines)


def find_peak(data, value_key):
    """找到峰值"""
    if not data:
        return None
    max_item = max(data, key=lambda x: x[value_key])
    return max_item


def find_anomalies(data, value_key, threshold):
    """找到超过阈值的异常点"""
    anomalies = []
    for item in data:
        if item[value_key] > threshold:
            anomalies.append(item)
    return anomalies


def find_task_at_time(tasks, time_str, date_str):
    """根据时间找到正在执行的任务"""
    # 解析时间字符串
    try:
        # time_str 格式：12:10:24 AM 或 06:40:00 PM
        # 转换为 24 小时制
        time_parts = time_str.split()
        if len(time_parts) == 2:
            time_12h, ampm = time_parts
            hour, minute, second = time_12h.split(':')
            hour = int(hour)
            minute = int(minute)
            second = int(second)

            if ampm == 'PM' and hour != 12:
                hour += 12
            elif ampm == 'AM' and hour == 12:
                hour = 0

            # 构造完整时间戳
            check_time = datetime.datetime.strptime(
                "{} {:02d}:{:02d}:{:02d}".format(date_str, hour, minute, second),
                "%Y-%m-%d %H:%M:%S"
            )

            # 查找在此时间执行的任务
            for task in tasks:
                if not task['start_time'] or not task['end_time']:
                    continue
                start = datetime.datetime.strptime(task['start_time'], "%Y-%m-%d %H:%M:%S")
                end = datetime.datetime.strptime(task['end_time'], "%Y-%m-%d %H:%M:%S")

                if start <= check_time <= end:
                    return task
        return None
    except Exception:
        return None


def query_tasks(worker_ip, start_date, end_date):
    """查询 Worker 在指定时间范围内的任务"""
    sql = """
    SELECT t.id, t.task_num, t.task_type, t.task_status,
           t.start_time, t.end_time
    FROM aio_total_task t
    JOIN aio_sub_task s ON t.id = s.total_task_id
    WHERE s.src_node_ip = '{}'
    AND t.start_time >= '{}'
    AND t.start_time <= '{}'
    ORDER BY t.start_time
    """.format(worker_ip, start_date, end_date)

    results = execute_mysql_query(sql)
    tasks = []
    for row in results:
        tasks.append({
            'id': int(row[0]),
            'task_num': row[1],
            'task_type': row[2],
            'status': row[3],
            'start_time': row[4],
            'end_time': row[5]
        })
    return tasks
    """查询 Worker 在指定时间范围内的任务"""
    sql = """
    SELECT t.id, t.task_num, t.task_type, t.task_status,
           t.start_time, t.end_time
    FROM aio_total_task t
    JOIN aio_sub_task s ON t.id = s.total_task_id
    WHERE s.src_node_ip = '{}'
    AND t.start_time >= '{}'
    AND t.start_time <= '{}'
    ORDER BY t.start_time
    """.format(worker_ip, start_date, end_date)

    results = execute_mysql_query(sql)
    tasks = []
    for row in results:
        tasks.append({
            'id': int(row[0]),
            'task_num': row[1],
            'task_type': row[2],
            'status': row[3],
            'start_time': row[4],
            'end_time': row[5]
        })
    return tasks


def analyze_worker(worker_ip, days):
    """分析 Worker 性能"""
    print("\n" + "=" * 70)
    print("Worker 性能分析: {}".format(worker_ip))
    print("=" * 70)
    print("时间范围: 最近 {} 天".format(days))
    print("分析时间: {}".format(datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")))
    print("")

    # 计算日期范围
    end_date = datetime.datetime.now()
    start_date = end_date - datetime.timedelta(days=days)

    # 查询任务
    print("[1/5] 查询备份任务...")
    tasks = query_tasks(worker_ip, start_date.strftime("%Y-%m-%d"), end_date.strftime("%Y-%m-%d"))
    print("  找到 {} 个任务".format(len(tasks)))

    # 收集 sar 数据
    print("\n[2/5] 收集 sar 性能数据...")

    all_cpu_data = []
    all_mem_data = []
    all_disk_data = []
    all_net_data = []

    for i in range(days):
        date = end_date - datetime.timedelta(days=i)
        day_num = date.strftime("%d")

        # CPU
        cmd = "sar -u -f /var/log/sa/sa{} 2>/dev/null | grep -v '^$'".format(day_num)
        output = rpc_execute(worker_ip, cmd)
        if output:
            all_cpu_data.extend(parse_sar_cpu(output))

        # 内存
        cmd = "sar -r -f /var/log/sa/sa{} 2>/dev/null | grep -v '^$'".format(day_num)
        output = rpc_execute(worker_ip, cmd)
        if output:
            all_mem_data.extend(parse_sar_memory(output))

        # 磁盘
        cmd = "sar -d -f /var/log/sa/sa{} 2>/dev/null | grep -v '^$'".format(day_num)
        output = rpc_execute(worker_ip, cmd)
        if output:
            all_disk_data.extend(parse_sar_disk(output))

        # 网络
        cmd = "sar -n DEV -f /var/log/sa/sa{} 2>/dev/null | grep -v '^$'".format(day_num)
        output = rpc_execute(worker_ip, cmd)
        if output:
            all_net_data.extend(parse_sar_network(output))

    print("  CPU 数据点: {}".format(len(all_cpu_data)))
    print("  内存数据点: {}".format(len(all_mem_data)))
    print("  磁盘数据点: {}".format(len(all_disk_data)))
    print("  网络数据点: {}".format(len(all_net_data)))

    # 分析
    print("\n[3/5] 分析性能指标...")

    results = {
        'worker_ip': worker_ip,
        'days': days,
        'task_count': len(tasks),
        'cpu': {},
        'memory': {},
        'disk': {},
        'network': {}
    }

    # CPU
    if all_cpu_data:
        cpu_values = [d['usage'] for d in all_cpu_data]
        results['cpu'] = {
            'avg': sum(cpu_values) / len(cpu_values),
            'peak': find_peak(all_cpu_data, 'usage'),
            'anomalies': find_anomalies(all_cpu_data, 'usage', THRESHOLDS['cpu'])
        }

    # 内存
    if all_mem_data:
        mem_values = [d['usage'] for d in all_mem_data]
        results['memory'] = {
            'avg': sum(mem_values) / len(mem_values),
            'peak': find_peak(all_mem_data, 'usage'),
            'anomalies': find_anomalies(all_mem_data, 'usage', THRESHOLDS['memory'])
        }

    # 磁盘（聚合所有设备）
    if all_disk_data:
        # 按设备分组
        disk_by_dev = defaultdict(list)
        for d in all_disk_data:
            disk_by_dev[d['dev']].append(d)

        # 选择主磁盘（数据点最多的）
        main_dev = max(disk_by_dev.keys(), key=lambda k: len(disk_by_dev[k]))
        main_disk_data = disk_by_dev[main_dev]

        write_values = [d['write_mb'] for d in main_disk_data]
        await_values = [d['await'] for d in main_disk_data]

        results['disk'] = {
            'device': main_dev,
            'write_avg': sum(write_values) / len(write_values),
            'write_peak': find_peak(main_disk_data, 'write_mb'),
            'await_avg': sum(await_values) / len(await_values),
            'await_peak': find_peak(main_disk_data, 'await'),
            'await_anomalies': find_anomalies(main_disk_data, 'await', THRESHOLDS['disk_await'])
        }

    # 网络（聚合所有网卡）
    if all_net_data:
        # 按网卡分组
        net_by_iface = defaultdict(list)
        for d in all_net_data:
            net_by_iface[d['iface']].append(d)

        # 选择主网卡
        main_iface = max(net_by_iface.keys(), key=lambda k: len(net_by_iface[k]))
        main_net_data = net_by_iface[main_iface]

        tx_values = [d['tx_mb'] for d in main_net_data]

        results['network'] = {
            'interface': main_iface,
            'tx_avg': sum(tx_values) / len(tx_values),
            'tx_peak': find_peak(main_net_data, 'tx_mb')
        }

    # 输出分析结果
    print("\n[4/5] 生成报告...")
    print_report(results, all_cpu_data, all_mem_data,
                 disk_by_dev.get(results['disk'].get('device'), []) if 'disk' in results and 'device' in results['disk'] else [],
                 net_by_iface.get(results['network'].get('interface'), []) if 'network' in results and 'interface' in results['network'] else [])

    print("\n[5/5] 完成")

    return results


def print_report(results, cpu_data, mem_data, disk_data, net_data):
    """打印报告"""
    print("\n" + "=" * 70)
    print("性能摘要")
    print("=" * 70)

    # CPU
    if results['cpu']:
        cpu = results['cpu']
        print("\n## CPU 使用率")
        print("  平均: {:.1f}%".format(cpu['avg']))
        if cpu['peak']:
            peak = cpu['peak']
            status = " ⚠️" if peak['usage'] > THRESHOLDS['cpu'] else ""
            print("  峰值: {:.1f}%{} (时间: {})".format(peak['usage'], status, peak['time']))
        if cpu['anomalies']:
            print("  ⚠️  {} 次超过 {}% 阈值".format(len(cpu['anomalies']), THRESHOLDS['cpu']))

    # 内存
    if results['memory']:
        mem = results['memory']
        print("\n## 内存使用率")
        print("  平均: {:.1f}%".format(mem['avg']))
        if mem['peak']:
            peak = mem['peak']
            status = " ⚠️" if peak['usage'] > THRESHOLDS['memory'] else ""
            print("  峰值: {:.1f}%{} (时间: {})".format(peak['usage'], status, peak['time']))
        if mem['anomalies']:
            print("  ⚠️  {} 次超过 {}% 阈值".format(len(mem['anomalies']), THRESHOLDS['memory']))

    # 磁盘
    if results['disk']:
        disk = results['disk']
        print("\n## 磁盘 IO ({})".format(disk['device']))
        print("  平均写入: {:.1f} MB/s".format(disk['write_avg']))
        if disk['write_peak']:
            peak = disk['write_peak']
            print("  峰值写入: {:.1f} MB/s (时间: {})".format(peak['write_mb'], peak['time']))
        print("  平均等待: {:.1f} ms".format(disk['await_avg']))
        if disk['await_peak']:
            peak = disk['await_peak']
            status = " ⚠️" if peak['await'] > THRESHOLDS['disk_await'] else ""
            print("  峰值等待: {:.1f} ms{} (时间: {})".format(peak['await'], status, peak['time']))
        if disk['await_anomalies']:
            print("  ⚠️  {} 次 IO 等待超过 {} ms".format(len(disk['await_anomalies']), THRESHOLDS['disk_await']))

    # 网络
    if results['network']:
        net = results['network']
        print("\n## 网络流量 ({})".format(net['interface']))
        print("  平均发送: {:.1f} MB/s".format(net['tx_avg']))
        if net['tx_peak']:
            peak = net['tx_peak']
            print("  峰值发送: {:.1f} MB/s (时间: {})".format(peak['tx_mb'], peak['time']))

    # 绘制图表
    print("\n" + "=" * 70)
    print("性能趋势图")
    print("=" * 70)

    if cpu_data:
        # 采样（每10个点取1个，避免图表太密集）
        sampled = cpu_data[::max(1, len(cpu_data) // 50)]
        print(draw_ascii_chart(sampled, "CPU 使用率 (%)", 'usage'))

    if mem_data:
        sampled = mem_data[::max(1, len(mem_data) // 50)]
        print(draw_ascii_chart(sampled, "\n内存使用率 (%)", 'usage'))

    if disk_data:
        sampled = disk_data[::max(1, len(disk_data) // 50)]
        print(draw_ascii_chart(sampled, "\n磁盘写入速度 (MB/s)", 'write_mb'))

    if net_data:
        sampled = net_data[::max(1, len(net_data) // 50)]
        print(draw_ascii_chart(sampled, "\n网络发送速度 (MB/s)", 'tx_mb'))


def main():
    parser = argparse.ArgumentParser(
        description='AIO Worker 性能分析工具 v{}'.format(VERSION),
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument('worker_ip', help='Worker IP 地址')
    parser.add_argument('--days', type=int, default=7, choices=[3, 7, 14, 30],
                        help='分析天数 (3/7/14/30，默认 7)')
    parser.add_argument('--html', action='store_true',
                        help='生成 HTML 报告')
    parser.add_argument('--version', action='version', version='v{}'.format(VERSION))

    args = parser.parse_args()

    try:
        load_config()
        analyze_worker(args.worker_ip, args.days)

        if args.html:
            print("\n[TODO] HTML 报告生成功能将在后续版本实现")

    finally:
        cleanup_mysql_defaults_file()


if __name__ == "__main__":
    main()

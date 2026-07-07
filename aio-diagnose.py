#!/usr/bin/python3
# -*- coding: utf-8 -*-
# 版本: 1.0.1
"""
AIO 任务诊断工具

功能：
  根据任务 ID 收集完整诊断信息，包括：
  - 任务日志（所有阶段）
  - 数据库记录快照
  - 服务日志（时间窗口）
  - 系统日志（时间窗口+关键词过滤）
  - Worker 状态
  - 诊断报告

用法：
  python3 aio-diagnose.py <task_id>

输出：
  /tmp/aio_diagnosis/task_<id>_diagnosis_<timestamp>.tar.gz
"""

VERSION = "1.0.1"

import os
import sys
import json
import gzip
import re
import subprocess
import datetime
import tempfile
import tarfile
import shutil

AIO_HOME = "/opt/aio"
OUTPUT_BASE = "/tmp/aio_diagnosis"

# 系统日志关键词
SYSTEM_LOG_KEYWORDS = [
    "mount", "umount", "disk", "volume", "zfs", "pool",
    "network", "connection", "timeout", "refused", "ssh", "rpc",
    "permission", "denied", "forbidden",
    "error", "fail", "panic", "segfault", "oom", "killed",
    "mysql", "postgresql", "oracle", "gaussdb",
    "fsdeamon", "fsbackup", "aio-speed", "rdbcomm",
]
SYSTEM_LOG_KEYWORDS_LOWER = [k.lower() for k in SYSTEM_LOG_KEYWORDS]
MAX_LOG_LINES_PER_FILE = 3000

DB_CONFIG = {"host": None, "port": None, "user": None, "password": None, "database": None}
MYSQL_DEFAULTS_FILE = None


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
        f.write("host={}\n".format(DB_CONFIG["host"]))
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


def line_has_keyword(line):
    lower = line.lower()
    return any(k in lower for k in SYSTEM_LOG_KEYWORDS_LOWER)


def parse_log_datetime(line, default_year=None):
    """解析常见服务/系统日志时间戳。解析失败返回 None。"""
    patterns = [
        (r'(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})', "%Y-%m-%d %H:%M:%S"),
        (r'(\d{4}/\d{2}/\d{2})[ T](\d{2}:\d{2}:\d{2})', "%Y/%m/%d %H:%M:%S"),
    ]
    for pattern, fmt in patterns:
        m = re.search(pattern, line)
        if m:
            try:
                return datetime.datetime.strptime("{} {}".format(m.group(1), m.group(2)), fmt)
            except ValueError:
                pass

    # uWSGI 常见格式: [Mon Jul  6 18:21:47 2026]
    m = re.search(r'\[?([A-Z][a-z]{2}\s+[A-Z][a-z]{2}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\d{4})\]?', line)
    if m:
        try:
            return datetime.datetime.strptime(m.group(1), "%a %b %d %H:%M:%S %Y")
        except ValueError:
            pass

    # /var/log/messages 常见格式: Jul  6 18:21:47 hostname ...
    if default_year:
        m = re.match(r'([A-Z][a-z]{2})\s+(\d{1,2})\s+(\d{2}:\d{2}:\d{2})\s+', line)
        if m:
            try:
                return datetime.datetime.strptime(
                    "{} {} {} {}".format(default_year, m.group(1), m.group(2), m.group(3)),
                    "%Y %b %d %H:%M:%S"
                )
            except ValueError:
                pass

    return None


def open_log_text(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8", errors="ignore")
    return open(path, "r", encoding="utf-8", errors="ignore")


def output_log_name(path, root_dir):
    rel = os.path.relpath(path, root_dir).replace(os.sep, "__")
    if rel.endswith(".gz"):
        rel = rel[:-3]
    return rel


def file_date_in_window(path, time_window):
    """有日期后缀的轮转日志按文件名预筛；无日期的当前日志直接保留扫描。"""
    name = os.path.basename(path)
    m = re.search(r'(\d{4}-\d{2}-\d{2})', name)
    if not m:
        return True
    try:
        file_date = datetime.datetime.strptime(m.group(1), "%Y-%m-%d").date()
    except ValueError:
        return True
    return time_window["start"].date() <= file_date <= time_window["end"].date()


def filter_log_file_by_window(src, dst, time_window, keyword_only=False):
    """按时间窗口提取日志；无时间戳的续行跟随上一条有时间戳日志。"""
    from collections import deque

    lines = deque(maxlen=MAX_LOG_LINES_PER_FILE)
    current_in_window = False
    default_year = time_window["start"].year

    try:
        with open_log_text(src) as f:
            for line in f:
                dt = parse_log_datetime(line, default_year=default_year)
                if dt is not None:
                    current_in_window = time_window["start"] <= dt <= time_window["end"]

                if not current_in_window:
                    continue
                if keyword_only and not line_has_keyword(line):
                    continue
                lines.append(line)
    except (IOError, OSError):
        return 0

    if not lines:
        return 0

    with open(dst, "w", encoding="utf-8") as f:
        f.writelines(lines)
        if len(lines) == MAX_LOG_LINES_PER_FILE:
            f.write("\n[提示] 单文件日志较多，仅保留时间窗口内最后 {} 行。\n".format(MAX_LOG_LINES_PER_FILE))
    return len(lines)


class TaskDiagnostic:
    """任务诊断器"""

    def __init__(self, task_id):
        self.task_id = task_id
        self.output_dir = "{}/task_{}_diagnosis".format(OUTPUT_BASE, task_id)
        self.task_info = None
        self.time_window = None

    def query_task_info(self):
        """查询任务基本信息"""
        print("[1/6] 查询任务信息...")
        sql = """
        SELECT id, task_num, task_type, task_status, start_time, end_time,
               JSON_UNQUOTE(JSON_EXTRACT(attribute, '$.db_type'))
        FROM aio_total_task WHERE id = {}
        """.format(self.task_id)
        results = execute_mysql_query(sql)
        if not results:
            print("[ERROR] 未找到任务 ID: {}".format(self.task_id))
            sys.exit(1)

        row = results[0]
        self.task_info = {
            "id": int(row[0]),
            "task_num": row[1],
            "task_type": row[2],
            "task_status": row[3],
            "start_time": row[4] if row[4] != "NULL" else None,
            "end_time": row[5] if row[5] != "NULL" else None,
            "db_type": row[6] if len(row) > 6 and row[6] not in ("null", "NULL") else None,
        }

        print("  任务: {} (ID: {})".format(self.task_info['task_num'], self.task_id))
        print("  类型: {}  状态: {}".format(self.task_info['task_type'], self.task_info['task_status']))

        # 计算时间窗口（前后扩展 5 分钟）
        if self.task_info['start_time']:
            start = datetime.datetime.strptime(self.task_info['start_time'], "%Y-%m-%d %H:%M:%S")
            if self.task_info['end_time']:
                end = datetime.datetime.strptime(self.task_info['end_time'], "%Y-%m-%d %H:%M:%S")
            else:
                end = datetime.datetime.now()
            self.time_window = {
                "start": start - datetime.timedelta(minutes=5),
                "end": end + datetime.timedelta(minutes=5)
            }
            print("  时间窗口: {} ~ {}".format(
                self.time_window['start'].strftime("%Y-%m-%d %H:%M:%S"),
                self.time_window['end'].strftime("%Y-%m-%d %H:%M:%S")
            ))

    def collect_db_records(self):
        """收集数据库记录快照"""
        print("\n[2/6] 收集数据库记录...")
        db_dir = os.path.join(self.output_dir, "database")
        os.makedirs(db_dir, exist_ok=True)

        # aio_total_task
        sql = "SELECT * FROM aio_total_task WHERE id = {}".format(self.task_id)
        results = execute_mysql_query(sql)
        with open(os.path.join(db_dir, "aio_total_task.json"), 'w') as f:
            json.dump(results, f, indent=2, default=str)
        print("  ✓ aio_total_task")

        # aio_sub_task
        sql = "SELECT * FROM aio_sub_task WHERE total_task_id = {} ORDER BY id".format(self.task_id)
        results = execute_mysql_query(sql)
        with open(os.path.join(db_dir, "aio_sub_task.json"), 'w') as f:
            json.dump(results, f, indent=2, default=str)
        print("  ✓ aio_sub_task ({} 条)".format(len(results)))

        # aio_log_detail
        sql = "SELECT * FROM aio_log_detail WHERE task_id = '{}' ORDER BY create_time".format(self.task_id)
        results = execute_mysql_query(sql)
        with open(os.path.join(db_dir, "aio_log_detail.json"), 'w') as f:
            json.dump(results, f, indent=2, default=str)
        print("  ✓ aio_log_detail ({} 条)".format(len(results)))

    def collect_task_logs(self):
        """调用 aio-collect-logs.py 收集任务日志"""
        print("\n[3/6] 收集任务日志...")
        collect_script = "{}/scripts/aio-collect-logs.py".format(AIO_HOME)
        if not os.path.exists(collect_script):
            print("  ✗ aio-collect-logs.py 不存在，跳过")
            return

        try:
            result = subprocess.run(
                ["python3", collect_script, str(self.task_id)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300
            )
            output = result.stdout.decode()
            # 从输出中提取打包文件路径
            for line in output.split('\n'):
                if '/tmp/aio_collected_logs/' in line and '.tar.gz' in line:
                    tar_path = line.split()[-1]
                    if os.path.exists(tar_path):
                        # 解压到诊断目录
                        import tarfile
                        with tarfile.open(tar_path, 'r:gz') as tar:
                            tar.extractall(os.path.join(self.output_dir, "task_logs"))
                        print("  ✓ 任务日志已收集")
                        return
            print("  ⚠ 日志收集完成但未找到打包文件")
        except Exception as e:
            print("  ✗ 日志收集失败: {}".format(e))

    def collect_service_logs(self):
        """收集服务日志（时间窗口）"""
        print("\n[4/6] 收集服务日志...")
        if not self.time_window:
            print("  ✗ 无时间窗口信息，跳过")
            return

        service_dir = os.path.join(self.output_dir, "service_logs")
        os.makedirs(service_dir, exist_ok=True)

        service_root = "{}/logs/service".format(AIO_HOME)
        if not os.path.isdir(service_root):
            print("  ✗ 服务日志目录不存在: {}".format(service_root))
            return

        candidates = []
        for root, _, files in os.walk(service_root):
            for name in files:
                if name.endswith(".log") or name.endswith(".log.gz"):
                    path = os.path.join(root, name)
                    if file_date_in_window(path, self.time_window):
                        candidates.append(path)

        collected = 0
        for log_path in sorted(candidates):
            output_file = os.path.join(service_dir, output_log_name(log_path, service_root))
            count = filter_log_file_by_window(log_path, output_file, self.time_window)
            if count > 0 and os.path.exists(output_file) and os.path.getsize(output_file) > 0:
                collected += 1
                print("  ✓ {} ({} 行, {:.1f} KB)".format(
                    os.path.relpath(log_path, service_root), count, os.path.getsize(output_file)/1024
                ))
            elif os.path.exists(output_file):
                os.remove(output_file)

        if collected == 0:
            print("  ⚠ 时间窗口内未匹配到服务日志")

    def collect_system_logs(self):
        """收集系统日志（时间窗口+关键词过滤）"""
        print("\n[5/6] 收集系统日志...")
        if not self.time_window:
            print("  ✗ 无时间窗口信息，跳过")
            return

        system_dir = os.path.join(self.output_dir, "system_logs")
        os.makedirs(system_dir, exist_ok=True)

        start_str = self.time_window['start'].strftime("%Y-%m-%d %H:%M:%S")
        end_str = self.time_window['end'].strftime("%Y-%m-%d %H:%M:%S")

        # journalctl（如果有）
        try:
            cmd = "journalctl --since '{}' --until '{}' 2>/dev/null | grep -iE '{}' > {}".format(
                start_str, end_str,
                '|'.join(SYSTEM_LOG_KEYWORDS),
                os.path.join(system_dir, "journal.log")
            )
            result = subprocess.run(cmd, shell=True, timeout=60)
            journal_file = os.path.join(system_dir, "journal.log")
            if os.path.exists(journal_file) and os.path.getsize(journal_file) > 0:
                print("  ✓ journal.log ({:.1f} KB)".format(os.path.getsize(journal_file)/1024))
            else:
                os.remove(journal_file) if os.path.exists(journal_file) else None
        except Exception:
            pass

        # /var/log/messages
        if os.path.exists("/var/log/messages"):
            try:
                msg_file = os.path.join(system_dir, "messages.log")
                count = filter_log_file_by_window("/var/log/messages", msg_file, self.time_window, keyword_only=True)
                if count > 0 and os.path.exists(msg_file) and os.path.getsize(msg_file) > 0:
                    print("  ✓ messages.log ({} 行, {:.1f} KB)".format(count, os.path.getsize(msg_file)/1024))
                else:
                    os.remove(msg_file) if os.path.exists(msg_file) else None
            except Exception:
                pass

    def generate_report(self):
        """生成诊断报告"""
        print("\n[6/6] 生成诊断报告...")
        report_file = os.path.join(self.output_dir, "DIAGNOSIS_REPORT.txt")

        with open(report_file, 'w', encoding='utf-8') as f:
            f.write("=" * 70 + "\n")
            f.write("AIO 任务诊断报告\n")
            f.write("=" * 70 + "\n\n")
            f.write("任务 ID: {}\n".format(self.task_id))
            f.write("任务编号: {}\n".format(self.task_info['task_num']))
            f.write("任务类型: {}\n".format(self.task_info['task_type']))
            f.write("任务状态: {}\n".format(self.task_info['task_status']))
            f.write("数据库类型: {}\n".format(self.task_info.get('db_type') or 'N/A'))
            f.write("开始时间: {}\n".format(self.task_info.get('start_time') or 'N/A'))
            f.write("结束时间: {}\n".format(self.task_info.get('end_time') or 'N/A'))
            f.write("\n")
            f.write("诊断时间: {}\n".format(datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")))
            f.write("诊断工具: aio-diagnose.py v{}\n".format(VERSION))
            f.write("\n")
            f.write("=" * 70 + "\n")
            f.write("收集内容\n")
            f.write("=" * 70 + "\n\n")
            f.write("1. 数据库记录快照\n")
            f.write("   - aio_total_task.json\n")
            f.write("   - aio_sub_task.json\n")
            f.write("   - aio_log_detail.json\n\n")
            f.write("2. 任务日志（所有阶段）\n")
            f.write("   - task_logs/\n\n")
            f.write("3. 服务日志（时间窗口过滤）\n")
            f.write("   - service_logs/\n\n")
            f.write("4. 系统日志（时间窗口+关键词过滤）\n")
            f.write("   - system_logs/\n\n")
            f.write("=" * 70 + "\n")
            f.write("使用说明\n")
            f.write("=" * 70 + "\n\n")
            f.write("1. 查看数据库记录： cat database/*.json\n")
            f.write("2. 查看任务日志： ls task_logs/\n")
            f.write("3. 查看服务日志： cat service_logs/*.log\n")
            f.write("4. 查看系统日志： cat system_logs/*.log\n")
            f.write("\n")

        print("  ✓ DIAGNOSIS_REPORT.txt")

    def package(self):
        """打包"""
        print("\n[打包中...]")
        timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        package_name = "task_{}_diagnosis_{}.tar.gz".format(self.task_id, timestamp)
        package_path = os.path.join(OUTPUT_BASE, package_name)

        with tarfile.open(package_path, "w:gz") as tar:
            tar.add(self.output_dir, arcname="task_{}_diagnosis".format(self.task_id))

        shutil.rmtree(self.output_dir)
        size_mb = os.path.getsize(package_path) / 1024 / 1024

        print("\n" + "=" * 70)
        print("诊断完成!")
        print("  输出: {}".format(package_path))
        print("  大小: {:.2f} MB".format(size_mb))
        print("=" * 70)
        return package_path

    def diagnose(self):
        """执行完整诊断"""
        print("\n" + "=" * 70)
        print("AIO 任务诊断工具 v{}".format(VERSION))
        print("任务 ID: {}".format(self.task_id))
        print("=" * 70)

        os.makedirs(OUTPUT_BASE, exist_ok=True)
        os.makedirs(self.output_dir, exist_ok=True)

        self.query_task_info()
        self.collect_db_records()
        self.collect_task_logs()
        self.collect_service_logs()
        self.collect_system_logs()
        self.generate_report()
        return self.package()


def main():
    if len(sys.argv) >= 2 and sys.argv[1] in ('--help', '-h'):
        print("AIO 任务诊断工具 v{}".format(VERSION))
        print("")
        print("用法: python3 aio-diagnose.py <task_id>")
        print("")
        print("功能:")
        print("  根据任务 ID 收集完整诊断信息，包括：")
        print("  - 任务日志（所有阶段）")
        print("  - 数据库记录快照")
        print("  - 服务日志（时间窗口）")
        print("  - 系统日志（时间窗口+关键词过滤）")
        print("  - 诊断报告")
        print("")
        print("输出:")
        print("  /tmp/aio_diagnosis/task_<id>_diagnosis_<timestamp>.tar.gz")
        print("")
        print("示例:")
        print("  python3 aio-diagnose.py 12345")
        sys.exit(0)

    if len(sys.argv) >= 2 and sys.argv[1] in ('--version', '-v'):
        print("v{}".format(VERSION))
        sys.exit(0)

    if len(sys.argv) < 2:
        print("用法: python3 aio-diagnose.py <task_id>")
        print("帮助: python3 aio-diagnose.py --help")
        sys.exit(1)

    try:
        task_id = int(sys.argv[1])
    except ValueError:
        print("[ERROR] task_id 必须是数字")
        sys.exit(1)

    try:
        load_config()
        diagnostic = TaskDiagnostic(task_id)
        diagnostic.diagnose()
    finally:
        cleanup_mysql_defaults_file()


if __name__ == "__main__":
    main()

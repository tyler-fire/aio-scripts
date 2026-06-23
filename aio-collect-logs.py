#!/usr/bin/python3
# -*- coding: utf-8 -*-
# 版本: 2.0.0
"""
AIO任务日志收集工具

功能:
  根据任务ID，通过RPC从所有相关Worker节点收集各阶段日志（含重试日志），
  打包为tar.gz供下载分析。

运行环境:
  - 部署在Server(CDM)节点
  - 通过RPC(端口6611)拉取Worker日志，无需SSH
  - 普通用户可直接执行，无需sudo
  - 数据库密码从/opt/aio/cfg/aio.env读取，通过--defaults-extra-file传递，不暴露在进程列表

支持场景:
  - 备份(backup)、恢复(restore)、挂载(mount)等多阶段任务
  - 多Worker并行任务的日志汇总
  - 重试产生的多份日志(_1, _2, _3)
  - .log明文和.log.gz压缩日志
  - 仅收集实际执行过的阶段，跳过未运行阶段

输出:
  /tmp/aio_collected_logs/task_<id>_logs_<timestamp>.tar.gz
  目录和文件权限为777/666，普通用户可直接读取和拷走
"""

VERSION = "2.0.0"

import os
import sys
import json
import tarfile
import shutil
import subprocess
import datetime
import tempfile
from pathlib import Path

AIO_HOME = "/opt/aio"
LOG_BASE_PATH = "{}/logs/task".format(AIO_HOME)
OUTPUT_BASE = "/tmp/aio_collected_logs"

RPC_CONFIG = {
    "command": "/opt/aio/airflow/tools/rpc/{}/rpc".format(os.uname().machine),
    "port": 6611
}

DB_CONFIG = {
    "host": None,
    "port": None,
    "user": None,
    "password": None,
    "database": None
}
MYSQL_DEFAULTS_FILE = None


def strip_quotes(s):
    """去除首尾单引号或双引号"""
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
                    DB_CONFIG["port"] = int(value)
                elif key == "AIO_DB_USERNAME":
                    DB_CONFIG["user"] = value
                elif key == "AIO_DB_PASSWORD":
                    DB_CONFIG["password"] = decrypt_enc_password(value)
                elif key == "AIO_DB_NAME":
                    DB_CONFIG["database"] = value

load_config()

if not DB_CONFIG["host"]:
    DB_CONFIG["host"] = "127.0.0.1"
if not DB_CONFIG["port"]:
    DB_CONFIG["port"] = 3306
if not DB_CONFIG["user"]:
    DB_CONFIG["user"] = "root"
if not DB_CONFIG["database"]:
    DB_CONFIG["database"] = "aio"


def get_local_ips():
    """获取本机所有IP地址"""
    try:
        result = subprocess.run(
            ["hostname", "-I"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5
        )
        if result.returncode == 0:
            return set(result.stdout.decode().strip().split())
    except Exception:
        pass
    return {"127.0.0.1"}


LOCAL_IPS = get_local_ips()


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


def execute_mysql_query(sql, database=None):
    db_name = database or DB_CONFIG["database"]
    defaults_file = get_mysql_defaults_file()
    cmd = [
        "/usr/local/mysql/bin/mysql",
        "--defaults-extra-file={}".format(defaults_file),
        db_name, "-N", "-e", sql
    ]
    try:
        result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        if result.returncode != 0:
            print("[ERROR] MySQL查询失败: {}".format(result.stderr.decode().strip()))
            return []
        output = result.stdout.decode().strip()
        if not output:
            return []
        return [line.split('\t') for line in output.split('\n') if line]
    except Exception as e:
        print("[ERROR] MySQL查询异常: {}".format(e))
        return []


def is_local(ip):
    return ip in LOCAL_IPS


def parse_execution_datetime(execution_date):
    """将execution_date(UTC)转为+08:00的naive datetime"""
    if not execution_date:
        return None
    dt_str = execution_date.split('+')[0].split('Z')[0]
    try:
        dt_utc = datetime.datetime.strptime(dt_str, "%Y-%m-%dT%H:%M:%S.%f")
    except ValueError:
        dt_utc = datetime.datetime.strptime(dt_str, "%Y-%m-%dT%H:%M:%S")
    return dt_utc + datetime.timedelta(hours=8)


class RPCClient:
    """RPC客户端，封装远程命令执行"""

    def __init__(self):
        self._tested = {}  # ip -> bool 缓存连通性结果

    def test(self, ip):
        if ip in self._tested:
            return self._tested[ip]
        cmd = "{} -h {} -p {} -c 'echo ok'".format(RPC_CONFIG['command'], ip, RPC_CONFIG['port'])
        try:
            result = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
            ok = result.returncode == 0 and b'ok' in result.stdout
        except Exception:
            ok = False
        self._tested[ip] = ok
        return ok

    def exec(self, ip, remote_cmd, timeout=60):
        cmd = "{} -h {} -p {} -c '{}'".format(RPC_CONFIG['command'], ip, RPC_CONFIG['port'], remote_cmd)
        try:
            result = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
            if result.returncode == 0:
                return True, result.stdout
            return False, result.stderr
        except Exception as e:
            return False, str(e).encode()

    def list_files(self, ip, directory):
        """列出远程目录下所有 .log 和 .log.gz 文件"""
        remote_cmd = 'find "{}" -type f \\( -name "*.log" -o -name "*.log.gz" \\) 2>/dev/null'.format(directory)
        ok, output = self.exec(ip, remote_cmd)
        if ok and output.strip():
            return [f for f in output.decode().strip().split('\n') if f]
        return []

    def fetch_file(self, ip, remote_path):
        """拉取远程文件内容"""
        if remote_path.endswith('.gz'):
            remote_cmd = 'base64 "{}"'.format(remote_path)
            ok, output = self.exec(ip, remote_cmd)
            if ok:
                import base64 as b64
                return b64.b64decode(output)
            return None
        else:
            remote_cmd = 'cat "{}"'.format(remote_path)
            ok, output = self.exec(ip, remote_cmd)
            return output if ok else None

    def list_dirs(self, ip, directory):
        """列出远程目录下的子目录名"""
        remote_cmd = 'ls -1 "{}" 2>/dev/null'.format(directory)
        ok, output = self.exec(ip, remote_cmd)
        if ok and output.strip():
            return [d for d in output.decode().strip().split('\n') if d]
        return []


class TaskLogCollector:
    """任务日志收集器"""

    def __init__(self, task_id, stages=None):
        self.task_id = task_id
        self.stages = stages
        self.output_dir = "{}/task_{}".format(OUTPUT_BASE, task_id)
        self.task_info = None
        self.sub_tasks = []
        self.collected_files = []
        self.rpc = RPCClient()

    def query_task_info(self):
        """查询总任务和所有子任务"""
        sql = """
        SELECT id, task_num, execution_batch, task_type, task_status,
               start_time, end_time, crontab_id,
               JSON_UNQUOTE(JSON_EXTRACT(attribute, '$.obj_name')),
               JSON_UNQUOTE(JSON_EXTRACT(attribute, '$.resource_type')),
               JSON_UNQUOTE(JSON_EXTRACT(attribute, '$.db_type')),
               JSON_UNQUOTE(JSON_EXTRACT(attribute, '$.version'))
        FROM aio_total_task WHERE id = {}
        """.format(self.task_id)
        results = execute_mysql_query(sql)
        if not results:
            print("[ERROR] 未找到任务ID: {}".format(self.task_id))
            sys.exit(1)

        row = results[0]
        self.task_info = {
            "id": int(row[0]),
            "task_num": row[1],
            "execution_batch": row[2],
            "task_type": row[3],
            "task_status": row[4],
            "start_time": row[5] if row[5] != "NULL" else None,
            "end_time": row[6] if row[6] != "NULL" else None,
            "crontab_id": int(row[7]) if row[7] not in (None, "", "NULL") else None,
            "attribute": {
                "obj_name": row[8] if row[8] not in ("null", "NULL") else None,
                "resource_type": row[9] if row[9] not in ("null", "NULL") else None,
                "db_type": row[10] if row[10] not in ("null", "NULL") else None,
                "version": row[11] if row[11] not in ("null", "NULL") else None,
            },
        }

        print("任务: {} (ID: {})".format(self.task_info['task_num'], self.task_id))
        print("  类型: {}  状态: {}".format(self.task_info['task_type'], self.task_info['task_status']))

        sql = """
        SELECT id, dag_id, execution_date, src_node_ip, data_node_ip, state,
               JSON_UNQUOTE(JSON_EXTRACT(attribute, '$.log_service_info.log_path')),
               JSON_UNQUOTE(JSON_EXTRACT(attribute, '$.log_service_info.storage_ip')),
               JSON_UNQUOTE(JSON_EXTRACT(attribute, '$.instance_id'))
        FROM aio_sub_task
        WHERE total_task_id = {}
        ORDER BY id
        """.format(self.task_id)
        results = execute_mysql_query(sql)

        for row in results:
            log_path = row[6] if len(row) > 6 and row[6] not in ("NULL", "null") else None
            storage_ip = row[7] if len(row) > 7 and row[7] not in ("NULL", "null") else None
            instance_id = row[8] if len(row) > 8 and row[8] not in ("NULL", "null") else None

            self.sub_tasks.append({
                "id": int(row[0]),
                "dag_id": row[1] if row[1] != "NULL" else None,
                "execution_date": row[2] if row[2] != "NULL" else None,
                "src_node_ip": row[3] if row[3] != "NULL" else None,
                "data_node_ip": row[4] if row[4] != "NULL" else None,
                "state": row[5] if row[5] != "NULL" else None,
                "log_path": log_path,
                "storage_ip": storage_ip,
                "instance_id": int(instance_id) if instance_id else None,
            })

        print("  子任务数: {} (失败: {})".format(
            len(self.sub_tasks),
            sum(1 for s in self.sub_tasks if s['state'] in ('failed', 'failed_uncleaned'))
        ))

    def get_log_base_paths(self, sub_task):
        execution_date = sub_task.get("execution_date")
        dt = parse_execution_datetime(execution_date)
        if dt is None:
            return []
        date_str = dt.strftime("%Y-%m-%d")

        log_path = sub_task.get("log_path")

        if log_path:
            base = "{}/{}/{}/{}".format(LOG_BASE_PATH, date_str, log_path.strip('/'), sub_task['dag_id'])
            return [base]

        attr = self.task_info.get("attribute", {})
        obj_name = attr.get("obj_name") or "unknown"
        resource_type = attr.get("resource_type") or attr.get("db_type") or "unknown"
        version = attr.get("version") or "v3"
        crontab_id = self.task_info.get("crontab_id") or 0
        instance_id = sub_task.get("instance_id")
        dag_id = sub_task.get("dag_id", "")

        candidates = []
        seen = set()
        for num in [instance_id, crontab_id, 0]:
            if num in (None, "", "NULL"):
                continue
            dir_name = "{}_{}_{}".format(obj_name, num, version)
            path = "{}/{}/{}/{}/{}".format(LOG_BASE_PATH, date_str, resource_type, dir_name, dag_id)
            if path not in seen:
                candidates.append(path)
                seen.add(path)

        storage_ip = self.get_storage_ip(sub_task)
        parent_dir = "{}/{}/{}".format(LOG_BASE_PATH, date_str, resource_type)
        prefix = "{}_".format(obj_name)

        if storage_ip and is_local(storage_ip):
            if os.path.isdir(parent_dir):
                for d in os.listdir(parent_dir):
                    if d.startswith(prefix) and os.path.isdir(os.path.join(parent_dir, d)):
                        path = "{}/{}/{}".format(parent_dir, d, dag_id)
                        if path not in seen:
                            candidates.append(path)
                            seen.add(path)
        elif storage_ip:
            dirs = self.rpc.list_dirs(storage_ip, parent_dir)
            for d in dirs:
                if d.startswith(prefix):
                    path = "{}/{}/{}".format(parent_dir, d, dag_id)
                    if path not in seen:
                        candidates.append(path)
                        seen.add(path)

        return candidates

    def get_storage_ip(self, sub_task):
        storage_ip = sub_task.get("storage_ip")
        if storage_ip:
            return storage_ip
        return sub_task.get("data_node_ip")

    def discover_stages(self, storage_ip, base_path):
        if is_local(storage_ip):
            if os.path.isdir(base_path):
                return [d for d in os.listdir(base_path) if os.path.isdir(os.path.join(base_path, d))]
            return []
        else:
            return self.rpc.list_dirs(storage_ip, base_path)

    def collect_stage_logs(self, storage_ip, stage_path, sub_task):
        target_dt = parse_execution_datetime(sub_task.get("execution_date"))
        if target_dt is None:
            return []

        target_prefix = target_dt.strftime("%Y-%m-%dT%H:%M:%S")

        if is_local(storage_ip):
            if not os.path.isdir(stage_path):
                return []
            all_files = []
            for f in os.listdir(stage_path):
                if f.endswith('.log') or f.endswith('.log.gz'):
                    all_files.append(os.path.join(stage_path, f))
        else:
            all_files = self.rpc.list_files(storage_ip, stage_path)

        if not all_files:
            return []

        target_full = target_dt.strftime("%Y-%m-%dT%H:%M:%S.") + \
                      target_dt.strftime("%f")[:6] + "+08:00"

        matched = []
        for f in all_files:
            basename = os.path.basename(f)
            if basename.startswith(target_full):
                matched.append(f)

        if not matched:
            target_sec = target_dt.strftime("%Y-%m-%dT%H:%M:%S")
            for f in all_files:
                basename = os.path.basename(f)
                if basename.startswith(target_sec):
                    matched.append(f)

        return sorted(matched)

    def fetch_and_save(self, storage_ip, remote_path, sub_task_id, stage):
        filename = os.path.basename(remote_path)
        dst_dir = os.path.join(self.output_dir, "subtask_{}".format(sub_task_id), stage)
        os.makedirs(dst_dir, mode=0o777, exist_ok=True)
        dst_file = os.path.join(dst_dir, filename)

        if os.path.exists(dst_file):
            return True

        if is_local(storage_ip):
            shutil.copy2(remote_path, dst_file)
        else:
            content = self.rpc.fetch_file(storage_ip, remote_path)
            if content is None:
                return False
            with open(dst_file, 'wb') as f:
                f.write(content)

        os.chmod(dst_file, 0o666)
        self.collected_files.append({
            "source": "{}:{}".format(storage_ip, remote_path),
            "dest": dst_file,
            "sub_task_id": sub_task_id,
            "stage": stage,
        })
        return True

    def collect(self):
        print("\n" + "=" * 60)
        print("AIO任务日志收集工具 v{}".format(VERSION))
        print("任务ID: {}".format(self.task_id))
        print("=" * 60 + "\n")

        os.makedirs(OUTPUT_BASE, exist_ok=True)
        os.chmod(OUTPUT_BASE, 0o777)

        self.query_task_info()

        if not self.sub_tasks:
            print("\n[WARN] 该任务没有子任务记录")
            return None

        storage_ips = set()
        for st in self.sub_tasks:
            ip = self.get_storage_ip(st)
            if ip:
                storage_ips.add(ip)
        print("  日志存储节点: {}".format(', '.join(sorted(storage_ips))))

        print("\n[1/3] 测试节点连通性...")
        for ip in sorted(storage_ips):
            if is_local(ip):
                print("  {} - 本地".format(ip))
            elif self.rpc.test(ip):
                print("  {} - RPC正常".format(ip))
            else:
                print("  {} - RPC不通! 该节点日志将无法收集".format(ip))

        print("\n[2/3] 收集任务日志...")
        os.makedirs(self.output_dir, exist_ok=True)

        for st in self.sub_tasks:
            storage_ip = self.get_storage_ip(st)
            if not storage_ip:
                print("  子任务 {} - 无存储节点信息，跳过".format(st['id']))
                continue

            if not is_local(storage_ip) and not self.rpc.test(storage_ip):
                print("  子任务 {} ({}) - 节点不可达，跳过".format(st['id'], storage_ip))
                continue

            base_paths = self.get_log_base_paths(st)
            if not base_paths:
                print("  子任务 {} - 无法构造日志路径，跳过".format(st['id']))
                continue

            stages = []
            base_path = None
            for bp in base_paths:
                found = self.discover_stages(storage_ip, bp)
                if found:
                    stages = found
                    base_path = bp
                    break

            if not stages:
                print("  子任务 {} [{}] ({}) - 未找到日志目录, 尝试过: {}".format(
                    st['id'], st['state'], storage_ip, base_paths[0] if base_paths else "无"))
                continue

            if self.stages:
                stages = [s for s in stages if s in self.stages]
                if not stages:
                    print("  子任务 {} - 指定阶段不存在".format(st['id']))
                    continue

            stage_count = 0
            file_count = 0
            for stage in sorted(stages):
                stage_path = "{}/{}".format(base_path, stage)
                matched_files = self.collect_stage_logs(storage_ip, stage_path, st)
                if matched_files:
                    for remote_file in matched_files:
                        if self.fetch_and_save(storage_ip, remote_file, st['id'], stage):
                            file_count += 1
                    stage_count += 1

            state_mark = "*" if st['state'] in ('failed', 'failed_uncleaned') else " "
            print(" {}子任务 {} [{}] ({}) - {} 个阶段, {} 个文件".format(
                state_mark, st['id'], st['state'], storage_ip, stage_count, file_count))

        print("\n[3/3] 打包...")
        if not self.collected_files:
            print("[WARN] 没有收集到任何日志文件")
            if os.path.exists(self.output_dir):
                shutil.rmtree(self.output_dir)
            return None

        manifest_file = os.path.join(self.output_dir, "manifest.json")
        manifest = {
            "task_id": self.task_id,
            "task_info": self.task_info,
            "sub_tasks": self.sub_tasks,
            "collected_files": self.collected_files,
            "collected_at": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        }
        with open(manifest_file, 'w', encoding='utf-8') as f:
            json.dump(manifest, f, indent=2, ensure_ascii=False, default=str)

        timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        package_name = "task_{}_logs_{}.tar.gz".format(self.task_id, timestamp)
        package_path = os.path.join(OUTPUT_BASE, package_name)

        with tarfile.open(package_path, "w:gz") as tar:
            tar.add(self.output_dir, arcname="task_{}_logs".format(self.task_id))

        shutil.rmtree(self.output_dir)
        os.chmod(package_path, 0o666)

        size_mb = os.path.getsize(package_path) / 1024 / 1024
        print("\n" + "=" * 60)
        print("收集完成!")
        print("  文件数: {}".format(len(self.collected_files)))
        print("  输出: {}".format(package_path))
        print("  大小: {:.2f} MB".format(size_mb))
        print("=" * 60 + "\n")
        return package_path


def main():
    if len(sys.argv) >= 2 and sys.argv[1] in ('--help', '-h'):
        print("AIO任务日志收集工具 v{}".format(VERSION))
        print("")
        print("用法: python3 collect_task_logs.py <task_id> [--stages stage1,stage2,...]")
        print("")
        print("说明:")
        print("  根据任务ID，通过RPC从所有相关Worker收集各阶段日志（含重试）")
        print("  部署在Server(CDM)节点，普通用户可直接执行，无需sudo")
        print("")
        print("参数:")
        print("  task_id              任务ID (必需)")
        print("  --stages <stages>    只收集指定阶段，逗号分隔")
        print("                       不指定则自动发现所有已执行阶段")
        print("")
        print("示例:")
        print("  python3 collect_task_logs.py 12147")
        print("  python3 collect_task_logs.py 12147 --stages backup,record")
        print("  python3 collect_task_logs.py 15885 --stages resource_prepare,worker_prepare")
        print("")
        print("输出:")
        print("  /tmp/aio_collected_logs/task_<id>_logs_<timestamp>.tar.gz")
        print("  目录权限777，文件权限666，普通用户可直接读取拷走")
        print("")
        print("输出目录结构:")
        print("  task_<id>_logs/")
        print("    manifest.json")
        print("    subtask_<sub_id>/")
        print("      <stage>/")
        print("        <timestamp>_<try_number>.log[.gz]")
        print("")
        print("依赖:")
        print("  - /opt/aio/cfg/aio.env (数据库连接配置)")
        print("  - /opt/aio/airflow/tools/rpc/*/rpc (远程日志拉取)")
        print("  - /usr/local/mysql/bin/mysql (数据库查询)")
        sys.exit(0)

    if len(sys.argv) >= 2 and sys.argv[1] in ('--version', '-v'):
        print("v{}".format(VERSION))
        sys.exit(0)

    if len(sys.argv) < 2:
        print("用法: python3 collect_task_logs.py <task_id> [--stages stage1,stage2,...]")
        sys.exit(1)

    try:
        task_id = int(sys.argv[1])
    except ValueError:
        print("[ERROR] task_id 必须是数字")
        sys.exit(1)

    stages = None
    if '--stages' in sys.argv:
        idx = sys.argv.index('--stages')
        if idx + 1 < len(sys.argv):
            stages = [s.strip() for s in sys.argv[idx + 1].split(',') if s.strip()]

    try:
        load_config()
        collector = TaskLogCollector(task_id, stages=stages)
        collector.collect()
    finally:
        cleanup_mysql_defaults_file()


if __name__ == "__main__":
    main()

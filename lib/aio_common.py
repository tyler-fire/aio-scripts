#!/usr/bin/python3
# -*- coding: utf-8 -*-
# 版本: 1.0.0
"""AIO 运维工具集公共库（Python，兼容 3.6）

此前 aio.env 解析、ENC 解密、mysql defaults-file、RPC 封装、Worker 发现
在每个脚本里各写一份，行为已经出现不一致（例如 stderr 有的合并有的丢弃）。
统一收敛到这里，一处修改处处生效。

用法（各工具脚本开头）:
    SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, os.path.join(SCRIPT_DIR, "lib"))
    import aio_common
"""

import os
import re
import subprocess
import sys
import tempfile

VERSION = "1.0.0"

AIO_HOME = os.environ.get("AIO_HOME", "/opt/aio")
AIO_ENV_FILE = os.path.join(AIO_HOME, "cfg", "aio.env")
RPC_PORT = int(os.environ.get("RPC_PORT", "6611"))


# ---------- aio.env ----------

def strip_quotes(s):
    """去除首尾成对的单引号或双引号"""
    if len(s) >= 2 and s[0] in ("'", '"') and s[-1] == s[0]:
        return s[1:-1]
    return s


def decrypt_enc_password(enc_str):
    """解密 ENC(xxx) 格式的密码；非 ENC 格式或解密失败时原样返回"""
    if not enc_str.startswith("ENC(") or not enc_str.endswith(")"):
        return enc_str
    enc_data = enc_str[4:-1]
    python_bin = "{}/cdm/bin/python3".format(AIO_HOME)
    if not os.path.exists(python_bin):
        python_bin = sys.executable
    try:
        cmd = [
            python_bin, "-c",
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


def load_aio_env(path=None):
    """解析 aio.env，返回 {KEY: value}（引号已剥离，不做 ENC 解密）"""
    env = {}
    path = path or AIO_ENV_FILE
    if not os.path.exists(path):
        return env
    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            key, value = line.split('=', 1)
            env[key.strip()] = strip_quotes(value.strip())
    return env


def load_db_config(require_env=True):
    """读取数据库连接配置（密码已解密），返回 dict。

    require_env=True 时 aio.env 不存在直接报错退出（与旧脚本行为一致）。
    """
    if require_env and not os.path.exists(AIO_ENV_FILE):
        print("[ERROR] 配置文件不存在: {}".format(AIO_ENV_FILE))
        sys.exit(1)
    env = load_aio_env()
    port = env.get("AIO_DB_PORT")
    return {
        "host": env.get("AIO_DB_HOSTNAME") or "127.0.0.1",
        "port": int(port) if port else 3306,
        "user": env.get("AIO_DB_USERNAME") or "root",
        "password": decrypt_enc_password(env.get("AIO_DB_PASSWORD") or ""),
        "database": env.get("AIO_DB_NAME") or "aio",
    }


def load_broker_url():
    """从 airflow.runtime.env 读取 Celery broker url，不存在返回 None"""
    runtime_file = "{}/cfg/airflow.runtime.env".format(AIO_HOME)
    if not os.path.exists(runtime_file):
        return None
    with open(runtime_file) as f:
        for line in f:
            line = line.strip()
            if line.startswith("AIRFLOW__CELERY__BROKER_URL="):
                return line.split("=", 1)[1].strip()
    return None


# ---------- mysql ----------

class MySQL(object):
    """mysql 客户端封装：defaults-extra-file 管理 + 查询。

    query() 出错时返回 []，错误信息存 last_error（旧脚本大多静默返回 []，
    统一改为可查询错误，调用方决定是否打印）。
    """

    def __init__(self, db_config=None):
        self.db_config = db_config or load_db_config()
        self.defaults_file = None
        self.last_error = None
        self.mysql_bin = "/usr/local/mysql/bin/mysql"
        if not os.path.exists(self.mysql_bin):
            self.mysql_bin = "mysql"

    def _defaults_file(self):
        if self.defaults_file and os.path.exists(self.defaults_file):
            return self.defaults_file
        fd, path = tempfile.mkstemp(prefix="aio_mysql_", suffix=".cnf", dir="/tmp")
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w') as f:
            f.write("[client]\n")
            f.write("host={}\n".format(self.db_config["host"]))
            f.write("port={}\n".format(self.db_config["port"]))
            f.write("user={}\n".format(self.db_config["user"]))
            f.write("password={}\n".format(self.db_config["password"]))
        self.defaults_file = path
        return path

    def query(self, sql, database=None, timeout=30):
        """执行 SQL，返回 [[col, ...], ...]；失败返回 [] 并记录 last_error"""
        self.last_error = None
        cmd = [
            self.mysql_bin,
            "--defaults-extra-file={}".format(self._defaults_file()),
            database or self.db_config["database"], "-N", "-B", "-e", sql,
        ]
        try:
            result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        except Exception as e:
            self.last_error = str(e)
            return []
        if result.returncode != 0:
            self.last_error = result.stderr.decode('utf-8', errors='ignore').strip()
            return []
        output = result.stdout.decode('utf-8', errors='ignore').strip()
        if not output:
            return []
        return [line.split('\t') for line in output.split('\n') if line]

    def execute(self, sql, database=None, timeout=30):
        """执行写 SQL；失败抛 RuntimeError"""
        self.last_error = None
        rows = self.query(sql, database=database, timeout=timeout)
        if self.last_error:
            raise RuntimeError(self.last_error)
        return rows

    def cleanup(self):
        if self.defaults_file and os.path.exists(self.defaults_file):
            os.remove(self.defaults_file)
        self.defaults_file = None


# ---------- RPC ----------

def rpc_bin():
    """rpc 二进制路径：优先 uname -m 原始值，找不到时 amd64->x86_64、arm64->aarch64"""
    raw_arch = os.uname().machine
    path = "{}/airflow/tools/rpc/{}/rpc".format(AIO_HOME, raw_arch)
    fallback = {"amd64": "x86_64", "arm64": "aarch64"}.get(raw_arch)
    if not os.access(path, os.X_OK) and fallback:
        alt = "{}/airflow/tools/rpc/{}/rpc".format(AIO_HOME, fallback)
        if os.access(alt, os.X_OK):
            return alt
    return path


def rpc_run(host, command, port=RPC_PORT, timeout=60):
    """RPC 远端执行，返回 (rc, stdout, stderr)；异常/超时返回 rc=124/-1。

    统一不用 shell=True 拼接，避免命令里引号被二次解释。
    """
    cmd = [rpc_bin(), '-h', host, '-p', str(port), '-c', command]
    try:
        result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, b"", "RPC 命令超时({}秒)".format(timeout).encode()
    except Exception as e:
        return -1, b"", str(e).encode()
    return result.returncode, result.stdout, result.stderr


def describe_rpc_error(host, rc, stderr_bytes, port=RPC_PORT):
    """把 RPC 失败翻译为统一的中文提示"""
    stderr = (stderr_bytes or b"").decode('utf-8', errors='ignore').strip()
    lower = stderr.lower()
    if rc == 124 or 'timed out' in lower or 'timeout' in lower:
        return "Worker {} RPC 连接超时".format(host)
    if 'connection refused' in lower or 'connect failed' in lower:
        return "Worker {} RPC 连接失败（端口 {} 不可达）".format(host, port)
    if 'no route to host' in lower or 'host is unreachable' in lower:
        return "Worker {} 网络不可达".format(host)
    if stderr:
        return "Worker {} RPC 执行失败: {}".format(host, stderr[:100])
    return "Worker {} RPC 返回错误（退出码 {}）".format(host, rc)


# ---------- Worker 发现 ----------

def discover_workers(mysql, broker_url=None):
    """发现 Worker 节点 IP 列表。

    优先通过 Celery inspect 找活跃队列再映射 IP，失败回落到直接查 aio_data_nodes。
    """
    if broker_url:
        python_bin = "{}/airflow/bin/python3".format(AIO_HOME)
        if not os.path.exists(python_bin):
            python_bin = sys.executable
        script = (
            "from celery import Celery; "
            "app = Celery(broker='{}'); "
            "active = app.control.inspect(timeout=5).active_queues() or {{}}; "
            "print('\\n'.join(n.split('@',1)[-1] for n in sorted(active)))"
        ).format(broker_url)
        queues = []
        try:
            r = subprocess.run([python_bin, "-c", script],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
            if r.returncode == 0 and r.stdout.decode().strip():
                queues = [n.strip() for n in r.stdout.decode().strip().split('\n') if n.strip()]
        except Exception:
            pass
        if queues:
            rows = mysql.query(
                "SELECT sys_dn_ipaddr FROM aio_data_nodes WHERE sys_dn_queue IN ({}) AND sys_dn_is_delete = 0".format(
                    ",".join("'{}'".format(q.replace("'", "''")) for q in queues)
                )
            )
            ips = [row[0].strip() for row in rows if row and row[0].strip()]
            if ips:
                return list(dict.fromkeys(ips))

    rows = mysql.query("SELECT DISTINCT sys_dn_ipaddr FROM aio_data_nodes WHERE sys_dn_is_delete = 0")
    ips = [row[0].strip() for row in rows if row and row[0].strip()]
    return list(dict.fromkeys(ips))


# ---------- 输入 ----------

HOST_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]*$')


def valid_host(host):
    """主机名/IP 统一校验（拼 SQL / 拼远端命令前必须先过这个）"""
    return bool(HOST_RE.match(host or ""))


def setup_readline():
    """启用 readline，让 input() 支持退格/中文编辑不乱码"""
    try:
        import readline  # noqa: F401
    except Exception:
        pass


# ---------- 脱敏 ----------
# 与 aio-collect-hang-logs.sh 的 sanitize_text_file 保持同一套规则：
#   1) URL 内嵌凭据  scheme://user:pass@host
#   2) key=value / key: value / key value 形式的敏感字段
#   3) JSON "key": "value" 形式的敏感字段

_SENSITIVE_KEYS = (
    r'(?:password|passwd|pwd|token|secret|authorization|'
    r'access[_-]?key|secret[_-]?key|sys_dn_os_passwd|sys_dn_os_password|AIO_DB_PASSWORD)'
)
_URL_CRED_RE = re.compile(r'(://[^:/@\s]+):([^@/\s]+)@')
_KV_RE = re.compile(
    r'(' + _SENSITIVE_KEYS + r'[^0-9A-Za-z_]{0,20}[=: ]+)[^,\'"\s;}]+',
    re.IGNORECASE)
_JSON_RE = re.compile(
    r'(' + _SENSITIVE_KEYS + r'["\']:\s*["\'])[^"\']*',
    re.IGNORECASE)

REDACTED = "***REDACTED***"


def sanitize_text(text):
    """对一段文本做敏感信息脱敏，返回处理后的文本"""
    if not text:
        return text
    text = _URL_CRED_RE.sub(r'\1:' + REDACTED + '@', text)
    text = _KV_RE.sub(r'\1' + REDACTED, text)
    text = _JSON_RE.sub(r'\1' + REDACTED, text)
    return text


def sanitize_file(path):
    """就地脱敏一个文本文件，返回是否有修改；二进制/不可读文件跳过"""
    try:
        with open(path, 'r', encoding='utf-8', errors='ignore') as f:
            original = f.read()
    except (IOError, OSError):
        return False
    cleaned = sanitize_text(original)
    if cleaned == original:
        return False
    try:
        with open(path, 'w', encoding='utf-8') as f:
            f.write(cleaned)
    except (IOError, OSError):
        return False
    return True

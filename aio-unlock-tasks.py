#!/usr/bin/env python3
# 版本: 1.0.0
import os
import subprocess
import sys
import tempfile

AIO_HOME = "/opt/aio"
MYSQL_BIN = "/usr/local/mysql/bin/mysql"
DB_CONFIG = {"host": "", "port": 3306, "user": "root", "password": "", "database": "aio"}
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
            "%s/cdm/bin/python3" % AIO_HOME, "-c",
            "import sys, base64, os; "
            "sys.path.insert(0, '%s/cdm/lib/python3.6/site-packages'); "
            "from Crypto.Cipher import AES; "
            "from Crypto.Util.Padding import unpad; "
            "from aio.config.key import AES_KEY_BASE_64; "
            "key = base64.b64decode(AES_KEY_BASE_64); "
            "data = base64.b64decode(os.environ['AIO_ENC_DATA']); "
            "decrypted = unpad(AES.new(key, AES.MODE_CBC, IV=b'0000000000000000').decrypt(data), AES.block_size); "
            "sys.stdout.buffer.write(decrypted)" % AIO_HOME
        ]
        env = os.environ.copy()
        env['AIO_ENC_DATA'] = enc_data
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, env=env)
        if r.returncode == 0:
            return r.stdout.decode('utf-8', errors='ignore')
    except Exception:
        pass
    return enc_str


TABLE_SPECS = [
    {
        "table": "aio_total_task",
        "where": "task_status='running'",
        "columns": ["id", "JSON_UNQUOTE(JSON_EXTRACT(attribute, '$.db_type')) as db_type", "obj_name", "task_num", "task_type", "task_status", "start_time", "end_time", "crontab_id", "crontab_id_"],
        "display_columns": ["id", "db_type", "obj_name", "task_num", "task_type", "task_status", "start_time", "end_time", "crontab_id", "crontab_id_"],
        "summary": ["db_type", "obj_name", "task_type", "task_status", "start_time", "end_time"],
        "update_sql": "UPDATE aio_total_task SET task_status='failed' WHERE id={id} AND task_status='running'",
        "action": "task_status -> failed",
    },
    {
        "table": "aio_sub_task",
        "where": "state='running'",
        "columns": ["id", "total_task_id", "state", "dag_id", "run_id", "src_node_ip", "data_node_ip", "create_time"],
        "display_columns": ["id", "total_task_id", "state", "dag_id", "run_id", "src_node_ip", "data_node_ip", "create_time"],
        "summary": ["total_task_id", "state", "dag_id", "src_node_ip", "data_node_ip", "create_time"],
        "update_sql": "UPDATE aio_sub_task SET state='failed' WHERE id={id} AND state='running'",
        "action": "state -> failed",
    },
    {
        "table": "total_task_stat",
        "where": "latest_task_status='running'",
        "columns": ["id", "crontab_id", "obj_name", "task_type", "latest_task_status", "latest_task_create_time"],
        "display_columns": ["id", "crontab_id", "obj_name", "task_type", "latest_task_status", "latest_task_create_time"],
        "summary": ["crontab_id", "obj_name", "task_type", "latest_task_status", "latest_task_create_time"],
        "update_sql": "UPDATE total_task_stat SET latest_task_status='failed' WHERE id={id} AND latest_task_status='running'",
        "action": "latest_task_status -> failed",
    },
    {
        "table": "crontab",
        "where": "state='running'",
        "columns": ["id", "backup_unit_id", "state", "crontab_type", "create_time"],
        "display_columns": ["id", "backup_unit_id", "state", "crontab_type", "create_time"],
        "summary": ["backup_unit_id", "state", "crontab_type", "create_time"],
        "update_sql": "UPDATE crontab SET state='error' WHERE id={id} AND state='running'",
        "action": "state -> error",
    },
    {
        "table": "crontab_",
        "where": "state='running'",
        "columns": ["id", "name", "db_type", "state", "create_time", "update_time"],
        "summary": ["name", "db_type", "state", "create_time", "update_time"],
        "update_sql": "UPDATE crontab_ SET state='error' WHERE id={id} AND state='running'",
        "action": "state -> error",
    },
    {
        "table": "mount_unit_result",
        "where": "mount_status IN ('mounting','deleting','canceling')",
        "columns": ["id", "mount_unit_id", "backup_unit_id", "mount_status", "checkpoint", "started_time"],
        "summary": ["mount_unit_id", "backup_unit_id", "mount_status", "checkpoint", "started_time"],
        "update_sql": "UPDATE mount_unit_result SET mount_status='mount_failed' WHERE id={id} AND mount_status IN ('mounting','deleting','canceling')",
        "action": "mount_status -> mount_failed",
    },
    {
        "table": "restore_unit_record",
        "where": "mount_status IN ('mounting','deleting','canceling')",
        "columns": ["id", "crontab_id", "total_task_id", "mount_status", "checkpoint", "started_time"],
        "summary": ["crontab_id", "total_task_id", "mount_status", "checkpoint", "started_time"],
        "update_sql": "UPDATE restore_unit_record SET mount_status='mount_failed' WHERE id={id} AND mount_status IN ('mounting','deleting','canceling')",
        "action": "mount_status -> mount_failed",
    },
]

TABLE_MAP = dict((item["table"], item) for item in TABLE_SPECS)


def load_config():
    env_path = "%s/cfg/aio.env" % AIO_HOME
    if not os.path.exists(env_path):
        return

    with open(env_path, "r") as handler:
        for raw_line in handler:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
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


def ensure_mysql_defaults_file():
    global MYSQL_DEFAULTS_FILE
    if MYSQL_DEFAULTS_FILE and os.path.exists(MYSQL_DEFAULTS_FILE):
        return MYSQL_DEFAULTS_FILE

    fd, path = tempfile.mkstemp(prefix="aio_unlock_", suffix=".cnf", dir="/tmp")
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w") as handler:
        handler.write("[client]\n")
        handler.write("host=%s\n" % DB_CONFIG["host"])
        handler.write("port=%s\n" % DB_CONFIG["port"])
        handler.write("user=%s\n" % DB_CONFIG["user"])
        handler.write("password=%s\n" % DB_CONFIG["password"])
    MYSQL_DEFAULTS_FILE = path
    return path


def run_mysql(sql):
    defaults_file = ensure_mysql_defaults_file()
    result = subprocess.run(
        [MYSQL_BIN, "--defaults-extra-file=%s" % defaults_file, DB_CONFIG["database"], "-N", "-e", sql],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode().strip())
    return result.stdout.decode().strip()


def query_rows(sql, display_columns):
    output = run_mysql(sql)
    if not output:
        return []
    rows = []
    for line in output.splitlines():
        values = line.split("\t")
        row = {}
        for index, column in enumerate(display_columns):
            row[column] = values[index] if index < len(values) else ""
        rows.append(row)
    return rows


C_RESET = "\033[0m"
C_BOLD = "\033[1m"
C_YELLOW = "\033[33m"
C_CYAN = "\033[36m"
C_RED = "\033[31m"

HIGHLIGHT_FIELDS = {
    "id": C_YELLOW + C_BOLD,
    "db_type": C_CYAN,
    "task_status": C_RED,
    "state": C_RED,
    "latest_task_status": C_RED,
    "mount_status": C_RED,
}


def format_fields(row, fields):
    parts = []
    for field in fields:
        value = row.get(field, "")
        color = HIGHLIGHT_FIELDS.get(field, "")
        if color:
            parts.append("%s=%s%s%s" % (field, color, value, C_RESET))
        else:
            parts.append("%s=%s" % (field, value))
    return ", ".join(parts)


def list_running_rows():
    listed = {}
    any_rows = False

    print("\n========== 当前 running / 挂载中 记录 ==========")
    for spec in TABLE_SPECS:
        table = spec["table"]
        display_columns = spec.get("display_columns", spec["columns"])
        sql = "SELECT %s FROM %s WHERE %s" % (",".join(spec["columns"]), table, spec["where"])
        try:
            rows = query_rows(sql, display_columns)
        except Exception as exc:
            print("\n[%s] 查询失败: %s" % (table, exc), file=sys.stderr)
            continue

        if not rows:
            continue

        any_rows = True
        print("\n[%s]" % table)
        for row in rows:
            row_id = row.get("id", "")
            listed[(table, row_id)] = row
            print("  - id=%s%s%s | %s" % (C_YELLOW + C_BOLD, row_id, C_RESET, format_fields(row, spec["summary"])))

    if not any_rows:
        print("\n没有 running 记录")
    return listed


def parse_selection(raw_selection, listed):
    selected = []
    invalid = []
    seen = set()

    id_to_keys = {}
    for table, row_id in listed:
        id_to_keys.setdefault(row_id, []).append(table)

    for part in raw_selection.split(","):
        token = part.strip()
        token = "".join(c for c in token if c.isprintable())
        if not token:
            continue

        if ":" in token:
            table, row_id = token.split(":", 1)
            table = table.strip()
            row_id = row_id.strip()
            if table not in TABLE_MAP:
                invalid.append((token, "未知表名"))
                continue
            try:
                int(row_id)
            except ValueError:
                invalid.append((token, "id 必须是纯数字"))
                continue
            key = (table, row_id)
            if key not in listed:
                invalid.append((token, "当前列表里没有这条记录"))
                continue
        else:
            try:
                int(token)
            except ValueError:
                invalid.append((token, "无效输入"))
                continue
            tables = id_to_keys.get(token, [])
            if not tables:
                invalid.append((token, "当前列表里没有这个ID"))
                continue
            if len(tables) > 1:
                invalid.append((token, "ID在多个表中存在，请用 表名:%s 指定: %s" % (token, ", ".join(t + ":" + token for t in tables))))
                continue
            key = (tables[0], token)

        if key in seen:
            continue
        seen.add(key)
        selected.append(key)

    return selected, invalid


def print_selection_summary(selected, listed):
    print("\n========== 即将执行的标记 ==========")
    for table, row_id in selected:
        spec = TABLE_MAP[table]
        row = listed[(table, row_id)]
        print("  - %s:%s | %s | action=%s" % (table, row_id, format_fields(row, spec["summary"]), spec["action"]))


def apply_updates(selected):
    print("\n========== 执行结果 ==========")
    applied = 0
    failed = 0
    for table, row_id in selected:
        spec = TABLE_MAP[table]
        sql = spec["update_sql"].format(id=int(row_id))
        try:
            run_mysql(sql)
            applied += 1
            print("  OK: %s:%s" % (table, row_id))
        except Exception as exc:
            failed += 1
            print("  FAIL: %s:%s -> %s" % (table, row_id, exc))
    print("\n完成: 成功 %s 条, 失败 %s 条" % (applied, failed))


def main():
    load_config()
    listed = list_running_rows()
    if not listed:
        return

    print("\n请输入要标记的记录ID，多个用逗号分隔。输入 q 退出。")
    if listed:
        all_ids = sorted(set(k[1] for k in listed), key=int)
        print("  可选ID: %s" % ", ".join(all_ids))
    raw_selection = input("> ").strip()
    if raw_selection.lower() == "q":
        print("已取消")
        return

    selected, invalid = parse_selection(raw_selection, listed)
    if invalid:
        print("\n以下输入无效:")
        for token, reason in invalid:
            print("  - %s -> %s" % (token, reason))
    if not selected:
        print("\n没有可执行的目标，退出")
        return

    print_selection_summary(selected, listed)
    confirm = input("\n确认执行? [y/N]: ").strip()
    if confirm not in ("y", "Y"):
        print("已取消")
        return

    apply_updates(selected)


if __name__ == "__main__":
    main()

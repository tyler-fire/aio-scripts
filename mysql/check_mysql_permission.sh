# 检测实例是否运行
$BASEDIR/bin/mysqladmin -h$IP -u$USER -p$PASSWORD -P$PORT  ping

# 检测binlog是否开启
BINLOG_STATUS=`$BASEDIR/bin/mysql -h$IP -u$USER -p$PASSWORD -P$PORT -N -e "show variables like 'log_bin';"`
BINLOG_PATTERN=`echo "$BINLOG_STATUS"|grep -E '(.*)ON$'`
if [ -z "$BINLOG_PATTERN" ]; then
  echo "binlog 未开启"
  exit 1
fi

# 获取mysql版本
MYSQL_VER=`$BASEDIR/bin/mysql -h$IP -u$USER -p$PASSWORD -P$PORT -s -e "select @@version"`
VERSION=`echo $MYSQL_VER |awk -F'-' '{print $1}'|awk -F'.' '{print $1}'`

# 权限检测
RESULT=`$BASEDIR/bin/mysql -h$IP -u$USER -p$PASSWORD -P$PORT -N -e "select distinct user from mysql.user where user='${USER}'
and select_priv='y'
and create_priv='y'
and insert_priv='y'
and reload_priv='y'
and lock_tables_priv='y'
and Repl_client_priv='y'
and Create_tablespace_priv='y'
and Process_priv='y'
and Super_priv='y'"`

if [ -z "$RESULT" ]; then
  echo "用户权限不足"
  exit 1
fi

if [ "$VERSION" == "8" ]; then
  RESULT=`$BASEDIR/bin/mysql -h$IP -u$USER -p$PASSWORD -P$PORT -N -e "select user from mysql.global_grants where user='root' and priv='backup_admin';"`
  if [ -z "$RESULT" ]; then
    echo "缺少backup_admin权限"
    exit 1
  fi
fi

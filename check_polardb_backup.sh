#!/bin/bash

MYSQL_CMD="$BASEDIR/bin/mysql --no-defaults -u$DB_USER -p$DB_PASSWORD -P$DB_PORT -h$IPADDR"
MYSQLADMIN_CMD="$BASEDIR/bin/mysqladmin --no-defaults -u$DB_USER -p$DB_PASSWORD -P$DB_PORT -h$IPADDR"

if [ ! -d "$BASEDIR" ];then
  echo "安装路径不存在">&2
  exit 1
fi

# 获取MySQL实例的版本
mysql_version=`$BASEDIR/bin/mysql --no-defaults --version | awk -F "Ver" '{print $2}'| awk -F " " '{print $1}' |grep -Eo "([0-9]{1,}\.)+[0-9]{1,}"`
if [ ! -n "$mysql_version" ]; then
  mysql_version=`$BASEDIR/bin/mysql --no-defaults --version | awk -F "Distrib" '{print $2}'| awk -F "," '{print $1}' |grep -Eo "([0-9]{1,}\.)+[0-9]{1,}"`
else
  mysql_version=$mysql_version
fi

# 检测MySQL实例是否运行
is_alived=`$MYSQLADMIN_CMD ping | grep 'mysqld is alive' | wc -l`
if [ $is_alived == "1" ];then
  is_alived=true
else
  is_alived=false
fi

# binlog是否开启
is_open_binlog=`$MYSQL_CMD -N -e "show variables like 'log_bin';"  | grep 'ON' | wc -l`
if [ $is_open_binlog == "1" ];then
  is_open_binlog=true
else
  is_open_binlog=false
fi

# 检查配置文件是否存在
if [ -f $DEFAULTS_FILE ]; then
  is_exist_cnf=true
else
  is_exist_cnf=false
fi

# 获取数据文件目录路径
datadir=`$MYSQL_CMD -N -e "show variables like 'datadir';" | awk '{print $2}'`

# 数据库用户权限
privileges=`$MYSQL_CMD -N -e "show GRANTS FOR CURRENT_USER;" `

result='{"mysql_version": "'${mysql_version}'", "mysql_alived": '${is_alived}' , "is_open_binlog": '${is_open_binlog}' , "mysql_cnf_path_exist": '${is_exist_cnf}',  "datadir": "'${datadir}'", "privileges": "'${privileges}'"}'

echo "${result}"

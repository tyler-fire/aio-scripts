#!/bin/bash


# 检测实例是否运行
is_alived=`sudo su - $SCHEMA_USER -c "$BASEDIR/bin/mysqladmin --no-defaults -u$DB_USER -p"${DB_PASSWORD}" -P$DB_PORT -h$IPADDR ping" | grep 'mysqld is alive' | wc -l`
if [ $is_alived -eq 1 ];then
  is_alived=true
else
  is_alived=false
fi


# 获取实例的版本
mysql_version=`sudo su - $SCHEMA_USER -c "$BASEDIR/bin/mysql --no-defaults --version" | grep -Eo "([0-9]{1}\.){2}[0-9]{1,}"`


# 实例是否开启binlog
is_open_binlog=`sudo su - $SCHEMA_USER -c "$BASEDIR/bin/mysql --no-defaults -u$DB_USER -p"${DB_PASSWORD}" -P$DB_PORT -h$IPADDR -N -e \"show variables like 'log_bin';\" " | grep 'ON' | wc -l`
if [ $is_open_binlog -eq 1 ];then
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
datadir=`sudo su - $SCHEMA_USER -c "$BASEDIR/bin/mysql --no-defaults -u$DB_USER -p"${DB_PASSWORD}" -P$DB_PORT -h$IPADDR -N -e \"show variables like 'datadir';\" " | awk '{print $2}'`


# 数据库用户权限
privileges=""`sudo su - $SCHEMA_USER -c "$BASEDIR/bin/mysql --no-defaults -u$DB_USER -p"${DB_PASSWORD}" -P$DB_PORT -h$IPADDR -N -e \"show GRANTS FOR CURRENT_USER;\" "`

result='{"mysql_version": "'${mysql_version}'", "mysql_cnf_path_exist": '${is_exist_cnf}',"is_open_binlog": '${is_open_binlog}', "mysql_alived": '${is_alived}', "datadir": "'${datadir}'", "privileges": "'${privileges}'"}'

echo "${result}"

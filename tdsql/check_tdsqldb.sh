#!/bin/bash


# 检测实例是否运行
is_alived=`sudo $BASEDIR/bin/mysql --socket=$SOCKET -u$DB_USER -p'$DB_PASSWORD' -P$DB_PORT ping  | grep 'mysqld is alive' | wc -l`
if [ $is_alived ];then
  is_alived=true
else
  is_alived=false
fi


# 实例是否开启binlog
is_open_binlog=`sudo $BASEDIR/bin/mysql --socket=$SOCKET -u$DB_USER -p'$DB_PASSWORD' -P$DB_PORT -N -e "show variables like 'log_bin';" | grep 'ON' | wc -l`
if [ $is_open_binlog ];then
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


# 数据库用户权限
privileges=`sudo $BASEDIR/bin/mysql --socket=$SOCKET -u$DB_USER -p$DB_PASSWORD -P$DB_PORT -N -e 'show GRANTS FOR CURRENT_USER;' `
result='{"mysql_cnf_path_exist": '${is_exist_cnf}', "is_open_binlog": '${is_open_binlog}', "privileges": "'${privileges}'"}'

echo "${result}"

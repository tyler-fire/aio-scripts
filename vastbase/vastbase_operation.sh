#!/bin/bash

help() {
    echo 'Usage:'
    echo "/bin/bash $0 [OPTION]... [DBNAME [USERNAME]]"
    echo 'General options:'
    echo '  -d, --dbname=DBNAME             database name to connect to (default: "vastbase")'
    echo '  -p, --port=PORT                 database server port (default: "5432")'
    echo '  -U, --username=USERNAME         database user name (default: "vastbase")'
    echo '  -W, --password=PASSWORD         the password of specified database user'
    echo '  -b, --bindir=BINDIR             installation directory of the database'
    echo '  -k, --kernel_path=KERNEL_PATH   installation directory of the database'
    echo '  -s, --wal_script=WAL_SCRIPT     wal_log script path'
    echo '  -t, --tag=TAG                   add tag to backup'
    echo '  -f, --func=FUNC                 the name of the function that needs to be called'
}

# 脚本命令执行状态 - 失败立即中断执行
Execute_status () {
    status=$?
    if [ ${status} -ne 0 ]; then
        exit ${status}
    fi
}

GETOPT_ARGS=$(getopt -o d:p:U:W:b:k:s:t::f: --long dbname:port:username:password:kernel_path:bindir:wal_script:tag::func:,help -n "$0" -- "$@")
[[ $? -ne 0 || $# -le 0 ]] && { echo "Try '$0 --help' for more information."; exit 1; }

eval set -- "$GETOPT_ARGS"

while true;do
    case "$1" in
        -d|--dbname) DB_NAME=$2; shift 2;;
        -p|--port) PORT=$2; shift 2;;
        -U|--username) USERNAME=$2; shift 2;;
        -W|--password) PASSWORD=$2; shift 2;;
        -b|--bindir) BINDIR=$2; shift 2;;
        -k|--kernel_path) KERNEL_PATH=$2; shift 2;;
        -s|--wal_script) WAL_SCRIPT=$2; shift 2;;
        -t|--tag) TAG=$2; shift 2;;
        -f|--func) FUNC=$2; shift 2;;
        --help)
            help
            exit 0;;
        --)
            shift
            break;;
        *)
            help
            exit 1;;
    esac
done

vsqlconn="$BINDIR/vsql -d $DB_NAME -p $PORT -U $USERNAME -W $PASSWORD -q -t"
KERNEL_VERSION=$(uname -r)


get_db_info(){
    db_is_valid="True"
    login_error_info=""
    login_error_info=$($vsqlconn -c "select 1;" 2>&1)
    if [ $? -gt 0 ];then
        db_is_valid="False"
        return
    else
        login_error_info=""
    fi
    archive_command=$(echo $($vsqlconn -c "show archive_command") | awk '{$1=$1};1')
    archive_dest=$(echo $($vsqlconn -c "show archive_dest") | awk '{$1=$1};1')
    archive_mode=$(echo $($vsqlconn -c "show archive_mode") | awk '{$1=$1};1')
    data_directory=$(echo $($vsqlconn -c "show data_directory") | awk '{$1=$1};1')
    wal_level=$(echo $($vsqlconn -c "show wal_level") | awk '{$1=$1};1')
    version=$(echo $($vsqlconn -c "select version();") | awk '{$1=$1};1')

}


set_archive_command(){
    # 1. 获取用户原来的配置
    archive_command=$(echo $($vsqlconn -c "show archive_command;") | awk '{$1=$1};1')
    Execute_status
    # 2. 判断设置是否已存在，不存在则追加
    if [[ $archive_command =~ $WAL_SCRIPT ]]; then
        echo "vastbase 的 archive_command 配置已存在脚本路径"
        # 3. 切换日志
        $vsqlconn -c "select pg_switch_xlog();"
        Execute_status
    else
        if [ -n "$archive_command" ];then
            new_archive_command="$archive_command;$WAL_SCRIPT"
        else
            new_archive_command="$WAL_SCRIPT"
        fi
        echo "$new_archive_command"
        # 3. 设置新配置
        $vsqlconn -c "alter system set archive_command='$new_archive_command %p %f';"
        Execute_status
        # 4. 重载配置
        $vsqlconn -c "select pg_reload_conf();"
        Execute_status
        # 5. 切换日志
        $vsqlconn -c "select pg_switch_xlog();"
        Execute_status
        echo "修改配置成功"
    fi
}

start_backup(){
    set -e
    result=$($vsqlconn -c "select pg_xlogfile_name(pg_start_backup('$TAG',false, true));")
    echo "$result"
}
stop_backup(){
    set -e
    result=$($vsqlconn -c "select pg_xlogfile_name(pg_stop_backup());")
    echo "$result"
}
switch_log(){
    set -e
    result=$($vsqlconn -c "select pg_xlogfile_name(pg_switch_xlog());")
    echo "$result"
}

check_fsbackup_kernel(){
    kernel_status="True"
    fsbackupKernelPath="$KERNEL_PATH/$KERNEL_VERSION/fsbackup.ko"
    kernel_error=""
    if [ ! -f "$fsbackupKernelPath" ];then
        kernel_error="file fsbackup.ko does not exist"
        kernel_status="False"
    fi
    result=$(sudo lsmod | grep "fsbackup" | wc -l)
    if [[ $result -eq 0 ]];then
        sudo insmod "$fsbackupKernelPath"
        if [ $? -gt 0 ];then
            kernel_error="insmod fsbackup.ko error"
            kernel_status="False"
        fi
    fi
cat << EOF
========================
{
    "kernel_error": "$kernel_error",
    "kernel_status": "$kernel_status"
}
========================
EOF
}

get_current_wal(){
    set -e
    $vsqlconn -c "select redo_wal_file from pg_control_checkpoint();"
}

get_current_time(){
    set -e
    $vsqlconn -c "select now();"
}

pg_is_in_recovery(){
    set -e
    $vsqlconn -c "select pg_is_in_recovery();"
}

get_wal_by_checkpoint(){
    set -e
    $vsqlconn -c "select redo_wal_file from pg_control_checkpoint();"
}

check_port(){
    set -e
    if netstat -ntlp | grep -q "$PORT";then
        echo TRUE
    else
        echo FALSE
    fi
}


to_json(){
cat << EOF
========================
{
    "db_is_valid": "$db_is_valid",
    "login_error_info": "$login_error_info",
    "archive_command": "$archive_command",
    "archive_dest": "$archive_dest",
    "archive_mode": "$archive_mode",
    "data_directory": "$data_directory",
    "wal_level": "$wal_level",
    "version": "$version"
}
========================
EOF
}

explore(){
    get_db_info
    to_json
}
$FUNC

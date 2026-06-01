#!/bin/bash
# set -x
# 获取入参
# 读取命令行参数并设置变量
while [[ $# -gt 0 ]]
do
    case "$1" in
        BASEDIR=*)
            BASEDIR="${1#*=}"
            shift
            ;;
        DBNAME=*)
            DBNAME="${1#*=}"
            shift
            ;;
        DBPASSWORD=*)
            DBPASSWORD="${1#*=}"
            shift
            ;;
        DBPORT=*)
            DBPORT="${1#*=}"
            shift
            ;;
        *)
            echo "Unknown argument: $1, exiting"
            exit 1
            ;;
    esac
done

# 添加环境变量
export LD_LIBRARY_PATH=$BASEDIR/bin:$LD_LIBRARY_PATH

DISQL_PATH="$BASEDIR/bin/disql"
APSERVICE_PATH="$BASEDIR/bin/DmAPService"
# 全局异常
error_code=0
error_msg=""

# 接收结果
function send_error(){
  local code=$1
  local msg=$2

  if [ ! $code -eq 0 ];then
    error_code=$code
    error_msg=$msg
  fi
}
#sql命令相关处理
function disql_handle(){
  local sql="$1"
  local dm_cdm="$DISQL_PATH -L -S $DBNAME/\"$DBPASSWORD\":$DBPORT -e"
  result=$($dm_cdm "$sql" 2>&1)
  code=$?
  eval $2=$code
  eval $3=\"$result\"
  send_error $code "$result"
}

function cmd_handle(){
    result=$(eval "$1 2>&1")
    code=$?
    eval $2=$code
    eval $3=$result
    if [ $code -ne 0 ] && [[ $result != "" ]];then
        send_error $code $result
    fi
}

function handle(){

    # 获取用户名
    local user_name=""
    disql_handle "SELECT TRIM(USER) FROM DUAL;" code msg
    if [ $code -eq 0 ];then
        user_name=$(echo "$msg" | awk '{print $3}')
    fi

    # 获取数据库名
    local db_name=""
    disql_handle "select TRIM(CUR_DATABASE()) FROM DUAL;" code msg
    if [ $code -eq 0 ];then
        db_name=$(echo "$msg" | awk '{print $3}')
    fi

    # 获取实例名
    local instance_name=""
    disql_handle "select TRIM(SF_GET_PARA_STRING_VALUE(2, 'INSTANCE_NAME')) FROM DUAL;" code msg
    if [ $code -eq 0 ];then
        instance_name=$(echo "$msg" | awk '{print $3}')
    fi

    # 获取端口
    local port_num=0
    disql_handle "select TRIM(convert(varchar, SF_GET_PARA_VALUE(2, 'PORT_NUM'))) FROM DUAL;" code msg
    if [ $code -eq 0 ];then
        port_num=$(echo "$msg" | awk '{print $3}')
    fi

    # 获取版本
    local db_version=""
    disql_handle "select TRIM(id_code()) FROM DUAL;" code msg
    if [ $code -eq 0 ];then
        db_version=$(echo "$msg" | awk '{print $3}')
    fi

    # 获取归档情况
    local arch_mode="False"
    disql_handle "select arch_mode from v\$database" code msg
    if [ $code -eq 0 ];then
        arch_mode_cmd=$(echo "$msg" | awk '{print $3}')
        if [[ $arch_mode_cmd == "Y" ]]; then
            arch_mode="True"
        fi
    fi

    # 获取大小
    local data_size=0
    disql_handle "select sum(size_mb) as db_size from (select sum(bytes) AS size_mb FROM dba_data_files union all select sum(RLOG_SIZE) AS size_mb from v\$rlogfile);" code msg
    if [ $code -eq 0 ];then
        data_size=$(echo "$msg" | awk '{print $3}')
    fi

    # # 获取ap server状态
    ap_status="stop"
    if [[ -f $APSERVICE_PATH ]] && $APSERVICE_PATH status | grep -v grep | grep -q "running" >/dev/null 2>&1;then
        ap_status="running"
    fi

    # 判断达梦进程是否存活
    is_active="False"
    if ps -ef | grep -i dmserver | grep -v grep >/dev/null 2>&1;then
        is_active="True"
    fi

    result="{
        \"code\":$error_code,
        \"msg\":\"$error_msg\",
        \"user_name\":\"$user_name\",
        \"db_name\":\"$db_name\",
        \"instance_name\":\"$instance_name\",
        \"port_num\":$port_num,
        \"db_version\":\"$db_version\",
        \"arch_mode\":\"$arch_mode\",
        \"data_size\":$data_size,
        \"is_active\":\"$is_active\",
        \"disql_path\":\"$DISQL_PATH\",
        \"ap_status\":\"$ap_status\"
    }"
    echo $result
}

handle

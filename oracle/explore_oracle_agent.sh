#!/bin/sh
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIO_PROFILE_SCRIPT="$PROJECT_DIR/load_profile.sh"
CURRENT_USER=$(whoami)
sh $AIO_PROFILE_SCRIPT && source "$PROJECT_DIR/$CURRENT_USER.profile"

help() {
  echo "sh getLogSequence.sh"
}

while getopts 'e:m:i:h' OPT; do
    case $OPT in
      e) explore_type="$OPTARG";;
      m) oracle_home="$OPTARG";;
      i) instance_name="$OPTARG";;
      h) help;;
    esac
done

Get_Oracle_Instance() {
    # 获取所有oracle实例的sid
    oracle_sid_ls=`ps -ef | grep ora_pmon | grep -vw grep | awk '{print $NF}' | cut -d'_' -f 3-`
    # oracle_sid_env=`echo $ORACLE_SID`
    # if [ -n "$oracle_sid_ls" ];then
    #     if [[ $oracle_sid_ls != *"$oracle_sid_env"* ]];then
    #         oracle_sid_ls+=" "
    #         oracle_sid_ls+=$oracle_sid_env
    #     fi
    # else
    #     oracle_sid_ls+=$oracle_sid_env
    # fi
    # 获取oracle实例的数量
    database_enable=`ps -ef | grep ora_pmon | grep -vw grep | awk '{print $NF}' | wc -l`
}

Get_Oracle_Home() {
    oracle_home_ls=()
    # for oracle_sid in $oracle_sid_ls;do
    #     oracle_sid_pid=`ps -ef | grep -w "..._pmon_$oracle_sid" | grep -vw grep | grep -vw strings | awk '{print $2}' | head -1`
    #     if [[ ! -r "/proc/$oracle_sid_pid/environ" ]]; then
    #         continue
    #     fi
    #     oracle_home=`strings /proc/$oracle_sid_pid/environ | grep ^ORACLE_HOME= | awk -F'=' '{print $NF}'`
    #     oracle_home_ls+=$oracle_home
    #     oracle_home_ls+=" "
    # done
    # oracle_home=`strings /etc/oratab | awk -F ':' '{print $2}'`
    # oracle_home_ls+=$oracle_home
    # oracle_home_ls+=" "
}

Get_Oracle_Home_Conf () {
    # 从bash_profile和bashrc中获取oracle home
    profile=("~/.bash_profile" "~/.bashrc")
    for file in ${profile[*]}; do

        profile_home=`cat $(eval echo $file) | grep ORACLE_HOME= | sed -r "s/.*ORACLE_HOME=(.*)/\1/g"`
        if [[ ${profile_home} =~ "ORACLE_BASE" ]];then
            ORACLE_BASE=`cat $(eval echo $file) | grep ORACLE_BASE= | sed -r "s/.*ORACLE_BASE=(.*)/\1/g" | awk '$1=$1'`
            profile_home=`eval echo ${profile_home/$ORACLE_BASE/$oracle_base}`
        fi
        oracle_home_ls+=" "
        oracle_home_ls+=$profile_home
    done
}

Get_Oracle_Home_By_Env() {
    # 获取oracle home的环境变量
    oracle_home_env=`echo $ORACLE_HOME`
    oracle_home_ls+=" "
    oracle_home_ls+=$oracle_home_env
}

Get_Oracle_Version() {
    # 获取oracle版本
    oracle_version=`$oracle_home/bin/sqlplus -version | awk -F ":" '{ print $2 }' | awk '{printf $0}' | awk '$1=$1' | sed -r "s/.* ([0-9]+.*) .*/\1/g" | awk -F " " '{ print $1 }'`
}

Get_Grid_Home() {
    # 获取asm数据库实例名
    grid_home=`grep -v "^[#]" /etc/oratab |grep -i "+ASM" | head -n1 | cut -f2 -d":"`
    if [ -z $grid_home ];then
		grid_home=`echo $GRID_HOME`
	fi
}

check_RAC_Cluster_Command() {
    Get_Grid_Home
    # 判断本地节点上的核心 Oracle 集群协调服务（Cluster Ready Services, CRS）是否正常运行。
    result=`$grid_home/bin/crsctl check crs | grep "Cluster Ready Services is online"`
    if [[ ! -z $result ]]; then
        rac_cluster="TRUE"
    else
        rac_cluster="FALSE"
    fi
}

Get_Oracle_RAC_Cluster (){
    # 查询是否是RAC数据库
    query_sql="select value from v\$parameter where name = 'cluster_database';"
    Run_Oracle_Inquire_Statement $query_sql
    rac_cluster=$retval
}

Get_Oracle_ASM_DISK(){
    # 查询ASM数据库磁盘信息
    query_sql="SELECT name,TOTAL_MB FROM V\$ASM_DISKGROUP;"
    Run_Oracle_Inquire_Statement $query_sql
    variable=$retval
	json_array=()
	size_arr=($variable)

	# 使用循环迭代数组中的元素，每次取两个元素作为一个键值对
	for ((i=0; i<${#size_arr[@]}; i+=2)); do
		asm_disk=${size_arr[$i]}
		size=${size_arr[$i+1]}
        size_g=$((size /1024))
		json_obj="{\"asm_disk\": \"$asm_disk\", \"size\": \"$size_g\"}"
		json_array+=("$json_obj")
	done

	asm_dict=$(IFS=','; echo "${json_array[*]}")
}

Get_ASM_USER(){
    # 查询asm用户名
    asm_user=$(ps -ef | grep asm | grep -w asm_smon.* | head -n 1 | awk '{print $1}')
}

Get_Oracle_ASM_VALUE (){
    # 查询ASM数据库实例数量
    query_sql="select count(1) from v\$datafile where name like '+%%';"
    Run_Oracle_Inquire_Statement $query_sql
    if [[ $retval -gt 0 ]]; then
        is_asm="TRUE"
        Get_Oracle_ASM_DISK
        Get_ASM_USER
    else
        is_asm="FALSE"
    fi
}

Get_Oracle_is_CDB() {
    # 判断是否是CDB数据库
    basics_version=`echo $oracle_version | awk '{split($1, arr, "."); print arr[1]}'`
    if [ "$basics_version" -ge "12" ]; then
        query_sql="select cdb from v\$database;"
        Run_Oracle_Inquire_Statement $query_sql
        if [[ $retval == "YES" ]]; then
            is_cdb="TRUE"
        else
            is_cdb="FALSE"
        fi
    else
        is_cdb="FALSE"
    fi
}

Get_Oracle_pdbs() {
    # 获取PDB数据库信息
    PDBS_RESULT=$(echo "select 'pdbs '||con_id||' '||name||' '||replace(open_mode,' ','-')||' '||total_size from v\$pdbs;" | $oracle_home/bin/sqlplus / as sysdba | grep 'pdbs')
    OLD_IFS=$IFS
    IFS=$'\n'

    pdbs=()
    for line in $PDBS_RESULT
    do
    IFS=$' '
    read sign con_id name open_mode total_size <<< $line
    if [[ $name == "PDB\$SEED" ]]; then
    continue
    fi
    if [[ $total_size -gt 0 ]]; then
        data_size=`echo "scale=2;$total_size/1024/1024/1024"| bc`
        if [[ $data_size == \.* ]]; then
            data_size="0"$data_size
        fi
    else
        data_size=$total_size
    fi
    pdb_dict=`echo $(eval echo '{\"con_id\": \""$con_id"\", \"name\": \""$name"\", \"open_mode\": \""$open_mode"\", \"data_size\": \""$data_size"\"}')`
    pdb_dict+=","
    pdbs+=$pdb_dict
    done
    IFS=$OLD_IFS
}

Get_Host_Name() {
    host_name=`hostname`
}

Get_Srvctl_Config_Database() {
    oracle_database=`$oracle_home/bin/srvctl config database`
    cluster_node_name=`$oracle_home/bin/srvctl config database -d $oracle_database | grep "Configured nodes" | cut -d':' -f 2-`
    OLD_IFS="$IFS"
    IFS=","
    node_host_ls=()
    for node in $cluster_node_name; do
        node_host_ls+=$node
        node_host_ls+=" "
    done
    IFS="$OLD_IFS"
}

Get_Oracle_Cluster_Node() {
    if [[ $database_enable -gt 0 ]]; then
        query_sql="select host_name from gv\$instance;"
        Run_Oracle_Inquire_Statement $query_sql
        node_host_ls=`echo $retval`
    else
        Get_Srvctl_Config_Database
    fi
}

Get_Oracle_Cluster_INFO() {
    Get_Oracle_Cluster_Node
    for node_host in $node_host_ls;do
        query_sql="select version from gv\$instance where host_name='$node_host';"
        Run_Oracle_Inquire_Statement $query_sql
        node_version=`echo $retval`
        node_ippadr=`grep $node_host /etc/hosts | grep -v '^#' | head -n 1 | awk '{print $1}'`

        node_dict=`echo $(eval echo '{\"node_host\": \""$node_host"\", \"node_version\": \""$node_version"\", \"node_ippadr\": \""$node_ippadr"\", \"connection\": \"\", \"iscsiadm\": \"\"}')`
        node_dict+=","
        node_arr+=$node_dict
    done
    # node_arr=`echo ${node_arr%%*,}`
    node_arr=`echo ${node_arr%,}`
}

Oracle_Database_PreCheck() {
    COMBINED_RESULT=$("${oracle_home}"/bin/sqlplus -S /nolog <<'EOSQL'
    set heading off feedback off pagesize 0 verify off echo off;
    set linesize 1000;
    conn / as sysdba;

    prompt ===DB_NAME_START===
    select value from v$parameter where name = 'db_name';
    prompt ===DB_NAME_END===

    prompt ===DB_UNIQUE_NAME_START===
    select value from v$parameter where name = 'db_unique_name';
    prompt ===DB_UNIQUE_NAME_END===

    prompt ===LOG_MODE_START===
    select log_mode from v$database;
    prompt ===LOG_MODE_END===

    prompt ===BCT_STATUS_START===
    select status from v$block_change_tracking;
    prompt ===BCT_STATUS_END===

    prompt ===BANNER_START===
    select banner from v$version where banner like 'Oracle%' and rownum = 1;
    prompt ===BANNER_END===

    prompt ===OPEN_MODE_START===
    select open_mode from v$database;
    prompt ===OPEN_MODE_END===

    prompt ===DATABASE_ROLE_START===
    select database_role from v$database;
    prompt ===DATABASE_ROLE_END===

    prompt ===ASM_COUNT_START===
    select count(name) from gv$datafile where name like '+%';
    prompt ===ASM_COUNT_END===

    prompt ===DBID_START===
    select dbid from v$database;
    prompt ===DBID_END===

    exit;
EOSQL
)

    db_name=$(echo "$COMBINED_RESULT" | sed -n '/===DB_NAME_START===/,/===DB_NAME_END===/p' | grep -v "===" | tr -d ' ')
    db_unique_name=$(echo "$COMBINED_RESULT" | sed -n '/===DB_UNIQUE_NAME_START===/,/===DB_UNIQUE_NAME_END===/p' | grep -v "===" | tr -d ' ')
    archive_status=$(echo "$COMBINED_RESULT" | sed -n '/===LOG_MODE_START===/,/===LOG_MODE_END===/p' | grep -v "===" | tr -d ' ')
    bct_status=$(echo "$COMBINED_RESULT" | sed -n '/===BCT_STATUS_START===/,/===BCT_STATUS_END===/p' | grep -v "===" | tr -d ' ')
    banner_version=$(echo "$COMBINED_RESULT" | sed -n '/===BANNER_START===/,/===BANNER_END===/p' | grep -v "===" | sed -r "s/.* ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+).*/\1/g")
    open_mode=$(echo "$COMBINED_RESULT" | sed -n '/===OPEN_MODE_START===/,/===OPEN_MODE_END===/p' | grep -v "===" | tr -d ' ')
    database_role=$(echo "$COMBINED_RESULT" | sed -n '/===DATABASE_ROLE_START===/,/===DATABASE_ROLE_END===/p' | grep -v "===" | tr -d ' ')
    asm_count=$(echo "$COMBINED_RESULT" | sed -n '/===ASM_COUNT_START===/,/===ASM_COUNT_END===/p' | grep -v "===" | tr -d ' ')
    dbid=$(echo "$COMBINED_RESULT" | sed -n '/===DBID_START===/,/===DBID_END===/p' | grep -v "===" | tr -d ' ')
}

Oracle_Backup_Resource_Precheck() {
    BACKUP_RESULT=$($oracle_home/bin/sqlplus -S /nolog <<'EOSQL'
    set heading off feedback off pagesize 0 verify off echo off;
    set linesize 1000;
    conn / as sysdba;

    prompt ===TEMP_SIZE_START===
    select sum(bytes) from dba_temp_files where tablespace_name like '%TEMP%';
    prompt ===TEMP_SIZE_END===

    prompt ===REDO_LOG_START===
    select group#, bytes from v$log where group# = (select max(group#) from v$log);
    prompt ===REDO_LOG_END===

    prompt ===ARCHIVELOG_START===
    select thread#, round(avg(daily_size)) from (
          SELECT THREAD#, TRUNC(completion_time) "Generation Date",
          round(SUM(blocks*block_size),0) daily_size FROM gv$archived_log
          where completion_time > sysdate - 60 and dest_id = 1
          and to_char(completion_time, 'yyyymmdd') != to_char(resetlogs_time, 'yyyymmdd')
          GROUP BY THREAD#,TRUNC(completion_time) order by THREAD#,TRUNC(completion_time)
        ) group by thread#;
    prompt ===ARCHIVELOG_END===

    prompt ===DATAFILE_PATH_START===
    select distinct case when instr(name, '/') > 0
        then substr(name, 1, instr(name, '/', -1, 2)) else substr(name, 1, instr(name, '\', -1, 2))
        end as device from v$datafile
    union
    select distinct case when instr(name, '/') > 0
        then substr(name, 1, instr(name, '/', -1, 2)) else substr(name, 1, instr(name, '\', -1, 2))
        end as device from v$controlfile
    union
    select distinct case when instr(member, '/') > 0
        then substr(member, 1, instr(member, '/', -1, 2)) else substr(member, 1, instr(member, '\', -1, 2))
        end as device from v$logfile;
    prompt ===DATAFILE_PATH_END===

    prompt ===RMAN_RUNNING_START===
    select count(SID) from v$session_longops where opname like 'RMAN%' and opname not like '%aggregate%' and totalwork != 0 and sofar <> totalwork;
    prompt ===RMAN_RUNNING_END===

    prompt ===LOG_SEQUENCE_START===
    select thread#,max(sequence#) from v$archived_log where FIRST_TIME > (select max(resetlogs_time) from v$archived_log) group by thread#;
    prompt ===LOG_SEQUENCE_END===

    prompt ===DBA_FILE_COUNT_START===
    select count(*) from dba_data_files;
    prompt ===DBA_FILE_COUNT_END===

    exit;
EOSQL
)

    # 解析结果
    dba_temp_size=$(echo "$BACKUP_RESULT" | sed -n '/===TEMP_SIZE_START===/,/===TEMP_SIZE_END===/p' | grep -v "===" | tr -d ' ')
    redo_log_info=$(echo "$BACKUP_RESULT" | sed -n '/===REDO_LOG_START===/,/===REDO_LOG_END===/p' | grep -v "===" | head -1)
    redo_log_count=$(echo $redo_log_info | awk '{ print $1 }')
    redo_log_size=$(echo $redo_log_info | awk '{ print $2 }')
    archivelog_info=$(echo "$BACKUP_RESULT" | sed -n '/===ARCHIVELOG_START===/,/===ARCHIVELOG_END===/p' | grep -v "===" | head -1)
    archivelog_thread=$(echo $archivelog_info | awk '{ print $1 }')
    archivelog_avg_value=$(echo $archivelog_info | awk '{ print $2 }')
    datafile_path=$(echo "$BACKUP_RESULT" | sed -n '/===DATAFILE_PATH_START===/,/===DATAFILE_PATH_END===/p' | grep -v "===" | tr '\n' ',' | sed 's/,$//')
    rman_running_count=$(echo "$BACKUP_RESULT" | sed -n '/===RMAN_RUNNING_START===/,/===RMAN_RUNNING_END===/p' | grep -v "===" | tr -d ' ')
    log_sequence_info=$(echo "$BACKUP_RESULT" | sed -n '/===LOG_SEQUENCE_START===/,/===LOG_SEQUENCE_END===/p' | grep -v "===" | head -1)
    log_thread=$(echo $log_sequence_info | awk '{ print $1 }')
    log_sequence=$(echo $log_sequence_info | awk '{ print $2 }')
    dba_file_count=$(echo "$BACKUP_RESULT" | sed -n '/===DBA_FILE_COUNT_START===/,/===DBA_FILE_COUNT_END===/p' | grep -v "===" | tr -d ' ')
}

Get_Oracle_Resource_Info() {
    # 获取oracle资源信息
    Oracle_Database_PreCheck
    if [[ $explore_type = "backup" ]]; then
        Oracle_Backup_Resource_Precheck
        sid_dict=`echo $(eval echo '{\"oracle_sid\": \""$oracle_sid"\", \"db_name\": \""$db_name"\", \"db_unique_name\": \""$db_unique_name"\", \"log_mode\": \""$archive_status"\",  \"bct_status\": \""$bct_status"\", \"banner_version\": \""$banner_version"\", \"dba_temp_size\": \""$dba_temp_size"\", \"redo_log_count\": \""$redo_log_count"\", \"redo_log_size\": \""$redo_log_size"\", \"database_role\": \""$database_role"\", \"open_mode\": \""$open_mode"\", \"asm_count\": \""$asm_count"\", \"spfile_path\": \""$spfile_path"\", \"archivelog_thread\": \""$archivelog_thread"\", \"archivelog_avg_value\": \""$archivelog_avg_value"\",  \"datafile_path\": \""$datafile_path"\", \"rman_running_count\": \""$rman_running_count"\", \"log_sequence\": \""$log_sequence"\", \"log_thread\": \""$log_thread"\", \"dbid\": \""$dbid"\", \"dba_file_count\": \""$dba_file_count"\", \"tablespace_info\": \""$tablespace_info"\", \"rac_cluster\": \""$rac_cluster"\", \"is_cdb\": \""$is_cdb"\", \"pdbs\": [$pdbs]}')`
    else
        sid_dict=`echo $(eval echo '{\"oracle_sid\": \""$oracle_sid"\", \"db_name\": \""$db_name"\", \"db_unique_name\": \""$db_unique_name"\", \"log_mode\": \""$archive_status"\",  \"bct_status\": \""$bct_status"\", \"banner_version\": \""$banner_version"\", \"database_role\": \""$database_role"\", \"open_mode\": \""$open_mode"\", \"asm_count\": \""$asm_count"\",  \"dbid\": \""$dbid"\", \"rac_cluster\": \""$rac_cluster"\"}')`
    fi
    sid_dict+=","
    sid_arr+=$sid_dict
}

Get_Oracle_Database_Info() {
    for oracle_sid in $oracle_sid_ls;do
        export ORACLE_SID=$oracle_sid
        Get_Oracle_is_CDB
        if [[ $is_cdb == "TRUE" ]]; then
            Get_Oracle_pdbs
            pdbs=`echo $pdbs | awk '{sub(/.$/,"")}1'`
        else
            pdbs=""
        fi
        if [ -z "$rac_cluster" ]; then
            Get_Oracle_RAC_Cluster
        fi
        if [ -z "$is_asm" ]; then
            Get_Oracle_ASM_VALUE
        fi
        if [[ $explore_type = "backup" ]]; then
#            pid=`ps -ef | grep -w "..._pmon_$oracle_sid" | grep -vw grep | grep -vw strings | awk '{print $2}' | head -1`
#            cwd_path=`strings /proc/$pid/environ | grep ^ORACLE_HOME= | awk -F'=' '{print $NF}'`
#            if [[ $cwd_path = $oracle_home ]]; then
                Get_Oracle_Resource_Info
#            fi
        fi
    done
    sid_arr=`echo $sid_arr | awk '{sub(/.$/,"")}1'`
}

Detect_Oracle_Database_Info() {
    export ORACLE_HOME=$oracle_home
    export ORACLE_SID=$instance_name
    Oracle_Database_PreCheck
    oracle_info=`echo $(eval echo '{\"oracle_sid\": \""$instance_name"\", \"db_name\": \""$db_name"\", \"db_unique_name\": \""$db_unique_name"\", \"log_mode\": \""$archive_status"\",  \"bct_status\": \""$bct_status"\", \"banner_version\": \""$banner_version"\", \"dba_temp_size\": \""$dba_temp_size"\", \"redo_log_count\": \""$redo_log_count"\", \"redo_log_size\": \""$redo_log_size"\", \"database_role\": \""$database_role"\", \"open_mode\": \""$open_mode"\", \"asm_count\": \""$asm_count"\", \"bct_status\": \""$bct_status"\", \"spfile_path\": \""$spfile_path"\", \"archivelog_thread\": \""$archivelog_thread"\", \"archivelog_avg_value\": \""$archivelog_avg_value"\",  \"datafile_path\": \""$datafile_path"\", \"rman_running_count\": \""$rman_running_count"\", \"log_sequence\": \""$log_sequence"\", \"log_thread\": \""$log_thread"\"}')`
    echo $oracle_info
}

Explore_Oracle_Info() {
    Get_Oracle_Instance
    # Get_Oracle_Home

    OLD_IFS="$IFS"
	IFS=" "
	array=($oracle_home_ls)
	IFS="$OLD_IFS"
	num=${#array[@]}

	if [ $num -lt 2 ];then
        if [ -z $oracle_home_ls ]; then
			Get_Oracle_Home_By_Env
		fi
		if [ -z $oracle_home_ls ]; then
			Get_Oracle_Home_Conf
		fi
	fi
    Get_is_Grid
    oracle_arr=()
    oracle_home_ls=$(awk -v RS=' ' '!a[$1]++' <<< ${oracle_home_ls[@]})
    for oracle_home in ${oracle_home_ls[@]}; do
        if [ -d $oracle_home ]; then
            export ORACLE_HOME=$oracle_home
            Get_Oracle_Version
            if [[ $database_enable -eq 0 && $is_grid == "True" ]]; then
                check_RAC_Cluster_Command
            fi

            if [[ $database_enable -gt 0 ]]; then
                Get_Oracle_Database_Info
            fi

            if [[ $explore_type = "backup" ]]; then
                oracle_info=`echo $(eval echo '{\"oracle_home\": \""$oracle_home"\", \"oracle_version\": \""$oracle_version"\", \"listener\": \""$listener"\", \"listener_port\": \""$listener_port"\", \"rac_cluster\": \""$rac_cluster"\", \"is_asm\": \""$is_asm"\", \"oracle_instance\": [$sid_arr], \"asm_list\": [$asm_dict]}')`
            elif [[ $explore_type = "mount" &&  $rac_cluster == "TRUE" ]]; then
                Get_Oracle_Cluster_INFO
                oracle_sid_list=$(echo "${oracle_sid_ls}" | tr ' ' ',')
                oracle_sid_list="[\"${oracle_sid_list}\"]"
                oracle_info=`echo $(eval echo '{\"oracle_home\": \""$oracle_home"\", \"oracle_version\": \""$oracle_version"\", \"listener\": \""$listener"\", \"listener_port\": \""$listener_port"\", \"rac_cluster\": \""$rac_cluster"\", \"is_asm\": \""$is_asm"\", \"cluster_node\": [$node_arr], \"asm_list\": [$asm_dict], \"oracle_sid_list\": $oracle_sid_list, \"asm_user\": \""$asm_user"\"}')`
            else
                Get_Host_Name
                oracle_sid_list=$(echo "${oracle_sid_ls}" | tr ' ' ',')
                oracle_sid_list="[\"${oracle_sid_list}\"]"
                oracle_info=`echo $(eval echo '{\"oracle_home\": \""$oracle_home"\", \"oracle_version\": \""$oracle_version"\", \"listener\": \""$listener"\", \"listener_port\": \""$listener_port"\", \"rac_cluster\": \""$rac_cluster"\", \"is_asm\": \""$is_asm"\", \"node_host\": \""$host_name"\", \"asm_list\": [$asm_dict], \"oracle_sid_list\": $oracle_sid_list, \"asm_user\": \""$asm_user"\"}')`
            fi
            oracle_info+="\\n"
            oracle_arr+=$oracle_info
        fi
    done
    echo $oracle_arr
}

Get_Oracle_Info() {
    export LANG="en_US.UTF-8"
    if [[ $explore_type = "detect" ]]; then
        Detect_Oracle_Database_Info
    else
        Explore_Oracle_Info
    fi
}


Get_is_Grid() {
    # 检查ocssd.bin是否在运行
    result=`ps -ef | grep ocssd.bin | grep -vw grep`
    if [ ! -z "$result" ]; then
        is_grid="True"
    else
        is_grid="False"
    fi
}


Run_Oracle_Inquire_Statement() {
    VALUE=`$oracle_home/bin/sqlplus -S /nolog <<EOF
    set heading off feedback off pagesize 0 verify off echo off;
    conn / as sysdba;
    set linesize 500;
    $query_sql
    exit;
EOF`
    result=$(echo $VALUE | grep "ERROR")
    if [ "$result" = "" ]; then
        retval=`echo $VALUE`
    else
        retval=""
    fi
}

Get_Oracle_Info

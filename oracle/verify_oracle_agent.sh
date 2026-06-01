#!/bin/sh
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIO_PROFILE_SCRIPT="$PROJECT_DIR/load_profile.sh"
CURRENT_USER=$(whoami)
sh $AIO_PROFILE_SCRIPT && source "$PROJECT_DIR/$CURRENT_USER.profile"

help() {
  echo "sh verify_oracle.sh"
}

while getopts 'm:s:t:h' OPT; do
    case $OPT in
      m) oracle_home="$OPTARG";;
      s) oracle_sid="$OPTARG";;
	  t) resc_type="$OPTARG";;
      h) help;;
    esac
done


Get_Oracle_RAC_Cluster (){
    query_sql="select value from v\$parameter where name = 'cluster_database';"
    Run_Oracle_Inquire_Statement $query_sql
    rac_cluster=$retval
}

Verity_Oracle_Home_Path(){
    if [ ! -d "$oracle_home" ]; then
        oracle_home=""
    else
        oracle_home=$oracle_home
    fi
    # echo $oracle_home
}

Get_Cluster_Grid_Home() {
    grid_home=`grep -v "^[#]" /etc/oratab |grep -i "+ASM" | head -n1 | cut -f2 -d":"`
}

Verity_Oracle_Version(){
    oracle_version=`$oracle_home/bin/sqlplus -version | awk -F ":" '{ print $2 }' | awk '{printf $0}' | awk '$1=$1' | sed -r "s/.* ([0-9]+.*) .*/\1/g" | awk -F " " '{ print $1 }'`
	# echo $oracle_version
}

Verity_Oracle_Instance(){
    query_sql="select value from v\$parameter where name in ('db_name', 'db_unique_name');"
    Run_Oracle_Inquire_Statement $query_sql
    db_name=`echo $retval | awk '{ print $1 }'`
	db_unique_name=`echo $retval | awk '{ print $2 }'`
	# echo $db_name
	# echo $db_unique_name
}

Run_Oracle_Inquire_Statement() {
    export ORACLE_SID=$oracle_sid
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

Get_Verity_result(){
    export ORACLE_HOME=$oracle_home
    Get_Oracle_RAC_Cluster
    Verity_Oracle_Home_Path
    Verity_Oracle_Version
    if [[ $rac_cluster == "TRUE" ]]; then
        Get_Cluster_Grid_Home
        # Verity_listener $grid_home
    # else
        # Verity_listener $oracle_home
    fi

    if [[ $resc_type == "backup" ]]; then
        Verity_Oracle_Instance
    fi
}

Get_Verity_result
echo $(eval echo '{\"oracle_home\":\""$oracle_home"\", \"oracle_version\":\""$oracle_version"\", \"db_name\":\""$db_name"\", \"db_unique_name\":\""$db_unique_name"\"}')

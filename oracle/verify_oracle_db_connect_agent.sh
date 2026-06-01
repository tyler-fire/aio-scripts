#!/bin/sh
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIO_PROFILE_SCRIPT="$PROJECT_DIR/load_profile.sh"
CURRENT_USER=$(whoami)
sh $AIO_PROFILE_SCRIPT && source "$PROJECT_DIR/$CURRENT_USER.profile"

help() {
  echo "sh verify_oracle_db_connect.sh"
}

while getopts 'm:s:u:p:h' OPT; do
    case $OPT in
      m) oracle_home="$OPTARG";;
      s) oracle_sid="$OPTARG";;
      u) username="$OPTARG";;
      p) passwd="$OPTARG";;
      h) help;;
    esac
done

Verify_Oracle_DB_Connect() {
    export ORACLE_HOME=$oracle_home
    export ORACLE_SID=$oracle_sid
    VALUE=`$oracle_home/bin/sqlplus -S /nolog <<EOF
    set heading off feedback off pagesize 0 verify off echo off;
	  conn $username/$passwd as sysdba;
    set linesize 500;
    select sysdate from dual;
    exit;
EOF`
    # echo $VALUE
	echo $(eval echo '{\"oracle_db_connect\":\""$VALUE"\"}')
}

Verify_Oracle_DB_Connect
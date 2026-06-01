#!/bin/sh
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIO_PROFILE_SCRIPT="$PROJECT_DIR/load_profile.sh"
CURRENT_USER=$(whoami)
sh $AIO_PROFILE_SCRIPT && source "$PROJECT_DIR/$CURRENT_USER.profile"

help() {
  echo "sh detect.sh"
}

while getopts 'm:s:t:h' OPT; do
    case $OPT in
      m) oracle_home="$OPTARG";;
      s) oracle_sid="$OPTARG";;
      h) help;;
    esac
done

export ORACLE_SID=$oracle_sid
export ORACLE_HOME=$oracle_home
bct_sql="select status from v\$block_change_tracking;"
archive_sql="select log_mode from v\$database;"
VALUE=`$oracle_home/bin/sqlplus -S /nolog <<EOF
set heading off feedback off pagesize 0 verify off echo off;
conn / as sysdba;
set linesize 500;
$bct_sql
$archive_sql
exit;
EOF`

result=$(echo $VALUE | grep "ERROR")
if [ "$result" = "" ]; then
	echo $VALUE
fi
oracle_home=%s
oracle_sid=%s
username=%s
passwd=%s

Verify_Oracle_DB_Connect() {
    export ORACLE_HOME=$oracle_home
    export ORACLE_SID=$oracle_sid
    VALUE=`$oracle_home/bin/sqlplus -S /nolog <<EOF
    set heading off feedback off pagesize 0 verify off echo off;
    conn $username/$passwd;
    set linesize 500;
    select sysdate from dual;
    exit;
EOF`
    echo $VALUE
}

Verify_Oracle_DB_Connect
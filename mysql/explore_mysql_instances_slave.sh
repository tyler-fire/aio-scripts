#!/bin/bash

hosts=`$BASEDIR/bin/mysql -h$HOSTNAME -P$PORT -u$USERNAME -p$PASSWORD -N -e "select HOST from information_schema.processlist as p where p.command like 'Binlog Dump%'"`

set -x

result='{"slaves":['
for host in ${hosts}
do
    result+='"'$host'",'
done
echo ${result%?}']}'

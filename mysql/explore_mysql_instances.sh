#!/bin/bash

set -x

pids=`ps -ef | grep mysqld | grep -v grep | awk {'print $2'}`
if [ "${pids}" != "" ];
then
    result="{"
    for pid in ${pids}
    do
        command=`ps -p ${pid} -o args | grep mysqld`
        datadir=`ls -l /proc/${pid}/cwd | awk '{print $11}'`
        mysqld=`ls -l /proc/${pid}/exe | awk '{print $11}'`
        basedir=`echo ${mysqld} | xargs dirname | xargs dirname`
        version=`${mysqld} --version`
        version=`echo ${version#*Ver }`
        version=`echo ${version% for*}`
        cnf=`echo ${command} | awk -F '--defaults-file=' '{print $2}' | awk '{print $1}'`
        if [ "${cnf}" == "" ];
        then
            cnf="/etc/my.cnf"
        fi
        port=`echo ${command} | awk -F '--port=' '{print $2}' | awk '{print $1}'`
        if [ "${port}" == "" ];
        then
           port=`cat ${cnf} | grep port | cut -d '=' -f2 | head -n 1 | awk '$1=$1'`
        fi
        result+='"'${pid}'": {"command": "'${command}'", "version": "'${version}'", "datadir": "'${datadir}'", "basedir": "'${basedir}'", "cnf": "'${cnf}'", "port": "'${port}'"},'
    done
    echo ${result%?}"}"
fi

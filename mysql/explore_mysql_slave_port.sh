#!/bin/bash

set -x

pid=`netstat -ntp | grep $HOSTNAME:$TCP_PORT | grep -v grep | awk '{print $7}' | awk -F '/' '{print $1}'`
port=`netstat -nltp | grep $pid/mysqld | grep -v grep | head -n 1 | awk '{print $4}' | awk -F ':' '{print $NF}'`
echo '{"port": "'$port'"}'

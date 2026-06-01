#!/bin/bash
IP=$1
hostid=$(hostid)
hostidmd5=$(echo -n "${hostid}" | openssl md5 | awk -F '=' '{print $2}' | sed 's/[[:space:]]//g')
hostipmd5=$(echo -n "${IP}" | openssl md5 | awk -F '=' '{print $2}' | sed 's/[[:space:]]//g')
  # shellcheck disable=SC2116
appid=$(echo "${hostidmd5}":"${hostipmd5}")
echo "${appid}"
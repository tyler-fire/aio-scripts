#!/bin/sh
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIO_PROFILE_SCRIPT="$PROJECT_DIR/load_profile.sh"
CURRENT_USER=$(whoami)
sh $AIO_PROFILE_SCRIPT && source "$PROJECT_DIR/$CURRENT_USER.profile"

help() {
  echo "sh verify_resource_host_info.sh"
}

while getopts 'h:w:q:H' OPT; do
    case $OPT in
      h) host_name="$OPTARG";;
      w) aio_work_path="$OPTARG";;
      q) agent_install_user="$OPTARG";;
      H) help;;
    esac
done


Verity_Oracle_Oinstall(){
    var=`id`
    var=`echo ${var##*groups=}`
	var2=`echo ${var##*组=}`
    groups=`echo ${var%% *}`
    groups2=`echo ${var2%% *}`
    if [[ ${groups} =~ "oinstall" ]] || [[ ${groups2} =~ "oinstall" ]] || [[ ${groups} =~ "dba" ]]; then
        oracle_oinstall=1
    else
        oracle_oinstall=0
    fi
}


Verify_User_Permission(){
    if [[ ${agent_install_user} =~ "root" ]];then
        user_permission=1
    else
        sudo_permission=$(sudo -n true >/dev/null 2>&1; echo $?)
        if [[ ${sudo_permission} == 0 ]]; then
            user_permission=1
        else
            user_permission=0
        fi
    fi
}


Verify_Oracle_Hostname(){
    hostname=`hostname`
    if [[ ${hostname} == ${host_name} ]]; then
        hostname=1
    else
        hostname=0
    fi
}


Verify_Path_Permission(){
    if [[ $aio_work_path == "/" ]]; then
        path=0
    elif [[ ! -r $aio_work_path ]]; then
        (mkdir -p $aio_work_path && path=1) || (path=0)
    else
        path=1
    fi
}


Get_Verity_result(){
    Verity_Oracle_Oinstall
    Verify_User_Permission
    Verify_Oracle_Hostname
    Verify_Path_Permission
}

Get_Verity_result
echo $(eval echo '{\"oracle_oinstall\":\""$oracle_oinstall"\", \"user_permission\":\""$user_permission"\", \"hostname\":\""$hostname"\", \"path\":\""$path"\"}')

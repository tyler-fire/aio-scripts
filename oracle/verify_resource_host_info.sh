host_name=%s
aio_work_path=%s

Verity_Oracle_Oinstall(){
    var=`id`
    var=`echo ${var##*groups=}`
    groups=`echo ${var%% *}`
    if [[ ${groups} =~ "oinstall" ]] || [[ ${groups} =~ "dba" ]]; then
        echo 1
    else
        echo 0
    fi
}


Verify_User_Permission(){
    suname=`sudo uname`
    uname=`uname`
    if [[ ${suname} == ${uname} ]]; then
        echo 1
    else
        echo 0
    fi
}


Verify_Oracle_Hostname(){
    hostname=`hostname`
    if [[ ${hostname} == ${host_name} ]]; then
        echo 1
    else
        echo 0
    fi
}


Verify_Path_Permission(){
    if [[ $aio_work_path == "/" ]]; then
        echo 0
    elif [[ ! -r $aio_work_path ]]; then
        (mkdir -p $aio_work_path && echo 1) || (echo 0)
    else
        echo 1
    fi
}


Get_Verity_result(){
    Verity_Oracle_Oinstall
    Verify_User_Permission
    Verify_Oracle_Hostname
    Verify_Path_Permission
}

Get_Verity_result

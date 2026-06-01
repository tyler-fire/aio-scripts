#!/bin/bash

# 这是一个将网络掩码位转子网掩码
# 示例:
#   调用方式: get_netmask_ip "24"
#   返回值: "255.255.255.0"
get_netmask_ip() {
    local netmask_bit="$1"
    local netmask=""

    # 计算子网掩码
    netmask=$((0xffffffff << (32 - netmask_bit)))

    # 将子网掩码转换为 IP 地址格式
    netmask_ip=$(printf "%d.%d.%d.%d\n" $((netmask >> 24 & 0xff)) $((netmask >> 16 & 0xff)) $((netmask >> 8 & 0xff)) $((netmask & 0xff)))

    echo "$netmask_ip"
}

# 定义网卡空数组
NIC_ARRAY=()

# 运行 ip 命令获取网络接口信息
IP_SHOW_OUTPUT=$(ip -o -brief -4 addr show)

# 检查命令执行的返回值
if [ $? != 0 ]; then
    IP_SHOW_OUTPUT=$(export PATH=$PATH:/sbin && ip -o -brief -4 addr show) # 如果报错，则执行 添加环境变量再执行一次
fi

while read -r line; do
    # 使用 awk 提取每个字段
    name=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $2}')
    ip_info=$(echo "$line" | awk '{print $3}')

    # lo回环网卡跳过
    if [[ "$name" == "lo" ]]; then
        continue
    fi

    # 使用正则表达式匹配IP地址和子网掩码
    if [[ "$ip_info" =~ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/([0-9]+) ]]; then
        ip_address="${BASH_REMATCH[1]}"
        netmask_bit="${BASH_REMATCH[2]}"
        netmask_ip=$(get_netmask_ip "$netmask_bit")
    else
        ip_address=""
        netmask_ip=""
    fi

    if [[ "$ip_address" == "" || "$netmask_ip" == "" ]]; then
        continue
    fi

    # 网卡Mac地址
    mac=$(cat /sys/class/net/$name/address 2> /dev/null)
    if [[ $? != 0 ]]; then
        continue
    fi

    # 网卡最高速度/速率
    speed=$(cat /sys/class/net/$name/speed 2> /dev/null)"Mbps"
    if [[ $? != 0 ]]; then
        speed="unknown"
    fi

    # 构建 Nic JSON 对象
    nic_json_object="{\"name\":\"$name\", \"ip\":\"$ip_address\", \"status\":\"$status\", \"netmask\":\"$netmask_ip\", \"mac\":\"$mac\", \"speed\":\"$speed\", \"ip_version\":\"4\"}"

    # 将 Nic JSON 对象添加到数组中
    NIC_ARRAY+=("$nic_json_object")

done <<< "$IP_SHOW_OUTPUT"


# 获取UUID
SYSTEM_UUID=$(sudo dmidecode -s system-uuid)
exit_code=$?
if [[ $exit_code != 0 ]]; then
    exit $exit_code
fi

# 获取硬件序列号
SYSTEM_SERIAL_NUMBER=$(sudo dmidecode -s system-serial-number)
exit_code=$?
if [[ $exit_code != 0 ]]; then
    exit $exit_code
fi

# 获取主机名称
HOSTNAME=$(hostname)

# 构建结果的 JSON 对象
RESULT_JSON="{\"system_uuid\":\"$SYSTEM_UUID\", \"system_serial_number\":\"$SYSTEM_SERIAL_NUMBER\", \"hostname\":\"$HOSTNAME\", \"nics\": ["

# 添加 JSON 数组元素
for ((i=0; i<${#NIC_ARRAY[@]}; i++)); do
    RESULT_JSON+=" ${NIC_ARRAY[$i]}"
    # 添加逗号，除了最后一个元素
    if [ $i -lt $(( ${#NIC_ARRAY[@]} - 1 )) ]; then
        RESULT_JSON+=","
    fi
done

RESULT_JSON+=" ]}"

# 输出结果 JSON 对象
echo "$RESULT_JSON"

# 输出结果格式
# {
#     "system_uuid": "xxx",
#     "system_serial_number": "xxx",
#     "nics": [
#         {
#             "name": "eth0",
#             "ip": "192.168.100.10",
#             "netmask": "255.255.128.0",
#             "status": "UP",
#             "mac": "00:50:56:9d:52:a0",
#             "ip_version": "4",
#         }
#     ]
# }

exit 0

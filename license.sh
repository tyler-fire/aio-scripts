#!/bin/bash
# 版本: 1.1.0
# AIO License 管理脚本
# 用法:
#   bash /opt/aio/ps_scripts/license.sh              # 检查 license 状态
#   bash /opt/aio/ps_scripts/license.sh apply        # 激活/重新激活 license
#   bash /opt/aio/ps_scripts/license.sh revert       # 恢复为未激活状态
#   bash /opt/aio/ps_scripts/license.sh --help       # 显示帮助信息

set -uo pipefail

AIO_HOME="/opt/aio"
AIO_ENV="${AIO_HOME}/cfg/aio.env"
ENV_FILE="${AIO_HOME}/cfg/cdm.runtime.env"

LICENSE_UUID="5a22dd5a85fd852ed20dd9b2e9e543ea:d41d8cd98f00b204e9800998ecf8427e"
LICENSE_KEY="UgSAHaGoOmnEmJPKwT6blU/iFrJGZIbBAEJpVUZO13Q6PDLkQAuh6xs1P7C3tTZJ2gHLffxh9FMextYRpDjcF3KIng7lOm1SJ/UPHstxskKNOy2/azLNGUJAPeLFGYseTF/TkqYIfrSjRIK+DrUjzWgHFPj2v5T/fGKsS2cwftujRsMkjo/J5mC8h5zFJ95lpYXGwWlOXp3R7MYp+xyjI+3hqhZvZEWDsJ4NzRAHgaiOKzp65eYtiH5sSoQy6s/ZmyEzlAJhJJ1fhqyTFdO+NKftHtme9IvmYF0lp8R7AJq3Rz12hLLXh4cms75m+OPTa1ptV7QDqO7abObtNUiN/A=="

MYSQL_DEFAULTS_FILE=""
MYSQL_BIN="/usr/local/mysql/bin/mysql"
DB_HOST=""
DB_PORT="3306"
DB_USER="root"
DB_PASS=""
DB_NAME="aio"
REDIS_HOST=""
REDIS_PORT="6379"
REDIS_DB="3"
REDIS_PASS=""

if [[ ! -x "${MYSQL_BIN}" ]]; then
    MYSQL_BIN="mysql"
fi

strip_quotes() {
    local value="$1"
    local first="${value:0:1}"
    local last="${value: -1}"

    if [[ ${#value} -ge 2 && ( "${first}" == "'" || "${first}" == '"' ) && "${last}" == "${first}" ]]; then
        printf "%s" "${value:1:${#value}-2}"
    else
        printf "%s" "${value}"
    fi
}

read_env() {
    local key="$1"
    local value
    value=$(grep -E "^${key}=" "${AIO_ENV}" 2>/dev/null | tail -1 | sed "s/^${key}=//")
    strip_quotes "${value}"
}

decrypt_enc() {
    local enc_str="$1"
    enc_str="${enc_str#ENC(}"
    enc_str="${enc_str%)}"
    AIO_ENC_DATA="${enc_str}" "${AIO_HOME}/cdm/bin/python3" -c "
import sys, base64, os
sys.path.insert(0, '${AIO_HOME}/cdm/lib/python3.6/site-packages')
from Crypto.Cipher import AES
from Crypto.Util.Padding import unpad
from aio.config.key import AES_KEY_BASE_64
key = base64.b64decode(AES_KEY_BASE_64)
data = base64.b64decode(os.environ['AIO_ENC_DATA'])
plain = unpad(AES.new(key, AES.MODE_CBC, IV=b'0000000000000000').decrypt(data), AES.block_size)
sys.stdout.buffer.write(plain)
" 2>/dev/null
}

read_env_value() {
    local value
    value=$(read_env "$1")
    if [[ "${value}" =~ ^ENC\( ]]; then
        decrypt_enc "${value}"
    else
        printf "%s" "${value}"
    fi
}

load_config() {
    if [[ ! -f "${AIO_ENV}" ]]; then
        echo "错误: 配置文件不存在: ${AIO_ENV}"
        exit 1
    fi

    DB_HOST=$(read_env AIO_DB_HOSTNAME)
    DB_PORT=$(read_env AIO_DB_PORT)
    DB_USER=$(read_env AIO_DB_USERNAME)
    DB_PASS=$(read_env_value AIO_DB_PASSWORD)
    DB_NAME=$(read_env AIO_DB_NAME)

    REDIS_HOST=$(read_env AIO_REDIS_HOST)
    REDIS_PORT=$(read_env AIO_REDIS_PORT)
    REDIS_DB=$(read_env AIO_REDIS_DB)
    REDIS_PASS=$(read_env_value AIO_REDIS_PASSWORD)

    DB_PORT="${DB_PORT:-3306}"
    DB_USER="${DB_USER:-root}"
    DB_NAME="${DB_NAME:-aio}"
    REDIS_PORT="${REDIS_PORT:-6379}"
    REDIS_DB="${REDIS_DB:-3}"

    if [[ -z "${DB_HOST}" || -z "${DB_PASS}" ]]; then
        echo "错误: AIO 数据库配置不完整"
        exit 1
    fi
    if [[ -z "${REDIS_HOST}" ]]; then
        echo "错误: AIO Redis 配置不完整"
        exit 1
    fi
}

cleanup_mysql_defaults_file() {
    if [[ -n "${MYSQL_DEFAULTS_FILE}" && -f "${MYSQL_DEFAULTS_FILE}" ]]; then
        rm -f "${MYSQL_DEFAULTS_FILE}"
    fi
    MYSQL_DEFAULTS_FILE=""
}

ensure_mysql_defaults_file() {
    if [[ -n "${MYSQL_DEFAULTS_FILE}" && -f "${MYSQL_DEFAULTS_FILE}" ]]; then
        return 0
    fi

    MYSQL_DEFAULTS_FILE=$(mktemp /tmp/aio_license_mysql.XXXXXX.cnf)
    chmod 600 "${MYSQL_DEFAULTS_FILE}"
    {
        echo "[client]"
        echo "host=${DB_HOST}"
        echo "port=${DB_PORT}"
        echo "user=${DB_USER}"
        echo "password=${DB_PASS}"
    } > "${MYSQL_DEFAULTS_FILE}"
}

run_mysql() {
    local sql="$1"
    ensure_mysql_defaults_file
    "${MYSQL_BIN}" --defaults-extra-file="${MYSQL_DEFAULTS_FILE}" "${DB_NAME}" -e "${sql}"
}

run_mysql_scalar() {
    local sql="$1"
    ensure_mysql_defaults_file
    "${MYSQL_BIN}" --defaults-extra-file="${MYSQL_DEFAULTS_FILE}" "${DB_NAME}" -N -B -e "${sql}" | tail -1
}

redis_cmd() {
    if [[ -n "${REDIS_PASS}" ]]; then
        REDISCLI_AUTH="${REDIS_PASS}" redis-cli --no-auth-warning -h "${REDIS_HOST}" -p "${REDIS_PORT}" -n "${REDIS_DB}" "$@"
    else
        redis-cli --no-auth-warning -h "${REDIS_HOST}" -p "${REDIS_PORT}" -n "${REDIS_DB}" "$@"
    fi
}

backup_env_file() {
    if [[ -f "${ENV_FILE}" ]]; then
        local backup="${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "${ENV_FILE}" "${backup}"
        echo "已备份 runtime 配置: ${backup}"
    fi
}

check_license() {
    echo "=== AIO License 状态 ==="
    run_mysql "SELECT id, license_type, active_at, active_days, expire_at, expire_days, is_valid FROM aio_license;" || true

    echo ""
    echo "=== 当前时间 ==="
    date

    echo ""
    echo "=== AIO_LICENSE_SERVER_UUID ==="
    grep "AIO_LICENSE_SERVER_UUID" "${ENV_FILE}" 2>/dev/null || echo "未配置"

    echo ""
    echo "=== Redis 缓存 (DB ${REDIS_DB}) ==="
    if command -v redis-cli >/dev/null 2>&1; then
        local license_cache
        license_cache=$(redis_cmd GET cdm_is_valid_license 2>/dev/null || true)
        echo "cdm_is_valid_license = ${license_cache:-未设置}"
    else
        echo "redis-cli 不存在，跳过"
    fi

    echo ""
    echo "=== 服务状态 ==="
    systemctl is-active aio.cdm 2>/dev/null || echo "CDM 服务未运行"
}

apply_license() {
    local license_count expire_at now new_expire

    backup_env_file

    if grep -q "AIO_LICENSE_SERVER_UUID" "${ENV_FILE}" 2>/dev/null; then
        echo "AIO_LICENSE_SERVER_UUID 已存在，更新值..."
        sed -i "s|^AIO_LICENSE_SERVER_UUID=.*|AIO_LICENSE_SERVER_UUID=${LICENSE_UUID}|" "${ENV_FILE}"
    else
        echo "添加 AIO_LICENSE_SERVER_UUID..."
        echo "AIO_LICENSE_SERVER_UUID=${LICENSE_UUID}" >> "${ENV_FILE}"
    fi

    if ! license_count=$(run_mysql_scalar "SELECT COUNT(*) FROM aio_license;" 2>/dev/null); then
        echo "错误: 查询 license 记录失败"
        exit 1
    fi

    if [[ "${license_count}" == "0" ]]; then
        echo "首次插入 license 记录..."
        run_mysql "INSERT INTO aio_license (license_key, license_type, active_at, active_days, expire_at, expire_days, is_valid, create_time, update_time, time_zone) VALUES ('${LICENSE_KEY}', 'poc', NOW(), 0, DATE_ADD(NOW(), INTERVAL 55 DAY), 55, 1, NOW(), NOW(), 'Asia/Shanghai');"
    else
        expire_at=$(run_mysql_scalar "SELECT expire_at FROM aio_license WHERE id=1;" 2>/dev/null)
        now=$(date +"%Y-%m-%d %H:%M:%S")

        if [[ "${expire_at}" < "${now}" ]]; then
            echo "License 已过期 (${expire_at})，重新激活..."
            run_mysql "UPDATE aio_license SET license_key='${LICENSE_KEY}', license_type='poc', active_at=NOW(), active_days=0, expire_at=DATE_ADD(NOW(), INTERVAL 55 DAY), expire_days=55, is_valid=1, update_time=NOW() WHERE id=1;"
        else
            echo "License 仍在有效期内 (${expire_at})，更新 key..."
            run_mysql "UPDATE aio_license SET license_key='${LICENSE_KEY}', update_time=NOW() WHERE id=1;"
        fi
    fi

    echo "设置 Redis 缓存..."
    if ! redis_cmd SET cdm_is_valid_license 1 EX 86400 >/dev/null; then
        echo "错误: Redis 缓存写入失败，请检查 ${REDIS_HOST}:${REDIS_PORT}"
        exit 1
    fi

    echo "重启 CDM 服务..."
    systemctl restart aio.cdm
    sleep 3

    if systemctl is-active aio.cdm >/dev/null 2>&1; then
        echo "CDM 服务启动成功"
    else
        echo "CDM 服务启动失败，请检查日志"
        exit 1
    fi

    new_expire=$(run_mysql_scalar "SELECT expire_at FROM aio_license WHERE id=1;" 2>/dev/null || true)
    echo ""
    echo "=============================="
    echo "License 激活完成，有效期 55 天"
    echo "新的过期时间: ${new_expire}"
    echo "=============================="
}

revert_license() {
    echo "恢复为未激活状态..."
    backup_env_file

    echo "删除 AIO_LICENSE_SERVER_UUID..."
    sed -i '/^AIO_LICENSE_SERVER_UUID=/d' "${ENV_FILE}"

    echo "删除 license 记录..."
    run_mysql "DELETE FROM aio_license;"

    echo "清除 Redis 缓存..."
    if ! redis_cmd DEL cdm_is_valid_license >/dev/null; then
        echo "错误: Redis 缓存清理失败，请检查 ${REDIS_HOST}:${REDIS_PORT}"
        exit 1
    fi

    echo "重启 CDM 服务..."
    systemctl restart aio.cdm
    sleep 3

    if systemctl is-active aio.cdm >/dev/null 2>&1; then
        echo "CDM 服务启动成功"
    else
        echo "CDM 服务启动失败，请检查日志"
        exit 1
    fi

    echo ""
    echo "=============================="
    echo "已恢复为未激活状态"
    echo "=============================="
}

show_help() {
    echo "AIO License 管理脚本"
    echo ""
    echo "用法: bash /opt/aio/ps_scripts/license.sh [选项]"
    echo ""
    echo "选项:"
    echo "  (无参数)      检查 license 状态"
    echo "  apply         激活/重新激活 license，有效期 55 天"
    echo "  revert        恢复为未激活状态"
    echo "  --help        显示此帮助信息"
}

case "${1:-}" in
    --help|-h)
        show_help
        exit 0
        ;;
esac

trap cleanup_mysql_defaults_file EXIT
load_config

case "${1:-}" in
    apply)
        apply_license
        ;;
    revert)
        revert_license
        ;;
    "")
        check_license
        ;;
    *)
        show_help
        exit 1
        ;;
esac

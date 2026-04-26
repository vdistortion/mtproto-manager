#!/usr/bin/env bash

set -euo pipefail

# ==============================================================
# КОНСТАНТЫ И ПУТИ
# ==============================================================

CONFIG_DIR="/etc/mtproto-manager"
USERS_FILE="$CONFIG_DIR/users.conf"
GLOBAL_DOMAINS_FILE="$CONFIG_DIR/domains_global.list"
RU_DOMAINS_FILE="$CONFIG_DIR/domains_ru.list"
MAIN_CONFIG_FILE="$CONFIG_DIR/config.conf"
BINARY_PATH="/usr/local/bin/mtproto-manager"
CONTAINER_PREFIX="mtproto-user"
SCRIPT_URL="https://raw.githubusercontent.com/vdistortion/mtproto-manager/main/mtproto-manager.sh"
DOCKER_IMAGE="nineseconds/mtg:2"

DEFAULT_REGION="GLOBAL"
DEFAULT_SERVER_DOMAIN=""
DEFAULT_RESERVED_PORTS="80 443 8080"

REGION=""
SERVER_DOMAIN=""
RESERVED_PORTS=()

# ==============================================================
# ЦВЕТА
# ==============================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ==============================================================
# ХАРДКОДНЫЕ СПИСКИ ДОМЕНОВ
# ==============================================================

INITIAL_DOMAINS_GLOBAL=(
    "google.com"
    "microsoft.com"
    "cloudflare.com"
    "aws.amazon.com"
    "github.com"
    "apple.com"
    "itunes.apple.com"
    "netflix.com"
    "zoom.us"
    "linkedin.com"
    "twitch.tv"
    "bing.com"
    "wikipedia.org"
    "yahoo.com"
    "reddit.com"
    "spotify.com"
    "coursera.org"
    "udemy.com"
    "medium.com"
    "stackoverflow.com"
    "bbc.com"
    "cnn.com"
    "reuters.com"
    "nytimes.com"
    "ted.com"
)

INITIAL_DOMAINS_RU=(
    "ya.ru"
    "vk.ru"
    "vk.com"
    "mail.ru"
    "gosuslugi.ru"
    "sberbank.ru"
    "avito.ru"
    "ozon.ru"
    "wildberries.ru"
    "yandex.ru"
    "auto.ru"
    "kinopoisk.ru"
    "habr.com"
    "tbank.ru"
    "max.ru"
    "rutube.ru"
    "lenta.ru"
    "rbc.ru"
    "ria.ru"
    "kommersant.ru"
    "stepik.org"
    "duolingo.com"
    "dzen.ru"
)

# ==============================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ==============================================================

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}Ошибка: скрипт должен запускаться от root (sudo).${NC}"
        exit 1
    fi
}

get_ip() {
    local ip
    ip=$(curl -s -4 --max-time 5 https://api.ipify.org \
      || curl -s -4 --max-time 5 https://icanhazip.com \
      || echo "127.0.0.1")
    echo "$ip" | grep -E -o '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1
}

get_iface() {
    ip route get 1.1.1.1 2>/dev/null \
      | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

get_docker_subnet() {
    local s
    s="$(docker network inspect bridge \
         -f '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)"
    [ -n "$s" ] && echo "$s" || echo "172.17.0.0/16"
}

load_config() {
    if [ -f "$MAIN_CONFIG_FILE" ]; then
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^# ]] && continue
            [[ -z "$key" ]] && continue
            case "$key" in
                REGION)         REGION="$value" ;;
                SERVER_DOMAIN)  SERVER_DOMAIN="$value" ;;
                RESERVED_PORTS) IFS=' ' read -r -a RESERVED_PORTS <<< "$value" ;;
            esac
        done < "$MAIN_CONFIG_FILE"
    else
        REGION="$DEFAULT_REGION"
        SERVER_DOMAIN="$DEFAULT_SERVER_DOMAIN"
        IFS=' ' read -r -a RESERVED_PORTS <<< "$DEFAULT_RESERVED_PORTS"
    fi
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    {
        echo "REGION=$REGION"
        echo "SERVER_DOMAIN=$SERVER_DOMAIN"
        echo "RESERVED_PORTS=${RESERVED_PORTS[*]:-}"
    } > "$MAIN_CONFIG_FILE"
}

is_port_reserved() {
    local p="$1"
    for rp in "${RESERVED_PORTS[@]:-}"; do
        [[ "$p" == "$rp" ]] && return 0
    done
    return 1
}

find_free_port() {
    local current_port="${1:-8443}"
    while true; do
        if ! is_port_reserved "$current_port" \
           && ! timeout 1 ss -tuln 2>/dev/null | grep -q ":${current_port} "; then
            echo "$current_port"
            return 0
        fi
        (( current_port++ ))
        if [ "$current_port" -gt 65535 ]; then
            echo -e "${RED}Ошибка: свободных портов не найдено.${NC}" >&2
            return 1
        fi
    done
}

cleanup_temp_files() {
    # Вызывается через trap, получает список файлов как аргументы
    for f in "$@"; do
        rm -f "$f" 2>/dev/null || true
    done
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}Ошибка: Docker не установлен. Запустите: mtproto-manager install${NC}"
        exit 1
    fi
    if ! docker info &>/dev/null; then
        echo -e "${RED}Ошибка: Docker демон не запущен. Запустите: systemctl start docker${NC}"
        exit 1
    fi
}

# ==============================================================
# СЕТЕВЫЕ ФУНКЦИИ
# ==============================================================

get_listening_ports() {
    timeout 3 ss -tuln 2>/dev/null \
      | grep 'LISTEN' \
      | awk '{print $4}' \
      | grep -E -o ':[0-9]+$' \
      | tr -d ':' \
      | sort -n \
      | uniq
}

check_domain_reachability() {
    local domain="$1"
    curl -s --max-time 5 --head "https://${domain}" 2>/dev/null \
      | grep -q "HTTP/" && return 0 || return 1
}

# Используется ТОЛЬКО при install — фильтрует файл, удаляя недоступные домены
filter_reachable_domains_initial() {
    local input_file="$1"
    local tmp_file
    tmp_file=$(mktemp)
    trap "cleanup_temp_files '$tmp_file'" EXIT

    local removed=0
    echo -e "${CYAN}  Проверка доменов в $(basename "$input_file")...${NC}"

    while read -r domain; do
        [[ -z "$domain" ]] && continue
        if check_domain_reachability "$domain"; then
            echo "$domain" >> "$tmp_file"
            echo -e "    ${GREEN}✓ $domain${NC}"
        else
            echo -e "    ${RED}✗ $domain — недоступен, исключён${NC}"
            (( removed++ )) || true
        fi
    done < "$input_file" || true

    cat "$tmp_file" > "$input_file"
    rm -f "$tmp_file"
    trap - EXIT
    echo -e "  ${GREEN}Готово. Исключено доменов: $removed${NC}"
}

auto_reserve_listening_ports() {
    echo -e "${CYAN}  Определение занятых портов...${NC}"
    local listening_ports
    listening_ports=$(get_listening_ports) || true

    if [ -z "$listening_ports" ]; then
        echo -e "  ${YELLOW}Слушающих портов не найдено.${NC}"
        return
    fi

    local added=0
    while read -r p; do
        [[ -z "$p" ]] && continue
        if ! printf '%s\n' "${RESERVED_PORTS[@]:-}" | grep -qw "$p"; then
            RESERVED_PORTS+=("$p")
            (( added++ )) || true
        fi
    done <<< "$listening_ports"

    echo -e "  ${GREEN}Добавлено в зарезервированные: $added портов.${NC}"
    echo -e "  ${GREEN}Итого зарезервировано: ${#RESERVED_PORTS[@]} портов.${NC}"
}

# ==============================================================
# УСТАНОВКА (install)
# ==============================================================

install_script() {
    check_root
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║     Установка mtproto-manager        ║${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════╝${NC}"
    echo ""

    # 1. Docker
    echo -e "${CYAN}[1/7] Проверка Docker...${NC}"
    if ! command -v docker &>/dev/null; then
        echo -e "  Установка Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
        echo -e "  ${GREEN}Docker установлен и запущен.${NC}"
    else
        echo -e "  ${YELLOW}Docker уже установлен.${NC}"
        if ! docker info &>/dev/null; then
            systemctl start docker
            echo -e "  ${GREEN}Docker запущен.${NC}"
        fi
    fi

    # 2. qrencode
    echo -e "${CYAN}[2/7] Проверка qrencode...${NC}"
    if ! command -v qrencode &>/dev/null; then
        echo -e "  Установка qrencode..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y qrencode
        elif command -v yum &>/dev/null; then
            yum install -y qrencode
        else
            echo -e "  ${YELLOW}Предупреждение: менеджер пакетов не найден. QR-коды недоступны.${NC}"
        fi
    else
        echo -e "  ${YELLOW}qrencode уже установлен.${NC}"
    fi

    # 3. Директории и файлы
    echo -e "${CYAN}[3/7] Создание директорий и конфигурации...${NC}"
    mkdir -p "$CONFIG_DIR"
    touch "$USERS_FILE"

    if [ ! -f "$MAIN_CONFIG_FILE" ]; then
        REGION="$DEFAULT_REGION"
        SERVER_DOMAIN="$DEFAULT_SERVER_DOMAIN"
        IFS=' ' read -r -a RESERVED_PORTS <<< "$DEFAULT_RESERVED_PORTS"
        save_config
        echo -e "  ${GREEN}Конфиг создан: $MAIN_CONFIG_FILE${NC}"
    else
        echo -e "  ${YELLOW}Конфиг уже существует: $MAIN_CONFIG_FILE${NC}"
        load_config
    fi

    # 4. Списки доменов
    echo -e "${CYAN}[4/7] Создание списков доменов FakeTLS...${NC}"

    if [ ! -f "$GLOBAL_DOMAINS_FILE" ]; then
        printf '%s\n' "${INITIAL_DOMAINS_GLOBAL[@]}" > "$GLOBAL_DOMAINS_FILE"
        echo -e "  ${GREEN}GLOBAL список создан (${#INITIAL_DOMAINS_GLOBAL[@]} доменов).${NC}"
    else
        echo -e "  ${YELLOW}GLOBAL список уже существует.${NC}"
    fi

    if [ ! -f "$RU_DOMAINS_FILE" ]; then
        printf '%s\n' "${INITIAL_DOMAINS_RU[@]}" > "$RU_DOMAINS_FILE"
        echo -e "  ${GREEN}RU список создан (${#INITIAL_DOMAINS_RU[@]} доменов).${NC}"
    else
        echo -e "  ${YELLOW}RU список уже существует.${NC}"
    fi

    # 5. Фильтрация доменов
    echo -e "${CYAN}[5/7] Фильтрация недоступных доменов...${NC}"
    filter_reachable_domains_initial "$GLOBAL_DOMAINS_FILE"
    filter_reachable_domains_initial "$RU_DOMAINS_FILE"

    # 6. Резервирование портов
    echo -e "${CYAN}[6/7] Авторезервирование занятых портов...${NC}"
    auto_reserve_listening_ports
    save_config

    # 7. Самоустановка скрипта
    echo -e "${CYAN}[7/7] Установка бинарника в $BINARY_PATH...${NC}"
    if curl -fsSL --max-time 15 "$SCRIPT_URL" -o "$BINARY_PATH" 2>/dev/null; then
        chmod +x "$BINARY_PATH"
        echo -e "  ${GREEN}Скрипт установлен из репозитория: $BINARY_PATH${NC}"
    else
        echo -e "  ${YELLOW}Не удалось скачать из репозитория, копирую текущий файл...${NC}"
        cp "$0" "$BINARY_PATH"
        chmod +x "$BINARY_PATH"
        echo -e "  ${GREEN}Скрипт установлен: $BINARY_PATH${NC}"
    fi

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      Установка завершена!            ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Запуск:       ${CYAN}mtproto-manager${NC}"
    echo -e "  Справка:      ${CYAN}mtproto-manager help${NC}"
    echo -e "  Настройка:    ${CYAN}mtproto-manager setup${NC}"
    echo ""
    read -rp "Хотите настроить прокси сейчас? [y/n]: " setup_now
    if [[ "$setup_now" =~ ^[Yy]$ ]]; then
        setup_server
    fi
}

# ==============================================================
# НАСТРОЙКА СЕРВЕРА (setup)
# ==============================================================

setup_server() {
    check_root
    load_config

    local arg_region="${1:-}"
    local arg_domain="${2:-}"

    echo -e "${BOLD}${BLUE}=== Настройка сервера ===${NC}"
    echo ""

    # Регион
    if [ -n "$arg_region" ]; then
        REGION="${arg_region^^}"
    else
        echo -e "Текущий регион: ${CYAN}${REGION:-не задан}${NC}"
        echo -e "  ${CYAN}1${NC}) RU     — для пользователей из России"
        echo -e "  ${CYAN}2${NC}) GLOBAL — для пользователей из других стран"
        echo ""
        read -rp "Выберите регион [1/2] (Enter = оставить текущий): " input_region
        case "$input_region" in
            1) REGION="RU" ;;
            2) REGION="GLOBAL" ;;
            "") : ;;
            *) REGION="${input_region^^}" ;;
        esac
    fi

    # Домен сервера
    echo ""
    if [ -n "$arg_domain" ]; then
        SERVER_DOMAIN="$arg_domain"
    else
        echo -e "Текущий домен сервера: ${CYAN}${SERVER_DOMAIN:-не задан}${NC}"
        echo -e "  Укажите домен или IP-адрес вашего сервера."
        echo -e "  Используется в ссылках для подключения пользователей."
        echo ""
        read -rp "Введите домен или IP (Enter = оставить текущий): " input_domain
        if [ -n "$input_domain" ]; then
            SERVER_DOMAIN="$input_domain"
        fi
    fi

    save_config

    echo ""
    echo -e "${GREEN}Настройка сохранена.${NC}"
    echo -e "  Регион: ${CYAN}${REGION:-не задан}${NC}"
    echo -e "  Домен:  ${CYAN}${SERVER_DOMAIN:-не задан}${NC}"
    echo ""
}

# ==============================================================
# УПРАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯМИ
# ==============================================================

generate_secret() {
    local domain="$1"
    check_docker
    docker run --rm "$DOCKER_IMAGE" generate-secret --hex "$domain" 2>/dev/null
}

get_domain_for_region() {
    local region="$1"
    local domain_file

    if [ "$region" = "RU" ]; then
        domain_file="$RU_DOMAINS_FILE"
    else
        domain_file="$GLOBAL_DOMAINS_FILE"
    fi

    if [ ! -f "$domain_file" ] || [ ! -s "$domain_file" ]; then
        echo ""
        return 1
    fi

    shuf -n 1 "$domain_file"
}

add_user() {
    check_root
    check_docker
    load_config

    local username="${1:-}"
    local custom_domain="${2:-}"
    local custom_port="${3:-}"

    if [ -z "$username" ]; then
        echo -e "${RED}Ошибка: укажи имя пользователя.${NC}"
        echo "Использование: mtproto-manager add-user <имя> [домен] [порт]"
        exit 1
    fi

    # Проверка дублей
    if grep -q "^${username}:" "$USERS_FILE" 2>/dev/null; then
        echo -e "${RED}Пользователь '${username}' уже существует.${NC}"
        exit 1
    fi

    # Домен
    local faketls_domain
    if [ -n "$custom_domain" ]; then
        faketls_domain="$custom_domain"
    else
        faketls_domain=$(get_domain_for_region "$REGION") || true
    fi

    if [ -z "$faketls_domain" ]; then
        echo -e "${RED}Ошибка: список доменов пуст. Запустите setup или добавьте домены.${NC}"
        exit 1
    fi

    # Секрет
    echo -e "${CYAN}Генерация секрета для домена ${faketls_domain}...${NC}"
    local secret
    secret=$(generate_secret "$faketls_domain")

    if [ -z "$secret" ]; then
        echo -e "${RED}Ошибка: не удалось сгенерировать секрет.${NC}"
        exit 1
    fi

    # Порт
    local port
    if [ -n "$custom_port" ]; then
        port="$custom_port"
    else
        port=$(find_free_port 8443)
    fi

    local server_ip
    server_ip=$(get_ip)

    # Запуск контейнера
    local container_name="${CONTAINER_PREFIX}-${username}"
    echo -e "${CYAN}Запуск контейнера ${container_name}...${NC}"

    if ! docker run -d \
        --name "$container_name" \
        --restart always \
        -p "${port}:${port}" \
        "$DOCKER_IMAGE" \
        simple-run \
        -n 1.1.1.1 \
        -i prefer-ipv4 \
        "0.0.0.0:${port}" \
        "$secret" 2>&1; then
        echo -e "${RED}Ошибка запуска контейнера${NC}"
        exit 1
    fi

    # Сохранение пользователя: username:port:secret:domain
    echo "${username}:${port}:${secret}:${faketls_domain}" >> "$USERS_FILE"

    # Ссылка
    local tg_link="https://t.me/proxy?server=${server_ip}&port=${port}&secret=${secret}"

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   Пользователь '${username}' создан!${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Сервер:  ${CYAN}${server_ip}${NC}"
    echo -e "  Порт:    ${CYAN}${port}${NC}"
    echo -e "  Секрет:  ${CYAN}${secret}${NC}"
    echo -e "  Домен:   ${CYAN}${faketls_domain}${NC}"
    echo -e "  Ссылка:  ${CYAN}${tg_link}${NC}"

    if [ -n "$SERVER_DOMAIN" ]; then
        local tg_link_domain="https://t.me/proxy?server=${SERVER_DOMAIN}&port=${port}&secret=${secret}"
        echo -e "  Ссылка (домен): ${CYAN}${tg_link_domain}${NC}"
    fi

    echo ""
    if command -v qrencode &>/dev/null; then
        echo -e "${CYAN}QR-код:${NC}"
        qrencode -t ansiutf8 "$tg_link"
    fi
}

remove_user() {
    check_root
    check_docker
    load_config

    local username="${1:-}"
    if [ -z "$username" ]; then
        echo -e "${RED}Ошибка: укажи имя пользователя.${NC}"
        echo "Использование: mtproto-manager remove-user <имя>"
        exit 1
    fi

    if ! grep -q "^${username}:" "$USERS_FILE" 2>/dev/null; then
        echo -e "${RED}Пользователь '${username}' не найден.${NC}"
        exit 1
    fi

    local container_name="${CONTAINER_PREFIX}-${username}"

    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        docker stop "$container_name" >/dev/null 2>&1 || true
        docker rm "$container_name" >/dev/null 2>&1 || true
        echo -e "${GREEN}Контейнер '${container_name}' удалён.${NC}"
    else
        echo -e "${YELLOW}Контейнер '${container_name}' не найден (уже удалён?).${NC}"
    fi

    sed -i "/^${username}:/d" "$USERS_FILE"
    echo -e "${GREEN}Пользователь '${username}' удалён.${NC}"
}

list_users() {
    check_root
    check_docker
    load_config

    if [ ! -s "$USERS_FILE" ]; then
        echo -e "${YELLOW}Пользователей нет.${NC}"
        return
    fi

    local server_ip
    server_ip=$(get_ip)

    echo -e "${BOLD}${BLUE}=== Список пользователей ===${NC}"
    echo ""

    while IFS=':' read -r username port secret domain; do
        [[ -z "$username" ]] && continue

        local tg_link="https://t.me/proxy?server=${server_ip}&port=${port}&secret=${secret}"
        local status

        if docker ps --format '{{.Names}}' 2>/dev/null \
           | grep -q "^${CONTAINER_PREFIX}-${username}$"; then
            status="${GREEN}работает${NC}"
        else
            status="${RED}остановлен${NC}"
        fi

        echo -e "  ${BOLD}${username}${NC} [${status}]"
        echo -e "    Порт:    ${CYAN}${port}${NC}"
        echo -e "    Домен:   ${CYAN}${domain}${NC}"
        echo -e "    Ссылка:  ${CYAN}${tg_link}${NC}"
        echo ""
    done < "$USERS_FILE"
}

show_user() {
    check_root
    check_docker
    load_config

    local username="${1:-}"
    if [ -z "$username" ]; then
        echo -e "${RED}Ошибка: укажи имя пользователя.${NC}"
        echo "Использование: mtproto-manager show-user <имя>"
        exit 1
    fi

    if ! grep -q "^${username}:" "$USERS_FILE" 2>/dev/null; then
        echo -e "${RED}Пользователь '${username}' не найден.${NC}"
        exit 1
    fi

    local port secret domain server_ip tg_link
    IFS=':' read -r _ port secret domain \
        <<< "$(grep "^${username}:" "$USERS_FILE")"

    server_ip=$(get_ip)
    tg_link="https://t.me/proxy?server=${server_ip}&port=${port}&secret=${secret}"

    echo -e "${BOLD}${BLUE}=== Пользователь: ${username} ===${NC}"
    echo ""
    echo -e "  Сервер:  ${CYAN}${server_ip}${NC}"
    echo -e "  Порт:    ${CYAN}${port}${NC}"
    echo -e "  Секрет:  ${CYAN}${secret}${NC}"
    echo -e "  Домен:   ${CYAN}${domain}${NC}"
    echo -e "  Ссылка:  ${CYAN}${tg_link}${NC}"

    if [ -n "$SERVER_DOMAIN" ]; then
        local tg_link_domain="https://t.me/proxy?server=${SERVER_DOMAIN}&port=${port}&secret=${secret}"
        echo -e "  Ссылка (домен): ${CYAN}${tg_link_domain}${NC}"
    fi

    echo ""
    if command -v qrencode &>/dev/null; then
        echo -e "${CYAN}QR-код:${NC}"
        qrencode -t ansiutf8 "$tg_link"
    fi
}

block_user() {
    check_root
    check_docker

    local username="${1:-}"
    if [ -z "$username" ]; then
        echo -e "${RED}Ошибка: укажи имя пользователя.${NC}"
        echo "Использование: mtproto-manager block-user <имя>"
        exit 1
    fi

    local container_name="${CONTAINER_PREFIX}-${username}"
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo -e "${RED}Контейнер '${container_name}' не найден.${NC}"
        exit 1
    fi

    docker stop "$container_name" >/dev/null
    echo -e "${YELLOW}Пользователь '${username}' заблокирован.${NC}"
}

unblock_user() {
    check_root
    check_docker

    local username="${1:-}"
    if [ -z "$username" ]; then
        echo -e "${RED}Ошибка: укажи имя пользователя.${NC}"
        echo "Использование: mtproto-manager unblock-user <имя>"
        exit 1
    fi

    local container_name="${CONTAINER_PREFIX}-${username}"
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo -e "${RED}Контейнер '${container_name}' не найден.${NC}"
        exit 1
    fi

    docker start "$container_name" >/dev/null
    echo -e "${GREEN}Пользователь '${username}' разблокирован.${NC}"
}

restart_user() {
    check_root
    check_docker

    local username="${1:-}"
    if [ -z "$username" ]; then
        echo -e "${RED}Ошибка: укажи имя пользователя.${NC}"
        echo "Использование: mtproto-manager restart-user <имя>"
        exit 1
    fi

    local container_name="${CONTAINER_PREFIX}-${username}"
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo -e "${RED}Контейнер '${container_name}' не найден.${NC}"
        exit 1
    fi

    docker restart "$container_name" >/dev/null
    echo -e "${GREEN}Пользователь '${username}' перезапущен.${NC}"
}

export_users() {
    check_root

    local export_file="mtproto_users_$(date +%Y%m%d_%H%M%S).bak"
    cp "$USERS_FILE" "$export_file"
    echo -e "${GREEN}Конфигурация экспортирована: $(pwd)/${export_file}${NC}"
}

import_users() {
    check_root
    check_docker

    local import_file="${1:-}"
    if [ -z "$import_file" ]; then
        echo -e "${RED}Ошибка: укажи файл.${NC}"
        echo "Использование: mtproto-manager import <файл>"
        exit 1
    fi

    if [ ! -f "$import_file" ]; then
        echo -e "${RED}Файл не найден: ${import_file}${NC}"
        exit 1
    fi

    cp "$import_file" "$USERS_FILE"
    echo -e "${GREEN}Конфигурация импортирована. Синхронизация контейнеров...${NC}"
    _sync_containers
}

# Внутренняя функция синхронизации контейнеров с USERS_FILE
_sync_containers() {
    load_config

    if [ ! -s "$USERS_FILE" ]; then
        echo -e "${YELLOW}Нет пользователей для синхронизации.${NC}"
        return
    fi

    while IFS=':' read -r username port secret domain; do
        [[ -z "$username" ]] && continue
        local container_name="${CONTAINER_PREFIX}-${username}"
        local running
        running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^${container_name}$" || true)

        if [ "$running" -gt 0 ]; then
            echo -e "  ${GREEN}✓ ${username}${NC} уже запущен."
        else
            echo -e "  ${CYAN}↻ ${username}${NC}: пересоздание контейнера..."
            docker stop "$container_name" >/dev/null 2>&1 || true
            docker rm "$container_name" >/dev/null 2>&1 || true

            docker run -d \
                --name "$container_name" \
                --restart always \
                -p "${port}:${port}" \
                "$DOCKER_IMAGE" \
                simple-run \
                -n 1.1.1.1 \
                -i prefer-ipv4 \
                "0.0.0.0:${port}" \
                "$secret" \
                >/dev/null \
            && echo -e "    ${GREEN}✓ Запущен на порту ${port}.${NC}" \
            || echo -e "    ${RED}✗ Ошибка запуска.${NC}"
        fi
    done < "$USERS_FILE"
}

# ==============================================================
# УПРАВЛЕНИЕ КОНТЕЙНЕРАМИ
# ==============================================================

start_all() {
    check_root
    check_docker
    echo -e "${CYAN}Запуск всех контейнеров...${NC}"

    local count=0
    while read -r name; do
        docker start "$name" >/dev/null
        echo -e "  ${GREEN}✓ $name${NC}"
        (( count++ )) || true
    done < <(docker ps -a --format '{{.Names}}' | grep "^${CONTAINER_PREFIX}-" || true)

    [ "$count" -eq 0 ] && echo -e "${YELLOW}Контейнеров не найдено.${NC}" \
                       || echo -e "${GREEN}Запущено: $count контейнеров.${NC}"
}

stop_all() {
    check_root
    check_docker
    echo -e "${CYAN}Остановка всех контейнеров...${NC}"

    local count=0
    while read -r name; do
        docker stop "$name" >/dev/null
        echo -e "  ${YELLOW}✓ $name${NC}"
        (( count++ )) || true
    done < <(docker ps --format '{{.Names}}' | grep "^${CONTAINER_PREFIX}-" || true)

    [ "$count" -eq 0 ] && echo -e "${YELLOW}Запущенных контейнеров не найдено.${NC}" \
                       || echo -e "${YELLOW}Остановлено: $count контейнеров.${NC}"
}

restart_all() {
    check_root
    check_docker
    echo -e "${CYAN}Перезапуск всех контейнеров...${NC}"

    local count=0
    while read -r name; do
        docker restart "$name" >/dev/null
        echo -e "  ${GREEN}✓ $name${NC}"
        (( count++ )) || true
    done < <(docker ps -a --format '{{.Names}}' | grep "^${CONTAINER_PREFIX}-" || true)

    [ "$count" -eq 0 ] && echo -e "${YELLOW}Контейнеров не найдено.${NC}" \
                       || echo -e "${GREEN}Перезапущено: $count контейнеров.${NC}"
}

status_all() {
    check_root
    check_docker
    load_config

    echo -e "${BOLD}${BLUE}=== Статус контейнеров ===${NC}"
    echo ""

    if [ ! -s "$USERS_FILE" ]; then
        echo -e "${YELLOW}Пользователей нет.${NC}"
        return
    fi

    while IFS=':' read -r username port secret domain; do
        [[ -z "$username" ]] && continue
        local container_name="${CONTAINER_PREFIX}-${username}"
        local status

        if docker ps --format '{{.Names}}' 2>/dev/null \
           | grep -q "^${container_name}$"; then
            status="${GREEN}работает${NC}"
        else
            status="${RED}остановлен${NC}"
        fi

        echo -e "  ${CYAN}${username}${NC} | порт: ${port} | домен: ${domain} | ${status}"
    done < "$USERS_FILE"
    echo ""
}

update_image() {
    check_root
    check_docker
    echo -e "${CYAN}Обновление образа ${DOCKER_IMAGE}...${NC}"
    docker pull "$DOCKER_IMAGE"
    echo -e "${GREEN}Образ обновлён. Перезапуск контейнеров...${NC}"
    restart_all
}

show_traffic() {
    check_root
    check_docker
    echo -e "${CYAN}Трафик контейнеров (Ctrl+C для выхода):${NC}"
    echo ""
    docker stats --format "table {{.Name}}\t{{.NetIO}}\t{{.CPUPerc}}\t{{.MemUsage}}" \
        $(docker ps --format '{{.Names}}' | grep "^${CONTAINER_PREFIX}-" | tr '\n' ' ') \
        2>/dev/null || echo -e "${YELLOW}Нет запущенных контейнеров.${NC}"
}

# ==============================================================
# УПРАВЛЕНИЕ ДОМЕНАМИ
# ==============================================================

list_domains() {
    echo -e "${BOLD}${BLUE}=== Домены GLOBAL ===${NC}"
    if [ -f "$GLOBAL_DOMAINS_FILE" ] && [ -s "$GLOBAL_DOMAINS_FILE" ]; then
        local i=1
        while read -r d; do
            echo -e "  ${i}. ${d}"
            (( i++ )) || true
        done < "$GLOBAL_DOMAINS_FILE"
    else
        echo -e "  ${YELLOW}(список пуст или файл не найден)${NC}"
    fi

    echo ""
    echo -e "${BOLD}${BLUE}=== Домены RU ===${NC}"
    if [ -f "$RU_DOMAINS_FILE" ] && [ -s "$RU_DOMAINS_FILE" ]; then
        local i=1
        while read -r d; do
            echo -e "  ${i}. ${d}"
            (( i++ )) || true
        done < "$RU_DOMAINS_FILE"
    else
        echo -e "  ${YELLOW}(список пуст или файл не найден)${NC}"
    fi
}

# Только отчёт — файлы НЕ изменяются
check_domains() {
    echo -e "${BOLD}${BLUE}=== Проверка доступности доменов ===${NC}"
    echo ""

    for list_name in "GLOBAL" "RU"; do
        local domain_file
        [ "$list_name" = "RU" ] && domain_file="$RU_DOMAINS_FILE" \
                                 || domain_file="$GLOBAL_DOMAINS_FILE"

        echo -e "${CYAN}Список ${list_name}:${NC}"

        if [ ! -f "$domain_file" ] || [ ! -s "$domain_file" ]; then
            echo -e "  ${YELLOW}(файл пуст или не найден)${NC}"
            echo ""
            continue
        fi

        local ok=0 fail=0
        while read -r domain; do
            [[ -z "$domain" ]] && continue
            if check_domain_reachability "$domain"; then
                echo -e "  ${GREEN}✓ ${domain}${NC}"
                (( ok++ )) || true
            else
                echo -e "  ${RED}✗ ${domain} — недоступен${NC}"
                (( fail++ )) || true
            fi
        done < "$domain_file"

        echo -e "  Итого: ${GREEN}${ok} доступно${NC}, ${RED}${fail} недоступно${NC}"
        echo ""
    done
}

add_domain() {
    check_root
    local region="${1:-}"
    local domain="${2:-}"

    if [ -z "$region" ] || [ -z "$domain" ]; then
        echo -e "${RED}Использование: mtproto-manager add-domain <GLOBAL|RU> <домен>${NC}"
        exit 1
    fi

    region="${region^^}"
    local domain_file
    [ "$region" = "RU" ] && domain_file="$RU_DOMAINS_FILE" \
                         || domain_file="$GLOBAL_DOMAINS_FILE"

    if grep -q "^${domain}$" "$domain_file" 2>/dev/null; then
        echo -e "${YELLOW}Домен '${domain}' уже есть в списке ${region}.${NC}"
        return
    fi

    echo -e "${CYAN}Проверка доступности ${domain}...${NC}"
    if check_domain_reachability "$domain"; then
        echo "$domain" >> "$domain_file"
        echo -e "${GREEN}Домен '${domain}' добавлен в список ${region}.${NC}"
    else
        echo -e "${RED}Домен '${domain}' недоступен. Не добавлен.${NC}"
        exit 1
    fi
}

remove_domain() {
    check_root
    local region="${1:-}"
    local domain="${2:-}"

    if [ -z "$region" ] || [ -z "$domain" ]; then
        echo -e "${RED}Использование: mtproto-manager remove-domain <GLOBAL|RU> <домен>${NC}"
        exit 1
    fi

    region="${region^^}"
    local domain_file
    [ "$region" = "RU" ] && domain_file="$RU_DOMAINS_FILE" \
                         || domain_file="$GLOBAL_DOMAINS_FILE"

    if ! grep -q "^${domain}$" "$domain_file" 2>/dev/null; then
        echo -e "${YELLOW}Домен '${domain}' не найден в списке ${region}.${NC}"
        return
    fi

    sed -i "/^${domain}$/d" "$domain_file"
    echo -e "${GREEN}Домен '${domain}' удалён из списка ${region}.${NC}"
}

# ==============================================================
# УПРАВЛЕНИЕ ЗАРЕЗЕРВИРОВАННЫМИ ПОРТАМИ
# ==============================================================

list_reserved_ports() {
    load_config
    echo -e "${BOLD}${BLUE}=== Зарезервированные порты ===${NC}"
    if [ "${#RESERVED_PORTS[@]}" -eq 0 ]; then
        echo -e "  ${YELLOW}(список пуст)${NC}"
        return
    fi
    for p in "${RESERVED_PORTS[@]}"; do
        echo -e "  ${CYAN}${p}${NC}"
    done
}

add_reserved_port() {
    check_root
    load_config
    local port="${1:-}"

    if [ -z "$port" ]; then
        echo -e "${RED}Использование: mtproto-manager add-reserved-port <порт>${NC}"
        exit 1
    fi

    if printf '%s\n' "${RESERVED_PORTS[@]:-}" | grep -qw "$port"; then
        echo -e "${YELLOW}Порт ${port} уже зарезервирован.${NC}"
        return
    fi

    RESERVED_PORTS+=("$port")
    save_config
    echo -e "${GREEN}Порт ${port} добавлен в зарезервированные.${NC}"
}

remove_reserved_port() {
    check_root
    load_config
    local port="${1:-}"

    if [ -z "$port" ]; then
        echo -e "${RED}Использование: mtproto-manager remove-reserved-port <порт>${NC}"
        exit 1
    fi

    local new_ports=()
    for p in "${RESERVED_PORTS[@]:-}"; do
        [[ "$p" != "$port" ]] && new_ports+=("$p")
    done

    RESERVED_PORTS=("${new_ports[@]:-}")
    save_config
    echo -e "${GREEN}Порт ${port} удалён из зарезервированных.${NC}"
}

# ==============================================================
# УДАЛЕНИЕ (uninstall)
# ==============================================================

uninstall_script() {
    check_root

    echo -e "${RED}${BOLD}=== Удаление mtproto-manager ===${NC}"
    echo ""
    read -rp "Вы уверены? Все контейнеры и конфигурация будут удалены. [y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && echo "Отменено." && return

    check_docker

    echo -e "${CYAN}Остановка и удаление контейнеров...${NC}"
    local containers
    containers=$(docker ps -a --format '{{.Names}}' | grep "^${CONTAINER_PREFIX}-" || true)

    if [ -n "$containers" ]; then
        echo "$containers" | while read -r name; do
            docker stop "$name" >/dev/null 2>&1 || true
            docker rm "$name" >/dev/null 2>&1 || true
            echo -e "  ${YELLOW}✓ $name удалён${NC}"
        done
    else
        echo -e "  ${YELLOW}Контейнеров не найдено.${NC}"
    fi

    echo -e "${CYAN}Удаление конфигурации...${NC}"
    rm -rf "$CONFIG_DIR"
    echo -e "  ${GREEN}✓ $CONFIG_DIR удалён${NC}"

    echo -e "${CYAN}Удаление бинарника...${NC}"
    rm -f "$BINARY_PATH"
    echo -e "  ${GREEN}✓ $BINARY_PATH удалён${NC}"

    echo ""
    echo -e "${GREEN}Удаление завершено.${NC}"
}

# ==============================================================
# СПРАВКА
# ==============================================================

show_help() {
    echo ""
    echo -e "${BOLD}Использование:${NC} mtproto-manager <команда> [аргументы]"
    echo ""
    echo -e "${BOLD}${BLUE}Установка и настройка:${NC}"
    echo "  install                              Установить скрипт и зависимости"
    echo "  setup                                Настроить регион и домен сервера"
    echo "  uninstall                            Полностью удалить скрипт и данные"
    echo ""
    echo -e "${BOLD}${BLUE}Пользователи:${NC}"
    echo "  add-user <имя> [домен] [порт]        Создать пользователя"
    echo "  remove-user <имя>                    Удалить пользователя"
    echo "  list-users                           Список всех пользователей"
    echo "  show-user <имя>                      Данные пользователя + QR-код"
    echo "  block-user <имя>                     Заблокировать пользователя"
    echo "  unblock-user <имя>                   Разблокировать пользователя"
    echo "  restart-user <имя>                   Перезапустить прокси пользователя"
    echo "  export                               Экспорт конфигурации пользователей"
    echo "  import <файл>                        Импорт конфигурации пользователей"
    echo ""
    echo -e "${BOLD}${BLUE}Контейнеры:${NC}"
    echo "  start                                Запустить все прокси"
    echo "  stop                                 Остановить все прокси"
    echo "  restart                              Перезапустить все прокси"
    echo "  status                               Статус всех прокси"
    echo "  update                               Обновить образ и перезапустить"
    echo "  show-traffic                         Трафик всех прокси"
    echo ""
    echo -e "${BOLD}${BLUE}Домены FakeTLS:${NC}"
    echo "  list-domains                         Показать все домены"
    echo "  check-domains                        Проверить доступность доменов"
    echo "  add-domain <GLOBAL|RU> <домен>       Добавить домен"
    echo "  remove-domain <GLOBAL|RU> <домен>    Удалить домен"
    echo ""
    echo -e "${BOLD}${BLUE}Зарезервированные порты:${NC}"
    echo "  list-reserved-ports                  Показать зарезервированные порты"
    echo "  add-reserved-port <порт>             Добавить порт"
    echo "  remove-reserved-port <порт>          Удалить порт"
    echo ""
    echo "  help                                 Показать эту справку"
    echo ""
}

# ==============================================================
# ИНТЕРАКТИВНОЕ МЕНЮ
# ==============================================================

show_menu() {
    while true; do
        clear
        echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${BLUE}║                 mtproto-manager                  ║${NC}"
        echo -e "${BOLD}${BLUE}║  https://github.com/vdistortion/mtproto-manager  ║${NC}"
        echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${BOLD}  Пользователи${NC}"
        echo -e "  ${CYAN}1${NC}) Добавить пользователя"
        echo -e "  ${CYAN}2${NC}) Удалить пользователя"
        echo -e "  ${CYAN}3${NC}) Список пользователей"
        echo -e "  ${CYAN}4${NC}) Показать пользователя (QR)"
        echo -e "  ${CYAN}5${NC}) Заблокировать пользователя"
        echo -e "  ${CYAN}6${NC}) Разблокировать пользователя"
        echo -e "  ${CYAN}7${NC}) Перезапустить пользователя"
        echo ""
        echo -e "${BOLD}  Контейнеры${NC}"
        echo -e "  ${CYAN}8${NC}) Запустить все"
        echo -e "  ${CYAN}9${NC}) Остановить все"
        echo -e "  ${CYAN}10${NC}) Перезапустить все"
        echo -e "  ${CYAN}11${NC}) Статус"
        echo -e "  ${CYAN}12${NC}) Трафик"
        echo -e "  ${CYAN}13${NC}) Обновить образ"
        echo ""
        echo -e "${BOLD}  Домены${NC}"
        echo -e "  ${CYAN}14${NC}) Список доменов"
        echo -e "  ${CYAN}15${NC}) Проверить домены"
        echo -e "  ${CYAN}16${NC}) Добавить домен"
        echo -e "  ${CYAN}17${NC}) Удалить домен"
        echo ""
        echo -e "${BOLD}  Прочее${NC}"
        echo -e "  ${CYAN}18${NC}) Настройка сервера"
        echo -e "  ${CYAN}19${NC}) Зарезервированные порты"
        echo -e "  ${CYAN}20${NC}) Экспорт конфигурации"
        echo -e "  ${CYAN}21${NC}) Импорт конфигурации"
        echo -e "  ${CYAN}22${NC}) Удалить скрипт и все данные"
        echo -e "  ${CYAN}0${NC})  Выход"
        echo ""
        read -rp "  Выбор: " choice

        case "$choice" in
            1)
                read -rp "  Имя пользователя: " u
                read -rp "  Домен (Enter = авто): " d
                read -rp "  Порт (Enter = авто): " p
                add_user "$u" "$d" "$p"
                read -rp "  Нажмите Enter..."
                ;;
            2)
                read -rp "  Имя пользователя: " u
                remove_user "$u"
                read -rp "  Нажмите Enter..."
                ;;
            3)
                list_users
                read -rp "  Нажмите Enter..."
                ;;
            4)
                read -rp "  Имя пользователя: " u
                show_user "$u"
                read -rp "  Нажмите Enter..."
                ;;
            5)
                read -rp "  Имя пользователя: " u
                block_user "$u"
                read -rp "  Нажмите Enter..."
                ;;
            6)
                read -rp "  Имя пользователя: " u
                unblock_user "$u"
                read -rp "  Нажмите Enter..."
                ;;
            7)
                read -rp "  Имя пользователя: " u
                restart_user "$u"
                read -rp "  Нажмите Enter..."
                ;;
            8)  start_all;   read -rp "  Нажмите Enter..." ;;
            9)  stop_all;    read -rp "  Нажмите Enter..." ;;
            10) restart_all; read -rp "  Нажмите Enter..." ;;
            11) status_all;  read -rp "  Нажмите Enter..." ;;
            12) show_traffic; read -rp "  Нажмите Enter..." ;;
            13) update_image; read -rp "  Нажмите Enter..." ;;
            14) list_domains; read -rp "  Нажмите Enter..." ;;
            15) check_domains; read -rp "  Нажмите Enter..." ;;
            16)
                read -rp "  Регион [GLOBAL/RU]: " r
                read -rp "  Домен: " d
                add_domain "$r" "$d"
                read -rp "  Нажмите Enter..."
                ;;
            17)
                read -rp "  Регион [GLOBAL/RU]: " r
                read -rp "  Домен: " d
                remove_domain "$r" "$d"
                read -rp "  Нажмите Enter..."
                ;;
            18) setup_server; read -rp "  Нажмите Enter..." ;;
            19)
                list_reserved_ports
                echo ""
                echo -e "  ${CYAN}a${NC}) Добавить порт  ${CYAN}r${NC}) Удалить порт  ${CYAN}Enter${NC}) Назад"
                read -rp "  Выбор: " pr
                case "$pr" in
                    a) read -rp "  Порт: " p; add_reserved_port "$p" ;;
                    r) read -rp "  Порт: " p; remove_reserved_port "$p" ;;
                esac
                read -rp "  Нажмите Enter..."
                ;;
            20) export_users; read -rp "  Нажмите Enter..." ;;
            21)
                read -rp "  Файл для импорта: " f
                import_users "$f"
                read -rp "  Нажмите Enter..."
                ;;
            22)
                uninstall_script
                read -rp "  Нажмите Enter..."
                ;;
            0) exit 0 ;;
            *) echo -e "  ${RED}Неверный выбор.${NC}"; sleep 1 ;;
        esac
    done
}

# ==============================================================
# ТОЧКА ВХОДА
# ==============================================================

main() {
    local cmd="${1:-}"
    shift || true

    case "$cmd" in
        install)              install_script ;;
        setup)                setup_server "$@" ;;
        uninstall)            uninstall_script ;;
        add-user)             add_user "$@" ;;
        remove-user)          remove_user "$@" ;;
        list-users)           list_users ;;
        show-user)            show_user "$@" ;;
        block-user)           block_user "$@" ;;
        unblock-user)         unblock_user "$@" ;;
        restart-user)         restart_user "$@" ;;
        export)               export_users ;;
        import)               import_users "$@" ;;
        start)                start_all ;;
        stop)                 stop_all ;;
        restart)              restart_all ;;
        status)               status_all ;;
        update)               update_image ;;
        show-traffic)         show_traffic ;;
        list-domains)         list_domains ;;
        check-domains)        check_domains ;;
        add-domain)           add_domain "$@" ;;
        remove-domain)        remove_domain "$@" ;;
        list-reserved-ports)  list_reserved_ports ;;
        add-reserved-port)    add_reserved_port "$@" ;;
        remove-reserved-port) remove_reserved_port "$@" ;;
        help|--help|-h)       show_help ;;
        "")                   show_menu ;;
        *)
            echo -e "${RED}Неизвестная команда: ${cmd}${NC}"
            show_help
            exit 1
            ;;
    esac
}

main "$@"

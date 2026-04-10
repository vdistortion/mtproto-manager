#!/usr/bin/env bash

set -euo pipefail

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- НАСТРОЙКИ ---
CONFIG_DIR="/root/.mtproto"
USERS_FILE="$CONFIG_DIR/users.conf"
SERVER_DOMAIN_FILE="$CONFIG_DIR/domain.txt"
CONTAINER_PREFIX="mtproto-proxy"
MSS_VALUE="1100"

# Регион сервера: "GLOBAL" (для Европы/Германии) или "RU" (для России)
REGION="GLOBAL"

# Списки доменов для FakeTLS
DOMAINS_GLOBAL=(
    "google.com" "microsoft.com" "cloudflare.com" "aws.amazon.com"
    "github.com" "apple.com" "windowsupdate.com" "itunes.apple.com"
    "netflix.com" "zoom.us" "linkedin.com" "twitch.tv" "bing.com"
    "wikipedia.org" "yahoo.com" "reddit.com" "spotify.com"
)

DOMAINS_RU=(
    "ya.ru" "vk.com" "mail.ru" "gosuslugi.ru" "sberbank.ru"
    "dzen.ru" "avito.ru" "ozon.ru" "wildberries.ru" "yandex.ru"
    "auto.ru" "kinopoisk.ru" "habr.com" "tbank.ru" "max.ru"
    "rutube.ru" "lenta.ru" "rbc.ru" "ok.ru"
)

# Зарезервированные порты Marzban
RESERVED_PORTS=(443 1080 10086 10087 2053 8443)

# Проверка на root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}❌ Скрипт необходимо запускать от имени root (sudo)${NC}"
    exit 1
fi

mkdir -p "$CONFIG_DIR"

# --- СЕТЕВЫЕ ФУНКЦИИ (IPTABLES) ---

get_iface() {
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

get_docker_subnet() {
    local s
    s="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)"
    [ -n "$s" ] && echo "$s" || echo "172.17.0.0/16"
}

manage_mss_rule() {
    local port="$1"
    local action="$2"
    local iface=$(get_iface)
    local subnet=$(get_docker_subnet)

    [ -z "$iface" ] && return 0

    if [ "$action" = "add" ]; then
        iptables -t mangle -C PREROUTING -i "$iface" -p tcp --dport "$port" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_VALUE" 2>/dev/null || \
        iptables -t mangle -I PREROUTING 1 -i "$iface" -p tcp --dport "$port" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_VALUE"

        iptables -t mangle -C POSTROUTING -o "$iface" -s "$subnet" -p tcp --sport "$port" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_VALUE" 2>/dev/null || \
        iptables -t mangle -I POSTROUTING 1 -o "$iface" -s "$subnet" -p tcp --sport "$port" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_VALUE"
    elif [ "$action" = "del" ]; then
        iptables -t mangle -D PREROUTING -i "$iface" -p tcp --dport "$port" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_VALUE" 2>/dev/null || true
        iptables -t mangle -D POSTROUTING -o "$iface" -s "$subnet" -p tcp --sport "$port" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_VALUE" 2>/dev/null || true
    fi

    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1
    fi
}

# --- ФУНКЦИИ УПРАВЛЕНИЯ ПРОКСИ ---

generate_secret() {
    local domain="$1"
    DOMAIN_HEX=$(echo -n "$domain" | xxd -ps | tr -d '\n')
    DOMAIN_LEN=${#DOMAIN_HEX}
    NEEDED=$((30 - DOMAIN_LEN))

    if [ $NEEDED -gt 0 ]; then
        RANDOM_HEX=$(openssl rand -hex 15 | cut -c1-$NEEDED)
    else
        RANDOM_HEX=""
    fi
    echo "ee${DOMAIN_HEX}${RANDOM_HEX}"
}

is_port_reserved() {
    local p="$1"
    for rp in "${RESERVED_PORTS[@]}"; do
        [[ "$p" == "$rp" ]] && return 0
    done
    return 1
}

create_user_proxy() {
    local username="$1"
    local domain="${2:-}"
    local port="${3:-8443}"

    if [ -z "$domain" ]; then
        if [ "$REGION" = "RU" ]; then
            local rand_idx=$((RANDOM % ${#DOMAINS_RU[@]}))
            domain="${DOMAINS_RU[$rand_idx]}"
        else
            local rand_idx=$((RANDOM % ${#DOMAINS_GLOBAL[@]}))
            domain="${DOMAINS_GLOBAL[$rand_idx]}"
        fi
    fi

    echo -e "${BLUE}🔧 Создание прокси для пользователя: $username${NC}"

    local secret=$(generate_secret "$domain")

    if is_port_reserved "$port" || ss -tuln | grep -q ":$port "; then
        echo -e "${YELLOW}⚠️ Порт $port занят или зарезервирован. Ищем свободный...${NC}"
        port=8443
        while is_port_reserved "$port" || ss -tuln | grep -q ":$port "; do
            ((port++))
        done
    fi

    local container_name="${CONTAINER_PREFIX}-${username}"
    docker stop "$container_name" 2>/dev/null || true
    docker rm "$container_name" 2>/dev/null || true

    docker run -d \
        --name "$container_name" \
        --restart unless-stopped \
        -p "${port}:443" \
        -e SECRET="$secret" \
        telegrammessenger/proxy > /dev/null 2>&1

    if [ $? -eq 0 ]; then
        cat > "$CONFIG_DIR/${username}.conf" << EOF
PORT="$port"
SECRET="$secret"
DOMAIN="$domain"
EOF

        if ! grep -q "^${username}:" "$USERS_FILE" 2>/dev/null; then
            echo "$username:$port:$domain" >> "$USERS_FILE"
        else
            sed -i "/^${username}:/c\\${username}:${port}:${domain}" "$USERS_FILE"
        fi

        manage_mss_rule "$port" "add"

        local server_ip=$(curl -s api.ipify.org)
        local srv_domain=""
        [ -f "$SERVER_DOMAIN_FILE" ] && srv_domain=$(cat "$SERVER_DOMAIN_FILE")

        echo -e "${GREEN}✅ Прокси создан успешно!${NC}"
        echo -e "👤 Пользователь: $username"
        echo -e "🔌 Порт: $port"
        echo -e "🌐 Домен (FakeTLS): $domain"
        echo -e "🔗 Ссылка (IP): ${GREEN}https://t.me/proxy?server=${server_ip}&port=${port}&secret=${secret}${NC}"
        if [ -n "$srv_domain" ]; then
            echo -e "🔗 Ссылка (Домен): ${GREEN}https://t.me/proxy?server=${srv_domain}&port=${port}&secret=${secret}${NC}"
        fi
        echo ""
    else
        echo -e "${RED}❌ Ошибка при создании прокси${NC}"
        return 1
    fi
}

delete_user_proxy() {
    local username="$1"
    local container_name="${CONTAINER_PREFIX}-${username}"

    if [ -f "$CONFIG_DIR/${username}.conf" ]; then
        local port_to_del=$(grep -E '^PORT=' "$CONFIG_DIR/${username}.conf" | cut -d'=' -f2- | tr -d '"'\''\r' || true)
        [ -n "$port_to_del" ] && manage_mss_rule "$port_to_del" "del"
    fi

    docker stop "$container_name" 2>/dev/null || true
    docker rm "$container_name" 2>/dev/null || true
    rm -f "$CONFIG_DIR/${username}.conf"

    sed -i "/^${username}:/d" "$USERS_FILE" 2>/dev/null || true

    echo -e "${GREEN}✅ Прокси пользователя $username удалён, правила фаервола очищены${NC}"
}

list_users() {
    echo -e "${BLUE}📋 Список активных прокси (отсортировано по портам):${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ ! -f "$USERS_FILE" ] || [ ! -s "$USERS_FILE" ]; then
        echo "Нет активных пользователей"
        return
    fi

    local server_ip
    server_ip=$(curl -s api.ipify.org || echo "127.0.0.1")
    local srv_domain=""
    [ -f "$SERVER_DOMAIN_FILE" ] && srv_domain=$(cat "$SERVER_DOMAIN_FILE" 2>/dev/null || true)

    while IFS=':' read -r username port domain; do
        [ -z "$username" ] && continue

        local conf_file="$CONFIG_DIR/${username}.conf"
        if [ -f "$conf_file" ]; then
            local c_port c_secret c_domain
            c_port=$(grep -E '^PORT=' "$conf_file" | cut -d'=' -f2- | tr -d '"'\''\r' || true)
            c_secret=$(grep -E '^SECRET=' "$conf_file" | cut -d'=' -f2- | tr -d '"'\''\r' || true)
            c_domain=$(grep -E '^DOMAIN=' "$conf_file" | cut -d'=' -f2- | tr -d '"'\''\r' || true)

            [ -z "$c_port" ] && c_port="$port"
            [ -z "$c_domain" ] && c_domain="$domain"

            if [ -n "$c_secret" ]; then
                echo -e "👤 ${GREEN}${username}${NC} | 🔌 ${YELLOW}${c_port}${NC} | 🌐 ${c_domain}"
                echo -e " 🔗 IP: https://t.me/proxy?server=${server_ip}&port=${c_port}&secret=${c_secret}"
                if [ -n "$srv_domain" ]; then
                    echo -e " 🔗 Домен: https://t.me/proxy?server=${srv_domain}&port=${c_port}&secret=${c_secret}"
                fi
                echo ""
            else
                echo -e "${RED}⚠️ Ошибка: у ${username} нет SECRET в конфиге!${NC}\n"
            fi
        else
            echo -e "${RED}⚠️ Ошибка: конфиг ${conf_file} не найден!${NC}\n"
        fi
    done < <(cat "$USERS_FILE" | tr -d '\r' | grep -v '^\s*$' | sort -t':' -k2 -n || true)
}

rebuild_users_file() {
    echo -e "${BLUE}🔄 Перестраиваем файл $USERS_FILE из существующих конфигов...${NC}"
    : > "$USERS_FILE"

    for conf_file in "$CONFIG_DIR"/*.conf; do
        [ -e "$conf_file" ] || continue
        [[ "$conf_file" == "$USERS_FILE" ]] && continue

        # Имя пользователя берем из названия файла
        local username=$(basename "$conf_file" .conf)
        local port=$(grep -E '^PORT=' "$conf_file" | cut -d'=' -f2- | tr -d '"'\''\r' || true)
        local domain=$(grep -E '^DOMAIN=' "$conf_file" | cut -d'=' -f2- | tr -d '"'\''\r' || true)

        if [ -n "$username" ] && [ -n "$port" ] && [ -n "$domain" ]; then
            echo "$username:$port:$domain" >> "$USERS_FILE"
            echo -e "  ✅ Добавлен: ${GREEN}$username${NC}"
        else
            echo -e "  ❌ Пропущен: ${YELLOW}$conf_file${NC} (неполные данные)${NC}"
        fi
    done
    echo -e "${GREEN}✅ Файл $USERS_FILE успешно перестроен.${NC}"
}

export_config() {
    local export_file="mtproto_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    tar -C "/root" -czf "$export_file" ".mtproto"
    echo -e "${GREEN}✅ Конфигурация экспортирована в: $(pwd)/$export_file${NC}"
}

import_config() {
    local import_file="$1"
    if [ ! -f "$import_file" ]; then
        echo -e "${RED}❌ Файл не найден: $import_file${NC}"
        return 1
    fi

    tar -xzf "$import_file" -C "/root"
    echo -e "${GREEN}✅ Конфигурация распакована${NC}"

    sync_all_proxies
}

check_proxy_status() {
    echo -e "${BLUE}🔍 Проверка статуса прокси-контейнеров:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ ! -f "$USERS_FILE" ] || [ ! -s "$USERS_FILE" ]; then
        echo "Нет настроенных пользователей"
        return
    fi

    while IFS=':' read -r username port domain; do
        [ -z "$username" ] && continue
        local container_name="${CONTAINER_PREFIX}-${username}"
        local status=$(docker ps -a --filter "name=${container_name}" --format "{{.Status}}" 2>/dev/null || true)

        if [[ "$status" == *"Up"* ]]; then
            echo -e "👤 ${GREEN}$username${NC} | Статус: ${GREEN}Запущен${NC} (Порт: $port)"
        elif [[ "$status" == *"Exited"* ]]; then
            echo -e "👤 ${YELLOW}$username${NC} | Статус: ${YELLOW}Остановлен${NC} (Порт: $port)"
        else
            echo -e "👤 ${RED}$username${NC} | Статус: ${RED}Не найден${NC} (Конфиг есть, контейнера нет)"
        fi
    done < <(cat "$USERS_FILE" | tr -d '\r' | grep -v '^\s*$' | sort -t':' -k2 -n || true)
    echo ""
}

sync_all_proxies() {
    echo -e "${BLUE}🚀 Синхронизация и запуск всех прокси...${NC}"
    rebuild_users_file

    if [ ! -f "$USERS_FILE" ] || [ ! -s "$USERS_FILE" ]; then
        echo "Нет пользователей для запуска."
        return
    fi

    while IFS=':' read -r username port domain; do
        [ -z "$username" ] && continue
        local conf_file="$CONFIG_DIR/${username}.conf"
        local container_name="${CONTAINER_PREFIX}-${username}"

        if [ -f "$conf_file" ]; then
            local c_port c_secret c_domain
            c_port=$(grep -E '^PORT=' "$conf_file" | cut -d'=' -f2- | tr -d '"'\''\r' || true)
            c_secret=$(grep -E '^SECRET=' "$conf_file" | cut -d'=' -f2- | tr -d '"'\''\r' || true)
            c_domain=$(grep -E '^DOMAIN=' "$conf_file" | cut -d'=' -f2- | tr -d '"'\''\r' || true)

            if [ -n "$c_port" ] && [ -n "$c_secret" ]; then
                local status=$(docker ps -a --filter "name=${container_name}" --format "{{.Status}}" 2>/dev/null || true)

                if [[ "$status" == *"Up"* ]]; then
                    echo -e "  ✅ ${GREEN}$username${NC} уже запущен."
                else
                    echo -e "  🔄 ${YELLOW}$username${NC}: Контейнер не запущен или не существует. Пересоздаем..."
                    docker stop "$container_name" 2>/dev/null || true
                    docker rm "$container_name" 2>/dev/null || true

                    docker run -d \
                        --name "$container_name" \
                        --restart unless-stopped \
                        -p "${c_port}:443" \
                        -e SECRET="$c_secret" \
                        telegrammessenger/proxy > /dev/null 2>&1

                    if [ $? -eq 0 ]; then
                        manage_mss_rule "$c_port" "add"
                        echo -e "  🚀 ${GREEN}$username${NC} успешно запущен на порту ${c_port}."
                    else
                        echo -e "  ❌ ${RED}Ошибка запуска ${username}${NC}."
                    fi
                fi
            else
                echo -e "  ❌ ${RED}Пропущен ${username}: неполные данные в конфиге ${conf_file}${NC}"
            fi
        else
            echo -e "  ❌ ${RED}Пропущен ${username}: конфиг ${conf_file} не найден!${NC}"
        fi
    done < <(cat "$USERS_FILE" | tr -d '\r' | grep -v '^\s*$' | sort -t':' -k2 -n || true)
    echo -e "${GREEN}✅ Синхронизация завершена.${NC}"
}

setup_server() {
    echo -e "${BLUE}[1/5] Установка пакетов...${NC}"
    apt-get update -y
    apt-get install -y docker.io iptables-persistent curl openssl xxd conntrack

    echo -e "${BLUE}[2/5] Настройка Docker (MTU=1400)...${NC}"
    systemctl enable --now docker
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'EOF'
{ "mtu": 1400 }
EOF
    systemctl restart docker

    echo -e "${BLUE}[3/5] Настройка ядра (BBR и tcp_mtu_probing)...${NC}"
    printf "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n" > /etc/sysctl.d/98-bbr.conf
    printf "net.ipv4.tcp_mtu_probing=1\n" > /etc/sysctl.d/99-mtproxy-mtu.conf
    sysctl --system >/dev/null || true

    echo -e "${BLUE}[4/5] Восстановление правил для существующих пользователей...${NC}"
    if [ -f "$USERS_FILE" ]; then
        while IFS=':' read -r username port domain; do
            local conf_file="$CONFIG_DIR/${username}.conf"
            local current_port=$(grep -E '^PORT=' "$conf_file" | cut -d'=' -f2- | tr -d '"'\''\r' || true)
            [ -n "$current_port" ] && manage_mss_rule "$current_port" "add"
        done < <(cat "$USERS_FILE" | tr -d '\r' | grep -v '^\s*$' || true)
    fi

    echo -e "${BLUE}[5/5] Настройка домена сервера...${NC}"
    read -p "Введите домен вашего сервера для генерации ссылок (нажмите Enter, чтобы пропустить): " srv_domain
    if [ -n "$srv_domain" ]; then
        echo "$srv_domain" > "$SERVER_DOMAIN_FILE"
        echo -e "${GREEN}Домен $srv_domain сохранен локально.${NC}"
    else
        rm -f "$SERVER_DOMAIN_FILE"
        echo -e "${YELLOW}Домен не указан, будут генерироваться только IP-ссылки.${NC}"
    fi

    echo -e "${GREEN}✅ Базовая настройка сервера завершена!${NC}"
}

case "${1:-help}" in
    setup) setup_server ;;
    create)
        [ -z "${2:-}" ] && { echo "Укажите имя пользователя!"; exit 1; }
        create_user_proxy "$2" "${3:-}" "${4:-8443}"
        ;;
    delete)
        [ -z "${2:-}" ] && { echo "Укажите имя пользователя!"; exit 1; }
        delete_user_proxy "$2"
        ;;
    list) list_users ;;
    export) export_config ;;
    import)
        [ -z "${2:-}" ] && { echo "Укажите файл бэкапа!"; exit 1; }
        import_config "$2"
        ;;
    rebuild) rebuild_users_file ;;
    check) check_proxy_status ;;
    sync) sync_all_proxies ;;
    *)
        echo -e "${YELLOW}Использование:${NC}"
        echo "  $0 setup                               - Первичная настройка сервера"
        echo "  $0 create <username> [domain] [port]   - Создать прокси (домен и порт можно пропустить)"
        echo "  $0 delete <username>                   - Удалить прокси"
        echo "  $0 list                                - Список всех прокси"
        echo "  $0 export                              - Экспортировать конфиги"
        echo "  $0 import <file>                       - Импортировать конфиги"
        echo "  $0 rebuild                             - Перестроить users.conf из файлов конфигов"
        echo "  $0 check                               - Проверить статус всех прокси"
        echo "  $0 sync                                - Запустить/перезапустить все прокси по конфигам"
        ;;
esac

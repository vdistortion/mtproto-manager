#!/usr/bin/env bash
set -euo pipefail

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Конфигурация
CONFIG_DIR="$HOME/.mtproto"
USERS_FILE="$CONFIG_DIR/users.conf"
CONTAINER_PREFIX="mtproto-proxy"
DEFAULT_DOMAIN="ya.ru"
MSS_VALUE="1100"

# Проверка на root (нужно для docker и iptables)
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

# Функция динамического управления правилами MSS для порта
manage_mss_rule() {
    local port="$1"
    local action="$2" # "add" или "del"
    local iface=$(get_iface)
    local subnet=$(get_docker_subnet)

    [ -z "$iface" ] && return 0

    if [ "$action" = "add" ]; then
        # Добавляем PREROUTING (если еще нет)
        iptables -t mangle -C PREROUTING -i "$iface" -p tcp --dport "$port" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_VALUE" 2>/dev/null || \
        iptables -t mangle -I PREROUTING 1 -i "$iface" -p tcp --dport "$port" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_VALUE"

        # Добавляем POSTROUTING (если еще нет)
        iptables -t mangle -C POSTROUTING -o "$iface" -s "$subnet" -p tcp --sport "$port" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_VALUE" 2>/dev/null || \
        iptables -t mangle -I POSTROUTING 1 -o "$iface" -s "$subnet" -p tcp --sport "$port" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_VALUE"
    elif [ "$action" = "del" ]; then
        # Удаляем правила
        iptables -t mangle -D PREROUTING -i "$iface" -p tcp --dport "$port" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_VALUE" 2>/dev/null || true
        iptables -t mangle -D POSTROUTING -o "$iface" -s "$subnet" -p tcp --sport "$port" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_VALUE" 2>/dev/null || true
    fi

    # Сохраняем правила, если установлен пакет
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

create_user_proxy() {
    local username="$1"
    local domain="${2:-$DEFAULT_DOMAIN}"
    local port="${3:-443}"

    echo -e "${BLUE}🔧 Создание прокси для пользователя: $username${NC}"

    local secret=$(generate_secret "$domain")

    # Находим свободный порт
    if [ "$port" = "443" ]; then
        if ss -tuln | grep -q ":443 "; then
            port=8443
            while ss -tuln | grep -q ":$port "; do
                ((port++))
            done
        fi
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
        local server_ip=$(curl -s api.ipify.org)
        local tg_link="tg://proxy?server=${server_ip}&port=${port}&secret=${secret}"
        local tme_link="https://t.me/proxy?server=${server_ip}&port=${port}&secret=${secret}"

        cat > "$CONFIG_DIR/${username}.conf" << EOF
USERNAME="$username"
SERVER_IP="$server_ip"
PORT="$port"
SECRET="$secret"
DOMAIN="$domain"
TG_LINK="$tg_link"
TME_LINK="$tme_link"
CREATED="$(date -Is)"
EOF

        # Добавляем в список
        sed -i "/^${username}:/d" "$USERS_FILE" 2>/dev/null || true
        echo "$username:$port:$domain" >> "$USERS_FILE"

        # АВТОМАТИЧЕСКИ ПРИМЕНЯЕМ ПРАВИЛА IPTABLES ДЛЯ НОВОГО ПОРТА
        manage_mss_rule "$port" "add"

        echo -e "${GREEN}✅ Прокси создан успешно!${NC}"
        echo -e "📊 Данные для подключения:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "👤 Пользователь: $username"
        echo "🌐 Сервер: $server_ip"
        echo "🔌 Порт: $port"
        echo "🔑 Секрет: $secret"
        echo "🌐 Домен: $domain"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "🔗 Ссылка: ${GREEN}${tme_link}${NC}\n"
    else
        echo -e "${RED}❌ Ошибка при создании прокси${NC}"
        return 1
    fi
}

delete_user_proxy() {
    local username="$1"
    local container_name="${CONTAINER_PREFIX}-${username}"

    # Получаем порт перед удалением конфига, чтобы очистить iptables
    if [ -f "$CONFIG_DIR/${username}.conf" ]; then
        source "$CONFIG_DIR/${username}.conf"
        manage_mss_rule "$PORT" "del"
    fi

    docker stop "$container_name" 2>/dev/null || true
    docker rm "$container_name" 2>/dev/null || true
    rm -f "$CONFIG_DIR/${username}.conf"

    sed -i "/^${username}:/d" "$USERS_FILE" 2>/dev/null || true

    echo -e "${GREEN}✅ Прокси пользователя $username удалён, правила фаервола очищены${NC}"
}

list_users() {
    echo -e "${BLUE}📋 Список активных прокси:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ ! -f "$USERS_FILE" ] || [ ! -s "$USERS_FILE" ]; then
        echo "Нет активных пользователей"
        return
    fi

    while IFS=':' read -r username port domain; do
        if [ -f "$CONFIG_DIR/${username}.conf" ]; then
            source "$CONFIG_DIR/${username}.conf"
            echo "👤 $username | 🔌 $PORT | 🌐 $DOMAIN"
            echo " 🔗 $TG_LINK"
            echo " 🔗 $TME_LINK"
        fi
    done < "$USERS_FILE"
}

export_config() {
    local export_file="mtproto_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    tar -C "$HOME" -czf "$export_file" ".mtproto"
    echo -e "${GREEN}✅ Конфигурация экспортирована в: $export_file${NC}"
}

import_config() {
    local import_file="$1"
    if [ ! -f "$import_file" ]; then
        echo -e "${RED}❌ Файл не найден: $import_file${NC}"
        return 1
    fi

    tar -xzf "$import_file" -C "$HOME"
    echo -e "${GREEN}✅ Конфигурация распакована${NC}"

    : > "$USERS_FILE"

    for conf in "$CONFIG_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        [ "$conf" = "$USERS_FILE" ] && continue

        source "$conf"
        echo "$USERNAME:$PORT:$DOMAIN" >> "$USERS_FILE"

        docker rm -f "${CONTAINER_PREFIX}-${USERNAME}" 2>/dev/null || true

        docker run -d --name "${CONTAINER_PREFIX}-${USERNAME}" --restart unless-stopped \
            -p "${PORT}:443" -e SECRET="${SECRET}" \
            telegrammessenger/proxy > /dev/null 2>&1

        # Восстанавливаем правила iptables для импортированного порта
        manage_mss_rule "$PORT" "add"

        echo -e "🚀 Прокси для ${GREEN}${USERNAME}${NC} запущен на порту ${YELLOW}${PORT}${NC}"
    done
}

# --- ПЕРВИЧНАЯ НАСТРОЙКА СЕРВЕРА ---
setup_server() {
    echo -e "${BLUE}[1/4] Установка пакетов...${NC}"
    apt-get update -y
    apt-get install -y docker.io iptables-persistent curl openssl xxd conntrack

    echo -e "${BLUE}[2/4] Настройка Docker (MTU=1400)...${NC}"
    systemctl enable --now docker
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'EOF'
{ "mtu": 1400 }
EOF
    systemctl restart docker

    echo -e "${BLUE}[3/4] Настройка ядра (BBR и tcp_mtu_probing)...${NC}"
    printf "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n" > /etc/sysctl.d/98-bbr.conf
    printf "net.ipv4.tcp_mtu_probing=1\n" > /etc/sysctl.d/99-mtproxy-mtu.conf
    sysctl --system >/dev/null || true

    echo -e "${BLUE}[4/4] Восстановление правил для существующих пользователей...${NC}"
    if [ -f "$USERS_FILE" ]; then
        while IFS=':' read -r username port domain; do
            manage_mss_rule "$port" "add"
        done < "$USERS_FILE"
    fi

    echo -e "${GREEN}✅ Базовая настройка сервера завершена!${NC}"
    echo "Теперь вы можете создавать пользователей командой: $0 create <имя>"
}

# --- ГЛАВНОЕ МЕНЮ ---
case "${1:-help}" in
    setup)
        setup_server
        ;;
    create)
        [ -z "${2:-}" ] && { echo "Укажите имя пользователя!"; exit 1; }
        create_user_proxy "$2" "${3:-$DEFAULT_DOMAIN}" "${4:-443}"
        ;;
    delete)
        [ -z "${2:-}" ] && { echo "Укажите имя пользователя!"; exit 1; }
        delete_user_proxy "$2"
        ;;
    list)
        list_users
        ;;
    export)
        export_config
        ;;
    import)
        [ -z "${2:-}" ] && { echo "Укажите файл бэкапа!"; exit 1; }
        import_config "$2"
        ;;
    *)
        echo -e "${YELLOW}Использование:${NC}"
        echo "  $0 setup                               - Первичная настройка сервера (Docker, BBR, MTU)"
        echo "  $0 create <username> [domain] [port]   - Создать прокси (правила iptables применятся сами)"
        echo "  $0 delete <username>                   - Удалить прокси (правила iptables удалятся сами)"
        echo "  $0 list                                - Список всех прокси"
        echo "  $0 export                              - Экспортировать конфиги"
        echo "  $0 import <file>                       - Импортировать конфиги"
        echo ""
        echo -e "${YELLOW}Пример рабочего процесса:${NC}"
        echo "  1. ./mtproto.sh setup"
        echo "  2. ./mtproto.sh create ivan ya.ru 443"
        echo "  3. ./mtproto.sh create maria max.ru 8443"
        ;;
esac

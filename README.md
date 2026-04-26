# MTProto Proxy Manager 🚀

Универсальный скрипт для управления MTProto-прокси на Linux.

## Основные возможности ✨

- Автоматическая установка и настройка Docker, `qrencode` и зависимостей
- Создание и удаление пользователей с генерацией ключей и QR-кодов
- Поддержка двух регионов (`GLOBAL` и `RU`) с предопределёнными списками доменов FakeTLS
- Автоматическая проверка доступности доменов и удаление недоступных из списков
- Резервирование занятых портов на сервере для предотвращения конфликтов
- Интерактивное меню и настройка с параметрами через аргументы
- Возможность запуска нескольких прокси на одном сервере
- Лёгкое управление контейнерами: запуск, остановка, перезапуск, обновление
- Поддержка сохранения конфигурации в отдельный файл

## Установка 🛠

Запустите в терминале:

```bash
curl -fsSL https://raw.githubusercontent.com/vdistortion/mtproto-manager/main/mtproto-manager.sh | sudo bash -s install
```

После установки скрипт предложит настроить регион и домен сервера.

## Быстрый старт ⚡

```bash
# Настройка региона и домена (интерактивно)
sudo mtproto-manager setup

# Настройка с параметрами (регион и домен сразу)
sudo mtproto-manager setup RU 1.2.3.4

# Создание первого пользователя
sudo mtproto-manager add-user myproxy

# Просмотр данных пользователя с QR-кодом
sudo mtproto-manager show-user myproxy
```

## Основные команды 📖

| Команда                                              | Описание                                     |
| ---------------------------------------------------- | -------------------------------------------- |
| `mtproto-manager install`                            | Переустановить скрипт и зависимости          |
| `mtproto-manager setup [REGION] [DOMAIN]`            | Настроить регион и домен сервера             |
| `mtproto-manager add-user <имя> [домен] [порт]`      | Создать нового пользователя                  |
| `mtproto-manager remove-user <имя>`                  | Удалить пользователя                         |
| `mtproto-manager list-users`                         | Показать список всех пользователей           |
| `mtproto-manager show-user <имя>`                    | Показать данные пользователя с QR-кодом      |
| `mtproto-manager block-user <имя>`                   | Заблокировать пользователя                   |
| `mtproto-manager unblock-user <имя>`                 | Разблокировать пользователя                  |
| `mtproto-manager restart-user <имя>`                 | Перезапустить прокси пользователя            |
| `mtproto-manager start`                              | Запустить все прокси                         |
| `mtproto-manager stop`                               | Остановить все прокси                        |
| `mtproto-manager restart`                            | Перезапустить все прокси                     |
| `mtproto-manager status`                             | Показать статус всех прокси                  |
| `mtproto-manager show-traffic`                       | Показать трафик контейнеров                  |
| `mtproto-manager update`                             | Обновить Docker-образ и перезапустить прокси |
| `mtproto-manager export`                             | Экспортировать конфигурацию пользователей    |
| `mtproto-manager import <файл>`                      | Импортировать конфигурацию пользователей     |
| `mtproto-manager list-domains`                       | Показать списки доменов FakeTLS              |
| `mtproto-manager check-domains`                      | Проверить доступность доменов                |
| `mtproto-manager add-domain <GLOBAL\|RU> <домен>`    | Добавить домен в список                      |
| `mtproto-manager remove-domain <GLOBAL\|RU> <домен>` | Удалить домен из списка                      |
| `mtproto-manager list-reserved-ports`                | Показать зарезервированные порты             |
| `mtproto-manager add-reserved-port <порт>`           | Добавить порт в резерв                       |
| `mtproto-manager remove-reserved-port <порт>`        | Удалить порт из резерва                      |
| `mtproto-manager help`                               | Показать полный список команд                |
| `mtproto-manager uninstall`                          | Полностью удалить скрипт и данные            |

## Выбор региона 🌎

**RU** — для пользователей из России. Маскирует трафик под подключение к российским сервисам (VK, Яндекс, Госуслуги и т.д.).

**GLOBAL** — для пользователей из других стран. Маскирует трафик под Google, Netflix, GitHub и т.д.

> Важно: регион выбирается исходя из местоположения пользователя, а не сервера. Если сервер в Германии, а пользователь подключается из России — выбирайте `RU`.

## Дополнительная настройка сервера 🔧

Скрипт устанавливает только базовые зависимости. Для максимальной производительности и стабильности рекомендуется применить следующие настройки вручную.

### 1. Docker MTU

Уменьшает размер MTU Docker-сети для предотвращения фрагментации пакетов. Особенно важно для VPS с туннелями или VPN.

```bash
sudo mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF'
{ "mtu": 1400 }
EOF
sudo systemctl restart docker
```

### 2. BBR + `tcp_mtu_probing`

Улучшает пропускную способность и автоматически подстраивает MTU при проблемах с фрагментацией.

```bash
cat > /etc/sysctl.d/98-bbr.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

cat > /etc/sysctl.d/99-mtproxy-mtu.conf << 'EOF'
net.ipv4.tcp_mtu_probing=1
EOF

sudo sysctl --system
```

Проверка:

```bash
sysctl net.ipv4.tcp_congestion_control
# Ожидаемый вывод: net.ipv4.tcp_congestion_control = bbr
```

### 3. `iptables` TCPMSS

Исправляет проблемы с установкой соединения на некоторых VPS. Применяется для каждого порта пользователя.

```bash
IFACE=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
DOCKER_SUBNET=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Subnet}}')
MSS=1100

while IFS=':' read -r username port secret domain; do
    [ -z "$port" ] && continue
    sudo iptables -t mangle -I PREROUTING 1 \
        -i "$IFACE" -p tcp --dport "$port" \
        --tcp-flags SYN,RST SYN \
        -j TCPMSS --set-mss "$MSS"
    sudo iptables -t mangle -I POSTROUTING 1 \
        -o "$IFACE" -s "$DOCKER_SUBNET" -p tcp --sport "$port" \
        --tcp-flags SYN,RST SYN \
        -j TCPMSS --set-mss "$MSS"
done < /etc/mtproto-manager/users.conf
```

### 4. Сохранение правил `iptables`

**Debian/Ubuntu:**

```bash
sudo apt-get install -y iptables-persistent
sudo netfilter-persistent save
```

**CentOS/RHEL:**

```bash
sudo yum install -y iptables-services
sudo systemctl enable --now iptables
sudo service iptables save
```

## Системные требования ⚡

- Linux (Ubuntu 20.04+, Debian 11+, CentOS 8+)
- Права `root` или `sudo`
- Минимум 512 MB RAM
- Минимум 1 ядро CPU

## Структура конфигурационных файлов 📁

| Файл                                       | Описание                                       |
| ------------------------------------------ | ---------------------------------------------- |
| `/etc/mtproto-manager/config.conf`         | Основные настройки (регион, домен, порты)      |
| `/etc/mtproto-manager/users.conf`          | Список пользователей (`имя:порт:секрет:домен`) |
| `/etc/mtproto-manager/domains_global.list` | Домены FakeTLS для региона `GLOBAL`            |
| `/etc/mtproto-manager/domains_ru.list`     | Домены FakeTLS для региона `RU`                |

## Лицензия 📄

MIT License — свободное использование и модификация.

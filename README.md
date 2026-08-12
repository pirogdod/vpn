# Selective VPN Routing for OpenWrt

Автоматическая настройка **точечной маршрутизации по доменам** на OpenWrt через `sing-box`.

Скрипт настраивает следующую схему:

```text
Клиенты LAN
    │
    ├── DNS → dnsmasq
    │           │
    │           ├── список доменов → nftset vpn_domains
    │           │
    │           └── https-dns-proxy → DoH/HTTPS:443
    │
    └── обычный IP-трафик
                │
                ├── IP не входит в vpn_domains → обычный WAN
                │
                └── IP входит в vpn_domains
                         ↓
                     fwmark 0x1
                         ↓
                     table vpn
                         ↓
                       tun0
                         ↓
                     sing-box
                         ↓
                   VLESS / WS / TLS
                         ↓
                     VPN-сервер
```

Основная идея: **через VPN идут только домены из заданного списка**, остальной интернет продолжает работать через обычное WAN-соединение.

---

## Что настраивает скрипт

`selective-vpn.sh` автоматически:

- устанавливает необходимые пакеты;
- заменяет стандартный `dnsmasq` на `dnsmasq-full`, если требуется;
- устанавливает и настраивает `sing-box`;
- создаёт TUN-интерфейс `tun0`;
- создаёт отдельную таблицу маршрутизации `vpn`;
- добавляет policy routing:
  - `fwmark 0x1`
  - `priority 100`
  - `lookup vpn`;
- создаёт nftables set `vpn_domains`;
- создаёт firewall-правило, маркирующее трафик к адресам из `vpn_domains`;
- создаёт firewall zone `singbox`;
- настраивает forwarding `lan → singbox`;
- скачивает список доменов проекта ITDog;
- добавляет дополнительные домены и IP-подсети;
- сохраняет последний успешно загруженный список доменов;
- устанавливает `https-dns-proxy`;
- переводит DNS OpenWrt на DNS-over-HTTPS;
- использует Cloudflare и Google как DoH upstream;
- использует Quad9 (`9.9.9.9`, `9.9.9.10`) как bootstrap DNS;
- включает необходимые сервисы в автозапуск;
- предоставляет встроенную проверку состояния конфигурации.

---

# Требования

Ориентировано на:

- OpenWrt 23.05+
- firewall4 / nftables
- IPv4 selective routing
- `sing-box`
- VLESS
- WebSocket
- TLS

Исходная рабочая конфигурация была протестирована на:

```text
OpenWrt 23.05.0
ARM Cortex-A9
fw4 / nftables
dnsmasq-full
sing-box
https-dns-proxy
```

Скрипт не привязан к конкретной ARM-архитектуре: пакеты устанавливаются через `opkg` из репозитория текущего OpenWrt.

---

# Файлы

Рекомендуемая структура:

```text
selective-vpn/
├── selective-vpn.sh
└── README.md
```

После запуска скрипт создаёт:

```text
/etc/selective-vpn.conf
/etc/selective-vpn/
/etc/sing-box/config.json
/usr/libexec/selective-vpn-refresh
/etc/init.d/getdomains
/etc/init.d/selective-vpn-route
/etc/hotplug.d/net/30-vpnroute
```

---

# Установка

Скопировать скрипт на OpenWrt, например в `/root`:

```sh
cd /root
chmod +x selective-vpn.sh
```

Создать конфигурационный файл:

```sh
./selective-vpn.sh init-config
```

Будет создан:

```text
/etc/selective-vpn.conf
```

Файл создаётся с правами `600`, так как содержит секретные параметры VLESS.

---

# Настройка VLESS

Открыть:

```sh
vi /etc/selective-vpn.conf
```

Минимально необходимо заполнить:

```sh
VLESS_SERVER=""
VLESS_PORT="443"
VLESS_UUID=""
VLESS_SNI=""
VLESS_WS_PATH="/ws"
VLESS_WS_HOST=""
```

Пример структуры:

```sh
VLESS_SERVER="vpn.example.com"
VLESS_PORT="443"
VLESS_UUID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
VLESS_SNI="vpn.example.com"
VLESS_WS_PATH="/ws"
VLESS_WS_HOST="vpn.example.com"
```

## VLESS_INSECURE

```sh
VLESS_INSECURE="0"
```

Рекомендуемое значение — `0`, если TLS-сертификат сервера корректный.

Если сервер используется по IP или сертификат не может быть нормально проверен:

```sh
VLESS_INSECURE="1"
```

Это отключает проверку сертификата и снижает безопасность TLS.

---

# Установка конфигурации

После заполнения `/etc/selective-vpn.conf`:

```sh
./selective-vpn.sh install
```

Скрипт:

1. сохранит резервные копии существующих настроек;
2. установит необходимые пакеты;
3. настроит `sing-box`;
4. настроит policy routing;
5. настроит firewall;
6. настроит nftset;
7. настроит DNS-over-HTTPS;
8. настроит загрузку списка доменов;
9. включит автозапуск;
10. выполнит встроенную проверку.

---

# Резервные копии

Перед изменением конфигурации создаётся backup в:

```text
/etc/selective-vpn/backups/
```

Пример:

```text
/etc/selective-vpn/backups/20260812-150000/
```

Туда сохраняются существующие файлы `network`, `firewall`, `dhcp`, sing-box и другие затрагиваемые настройки.

---

# Проверка состояния

Основная диагностическая команда:

```sh
./selective-vpn.sh check
```

Пример нормального результата:

```text
[ OK ] dnsmasq-full installed
[ OK ] https-dns-proxy installed
[ OK ] sing-box installed
[ OK ] dnsmasq running
[ OK ] https-dns-proxy running
[ OK ] sing-box running
[ OK ] tun0 exists
[ OK ] fwmark 0x1 -> table vpn
[ OK ] table vpn default -> tun0
[ OK ] nft set vpn_domains exists
[ OK ] nft mark rule active
[ OK ] DNS through local dnsmasq works
[ OK ] dnsmasq uses local DoH proxy
[ OK ] domain list loaded
```

После установки рекомендуется всегда выполнить:

```sh
./selective-vpn.sh check
```

---

# Команды

## Создать шаблон конфигурации

```sh
./selective-vpn.sh init-config
```

---

## Установить / применить конфигурацию

```sh
./selective-vpn.sh install
```

Повторный запуск предусмотрен: скрипт старается не создавать дублирующиеся UCI-объекты.

---

## Проверить состояние

```sh
./selective-vpn.sh check
```

---

## Обновить список доменов

```sh
./selective-vpn.sh refresh-domains
```

Список загружается из:

```text
https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst
```

URL можно изменить в:

```text
/etc/selective-vpn.conf
```

---

## Перезапустить компоненты

```sh
./selective-vpn.sh restart
```

После перезапуска автоматически выполняется `check`.

---

## Удалить selective routing

```sh
./selective-vpn.sh uninstall
```

Удаляются:

- policy routing;
- firewall-правила selective VPN;
- nftset `vpn_domains`;
- `tun0` из UCI;
- startup/helper-скрипты selective routing.

Намеренно **не удаляются**:

- установленные пакеты;
- `https-dns-proxy`;
- `/etc/selective-vpn.conf`;
- `/etc/sing-box/config.json`.

Это сделано для возможности ручного восстановления или повторной установки.

---

# Таблица маршрутизации

По умолчанию используется:

```text
99 vpn
```

Запись создаётся в:

```text
/etc/iproute2/rt_tables
```

Policy rule:

```text
fwmark 0x1 → table vpn
```

Приоритет:

```text
100
```

Маршрут:

```text
default dev tun0
```

Проверка:

```sh
ip rule show
```

Ожидается:

```text
100: from all fwmark 0x1 lookup vpn
```

Проверка таблицы:

```sh
ip route show table vpn
```

Ожидается:

```text
default dev tun0 scope link
```

---

# nftables

Создаётся set:

```text
vpn_domains
```

Проверить:

```sh
nft list set inet fw4 vpn_domains
```

Firewall маркирует IPv4-трафик LAN к адресам из этого set:

```text
destination ∈ vpn_domains
        ↓
meta mark = 0x1
```

Проверить правило:

```sh
nft list chain inet fw4 mangle_prerouting
```

---

# Как домены попадают в vpn_domains

Используется функциональность `dnsmasq-full` `nftset`.

В загруженном файле содержатся правила вида:

```text
nftset=/youtube.com/4#inet#fw4#vpn_domains
nftset=/facebook.com/4#inet#fw4#vpn_domains
```

Когда клиент делает DNS-запрос через `dnsmasq`, полученный IPv4 автоматически добавляется в:

```text
inet fw4 vpn_domains
```

После этого трафик к этому IP получает `fwmark 0x1` и попадает в `tun0`.

---

# Последний рабочий список доменов

Свежий список сохраняется в:

```text
/etc/selective-vpn/domains.lst
```

Runtime-копия:

```text
/tmp/dnsmasq.d/90-selective-vpn-domains.conf
```

Это сделано специально для загрузки роутера.

Если GitHub временно недоступен после reboot, используется последняя успешно скачанная версия списка, а обновление выполняется позже.

Повреждённый или синтаксически неверный новый файл не заменяет последний рабочий.

---

# Дополнительные домены

В `/etc/selective-vpn.conf` есть:

```sh
EXTRA_DOMAINS="
...
"
```

Можно добавить собственные домены, например:

```sh
EXTRA_DOMAINS="
example.com
example.org
my-service.net
"
```

После изменения выполнить:

```sh
./selective-vpn.sh install
```

или при необходимости вручную обновить конфигурацию.

---

# Дополнительные IP-подсети

В конфигурации присутствует:

```sh
VPN_IPS="
...
"
```

Эти сети добавляются напрямую в `vpn_domains`, независимо от DNS.

Пример:

```sh
VPN_IPS="
91.108.56.0/22
149.154.160.0/20
"
```

Это удобно для сервисов с известными IP-префиксами.

---

# DNS-over-HTTPS

Скрипт устанавливает:

```text
https-dns-proxy
```

По умолчанию используются два DoH resolver:

```text
Cloudflare
https://cloudflare-dns.com/dns-query

Google
https://dns.google/dns-query
```

Локально они слушают примерно:

```text
127.0.0.1:5053
127.0.0.1:5054
```

`dnsmasq` отправляет запросы в локальные DoH-прокси.

Снаружи DNS идёт как обычный HTTPS:

```text
TCP/443
```

а не как открытый:

```text
UDP/TCP 53
```

Это важно в сетях, где провайдер перехватывает или фильтрует обычные DNS-запросы.

---

# Bootstrap DNS

Чтобы `https-dns-proxy` мог первоначально определить IP DoH-сервера, используется:

```text
9.9.9.9
9.9.9.10
```

Настройка:

```sh
DOH_BOOTSTRAP="9.9.9.9,9.9.9.10"
```

Bootstrap используется только для первоначального разрешения имени DoH endpoint. Основные DNS-запросы идут через HTTPS.

---

# DNS клиентов LAN

Рекомендуемая схема:

```text
Клиент → OpenWrt/dnsmasq → https-dns-proxy → DoH
```

Клиентам желательно выдавать **только адрес самого OpenWrt как DNS**.

Не рекомендуется выдавать клиенту одновременно:

```text
OpenWrt + внешний DNS
```

Например:

```text
192.168.1.1 + 8.8.8.8
```

иначе часть запросов может обходить dnsmasq.

Это важно не только для DoH, но и для selective routing: если DNS-запрос обошёл `dnsmasq`, соответствующий IP может не попасть в `vpn_domains`.

Проверить DHCP option 6:

```sh
uci show dhcp.lan.dhcp_option
```

---

# Secure DNS / DoH в браузерах

Если браузер самостоятельно использует внешний DoH, DNS-запрос может обходить OpenWrt `dnsmasq`.

При такой схеме точечная маршрутизация по DNS-IP может работать непредсказуемо.

`https-dns-proxy` включает механизмы принудительного DNS для обычных DNS/DoT-запросов, однако произвольный DoH на TCP/443 невозможно прозрачно отличить от другого HTTPS-трафика только по порту.

Поэтому при диагностике полезно проверить настройки:

```text
Chrome / Edge:
Settings
→ Privacy and security
→ Security
→ Use secure DNS
```

---

# sing-box

Скрипт генерирует:

```text
/etc/sing-box/config.json
```

Используется:

```text
TUN
→ VLESS
→ WebSocket
→ TLS
```

Пример логической структуры:

```text
tun0
  ↓
vless-ws-out
  ↓
VLESS_SERVER:443
```

---

# Совместимость версий sing-box

Рабочая исходная конфигурация использовала sing-box `1.9.x`.

В более новых версиях изменился формат адреса TUN inbound.

Старый вариант:

```json
"inet4_address": "172.16.250.1/30"
```

Новый вариант:

```json
"address": [
  "172.16.250.1/30"
]
```

Скрипт определяет установленную версию sing-box и генерирует подходящий вариант автоматически.

Перед запуском конфигурация проверяется:

```sh
sing-box check -c /etc/sing-box/config.json
```

Если проверка завершается ошибкой, установка останавливается.

---

# Проверка DNS

Через dnsmasq:

```sh
nslookup www.facebook.com 127.0.0.1
```

Нормальный результат должен содержать IP.

Например:

```text
Name:    star-mini.c10r.facebook.com
Address: 31.13.x.x
```

---

# Проверка DoH

Убедиться, что обычный DNS не выходит через WAN:

```sh
tcpdump -ni pppoe-wan 'port 53'
```

При открытии сайтов вывод в нормальной конфигурации должен быть пустым.

DoH можно увидеть как HTTPS:

```sh
tcpdump -ni pppoe-wan 'host 8.8.8.8 and port 443'
```

или аналогичным фильтром для используемого resolver.

---

# Проверка конкретного IP

Проверить наличие адреса в selective set:

```sh
nft get element inet fw4 vpn_domains '{ 57.145.4.1 }'
```

Если адрес присутствует, он должен маршрутизироваться через `tun0`.

---

# Проверка TUN

```sh
ip addr show tun0
```

Проверить передачу трафика:

```sh
tcpdump -ni tun0
```

---

# Логи sing-box

```sh
logread -e sing-box
```

В рабочем случае можно увидеть:

```text
inbound/tun: inbound connection to X.X.X.X:443
outbound/vless: outbound connection to X.X.X.X:443
```

---

# Типовые проблемы

## DNS_PROBE_FINISHED_NXDOMAIN

Сначала проверить:

```sh
nslookup problematic.example 127.0.0.1
```

Если OpenWrt также возвращает `NXDOMAIN`, проблема находится до маршрутизации VPN — на уровне DNS.

Проверить DoH:

```sh
/etc/init.d/https-dns-proxy status
```

и:

```sh
logread -e https-dns-proxy
```

---

## Сайт резолвится, но не открывается

Проверить IP:

```sh
nslookup example.com 127.0.0.1
```

Затем:

```sh
nft get element inet fw4 vpn_domains '{ IP }'
```

Проверить `tun0`:

```sh
tcpdump -ni tun0 host IP
```

И логи:

```sh
logread | grep 'IP'
```

---

## После перезагрузки нет маршрута vpn

Проверить:

```sh
ip route show table vpn
```

Если отсутствует:

```text
default dev tun0
```

запустить:

```sh
./selective-vpn.sh restart
```

Скрипт использует `ip route replace`, поэтому повторное добавление маршрута безопасно.

---

## Нет vpn_domains

Проверить:

```sh
nft list set inet fw4 vpn_domains
```

Если set отсутствует:

```sh
/etc/init.d/firewall restart
```

а затем:

```sh
./selective-vpn.sh refresh-domains
```

---

## Список доменов не скачивается

Проверить:

```sh
logread -e getdomains
```

Система продолжит использовать последний рабочий файл:

```text
/etc/selective-vpn/domains.lst
```

---

# Безопасность

`/etc/selective-vpn.conf` содержит:

- адрес VPN-сервера;
- UUID VLESS;
- TLS/SNI параметры.

Права файла:

```text
600
```

Не публикуйте этот файл в GitHub.

Также не следует публиковать:

```text
/etc/sing-box/config.json
```

если в нём находится реальный UUID.

Рекомендуемый `.gitignore`:

```gitignore
selective-vpn.conf
config.json
*.backup
*.bak
```

---

# Что НЕ делает скрипт

Скрипт не:

- создаёт VLESS-сервер;
- настраивает VPS;
- выпускает TLS-сертификаты;
- автоматически определяет UUID;
- настраивает IPv6 selective routing;
- гарантирует работу с сильно изменёнными downstream-сборками OpenWrt;
- управляет WireGuard;
- переносит WAN/PPPoE настройки между роутерами.

Он занимается только клиентской частью selective routing на OpenWrt.

---

# Рекомендуемый порядок установки на новом роутере

```sh
# 1. Скопировать скрипт
chmod +x selective-vpn.sh

# 2. Создать конфиг
./selective-vpn.sh init-config

# 3. Заполнить параметры VLESS
vi /etc/selective-vpn.conf

# 4. Установить
./selective-vpn.sh install

# 5. Проверить
./selective-vpn.sh check
```

После этого проверить несколько обычных сайтов и несколько сайтов из VPN-списка.

---

# Быстрый health-check

В дальнейшем основная команда обслуживания:

```sh
./selective-vpn.sh check
```

Если всё работает, никаких ручных действий обычно не требуется.

Для обновления списка:

```sh
./selective-vpn.sh refresh-domains
```

Для полного перезапуска selective VPN:

```sh
./selective-vpn.sh restart
```

---

# Источник доменного списка

По умолчанию используется проект ITDog:

```text
https://github.com/itdoginfo/allow-domains
```

и список:

```text
Russia/inside-dnsmasq-nfset.lst
```

Проект скрипта не является частью ITDog и использует этот список как внешний источник данных.

---

# Примечание

Перед использованием на основном маршрутизаторе желательно иметь:

- резервную копию OpenWrt;
- доступ к роутеру по Ethernet;
- возможность восстановить `/etc/config/network`, `/etc/config/firewall` и `/etc/config/dhcp`.

Скрипт сам создаёт backup перед изменениями, но полноценный системный backup OpenWrt всё равно рекомендуется.

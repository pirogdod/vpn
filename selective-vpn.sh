#!/bin/sh
#
# selective-vpn.sh
# OpenWrt selective domain routing through sing-box TUN + nftset + DoH
#
# Commands:
#   ./selective-vpn.sh init-config
#   vi /etc/selective-vpn.conf
#   ./selective-vpn.sh install
#   ./selective-vpn.sh check
#   ./selective-vpn.sh refresh-domains
#   ./selective-vpn.sh restart
#   ./selective-vpn.sh uninstall
#
# Designed for OpenWrt 23.05+ / fw4 (nftables).
#

set -u

CONF="/etc/selective-vpn.conf"
STATE_DIR="/etc/selective-vpn"
TMP_DNS_DIR="/tmp/dnsmasq.d"
TMP_DOMAINS="${TMP_DNS_DIR}/90-selective-vpn-domains.conf"
PERSIST_DOMAINS="${STATE_DIR}/domains.lst"
DOMAINS_URL_DEFAULT="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst"

log() { echo "[selective-vpn] $*"; }
ok()  { echo "[ OK ] $*"; }
bad() { echo "[FAIL] $*"; }
warn(){ echo "[WARN] $*"; }

need_root() {
    [ "$(id -u)" = "0" ] || {
        echo "Run as root."
        exit 1
    }
}

create_config() {
    need_root
    if [ -e "$CONF" ]; then
        log "$CONF already exists; not overwriting."
        return 0
    fi

    cat > "$CONF" <<'EOF'
# ==== VLESS / sing-box ====
# Fill these values before "install".
VLESS_SERVER=""
VLESS_PORT="443"
VLESS_UUID=""
VLESS_SNI=""
VLESS_WS_PATH="/ws"
VLESS_WS_HOST=""

# 1 = skip TLS certificate verification, 0 = verify normally.
# Current working router used 1 because the server was addressed by IP.
VLESS_INSECURE="1"

# uTLS fingerprint. Leave "chrome" unless your server requires another value.
VLESS_UTLS_FINGERPRINT="chrome"

# ==== Router-side selective routing ====
LAN_ZONE="lan"
TUN_IF="tun0"
TUN_ADDRESS="172.16.250.1/30"
TUN_UCI_IP="172.16.250.1"
TUN_UCI_NETMASK="255.255.255.0"

ROUTE_TABLE_ID="99"
ROUTE_TABLE_NAME="vpn"
FWMARK="0x1"
RULE_PRIORITY="100"

# ITDog domain list.
DOMAINS_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst"

# DoH bootstrap. These are only used to resolve the DoH server name initially.
DOH_BOOTSTRAP="9.9.9.9,9.9.9.10"

# Static networks added to vpn_domains in addition to DNS-derived IPs.
# Taken from the working router.
VPN_IPS="
91.108.56.0/22
91.108.4.0/22
91.108.8.0/22
91.108.16.0/22
91.108.12.0/22
149.154.160.0/20
91.105.192.0/23
91.108.20.0/22
185.76.151.0/24
"

# Extra domains that are always added to the same nftset via dnsmasq UCI.
# Space-separated. Edit freely.
EXTRA_DOMAINS="
asgardeo.io
choreo.dev
qnap.com
myqnapcloud.com
qmiix.com
wso2.com
thinkific.com
amazonaws.com
hashcat.net
cdn-telegram.org
telegram-cdn.org
comments.app
contest.com
fragment.com
graph.org
quiz.directory
t.me
tdesktop.com
telega.one
telegra.ph
telegram.dog
telegram.me
telegram.org
telegram.space
telesco.pe
tg.dev
tx.me
usercontent.dev
ton.org
"
EOF

    chmod 600 "$CONF"
    log "Created $CONF"
    log "Fill VLESS_SERVER / VLESS_UUID / VLESS_SNI / VLESS_WS_HOST, then run:"
    log "  $0 install"
}

load_config() {
    [ -r "$CONF" ] || {
        bad "$CONF not found."
        echo "Run: $0 init-config"
        exit 1
    }
    # shellcheck disable=SC1090
    . "$CONF"
    DOMAINS_URL="${DOMAINS_URL:-$DOMAINS_URL_DEFAULT}"
}

validate_config() {
    [ -n "${VLESS_SERVER:-}" ] || { bad "VLESS_SERVER is empty in $CONF"; return 1; }
    [ -n "${VLESS_UUID:-}" ] || { bad "VLESS_UUID is empty in $CONF"; return 1; }

    [ -n "${VLESS_SNI:-}" ] || VLESS_SNI="$VLESS_SERVER"
    [ -n "${VLESS_WS_HOST:-}" ] || VLESS_WS_HOST="$VLESS_SNI"

    case "${VLESS_INSECURE:-0}" in
        0|1) ;;
        *) bad "VLESS_INSECURE must be 0 or 1"; return 1 ;;
    esac

    return 0
}

backup_configs() {
    mkdir -p "$STATE_DIR/backups"
    TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
    BAK="$STATE_DIR/backups/$TS"
    mkdir -p "$BAK"

    for f in \
        /etc/config/network \
        /etc/config/firewall \
        /etc/config/dhcp \
        /etc/config/https-dns-proxy \
        /etc/config/sing-box \
        /etc/sing-box/config.json \
        /etc/iproute2/rt_tables \
        /etc/init.d/getdomains \
        /etc/hotplug.d/iface/30-vpnroute \
        /etc/hotplug.d/net/30-vpnroute
    do
        [ -e "$f" ] || continue
        d="$BAK$(dirname "$f")"
        mkdir -p "$d"
        cp -p "$f" "$d/"
    done

    log "Backup: $BAK"
}

pkg_installed() {
    opkg list-installed 2>/dev/null | grep -q "^$1 "
}

install_packages() {
    log "Updating package lists..."
    opkg update || {
        bad "opkg update failed"
        return 1
    }

    # dnsmasq-full is needed for nftset support.
    if ! pkg_installed dnsmasq-full; then
        log "Installing dnsmasq-full (replaces stock dnsmasq)..."
        cp -p /etc/config/dhcp "$STATE_DIR/dhcp.before-dnsmasq-full" 2>/dev/null || true
        if pkg_installed dnsmasq; then
            opkg remove dnsmasq || {
                bad "Could not remove stock dnsmasq"
                return 1
            }
        fi
        opkg install dnsmasq-full || {
            bad "Could not install dnsmasq-full"
            return 1
        }
    fi

    for p in curl ca-bundle kmod-tun https-dns-proxy sing-box; do
        if ! pkg_installed "$p"; then
            log "Installing $p..."
            opkg install "$p" || {
                bad "Could not install $p"
                return 1
            }
        fi
    done

    return 0
}

version_ge_1_10() {
    # sing-box version output examples differ slightly by package.
    VER="$(sing-box version 2>/dev/null | head -n1 | sed -n 's/.*version[[:space:]]\+\([0-9][0-9.]*\).*/\1/p')"
    [ -n "$VER" ] || VER="$(sing-box version 2>/dev/null | head -n1 | grep -o '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' | head -n1)"
    MINOR="$(echo "$VER" | cut -d. -f2)"
    [ -n "$MINOR" ] || MINOR=0
    [ "$MINOR" -ge 10 ]
}

json_bool() {
    [ "$1" = "1" ] && echo true || echo false
}

write_singbox_config() {
    mkdir -p /etc/sing-box /usr/share/sing-box

    INSECURE="$(json_bool "$VLESS_INSECURE")"

    if version_ge_1_10; then
        TUN_ADDR_JSON="\"address\": [\"$TUN_ADDRESS\"],"
    else
        TUN_ADDR_JSON="\"inet4_address\": \"$TUN_ADDRESS\","
    fi

    cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "tun",
      "interface_name": "$TUN_IF",
      $TUN_ADDR_JSON
      "mtu": 1500,
      "auto_route": false,
      "strict_route": false,
      "sniff": true
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-ws-out",
      "server": "$VLESS_SERVER",
      "server_port": $VLESS_PORT,
      "uuid": "$VLESS_UUID",
      "tls": {
        "enabled": true,
        "server_name": "$VLESS_SNI",
        "insecure": $INSECURE,
        "utls": {
          "enabled": true,
          "fingerprint": "$VLESS_UTLS_FINGERPRINT"
        }
      },
      "transport": {
        "type": "ws",
        "path": "$VLESS_WS_PATH",
        "headers": {
          "Host": "$VLESS_WS_HOST"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "vless-ws-out"
  }
}
EOF
    chmod 600 /etc/sing-box/config.json

    # UCI config used by the OpenWrt sing-box init script.
    uci -q delete sing-box.main
    uci set sing-box.main='sing-box'
    uci set sing-box.main.enabled='1'
    uci set sing-box.main.user='root'
    uci set sing-box.main.conffile='/etc/sing-box/config.json'
    uci set sing-box.main.workdir='/usr/share/sing-box'
    uci commit sing-box

    if ! sing-box check -c /etc/sing-box/config.json >/tmp/sing-box-check.log 2>&1; then
        bad "sing-box config validation failed:"
        cat /tmp/sing-box-check.log
        return 1
    fi

    ok "sing-box config validated"
    return 0
}

configure_route_table() {
    mkdir -p /etc/iproute2
    touch /etc/iproute2/rt_tables

    # Remove any old mapping of our name/id, then add exactly one line.
    sed -i \
        -e "/^[[:space:]]*$ROUTE_TABLE_ID[[:space:]]\+$ROUTE_TABLE_NAME[[:space:]]*$/d" \
        -e "/^[[:space:]]*[0-9][0-9]*[[:space:]]\+$ROUTE_TABLE_NAME[[:space:]]*$/d" \
        /etc/iproute2/rt_tables
    echo "$ROUTE_TABLE_ID $ROUTE_TABLE_NAME" >> /etc/iproute2/rt_tables

    # Named UCI section: idempotent.
    uci -q delete network.selective_vpn_mark
    uci set network.selective_vpn_mark='rule'
    uci set network.selective_vpn_mark.name='mark0x1'
    uci set network.selective_vpn_mark.mark="$FWMARK"
    uci set network.selective_vpn_mark.priority="$RULE_PRIORITY"
    uci set network.selective_vpn_mark.lookup="$ROUTE_TABLE_NAME"

    # Keep the same OpenWrt-side tun0 setup as the known-good router.
    uci -q delete network.tun0
    uci set network.tun0='interface'
    uci set network.tun0.device="$TUN_IF"
    uci set network.tun0.proto='static'
    uci set network.tun0.ipaddr="$TUN_UCI_IP"
    uci set network.tun0.netmask="$TUN_UCI_NETMASK"

    uci commit network
}

configure_firewall() {
    # Named sections avoid dependence on @zone[2], @rule[9], etc.
    uci -q delete firewall.singbox
    uci set firewall.singbox='zone'
    uci set firewall.singbox.name='singbox'
    uci set firewall.singbox.device="$TUN_IF"
    uci set firewall.singbox.forward='ACCEPT'
    uci set firewall.singbox.output='ACCEPT'
    uci set firewall.singbox.input='ACCEPT'
    uci set firewall.singbox.masq='1'
    uci set firewall.singbox.mtu_fix='1'
    uci set firewall.singbox.family='ipv4'

    uci -q delete firewall.singbox_lan
    uci set firewall.singbox_lan='forwarding'
    uci set firewall.singbox_lan.name='singbox-lan'
    uci set firewall.singbox_lan.src="$LAN_ZONE"
    uci set firewall.singbox_lan.dest='singbox'
    uci set firewall.singbox_lan.family='ipv4'

    uci -q delete firewall.vpn_domains
    uci set firewall.vpn_domains='ipset'
    uci set firewall.vpn_domains.name='vpn_domains'
    uci set firewall.vpn_domains.match='dst_net'

    uci -q delete firewall.mark_domains
    uci set firewall.mark_domains='rule'
    uci set firewall.mark_domains.name='mark_domains'
    uci set firewall.mark_domains.src="$LAN_ZONE"
    uci set firewall.mark_domains.dest='*'
    uci set firewall.mark_domains.proto='all'
    uci set firewall.mark_domains.ipset='vpn_domains'
    uci set firewall.mark_domains.set_mark="$FWMARK"
    uci set firewall.mark_domains.target='MARK'
    uci set firewall.mark_domains.family='ipv4'

    uci commit firewall
}

configure_extra_domains() {
    uci -q delete dhcp.selective_vpn_domains
    uci set dhcp.selective_vpn_domains='ipset'
    uci set dhcp.selective_vpn_domains.name='vpn_domains'

    for d in $EXTRA_DOMAINS; do
        [ -n "$d" ] && uci add_list dhcp.selective_vpn_domains.domain="$d"
    done

    uci commit dhcp
}

configure_doh() {
    # https-dns-proxy package normally injects its local listeners into dnsmasq.
    # We only replace bootstrap DNS for every configured DoH instance.
    SECTIONS="$(uci show https-dns-proxy 2>/dev/null \
        | sed -n 's/^https-dns-proxy\.\(@https-dns-proxy\[[0-9][0-9]*\]\)=https-dns-proxy$/\1/p')"

    for s in $SECTIONS; do
        uci set "https-dns-proxy.$s.bootstrap_dns=$DOH_BOOTSTRAP"
    done

    uci set https-dns-proxy.config.force_dns='1'
    uci commit https-dns-proxy
}

write_route_helpers() {
    # Remove legacy duplicate helpers if they exist.
    rm -f /etc/hotplug.d/iface/30-vpnroute

    mkdir -p /etc/hotplug.d/net
    cat > /etc/hotplug.d/net/30-vpnroute <<EOF
#!/bin/sh
ip link show "$TUN_IF" >/dev/null 2>&1 || exit 0
ip route replace table "$ROUTE_TABLE_NAME" default dev "$TUN_IF" 2>/dev/null
EOF
    chmod 755 /etc/hotplug.d/net/30-vpnroute

    cat > /etc/init.d/selective-vpn-route <<EOF
#!/bin/sh /etc/rc.common
START=99

start() {
    (
        n=0
        while [ "\$n" -lt 60 ]; do
            if ip link show "$TUN_IF" >/dev/null 2>&1; then
                ip route replace table "$ROUTE_TABLE_NAME" default dev "$TUN_IF" 2>/dev/null
                exit 0
            fi
            n=\$((n+1))
            sleep 2
        done
        logger -t selective-vpn-route "tun interface $TUN_IF did not appear"
    ) &
}
EOF
    chmod 755 /etc/init.d/selective-vpn-route
    /etc/init.d/selective-vpn-route enable
}

write_domain_refresh() {
    mkdir -p "$STATE_DIR" "$TMP_DNS_DIR" /usr/libexec

    cat > /usr/libexec/selective-vpn-refresh <<'EOF'
#!/bin/sh

CONF="/etc/selective-vpn.conf"
STATE_DIR="/etc/selective-vpn"
TMP_DNS_DIR="/tmp/dnsmasq.d"
TMP_DOMAINS="${TMP_DNS_DIR}/90-selective-vpn-domains.conf"
PERSIST_DOMAINS="${STATE_DIR}/domains.lst"

[ -r "$CONF" ] || exit 1
. "$CONF"

mkdir -p "$STATE_DIR" "$TMP_DNS_DIR"

# Load last-known-good list immediately after boot, before GitHub is reachable.
if [ -s "$PERSIST_DOMAINS" ] && [ ! -s "$TMP_DOMAINS" ]; then
    cp "$PERSIST_DOMAINS" "$TMP_DOMAINS"
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
fi

# Wait for DNS + firewall nft set. Do not block forever.
n=0
while [ "$n" -lt 30 ]; do
    if nslookup raw.githubusercontent.com 127.0.0.1 >/dev/null 2>&1 \
       && nft list set inet fw4 vpn_domains >/dev/null 2>&1; then
        break
    fi
    n=$((n+1))
    sleep 5
done

NEW="/tmp/selective-vpn-domains.new"
rm -f "$NEW"

if curl -fsSL \
    --connect-timeout 5 \
    --max-time 30 \
    --retry 3 \
    "$DOMAINS_URL" \
    -o "$NEW"
then
    if dnsmasq --conf-file="$NEW" --test 2>&1 | grep -q "syntax check OK"; then
        cp "$NEW" "$PERSIST_DOMAINS"
        cp "$NEW" "$TMP_DOMAINS"
        logger -t getdomains "Downloaded and validated fresh domain list"
        /etc/init.d/dnsmasq restart >/dev/null 2>&1
    else
        logger -t getdomains "Downloaded domain list failed dnsmasq validation; keeping last-good copy"
    fi
else
    logger -t getdomains "Could not download domain list; keeping last-good copy"
fi
rm -f "$NEW"

# Firewall restart may recreate the set, so wait for it.
n=0
while [ "$n" -lt 30 ]; do
    nft list set inet fw4 vpn_domains >/dev/null 2>&1 && break
    n=$((n+1))
    sleep 2
done

for ip in $VPN_IPS; do
    nft add element inet fw4 vpn_domains "{ $ip }" 2>/dev/null
done
EOF
    chmod 755 /usr/libexec/selective-vpn-refresh

    cat > /etc/init.d/getdomains <<'EOF'
#!/bin/sh /etc/rc.common
START=99

start() {
    /usr/libexec/selective-vpn-refresh >/dev/null 2>&1 &
}
EOF
    chmod 755 /etc/init.d/getdomains
    /etc/init.d/getdomains enable
}

restart_all() {
    log "Restarting firewall..."
    /etc/init.d/firewall restart || return 1

    log "Restarting https-dns-proxy..."
    /etc/init.d/https-dns-proxy restart || return 1

    log "Restarting dnsmasq..."
    /etc/init.d/dnsmasq restart || return 1

    log "Restarting sing-box..."
    /etc/init.d/sing-box enable
    /etc/init.d/sing-box restart || return 1

    /etc/init.d/selective-vpn-route start
    /usr/libexec/selective-vpn-refresh >/dev/null 2>&1 &

    return 0
}

install_all() {
    need_root
    load_config
    validate_config || exit 1

    mkdir -p "$STATE_DIR"
    backup_configs

    install_packages || exit 1
    write_singbox_config || exit 1
    configure_route_table
    configure_firewall
    configure_extra_domains
    configure_doh
    write_route_helpers
    write_domain_refresh

    restart_all || {
        bad "A service restart failed. Run: $0 check"
        exit 1
    }

    log "Installation finished."
    log "Domain refresh continues in background."
    echo
    "$0" check
}

check_one() {
    desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        ok "$desc"
        return 0
    else
        bad "$desc"
        return 1
    fi
}

check_all() {
    need_root
    load_config

    FAIL=0

    check_one "dnsmasq-full installed" pkg_installed dnsmasq-full || FAIL=$((FAIL+1))
    check_one "https-dns-proxy installed" pkg_installed https-dns-proxy || FAIL=$((FAIL+1))
    check_one "sing-box installed" pkg_installed sing-box || FAIL=$((FAIL+1))

    /etc/init.d/dnsmasq status >/dev/null 2>&1 && ok "dnsmasq running" || { bad "dnsmasq not running"; FAIL=$((FAIL+1)); }
    /etc/init.d/https-dns-proxy status >/dev/null 2>&1 && ok "https-dns-proxy running" || { bad "https-dns-proxy not running"; FAIL=$((FAIL+1)); }
    /etc/init.d/sing-box status >/dev/null 2>&1 && ok "sing-box running" || { bad "sing-box not running"; FAIL=$((FAIL+1)); }

    ip link show "$TUN_IF" >/dev/null 2>&1 \
        && ok "$TUN_IF exists" \
        || { bad "$TUN_IF missing"; FAIL=$((FAIL+1)); }

    ip rule show | grep -q "fwmark 0x1 lookup $ROUTE_TABLE_NAME" \
        && ok "fwmark $FWMARK -> table $ROUTE_TABLE_NAME" \
        || { bad "policy rule missing"; FAIL=$((FAIL+1)); }

    ip route show table "$ROUTE_TABLE_NAME" 2>/dev/null | grep -q "default dev $TUN_IF" \
        && ok "table $ROUTE_TABLE_NAME default -> $TUN_IF" \
        || { bad "VPN default route missing"; FAIL=$((FAIL+1)); }

    nft list set inet fw4 vpn_domains >/dev/null 2>&1 \
        && ok "nft set vpn_domains exists" \
        || { bad "nft set vpn_domains missing"; FAIL=$((FAIL+1)); }

    nft list chain inet fw4 mangle_prerouting 2>/dev/null | grep -q "vpn_domains.*mark set" \
        && ok "nft mark rule active" \
        || { bad "nft mark rule missing"; FAIL=$((FAIL+1)); }

    if nslookup www.facebook.com 127.0.0.1 >/tmp/selective-vpn-nslookup 2>&1; then
        ok "DNS through local dnsmasq works"
        grep -E "Name:|Address:" /tmp/selective-vpn-nslookup | tail -n 4
    else
        bad "DNS through local dnsmasq failed"
        cat /tmp/selective-vpn-nslookup
        FAIL=$((FAIL+1))
    fi

    if uci show dhcp.@dnsmasq[0].server 2>/dev/null | grep -q "127.0.0.1#505"; then
        ok "dnsmasq uses local DoH proxy"
    else
        warn "Could not confirm dnsmasq -> https-dns-proxy from UCI"
    fi

    if [ -s "$TMP_DOMAINS" ]; then
        LINES="$(wc -l < "$TMP_DOMAINS" 2>/dev/null)"
        ok "domain list loaded ($LINES lines)"
    elif [ -s "$PERSIST_DOMAINS" ]; then
        warn "persistent domain list exists, but runtime copy is missing"
    else
        warn "domain list not downloaded yet"
    fi

    DHCP6="$(uci -q get dhcp.lan.dhcp_option 2>/dev/null || true)"
    case "$DHCP6" in
        *"6,"*)
            warn "LAN has explicit DHCP option 6: $DHCP6"
            warn "Prefer router DNS only; https-dns-proxy force_dns is enabled."
            ;;
    esac

    echo
    if [ "$FAIL" -eq 0 ]; then
        ok "Core selective routing checks passed"
        return 0
    fi

    bad "$FAIL core check(s) failed"
    return 1
}

refresh_domains() {
    need_root
    load_config
    /usr/libexec/selective-vpn-refresh
}

restart_cmd() {
    need_root
    load_config
    restart_all
    sleep 2
    "$0" check
}

uninstall_selective() {
    need_root
    load_config

    backup_configs

    /etc/init.d/getdomains disable 2>/dev/null || true
    /etc/init.d/selective-vpn-route disable 2>/dev/null || true

    uci -q delete firewall.mark_domains
    uci -q delete firewall.vpn_domains
    uci -q delete firewall.singbox_lan
    uci -q delete firewall.singbox
    uci commit firewall

    uci -q delete dhcp.selective_vpn_domains
    uci commit dhcp

    uci -q delete network.selective_vpn_mark
    uci -q delete network.tun0
    uci commit network

    ip route flush table "$ROUTE_TABLE_NAME" 2>/dev/null || true
    sed -i "/^[[:space:]]*$ROUTE_TABLE_ID[[:space:]]\+$ROUTE_TABLE_NAME[[:space:]]*$/d" /etc/iproute2/rt_tables

    rm -f \
        /etc/init.d/getdomains \
        /etc/init.d/selective-vpn-route \
        /usr/libexec/selective-vpn-refresh \
        /etc/hotplug.d/net/30-vpnroute \
        "$TMP_DOMAINS"

    /etc/init.d/firewall restart
    /etc/init.d/dnsmasq restart

    warn "Selective routing UCI/files removed."
    warn "Packages, DoH configuration, $CONF and /etc/sing-box/config.json were intentionally kept."
}

usage() {
    cat <<EOF
Usage:
  $0 init-config       Create /etc/selective-vpn.conf template
  $0 install           Install/configure selective routing
  $0 check             Check current state
  $0 refresh-domains   Refresh ITDog domain list now
  $0 restart           Restart components and run checks
  $0 uninstall         Remove selective-routing rules/files; keep packages/DoH/config
EOF
}

case "${1:-}" in
    init-config)     create_config ;;
    install)         install_all ;;
    check)           check_all ;;
    refresh-domains) refresh_domains ;;
    restart)         restart_cmd ;;
    uninstall)       uninstall_selective ;;
    *)               usage; exit 1 ;;
esac

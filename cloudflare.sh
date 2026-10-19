#!/usr/bin/env bash
#
# Let only Cloudflare reach the web ports of this host.
#
#   cloudflare.sh update   download Cloudflare's current ranges and apply them
#   cloudflare.sh apply    apply the stored ranges (the bundled ones until the
#                          first update); needs no network, used at boot
#   cloudflare.sh remove   delete everything this script has added
#
# New connections to the ports are filtered in the raw table, before Docker's
# DNAT, so published container ports are covered too. A filter chain then
# accepts the allowed sources in case another firewall keeps the ports closed.
#
# Settings are read from /etc/cloudflare-firewall.conf or $CLOUDFLARE_FIREWALL_CONF,
# downloaded ranges are kept in /var/lib/cloudflare-firewall.

set -euo pipefail

PATH=${PATH:-/usr/bin:/bin}:/usr/local/sbin:/usr/sbin:/sbin

readonly CONFIG=${CLOUDFLARE_FIREWALL_CONF:-/etc/cloudflare-firewall.conf}
readonly STATE_DIR=${STATE_DIRECTORY:-/var/lib/cloudflare-firewall}
readonly LOCK=/run/cloudflare-firewall.lock
readonly CHAIN=CLOUDFLARE SOURCES=CLOUDFLARE-SOURCES
readonly -a IPTABLES=([4]=iptables [6]=ip6tables)
readonly -a RAW_JUMP=(PREROUTING -m addrtype --dst-type LOCAL -j "$CHAIN")
readonly -a FILTER_JUMP=(INPUT -p tcp -j "$CHAIN")

# Used until the first successful update, see https://www.cloudflare.com/ips/
readonly -a BUNDLED_IPV4=(
    173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22
    141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20
    197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13
    104.24.0.0/14 172.64.0.0/13 131.0.72.0/22
)
readonly -a BUNDLED_IPV6=(
    2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32
    2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32
)

log() { echo "cloudflare-firewall: $*"; }
warn() { echo "cloudflare-firewall: warning: $*" >&2; }
die() { echo "cloudflare-firewall: $*" >&2; exit 1; }

usage() {
    echo "usage: ${0##*/} update|apply|remove" >&2
    exit 2
}

require() {
    local cmd
    for cmd; do
        command -v "$cmd" >/dev/null || die "$cmd is not installed"
    done
}

# valid_net 4|6 ADDRESS[/PREFIX]
# IPv4 is checked fully. IPv6 only loosely, which still keeps anything but an
# address out of the iptables input; iptables-restore --test does the rest.
valid_net() {
    local octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
    if [[ $1 == 4 ]]; then
        [[ $2 =~ ^$octet(\.$octet){3}(/(3[0-2]|[12]?[0-9]))?$ ]]
    else
        [[ $2 =~ ^[0-9A-Fa-f.]*:[0-9A-Fa-f:.]*(/(12[0-8]|1[01][0-9]|[1-9]?[0-9]))?$ &&
            $2 != *:::* && $2 != *::*::* ]]
    fi
}

# Copy stdin to stdout if it holds nothing but networks of the given family.
valid_list() {
    local family=$1 line count=0
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ -n $line ]] || continue
        valid_net "$family" "$line" || return 1
        echo "$line"
        (( ++count ))
    done
    (( count > 0 ))
}

load_config() {
    ALLOW=()
    PORTS=(80 443)
    if [[ -e $CONFIG ]]; then
        # shellcheck source=/dev/null
        . "$CONFIG"
    fi

    (( ${#PORTS[@]} >= 1 && ${#PORTS[@]} <= 15 )) || die "PORTS must list 1 to 15 ports"
    local port entry
    for port in "${PORTS[@]}"; do
        if ! [[ $port =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
            die "PORTS: '$port' is not a port number"
        fi
    done
    PORT_LIST=$(IFS=,; echo "${PORTS[*]}")

    ALLOW4=()
    ALLOW6=()
    for entry in "${ALLOW[@]}"; do
        if valid_net 4 "$entry"; then
            ALLOW4+=("$entry")
        elif valid_net 6 "$entry"; then
            ALLOW6+=("$entry")
        elif [[ -n $entry ]]; then
            die "ALLOW: '$entry' is not an IPv4 or IPv6 address or network"
        fi
    done
}

download() {
    if command -v curl >/dev/null; then
        curl -fsSL --proto =https --connect-timeout 10 --max-time 30 --retry 2 "$1"
    else
        wget -qO- --timeout=30 --tries=3 "$1"
    fi
}

download_ranges() {
    command -v curl >/dev/null || command -v wget >/dev/null || die "curl or wget is required"
    local family url body
    for family in 4 6; do
        url=https://www.cloudflare.com/ips-v$family
        body=$(download "$url") || die "could not download $url"
        DOWNLOADED[family]=$(valid_list "$family" <<< "$body") || die "unexpected content at $url"
    done
}

store_ranges() {
    local family
    mkdir -p "$STATE_DIR"
    for family in 4 6; do
        echo "${DOWNLOADED[family]}" > "$STATE_DIR/ips-v$family.new"
    done
    for family in 4 6; do
        mv -f "$STATE_DIR/ips-v$family.new" "$STATE_DIR/ips-v$family"
    done
    log "stored the current Cloudflare ranges"
}

# Cloudflare's networks of one family, one per line.
ranges() {
    local family=$1 stored=$STATE_DIR/ips-v$1 networks
    if [[ -e $stored ]]; then
        if networks=$(valid_list "$family" < "$stored"); then
            echo "$networks"
            return
        fi
        warn "$stored is corrupt, using the bundled list"
    fi
    if [[ $family == 4 ]]; then
        printf '%s\n' "${BUNDLED_IPV4[@]}"
    else
        printf '%s\n' "${BUNDLED_IPV6[@]}"
    fi
}

# iptables-restore input that rebuilds the chains of one family.
ruleset() {
    local family=$1 cloudflare net
    local -a nets
    cloudflare=$(ranges "$family")
    mapfile -t nets <<< "$cloudflare"
    if [[ $family == 4 ]]; then
        nets+=("${ALLOW4[@]}")
    else
        nets+=("${ALLOW6[@]}")
    fi

    cat <<EOF
*raw
:$CHAIN - [0:0]
:$SOURCES - [0:0]
-F $CHAIN
-F $SOURCES
-A $CHAIN -p tcp --syn -m multiport --dports $PORT_LIST -j $SOURCES
-A $CHAIN -p udp -m multiport --dports $PORT_LIST -j $SOURCES
-A $SOURCES -i lo -j RETURN
EOF
    for net in "${nets[@]}"; do
        echo "-A $SOURCES -s $net -j RETURN"
    done
    cat <<EOF
-A $SOURCES -j DROP
COMMIT
*filter
:$CHAIN - [0:0]
-F $CHAIN
-A $CHAIN -p tcp -m multiport ! --dports $PORT_LIST -j RETURN
-A $CHAIN -i lo -j ACCEPT
EOF
    for net in "${nets[@]}"; do
        echo "-A $CHAIN -s $net -j ACCEPT"
    done
    echo COMMIT
}

ensure_rule() {   # IPTABLES TABLE CHAIN RULE...
    local ipt=$1 table=$2 chain=$3
    shift 3
    "$ipt" -w -t "$table" -C "$chain" "$@" 2>/dev/null || "$ipt" -w -t "$table" -I "$chain" "$@"
}

delete_rule() {   # IPTABLES TABLE CHAIN RULE...
    local ipt=$1 table=$2 chain=$3
    shift 3
    while "$ipt" -w -t "$table" -C "$chain" "$@" 2>/dev/null; do
        "$ipt" -w -t "$table" -D "$chain" "$@"
    done
}

delete_chain() {   # IPTABLES TABLE CHAIN
    if "$1" -w -t "$2" -S "$3" >/dev/null 2>&1; then
        "$1" -w -t "$2" -F "$3"
        "$1" -w -t "$2" -X "$3"
    fi
}

apply() {
    local family ipt
    local -a rules

    # Check every family before changing any of them.
    for family in "${FAMILIES[@]}"; do
        ipt=${IPTABLES[family]}
        rules[family]=$(ruleset "$family")
        "$ipt-restore" -w --noflush --test <<< "${rules[family]}" \
            || die "$ipt-restore rejected the IPv$family rules"
    done

    for family in "${FAMILIES[@]}"; do
        ipt=${IPTABLES[family]}
        "$ipt-restore" -w --noflush <<< "${rules[family]}"
        ensure_rule "$ipt" raw "${RAW_JUMP[@]}"
        ensure_rule "$ipt" filter "${FILTER_JUMP[@]}"
    done
    log "ports $PORT_LIST: only Cloudflare and $(( ${#ALLOW4[@]} + ${#ALLOW6[@]} )) extra source(s) may connect"
}

remove() {
    local family ipt
    for family in "${FAMILIES[@]}"; do
        ipt=${IPTABLES[family]}
        delete_rule "$ipt" filter "${FILTER_JUMP[@]}"
        delete_chain "$ipt" filter "$CHAIN"
        delete_rule "$ipt" raw "${RAW_JUMP[@]}"
        delete_chain "$ipt" raw "$CHAIN"
        delete_chain "$ipt" raw "$SOURCES"
    done
    log "rules removed"
}

lock() {
    exec 9> "$LOCK"
    flock -w 60 9 || die "another instance is still running"
}

main() {
    [[ $# == 1 && $1 =~ ^(update|apply|remove)$ ]] || usage
    (( EUID == 0 )) || die "must be run as root"

    FAMILIES=(4)
    if [[ -e /proc/net/if_inet6 ]]; then
        FAMILIES+=(6)
    fi
    local family
    for family in "${FAMILIES[@]}"; do
        require "${IPTABLES[family]}" "${IPTABLES[family]}-restore"
    done
    require flock

    case $1 in
        update)
            load_config
            download_ranges
            lock
            store_ranges
            apply
            ;;
        apply)
            load_config
            lock
            apply
            ;;
        remove)
            lock
            remove
            ;;
    esac
}

main "$@"

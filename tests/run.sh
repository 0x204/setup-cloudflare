#!/usr/bin/env bash
#
# Integration tests for cloudflare.sh. Every case builds its own network
# namespaces, so the host firewall is never touched. Needs root, iproute2
# and python3.
#
#   sudo tests/run.sh                    run all cases
#   sudo tests/run.sh test_name ...      run selected cases
#   sudo BACKEND=legacy tests/run.sh     force iptables-legacy (or nft)
#
#   client ──veth── server ──veth── container
#
# The client owns Cloudflare and foreign source addresses. The server runs
# cloudflare.sh, listens on tcp/443, udp/443 and tcp/8000, and publishes
# tcp/80 to the container the way Docker does.

# shellcheck disable=SC2317  # cases and helpers are called by name
set -euo pipefail

TESTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=$(dirname "$TESTS")/cloudflare.sh
readonly TESTS SCRIPT

readonly SERVER4=192.0.2.1 SERVER6=2001:db8::1
readonly CF4=104.16.0.1 CF6=2606:4700::1
readonly FOREIGN4=203.0.113.5 FOREIGN6=2001:db8:5::5
readonly EXTRA4=198.51.100.7 EXTRA6=2001:db8:7::7
readonly CONTAINER4=172.17.0.2

if [[ -e /proc/net/if_inet6 ]]; then readonly HAVE_IPV6=1; else readonly HAVE_IPV6=; fi

fail() { echo "$*" >&2; exit 1; }

# Run a command only when the kernel has IPv6.
v6() { if [[ $HAVE_IPV6 ]]; then "$@"; fi; }

srv() { ip netns exec "$NS-srv" "$@"; }
cli() { ip netns exec "$NS-cli" "$@"; }
ctr() { ip netns exec "$NS-ctr" "$@"; }

setup() {
    mkdir "$WORK/bin" "$WORK/state"
    touch "$WORK/conf"

    local ns addr
    for ns in srv cli ctr; do
        ip netns add "$NS-$ns"
        ip -n "$NS-$ns" link set lo up
        v6 ip netns exec "$NS-$ns" sysctl -qw net.ipv6.conf.all.accept_dad=0 net.ipv6.conf.default.accept_dad=0
    done
    ip link add eth0 netns "$NS-srv" type veth peer name eth0 netns "$NS-cli"
    ip link add docker0 netns "$NS-srv" type veth peer name eth0 netns "$NS-ctr"

    ip -n "$NS-srv" addr add "$SERVER4/32" dev eth0
    ip -n "$NS-srv" addr add 172.17.0.1/16 dev docker0
    for addr in "$CF4" "$FOREIGN4" "$EXTRA4"; do ip -n "$NS-cli" addr add "$addr/32" dev eth0; done
    ip -n "$NS-ctr" addr add "$CONTAINER4/16" dev eth0
    v6 ip -n "$NS-srv" addr add "$SERVER6/128" dev eth0 nodad
    for addr in "$CF6" "$FOREIGN6" "$EXTRA6"; do v6 ip -n "$NS-cli" addr add "$addr/128" dev eth0 nodad; done

    for ns in srv cli ctr; do ip -n "$NS-$ns" link set eth0 up; done
    ip -n "$NS-srv" link set docker0 up
    for ns in srv cli; do
        ip -n "$NS-$ns" route add default dev eth0
        v6 ip -n "$NS-$ns" -6 route add default dev eth0
    done
    ip -n "$NS-ctr" route add default via 172.17.0.1

    srv sysctl -qw net.ipv4.ip_forward=1
    srv iptables -t nat -A PREROUTING -m addrtype --dst-type LOCAL -p tcp --dport 80 \
        -j DNAT --to-destination "$CONTAINER4:8080"
    srv iptables -t nat -A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE

    listen srv tcp:443 udp:443 tcp:8000
    listen cli tcp:443
    listen ctr tcp:8080
    ready srv tcp 443
    ready srv udp 443
    ready srv tcp 8000
    ready cli tcp 443
    ready ctr tcp 8080
}

teardown() {
    local ns
    for ns in srv cli ctr; do
        ip netns pids "$NS-$ns" 2>/dev/null | xargs -r kill 2>/dev/null || true
        ip netns del "$NS-$ns" 2>/dev/null || true
    done
    rm -rf "$WORK"
}

listen() {   # NS PROTO:PORT...
    local ns=$1
    shift
    ip netns exec "$NS-$ns" python3 "$TESTS/net.py" listen "$@" &
}

ready() {   # NS PROTO PORT
    local _
    for _ in {1..50}; do
        "$1" python3 "$TESTS/net.py" probe "$2" 127.0.0.1 127.0.0.1 "$3" && return
        sleep 0.1
    done
    fail "nothing listens on $2/$3 in $1"
}

# reachable|blocked NS PROTO SRC DST PORT
reachable() { expect 0 "$@"; }
blocked() { expect 1 "$@"; }
expect() {
    local want=$1 ns=$2 proto=$3 src=$4 dst=$5 port=$6 got=0
    local -a outcome=(reachable dropped refused)
    "$ns" python3 "$TESTS/net.py" probe "$proto" "$src" "$dst" "$port" || got=$?
    (( got == want )) || fail "$proto $src -> $dst port $port is ${outcome[got]}, expected ${outcome[want]}"
}

firewall() {
    srv env CLOUDFLARE_FIREWALL_CONF="$WORK/conf" STATE_DIRECTORY="$WORK/state" \
        PATH="$WORK/bin:$PATH" "$SCRIPT" "$@"
}

config() { printf '%s\n' "$@" > "$WORK/conf"; }

rules() {   # the tables cloudflare.sh manages
    srv iptables -t raw -S
    srv iptables -t filter -S
    v6 srv ip6tables -t raw -S
    v6 srv ip6tables -t filter -S
}

# Replace curl with a stub that answers with the given lists.
serve_downloads() {   # IPV4_BODY IPV6_BODY
    mkdir -p "$WORK/www"
    printf '%s\n' "$1" > "$WORK/www/ips-v4"
    printf '%s\n' "$2" > "$WORK/www/ips-v6"
    cat > "$WORK/bin/curl" <<EOF
#!/bin/sh
for arg; do url=\$arg; done
exec cat "$WORK/www/\${url##*/}"
EOF
    chmod +x "$WORK/bin/curl"
}

downloads_fail() {
    printf '#!/bin/sh\nexit 6\n' > "$WORK/bin/curl"
    chmod +x "$WORK/bin/curl"
}

test_only_cloudflare_reaches_web_ports() {
    firewall apply
    reachable cli tcp "$CF4" "$SERVER4" 443
    blocked cli tcp "$FOREIGN4" "$SERVER4" 443
    v6 reachable cli tcp "$CF6" "$SERVER6" 443
    v6 blocked cli tcp "$FOREIGN6" "$SERVER6" 443
}

test_existing_accept_rule_does_not_bypass() {
    # What `ufw allow 80,443/tcp` or a hand-written rule leaves in INPUT.
    srv iptables -A INPUT -p tcp -m multiport --dports 80,443 -j ACCEPT
    v6 srv ip6tables -A INPUT -p tcp -m multiport --dports 80,443 -j ACCEPT
    firewall apply
    blocked cli tcp "$FOREIGN4" "$SERVER4" 443
    v6 blocked cli tcp "$FOREIGN6" "$SERVER6" 443
}

test_cloudflare_passes_a_closed_input_chain() {
    # A default-deny firewall without a rule for the web ports.
    srv iptables -P INPUT DROP
    v6 srv ip6tables -P INPUT DROP
    firewall apply
    reachable cli tcp "$CF4" "$SERVER4" 443
    v6 reachable cli tcp "$CF6" "$SERVER6" 443
}

test_published_container_port_is_restricted() {
    firewall apply
    blocked cli tcp "$FOREIGN4" "$SERVER4" 80
    reachable cli tcp "$CF4" "$SERVER4" 80
}

test_udp_web_port_is_restricted() {
    firewall apply
    blocked cli udp "$FOREIGN4" "$SERVER4" 443
    reachable cli udp "$CF4" "$SERVER4" 443
    v6 blocked cli udp "$FOREIGN6" "$SERVER6" 443
}

test_local_traffic_is_allowed() {
    firewall apply
    reachable srv tcp 127.0.0.1 127.0.0.1 443
    reachable srv tcp "$SERVER4" "$SERVER4" 443
    v6 reachable srv tcp ::1 ::1 443
}

test_other_ports_and_outgoing_traffic_are_untouched() {
    firewall apply
    reachable cli tcp "$FOREIGN4" "$SERVER4" 8000
    reachable srv tcp "$SERVER4" "$FOREIGN4" 443
    reachable ctr tcp "$CONTAINER4" "$FOREIGN4" 443
}

test_allow_list_covers_both_families() {
    config "ALLOW=($EXTRA4 $EXTRA6)"
    firewall apply
    reachable cli tcp "$EXTRA4" "$SERVER4" 443
    blocked cli tcp "$FOREIGN4" "$SERVER4" 443
    v6 reachable cli tcp "$EXTRA6" "$SERVER6" 443
}

test_repeated_apply_keeps_the_ruleset() {
    firewall apply
    local first
    first=$(rules)
    firewall apply
    [[ $(rules) == "$first" ]] || fail "second apply changed the ruleset"
}

test_apply_replaces_previous_settings() {
    config "ALLOW=($EXTRA4)" 'PORTS=(443 8000)'
    firewall apply
    reachable cli tcp "$EXTRA4" "$SERVER4" 443
    blocked cli tcp "$FOREIGN4" "$SERVER4" 8000
    config "ALLOW=($FOREIGN4)"
    firewall apply
    blocked cli tcp "$EXTRA4" "$SERVER4" 443
    reachable cli tcp "$FOREIGN4" "$SERVER4" 443
    reachable cli tcp "$EXTRA4" "$SERVER4" 8000
}

test_invalid_settings_leave_rules_untouched() {
    config "ALLOW=($EXTRA4)"
    firewall apply
    local setting
    for setting in "ALLOW=($EXTRA4/33)" 'ALLOW=(010.0.0.1)' 'ALLOW=(example.com)' \
        'ALLOW=("192.0.2.9 -j ACCEPT")' 'ALLOW=(2001:db8:::1)' 'PORTS=(80 https)' 'PORTS=(70000)' \
        'PORTS=()'; do
        config "$setting"
        if firewall apply 2>/dev/null; then fail "apply accepted $setting"; fi
    done
    reachable cli tcp "$EXTRA4" "$SERVER4" 443
    blocked cli tcp "$FOREIGN4" "$SERVER4" 443
}

test_remove_restores_previous_rules() {
    srv iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    local before
    before=$(rules)
    config "ALLOW=($EXTRA4 $EXTRA6)"
    firewall apply
    firewall remove
    [[ $(rules) == "$before" ]] || fail "remove did not restore the original rules"
    reachable cli tcp "$FOREIGN4" "$SERVER4" 443
}

test_update_applies_downloaded_ranges() {
    serve_downloads 203.0.113.0/24 2001:db8:5::/48
    firewall update
    reachable cli tcp "$FOREIGN4" "$SERVER4" 443
    blocked cli tcp "$CF4" "$SERVER4" 443
    v6 reachable cli tcp "$FOREIGN6" "$SERVER6" 443
    downloads_fail
    firewall apply   # the boot-time path works offline from the stored copy
    reachable cli tcp "$FOREIGN4" "$SERVER4" 443
}

test_failed_update_changes_nothing() {
    firewall apply
    serve_downloads 203.0.113.0/24 '<html>Service unavailable</html>'
    if firewall update 2>/dev/null; then fail "update accepted a malformed list"; fi
    downloads_fail
    if firewall update 2>/dev/null; then fail "update succeeded without a download"; fi
    firewall apply
    reachable cli tcp "$CF4" "$SERVER4" 443
    blocked cli tcp "$FOREIGN4" "$SERVER4" 443
}

test_corrupt_stored_ranges_fall_back_to_bundled() {
    printf '%s\n' '203.0.113.0/24 -j RETURN' > "$WORK/state/ips-v4"
    firewall apply 2>/dev/null
    reachable cli tcp "$CF4" "$SERVER4" 443
    blocked cli tcp "$FOREIGN4" "$SERVER4" 443
}

if [[ -n ${TEST_CASE-} ]]; then
    NS=cft$$
    WORK=$(mktemp -d)
    trap teardown EXIT
    setup
    "$TEST_CASE"
    exit 0
fi

(( EUID == 0 )) || fail "run as root"

if [[ -n ${BACKEND-} ]]; then
    shim=$(mktemp -d)
    trap 'rm -rf "$shim"' EXIT
    for tool in iptables iptables-restore ip6tables ip6tables-restore; do
        target=$(command -v "${tool/tables/tables-$BACKEND}") || fail "${tool/tables/tables-$BACKEND} not found"
        ln -s "$target" "$shim/$tool"
    done
    PATH=$shim:$PATH
fi

cases=("$@")
(( ${#cases[@]} )) || mapfile -t cases < <(declare -F | awk '$3 ~ /^test_/ { print $3 }')
(( ${#cases[@]} )) || fail "no test cases found"
[[ $HAVE_IPV6 ]] || echo "IPv6 is not available in this kernel, IPv6 checks are skipped"

status=0
for name in "${cases[@]}"; do
    if output=$(TEST_CASE=$name "$BASH" "$0" 2>&1); then
        echo "ok   $name"
    else
        echo "FAIL $name"
        mapfile -t lines <<< "$output"
        printf '     %s\n' "${lines[@]}"
        status=1
    fi
done
exit "$status"

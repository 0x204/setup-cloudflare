# setup-cloudflare

Firewall rules that let only [Cloudflare](https://www.cloudflare.com/ips/) reach the web
ports of an origin server, so nobody can bypass Cloudflare by connecting to the server's
IP address directly.

- IPv4 and IPv6, TCP and UDP (HTTP/3).
- Covers services on the host and ports published by Docker.
- Loopback traffic is never blocked; extra addresses can be allowed.
- Cloudflare's ranges are downloaded daily. The last good copy is kept, and a bundled
  list is used until the first download.
- Rules are restored at boot and removed with one command.

## Requirements

Linux with iptables 1.6.2 or newer (nft or legacy backend), bash 4.4 or newer, curl or
wget. systemd for the persistent setup.

## Install

```sh
git clone https://github.com/0x204/setup-cloudflare
cd setup-cloudflare
sudo install -m 0755 cloudflare.sh /usr/local/sbin/cloudflare-firewall
sudo install -m 0644 systemd/* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now cloudflare-firewall
sudo systemctl start cloudflare-firewall-update
```

The service applies the rules at boot, before the network comes up, and a timer refreshes
Cloudflare's ranges once a day. The last command downloads them right away.

To try it without installing anything, run `sudo ./cloudflare.sh update`. The rules then
last until the next reboot.

## Configuration

Copy `cloudflare-firewall.conf` to `/etc/cloudflare-firewall.conf` and edit it:

```sh
ALLOW=(203.0.113.10 2001:db8::/64)   # allowed in addition to Cloudflare
PORTS=(80 443)                        # ports to restrict
```

Then run `sudo systemctl reload cloudflare-firewall`. An invalid setting is rejected and
the rules in place stay as they are.

## Commands

| Command | Effect |
|---|---|
| `cloudflare-firewall update` | download the current ranges and apply them |
| `cloudflare-firewall apply` | apply the stored ranges, no network needed |
| `cloudflare-firewall remove` | delete every rule the script added |

## Uninstall

```sh
sudo systemctl disable --now cloudflare-firewall
sudo rm /usr/local/sbin/cloudflare-firewall /etc/systemd/system/cloudflare-firewall*
sudo rm -rf /var/lib/cloudflare-firewall /etc/cloudflare-firewall.conf
sudo systemctl daemon-reload
```

Stopping the service removes the rules.

## How it works

New connections to the ports are checked in the `raw` table, before connection tracking
and before Docker's DNAT. That is why published container ports are covered and why
`ACCEPT` rules of other firewalls (ufw, firewalld) cannot let other addresses through.
A chain in the `filter` table accepts the allowed sources, so the ports stay reachable
even when another firewall keeps them closed. `sudo iptables -t raw -S` and
`sudo iptables -S` show the rules.

## Limitations

- firewalld with the iptables backend, and nftables configurations that start with
  `flush ruleset`, delete these rules when they reload. Run
  `sudo systemctl reload cloudflare-firewall` afterwards. At boot the service starts
  after them.
- Docker bridges, VPNs and other internal networks are blocked like any other address.
  Add them to `ALLOW` if they need to reach the ports.
- Cloudflare's addresses are shared by all of its customers, so the rules prove that a
  request came through Cloudflare, not through your account. Use
  [Authenticated Origin Pulls](https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/)
  to close that gap, or
  [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/),
  which needs no open ports at all.
- Rules added by the previous version of the script stay until the next reboot. They do
  not interfere with the new ones.

## Tests

```sh
sudo tests/run.sh
```

Every case runs in its own network namespaces, so the host firewall is not touched. The
tests need iproute2 and python3; `BACKEND=legacy` runs them against iptables-legacy.

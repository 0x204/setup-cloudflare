#!/bin/bash

#ipv4
/usr/sbin/iptables -I INPUT -p tcp -m multiport --dports 80,443 -s 103.21.244.0/22 -j ACCEPT
/usr/sbin/iptables -I INPUT -p tcp -m multiport --dports 80,443 -s 103.22.200.0/22 -j ACCEPT
/usr/sbin/iptables -I INPUT -p tcp -m multiport --dports 80,443 -s 103.31.4.0/22 -j ACCEPT
/usr/sbin/iptables -I INPUT -p tcp -m multiport --dports 80,443 -s 104.16.0.0/13 -j ACCEPT
/usr/sbin/iptables -I INPUT -p tcp -m multiport --dports 80,443 -s 104.24.0.0/14 -j ACCEPT
/usr/sbin/iptables -I INPUT -p tcp -m multiport --dports 80,443 -s 108.162.192.0/18 -j ACCEPT
/usr/sbin/iptables -I INPUT -p tcp -m multiport --dports 80,443 -s 131.0.72.0/22 -j ACCEPT
/usr/sbin/iptables -I INPUT -p tcp -m multiport --dports 80,443 -s 141.101.64.0/18 -j ACCEPT
/usr/sbin/iptables -I INPUT -p tcp -m multiport --dports 80,443 -s 162.158.0.0/15 -j ACCEPT
/usr/sbin/iptables -I INPUT -p tcp -m multiport --dports 80,443 -s 172.64.0.0/13 -j ACCEPT
/usr/sbin/iptables -I INPUT -p tcp -m multiport --dports 80,443 -s 173.245.48.0/20 -j ACCEPT
/usr/sbin/iptables -I INPUT -p tcp -m multiport --dports 80,443 -s 188.114.96.0/20 -j ACCEPT
/usr/sbin/iptables -I INPUT -p tcp -m multiport --dports 80,443 -s 190.93.240.0/20 -j ACCEPT
/usr/sbin/iptables -I INPUT -p tcp -m multiport --dports 80,443 -s 197.234.240.0/22 -j ACCEPT
/usr/sbin/iptables -I INPUT -p tcp -m multiport --dports 80,443 -s 198.41.128.0/17 -j ACCEPT

#ipv6
/usr/sbin/ip6tables -I INPUT -p tcp -m multiport --dports 80,443 -s 2400:cb00::/32 -j ACCEPT
/usr/sbin/ip6tables -I INPUT -p tcp -m multiport --dports 80,443 -s 2606:4700::/32 -j ACCEPT
/usr/sbin/ip6tables -I INPUT -p tcp -m multiport --dports 80,443 -s 2803:f800::/32 -j ACCEPT
/usr/sbin/ip6tables -I INPUT -p tcp -m multiport --dports 80,443 -s 2405:b500::/32 -j ACCEPT
/usr/sbin/ip6tables -I INPUT -p tcp -m multiport --dports 80,443 -s 2405:8100::/32 -j ACCEPT
/usr/sbin/ip6tables -I INPUT -p tcp -m multiport --dports 80,443 -s 2a06:98c0::/29 -j ACCEPT
/usr/sbin/ip6tables -I INPUT -p tcp -m multiport --dports 80,443 -s 2c0f:f248::/32 -j ACCEPT

#IP FOR YOU API && smth
/usr/sbin/iptables -I INPUT -p tcp -m multiport --dports 80,443 -s 1.1.1.1/32 -j ACCEPT

#enable firewall
/usr/sbin/iptables -A INPUT -p tcp -m multiport --dports 80,443 -j DROP
/usr/sbin/ip6tables -A INPUT -p tcp -m multiport --dports 80,443 -j DROP
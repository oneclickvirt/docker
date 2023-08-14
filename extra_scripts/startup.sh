#!/bin/bash
# from 
# https://github.com/spiritLHLS/docker
# 2023.08.14


set -eou pipefail
chown root:kvm /dev/kvm
cat > /etc/apt/preferences.d/hashicorp <<EOF
Package: *
Pin: origin apt.releases.hashicorp.com
Pin-Priority: 999
EOF
systemctl enable libvirtd virtlogd --now
VAGRANT_DEFAULT_PROVIDER=libvirt vagrant up 
# --debug
rdp_info=$(vagrant rdp 2>&1)
ip_address=$(echo "$rdp_info" | grep -oP 'Address: (\d+\.\d+\.\d+\.\d+)' | grep -oP '(\d+\.\d+\.\d+\.\d+)')
iptables-save > $HOME/firewall.txt
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
iptables -A FORWARD -i eth0 -o virbr1 -p tcp --syn --dport 3389 -m conntrack --ctstate NEW -j ACCEPT
iptables -A FORWARD -i eth0 -o virbr1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -i virbr1 -o eth0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 3389 -j DNAT --to-destination $ip_address
iptables -t nat -A POSTROUTING -o virbr1 -p tcp --dport 3389 -d $ip_address -j SNAT --to-source 192.168.121.1
iptables -D FORWARD -o virbr1 -j REJECT --reject-with icmp-port-unreachable
iptables -D FORWARD -i virbr1 -j REJECT --reject-with icmp-port-unreachable
iptables -D FORWARD -o virbr0 -j REJECT --reject-with icmp-port-unreachable
iptables -D FORWARD -i virbr0 -j REJECT --reject-with icmp-port-unreachable
exec "$@"

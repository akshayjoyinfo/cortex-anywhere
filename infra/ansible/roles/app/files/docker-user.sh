#!/bin/sh
# Container egress on srv-app. Docker bypasses host input rules, so scope here.
# web (172.31.0.0/24): srv-data only. worker (172.30.0.0/24): srv-data, vLLM, Smokescreen.
set -e
iptables -F DOCKER-USER
iptables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
iptables -A DOCKER-USER -s 172.31.0.0/24 -d 10.10.1.20 -p tcp -m multiport --dports 6432,6379,8200 -j RETURN
iptables -A DOCKER-USER -s 172.30.0.0/24 -d 10.10.1.20 -p tcp -m multiport --dports 6432,6379,8200 -j RETURN
iptables -A DOCKER-USER -s 172.30.0.0/24 -d 10.10.2.10 -p tcp --dport 8000 -j RETURN
iptables -A DOCKER-USER -s 172.30.0.0/24 -d 172.30.0.0/24 -j RETURN
iptables -A DOCKER-USER -s 172.31.0.0/24 -d 172.31.0.0/24 -j RETURN
iptables -A DOCKER-USER -s 172.30.0.0/23 -j DROP
iptables -A DOCKER-USER -j RETURN

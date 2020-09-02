#!/bin/bash

source ./functions.sh

mkdir -p /dev/net

if [ ! -c /dev/net/tun ]; then
    echo "$(datef) Creating tun/tap device."
    mknod /dev/net/tun c 10 200
fi

# Allow UDP traffic on port 1194.
iptables -A INPUT -i eth0 -p udp -m state --state NEW,ESTABLISHED --dport 1194 -j ACCEPT
iptables -A OUTPUT -o eth0 -p udp -m state --state ESTABLISHED --sport 1194 -j ACCEPT

# Allow traffic on the TUN interface.
iptables -A INPUT -i tun0 -j ACCEPT
iptables -A FORWARD -i tun0 -j ACCEPT
iptables -A OUTPUT -o tun0 -j ACCEPT

# Allow forwarding traffic only from the VPN.
iptables -A FORWARD -i tun0 -o eth0 -s 10.8.0.0/24 -j ACCEPT
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE

cd "$APP_PERSIST_DIR"

LOCKFILE=.gen

# Regenerate certs only on the first start
if [ ! -f $LOCKFILE ]; then

    /usr/share/easy-rsa/easyrsa build-ca nopass << EOF

EOF
    # CA creation complete and you may now import and sign cert requests.
    # Your new CA certificate file for publishing is at:
    # /opt/Dockovpn_data/pki/ca.crt

    /usr/share/easy-rsa/easyrsa gen-req MyReq nopass << EOF2

EOF2
    # Keypair and certificate request completed. Your files are:
    # req: /opt/Dockovpn_data/pki/reqs/MyReq.req
    # key: /opt/Dockovpn_data/pki/private/MyReq.key

    /usr/share/easy-rsa/easyrsa sign-req server MyReq << EOF3
yes
EOF3
    # Certificate created at: /opt/Dockovpn_data/pki/issued/MyReq.crt

    openvpn --genkey --secret ta.key << EOF4
yes
EOF4

    touch $LOCKFILE
fi

# Copy server keys and certificates
cp pki/ca.crt pki/issued/MyReq.crt pki/private/MyReq.key ta.key /etc/openvpn

cd "$APP_INSTALL_PATH"

# Print app version
$APP_INSTALL_PATH/version.sh

# Need to feed key password
openvpn --config /etc/openvpn/server.conf &

# By some strange reason we need to do echo command to get to the next command
echo " "

# Generate client config
./genclient.sh $@

#RUN tor
IPTABLES=$(which iptables)  # /sbin/iptables
OVPN=$(ip r | grep "tun" | awk '{print $3}')  # tun0
VPN_IP=$(ip r | grep "tun" | awk '{print $9}')  # 10.8.0.1

# Config IPtables to route all traffic trough Tor proxy
# transparent Tor proxy
$IPTABLES -A INPUT -i $OVPN -s 10.8.0.0/24 -m state --state NEW -j ACCEPT
$IPTABLES -t nat -A PREROUTING -i $OVPN -p udp --dport 53 -s 10.8.0.0/24 -j DNAT --to-destination $VPN_IP:53530
$IPTABLES -t nat -A PREROUTING -i $OVPN -p tcp -s 10.8.0.0/24 -j DNAT --to-destination $VPN_IP:9040
$IPTABLES -t nat -A PREROUTING -i $OVPN -p udp -s 10.8.0.0/24 -j DNAT --to-destination $VPN_IP:9040

## Transproxy leak blocked:
# https://trac.torproject.org/projects/tor/wiki/doc/TransparentProxy#WARNING
$IPTABLES -A OUTPUT -m conntrack --ctstate INVALID -j DROP
$IPTABLES -A OUTPUT -m state --state INVALID -j DROP
$IPTABLES -A OUTPUT ! -o lo ! -d 127.0.0.1 ! -s 127.0.0.1 -p tcp -m tcp --tcp-flags ACK,FIN ACK,FIN -j DROP
$IPTABLES -A OUTPUT ! -o lo ! -d 127.0.0.1 ! -s 127.0.0.1 -p tcp -m tcp --tcp-flags ACK,RST ACK,RST -j DROP

tor

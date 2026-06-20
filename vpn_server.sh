#!/bin/sh
set -e

# ============================================
# OpenVPN server management (inside Alpine LXC)
# Usage: vpn_server.sh {install|config|cleanup}
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "Run as root"
        exit 1
    fi
}

input_param() {
    local prompt="$1"
    local default="$2"
    printf "%s [%s]: " "$prompt" "$default" >&2
    read_input
    [ -z "$val" ] && val="$default"
    echo "$val"
}

read_input() {
    if [ -c /dev/tty ] 2>/dev/null && read -r val </dev/tty 2>/dev/null; then
        return 0
    fi
    read -r val
    return 0
}

read_input_var() {
    if [ -c /dev/tty ] 2>/dev/null && read -r "$1" </dev/tty 2>/dev/null; then
        return 0
    fi
    read -r "$1"
    return 0
}

# -------------------------------------------
# Install: full server setup
# -------------------------------------------
do_install() {
    echo ""
    info "=== OpenVPN server installation ==="
    echo ""

    info "Installing packages..."
    apk update
    apk add openvpn easy-rsa iptables iptables-openrc

    info "Configuring easy-rsa..."
    cp -a /usr/share/easy-rsa /etc/openvpn/easy-rsa
    cd /etc/openvpn/easy-rsa
    mv vars.example vars 2>/dev/null || true

    COUNTRY=$(input_param "Country" "RU")
    PROVINCE=$(input_param "State/Province" "Moscow")
    CITY=$(input_param "City" "Moscow")
    ORG=$(input_param "Organization" "MyOrg")
    EMAIL=$(input_param "Email" "admin@example.com")
    OU=$(input_param "Organizational Unit" "IT")
    SERVER_PORT=$(input_param "OpenVPN port" "1194")
    VPN_PROTO=$(input_param "Protocol (tcp/udp)" "tcp")
    VPN_SUBNET=$(input_param "VPN subnet" "10.8.0.0")
    VPN_MASK=$(input_param "VPN mask" "255.255.255.0")
    DNS1=$(input_param "DNS 1" "8.8.8.8")
    DNS2=$(input_param "DNS 2" "8.8.4.4")
    VPN_PUBLIC_IP=$(input_param "Public IP/hostname" "$(curl -s --max-time 5 ifconfig.me 2>/dev/null || ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')")

    cat >> vars << EOF
set_var EASYRSA_REQ_COUNTRY     "${COUNTRY}"
set_var EASYRSA_REQ_PROVINCE    "${PROVINCE}"
set_var EASYRSA_REQ_CITY        "${CITY}"
set_var EASYRSA_REQ_ORG         "${ORG}"
set_var EASYRSA_REQ_EMAIL       "${EMAIL}"
set_var EASYRSA_REQ_OU          "${OU}"
set_var EASYRSA_ALGO            "ec"
set_var EASYRSA_DIGEST          "sha512"
EOF

    info "Initializing PKI..."
    ./easyrsa init-pki
    echo "xtbz" | ./easyrsa --batch build-ca nopass

    info "Generating server certificate..."
    ./easyrsa --batch gen-req server nopass
    ./easyrsa --batch sign-req server server

    info "Generating DH parameters..."
    ./easyrsa gen-dh

    info "Generating TLS-Auth key..."
    openvpn --genkey secret /etc/openvpn/ta.key

    cp pki/ca.crt pki/issued/server.crt pki/private/server.key pki/dh.pem /etc/openvpn/

    info "Creating server config..."
    cat > /etc/openvpn/server.conf << EOF
port ${SERVER_PORT}
proto ${VPN_PROTO}
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
tls-auth ta.key 0
cipher AES-256-GCM
auth SHA512
server ${VPN_SUBNET} ${VPN_MASK}
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS ${DNS1}"
push "dhcp-option DNS ${DNS2}"
keepalive 10 120
persist-key
persist-tun
user nobody
group nobody
status openvpn-status.log
log-append /var/log/openvpn.log
verb 3
explicit-exit-notify 1
EOF

    info "Configuring forwarding and NAT..."
    sysctl -w net.ipv4.ip_forward=1
    if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    fi

    INTERFACE=$(ip route | grep default | awk '{print $5}')

    iptables -t nat -A POSTROUTING -s "${VPN_SUBNET}/24" -o "$INTERFACE" -j MASQUERADE
    iptables -A FORWARD -i tun0 -o "$INTERFACE" -j ACCEPT
    iptables -A FORWARD -i "$INTERFACE" -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT

    rc-update add iptables default
    /etc/init.d/iptables save 2>/dev/null || true

    info "Configuring OpenVPN autostart..."
    rc-update add openvpn default
    mv /etc/openvpn/server.conf /etc/openvpn/openvpn.conf

    info "Starting OpenVPN..."
    service openvpn start

    sleep 2

    if service openvpn status | grep -q "running"; then
        info "OpenVPN started and running"
    else
        warn "Check logs: tail /var/log/openvpn.log"
    fi

    # Save parameters for user script
    cat > /etc/openvpn/.vpn_params << EOF
VPN_PUBLIC_IP=${VPN_PUBLIC_IP}
VPN_PORT=${SERVER_PORT}
VPN_PROTO=${VPN_PROTO}
VPN_SUBNET=${VPN_SUBNET}
EOF

    echo ""
    info "Installation complete!"
    info "Create users: /root/vpn_users.sh"
}

# -------------------------------------------
# Config: change server parameters
# -------------------------------------------
do_config() {
    echo ""
    info "=== OpenVPN server configuration ==="
    echo ""

    CONF="/etc/openvpn/openvpn.conf"
    if [ ! -f "$CONF" ]; then
        error "Config not found: $CONF"
        exit 1
    fi

    info "Current config:"
    echo "--------------------------------------------"
    cat "$CONF"
    echo "--------------------------------------------"
    echo ""

    info "What to change?"
    echo "  1) Port"
    echo "  2) Protocol"
    echo "  3) DNS"
    echo "  4) VPN subnet"
    echo "  5) Public IP"
    echo "  6) All parameters"
    echo ""
    printf "Select [1-6]: "
    read_input_var choice

    case "$choice" in
        1)
            NEW_PORT=$(input_param "New port" "11995")
            sed -i "s/^port .*/port ${NEW_PORT}/" "$CONF"
            info "Port changed to ${NEW_PORT}"
            ;;
        2)
            NEW_PROTO=$(input_param "Protocol (tcp/udp)" "tcp")
            sed -i "s/^proto .*/proto ${NEW_PROTO}/" "$CONF"
            info "Protocol changed to ${NEW_PROTO}"
            ;;
        3)
            NEW_DNS1=$(input_param "DNS 1" "8.8.8.8")
            NEW_DNS2=$(input_param "DNS 2" "8.8.4.4")
            sed -i "s|push \"dhcp-option DNS .*\"|push \"dhcp-option DNS ${NEW_DNS1}\"|" "$CONF"
            sed -i "0,/push \"dhcp-option DNS .*\"/{s|push \"dhcp-option DNS .*\"|push \"dhcp-option DNS ${NEW_DNS2}\"|}" "$CONF"
            info "DNS changed: ${NEW_DNS1}, ${NEW_DNS2}"
            ;;
        4)
            NEW_SUBNET=$(input_param "VPN subnet" "10.8.0.0")
            NEW_MASK=$(input_param "Mask" "255.255.255.0")
            sed -i "s/^server .*/server ${NEW_SUBNET} ${NEW_MASK}/" "$CONF"
            info "Subnet changed: ${NEW_SUBNET} ${NEW_MASK}"
            ;;
        5)
            NEW_IP=$(input_param "Public IP" "$(curl -s --max-time 5 ifconfig.me 2>/dev/null || ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')")
            PARAMS="/etc/openvpn/.vpn_params"
            if [ -f "$PARAMS" ]; then
                sed -i "s/^VPN_PUBLIC_IP=.*/VPN_PUBLIC_IP=${NEW_IP}/" "$PARAMS"
            fi
            info "Public IP changed to ${NEW_IP}"
            warn "Regenerate .ovpn files for all clients!"
            ;;
        6)
            do_install
            return
            ;;
        *)
            error "Invalid choice"
            return
            ;;
    esac

    echo ""
    printf "Restart OpenVPN now? [Y/n]: "
    read_input_var answer
    if [ "$answer" != "n" ] && [ "$answer" != "N" ]; then
        service openvpn restart
        info "OpenVPN restarted"
    fi
}

# -------------------------------------------
# Cleanup: remove OpenVPN completely
# -------------------------------------------
do_cleanup() {
    echo ""
    warn "=== Full OpenVPN cleanup ==="
    echo ""
    warn "WILL BE REMOVED:"
    echo "  - OpenVPN and all configs"
    echo "  - All certificates and keys"
    echo "  - All client files"
    echo "  - VPN iptables rules"
    echo ""
    printf "Are you sure? Type 'YES' to confirm: "
    read_input_var answer

    if [ "$answer" != "YES" ]; then
        info "Cancelled"
        return
    fi

    info "Stopping OpenVPN..."
    service openvpn stop 2>/dev/null || true
    rc-update del openvpn default 2>/dev/null || true

    info "Removing packages..."
    apk del openvpn easy-rsa iptables-openrc 2>/dev/null || true

    info "Removing configs and keys..."
    rm -rf /etc/openvpn
    rm -rf /root/clients

    info "Cleaning iptables rules..."
    # Read saved VPN subnet for cleanup
    SAVED_SUBNET="10.8.0.0"
    if [ -f /etc/openvpn/.vpn_params ]; then
        . /etc/openvpn/.vpn_params
        [ -n "$VPN_SUBNET" ] && SAVED_SUBNET="$VPN_SUBNET"
    fi
    iptables -t nat -D POSTROUTING -s "${SAVED_SUBNET}/24" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i tun0 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -j ACCEPT 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    /etc/init.d/iptables save 2>/dev/null || true

    info "Disabling forwarding..."
    sysctl -w net.ipv4.ip_forward=0
    sed -i '/net.ipv4.ip_forward = 1/d' /etc/sysctl.conf

    info "Cleanup complete"
}

# -------------------------------------------
# Menu
# -------------------------------------------
menu() {
    echo ""
    echo "============================================"
    echo "  OpenVPN Server — Management"
    echo "============================================"
    echo ""
    echo "  1) Install and configure"
    echo "  2) Change server parameters"
    echo "  3) Full cleanup"
    echo ""
    echo "  0) Exit"
    echo ""
    printf "Select action [0-3]: "
    read_input_var choice
    echo ""

    case "$choice" in
        1) do_install ;;
        2) do_config ;;
        3) do_cleanup ;;
        0) info "Exit"; exit 0 ;;
        *) error "Invalid choice"; menu ;;
    esac
}

check_root

if [ -n "$1" ]; then
    case "$1" in
        install) do_install ;;
        config)  do_config ;;
        cleanup) do_cleanup ;;
        *)       error "Usage: $0 {install|config|cleanup}"; exit 1 ;;
    esac
else
    menu
fi

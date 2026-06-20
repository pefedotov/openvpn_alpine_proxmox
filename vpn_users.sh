#!/bin/sh
set -e

# ============================================
# OpenVPN user management (inside Alpine LXC)
# Usage: vpn_users.sh {add|del|list|ovpn} [username]
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

EASY_RSA_DIR="/etc/openvpn/easy-rsa"
CLIENTS_BASE="/root/clients"

load_params() {
    PARAMS="/etc/openvpn/.vpn_params"
    if [ -f "$PARAMS" ]; then
        . "$PARAMS"
    else
        VPN_PUBLIC_IP=""
        VPN_PORT="1194"
        VPN_PROTO="tcp"
    fi
}

# -------------------------------------------
# Add user
# -------------------------------------------
do_add() {
    if [ -n "$1" ]; then
        CLIENT_NAME="$1"
    else
        printf "Enter client name: "
        read_input_var CLIENT_NAME
    fi

    if [ -z "$CLIENT_NAME" ]; then
        error "Client name cannot be empty"
        exit 1
    fi

    CLIENT_DIR="${CLIENTS_BASE}/${CLIENT_NAME}"

    if [ -d "$CLIENT_DIR" ]; then
        warn "Client '$CLIENT_NAME' already exists"
        printf "Recreate? [y/N]: "
        read_input_var answer
        if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
            info "Cancelled"
            return
        fi
        do_del "$CLIENT_NAME" force
    fi

    if [ ! -d "$EASY_RSA_DIR" ] || [ ! -x "$EASY_RSA_DIR/easyrsa" ]; then
        error "easy-rsa not found. Install OpenVPN: /root/vpn_server.sh install"
        exit 1
    fi

    if [ ! -f "/etc/openvpn/ca.crt" ] || [ ! -f "/etc/openvpn/ta.key" ]; then
        error "ca.crt or ta.key not found"
        exit 1
    fi

    load_params

    cd "$EASY_RSA_DIR"

    info "Generating request for '$CLIENT_NAME'..."
    ./easyrsa --batch gen-req "$CLIENT_NAME" nopass

    info "Signing certificate for '$CLIENT_NAME'..."
    ./easyrsa --batch sign-req client "$CLIENT_NAME"

    mkdir -p "$CLIENT_DIR"

    cp "pki/issued/${CLIENT_NAME}.crt" \
       "pki/private/${CLIENT_NAME}.key" \
       "$CLIENT_DIR/"

    cp /etc/openvpn/ca.crt \
       /etc/openvpn/ta.key \
       "$CLIENT_DIR/"

    info "Generating .ovpn file..."
    cat > "${CLIENT_DIR}/${CLIENT_NAME}.ovpn" << EOF
client
dev tun
proto ${VPN_PROTO:-tcp}
remote ${VPN_PUBLIC_IP:-127.0.0.1} ${VPN_PORT:-1194}
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
auth SHA512
key-direction 1
verb 3

<ca>
$(cat "${CLIENT_DIR}/ca.crt")
</ca>
<cert>
$(cat "${CLIENT_DIR}/${CLIENT_NAME}.crt")
</cert>
<key>
$(cat "${CLIENT_DIR}/${CLIENT_NAME}.key")
</key>
<tls-auth>
$(cat "${CLIENT_DIR}/ta.key")
</tls-auth>
EOF

    echo ""
    info "Client '$CLIENT_NAME' created!"
    info "File: ${CLIENT_DIR}/${CLIENT_NAME}.ovpn"
}

# -------------------------------------------
# Delete user
# -------------------------------------------
do_del() {
    local force=""
    if [ "$2" = "force" ]; then
        force="force"
    fi

    if [ -n "$1" ]; then
        CLIENT_NAME="$1"
    else
        printf "Enter client name to delete: "
        read_input_var CLIENT_NAME
    fi

    if [ -z "$CLIENT_NAME" ]; then
        error "Client name cannot be empty"
        exit 1
    fi

    CLIENT_DIR="${CLIENTS_BASE}/${CLIENT_NAME}"

    if [ ! -d "$CLIENT_DIR" ]; then
        error "Client '$CLIENT_NAME' not found"
        exit 1
    fi

    if [ "$force" != "force" ]; then
        warn "Deleting client '$CLIENT_NAME'..."
        warn "Files will be removed from $CLIENT_DIR"
        printf "Confirm? [y/N]: "
        read_input_var answer

        if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
            info "Cancelled"
            return
        fi
    fi

    cd "$EASY_RSA_DIR"
    ./easyrsa --batch revoke "$CLIENT_NAME" 2>/dev/null || true

    rm -rf "$CLIENT_DIR"

    info "Client '$CLIENT_NAME' deleted"
}

# -------------------------------------------
# List users
# -------------------------------------------
do_list() {
    echo ""
    info "=== Client list ==="
    echo ""

    if [ ! -d "$CLIENTS_BASE" ]; then
        warn "No clients found"
        return
    fi

    COUNT=0
    for dir in "$CLIENTS_BASE"/*/; do
        [ -d "$dir" ] || continue
        name=$(basename "$dir")
        ovpn_file="${dir}${name}.ovpn"
        if [ -f "$ovpn_file" ]; then
            printf "  %-20s .ovpn: ok\n" "$name"
        else
            printf "  %-20s .ovpn: missing\n" "$name"
        fi
        COUNT=$((COUNT + 1))
    done

    echo ""
    if [ "$COUNT" -eq 0 ]; then
        warn "No clients found"
    else
        info "Total: ${COUNT}"
    fi
}

# -------------------------------------------
# Regenerate .ovpn for existing user
# -------------------------------------------
do_ovpn() {
    if [ -n "$1" ]; then
        CLIENT_NAME="$1"
    else
        printf "Enter client name: "
        read_input_var CLIENT_NAME
    fi

    if [ -z "$CLIENT_NAME" ]; then
        error "Client name cannot be empty"
        exit 1
    fi

    CLIENT_DIR="${CLIENTS_BASE}/${CLIENT_NAME}"

    if [ ! -d "$CLIENT_DIR" ]; then
        error "Client '$CLIENT_NAME' not found"
        exit 1
    fi

    if [ ! -f "${CLIENT_DIR}/${CLIENT_NAME}.crt" ] || [ ! -f "${CLIENT_DIR}/${CLIENT_NAME}.key" ]; then
        error "Certificate files not found for '$CLIENT_NAME'"
        exit 1
    fi

    load_params

    info "Regenerating .ovpn file for '$CLIENT_NAME'..."
    cat > "${CLIENT_DIR}/${CLIENT_NAME}.ovpn" << EOF
client
dev tun
proto ${VPN_PROTO:-tcp}
remote ${VPN_PUBLIC_IP:-127.0.0.1} ${VPN_PORT:-1194}
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
auth SHA512
key-direction 1
verb 3

<ca>
$(cat "${CLIENT_DIR}/ca.crt")
</ca>
<cert>
$(cat "${CLIENT_DIR}/${CLIENT_NAME}.crt")
</cert>
<key>
$(cat "${CLIENT_DIR}/${CLIENT_NAME}.key")
</key>
<tls-auth>
$(cat "${CLIENT_DIR}/ta.key")
</tls-auth>
EOF

    info ".ovpn file created: ${CLIENT_DIR}/${CLIENT_NAME}.ovpn"
}

# -------------------------------------------
# Menu
# -------------------------------------------
menu() {
    echo ""
    echo "============================================"
    echo "  OpenVPN Users — Management"
    echo "============================================"
    echo ""
    echo "  1) Add client"
    echo "  2) Delete client"
    echo "  3) List clients"
    echo "  4) Regenerate .ovpn file"
    echo ""
    echo "  0) Exit"
    echo ""
    printf "Select action [0-4]: "
    read_input_var choice
    echo ""

    case "$choice" in
        1) do_add ;;
        2) do_del ;;
        3) do_list ;;
        4) do_ovpn ;;
        0) info "Exit"; exit 0 ;;
        *) error "Invalid choice"; menu ;;
    esac
}

check_root

if [ -n "$1" ]; then
    case "$1" in
        add)   do_add "$2" ;;
        del)   do_del "$2" ;;
        list)  do_list ;;
        ovpn)  do_ovpn "$2" ;;
        *)     error "Usage: $0 {add|del|list|ovpn} [name]"; exit 1 ;;
    esac
else
    menu
fi

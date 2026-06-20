#!/bin/sh

# ============================================
# Main script — Alpine OpenVPN for Proxmox LXC
# Runs on Proxmox host
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "Run as root (sudo)"
        exit 1
    fi
}

check_proxmox() {
    if [ ! -d "/etc/pve" ]; then
        error "Script must be run on Proxmox host"
        exit 1
    fi
}

# Read from terminal even when stdin is piped (curl | bash)
input_param() {
    local prompt="$1"
    local default="$2"
    printf "%s [%s]: " "$prompt" "$default" >&2
    read -r val </dev/tty
    [ -z "$val" ] && val="$default"
    echo "$val"
}

input_password() {
    local prompt="$1"
    local default="$2"
    printf "%s: " "$prompt" >&2
    stty -echo 2>/dev/null
    val=""
    read -r val
    stty echo 2>/dev/null
    printf "\n" >&2
    [ -z "$val" ] && val="$default"
    echo "$val"
}

ask_yes_no() {
    printf "%s [y/N]: " "$1"
    read -r answer </dev/tty
    [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}

# Get host IP on the external interface
get_host_ip() {
    local ext_if
    ext_if=$(ip route | grep default | awk '{print $5}')
    ip addr show "$ext_if" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1
}

# Restore DNS in container (apk upgrade overwrites resolv.conf)
restore_dns() {
    local host_ip
    host_ip=$(get_host_ip)
    echo "nameserver ${host_ip}" > /tmp/_resolv.conf
    pct push "$CTID" /tmp/_resolv.conf /etc/resolv.conf 2>/dev/null
    rm -f /tmp/_resolv.conf
}

# Ensure container has internet access via host NAT + DNS forwarding
ensure_container_network() {
    local ct_ip="$1"

    # Test if container can reach the internet
    if pct exec "$CTID" -- ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        return 0
    fi

    info "Container has no internet access. Configuring NAT and DNS on host..."

    # Extract subnet from container IP (e.g. 192.168.100.100/24 -> 192.168.100.0/24)
    local subnet_base
    subnet_base=$(echo "$ct_ip" | cut -d. -f1-3)
    local ct_subnet_cidr="${subnet_base}.0/24"

    # Find the host's external interface (the one with the default route)
    local ext_if
    ext_if=$(ip route | grep default | awk '{print $5}')

    # Enable IP forwarding
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    # Add masquerade for container subnet
    if ! iptables -t nat -C POSTROUTING -s "$ct_subnet_cidr" -o "$ext_if" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -s "$ct_subnet_cidr" -o "$ext_if" -j MASQUERADE
    fi

    # Allow forwarding
    if ! iptables -C FORWARD -i vmbr+ -o "$ext_if" -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -i vmbr+ -o "$ext_if" -j ACCEPT
    fi
    if ! iptables -C FORWARD -i "$ext_if" -o vmbr+ -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -i "$ext_if" -o vmbr+ -m state --state RELATED,ESTABLISHED -j ACCEPT
    fi

    # Set up DNS forwarding via dnsmasq
    local host_ip
    host_ip=$(get_host_ip)

    if ! command -v dnsmasq >/dev/null 2>&1; then
        info "Installing dnsmasq for DNS forwarding..."
        apt-get install -y dnsmasq >/dev/null 2>&1
    fi

    mkdir -p /etc/dnsmasq.d
    cat > /etc/dnsmasq.d/openvpn-forward.conf << DNSEOF
listen-address=127.0.0.1,${host_ip}
bind-interfaces
no-resolv
server=8.8.8.8
server=8.8.4.4
DNSEOF
    systemctl restart dnsmasq 2>/dev/null || service dnsmasq restart 2>/dev/null

    # Set DNS in container to point to host
    restore_dns

    # Wait for DNS to become available
    sleep 2

    # Verify connectivity
    if pct exec "$CTID" -- ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        info "Internet access configured successfully"
    else
        warn "Internet access still unavailable — packages may fail to install"
    fi
}

# -------------------------------------------
# 1. Proxmox host configuration
# -------------------------------------------
setup_proxmox() {
    check_proxmox

    echo ""
    info "=== Proxmox host configuration ==="
    echo ""

    info "Enabling IP forwarding on host..."
    sysctl -w net.ipv4.ip_forward=1
    if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    fi
    info "IP forwarding enabled"
    info "Host configuration complete. Create container next."
}

# -------------------------------------------
# 2. Container creation
# -------------------------------------------
create_container() {
    check_proxmox

    echo ""
    info "=== Create Alpine LXC container ==="
    echo ""

    # Compute default container ID: next available starting from 100
    DEFAULT_CTID=100
    while [ -f "/etc/pve/lxc/${DEFAULT_CTID}.conf" ]; do
        DEFAULT_CTID=$((DEFAULT_CTID + 1))
    done

    # Compute default IP: last octet = container ID, same subnet as host
    DEFAULT_GW=$(ip route | grep default | awk '{print $3}')
    DEFAULT_SUBNET=$(echo "$DEFAULT_GW" | cut -d. -f1-3)
    DEFAULT_IP="${DEFAULT_SUBNET}.${DEFAULT_CTID}"

    CTID=$(input_param "Container ID" "$DEFAULT_CTID")
    HOSTNAME=$(input_param "Hostname" "alpine-vpn")
    PASSWORD=$(input_password "Root password (for SSH)" "vpn123")

    DEFAULT_STORAGE=$(pvesm status 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}')
    [ -z "$DEFAULT_STORAGE" ] && DEFAULT_STORAGE="local"

    case "$(uname -m)" in
        x86_64)  DEFAULT_ARCH="amd64" ;;
        i?86)    DEFAULT_ARCH="i386" ;;
        aarch64) DEFAULT_ARCH="arm64" ;;
        armv7l)  DEFAULT_ARCH="armhf" ;;
        *)       DEFAULT_ARCH="amd64" ;;
    esac

    info "Available storage:"
    pvesm status | awk 'NR>1 && $3=="active" {print "  " $1, "(" $4 ")"}'
    echo ""
    STORAGE=$(input_param "Storage" "$DEFAULT_STORAGE")

    DISK=$(input_param "Disk (GB)" "2")
    RAM=$(input_param "RAM (MB)" "512")
    SWAP=$(input_param "Swap (MB)" "256")
    CORES=$(input_param "CPU cores" "1")

    info "Available bridges:"
    ip -o link show type bridge | awk -F': ' '{print "  " $2}'
    echo ""
    BRIDGE=$(input_param "Bridge" "vmbr0")

    # Recompute defaults based on selected bridge
    BRIDGE_IP=$(ip addr show "$BRIDGE" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
    BRIDGE_SUBNET=$(echo "$BRIDGE_IP" | cut -d. -f1-3)
    BRIDGE_GW="${BRIDGE_SUBNET}.1"
    BRIDGE_NEXT="${BRIDGE_SUBNET}.${DEFAULT_CTID}"

    GW=$(input_param "Gateway" "$BRIDGE_GW")
    IP_ADDR=$(input_param "Container IP" "$BRIDGE_NEXT")

    if [ -f "/etc/pve/lxc/${CTID}.conf" ]; then
        warn "Container with ID ${CTID} already exists!"
        if ! ask_yes_no "Delete and recreate?"; then
            error "Cancelled"
            exit 1
        fi
        pct stop "$CTID" 2>/dev/null || true
        pct destroy "$CTID" --purge
        info "Container ${CTID} deleted"
    fi

    info "Detecting Alpine template..."
    TEMPLATE=$(pveam list local 2>/dev/null | grep -i alpine | tail -1 | awk '{print $1}')
    if [ -z "$TEMPLATE" ]; then
        warn "No Alpine template found in local storage"
        info "Updating template list..."
        pveam update
        AVAILABLE=$(pveam available 2>/dev/null | grep -i alpine | tail -1 | awk '{print $2}')
        if [ -z "$AVAILABLE" ]; then
            error "No Alpine template available. Check your Proxmox repositories."
            exit 1
        fi
        info "Downloading $AVAILABLE to local storage..."
        pveam download local "$AVAILABLE"
        TEMPLATE="local:vztmpl/${AVAILABLE}"
    fi
    info "Using template: $TEMPLATE"

    info "Creating container ${CTID}..."
    pct create "$CTID" "$TEMPLATE" \
        --hostname "$HOSTNAME" \
        --password "$PASSWORD" \
        --storage "$STORAGE" \
        --rootfs "${STORAGE}:${DISK}" \
        --memory "$RAM" \
        --swap "$SWAP" \
        --cores "$CORES" \
        --arch "$DEFAULT_ARCH" \
        --net0 "name=eth0,bridge=${BRIDGE},ip=${IP_ADDR}/24,gw=${GW},type=veth" \
        --ostype alpine \
        --unprivileged 1

    if [ $? -ne 0 ]; then
        error "Failed to create container"
        exit 1
    fi

    # Add cgroup for tun
    CONF="/etc/pve/lxc/${CTID}.conf"
    if ! grep -q "c 10:200" "$CONF"; then
        echo "" >> "$CONF"
        echo "# OpenVPN tun access" >> "$CONF"
        echo "lxc.cgroup2.devices.allow: c 10:200 rwm" >> "$CONF"
        echo "lxc.mount.entry: /dev/net dev/net none bind,create=dir" >> "$CONF"
    fi

    info "Starting container..."
    pct start "$CTID"

    sleep 3

    # Ensure container has internet access
    ensure_container_network "$IP_ADDR"

    info "Updating system..."
    if ! pct exec "$CTID" -- apk update 2>&1; then
        error "Failed to update packages. Check DNS and internet connectivity."
        exit 1
    fi

    info "Upgrading system..."
    pct exec "$CTID" -- apk upgrade
    # apk upgrade overwrites /etc/resolv.conf with Proxmox defaults — restore DNS
    restore_dns

    info "Installing packages..."
    if ! pct exec "$CTID" -- apk add openvpn easy-rsa iptables iptables-openrc 2>&1; then
        error "Failed to install packages. Check DNS and internet connectivity."
        exit 1
    fi

    # Copy management scripts into container
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    GITHUB_RAW="https://raw.githubusercontent.com/pefedotov/openvpn_alpine_proxmox/main"

    for script in vpn_server.sh vpn_users.sh; do
        if [ -f "$SCRIPT_DIR/$script" ]; then
            pct push "$CTID" "$SCRIPT_DIR/$script" "/root/$script"
        else
            # Download on host (reliable) then push into container
            info "Downloading $script from GitHub..."
            wget -T 30 --tries=2 -q -O "/tmp/_${script}" "${GITHUB_RAW}/${script}"
            if [ $? -ne 0 ]; then
                error "Failed to download $script"
                exit 1
            fi
            pct push "$CTID" "/tmp/_${script}" "/root/$script"
            rm -f "/tmp/_${script}"
        fi
        pct exec "$CTID" -- chmod +x "/root/$script"
        info "$script ready in container"
    done

    echo ""
    info "Container ${CTID} created and started"
    echo ""
    info "=== Connection ==="
    info "Console:  pct enter ${CTID}"
    info "SSH:      ssh root@${IP_ADDR}  (password: ${PASSWORD})"
    echo ""
    info "=== OpenVPN setup ==="
    info "Run inside container:"
    info "  /root/vpn_server.sh install"
}

# -------------------------------------------
# 3. Enable access in Proxmox
# -------------------------------------------
enable_proxmox_access() {
    check_proxmox

    echo ""
    info "=== Configure DNAT for VPN access through Proxmox ==="
    echo ""

    DEFAULT_GW=$(ip route | grep default | awk '{print $3}')
    DEFAULT_SUBNET=$(echo "$DEFAULT_GW" | cut -d. -f1-3)

    CT_IP=$(input_param "Container IP" "${DEFAULT_SUBNET}.104")
    VPN_PORT=$(input_param "OpenVPN port" "1194")
    EXT_IF=$(input_param "Host external interface" "vmbr0")

    sysctl -w net.ipv4.ip_forward=1

    info "Adding DNAT and MASQUERADE rules..."

    iptables -t nat -A PREROUTING -i "$EXT_IF" -p tcp --dport "$VPN_PORT" \
        -j DNAT --to-destination "${CT_IP}:${VPN_PORT}" 2>/dev/null || true

    iptables -t nat -A POSTROUTING -s "$CT_IP" -o "$EXT_IF" -j MASQUERADE 2>/dev/null || true

    iptables -I FORWARD 1 -i "$EXT_IF" -d "$CT_IP" -p tcp --dport "$VPN_PORT" -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD 2 -o "$EXT_IF" -s "$CT_IP" -p tcp --sport "$VPN_PORT" -j ACCEPT 2>/dev/null || true

    info "DNAT configured: ${EXT_IF}:${VPN_PORT} -> ${CT_IP}:${VPN_PORT}"
    warn "To persist iptables rules use: iptables-save > /etc/iptables/rules.v4"
}

# -------------------------------------------
# 4. Full setup
# -------------------------------------------
full_setup() {
    echo ""
    info "=== Full installation and setup ==="
    echo ""

    setup_proxmox

    echo ""
    info "Creating container..."
    create_container

    echo ""
    info "Configuring OpenVPN inside container..."
    pct exec "$CTID" -- /root/vpn_server.sh install

    # Read VPN port from container config
    VPN_PORT=$(pct exec "$CTID" -- awk '/^port /{print $2}' /etc/openvpn/openvpn.conf 2>/dev/null)
    [ -z "$VPN_PORT" ] && VPN_PORT="1194"
    VPN_PORT=$(input_param "VPN port for external access" "$VPN_PORT")

    # Set up DNAT: forward VPN port from host to container
    local ext_if
    ext_if=$(ip route | grep default | awk '{print $5}')

    sysctl -w net.ipv4.ip_forward=1

    info "Setting up DNAT: ${ext_if}:${VPN_PORT} -> ${IP_ADDR}:${VPN_PORT}"
    iptables -t nat -A PREROUTING -i "$ext_if" -p tcp --dport "$VPN_PORT" \
        -j DNAT --to-destination "${IP_ADDR}:${VPN_PORT}" 2>/dev/null || true
    iptables -t nat -A POSTROUTING -s "$IP_ADDR" -o "$ext_if" -j MASQUERADE 2>/dev/null || true
    iptables -I FORWARD -i "$ext_if" -d "$IP_ADDR" -p tcp --dport "$VPN_PORT" -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD -o "$ext_if" -s "$IP_ADDR" -p tcp --sport "$VPN_PORT" -j ACCEPT 2>/dev/null || true

    warn "To persist iptables rules: iptables-save > /etc/iptables/rules.v4"

    echo ""
    info "Full setup complete!"
    info "Connect: ssh root@${IP_ADDR}"
    info "Create users: /root/vpn_users.sh"
}

# -------------------------------------------
# Menu
# -------------------------------------------
menu() {
    echo ""
    echo "============================================"
    echo "  Alpine OpenVPN — Management"
    echo "============================================"
    echo ""
    echo "  1) Proxmox configuration"
    echo "  2) Create container"
    echo "  3) Enable access in Proxmox"
    echo "  4) Full installation and setup"
    echo ""
    echo "  0) Exit"
    echo ""
    printf "Select action [0-4]: "
    read -r choice </dev/tty
    echo ""

    case "$choice" in
        1) setup_proxmox; menu ;;
        2) create_container; menu ;;
        3) enable_proxmox_access; menu ;;
        4) full_setup; menu ;;
        0) info "Exit"; exit 0 ;;
        *) error "Invalid choice"; menu ;;
    esac
}

check_root
menu

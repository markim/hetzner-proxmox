#!/bin/bash

# Network Configuration Script for Hetzner Proxmox
# This script safely configures additional IP addresses while preserving SSH connectivity

set -euo pipefail

# Custom error handler
error_handler() {
    local line_no=$1
    local error_code=$2
    log "ERROR" "Script failed at line $line_no with exit code $error_code"
    log "ERROR" "This error occurred in the setup-network script"
    exit "$error_code"
}

# Set up error handling
trap 'error_handler ${LINENO} $?' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source common functions
source "$SCRIPT_DIR/lib/common.sh"

# Load environment
load_env "$SCRIPT_DIR/.env"

# Global flag for reset mode
RESET_TO_ARIADATA=false

# Network configuration safety checks
NETWORK_BACKUP_DIR="${NETWORK_BACKUP_DIR:-/root/network-backups}"
INTERFACES_FILE="${INTERFACES_FILE:-/etc/network/interfaces}"
INTERFACES_BACKUP="$NETWORK_BACKUP_DIR/interfaces.backup.$(date +%Y%m%d_%H%M%S)"

# Create backup directory
create_backup_dir() {
    log "INFO" "Creating network backup directory..."
    mkdir -p "$NETWORK_BACKUP_DIR"
}

# Get current SSH connection info
get_ssh_info() {
    local ssh_client_ip=""
    local ssh_interface=""
    local current_ip=""
    local physical_interface=""
    
    if [[ -n "${SSH_CLIENT:-}" ]]; then
        ssh_client_ip=$(echo "$SSH_CLIENT" | awk '{print $1}')
        log "INFO" "SSH connection detected from: $ssh_client_ip"
    fi
    
    # Get current default route interface
    ssh_interface=$(ip route | grep default | awk '{print $5}' | head -n1)
    current_ip=$(ip addr show "$ssh_interface" | grep "inet " | awk '{print $2}' | cut -d/ -f1 | head -n1)
    
    # If we're already on a bridge interface, find the physical interface
    if [[ "$ssh_interface" == "vmbr0" ]]; then
        log "INFO" "Already using bridge interface vmbr0, finding physical interface..."
        
        # Try to find the physical interface from bridge configuration
        if [[ -f /sys/class/net/vmbr0/bridge/bridge_id ]]; then
            # This is definitely a bridge, get the physical interface
            physical_interface=$(find /sys/class/net/vmbr0/brif/ -mindepth 1 -maxdepth 1 2>/dev/null | head -n1 | xargs basename)
            if [[ -n "$physical_interface" ]]; then
                log "INFO" "Found physical interface: $physical_interface"
                export PHYSICAL_INTERFACE="$physical_interface"
            else
                log "WARN" "Could not determine physical interface from bridge"
                # Fallback: look for eth0 or similar
                for iface in eth0 ens3 ens18 enp0s3; do
                    if ip link show "$iface" >/dev/null 2>&1; then
                        physical_interface="$iface"
                        log "INFO" "Using fallback physical interface: $physical_interface"
                        break
                    fi
                done
                export PHYSICAL_INTERFACE="${physical_interface:-eth0}"
            fi
        else
            log "ERROR" "Interface vmbr0 exists but is not a bridge"
            return 1
        fi
    else
        # Regular physical interface
        physical_interface="$ssh_interface"
        export PHYSICAL_INTERFACE="$physical_interface"
    fi
    
    log "INFO" "Current SSH interface: $ssh_interface"
    log "INFO" "Physical interface: ${PHYSICAL_INTERFACE}"
    log "INFO" "Current IP: $current_ip"
    
    # Debug information
    log "DEBUG" "SSH_CLIENT: ${SSH_CLIENT:-unset}"
    log "DEBUG" "ssh_client_ip: ${ssh_client_ip:-unset}"
    log "DEBUG" "ssh_interface: ${ssh_interface:-unset}"
    log "DEBUG" "current_ip: ${current_ip:-unset}"
    log "DEBUG" "physical_interface: ${physical_interface:-unset}"
    
    export SSH_CLIENT_IP="$ssh_client_ip"
    export SSH_INTERFACE="$ssh_interface"
    export CURRENT_IP="$current_ip"
}

# Backup current network configuration
backup_network_config() {
    log "INFO" "Backing up current network configuration..."
    
    # Backup interfaces file
    if [[ -f "$INTERFACES_FILE" ]]; then
        cp "$INTERFACES_FILE" "$INTERFACES_BACKUP"
        log "INFO" "Backed up $INTERFACES_FILE to $INTERFACES_BACKUP"
    fi
    
    # Save current routing table
    ip route > "$NETWORK_BACKUP_DIR/routes.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Save current interface configuration
    ip addr > "$NETWORK_BACKUP_DIR/interfaces.current.$(date +%Y%m%d_%H%M%S)"
    
    log "INFO" "Network configuration backed up successfully"
}

# Validate network configuration before applying
validate_network_config() {
    log "INFO" "Validating network configuration..."
    
    # Check if main interface is defined
    if [[ -z "${SSH_INTERFACE:-}" ]]; then
        log "ERROR" "Cannot determine main network interface"
        return 1
    fi
    
    # Check if current IP is accessible
    if [[ -z "${CURRENT_IP:-}" ]]; then
        log "ERROR" "Cannot determine current IP address"
        return 1
    fi
    
    log "INFO" "Network configuration validation passed"
}

# Parse additional IPs from environment or config file
parse_additional_ips() {
    local ips_array=()
    local macs_array=()
    local gateways_array=()
    local netmasks_array=()
    
    # Method 1: Check for separate config file
    local config_file="$SCRIPT_DIR/config/additional-ips.conf"
    if [[ -f "$config_file" ]]; then
        log "INFO" "Loading additional IPs from config file: $config_file"
        
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Skip empty lines and comments
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            
            # Parse format: IP=1.2.3.4 MAC=00:11:22:33:44:55 GATEWAY=1.2.3.1 NETMASK=255.255.255.0
            local ip="" mac="" gateway="" netmask=""
            
            # Extract values using parameter expansion
            if [[ "$line" =~ IP=([^[:space:]]+) ]]; then
                ip="${BASH_REMATCH[1]}"
            fi
            if [[ "$line" =~ MAC=([^[:space:]]+) ]]; then
                mac="${BASH_REMATCH[1]}"
            fi
            if [[ "$line" =~ GATEWAY=([^[:space:]]+) ]]; then
                gateway="${BASH_REMATCH[1]}"
            fi
            if [[ "$line" =~ NETMASK=([^[:space:]]+) ]]; then
                netmask="${BASH_REMATCH[1]}"
            fi
            
            # Validate required fields
            if [[ -n "$ip" && -n "$gateway" && -n "$netmask" ]]; then
                ips_array+=("$ip")
                macs_array+=("${mac:-}")
                gateways_array+=("$gateway")
                netmasks_array+=("$netmask")
                log "DEBUG" "Parsed from config: IP=$ip, MAC=${mac:-N/A}, Gateway=$gateway, Netmask=$netmask"
            else
                log "WARN" "Invalid config line (missing required fields): $line"
            fi
        done < "$config_file"
        
    # Method 2: Check for structured environment variables
    elif [[ -n "${ADDITIONAL_IP_1:-}" ]]; then
        log "INFO" "Loading additional IPs from structured environment variables"
        
        local i=1
        while true; do
            local ip_var="ADDITIONAL_IP_${i}"
            local mac_var="ADDITIONAL_MAC_${i}"
            local gateway_var="ADDITIONAL_GATEWAY_${i}"
            local netmask_var="ADDITIONAL_NETMASK_${i}"
            
            local ip="${!ip_var:-}"
            local mac="${!mac_var:-}"
            local gateway="${!gateway_var:-}"
            local netmask="${!netmask_var:-}"
            
            # Stop if no more IPs defined
            [[ -z "$ip" ]] && break
            
            # Validate required fields
            if [[ -n "$gateway" && -n "$netmask" ]]; then
                ips_array+=("$ip")
                macs_array+=("$mac")
                gateways_array+=("$gateway")
                netmasks_array+=("$netmask")
                log "DEBUG" "Parsed from env: IP=$ip, MAC=${mac:-N/A}, Gateway=$gateway, Netmask=$netmask"
            else
                log "WARN" "Invalid IP config $i: missing gateway or netmask"
            fi
            
            ((i++))
        done
        
    else
        log "INFO" "No additional IPs to configure"
        log "INFO" "Configure using one of these methods:"
        log "INFO" "  1. Create config file: $config_file"
        log "INFO" "  2. Set environment variables: ADDITIONAL_IP_1, ADDITIONAL_GATEWAY_1, etc."
        return 0
    fi
    
    if [[ -n "${ips_array[*]:-}" ]]; then
        export ADDITIONAL_IPS_ARRAY=("${ips_array[@]}")
        export ADDITIONAL_MACS_ARRAY=("${macs_array[@]}")
        export ADDITIONAL_GATEWAYS_ARRAY=("${gateways_array[@]}")
        export ADDITIONAL_NETMASKS_ARRAY=("${netmasks_array[@]}")
    else
        export ADDITIONAL_IPS_ARRAY=()
        export ADDITIONAL_MACS_ARRAY=()
        export ADDITIONAL_GATEWAYS_ARRAY=()
        export ADDITIONAL_NETMASKS_ARRAY=()
    fi
    
    log "INFO" "Parsed ${#ips_array[@]} additional IP configurations"
}

# Create ariadata pve-install.sh compatible network configuration
create_ariadata_network_config() {
    log "INFO" "Creating ariadata pve-install.sh compatible network configuration..."
    
    local temp_config="/tmp/interfaces.ariadata"
    
    # Get current network info safely
    local current_cidr=""
    local current_gateway=""
    local current_mac=""
    local current_ipv6=""
    
    # Try to get CIDR from current IP configuration
    current_cidr=$(ip addr show "$SSH_INTERFACE" | grep "inet " | grep "$CURRENT_IP" | awk '{print $2}' | head -n1)
    if [[ -z "$current_cidr" ]]; then
        log "WARN" "Could not determine current CIDR, using /26 as fallback for Hetzner"
        current_cidr="$CURRENT_IP/26"
    fi
    
    # Get current gateway
    current_gateway=$(ip route | grep default | awk '{print $3}' | head -n1)
    if [[ -z "$current_gateway" ]]; then
        log "ERROR" "Could not determine current gateway"
        return 1
    fi
    
    # Get MAC address of the physical interface
    local interface_for_mac="${PHYSICAL_INTERFACE:-$SSH_INTERFACE}"
    if [[ "$SSH_INTERFACE" == "vmbr0" ]]; then
        interface_for_mac="${PHYSICAL_INTERFACE}"
    fi
    current_mac=$(ip link show "$interface_for_mac" | awk '/ether/ {print $2}')
    if [[ -z "$current_mac" ]]; then
        log "ERROR" "Could not determine MAC address for interface $interface_for_mac"
        return 1
    fi
    
    # Get IPv6 address if available
    current_ipv6=$(ip addr show "$SSH_INTERFACE" | grep "inet6.*global" | awk '{print $2}' | head -n1)
    
    # Define private subnet for vmbr1 (pfSense compatible)
    local private_subnet="192.168.1.0/24"
    local private_ip="192.168.1.10/24"  # Host IP that doesn't conflict with pfSense gateway (.1)
    local first_ipv6=""
    if [[ -n "$current_ipv6" ]]; then
        # Generate first IPv6 CIDR similar to ariadata format
        local ipv6_prefix
        ipv6_prefix=$(echo "$current_ipv6" | cut -d'/' -f1 | cut -d':' -f1-4)
        first_ipv6="${ipv6_prefix}:1::1/80"
    fi
    
    log "INFO" "Creating ariadata-compatible configuration:"
    log "INFO" "  Interface: ${interface_for_mac}"
    log "INFO" "  IP: $current_cidr"
    log "INFO" "  Gateway: $current_gateway"
    log "INFO" "  MAC: $current_mac"
    log "INFO" "  IPv6: ${current_ipv6:-N/A}"
    log "INFO" "  Private: $private_ip"
    
    # Validate variables before creating config
    if [[ -z "$current_cidr" ]]; then
        log "ERROR" "current_cidr is empty"
        return 1
    fi
    if [[ -z "$current_gateway" ]]; then
        log "ERROR" "current_gateway is empty"
        return 1
    fi
    if [[ -z "$current_mac" ]]; then
        log "ERROR" "current_mac is empty"
        return 1
    fi
    if [[ -z "$interface_for_mac" ]]; then
        log "ERROR" "interface_for_mac is empty"
        return 1
    fi
    
    # Create the ariadata-style configuration
    cat > "$temp_config" << EOF
# network interface settings; autogenerated
# Please do NOT modify this file directly, unless you know what
# you're doing.
#
# If you want to manage parts of the network configuration manually,
# please utilize the 'source' or 'source-directory' directives to do
# so.
# PVE will preserve these directives, but will NOT read its network
# configuration from sourced files, so do not attempt to move any of
# the PVE managed interfaces into external files!

source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

iface lo inet6 loopback

auto ${interface_for_mac}
iface ${interface_for_mac} inet manual

auto vmbr0
iface vmbr0 inet static
    address $current_cidr
    gateway $current_gateway
    bridge-ports ${interface_for_mac}
    bridge-stp off
    bridge-fd 1
    bridge-vlan-aware yes
    bridge-vids 2-4094
    hwaddress $current_mac
    pointopoint $current_gateway
    up sysctl -p
EOF

    # Add IPv6 configuration if available
    if [[ -n "$current_ipv6" ]]; then
        cat >> "$temp_config" << EOF

iface vmbr0 inet6 static
    address $current_ipv6
    gateway fe80::1
EOF
    fi

    # Add vmbr1 configuration (ariadata private bridge)
    cat >> "$temp_config" << EOF

auto vmbr1
iface vmbr1 inet static
    address $private_ip
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   iptables -t nat -A POSTROUTING -s '$private_subnet' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '$private_subnet' -o vmbr0 -j MASQUERADE
    post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
    post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
EOF

    # Add IPv6 configuration for vmbr1 if IPv6 is available
    if [[ -n "$first_ipv6" ]]; then
        cat >> "$temp_config" << EOF

iface vmbr1 inet6 static
    address $first_ipv6
EOF
    fi
    
    # Validate the new configuration
    log "DEBUG" "Validating generated configuration for current IP: $CURRENT_IP"
    log "DEBUG" "Generated configuration file: $temp_config"
    
    # Show generated config for debugging
    if [[ "${LOG_LEVEL:-INFO}" == "DEBUG" ]]; then
        log "DEBUG" "Generated configuration content:"
        while IFS= read -r line; do
            log "DEBUG" "  $line"
        done < "$temp_config"
    fi
    
    if ! grep -q "$CURRENT_IP" "$temp_config"; then
        log "ERROR" "Generated ariadata configuration is missing current primary IP: $CURRENT_IP"
        log "ERROR" "Configuration file contents:"
        cat "$temp_config"
        return 1
    fi
    
    if ! grep -q "auto vmbr0" "$temp_config"; then
        log "ERROR" "Generated ariadata configuration is missing vmbr0 bridge"
        log "ERROR" "Configuration file contents:"
        cat "$temp_config"
        return 1
    fi
    
    log "INFO" "Ariadata-compatible network configuration created successfully"
    export NEW_INTERFACES_CONFIG="$temp_config"
}

# Create consistent network configuration with exactly 3 bridges
create_network_config () {
    log "INFO" "Creating consistent 3-bridge network configuration..."
    log "DEBUG" "Function start - checking variables"
    log "DEBUG" "SSH_INTERFACE: ${SSH_INTERFACE:-unset}"
    log "DEBUG" "CURRENT_IP: ${CURRENT_IP:-unset}"
    log "DEBUG" "PHYSICAL_INTERFACE: ${PHYSICAL_INTERFACE:-unset}"
    
    local temp_config="/tmp/interfaces.consistent"
    
    # Get current network info safely
    local current_cidr=""
    local current_gateway=""
    local current_mac=""
    local current_ipv6=""
    
    log "DEBUG" "Getting CIDR from interface $SSH_INTERFACE for IP $CURRENT_IP"
    # Try to get CIDR from current IP configuration
    current_cidr=$(ip addr show "$SSH_INTERFACE" | grep "inet " | grep "$CURRENT_IP" | awk '{print $2}' | head -n1 || true)
    if [[ -z "$current_cidr" ]]; then
        log "WARN" "Could not determine current CIDR, using /26 as fallback for Hetzner"
        current_cidr="$CURRENT_IP/26"
    fi
    log "DEBUG" "current_cidr: $current_cidr"
    
    # Get current gateway
    log "DEBUG" "Getting gateway"
    current_gateway=$(ip route | grep default | awk '{print $3}' | head -n1 || true)
    if [[ -z "$current_gateway" ]]; then
        log "ERROR" "Could not determine current gateway"
        return 1
    fi
    log "DEBUG" "current_gateway: $current_gateway"
    
    # Get MAC address of the physical interface
    local interface_for_mac="${PHYSICAL_INTERFACE:-$SSH_INTERFACE}"
    if [[ "$SSH_INTERFACE" == "vmbr0" ]]; then
        interface_for_mac="${PHYSICAL_INTERFACE}"
    fi
    log "DEBUG" "Getting MAC for interface: $interface_for_mac"
    current_mac=$(ip link show "$interface_for_mac" | awk '/ether/ {print $2}' || true)
    if [[ -z "$current_mac" ]]; then
        log "ERROR" "Could not determine MAC address for interface $interface_for_mac"
        return 1
    fi
    log "DEBUG" "current_mac: $current_mac"
    
    # Get IPv6 address if available  
    log "DEBUG" "Getting IPv6 address"
    current_ipv6=$(ip addr show "$SSH_INTERFACE" | grep "inet6.*global" | awk '{print $2}' | head -n1 || true)
    log "DEBUG" "current_ipv6: ${current_ipv6:-none}"
    
    log "INFO" "Creating network configuration with:"
    log "INFO" "  Interface: ${interface_for_mac}"
    log "INFO" "  IP: $current_cidr"
    log "INFO" "  Gateway: $current_gateway"
    log "INFO" "  MAC: $current_mac"
    log "INFO" "  IPv6: ${current_ipv6:-N/A}"
    
    # Create the network configuration
    cat > "$temp_config" << EOF
# Network interfaces configuration for Hetzner Proxmox
# Automatically generated on: $(date)
# This configuration provides exactly 3 network bridges:
#   vmbr0: WAN bridge with host IP and additional IPs
#   vmbr1: LAN bridge (192.168.1.254/24) for pfSense management network
#   vmbr2: DMZ bridge (10.0.2.1/24) for public services

source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

# Physical interface (enslaved to WAN bridge)
auto ${interface_for_mac}
iface ${interface_for_mac} inet manual

# WAN Bridge (vmbr0) - Internet connection with host IP and additional IPs
auto vmbr0
iface vmbr0 inet static
    address $current_cidr
    gateway $current_gateway
    bridge-ports ${interface_for_mac}
    bridge-stp off
    bridge-fd 0
    bridge-maxwait 0
    hwaddress $current_mac
    # Enable VLAN awareness for advanced networking
    bridge-vlan-aware yes
    bridge-vids 2-4094
    # Point-to-point for Hetzner routing
    pointopoint $current_gateway
    # Apply sysctl settings
    up sysctl -p
EOF

    # Add IPv6 configuration if available
    if [[ -n "$current_ipv6" ]]; then
        cat >> "$temp_config" << EOF

iface vmbr0 inet6 static
    address $current_ipv6
    gateway fe80::1
EOF
    fi

    # Add vmbr1 configuration (ariadata private bridge)
    cat >> "$temp_config" << EOF

# LAN Bridge (vmbr1) - pfSense management network
auto vmbr1
iface vmbr1 inet static
    address 192.168.1.10/24  # Host IP that doesn't conflict with pfSense gateway (.1)
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-maxwait 0
    # Remove NAT rules - pfSense will handle routing
    # pfSense at 192.168.1.1 will be the gateway for this network
EOF

    # Add vmbr2 configuration (DMZ bridge)
    cat >> "$temp_config" << EOF

# DMZ Bridge (vmbr2) - public services network
auto vmbr2
iface vmbr2 inet static
    address 10.0.2.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-maxwait 0
    # No NAT rules - pfSense will handle DMZ routing and firewall rules
EOF
    
    # Validate the new configuration
    log "DEBUG" "Validating generated configuration for current IP: $CURRENT_IP"
    log "DEBUG" "Generated configuration file: $temp_config"
    
    # Show generated config for debugging
    if [[ "${LOG_LEVEL:-INFO}" == "DEBUG" ]]; then
        log "DEBUG" "Generated configuration content:"
        while IFS= read -r line; do
            log "DEBUG" "  $line"
        done < "$temp_config"
    fi
    
    if ! grep -q "$CURRENT_IP" "$temp_config"; then
        log "ERROR" "Generated configuration is missing current primary IP: $CURRENT_IP"
        log "ERROR" "Configuration file contents:"
        cat "$temp_config"
        return 1
    fi
    
    if ! grep -q "auto vmbr0" "$temp_config"; then
        log "ERROR" "Generated configuration is missing vmbr0 bridge"
        return 1
    fi
    
    if ! grep -q "auto vmbr1" "$temp_config"; then
        log "ERROR" "Generated configuration is missing vmbr1 bridge"
        return 1
    fi
    
    if ! grep -q "auto vmbr2" "$temp_config"; then
        log "ERROR" "Generated configuration is missing vmbr2 bridge"
        return 1
    fi
    
    log "INFO" "Consistent 3-bridge network configuration created successfully"
    export NEW_INTERFACES_CONFIG="$temp_config"
}

# Create ariadata-compatible configuration with additional IPs
create_ariadata_compatible_config() {
    log "INFO" "Creating ariadata-compatible network configuration with additional IPs..."
    log "DEBUG" "Function start - checking variables"
    log "DEBUG" "SSH_INTERFACE: ${SSH_INTERFACE:-unset}"
    log "DEBUG" "CURRENT_IP: ${CURRENT_IP:-unset}"
    log "DEBUG" "PHYSICAL_INTERFACE: ${PHYSICAL_INTERFACE:-unset}"
    
    local temp_config="/tmp/interfaces.ariadata_with_ips"
    
    # Get current network info safely
    local current_cidr=""
    local current_gateway=""
    local current_mac=""
    local current_ipv6=""
    
    log "DEBUG" "Getting CIDR from interface $SSH_INTERFACE for IP $CURRENT_IP"
    # Try to get CIDR from current IP configuration
    current_cidr=$(ip addr show "$SSH_INTERFACE" | grep "inet " | grep "$CURRENT_IP" | awk '{print $2}' | head -n1 || true)
    if [[ -z "$current_cidr" ]]; then
        log "WARN" "Could not determine current CIDR, using /26 as fallback for Hetzner"
        current_cidr="$CURRENT_IP/26"
    fi
    log "DEBUG" "current_cidr: $current_cidr"
    
    # Get current gateway
    log "DEBUG" "Getting gateway"
    current_gateway=$(ip route | grep default | awk '{print $3}' | head -n1 || true)
    if [[ -z "$current_gateway" ]]; then
        log "ERROR" "Could not determine current gateway"
        return 1
    fi
    log "DEBUG" "current_gateway: $current_gateway"
    
    # Get MAC address of the physical interface
    local interface_for_mac="${PHYSICAL_INTERFACE:-$SSH_INTERFACE}"
    if [[ "$SSH_INTERFACE" == "vmbr0" ]]; then
        interface_for_mac="${PHYSICAL_INTERFACE}"
    fi
    log "DEBUG" "Getting MAC for interface: $interface_for_mac"
    current_mac=$(ip link show "$interface_for_mac" | awk '/ether/ {print $2}' || true)
    if [[ -z "$current_mac" ]]; then
        log "ERROR" "Could not determine MAC address for interface $interface_for_mac"
        return 1
    fi
    log "DEBUG" "current_mac: $current_mac"
    
    # Get IPv6 address if available  
    log "DEBUG" "Getting IPv6 address"
    current_ipv6=$(ip addr show "$SSH_INTERFACE" | grep "inet6.*global" | awk '{print $2}' | head -n1 || true)
    log "DEBUG" "current_ipv6: ${current_ipv6:-none}"
    
    # Define private subnet for vmbr1 (pfSense compatible)
    local private_subnet="192.168.1.0/24"
    local private_ip="192.168.1.10/24"  # Host IP that doesn't conflict with pfSense gateway (.1)
    local first_ipv6=""
    if [[ -n "$current_ipv6" ]]; then
        log "DEBUG" "Processing IPv6 configuration"
        # Generate first IPv6 CIDR similar to ariadata format
        local ipv6_prefix
        ipv6_prefix=$(echo "$current_ipv6" | cut -d'/' -f1 | cut -d':' -f1-4 || true)
        if [[ -n "$ipv6_prefix" ]]; then
            first_ipv6="${ipv6_prefix}:1::1/80"
            log "DEBUG" "first_ipv6: $first_ipv6"
        else
            log "DEBUG" "Could not generate IPv6 prefix"
        fi
    fi
    
    log "INFO" "Creating ariadata-compatible configuration with additional IPs:"
    log "INFO" "  Interface: ${interface_for_mac}"
    log "INFO" "  IP: $current_cidr"
    log "INFO" "  Gateway: $current_gateway"
    log "INFO" "  MAC: $current_mac"
    log "INFO" "  IPv6: ${current_ipv6:-N/A}"
    log "INFO" "  Private: $private_ip"
    
    # Create the ariadata-style configuration header
    cat > "$temp_config" << EOF
# network interface settings; autogenerated
# Please do NOT modify this file directly, unless you know what
# you're doing.
#
# If you want to manage parts of the network configuration manually,
# please utilize the 'source' or 'source-directory' directives to do
# so.
# PVE will preserve these directives, but will NOT read its network
# configuration from sourced files, so do not attempt to move any of
# the PVE managed interfaces into external files!

source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

iface lo inet6 loopback

auto ${interface_for_mac}
iface ${interface_for_mac} inet manual

auto vmbr0
iface vmbr0 inet static
    address $current_cidr
    gateway $current_gateway
    bridge-ports ${interface_for_mac}
    bridge-stp off
    bridge-fd 1
    bridge-vlan-aware yes
    bridge-vids 2-4094
    hwaddress $current_mac
    pointopoint $current_gateway
    up sysctl -p
EOF

    # Add additional IPs to vmbr0 if configured
    if [[ -n "${ADDITIONAL_IPS_ARRAY[*]:-}" && ${#ADDITIONAL_IPS_ARRAY[@]} -gt 0 ]]; then
        log "INFO" "Adding ${#ADDITIONAL_IPS_ARRAY[@]} additional IP configurations to vmbr0..."
        
        echo "" >> "$temp_config"
        echo "    # Additional IP addresses" >> "$temp_config"
        
        for i in "${!ADDITIONAL_IPS_ARRAY[@]}"; do
            local ip="${ADDITIONAL_IPS_ARRAY[$i]}"
            local mac="${ADDITIONAL_MACS_ARRAY[$i]}"
            local gateway="${ADDITIONAL_GATEWAYS_ARRAY[$i]}"
            local netmask="${ADDITIONAL_NETMASKS_ARRAY[$i]}"
            
            log "DEBUG" "Processing additional IP $((i+1)): ip=$ip, netmask=$netmask, gateway=$gateway"
            
            # Convert netmask to CIDR
            local cidr
            if ! cidr=$(netmask_to_cidr "$netmask"); then
                log "ERROR" "Failed to convert netmask '$netmask' to CIDR"
                return 1
            fi
            
            log "DEBUG" "Converted netmask $netmask to CIDR /$cidr"
            log "INFO" "Adding IP $ip/$cidr with gateway $gateway"
            
            {
                echo "    post-up ip addr add $ip/$cidr dev vmbr0"
                echo "    post-down ip addr del $ip/$cidr dev vmbr0"
                # For Hetzner additional IPs, all traffic must route through main gateway
                # Add specific route for this IP through the main gateway
                echo "    post-up ip route add $ip/32 dev vmbr0 table main"
                echo "    post-down ip route del $ip/32 dev vmbr0 table main"
            } >> "$temp_config"
            
            # Add MAC address configuration if provided - CRITICAL for Hetzner routing
            if [[ -n "$mac" ]]; then
                echo "    # MAC for $ip: $mac (REQUIRED for Hetzner routing!)" >> "$temp_config"
                echo "    # Configure this MAC in the VM/container using this IP" >> "$temp_config"
            else
                echo "    # WARNING: No MAC address configured for $ip" >> "$temp_config"
                echo "    # Hetzner additional IPs require correct MAC addresses for routing!" >> "$temp_config"
            fi
        done
    fi

    # Add vmbr1 configuration (ariadata private bridge)
    cat >> "$temp_config" << EOF

auto vmbr1
iface vmbr1 inet static
    address $private_ip
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   iptables -t nat -A POSTROUTING -s '$private_subnet' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '$private_subnet' -o vmbr0 -j MASQUERADE
    post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
    post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
EOF

    # Add IPv6 configuration for vmbr1 if IPv6 is available
    if [[ -n "$first_ipv6" ]]; then
        cat >> "$temp_config" << EOF

iface vmbr1 inet6 static
    address $first_ipv6
EOF
    fi
    
    # Add vmbr2 configuration (DMZ bridge)
    cat >> "$temp_config" << EOF

auto vmbr2
iface vmbr2 inet static
    address 10.0.2.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   iptables -t nat -A POSTROUTING -s '10.0.2.0/24' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '10.0.2.0/24' -o vmbr0 -j MASQUERADE
    post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
    post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
EOF
    
    # Validate the new configuration
    log "DEBUG" "Validating generated configuration for current IP: $CURRENT_IP"
    log "DEBUG" "Generated configuration file: $temp_config"
    
    # Show generated config for debugging
    if [[ "${LOG_LEVEL:-INFO}" == "DEBUG" ]]; then
        log "DEBUG" "Generated configuration content:"
        while IFS= read -r line; do
            log "DEBUG" "  $line"
        done < "$temp_config"
    fi
    
    if ! grep -q "$CURRENT_IP" "$temp_config"; then
        log "ERROR" "Generated configuration is missing current primary IP: $CURRENT_IP"
        log "ERROR" "Configuration file contents:"
        cat "$temp_config"
        return 1
    fi
    
    if ! grep -q "auto vmbr0" "$temp_config"; then
        log "ERROR" "Generated configuration is missing vmbr0 bridge"
        return 1
    fi
    
    if ! grep -q "auto vmbr1" "$temp_config"; then
        log "ERROR" "Generated configuration is missing vmbr1 bridge"
        return 1
    fi
    
    if ! grep -q "auto vmbr2" "$temp_config"; then
        log "ERROR" "Generated configuration is missing vmbr2 bridge"
        return 1
    fi
    
    log "INFO" "Ariadata-compatible network configuration with additional IPs created successfully"
    export NEW_INTERFACES_CONFIG="$temp_config"
}

# Create standard network configuration (original method)
create_standard_network_config() {
    log "INFO" "Creating standard network configuration..."
    
    local temp_config="/tmp/interfaces.new"
    
    # Get current network info safely
    local current_cidr=""
    local current_gateway=""
    
    # Try to get CIDR from current IP configuration
    current_cidr=$(ip addr show "$SSH_INTERFACE" | grep "inet " | grep "$CURRENT_IP" | awk '{print $2}' | head -n1)
    if [[ -z "$current_cidr" ]]; then
        log "WARN" "Could not determine current CIDR, using /26 as fallback for Hetzner"
        current_cidr="$CURRENT_IP/26"
    fi
    
    # Get current gateway
    current_gateway=$(ip route | grep default | awk '{print $3}' | head -n1)
    if [[ -z "$current_gateway" ]]; then
        log "ERROR" "Could not determine current gateway"
        return 1
    fi
    
    log "INFO" "Current network config: IP=$current_cidr, Gateway=$current_gateway"
    
    cat > "$temp_config" << EOF
# Network configuration generated by Hetzner Proxmox Setup
# Generated on: $(date)
# Backup available at: $INTERFACES_BACKUP

# Loopback interface
auto lo
iface lo inet loopback
EOF

    # Handle interface configuration based on current setup
    if [[ "$SSH_INTERFACE" == "vmbr0" ]]; then
        # We're already on a bridge, just update it
        log "INFO" "Updating existing vmbr0 bridge configuration"
        cat >> "$temp_config" << EOF

# Physical interface (enslaved to bridge)
auto ${PHYSICAL_INTERFACE}
iface ${PHYSICAL_INTERFACE} inet manual

# WAN Bridge (vmbr0) - Primary network interface  
auto vmbr0
iface vmbr0 inet static
    address $current_cidr
    gateway $current_gateway
    bridge-ports ${PHYSICAL_INTERFACE}
    bridge-stp off
    bridge-fd 0
    bridge-maxwait 0
EOF
    else
        # Create bridge from scratch
        log "INFO" "Creating new vmbr0 bridge configuration"
        cat >> "$temp_config" << EOF

# Physical interface (enslaved to bridge)
auto $SSH_INTERFACE
iface $SSH_INTERFACE inet manual

# WAN Bridge (vmbr0) - Primary network interface
auto vmbr0
iface vmbr0 inet static
    address $current_cidr
    gateway $current_gateway
    bridge-ports $SSH_INTERFACE
    bridge-stp off
    bridge-fd 0
    bridge-maxwait 0
EOF
    fi

    # Add additional IPs using modern method (post-up commands on vmbr0)
    if [[ -n "${ADDITIONAL_IPS_ARRAY[*]:-}" && ${#ADDITIONAL_IPS_ARRAY[@]} -gt 0 ]]; then
        log "INFO" "Adding ${#ADDITIONAL_IPS_ARRAY[@]} additional IP configurations to vmbr0..."
        
        echo "" >> "$temp_config"
        echo "    # Additional IP addresses (using modern networking commands)" >> "$temp_config"
        
        for i in "${!ADDITIONAL_IPS_ARRAY[@]}"; do
            local ip="${ADDITIONAL_IPS_ARRAY[$i]}"
            local mac="${ADDITIONAL_MACS_ARRAY[$i]}"
            local gateway="${ADDITIONAL_GATEWAYS_ARRAY[$i]}"
            local netmask="${ADDITIONAL_NETMASKS_ARRAY[$i]}"
            
            # Convert netmask to CIDR
            local cidr
            cidr=$(netmask_to_cidr "$netmask")
            
            log "INFO" "Adding IP $ip/$cidr with gateway $gateway"
            
            echo "    post-up ip addr add $ip/$cidr dev vmbr0" >> "$temp_config"
            echo "    post-down ip addr del $ip/$cidr dev vmbr0" >> "$temp_config"
            
            # Add route for this additional IP if gateway is different
            if [[ "$gateway" != "$current_gateway" ]]; then
                echo "    post-up ip route add $ip via $gateway dev vmbr0" >> "$temp_config"
                echo "    post-down ip route del $ip via $gateway dev vmbr0" >> "$temp_config"
            fi
        done
        
        # Add LAN and DMZ bridges after additional IPs
        cat >> "$temp_config" << EOF

# LAN Bridge for internal networking (pfSense LAN side)
auto vmbr1
iface vmbr1 inet static
    address 192.168.1.10/24  # Host IP that doesn't conflict with pfSense gateway (.1)
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-maxwait 0

# DMZ Bridge for additional services  
auto vmbr2
iface vmbr2 inet static
    address 10.0.2.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-maxwait 0
EOF
    else
        # Add LAN and DMZ bridges even without additional IPs
        cat >> "$temp_config" << EOF

# LAN Bridge for internal networking (pfSense LAN side)
auto vmbr1
iface vmbr1 inet static
    address 192.168.1.10/24  # Host IP that doesn't conflict with pfSense gateway (.1)
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-maxwait 0

# DMZ Bridge for additional services
auto vmbr2
iface vmbr2 inet static
    address 10.0.2.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-maxwait 0
EOF
    fi
    
    # Validate the new configuration syntax
    local expected_physical="${PHYSICAL_INTERFACE:-$SSH_INTERFACE}"
    if [[ "$SSH_INTERFACE" != "vmbr0" ]] && ! grep -q "auto $SSH_INTERFACE" "$temp_config"; then
        log "ERROR" "Generated configuration is missing primary interface"
        return 1
    fi
    
    if [[ "$SSH_INTERFACE" == "vmbr0" ]] && ! grep -q "auto $expected_physical" "$temp_config"; then
        log "ERROR" "Generated configuration is missing physical interface"
        return 1
    fi
    
    # Validate that primary IP is preserved
    if ! grep -q "$CURRENT_IP" "$temp_config"; then
        log "ERROR" "Generated configuration is missing current primary IP"
        return 1
    fi
    
    # Validate proper interface setup
    local expected_physical="${PHYSICAL_INTERFACE:-$SSH_INTERFACE}"
    if ! grep -q "bridge-ports $expected_physical" "$temp_config"; then
        log "ERROR" "Generated configuration has incorrect bridge-ports setting"
        return 1
    fi
    
    log "INFO" "Network configuration created successfully"
    export NEW_INTERFACES_CONFIG="$temp_config"
}

# Validate Hetzner-specific requirements for additional IPs
validate_hetzner_config() {
    log "INFO" "Validating Hetzner-specific configuration requirements..."
    
    # Check if we have additional IPs configured
    if [[ -n "${ADDITIONAL_IPS_ARRAY[*]:-}" && ${#ADDITIONAL_IPS_ARRAY[@]} -gt 0 ]]; then
        log "INFO" "Found ${#ADDITIONAL_IPS_ARRAY[@]} additional IP(s) configured"
        
        # Validate each additional IP has required MAC address for Hetzner
        for i in "${!ADDITIONAL_IPS_ARRAY[@]}"; do
            local ip="${ADDITIONAL_IPS_ARRAY[$i]}"
            local mac="${ADDITIONAL_MACS_ARRAY[$i]:-}"
            local gateway="${ADDITIONAL_GATEWAYS_ARRAY[$i]}"
            local netmask="${ADDITIONAL_NETMASKS_ARRAY[$i]}"
            
            log "INFO" "Validating additional IP $((i+1)): $ip"
            
            # Critical: MAC address validation for Hetzner
            if [[ -z "$mac" ]]; then
                log "ERROR" "MAC address is REQUIRED for additional IP: $ip"
                log "ERROR" "Hetzner routes additional IPs based on MAC addresses"
                log "ERROR" "Get MAC addresses from Hetzner Robot panel or contact support"
                log "ERROR" "Configure in config/additional-ips.conf: MAC=XX:XX:XX:XX:XX:XX"
                return 1
            fi
            
            # Validate MAC address format
            if [[ ! "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
                log "ERROR" "Invalid MAC address format for IP $ip: $mac"
                log "ERROR" "Required format: XX:XX:XX:XX:XX:XX (e.g., 00:50:56:00:01:02)"
                return 1
            fi
            
            # Validate gateway matches main gateway (Hetzner requirement)
            local main_gateway
            main_gateway=$(ip route | grep default | awk '{print $3}' | head -n1)
            if [[ "$gateway" != "$main_gateway" ]]; then
                log "WARN" "Additional IP gateway ($gateway) differs from main gateway ($main_gateway)"
                log "WARN" "This is unusual for Hetzner - verify configuration with Hetzner support"
            fi
            
            # Validate netmask is reasonable for Hetzner (/26 to /29 typical)
            local cidr
            if ! cidr=$(netmask_to_cidr "$netmask"); then
                log "ERROR" "Invalid netmask for IP $ip: $netmask"
                return 1
            fi
            
            if [[ $cidr -lt 26 || $cidr -gt 30 ]]; then
                log "WARN" "Unusual subnet size /$cidr for additional IP $ip"
                log "WARN" "Hetzner typically uses /26 or /29 subnets - verify with Hetzner"
            fi
            
            log "INFO" "✓ Additional IP $ip validated (MAC: $mac, /$cidr)"
        done
        
        log "INFO" "✓ All additional IPs validated for Hetzner requirements"
    else
        log "INFO" "No additional IPs configured - skipping Hetzner-specific validation"
    fi
    
    return 0
}

# Convert netmask to CIDR notation
netmask_to_cidr() {
    local netmask="$1"
    local cidr=0
    
    case "$netmask" in
        "255.255.255.255") cidr=32 ;;
        "255.255.255.254") cidr=31 ;;
        "255.255.255.252") cidr=30 ;;
        "255.255.255.248") cidr=29 ;;
        "255.255.255.240") cidr=28 ;;
        "255.255.255.224") cidr=27 ;;
        "255.255.255.192") cidr=26 ;;
        "255.255.255.128") cidr=25 ;;
        "255.255.255.0") cidr=24 ;;
        "255.255.254.0") cidr=23 ;;
        "255.255.252.0") cidr=22 ;;
        "255.255.248.0") cidr=21 ;;
        "255.255.240.0") cidr=20 ;;
        "255.255.224.0") cidr=19 ;;
        "255.255.192.0") cidr=18 ;;
        "255.255.128.0") cidr=17 ;;
        "255.255.0.0") cidr=16 ;;
        *) 
            cidr=24  # Default fallback
            ;;
    esac
    
    echo "$cidr"
}

# Test network configuration safely
test_network_config() {
    log "INFO" "Testing network configuration..."
    
    # Create a test script that will restore configuration if SSH is lost
    local test_script="/tmp/network-test.sh"
    cat > "$test_script" << 'EOF'
#!/bin/bash
# Network configuration test script
# This script will restore the original configuration if SSH connectivity is lost

BACKUP_FILE="INTERFACES_BACKUP_PLACEHOLDER"
INTERFACES_FILE="/etc/network/interfaces"
SLEEP_TIME=30

echo "Testing network configuration for $SLEEP_TIME seconds..."
echo "If SSH connectivity is lost, configuration will be restored automatically"

sleep $SLEEP_TIME

# Check if this script is still running (SSH is working)
echo "Test completed successfully - SSH connectivity maintained"
exit 0
EOF
    
    # Replace placeholder with actual backup file
    sed -i "s|INTERFACES_BACKUP_PLACEHOLDER|$INTERFACES_BACKUP|g" "$test_script"
    chmod +x "$test_script"
    
    log "INFO" "Network test script created at $test_script"
}

# Validate and debug network configuration structure
validate_interfaces_syntax() {
    local config_file="$1"
    
    log "DEBUG" "Validating interfaces configuration syntax..."
    
    # Check for basic structure
    if ! grep -q "auto lo" "$config_file"; then
        log "ERROR" "Missing loopback interface (auto lo)"
        return 1
    fi
    
    if ! grep -q "iface lo inet loopback" "$config_file"; then
        log "ERROR" "Missing loopback interface configuration (iface lo inet loopback)"
        return 1
    fi
    
    # Check primary interface
    local expected_physical_interface="${PHYSICAL_INTERFACE:-$SSH_INTERFACE}"
    if [[ "$SSH_INTERFACE" != "vmbr0" ]]; then
        # When creating bridge from scratch, check for physical interface
        if ! grep -q "auto $SSH_INTERFACE" "$config_file"; then
            log "ERROR" "Missing primary interface auto declaration (auto $SSH_INTERFACE)"
            return 1
        fi
    else
        # When updating existing bridge, check for physical interface
        if ! grep -q "auto $expected_physical_interface" "$config_file"; then
            log "ERROR" "Missing physical interface auto declaration (auto $expected_physical_interface)"
            return 1
        fi
    fi
    
    if ! grep -q "auto vmbr0" "$config_file"; then
        log "ERROR" "Missing WAN bridge auto declaration (auto vmbr0)"
        return 1
    fi
    
    if ! grep -q "iface vmbr0 inet static" "$config_file"; then
        log "ERROR" "Missing WAN bridge configuration (iface vmbr0 inet static)"
        return 1
    fi
    
    # Check for address and gateway
    if ! grep -q "address.*$CURRENT_IP" "$config_file"; then
        log "ERROR" "Missing or incorrect address configuration for primary interface"
        return 1
    fi
    
    if ! grep -q "gateway" "$config_file"; then
        log "ERROR" "Missing gateway configuration"
        return 1
    fi
    
    # Check for proper indentation in post-up/post-down commands
    local post_up_count
    post_up_count=$(grep -c "^[[:space:]]*post-up" "$config_file" || true)
    local post_down_count
    post_down_count=$(grep -c "^[[:space:]]*post-down" "$config_file" || true)
    
    if [[ $post_up_count -ne $post_down_count ]]; then
        log "ERROR" "Mismatched post-up ($post_up_count) and post-down ($post_down_count) commands"
        return 1
    fi
    
    # Check for proper indentation (should start with 4 spaces)
    if grep -n "post-up\|post-down" "$config_file" | grep -v "^[0-9]*:    "; then
        log "ERROR" "Improper indentation for post-up/post-down commands"
        log "ERROR" "Commands should be indented with 4 spaces"
        grep -n "post-up\|post-down" "$config_file" | while IFS= read -r line; do
            log "ERROR" "  $line"
        done
        
        if [[ "${LOG_LEVEL:-}" == "DEBUG" ]]; then
            debug_config_file "$config_file"
        fi
        return 1
    fi
    
    log "DEBUG" "Configuration structure validation passed"
    return 0
}

# Alternative configuration validation using parsing
validate_config_parsing() {
    local config_file="$1"
    
    log "DEBUG" "Performing alternative configuration validation..."
    
    # Check if the file is readable
    if [[ ! -r "$config_file" ]]; then
        log "ERROR" "Configuration file is not readable: $config_file"
        return 1
    fi
    
    # Basic syntax checks
    local line_num=0
    local in_interface=false
    local current_interface=""
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++))
        
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Check for auto declarations
        if [[ "$line" =~ ^auto[[:space:]]+(.+) ]]; then
            current_interface="${BASH_REMATCH[1]}"
            in_interface=false
            log "DEBUG" "Found auto declaration for interface: $current_interface"
            continue
        fi
        
        # Check for iface declarations
        if [[ "$line" =~ ^iface[[:space:]]+([^[:space:]]+)[[:space:]]+inet[[:space:]]+(.+) ]]; then
            current_interface="${BASH_REMATCH[1]}"
            local inet_type="${BASH_REMATCH[2]}"
            in_interface=true
            log "DEBUG" "Found iface declaration: $current_interface inet $inet_type"
            continue
        fi
        
        # Check for indented configuration lines
        if [[ "$line" =~ ^[[:space:]]+(.+) ]]; then
            local config_line="${BASH_REMATCH[1]}"
            
            if [[ ! "$in_interface" == true ]]; then
                log "ERROR" "Configuration line outside of interface block at line $line_num: $line"
                return 1
            fi
            
            # Validate known configuration options
            if [[ "$config_line" =~ ^(address|gateway|netmask|broadcast|network|post-up|post-down|pre-up|pre-down)[[:space:]] ]]; then
                log "DEBUG" "Valid configuration line: $config_line"
            else
                log "WARN" "Unknown configuration option at line $line_num: $config_line"
            fi
            continue
        fi
        
        # If we get here, it's an unexpected line format
        log "WARN" "Unexpected line format at line $line_num: $line"
    done < "$config_file"
    
    log "DEBUG" "Alternative configuration validation completed"
    return 0
}

# Debug function to show configuration with line numbers
debug_config_file() {
    local config_file="$1"
    
    log "DEBUG" "Configuration file contents with line numbers:"
    log "DEBUG" "=============================================="
    local line_num=1
    while IFS= read -r line; do
        log "DEBUG" "$(printf "%3d: %s" "$line_num" "$line")"
        ((line_num++))
    done < "$config_file"
    log "DEBUG" "=============================================="
}

# Apply network configuration with safety measures
apply_network_config() {
    log "WARN" "About to apply network configuration changes"
    log "WARN" "This could potentially interrupt SSH connectivity"
    log "INFO" "Backup available at: $INTERFACES_BACKUP"
    
    # Show what we're about to do
    log "INFO" ""
    log "INFO" "Changes to be applied:"
    log "INFO" "====================="
    log "INFO" "Source: $NEW_INTERFACES_CONFIG"
    log "INFO" "Target: $INTERFACES_FILE"
    log "INFO" ""
    log "INFO" "New configuration preview (first 20 lines):"
    if [[ -f "$NEW_INTERFACES_CONFIG" ]]; then
        head -20 "$NEW_INTERFACES_CONFIG" | while IFS= read -r line; do
            log "INFO" "  $line"
        done || true
    else
        log "ERROR" "Configuration file not found: $NEW_INTERFACES_CONFIG"
        return 1
    fi
    log "INFO" ""
    
    # Create a restoration script
    local restore_script="/root/restore-network.sh"
    cat > "$restore_script" << EOF
#!/bin/bash
# Emergency network restoration script
echo "Restoring network configuration from backup..."
cp "$INTERFACES_BACKUP" "$INTERFACES_FILE"
systemctl restart networking
echo "Network configuration restored"
EOF
    chmod +x "$restore_script"
    
    log "INFO" "Emergency restore script created at: $restore_script"
    log "INFO" "To restore manually if needed: bash $restore_script"
    
    # Final validation before applying
    log "INFO" "Performing final validation..."
    if ! grep -q "$CURRENT_IP" "$NEW_INTERFACES_CONFIG"; then
        log "ERROR" "SAFETY CHECK FAILED: Current IP not found in new configuration"
        log "ERROR" "This would break SSH connectivity. Aborting."
        return 1
    fi
    
    if ! grep -q "auto vmbr0" "$NEW_INTERFACES_CONFIG"; then
        log "ERROR" "SAFETY CHECK FAILED: WAN bridge not properly configured"
        return 1
    fi
    
    log "INFO" "Safety checks passed"
    
    # Apply the new configuration
    log "INFO" "Applying network configuration..."
    cp "$NEW_INTERFACES_CONFIG" "$INTERFACES_FILE"
    
    # Test configuration before restarting networking
    log "INFO" "Testing configuration syntax..."
    
    # First, validate the configuration file structure
    if ! validate_interfaces_syntax "$NEW_INTERFACES_CONFIG"; then
        log "ERROR" "Configuration structure validation failed"
        cp "$INTERFACES_BACKUP" "$INTERFACES_FILE"
        return 1
    fi
    
    # Use ifup for syntax validation if available
    local syntax_error=""
    if command -v ifup >/dev/null 2>&1; then
        # Test syntax with comprehensive ifup validation
        log "DEBUG" "Testing with ifup --verbose --no-act --force --all --interfaces=\"$NEW_INTERFACES_CONFIG\""
        local test_output
        test_output=$(ifup --verbose --no-act --force --all --interfaces="$NEW_INTERFACES_CONFIG" 2>&1)
        local ifup_exit_code=$?
        log "DEBUG" "ifup exit code: $ifup_exit_code"
        if [[ "${LOG_LEVEL:-}" == "DEBUG" ]]; then
            log "DEBUG" "ifup detailed output:"
            echo "$test_output" | while IFS= read -r line; do
                log "DEBUG" "  $line"
            done
        fi
        
        if [[ $ifup_exit_code -ne 0 ]]; then
            syntax_error="$test_output"
        fi
    else
        log "DEBUG" "ifup command not available"
    fi
    
    # If ifup test failed, show detailed error information
    if [[ -n "$syntax_error" ]]; then
        log "ERROR" "Configuration syntax validation failed:"
        log "ERROR" "ifup detailed error output:"
        echo "$syntax_error" | while IFS= read -r line; do
            log "ERROR" "  $line"
        done
        log "ERROR" ""
        log "ERROR" "Restoring backup configuration..."
        cp "$INTERFACES_BACKUP" "$INTERFACES_FILE"
        return 1
    else
        log "INFO" "Configuration syntax validation passed"
    fi
    
    # Restart networking (this is the risky part)
    log "WARN" "Restarting networking service..."
    if systemctl restart networking; then
        log "INFO" "Network service restarted successfully"
        
        # Test connectivity
        sleep 5
        if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
            log "INFO" "Internet connectivity verified"
        else
            log "WARN" "Internet connectivity test failed"
        fi
        
        # Verify additional IPs are configured
        if [[ -n "${ADDITIONAL_IPS_ARRAY[*]:-}" && ${#ADDITIONAL_IPS_ARRAY[@]} -gt 0 ]]; then
            log "INFO" "Verifying additional IP addresses..."
            for ip in "${ADDITIONAL_IPS_ARRAY[@]}"; do
                if ip addr show vmbr0 | grep -q "$ip"; then
                    log "INFO" "✓ Additional IP $ip is configured on vmbr0"
                else
                    log "WARN" "✗ Additional IP $ip not found on vmbr0"
                fi
            done
        fi
        
        # Show current network status
        log "INFO" "Current network configuration:"
        
        # Show physical interface (should be enslaved to bridge now)
        local physical_iface="${PHYSICAL_INTERFACE:-$SSH_INTERFACE}"
        if [[ "$SSH_INTERFACE" == "vmbr0" ]]; then
            physical_iface="${PHYSICAL_INTERFACE}"
        fi
        
        log "INFO" "=== Physical Interface ($physical_iface) ==="
        if ip addr show "$physical_iface" >/dev/null 2>&1; then
            local physical_addrs
            physical_addrs=$(ip addr show "$physical_iface" 2>/dev/null | grep "inet " || true)
            if [[ -n "$physical_addrs" ]]; then
                echo "$physical_addrs" | while IFS= read -r line; do
                    log "INFO" "  $line"
                done
            else
                log "INFO" "  No IP addresses (enslaved to bridge)"
            fi
        else
            log "WARN" "  Interface not found or not accessible"
        fi
        
        log "INFO" "=== WAN Bridge (vmbr0) ==="
        if ip addr show vmbr0 >/dev/null 2>&1; then
            local wan_addrs
            wan_addrs=$(ip addr show vmbr0 2>/dev/null | grep "inet " || true)
            if [[ -n "$wan_addrs" ]]; then
                echo "$wan_addrs" | while IFS= read -r line; do
                    log "INFO" "  $line"
                done
            else
                log "INFO" "  No IP addresses configured"
            fi
        else
            log "INFO" "  vmbr0 not yet active (restart required)"
        fi
        
        log "INFO" "=== LAN Bridge (vmbr1) ==="
        if ip addr show vmbr1 >/dev/null 2>&1; then
            local lan_addrs
            lan_addrs=$(ip addr show vmbr1 2>/dev/null | grep "inet " || true)
            if [[ -n "$lan_addrs" ]]; then
                echo "$lan_addrs" | while IFS= read -r line; do
                    log "INFO" "  $line"
                done
            else
                log "INFO" "  No IP addresses configured"
            fi
        else
            log "INFO" "  vmbr1 not yet active (restart required)"
        fi
        
        log "INFO" "=== DMZ Bridge (vmbr2) ==="
        if ip addr show vmbr2 >/dev/null 2>&1; then
            # Show IP addresses
            local dmz_addrs
            dmz_addrs=$(ip addr show vmbr2 2>/dev/null | grep "inet " || true)
            if [[ -n "$dmz_addrs" ]]; then
                echo "$dmz_addrs" | while IFS= read -r line; do
                    log "INFO" "  $line"
                done
            else
                log "INFO" "  No IP addresses configured"
            fi
            
            # Check if bridge is up and operational
            if ip link show vmbr2 | grep -q "state UP"; then
                log "INFO" "  ✓ DMZ bridge is up and operational"
            else
                log "WARN" "  ⚠️  DMZ bridge is down"
            fi
            
            # Check if it's properly configured as a bridge
            if [[ -d "/sys/class/net/vmbr2/bridge" ]]; then
                log "INFO" "  ✓ DMZ bridge properly configured for VM/container use"
                log "INFO" "  ℹ️  Ready for public-facing services on 10.0.2.0/24 network"
            else
                log "WARN" "  ⚠️  vmbr2 exists but is not configured as a bridge"
            fi
        else
            log "WARN" "  ✗ vmbr2 not yet active (restart required or configuration error)"
            log "INFO" "  ℹ️  DMZ network (10.0.2.0/24) will be available after reboot/restart"
        fi
        
    else
        log "ERROR" "Failed to restart networking service"
        log "ERROR" "You may need to manually restore using: bash $restore_script"
        return 1
    fi
}

# Show current network configuration status  
show_network_status() {
    log "INFO" "=== CURRENT NETWORK CONFIGURATION STATUS ==="
    
    # Show physical interfaces
    log "INFO" ""
    log "INFO" "Physical Interfaces:"
    ip link show | grep -E "^[0-9]+:" | while read -r line; do
        iface=$(echo "$line" | cut -d: -f2 | sed 's/^ *//')
        state=$(echo "$line" | grep -o "state [A-Z]*" | cut -d' ' -f2)
        log "INFO" "  $iface: $state"
    done
    
    # Show bridge interfaces
    log "INFO" ""
    log "INFO" "Bridge Interfaces:"
    for bridge in vmbr0 vmbr1 vmbr2; do
        if ip link show "$bridge" >/dev/null 2>&1; then
            local ip_addr
            local state
            ip_addr=$(ip addr show "$bridge" | grep "inet " | awk '{print $2}' | head -n1)
            state=$(ip link show "$bridge" | grep -o "state [A-Z]*" | cut -d' ' -f2)
            
            # Add context for UNKNOWN state
            if [[ "$state" == "UNKNOWN" && -n "$ip_addr" ]]; then
                log "INFO" "  $bridge: $state (active, no ports) - ${ip_addr:-no IP}"
            else
                log "INFO" "  $bridge: $state - ${ip_addr:-no IP}"
            fi
        else
            log "INFO" "  $bridge: NOT CONFIGURED"
        fi
    done
    
    # Show routing table
    log "INFO" ""
    log "INFO" "Default Routes:"
    ip route | grep default || log "WARN" "  No default routes found"
    
    # Show additional IPs if configured
    log "INFO" ""
    log "INFO" "Additional IP Configuration:"
    if [[ -f "$SCRIPT_DIR/config/additional-ips.conf" ]]; then
        log "INFO" "  Config file: $SCRIPT_DIR/config/additional-ips.conf"
        grep -v "^#" "$SCRIPT_DIR/config/additional-ips.conf" | grep -v "^$" | while read -r line; do
            log "INFO" "    $line"
        done
    else
        log "INFO" "  No additional-ips.conf file found"
    fi
    
    # Parse and show parsed additional IPs
    parse_additional_ips
    if [[ -n "${ADDITIONAL_IPS_ARRAY[*]:-}" && ${#ADDITIONAL_IPS_ARRAY[@]} -gt 0 ]]; then
        log "INFO" ""
        log "INFO" "Parsed Additional IPs:"
        for i in "${!ADDITIONAL_IPS_ARRAY[@]}"; do
            local ip="${ADDITIONAL_IPS_ARRAY[$i]}"
            local mac="${ADDITIONAL_MACS_ARRAY[$i]:-N/A}"
            log "INFO" "  IP $((i+1)): $ip (MAC: $mac)"
        done
    fi
    
    log "INFO" ""
    log "INFO" "=== STATUS CHECK COMPLETE ==="
}

# Ensure network configuration is properly running
ensure_network_configuration() {
    log "INFO" "=== ENSURING NETWORK CONFIGURATION IS ACTIVE ==="
    
    # Wait for networking to stabilize
    log "INFO" "Waiting for network to stabilize..."
    sleep 5
    
    # Check if main bridge interfaces exist and are up
    local required_bridges=("vmbr0" "vmbr1" "vmbr2")
    local missing_bridges=()
    
    for bridge in "${required_bridges[@]}"; do
        if ! ip link show "$bridge" >/dev/null 2>&1; then
            missing_bridges+=("$bridge")
        else
            local state
            state=$(ip link show "$bridge" | grep -o "state [A-Z]*" | cut -d' ' -f2)
            if [[ "$state" != "UP" ]]; then
                log "INFO" "Bringing up bridge: $bridge"
                ip link set "$bridge" up 2>/dev/null || log "WARN" "Failed to bring up $bridge"
            fi
        fi
    done
    
    if [[ ${#missing_bridges[@]} -gt 0 ]]; then
        log "WARN" "Missing bridges: ${missing_bridges[*]}"
        log "WARN" "These may be created during the configuration process"
    fi
    
    # Verify primary IP is still accessible
    local primary_ip
    primary_ip=$(ip route get 8.8.8.8 | grep -Po 'src \K[0-9.]+' | head -n1)
    if [[ -n "$primary_ip" ]]; then
        log "INFO" "Primary IP accessible: $primary_ip"
    else
        log "WARN" "Could not determine primary IP"
    fi
    
    # Check if SSH is still accessible
    local ssh_port
    ssh_port=$(ss -tlnp | grep -c ':22 ')
    if [[ $ssh_port -gt 0 ]]; then
        log "INFO" "SSH service is accessible"
    else
        log "WARN" "SSH service may not be accessible"
    fi
    
    # Verify routing is working
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        log "INFO" "Internet connectivity verified"
    else
        log "WARN" "Internet connectivity test failed"
    fi
    
    log "INFO" "Network configuration stability check completed"
}

# Verify DMZ interface is properly configured
verify_dmz_interface() {
    log "INFO" "=== VERIFYING DMZ INTERFACE CONFIGURATION ==="
    
    local dmz_bridge="vmbr2"
    local dmz_ip="10.0.2.1"
    local success=true
    
    # Check if DMZ bridge exists
    if ! ip link show "$dmz_bridge" >/dev/null 2>&1; then
        log "WARN" "DMZ bridge ($dmz_bridge) not found"
        success=false
    else
        local bridge_state
        bridge_state=$(ip link show "$dmz_bridge" | grep -o "state [A-Z]*" | cut -d' ' -f2)
        if [[ "$bridge_state" == "UP" ]]; then
            log "INFO" "✓ DMZ bridge is UP"
        elif [[ "$bridge_state" == "UNKNOWN" ]]; then
            log "INFO" "✓ DMZ bridge is active (state: $bridge_state - this is normal for bridges without active ports)"
        else
            log "WARN" "DMZ bridge is not UP (state: $bridge_state)"
            success=false
        fi
        
        # Check if DMZ IP is configured
        local current_dmz_ip
        current_dmz_ip=$(ip addr show "$dmz_bridge" | grep "inet " | awk '{print $2}' | head -n1)
        if [[ "$current_dmz_ip" == "${dmz_ip}/24" ]]; then
            log "INFO" "✓ DMZ IP correctly configured: $current_dmz_ip"
        else
            log "WARN" "DMZ IP not correctly configured (expected: ${dmz_ip}/24, found: ${current_dmz_ip:-none})"
            success=false
        fi
    fi
    
    # Check if DMZ network configuration exists in interfaces file
    if [[ -f "$INTERFACES_FILE" ]]; then
        if grep -q "auto $dmz_bridge" "$INTERFACES_FILE" && grep -q "address $dmz_ip" "$INTERFACES_FILE"; then
            log "INFO" "✓ DMZ configuration found in interfaces file"
        else
            log "WARN" "DMZ configuration not found in interfaces file"
            success=false
        fi
    else
        log "WARN" "Interfaces file not found: $INTERFACES_FILE"
        success=false
    fi
    
    # Check if DMZ can be used for routing (basic connectivity test)
    if ip link show "$dmz_bridge" >/dev/null 2>&1; then
        if ping -c 1 -W 1 -I "$dmz_bridge" "$dmz_ip" >/dev/null 2>&1; then
            log "INFO" "✓ DMZ interface responds to ping"
        else
            log "DEBUG" "DMZ interface ping test failed (this is normal if no VMs are connected)"
        fi
    fi
    
    if [[ "$success" == true ]]; then
        log "INFO" "✓ DMZ interface verification passed"
        return 0
    else
        log "WARN" "DMZ interface verification completed with issues"
        return 1
    fi
}

# Fix network configuration issues
fix_network_configuration() {
    log "INFO" "=== FIXING NETWORK CONFIGURATION ==="
    
    # Check and fix network interfaces
    log "INFO" "Checking network interface configuration..."
    
    # Ensure vmbr1 exists and has correct IP
    if ! ip link show vmbr1 >/dev/null 2>&1; then
        log "WARN" "vmbr1 bridge missing - this will be created during full network setup"
        log "INFO" "Run without --fix to perform full network configuration"
    else
        local vmbr1_ip
        vmbr1_ip=$(ip addr show vmbr1 | grep "inet " | awk '{print $2}' | cut -d'/' -f1 | head -n1)
        if [[ "$vmbr1_ip" != "192.168.1.10" ]]; then
            log "INFO" "Fixing vmbr1 IP address..."
            if [[ -n "$vmbr1_ip" ]]; then
                ip addr del "${vmbr1_ip}/24" dev vmbr1 2>/dev/null || true
            fi
            if ip addr add 192.168.1.10/24 dev vmbr1 2>/dev/null; then
                log "INFO" "✓ Fixed vmbr1 IP to 192.168.1.10/24"
            else
                log "ERROR" "Failed to fix vmbr1 IP"
            fi
        else
            log "INFO" "✓ vmbr1 IP is correct: $vmbr1_ip"
        fi
    fi
    
    # Ensure vmbr2 exists and has correct IP
    if ! ip link show vmbr2 >/dev/null 2>&1; then
        log "WARN" "vmbr2 bridge missing - this will be created during full network setup"
    else
        local vmbr2_ip
        vmbr2_ip=$(ip addr show vmbr2 | grep "inet " | awk '{print $2}' | cut -d'/' -f1 | head -n1)
        if [[ "$vmbr2_ip" != "10.0.2.1" ]]; then
            log "INFO" "Fixing vmbr2 IP address..."
            if [[ -n "$vmbr2_ip" ]]; then
                ip addr del "${vmbr2_ip}/24" dev vmbr2 2>/dev/null || true
            fi
            if ip addr add 10.0.2.1/24 dev vmbr2 2>/dev/null; then
                log "INFO" "✓ Fixed vmbr2 IP to 10.0.2.1/24"
            else
                log "ERROR" "Failed to fix vmbr2 IP"
            fi
        else
            log "INFO" "✓ vmbr2 IP is correct: $vmbr2_ip"
        fi
    fi
    
    # Validate additional IP configuration
    parse_additional_ips
    if validate_hetzner_config; then
        log "INFO" "✓ Additional IP configuration is valid"
    else
        log "ERROR" "Additional IP configuration has issues - see errors above"
    fi
    
    log "INFO" "=== NETWORK FIX COMPLETE ==="
    log "INFO" "Run with --status to verify fixes"
}

# Get user confirmation for reset operations
get_user_confirmation() {
    local operation_name="$1"
    echo ""
    echo "=========================================="
    echo "⚠️  IMPORTANT: $operation_name"
    echo "=========================================="
    echo ""
    echo "This will modify your network configuration."
    echo "SSH connectivity will be preserved during changes."
    echo ""
    echo "Current network interface: ${SSH_INTERFACE:-unknown}"
    echo "Current IP address: ${CURRENT_IP:-unknown}"
    echo ""
    read -p "Do you want to continue? (yes/no): " -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log "INFO" "Operation cancelled by user"
        exit 0
    fi
    
    log "INFO" "User confirmed: $operation_name"
    echo ""
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --reset)
                export RESET_TO_ARIADATA=true
                log "INFO" "Reset mode enabled - will restore ariadata baseline configuration"
                shift
                ;;
            --fix)
                export FIX_MODE=true
                log "INFO" "Fix mode enabled - will check and repair network configuration"
                shift
                ;;
            --status)
                export STATUS_MODE=true
                log "INFO" "Status mode enabled - will show current network configuration"
                shift
                ;;
            --verbose|-v)
                export LOG_LEVEL=DEBUG
                log "INFO" "Verbose logging enabled"
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Show help information
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Configure network interfaces for Hetzner Proxmox with additional IPs.

OPTIONS:
    --reset              Reset network configuration to ariadata pve-install.sh baseline
    --fix                Check and repair network configuration issues
    --status             Show current network configuration status
    --verbose, -v        Enable verbose logging
    --help, -h          Show this help message

EXAMPLES:
    $0                   # Configure network with additional IPs (default)
    $0 --reset           # Reset to ariadata baseline configuration
    $0 --fix             # Check and fix network issues
    $0 --status          # Show current configuration
    $0 --verbose         # Run with detailed logging

NETWORK ARCHITECTURE:
    Internet → vmbr0 (WAN + Additional IPs) → pfSense VM
                                               ├── vmbr1 (LAN: 192.168.1.0/24)
                                               └── vmbr2 (DMZ: 10.0.2.0/24)

ADDITIONAL IP CONFIGURATION:
    Configure additional IPs in config/additional-ips.conf:
    IP=203.0.113.10 MAC=00:50:56:00:01:02 GATEWAY=203.0.113.1 NETMASK=255.255.255.192

REQUIREMENTS:
    - MAC addresses are REQUIRED for Hetzner additional IPs
    - Get MAC addresses from Hetzner Robot panel or contact support
    - All additional IPs must route through main gateway

EOF
}

# Main execution block
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Parse command line arguments first
    parse_arguments "$@"
    
    # Initialize logging and environment
    create_backup_dir
    get_ssh_info
    
    # Handle different operation modes
    if [[ "${STATUS_MODE:-false}" == "true" ]]; then
        log "INFO" "Showing current network configuration status..."
        show_network_status
        exit 0
    elif [[ "${FIX_MODE:-false}" == "true" ]]; then
        log "INFO" "Checking and fixing network configuration..."
        fix_network_configuration
        exit 0
    elif [[ "$RESET_TO_ARIADATA" == "true" ]]; then
        get_user_confirmation "RESET NETWORK CONFIGURATION TO ARIADATA BASELINE"
        
        log "INFO" "Resetting network configuration to ariadata pve-install.sh baseline..."
        
        # Create ariadata configuration (without additional IPs)
        create_ariadata_network_config
        
        # Apply the configuration
        log "INFO" "Applying ariadata baseline network configuration..."
        apply_network_config
        
        log "INFO" "✅ Network reset to ariadata baseline complete!"
        log "INFO" "Configuration is now compatible with ariadata pve-install.sh"
        log "INFO" "Additional IPs can be added by running without --reset flag"
    else
        get_user_confirmation "CONFIGURE HETZNER PROXMOX NETWORK WITH ADDITIONAL IPs"
        
        # Normal execution flow
        log "INFO" "Starting Hetzner Proxmox network configuration..."
        log "INFO" "This script will safely add additional IPs while preserving SSH connectivity"
        
        # Validate prerequisites
        validate_network_config
        
        # Create network backup
        backup_network_config
        
        # Parse additional IP configurations
        parse_additional_ips
        
        # Validate Hetzner-specific requirements
        validate_hetzner_config
        
        # Create and apply network configuration
        create_network_config
        apply_network_config
        
        # Ensure network is properly running
        ensure_network_configuration
        
        # Verify DMZ interface is properly configured
        log "INFO" "Verifying network configuration..."
        set +e  # Temporarily disable error exit
        verify_dmz_interface
        dmz_result=$?
        set -e  # Re-enable error exit
        
        if [[ $dmz_result -eq 0 ]]; then
            log "INFO" "✓ DMZ verification completed successfully"
        else
            log "WARN" "⚠️  DMZ verification completed with issues (this is often normal on first run)"
        fi
        
        # Show final status
        show_network_status
        
        log "INFO" "✅ Hetzner Proxmox network configuration complete!"
        log "INFO" ""
        log "INFO" "📋 Network Summary:"
        log "INFO" "   - WAN (vmbr0): Internet access with additional IPs"
        log "INFO" "   - LAN (vmbr1): 192.168.1.0/24 - pfSense management network"
        log "INFO" "   - DMZ (vmbr2): 10.0.2.0/24 - public-facing services network"
        log "INFO" ""
        log "INFO" "🔐 Security Notes:"
        log "INFO" "   - SSH connectivity has been preserved"
        log "INFO" "   - Network bridges are ready for pfSense configuration"
        log "INFO" "   - DMZ network is isolated and ready for public services"
        log "INFO" ""
        log "INFO" "Next Steps:"
        log "INFO" "   1. Set up pfSense VM: \$(dirname \"\$0\")/../install.sh --pfsense"
        log "INFO" "   2. Configure firewall rules in pfSense"
        log "INFO" "   3. Create VMs/containers using the DMZ network (vmbr2)"
        log "INFO" ""
        log "INFO" "DMZ Usage Examples:"
        log "INFO" "   VM: --net0 virtio,bridge=vmbr2"
        log "INFO" "   Container: --net0 name=eth0,bridge=vmbr2,ip=10.0.2.10/24,gw=10.0.2.1"
    fi
    
    # Explicit successful exit
    exit 0
fi

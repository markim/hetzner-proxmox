#!/bin/bash

# Firewall Admin VM Setup Script for Hetzner Proxmox
# This script creates a VM with LAN and WAN network interfaces for pfSense administration
# Uses Puppy Linux for fast, lightweight access to pfSense web interface

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source common functions
source "$SCRIPT_DIR/lib/common.sh"

# Load environment
load_env "$SCRIPT_DIR/.env"

# Import pfSense network configuration constants
PFSENSE_LAN_IP="${PFSENSE_LAN_IP:-192.168.1.1}"
PFSENSE_LAN_SUBNET="${PFSENSE_LAN_SUBNET:-192.168.1.0/24}"
PFSENSE_DHCP_START="${PFSENSE_DHCP_START:-192.168.1.100}"
PFSENSE_DHCP_END="${PFSENSE_DHCP_END:-192.168.1.200}"

# Firewall Admin VM configuration constants
VM_ISO_URL="https://distro.ibiblio.org/puppylinux/puppy-bookwormpup/BookwormPup64/10.0.11/BookwormPup64_10.0.11.iso"
VM_ISO_PATH="${VM_ISO_PATH:-/var/lib/vz/template/iso/BookwormPup64_10.0.11.iso}"
FIREWALL_ADMIN_VM_ID="${FIREWALL_ADMIN_VM_ID:-200}"
FIREWALL_ADMIN_HOSTNAME="${FIREWALL_ADMIN_HOSTNAME:-firewall-admin}"
FIREWALL_ADMIN_MEMORY="${FIREWALL_ADMIN_MEMORY:-1024}"
FIREWALL_ADMIN_CORES="${FIREWALL_ADMIN_CORES:-1}"
FIREWALL_ADMIN_DISK_SIZE="${FIREWALL_ADMIN_DISK_SIZE:-8}"

# Validate prerequisites
validate_prerequisites() {
    log "INFO" "Validating firewall admin VM prerequisites..."
    
    # Check if Proxmox is running
    if ! systemctl is-active --quiet pveproxy; then
        log "ERROR" "Proxmox web service is not running"
        return 1
    fi
    
    # Check if firewall admin VM already exists
    if qm status "$FIREWALL_ADMIN_VM_ID" >/dev/null 2>&1; then
        log "ERROR" "Firewall admin VM (ID: $FIREWALL_ADMIN_VM_ID) already exists"
        log "ERROR" "Destroy it first: qm destroy $FIREWALL_ADMIN_VM_ID"
        return 1
    fi
    
    # Check if network bridges exist
    if ! ip link show vmbr0 >/dev/null 2>&1; then
        log "ERROR" "WAN bridge vmbr0 not found. Run network configuration first."
        log "ERROR" "Execute: ./scripts/setup-network.sh"
        return 1
    fi
    
    if ! ip link show vmbr1 >/dev/null 2>&1; then
        log "ERROR" "LAN bridge vmbr1 not found. Run network configuration first."
        log "ERROR" "Execute: ./scripts/setup-network.sh"
        return 1
    fi
    
    log "INFO" "Prerequisites validation passed"
}

# Download Puppy Linux ISO for VM
download_vm_iso() {
    log "INFO" "Checking Puppy Linux ISO..."
    
    # Create ISO directory if it doesn't exist
    mkdir -p "$(dirname "$VM_ISO_PATH")"
    
    # Download if not already present
    if [[ ! -f "$VM_ISO_PATH" ]]; then
        log "INFO" "Downloading Puppy Linux ISO from: $VM_ISO_URL"
        log "INFO" "This is a much smaller and faster alternative to Ubuntu (~400MB vs ~4GB)"
        
        if curl -L -o "$VM_ISO_PATH" "$VM_ISO_URL"; then
            log "INFO" "Puppy Linux ISO downloaded to: $VM_ISO_PATH"
        else
            log "ERROR" "Failed to download Puppy Linux ISO"
            return 1
        fi
    else
        log "INFO" "Puppy Linux ISO already exists at: $VM_ISO_PATH"
    fi
    
    # Verify ISO file
    if [[ ! -s "$VM_ISO_PATH" ]]; then
        log "ERROR" "Puppy Linux ISO file is empty or corrupted"
        return 1
    fi
    
    log "INFO" "Puppy Linux ISO ready"
}

# Create firewall admin VM
create_firewall_admin_vm() {
    log "INFO" "Creating firewall admin VM with ID: $FIREWALL_ADMIN_VM_ID"
    
    # Load additional IPs and MACs arrays from network configuration
    source "$SCRIPT_DIR/scripts/setup-network.sh" || {
        log "ERROR" "Failed to load network configuration"
        return 1
    }
    
    # Parse additional IPs if the function exists
    if command -v parse_additional_ips >/dev/null 2>&1; then
        parse_additional_ips || {
            log "ERROR" "Failed to parse additional IPs configuration"
            return 1
        }
    fi
    
    # Create VM
    qm create "$FIREWALL_ADMIN_VM_ID" \
        --name "$FIREWALL_ADMIN_HOSTNAME" \
        --memory "$FIREWALL_ADMIN_MEMORY" \
        --cores "$FIREWALL_ADMIN_CORES" \
        --scsihw virtio-scsi-pci \
        --scsi0 "local-zfs:$FIREWALL_ADMIN_DISK_SIZE" \
        --ide2 "local:iso/BookwormPup64_10.0.11.iso,media=cdrom" \
        --ostype l26 \
        --boot order=ide2 \
        --onboot 0 \
        --agent enabled=1 \
        --vga qxl \
        --tablet 1
    
    # Configure LAN interface for pfSense admin access (vmbr1)
    # This interface will connect to the same LAN as pfSense for management access
    qm set "$FIREWALL_ADMIN_VM_ID" --net0 "virtio,bridge=vmbr1,firewall=0"
    log "INFO" "LAN interface configured on vmbr1 (pfSense management network)"
    log "INFO" "Expected pfSense LAN IP: ${PFSENSE_LAN_IP:-192.168.1.1}"
    log "INFO" "Firewall admin should use IP in range: ${PFSENSE_LAN_SUBNET:-192.168.1.0/24}"
    
    # Configure WAN interface for internet access (vmbr0) with MAC address
    local wan_net_config="virtio,bridge=vmbr0,firewall=0"
    if [[ -n "${ADDITIONAL_MACS_ARRAY[*]:-}" && ${#ADDITIONAL_MACS_ARRAY[@]} -gt 1 && -n "${ADDITIONAL_MACS_ARRAY[1]}" ]]; then
        wan_net_config="virtio,bridge=vmbr0,firewall=0,macaddr=${ADDITIONAL_MACS_ARRAY[1]}"
        log "INFO" "WAN interface configured with MAC address: ${ADDITIONAL_MACS_ARRAY[1]}"
        log "INFO" "This MAC address should correspond to additional IP: ${ADDITIONAL_IPS_ARRAY[1]:-'Not configured'}"
    else
        log "WARN" "No MAC address specified for WAN interface - using auto-generated"
        log "WARN" "This may cause routing issues with Hetzner additional IPs"
        log "WARN" "Consider configuring MAC addresses in your .env file"
    fi
    qm set "$FIREWALL_ADMIN_VM_ID" --net1 "$wan_net_config"
    
    log "INFO" "Firewall admin VM created successfully"
    log "INFO" ""
    log "INFO" "VM Configuration Summary:"
    log "INFO" "========================"
    log "INFO" "VM ID: $FIREWALL_ADMIN_VM_ID"
    log "INFO" "Hostname: $FIREWALL_ADMIN_HOSTNAME"
    log "INFO" "Memory: ${FIREWALL_ADMIN_MEMORY}MB"
    log "INFO" "CPU Cores: $FIREWALL_ADMIN_CORES"
    log "INFO" "Disk: $FIREWALL_ADMIN_DISK_SIZE GB"
    log "INFO" ""
    log "INFO" "Network Configuration:"
    log "INFO" "LAN Interface (net0): vmbr1 (pfSense management network)"
    log "INFO" "  └─ pfSense LAN IP: $PFSENSE_LAN_IP"
    log "INFO" "  └─ LAN Subnet: $PFSENSE_LAN_SUBNET"
    log "INFO" "  └─ Available DHCP Range: $PFSENSE_DHCP_START - $PFSENSE_DHCP_END"
    log "INFO" "WAN Interface (net1): vmbr0 (internet access)"
    if [[ -n "${ADDITIONAL_IPS_ARRAY[1]:-}" ]]; then
        log "INFO" "  └─ Assigned Public IP: ${ADDITIONAL_IPS_ARRAY[1]}"
    fi
    if [[ -n "${ADDITIONAL_MACS_ARRAY[1]:-}" ]]; then
        log "INFO" "  └─ Assigned MAC Address: ${ADDITIONAL_MACS_ARRAY[1]}"
    fi
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
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

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "This script must be run as root"
        exit 1
    fi
}

# Show help information
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Create firewall admin VM for pfSense management through Proxmox VNC console.

OPTIONS:
    --help, -h          Show this help message

DESCRIPTION:
    This script creates a VM with dual network interfaces for pfSense administration:
    - LAN interface (net0/vmbr1) for accessing pfSense web interface
      └─ Connects to pfSense LAN network ($PFSENSE_LAN_SUBNET)
      └─ pfSense LAN IP: $PFSENSE_LAN_IP
      └─ DHCP range: $PFSENSE_DHCP_START - $PFSENSE_DHCP_END
    - WAN interface (net1/vmbr0) with public IP and MAC address for internet access
    
    The VM uses Puppy Linux (~400MB) for faster installation and lower resource usage.
    
    After VM creation, you can:
    1. Start the VM through Proxmox web interface
    2. Boot Puppy Linux from the mounted ISO (runs from RAM)
    3. Configure LAN interface to access pfSense network
    4. Access pfSense admin panel at https://$PFSENSE_LAN_IP

EXAMPLES:
    $0                  # Create the firewall admin VM

NOTES:
    - Network bridges (vmbr0, vmbr1) must be configured first
    - Additional IP addresses and MAC addresses should be configured
    - VM will boot from Puppy Linux ISO for instant access

EOF
}

# Main function
main() {
    log "INFO" "Starting firewall admin VM setup for Hetzner Proxmox..."
    
    
    # Validate prerequisites
    validate_prerequisites
    
    # Download Puppy Linux ISO
    download_vm_iso
    
    # Create firewall admin VM
    create_firewall_admin_vm
    
    log "INFO" ""
    log "INFO" "🎉 Firewall admin VM setup completed successfully!"
    log "INFO" ""
    log "INFO" "NEXT STEPS:"
    log "INFO" "==========="
    log "INFO" ""
    log "INFO" "1. Start the VM:"
    log "INFO" "   qm start $FIREWALL_ADMIN_VM_ID"
    log "INFO" ""
    log "INFO" "2. Access VM console through Proxmox web interface:"
    log "INFO" "   https://your-proxmox-server:8006"
    log "INFO" "   Navigate to: VM $FIREWALL_ADMIN_VM_ID > Console"
    log "INFO" ""
    log "INFO" "3. Boot Puppy Linux from the ISO (no installation required - runs from RAM)"
    log "INFO" ""
    log "INFO" "4. Configure network interfaces in Puppy Linux:"
    log "INFO" "   - LAN Interface (eth0): Configure as DHCP client or static IP"
    log "INFO" "     Static IP example: 192.168.1.10/24, Gateway: $PFSENSE_LAN_IP"
    log "INFO" "     DHCP range: $PFSENSE_DHCP_START - $PFSENSE_DHCP_END"
    log "INFO" "   - WAN Interface (eth1): Configure with public IP ${ADDITIONAL_IPS_ARRAY[1]:-'(configure in .env)'}"
    log "INFO" "     Or use DHCP if automatic configuration is available"
    log "INFO" ""
    log "INFO" "5. Test LAN connectivity to pfSense:"
    log "INFO" "   ping $PFSENSE_LAN_IP"
    log "INFO" ""
    log "INFO" "6. Access pfSense admin panel:"
    log "INFO" "   Open web browser in Puppy Linux and navigate to:"
    log "INFO" "   https://$PFSENSE_LAN_IP (or http://$PFSENSE_LAN_IP if HTTPS not configured)"
    log "INFO" "   Default credentials: admin / pfsense"
    log "INFO" "   Note: You may need to accept the self-signed SSL certificate warning"
    log "INFO" "   pfSense generates its own certificate on first boot"
    log "INFO" ""
    log "INFO" "6. Optional: Save session to disk if you want persistent changes"
    log "INFO" "   Puppy Linux can run entirely from RAM for instant startup"
    log "INFO" ""
    log "INFO" "VM ready for pfSense administration!"
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    check_root
    parse_arguments "$@"
    main "$@"
fi

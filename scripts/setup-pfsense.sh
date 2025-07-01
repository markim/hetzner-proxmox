#!/bin/bash

# pfSense Setup Script for Hetzner Proxmox
# This script creates and configures a pfSense container/VM with proper networking

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source common functions
source "$SCRIPT_DIR/lib/common.sh"

# Load environment
load_env "$SCRIPT_DIR/.env"

# pfSense configuration constants
PFSENSE_ISO_URL="https://atxfiles.netgate.com/mirror/downloads/pfSense-CE-2.7.2-RELEASE-amd64.iso.gz"
PFSENSE_ISO_PATH="${PFSENSE_ISO_PATH:-/var/lib/vz/template/iso/pfSense-CE-2.7.2-RELEASE-amd64.iso}"
PFSENSE_VM_ID="${PFSENSE_VM_ID:-100}"
PFSENSE_CPU_CORES="${PFSENSE_CPU_CORES:-2}"
PFSENSE_MEMORY="${PFSENSE_MEMORY:-2048}"
PFSENSE_DISK_SIZE="${PFSENSE_DISK_SIZE:-8}"
PFSENSE_WAN_IP="${PFSENSE_WAN_IP:-}"
PFSENSE_LAN_IP="${PFSENSE_LAN_IP:-192.168.1.1}"
PFSENSE_LAN_SUBNET="${PFSENSE_LAN_SUBNET:-192.168.1.0/24}"
PFSENSE_DMZ_IP="${PFSENSE_DMZ_IP:-10.0.2.1}"
PFSENSE_DMZ_SUBNET="${PFSENSE_DMZ_SUBNET:-10.0.2.0/24}"
PFSENSE_DHCP_START="${PFSENSE_DHCP_START:-192.168.1.100}"
PFSENSE_DHCP_END="${PFSENSE_DHCP_END:-192.168.1.200}"

# Validate prerequisites
validate_prerequisites() {
    log "INFO" "Validating pfSense setup prerequisites..."
    
    # Check if Proxmox is running
    if ! systemctl is-active --quiet pveproxy; then
        log "ERROR" "Proxmox web service is not running"
        return 1
    fi
    
    # Check if network bridges exist
    if ! ip link show vmbr0 >/dev/null 2>&1; then
        log "ERROR" "WAN bridge vmbr0 not found. Run network configuration first."
        log "ERROR" "Execute: ./scripts/configure-network.sh"
        return 1
    fi
    
    if ! ip link show vmbr1 >/dev/null 2>&1; then
        log "ERROR" "LAN bridge vmbr1 not found. Run network configuration first."
        log "ERROR" "Execute: ./scripts/configure-network.sh"
        return 1
    fi
    
    # Check if vmbr2 exists (DMZ bridge - optional but recommended)
    if ! ip link show vmbr2 >/dev/null 2>&1; then
        log "WARN" "DMZ bridge vmbr2 not found (optional but recommended)"
        log "WARN" "DMZ interface will not be configured for pfSense"
    fi
    
    # Validate network configuration is proper for pfSense
    local vmbr1_ip
    vmbr1_ip=$(ip addr show vmbr1 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1 | head -n1)
    if [[ "$vmbr1_ip" != "192.168.1.1" ]]; then
        log "ERROR" "vmbr1 must have IP 192.168.1.1 for pfSense LAN configuration"
        log "ERROR" "Current vmbr1 IP: ${vmbr1_ip:-none}"
        log "ERROR" "Run network configuration to fix this: ./scripts/configure-network.sh"
        return 1
    fi
    
    local vmbr2_ip
    if ip link show vmbr2 >/dev/null 2>&1; then
        vmbr2_ip=$(ip addr show vmbr2 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1 | head -n1)
        if [[ "$vmbr2_ip" != "10.0.2.1" ]]; then
            log "WARN" "vmbr2 should have IP 10.0.2.1 for pfSense DMZ configuration"
            log "WARN" "Current vmbr2 IP: ${vmbr2_ip:-none}"
        fi
    fi
    
    # Check for available additional IP
    if [[ -z "${PFSENSE_WAN_IP}" ]]; then
        if [[ -n "${ADDITIONAL_IPS_ARRAY[*]:-}" && ${#ADDITIONAL_IPS_ARRAY[@]} -gt 0 ]]; then
            export PFSENSE_WAN_IP="${ADDITIONAL_IPS_ARRAY[0]}"
            log "INFO" "Using first additional IP for pfSense WAN: $PFSENSE_WAN_IP"
        else
            log "ERROR" "No WAN IP specified for pfSense. Set PFSENSE_WAN_IP or configure additional IPs"
            return 1
        fi
    fi
    
    # Check if VM ID is available
    if qm status "$PFSENSE_VM_ID" >/dev/null 2>&1; then
        log "WARN" "VM ID $PFSENSE_VM_ID is already in use"
        log "INFO" "Current VM status:"
        qm status "$PFSENSE_VM_ID"
        
        if [[ "${FORCE_RECREATE:-false}" == "true" ]]; then
            log "WARN" "FORCE_RECREATE=true, destroying existing VM..."
            if qm status "$PFSENSE_VM_ID" | grep -q "running"; then
                log "INFO" "Stopping running VM..."
                qm stop "$PFSENSE_VM_ID"
                sleep 5
            fi
            qm destroy "$PFSENSE_VM_ID"
            log "INFO" "Existing VM destroyed"
        else
            log "ERROR" "VM already exists. Use --force to recreate or choose different VM ID"
            log "INFO" "To destroy manually: qm destroy $PFSENSE_VM_ID"
            return 1
        fi
    fi
    
    log "INFO" "Prerequisites validation passed"
}

# Download pfSense ISO
download_pfsense_iso() {
    log "INFO" "Downloading pfSense ISO..."
    
    # Create ISO directory if it doesn't exist
    mkdir -p "$(dirname "$PFSENSE_ISO_PATH")"
    
    # Download if not already present
    if [[ ! -f "$PFSENSE_ISO_PATH" ]]; then
        log "INFO" "Downloading pfSense ISO from: $PFSENSE_ISO_URL"
        
        # Download compressed ISO
        local temp_file="/tmp/pfsense.iso.gz"
        if curl -L -o "$temp_file" "$PFSENSE_ISO_URL"; then
            log "INFO" "Download completed, extracting..."
            gunzip -c "$temp_file" > "$PFSENSE_ISO_PATH"
            rm -f "$temp_file"
            log "INFO" "pfSense ISO extracted to: $PFSENSE_ISO_PATH"
        else
            log "ERROR" "Failed to download pfSense ISO"
            return 1
        fi
    else
        log "INFO" "pfSense ISO already exists at: $PFSENSE_ISO_PATH"
    fi
    
    # Verify ISO file
    if [[ ! -s "$PFSENSE_ISO_PATH" ]]; then
        log "ERROR" "pfSense ISO file is empty or corrupted"
        return 1
    fi
    
    log "INFO" "pfSense ISO ready"
}

# Create pfSense VM
create_pfsense_vm() {
    log "INFO" "Creating pfSense VM with ID: $PFSENSE_VM_ID"
    
    # Create VM with optimized settings for pfSense
    qm create "$PFSENSE_VM_ID" \
        --name "pfSense-Firewall" \
        --description "pfSense Firewall VM - WAN: $PFSENSE_WAN_IP | LAN: $PFSENSE_LAN_IP | DMZ: $PFSENSE_DMZ_IP" \
        --ostype other \
        --memory "$PFSENSE_MEMORY" \
        --cores "$PFSENSE_CPU_CORES" \
        --cpu host \
        --onboot 1 \
        --tablet 0 \
        --boot order=ide2 \
        --cdrom "$PFSENSE_ISO_PATH" \
        --machine q35
    
    # Add SCSI controller and disk with optimal settings for pfSense
    qm set "$PFSENSE_VM_ID" \
        --scsihw virtio-scsi-single \
        --scsi0 "local-zfs:$PFSENSE_DISK_SIZE,cache=writeback,discard=on,iothread=1"
    
    # Configure network interfaces with proper virtio drivers
    # WAN interface (vmbr0) - use MAC address if available
    local wan_net_config="virtio,bridge=vmbr0,firewall=0"
    if [[ -n "${ADDITIONAL_MACS_ARRAY[*]:-}" && ${#ADDITIONAL_MACS_ARRAY[@]} -gt 0 && -n "${ADDITIONAL_MACS_ARRAY[0]}" ]]; then
        wan_net_config="virtio,bridge=vmbr0,firewall=0,macaddr=${ADDITIONAL_MACS_ARRAY[0]}"
        log "INFO" "WAN interface configured with MAC address: ${ADDITIONAL_MACS_ARRAY[0]}"
    else
        log "WARN" "No MAC address specified for WAN interface - using auto-generated"
        log "WARN" "This may cause routing issues with Hetzner additional IPs"
        log "WARN" "Configure MAC addresses in additional-ips.conf for proper routing"
    fi
    qm set "$PFSENSE_VM_ID" --net0 "$wan_net_config"
    
    # LAN interface (vmbr1) - auto-generated MAC is fine for internal networks
    qm set "$PFSENSE_VM_ID" --net1 "virtio,bridge=vmbr1,firewall=0"
    
    # DMZ interface (vmbr2) - only if bridge exists
    if ip link show vmbr2 >/dev/null 2>&1; then
        qm set "$PFSENSE_VM_ID" --net2 "virtio,bridge=vmbr2,firewall=0"
        log "INFO" "DMZ interface configured on vmbr2"
    else
        log "INFO" "DMZ interface skipped (vmbr2 not available)"
    fi
    
    # Configure VGA and other settings optimized for pfSense
    qm set "$PFSENSE_VM_ID" \
        --vga std \
        --serial0 socket \
        --watchdog i6300esb,action=reset
    
    log "INFO" "pfSense VM created successfully"
    log "INFO" "VM Configuration:"
    log "INFO" "  - VM ID: $PFSENSE_VM_ID"
    log "INFO" "  - Memory: ${PFSENSE_MEMORY}MB"
    log "INFO" "  - CPU Cores: $PFSENSE_CPU_CORES"
    log "INFO" "  - Disk: ${PFSENSE_DISK_SIZE}GB with cache=writeback"
    log "INFO" "  - WAN Interface: vmbr0 → $PFSENSE_WAN_IP"
    log "INFO" "  - LAN Interface: vmbr1 → $PFSENSE_LAN_IP"
    if ip link show vmbr2 >/dev/null 2>&1; then
        log "INFO" "  - DMZ Interface: vmbr2 → $PFSENSE_DMZ_IP"
    fi
}



# Show VM management commands and quick start guide
show_management_commands() {
    log "INFO" "pfSense VM Management & Quick Start Guide"
    echo
    echo "=== 🚀 QUICK START WORKFLOW ==="
    echo "1. qm start $PFSENSE_VM_ID                    # Start the VM"
    echo "2. qm terminal $PFSENSE_VM_ID                 # Console access for installation"
    echo "3. Install pfSense to disk (follow prompts)"
    echo "4. qm stop $PFSENSE_VM_ID && qm set $PFSENSE_VM_ID --ide2 none  # Remove ISO"
    echo "5. qm start $PFSENSE_VM_ID                    # Start again"
    echo "6. Configure interfaces via console (menu options 1 & 2)"
    echo "7. Access web interface: https://$PFSENSE_LAN_IP"
    echo
    echo "=== 🎛️ VM CONTROL ==="
    echo "Start VM:           qm start $PFSENSE_VM_ID"
    echo "Stop VM:            qm stop $PFSENSE_VM_ID"
    echo "Reset VM:           qm reset $PFSENSE_VM_ID"
    echo "Console Access:     qm terminal $PFSENSE_VM_ID"
    echo "VM Status:          qm status $PFSENSE_VM_ID"
    echo "VM Configuration:   qm config $PFSENSE_VM_ID"
    echo
    echo "=== 🌐 NETWORK INFORMATION ==="
    echo "WAN IP:             $PFSENSE_WAN_IP"
    echo "LAN IP:             $PFSENSE_LAN_IP"
    echo "LAN Subnet:         $PFSENSE_LAN_SUBNET"
    if ip link show vmbr2 >/dev/null 2>&1; then
        echo "DMZ IP:             $PFSENSE_DMZ_IP"
        echo "DMZ Subnet:         $PFSENSE_DMZ_SUBNET"
    fi
    echo "Web Interface:      https://$PFSENSE_LAN_IP"
    echo "Default Login:      admin / pfsense"
    echo
    echo "=== 🔧 TESTING & VALIDATION ==="
    echo "Check Bridges:      ip addr show vmbr1"
    echo "Monitor VM:         qm monitor $PFSENSE_VM_ID"
    echo "=== ⚠️ IMPORTANT NOTES ==="
    echo "• Change default password IMMEDIATELY after first login"
    echo "• Interface assignment: WAN=vtnet0, LAN=vtnet1, DMZ=vtnet2"
    echo "• WAN requires correct MAC address for Hetzner routing"
    echo "• LAN devices will connect to vmbr1 bridge"
    echo "• DMZ devices will connect to vmbr2 bridge (if configured)"
    echo
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --vm-id)
                export PFSENSE_VM_ID="$2"
                shift 2
                ;;
            --wan-ip)
                export PFSENSE_WAN_IP="$2"
                shift 2
                ;;
            --memory)
                export PFSENSE_MEMORY="$2"
                shift 2
                ;;
            --cores)
                export PFSENSE_CPU_CORES="$2"
                shift 2
                ;;
            --disk-size)
                export PFSENSE_DISK_SIZE="$2"
                shift 2
                ;;
            --force)
                export FORCE_RECREATE=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            --verbose|-v)
                export LOG_LEVEL=DEBUG
                shift
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

Create and configure a pfSense VM for Hetzner Proxmox setup.

OPTIONS:
    --vm-id ID           VM ID to use (default: $PFSENSE_VM_ID)
    --wan-ip IP          WAN IP address for pfSense
    --memory MB          Memory allocation in MB (default: $PFSENSE_MEMORY)
    --cores N            CPU cores (default: $PFSENSE_CPU_CORES)
    --disk-size SIZE     Disk size (default: $PFSENSE_DISK_SIZE GB)
    --force              Recreate VM if it already exists
    --verbose, -v        Enable verbose output
    --help, -h           Show this help message

EXAMPLES:
    $0                                    # Use defaults
    $0 --vm-id 200 --memory 4096          # Custom VM ID and memory
    $0 --wan-ip 1.2.3.4                   # Specify WAN IP

PREREQUISITES:
    - Network configuration must be completed first
    - Additional IP addresses configured
    - Network bridges (vmbr0, vmbr1, vmbr2) must exist

EOF
}

# Main function
main() {
    # Parse command line arguments first
    parse_arguments "$@"
    
    log "INFO" "Starting pfSense setup for Hetzner Proxmox..."
    
    
    # Load additional IPs array if available
    if [[ -f "$SCRIPT_DIR/scripts/configure-network.sh" ]]; then
        # Source the network configuration to get additional IPs
        source "$SCRIPT_DIR/scripts/configure-network.sh" >/dev/null 2>&1 || true
        
        # Try to parse additional IPs if the function exists
        if command -v parse_additional_ips >/dev/null 2>&1; then
            parse_additional_ips 2>/dev/null || true
        fi
    fi
    
    # Validate prerequisites
    validate_prerequisites
    
    # Download pfSense ISO
    download_pfsense_iso
    
    # Create pfSense VM
    create_pfsense_vm
    
    # Show management commands
    show_management_commands
    
    log "INFO" "pfSense VM setup completed successfully!"
    log "INFO" ""
    log "INFO" "Next steps:"
    log "INFO" "1. Start the VM: qm start $PFSENSE_VM_ID"
    log "INFO" "2. Access console: qm terminal $PFSENSE_VM_ID"
    log "INFO" "3. Install pfSense to disk and reboot"
    log "INFO" "4. Configure interfaces through console menu"
    log "INFO" "5. Access web interface: https://$PFSENSE_LAN_IP"
    log "INFO" "6. Complete setup using web interface"
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    check_root
    parse_arguments "$@"
    main "$@"
fi

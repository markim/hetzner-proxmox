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
PFSENSE_ISO_PATH="/var/lib/vz/template/iso/pfSense-CE-2.7.2-RELEASE-amd64.iso"
PFSENSE_VM_ID="${PFSENSE_VM_ID:-100}"
PFSENSE_CPU_CORES="${PFSENSE_CPU_CORES:-2}"
PFSENSE_MEMORY="${PFSENSE_MEMORY:-2048}"
PFSENSE_DISK_SIZE="${PFSENSE_DISK_SIZE:-8}"
PFSENSE_WAN_IP="${PFSENSE_WAN_IP:-}"
PFSENSE_LAN_IP="${PFSENSE_LAN_IP:-192.168.1.1}"
PFSENSE_DMZ_IP="${PFSENSE_DMZ_IP:-10.0.2.1}"

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
    
    # Create VM
    qm create "$PFSENSE_VM_ID" \
        --name "pfSense-Firewall" \
        --description "pfSense Firewall VM with WAN IP: $PFSENSE_WAN_IP" \
        --ostype other \
        --memory "$PFSENSE_MEMORY" \
        --cores "$PFSENSE_CPU_CORES" \
        --cpu host \
        --onboot 1 \
        --tablet 0 \
        --boot order=ide2 \
        --cdrom "$PFSENSE_ISO_PATH"
    
    # Add SCSI controller and disk
    qm set "$PFSENSE_VM_ID" \
        --scsihw virtio-scsi-pci \
        --scsi0 "local:$PFSENSE_DISK_SIZE"
    
    # Configure network interfaces
    # WAN interface (vmbr0) - use MAC address if available
    local wan_net_config="virtio,bridge=vmbr0,firewall=0"
    if [[ -n "${ADDITIONAL_MACS_ARRAY[*]:-}" && ${#ADDITIONAL_MACS_ARRAY[@]} -gt 0 && -n "${ADDITIONAL_MACS_ARRAY[0]}" ]]; then
        wan_net_config="virtio,bridge=vmbr0,firewall=0,macaddr=${ADDITIONAL_MACS_ARRAY[0]}"
        log "INFO" "WAN interface configured with MAC address: ${ADDITIONAL_MACS_ARRAY[0]}"
    else
        log "WARN" "No MAC address specified for WAN interface - using auto-generated"
        log "WARN" "This may cause routing issues with Hetzner additional IPs"
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
    
    # Configure VGA and other settings
    qm set "$PFSENSE_VM_ID" \
        --vga std \
        --serial0 socket \
        --watchdog i6300esb,action=reset
    
    log "INFO" "pfSense VM created successfully"
    log "INFO" "VM Configuration:"
    log "INFO" "  - VM ID: $PFSENSE_VM_ID"
    log "INFO" "  - Memory: ${PFSENSE_MEMORY}MB"
    log "INFO" "  - CPU Cores: $PFSENSE_CPU_CORES"
    log "INFO" "  - Disk: $PFSENSE_DISK_SIZE"
    log "INFO" "  - WAN Interface: vmbr0 (connects to $PFSENSE_WAN_IP)"
    log "INFO" "  - LAN Interface: vmbr1 (192.168.1.0/24)"
    log "INFO" "  - DMZ Interface: vmbr2 (10.0.2.0/24)"
}

# Generate pfSense setup documentation
generate_pfsense_documentation() {
    log "INFO" "Generating pfSense setup documentation..."
    
    local config_dir="$SCRIPT_DIR/config/pfsense"
    mkdir -p "$config_dir"
    
    # Generate setup instructions instead of config template
    cat > "$config_dir/setup-instructions.md" << EOF
# pfSense Manual Configuration Guide

After pfSense installation, you'll need to configure it manually through the console or web interface.

## Network Interface Configuration

### WAN Interface (vtnet0)
- **IP Address**: $PFSENSE_WAN_IP
- **Subnet**: ${ADDITIONAL_NETMASKS_ARRAY[0]:-255.255.255.192}
- **Gateway**: ${ADDITIONAL_GATEWAYS_ARRAY[0]:-Check your Hetzner control panel}

### LAN Interface (vtnet1) 
- **IP Address**: $PFSENSE_LAN_IP
- **Subnet**: 255.255.255.0 (24-bit)
- **DHCP Range**: 192.168.1.100 - 192.168.1.200

### DMZ Interface (vtnet2) - Optional
- **IP Address**: $PFSENSE_DMZ_IP  
- **Subnet**: 255.255.255.0 (24-bit)
- **DHCP Range**: 10.0.2.100 - 10.0.2.200

## Initial Setup Steps

1. **Boot from ISO and install pfSense to disk**
2. **Reboot and remove ISO**
3. **Console Configuration**:
   - Assign interfaces: WAN=vtnet0, LAN=vtnet1, OPT1=vtnet2
   - Configure WAN interface with static IP
   - Configure LAN interface with $PFSENSE_LAN_IP
4. **Web Interface Setup**:
   - Access: https://$PFSENSE_LAN_IP
   - Login: admin / pfsense
   - **CHANGE DEFAULT PASSWORD IMMEDIATELY**
5. **Configure firewall rules and NAT as needed**

## DNS Servers
- Primary: 8.8.8.8
- Secondary: 8.8.4.4

## Important Notes
- Default credentials: admin / pfsense
- Change the default password during initial setup
- Configure firewall rules to secure your environment
- Enable DHCP on LAN/DMZ if needed
EOF

    log "INFO" "pfSense setup documentation created at: $config_dir/setup-instructions.md"
    log "INFO" "Manual configuration required after pfSense installation"
}



# Show VM management commands
show_management_commands() {
    log "INFO" "pfSense VM Management Commands:"
    echo
    echo "=== VM Control ==="
    echo "Start VM:      qm start $PFSENSE_VM_ID"
    echo "Stop VM:       qm stop $PFSENSE_VM_ID"
    echo "Reset VM:      qm reset $PFSENSE_VM_ID"
    echo "Console:       qm terminal $PFSENSE_VM_ID"
    echo "Status:        qm status $PFSENSE_VM_ID"
    echo
    echo "=== Access Information ==="
    echo "WAN IP:        $PFSENSE_WAN_IP"
    echo "LAN IP:        $PFSENSE_LAN_IP (https://$PFSENSE_LAN_IP)"
    echo "DMZ IP:        $PFSENSE_DMZ_IP"
    echo "Default Login: admin / pfsense"
    echo
    echo "=== Documentation ==="
    echo "Setup Guide:   config/pfsense/setup-instructions.md"
    echo "Manual Config: Required after installation"
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
            --dry-run)
                export DRY_RUN=true
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
    --dry-run            Show what would be done without creating VM
    --verbose, -v        Enable verbose output
    --help, -h           Show this help message

EXAMPLES:
    $0                                    # Use defaults
    $0 --vm-id 200 --memory 4096          # Custom VM ID and memory
    $0 --wan-ip 1.2.3.4                   # Specify WAN IP
    $0 --dry-run                          # Preview without creating

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
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "=== DRY RUN MODE - SHOWING PLANNED ACTIONS ==="
        log "INFO" ""
        log "INFO" "pfSense VM Configuration:"
        log "INFO" "  - VM ID: $PFSENSE_VM_ID"
        log "INFO" "  - Memory: ${PFSENSE_MEMORY}MB"
        log "INFO" "  - CPU Cores: $PFSENSE_CPU_CORES"
        log "INFO" "  - Disk Size: $PFSENSE_DISK_SIZE GB"
        log "INFO" "  - WAN IP: ${PFSENSE_WAN_IP:-'Auto-select from additional IPs'}"
        log "INFO" "  - LAN IP: $PFSENSE_LAN_IP"
        log "INFO" "  - DMZ IP: $PFSENSE_DMZ_IP"
        log "INFO" ""
        log "INFO" "Actions that would be performed:"
        log "INFO" "  1. Validate prerequisites"
        log "INFO" "  2. Download pfSense ISO if needed"
        log "INFO" "  3. Create VM with ID $PFSENSE_VM_ID"
        log "INFO" "  4. Configure network interfaces"
        log "INFO" "  5. Generate setup documentation"
        log "INFO" "  6. Create manual configuration guide"
        log "INFO" ""
        log "INFO" "DRY RUN completed - no changes were made"
        log "INFO" "To create the pfSense VM, run without --dry-run flag"
        return 0
    fi
    
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
    
    # Generate configuration files
    generate_pfsense_documentation
    
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
    log "INFO" ""
    log "INFO" "Configuration guide: config/pfsense/setup-instructions.md"
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    check_root
    parse_arguments "$@"
    main "$@"
fi

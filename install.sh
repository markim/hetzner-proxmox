#!/bin/bash

# Hetzner Proxmox Setup - Main Installation Script
# This script orchestrates the complete setup process

set -euo pipefail

readonly SCRIPT_NAME="install"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "$SCRIPT_DIR/lib/common.sh"

# Load default environment (will be overridden by parse_args if needed)
load_env

# Usage information
usage() {
    cat << EOF
Usage: $0 [COMMAND] [OPTIONS]

Automated setup for Hetzner Proxmox server with Caddy reverse proxy and HTTPS.

COMMANDS:
    (no command)        Show this help and available commands
    --caddy             Install and configure Caddy with HTTPS (current functionality)
    --network           Configure network interfaces for additional Hetzner IPs
    --pfsense           Create and configure pfSense firewall VM (requires --network first)
    --firewalladmin     Create Fedora container for firewall administration (requires --pfsense first)
    --check-mac         Verify MAC address configuration for additional IPs
    --all               Run complete setup (network + caddy) - FUTURE

OPTIONS:
    -h, --help          Show this help message
    -c, --config FILE   Use specific environment file (default: .env)
    -d, --dry-run       Show what would be done without executing
    -v, --verbose       Enable verbose logging

EXAMPLES:
    $0                  # Show available commands
    $0 --caddy          # Install Caddy with current configuration
    $0 --network        # Configure network interfaces for additional IPs
    $0 --pfsense        # Create pfSense VM after network configuration
    $0 --firewalladmin  # Create firewall admin container after pfSense setup
    $0 --caddy -c prod.env      # Use custom environment file
    $0 --network --dry-run      # Show network changes without executing

REQUIREMENTS:
    - Fresh Proxmox installation on Hetzner server
    - Domain name pointing to server IP (for --caddy)
    - Properly configured .env file

NETWORK SETUP:
    Configure ADDITIONAL_IPS in .env file with your Hetzner IPs:
    Format: IP:MAC:GATEWAY:NETMASK,IP:MAC:GATEWAY:NETMASK
    
    Example:
    ADDITIONAL_IPS=YOUR_ADDITIONAL_IP:YOUR_MAC_ADDRESS:YOUR_GATEWAY_IP:YOUR_NETMASK

SAFETY NOTES:
    - Network configuration includes automatic backup and restore capabilities
    - SSH connectivity is preserved during network changes
    - Emergency restore script is created: /root/restore-network.sh

EOF
}

# Parse command line arguments
parse_args() {
    local config_file=""
    local dry_run=false
    local command=""
    
    # Parse command first
    if [[ $# -gt 0 ]] && [[ "$1" =~ ^--.* ]]; then
        case $1 in
            --caddy)
                command="caddy"
                shift
                ;;
            --network)
                command="network"
                shift
                ;;
            --pfsense)
                command="pfsense"
                shift
                ;;
            --firewalladmin)
                command="firewalladmin"
                shift
                ;;
            --check-mac)
                command="check-mac"
                shift
                ;;
            --all)
                command="all"
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                # Continue to option parsing
                ;;
        esac
    fi
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -c|--config)
                config_file="$2"
                shift 2
                ;;
            -d|--dry-run)
                dry_run=true
                shift
                ;;
            -v|--verbose)
                export LOG_LEVEL="DEBUG"
                shift
                ;;
            --caddy|--network|--pfsense|--firewalladmin|--check-mac|--all)
                # Already handled above
                shift
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # Load environment
    if [[ -n "$config_file" ]]; then
        load_env "$SCRIPT_DIR/$config_file"
    else
        load_env "$SCRIPT_DIR/.env"
    fi
    
    export DRY_RUN="$dry_run"
    export COMMAND="$command"
}

# Validate environment and requirements
validate_setup() {
    log "INFO" "Validating setup requirements..."
    
    # Different validation based on command
    case "${COMMAND:-}" in
        "caddy")
            # Check if required environment variables are set for Caddy
            validate_env "DOMAIN" "EMAIL"
            
            # Validate domain format
            if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
                log "ERROR" "Invalid domain name: $DOMAIN"
                exit 1
            fi
            ;;
        "network")
            # Network-specific validation is handled in the network script
            log "INFO" "Network validation will be performed by configure-network.sh"
            ;;
        "pfsense")
            # pfSense-specific validation is handled in the pfSense script
            log "INFO" "pfSense validation will be performed by setup-pfsense.sh"
            # Check that network configuration has been run first
            if ! ip link show vmbr0 >/dev/null 2>&1 || ! ip link show vmbr1 >/dev/null 2>&1; then
                log "ERROR" "Network bridges not found. Run network configuration first:"
                log "ERROR" "  $0 --network"
                exit 1
            fi
            ;;
        "firewalladmin")
            # Firewall admin specific validation is handled in the firewall admin script
            log "INFO" "Firewall admin validation will be performed by setup-firewall-admin.sh"
            # Check that network configuration and pfSense have been set up first
            if ! ip link show vmbr0 >/dev/null 2>&1 || ! ip link show vmbr1 >/dev/null 2>&1; then
                log "ERROR" "Network bridges not found. Run network configuration first:"
                log "ERROR" "  $0 --network"
                exit 1
            fi
            local pfsense_vm_id="${PFSENSE_VM_ID:-100}"
            if ! qm status "$pfsense_vm_id" >/dev/null 2>&1; then
                log "ERROR" "pfSense VM not found. Set up pfSense first:"
                log "ERROR" "  $0 --pfsense"
                exit 1
            fi
            ;;
        "all")
            # Validate for both network and caddy
            validate_env "DOMAIN" "EMAIL"
            if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
                log "ERROR" "Invalid domain name: $DOMAIN"
                exit 1
            fi
            ;;
        "check-mac")
            # MAC address check doesn't require special validation - it just checks configuration
            log "INFO" "MAC address configuration check - no prerequisites required"
            ;;
        *)
            # No command specified - just show usage
            log "INFO" "No command specified. Available commands:"
            usage
            exit 0
            ;;
    esac
    
    # Check if Proxmox is installed
    if ! command -v pvesh &> /dev/null; then
        log "ERROR" "Proxmox VE not found. Please install Proxmox first."
        exit 1
    fi
    
    # Check if we're on Debian
    if ! grep -q "debian" /etc/os-release; then
        log "ERROR" "This script is designed for Debian systems."
        exit 1
    fi
    
    # Check internet connectivity
    if ! ping -c 1 8.8.8.8 &> /dev/null; then
        log "ERROR" "No internet connectivity. Please check your network connection."
        exit 1
    fi
    
    log "INFO" "Validation completed successfully."
}

# Show usage information
show_usage() {
    cat << EOF
Usage: $0 <domain>

Arguments:
    domain    Your domain name (e.g., proxmox.example.com)

Environment Variables:
    PROXMOX_PORT     Proxmox web interface port (default: 8006)
    CADDY_CONFIG_DIR Caddy configuration directory (default: /etc/caddy)

Example:
    sudo $0 proxmox.example.com
EOF
}

# Execute script with dry-run support
run_script() {
    local script="$1"
    local script_path="$SCRIPT_DIR/$script"
    
    if [[ ! -f "$script_path" ]]; then
        log "ERROR" "Script not found: $script_path"
        exit 1
    fi
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "Executing: $script --dry-run"
        if ! bash "$script_path" --dry-run; then
            log "ERROR" "Failed to execute: $script --dry-run"
            exit 1
        fi
    else
        log "INFO" "Executing: $script"
        if ! bash "$script_path"; then
            log "ERROR" "Failed to execute: $script"
            exit 1
        fi
    fi
}

# Main installation function
main() {
    case "${COMMAND:-}" in
        "caddy")
            run_caddy_setup
            ;;
        "network")
            run_network_setup
            ;;
        "pfsense")
            run_pfsense_setup
            ;;
        "firewalladmin")
            run_firewall_admin_setup
            ;;
        "check-mac")
            run_mac_check
            ;;
        "all")
            run_complete_setup
            ;;
        *)
            # No command specified - show usage
            log "INFO" "Hetzner Proxmox Setup Script"
            log "INFO" "=============================="
            echo
            log "INFO" "Available commands:"
            log "INFO" "  --caddy    Install Caddy reverse proxy with HTTPS"
            log "INFO" "  --network  Configure network interfaces for additional IPs"
            log "INFO" "  --pfsense  Create pfSense firewall VM (requires --network first)"
            log "INFO" "  --firewalladmin  Create firewall admin container (requires --pfsense first)"
            log "INFO" "  --check-mac  Verify MAC address configuration for additional IPs"
            log "INFO" "  --all      Complete setup (network + caddy) [FUTURE]"
            echo
            log "INFO" "Use --help for detailed information"
            log "INFO" "Example: $0 --caddy"
            exit 0
            ;;
    esac
}

# Run Caddy setup (original functionality)
run_caddy_setup() {
    log "INFO" "Starting Hetzner Proxmox Caddy setup..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    # Validate setup for Caddy
    validate_setup
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "DRY RUN MODE - No changes will be made"
    fi
    
    # Run setup scripts in order
    local scripts=(
        "scripts/install-caddy.sh"
        "scripts/configure-proxmox.sh"
        "scripts/setup-https.sh"
    )
    
    for script in "${scripts[@]}"; do
        run_script "$script"
        log "INFO" "Completed: $script"
    done
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "DRY RUN completed - no changes were made"
        log "INFO" "To execute for real, run without --dry-run flag"
    else
        log "INFO" "Caddy setup completed successfully!"
        log "INFO" "You can now access Proxmox at: https://$DOMAIN"
        
        # Log final instructions
        log "INFO" "✅ Caddy Setup Complete!"
        log "INFO" "Your Proxmox server is now accessible at: https://$DOMAIN"
        log "INFO" "Next Steps:"
        log "INFO" "1. Access Proxmox web interface at https://$DOMAIN"
        log "INFO" "2. Change default root password"
        log "INFO" "3. Configure backup strategies"
        log "INFO" "4. Set up additional users if needed"
        log "INFO" "5. Review firewall rules: ufw status"
        log "INFO" "Important Security Notes:"
        log "INFO" "- Direct access to port $PROXMOX_PORT has been disabled"
        log "INFO" "- Consider disabling SSH root login"
        log "INFO" "- Regularly update the system: apt update && apt upgrade"
        log "INFO" "Logs are available at: $LOG_FILE"
    fi
}

# Run network setup
run_network_setup() {
    log "INFO" "Starting Hetzner Proxmox network configuration..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    # Validate setup for network
    validate_setup
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "DRY RUN MODE - No changes will be made"
    fi
    
    # Run network configuration script
    run_script "scripts/configure-network.sh"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "DRY RUN completed - no changes were made"
        log "INFO" "To execute for real, run without --dry-run flag"
    else
        log "INFO" "✅ Network Configuration Complete!"
        log "INFO" "Additional IP addresses have been configured"
        log "INFO" "Network backup available at: /root/network-backups/"
        log "INFO" "Emergency restore script: /root/restore-network.sh"
        log "INFO" "Next Steps:"
        log "INFO" "1. Test connectivity to additional IPs"
        log "INFO" "2. Run pfSense setup: $0 --pfsense"
        log "INFO" "3. Set up DNS entries for the additional IPs"
        log "INFO" "Logs are available at: $LOG_FILE"
    fi
}

# Run pfSense setup
run_pfsense_setup() {
    log "INFO" "Starting Hetzner Proxmox pfSense setup..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    # Validate setup for pfSense
    validate_setup
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "DRY RUN MODE - No changes will be made"
    fi
    
    # Run pfSense setup script
    run_script "scripts/setup-pfsense.sh"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "DRY RUN completed - no changes were made"
        log "INFO" "To execute for real, run without --dry-run flag"
    else
        log "INFO" "✅ pfSense VM Setup Complete!"
        log "INFO" "pfSense firewall VM has been created and configured"
        log "INFO" "VM Management Commands:"
        log "INFO" "  Start VM:  qm start \${PFSENSE_VM_ID:-100}"
        log "INFO" "  Stop VM:   qm stop \${PFSENSE_VM_ID:-100}"
        log "INFO" "  Console:   qm terminal \${PFSENSE_VM_ID:-100}"
        log "INFO" "Next Steps:"
        log "INFO" "1. Start the pfSense VM: qm start \${PFSENSE_VM_ID:-100}"
        log "INFO" "2. Access VM console for initial setup: qm terminal \${PFSENSE_VM_ID:-100}"
        log "INFO" "3. Complete pfSense installation wizard"
        log "INFO" "4. Configure WAN interface with one of your additional IPs"
        log "INFO" "5. Configure LAN interface (default: 10.0.1.1/24)"
        log "INFO" "6. Access web interface from LAN: https://10.0.1.1"
        log "INFO" "7. Change default password (admin/pfsense)"
        log "INFO" "8. Configure firewall rules and port forwarding"
        log "INFO" "Configuration files: config/pfsense/"
        log "INFO" "Logs are available at: $LOG_FILE"
    fi
}

# Run firewall admin container setup
run_firewall_admin_setup() {
    log "INFO" "Starting Hetzner Proxmox firewall admin container setup..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    # Validate setup for firewall admin
    validate_setup
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "DRY RUN MODE - No changes will be made"
    fi
    
    # Run firewall admin setup script
    run_script "scripts/setup-firewall-admin.sh"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "DRY RUN completed - no changes were made"
        log "INFO" "To execute for real, run without --dry-run flag"
    else
        log "INFO" "✅ Firewall Admin Container Setup Complete!"
        log "INFO" "Fedora container for firewall administration has been created"
        log "INFO" "Container Management Commands:"
        log "INFO" "  Start:    pct start \${FIREWALL_ADMIN_CT_ID:-200}"
        log "INFO" "  Stop:     pct stop \${FIREWALL_ADMIN_CT_ID:-200}"
        log "INFO" "  Console:  pct console \${FIREWALL_ADMIN_CT_ID:-200}"
        log "INFO" "Access Information:"
        log "INFO" "  LAN IP:   \${FIREWALL_ADMIN_LAN_IP:-10.0.1.10}"
        log "INFO" "  WAN IP:   Second additional IP from configuration"
        log "INFO" "  pfSense:  https://\${PFSENSE_LAN_IP:-10.0.1.1}"
        log "INFO" "Next Steps:"
        log "INFO" "1. Container should start automatically"
        log "INFO" "2. Access console: pct console \${FIREWALL_ADMIN_CT_ID:-200}"
        log "INFO" "3. Login with admin user"
        log "INFO" "4. Run: ./pfsense-access.sh for quick pfSense access"
        log "INFO" "5. Open Firefox and navigate to pfSense web interface"
        log "INFO" "6. Configure firewall rules and settings as needed"
        log "INFO" "Credentials file: config/firewall-admin-credentials.txt"
        log "INFO" "Logs are available at: $LOG_FILE"
    fi
}

# Run MAC address check
run_mac_check() {
    log "INFO" "Starting MAC address configuration check..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "DRY RUN MODE - This will check configuration without making changes"
    fi
    
    # Run MAC address check script
    if ! run_script "scripts/check-mac-addresses.sh"; then
        log "ERROR" "MAC address check failed"
        log "ERROR" "Please fix MAC address configuration before proceeding with setup"
        exit 1
    fi
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "DRY RUN completed - MAC address check performed"
    else
        log "INFO" "✅ MAC Address Check Complete!"
        log "INFO" "All MAC addresses are properly configured"
        log "INFO" ""
        log "INFO" "Next Steps:"
        log "INFO" "1. Run network configuration: $0 --network"
        log "INFO" "2. Create pfSense VM: $0 --pfsense" 
        log "INFO" "3. Create admin container: $0 --firewalladmin"
        log "INFO" "4. Configure HTTPS: $0 --caddy"
        log "INFO" ""
        log "INFO" "Logs are available at: $LOG_FILE"
    fi
}

# Run complete setup (future implementation)
run_complete_setup() {
    log "INFO" "Complete setup not yet implemented"
    log "INFO" "For now, run setup commands in sequence:"
    log "INFO" "1. $0 --network"
    log "INFO" "2. $0 --pfsense"
    log "INFO" "3. $0 --firewalladmin"
    log "INFO" "4. $0 --caddy"
    exit 1
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Check if running as root (unless dry-run)
    if [[ "${1:-}" != "--dry-run" && "${1:-}" != "-d" ]]; then
        check_root
    fi
    
    # Parse arguments and run
    parse_args "$@"
    main
fi

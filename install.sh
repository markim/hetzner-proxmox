#!/bin/bash

# Hetzner Proxmox Setup - Main Installation Script
# This script orchestrates the complete setup process

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

# Load default environment (will be overridden by parse_args if needed)
# Only load_env if we're not just showing help
if [[ "${1:-}" != "--help" ]] && [[ "${1:-}" != "-h" ]] && [[ "${1:-}" != "" ]]; then
    load_env 2>/dev/null || true
fi

# Usage information
usage() {
    cat << EOF
Usage: $0 [COMMAND] [OPTIONS]

Automated setup for Hetzner Proxmox server with Caddy reverse proxy and HTTPS.

COMMANDS:
    (no command)        Show this help and available commands
    --setup-system      Optimize host system for Proxmox and ensure /var/lib/vz partition exists
    --format-drives     Format non-system drives interactively (safe, asks for confirmation)
    --setup-mirrors     Scan drives and configure optimal RAID mirror arrays (interactive)
    --remove-mirrors    Remove ALL RAID mirror configurations including system mirrors (preserves data on drives)
    --caddy             Install and configure Caddy with HTTPS (current functionality)
    --network           Configure network interfaces for additional Hetzner IPs
    --network --reset   Reset network configuration to base ariadata pve-install.sh configuration
    --pfsense           Create and configure pfSense firewall VM (requires --network first)
    --firewalladmin     Create Fedora container for firewall administration (requires --pfsense first)
    --check-mac         Verify MAC address configuration for additional IPs

OPTIONS:
    -h, --help          Show this help message
    -c, --config FILE   Use specific environment file (default: .env)
    -v, --verbose       Enable verbose logging

EXAMPLES:
    $0                          # Show available commands (safe - shows help only)
    $0 --check-mac              # Verify MAC address configuration (recommended first step)
    $0 --setup-system           # Optimize host system for Proxmox and setup /var/lib/vz partition
    $0 --format-drives          # Format non-system drives interactively
    $0 --setup-mirrors          # Scan drives and configure optimal RAID mirror arrays
    $0 --remove-mirrors         # Remove ALL RAID mirror configurations including system mirrors
    $0 --caddy                  # Install Caddy with current configuration
    $0 --network                # Configure network interfaces for additional IPs
    $0 --network --reset        # Reset to base ariadata pve-install.sh network configuration
    $0 --pfsense                # Create pfSense VM after network configuration
    $0 --firewalladmin          # Create firewall admin container after pfSense setup

RECOMMENDED WORKFLOW:
    1. $0 --check-mac           # Verify MAC addresses are correct
    2. $0 --format-drives       # (Optional) Format any drives that need clean state
    3. $0 --network             # Apply network configuration
    5. $0 --caddy               # Install Caddy reverse proxy
    6. $0 --pfsense             # (Optional) Create pfSense firewall
    7. $0 --firewalladmin       # (Optional) Create admin VM for pfSense

REQUIREMENTS:
    - Fresh Proxmox installation on Hetzner server
    - Domain name pointing to server IP (for --caddy)
    - Properly configured .env file

NETWORK SETUP:
    Configure additional IPs in one of these ways:
    1. Create config/additional-ips.conf file
    2. Set structured environment variables (ADDITIONAL_IP_1, ADDITIONAL_MAC_1, etc.)
    
    See .env.example for configuration examples.

SAFETY NOTES:
    - Network configuration includes automatic backup and restore capabilities
    - SSH connectivity is preserved during network changes
    - Emergency restore script is created: /root/restore-network.sh

EOF
}

# Parse command line arguments
parse_args() {
    local config_file=""
    local command=""
    declare -a command_args=()
    
    # Parse command first
    if [[ $# -gt 0 ]] && [[ "$1" =~ ^--.* ]]; then
        case $1 in
            --caddy)
                command="caddy"
                shift
                ;;
            --setup-system)
                command="setup-system"
                shift
                ;;
            --network)
                command="network"
                shift
                # Check for --reset flag
                if [[ $# -gt 0 && "$1" == "--reset" ]]; then
                    command_args+=("--reset")
                    shift
                fi
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
            --setup-mirrors)
                command="setup-mirrors"
                shift
                ;;
            --remove-mirrors)
                command="remove-mirrors"
                shift
                ;;
            --format-drives)
                command="format-drives"
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
            -v|--verbose)
                export LOG_LEVEL="DEBUG"
                shift
                ;;
            --force-zfs-drives)
                # Legacy option - now handled interactively in setup-mirrors
                log "INFO" "Note: Drive selection is now handled interactively"
                shift
                ;;
            --caddy|--setup-system|--network|--pfsense|--firewalladmin|--check-mac|--setup-mirrors|--remove-mirrors|--format-drives)
                # Already handled above
                # Skip --reset flag for --network if present
                if [[ "$1" == "--reset" ]]; then
                    shift
                fi
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
    
    export COMMAND="$command"
    # Simple approach - don't create temp file if no args
    if [[ ${#command_args[@]} -gt 0 ]]; then
        printf '%s\n' "${command_args[@]}" > "/tmp/install_command_args_$$"
    fi
    
}

# Validate environment and requirements
validate_setup() {
    log "INFO" "Validating setup requirements..."
    
    # Different validation based on command
    case "${COMMAND:-}" in
        "setup-system")
            # System setup validation
            log "INFO" "System setup validation will be performed by setup-system.sh"
            ;;
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
        "check-mac")
            # MAC address check doesn't require special validation - it just checks configuration
            log "INFO" "MAC address configuration check - no prerequisites required"
            ;;
        "format-drives")
            # Drive formatting - check we have the required tools
            log "INFO" "Drive formatting - checking for required tools"
            if ! command -v lsblk &> /dev/null; then
                log "ERROR" "lsblk command not found. Required for drive management."
                exit 1
            fi
            if ! command -v parted &> /dev/null; then
                log "ERROR" "parted command not found. Required for partitioning."
                exit 1
            fi
            ;;
        "setup-mirrors")
            # Drive mirror setup - check we have the required tools
            log "INFO" "Drive mirror setup - checking for required tools"
            if ! command -v lsblk &> /dev/null; then
                log "ERROR" "lsblk command not found. Required for drive management."
                exit 1
            fi
            ;;
        "drives")
            # Drives configuration - check we have the required tools
            log "INFO" "Drive configuration - checking for required tools"
            if ! command -v lsblk &> /dev/null; then
                log "ERROR" "lsblk command not found. Required for drive management."
                exit 1
            fi
            ;;
        "remove-mirrors")
            # RAID mirror removal - check we have the required tools
            log "INFO" "RAID mirror removal - checking for required tools"
            if ! command -v findmnt &> /dev/null; then
                log "ERROR" "findmnt command not found. Required for mount detection."
                exit 1
            fi
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


run_script() {
    local script="$1"
    shift # Remove script name, remaining arguments will be passed to the script
    local script_path="$SCRIPT_DIR/$script"
    
    if [[ ! -f "$script_path" ]]; then
        log "ERROR" "Script not found: $script_path"
        exit 1
    fi
    
    log "INFO" "Executing: $script"
    if ! bash "$script_path" "$@"; then
        log "ERROR" "Failed to execute: $script"
        exit 1
    fi
}


# Run Caddy setup (original functionality)
run_caddy_setup() {
    log "INFO" "Starting Hetzner Proxmox Caddy setup..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    # Validate setup for Caddy
    validate_setup
    
    # Run Caddy setup script
    local script_path="$SCRIPT_DIR/scripts/setup-caddy.sh"
    
    if [[ ! -f "$script_path" ]]; then
        log "ERROR" "Caddy setup script not found: $script_path"
        exit 1
    fi
    
    # Build arguments for the Caddy setup script
    local caddy_args=()
    
    # Add verbose flag if set
    if [[ "${LOG_LEVEL:-}" == "DEBUG" ]]; then
        caddy_args+=("--verbose")
    fi
     log "INFO" "Executing Caddy setup script..."

    if ! bash "$script_path" "${caddy_args[@]}"; then
        log "ERROR" "Caddy setup failed"
        exit 1
    fi

    # Also run HTTPS configuration script
    local https_script_path="$SCRIPT_DIR/scripts/setup-https.sh"
    
    if [[ ! -f "$https_script_path" ]]; then
        log "ERROR" "HTTPS setup script not found: $https_script_path"
        exit 1
    fi

    log "INFO" "Executing HTTPS configuration script..."

    if ! bash "$https_script_path" "${caddy_args[@]}"; then
        log "ERROR" "HTTPS configuration failed"
        exit 1
    fi
    
    log "INFO" "✅ Caddy Setup Complete!"
    log "INFO" "Caddy is now installed, configured, and running"
    log "INFO" ""
    log "INFO" "You should now be able to access Proxmox at: https://$DOMAIN"
    log "INFO" ""
    log "INFO" "If HTTPS is not working yet:"
    log "INFO" "1. Ensure your domain DNS points to this server's IP"
    log "INFO" "2. Check that ports 80 and 443 are open"
    log "INFO" "3. Monitor Caddy logs: journalctl -u caddy -f"
    log "INFO" "4. Check Caddy access logs: tail -f $CADDY_LOG_FILE"
    log "INFO" ""
    log "INFO" "Important Notes:"
    log "INFO" "- SSL certificates are automatically managed by Caddy"
    log "INFO" "- Ensure your firewall allows traffic on ports 80 and 443"
    log "INFO" ""
    log "INFO" "Logs are available at: $LOG_FILE"
}


# Run network setup
run_network_setup() {
    log "INFO" "Starting Hetzner Proxmox network configuration..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    # Enable verbose logging for network operations to help with debugging
    # Only if not already set
    if [[ "${LOG_LEVEL:-}" != "DEBUG" ]]; then
        export LOG_LEVEL="DEBUG"
    fi
    
    # Build arguments for the network script
    local network_args=()
    
    # Read command args from temp file
    if [[ -f "/tmp/install_command_args_$$" ]]; then
        while IFS= read -r arg; do
            [[ -n "$arg" ]] && network_args+=("$arg")
        done < "/tmp/install_command_args_$$"
        rm -f "/tmp/install_command_args_$$"
    fi
    
    # Add verbose flag to network script
    network_args+=("--verbose")
    
    # Run network configuration script with arguments
    if [[ ${#network_args[@]} -gt 0 ]]; then
        run_script "scripts/configure-network.sh" "${network_args[@]}"
    else
        run_script "scripts/configure-network.sh" "--verbose"
    fi

    log "INFO" "✅ Network Configuration Complete!"
    log "INFO" "Network bridges have been configured successfully"
    log "INFO" ""
    log "INFO" "Next Steps:"
    log "INFO" "1. Install Caddy: $0 --caddy"
    log "INFO" "2. Create pfSense VM: $0 --pfsense"
    log "INFO" ""
    log "INFO" "Logs are available at: $LOG_FILE"
}

# Run pfSense setup
run_pfsense_setup() {
    log "INFO" "Starting Hetzner Proxmox pfSense setup..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    # Run pfSense setup script
    run_script "scripts/setup-pfsense.sh"

    log "INFO" "✅ pfSense Setup Complete!"
    log "INFO" "pfSense VM has been created successfully"
    log "INFO" ""
    log "INFO" "Next Steps:"
    log "INFO" "1. Access pfSense via Proxmox console to complete initial setup"
    log "INFO" "2. Create firewall admin VM: $0 --firewalladmin"
    log "INFO" ""
    log "INFO" "Logs are available at: $LOG_FILE"
}

# Run firewall admin setup
run_firewall_admin_setup() {
    log "INFO" "Starting Hetzner Proxmox firewall admin setup..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    # Run firewall admin setup script
    run_script "scripts/setup-firewall-admin.sh"

    log "INFO" "✅ Firewall Admin Setup Complete!"
    log "INFO" "Firewall admin VM has been created successfully"
    log "INFO" ""
    log "INFO" "Next Steps:"
    log "INFO" "1. Access the admin VM via Proxmox console"
    log "INFO" "2. Use the admin VM to configure pfSense via web interface"
    log "INFO" ""
    log "INFO" "Logs are available at: $LOG_FILE"
}

# Run MAC address check
run_mac_check() {
    log "INFO" "Starting MAC address verification..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    # Run MAC address check script
    run_script "scripts/check-mac-addresses.sh"
    
    log "INFO" "✅ MAC Address Check Complete!"
    log "INFO" ""
    log "INFO" "If MAC addresses are correctly configured, proceed with:"
    log "INFO" "1. Network setup: $0 --network"
    log "INFO" "2. Caddy setup: $0 --caddy"
    log "INFO" ""
    log "INFO" "Logs are available at: $LOG_FILE"
}

# Run mirror setup
run_setup_mirrors() {
    log "INFO" "Starting drive configuration and RAID mirror setup..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    # Read command args from temp file
    local command_args=()
    if [[ -f "/tmp/install_command_args_$$" ]]; then
        while IFS= read -r arg; do
            [[ -n "$arg" ]] && command_args+=("$arg")  # Only add non-empty args
        done < "/tmp/install_command_args_$$"
        rm -f "/tmp/install_command_args_$$"
    fi
    
    # Run drives setup script - always run interactively unless explicitly passed --yes
    if [[ ${#command_args[@]} -gt 0 ]]; then
        run_script "scripts/setup-mirrors.sh" "${command_args[@]}"
    else
        # When called from install.sh without arguments, run in interactive mode
        run_script "scripts/setup-mirrors.sh"
    fi
    
    log "INFO" "✅ Drive Mirror Configuration Complete!"
    log "INFO" "Drive mirrors have been configured successfully"
    log "INFO" ""
    log "INFO" "Next Steps:"
    log "INFO" "1. Verify storage pools in Proxmox web interface"
    log "INFO" "2. Configure network: $0 --network"
    log "INFO" "3. Install Caddy: $0 --caddy"
    log "INFO" ""
    log "INFO" "Logs are available at: $LOG_FILE"
}

# Run RAID mirror removal
run_remove_mirrors() {
    log "INFO" "Starting RAID mirror removal..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    # Run RAID removal script
    run_script "scripts/remove-mirrors.sh"
    
    log "INFO" "✅ RAID Mirror Removal Complete!"
    log "INFO" "ALL RAID mirror configurations have been removed (including system mirrors)"
    log "INFO" "Original data remains on individual drives"
    log "INFO" ""
    log "INFO" "⚠️  IMPORTANT: System may need to be rebooted to boot from individual drives"
    log "INFO" ""
    log "INFO" "Next Steps:"
    log "INFO" "1. Run drive configuration: $0 --setup-mirrors"
    log "INFO" "2. Configure network: $0 --network"
    log "INFO" "3. Install Caddy: $0 --caddy"
    log "INFO" ""
    log "INFO" "Logs are available at: $LOG_FILE"
}


# Run drive formatting
run_format_drives() {
    log "INFO" "Starting drive formatting process..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    # Run drive formatting script
    run_script "scripts/format-drives.sh"
    
    log "INFO" "✅ Drive Formatting Complete!"
    log "INFO" "Selected drives have been formatted successfully"
    log "INFO" ""
    log "INFO" "Next Steps:"
    log "INFO" "1. Configure RAID mirrors: $0 --setup-mirrors"
    log "INFO" "2. Configure network: $0 --network"
    log "INFO" "3. Install Caddy: $0 --caddy"
    log "INFO" ""
    log "INFO" "Logs are available at: $LOG_FILE"
}


# Run system setup and optimization
run_setup_system() {
    log "INFO" "Starting Proxmox system optimization and setup..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    # Run system setup script
    run_script "scripts/setup-system.sh"
    
    log "INFO" "✅ System Setup Complete!"
    log "INFO" "Host system has been optimized for Proxmox"
    log "INFO" "Data partition has been configured (if space was available)"
    log "INFO" ""
    log "INFO" "Next Steps:"
    log "INFO" "1. Reboot to ensure all optimizations are active"
    log "INFO" "2. Format additional drives: $0 --format-drives"
    log "INFO" "3. Setup RAID mirrors: $0 --setup-mirrors"
    log "INFO" "4. Configure network: $0 --network"
    log "INFO" "5. Install Caddy: $0 --caddy"
    log "INFO" ""
    log "INFO" "Logs are available at: $LOG_FILE"
}


# Main installation function
main() {
    case "${COMMAND:-}" in
        "setup-system")
            run_setup_system
            ;;
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
        "format-drives")
            run_format_drives
            ;;
        "setup-mirrors")
            run_setup_mirrors
            ;;
        "drives")
            run_drives_setup
            ;;
        "remove-mirrors")
            run_remove_mirrors
            ;;
        *)
            # No command specified - show usage and exit safely
            log "INFO" "Hetzner Proxmox Setup Script"
            log "INFO" "=============================="
            echo
            log "INFO" "⚠️  No command specified. This script requires explicit commands for safety."
            echo
            log "INFO" "Available commands:"
            log "INFO" "  --check-mac      ⭐ START HERE - Verify MAC address configuration"
            log "INFO" "  --setup-system   🚀 Optimize host system for Proxmox and setup /var/lib/vz partition"
            log "INFO" "  --format-drives  🧹 Format non-system drives interactively (safe)"
            log "INFO" "  --remove-mirrors 🧹 Remove ALL RAID mirror configurations including system (preserves data)"
            log "INFO" "  --setup-mirrors  🔧 Scan drives and configure optimal RAID mirror arrays"
            log "INFO" "  --caddy          🌐 Install Caddy reverse proxy with HTTPS"
            log "INFO" "  --network        🔗 Configure network interfaces for additional IPs"
            log "INFO" "  --network --reset🔄 Reset to base ariadata pve-install.sh network configuration"
            log "INFO" "  --pfsense        🔥 Create pfSense firewall VM (requires --network first)"
            log "INFO" "  --firewalladmin  🖥️  Create firewall admin container (requires --pfsense first)"
            echo
            log "INFO" "Safety features:"
            log "INFO" "  --verbose        Enable detailed logging"
            log "INFO" "  --help           Show detailed usage information"
            echo
            log "INFO" "Recommended first-time workflow:"
            log "INFO" "  1. $0 --check-mac     # Verify your configuration"
            log "INFO" "  2. $0 --setup-system  # Optimize system and setup /var/lib/vz partition"
            log "INFO" "  3. $0 --format-drives # (Optional) Format drives for clean state"
            log "INFO" "  4. $0 --setup-mirrors # Configure RAID arrays"
            log "INFO" "  5. $0 --network       # Configure network"
            log "INFO" "  6. $0 --caddy         # Install Caddy"
            echo
            log "INFO" "⚠️  NEVER run without specifying a command - this prevents accidental execution!"
            exit 0
            ;;
    esac
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Parse command line arguments
    parse_args "$@"
    
    # Validate setup requirements
    validate_setup
    
    # Execute main function
    main
fi
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
load_env

# Usage information
usage() {
    cat << EOF
Usage: $0 [COMMAND] [OPTIONS]

Automated setup for Hetzner Proxmox server with Caddy reverse proxy and HTTPS.

COMMANDS:
    (no command)        Show this help and available commands
    --preparedrives     Scan drives and configure optimal RAID arrays
    --format-drives     Format all non-system drives and remove existing RAID arrays
    --caddy             Install and configure Caddy with HTTPS (current functionality)
    --network           Configure network interfaces for additional Hetzner IPs
    --pfsense           Create and configure pfSense firewall VM (requires --network first)
    --firewalladmin     Create Fedora container for firewall administration (requires --pfsense first)
    --check-mac         Verify MAC address configuration for additional IPs

OPTIONS:
    -h, --help          Show this help message
    -c, --config FILE   Use specific environment file (default: .env)
    -d, --dry-run       Show what would be done without executing
    -v, --verbose       Enable verbose logging

EXAMPLES:
    $0                          # Show available commands (safe - shows help only)
    $0 --check-mac              # Verify MAC address configuration (recommended first step)
    $0 --format-drives          # Format all non-system drives and remove RAID arrays
    $0 --format-drives --dry-run # Preview which drives would be formatted
    $0 --preparedrives          # Scan drives and show optimal RAID configurations
    $0 --preparedrives --config <detected> --dry-run   # Preview setup for your drives
    $0 --caddy                  # Install Caddy with current configuration
    $0 --network                # Configure network interfaces for additional IPs
    $0 --pfsense                # Create pfSense VM after network configuration
    $0 --firewalladmin          # Create firewall admin container after pfSense setup
    $0 --caddy -c prod.env      # Use custom environment file
    $0 --network --dry-run      # Show network changes without executing

RECOMMENDED WORKFLOW:
    1. $0 --check-mac           # Verify MAC addresses are correct
    2. $0 --network --dry-run   # Preview network configuration
    3. $0 --network             # Apply network configuration
    4. $0 --caddy --dry-run     # Preview Caddy installation
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
    local dry_run=false
    local command=""
    
    # Parse command first
    if [[ $# -gt 0 ]] && [[ "$1" =~ ^--.* ]]; then
        case $1 in
            --preparedrives)
                command="preparedrives"
                shift
                ;;
            --format-drives)
                command="format-drives"
                shift
                ;;
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
            --raid-config)
                export RAID_CONFIG="$2"
                shift 2
                ;;
            --caddy|--network|--pfsense|--firewalladmin|--check-mac|--preparedrives|--format-drives)
                # Already handled above
                shift
                ;;
            *)
                # For drive preparation, pass unknown arguments through
                if [[ "$command" == "preparedrives" ]]; then
                    # Store remaining arguments for drive preparation script
                    export DRIVE_ARGS="$*"
                    break
                else
                    log "ERROR" "Unknown option: $1"
                    usage
                    exit 1
                fi
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
    
    # Safety check for destructive commands
    if [[ "$command" == "format-drives" ]] && [[ "$dry_run" == "false" ]]; then
        log "WARN" "⚠️  You are about to FORMAT ALL NON-SYSTEM DRIVES!"
        log "WARN" "⚠️  This will PERMANENTLY DESTROY ALL DATA on those drives!"
        log "WARN" "⚠️  Consider running with --dry-run first to preview the changes."
        echo
        log "WARN" "Type 'I UNDERSTAND AND WANT TO FORMAT DRIVES' to continue:"
        read -r confirmation
        if [[ "$confirmation" != "I UNDERSTAND AND WANT TO FORMAT DRIVES" ]]; then
            log "INFO" "Operation cancelled for safety. Use --dry-run to preview changes."
            exit 0
        fi
    fi
}

# Validate environment and requirements
validate_setup() {
    log "INFO" "Validating setup requirements..."
    
    # Different validation based on command
    case "${COMMAND:-}" in
        "preparedrives")
            # Drive preparation has its own validation
            log "INFO" "Drive preparation validation will be performed by prepare-drives.sh"
            # Basic check for required tools
            if ! command -v lsblk &> /dev/null; then
                log "ERROR" "lsblk command not found. Please install util-linux package."
                exit 1
            fi
            ;;
        "format-drives")
            # Drive formatting requires root access and confirmation
            log "INFO" "Drive formatting validation will be performed by format-drives.sh"
            # Basic check for required tools
            if ! command -v wipefs &> /dev/null; then
                log "ERROR" "wipefs command not found. Please install util-linux package."
                exit 1
            fi
            if ! command -v mdadm &> /dev/null; then
                log "ERROR" "mdadm command not found. Please install mdadm package."
                exit 1
            fi
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
        "all")
            # Disabled for safety
            log "ERROR" "The --all command has been disabled for safety"
            log "ERROR" "Please run individual components manually"
            exit 1
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


# Run Caddy setup (original functionality)
run_caddy_setup() {
    log "INFO" "Starting Hetzner Proxmox Caddy setup..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    # Validate setup for Caddy
    validate_setup
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "DRY RUN MODE - No changes will be made"
    fi
    
    # Run Caddy setup script
    local script_path="$SCRIPT_DIR/scripts/setup-caddy.sh"
    
    if [[ ! -f "$script_path" ]]; then
        log "ERROR" "Caddy setup script not found: $script_path"
        exit 1
    fi
    
    # Build arguments for the Caddy setup script
    local caddy_args=()
    
    # Add dry-run flag if set
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        caddy_args+=("--dry-run")
    fi
    
    # Add verbose flag if set
    if [[ "${LOG_LEVEL:-}" == "DEBUG" ]]; then
        caddy_args+=("--verbose")
    fi
    
    log "INFO" "Executing Caddy setup script..."
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "Command: bash $script_path ${caddy_args[*]}"
    fi
    
    if ! bash "$script_path" "${caddy_args[@]}"; then
        log "ERROR" "Caddy setup failed"
        exit 1
    fi
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "DRY RUN completed - no changes were made"
        log "INFO" "To execute for real, run without --dry-run flag"
    else
        log "INFO" "✅ Caddy Setup Complete!"
        log "INFO" "Caddy is now installed and configured"
        log "INFO" ""
        log "INFO" "Next Steps:"
        log "INFO" "1. Configure your domain DNS to point to this server"
        log "INFO" "2. Obtain SSL certificate (if not using Caddy's automatic HTTPS)"
        log "INFO" "3. Access Caddy at: http://<your-server-ip> or https://<your-domain>"
        log "INFO" ""
        log "INFO" "Important Notes:"
        log "INFO" "- If you encounter issues, check the Caddy logs at $CADDY_LOG_FILE"
        log "INFO" "- Ensure your firewall allows traffic on ports 80 and 443"
        log "INFO" ""
        log "INFO" "Logs are available at: $LOG_FILE"
    fi
}

# Run drive formatting
run_drive_formatting() {
    log "INFO" "Starting Hetzner Proxmox drive formatting..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "DRY RUN MODE - No changes will be made"
    fi
    
    # Run drive formatting script
    local script_path="$SCRIPT_DIR/scripts/format-drives.sh"
    
    if [[ ! -f "$script_path" ]]; then
        log "ERROR" "Drive formatting script not found: $script_path"
        log "INFO" "Creating format-drives.sh script..."
        create_format_drives_script
    fi
    
    # Build arguments for the drive formatting script
    local format_args=()
    
    # Add dry-run flag if set
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        format_args+=("--dry-run")
    fi
    
    # Add verbose flag if set
    if [[ "${LOG_LEVEL:-}" == "DEBUG" ]]; then
        format_args+=("--verbose")
    fi
    
    log "INFO" "Executing drive formatting script..."
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "Command: bash $script_path ${format_args[*]}"
    fi
    
    if ! bash "$script_path" "${format_args[@]}"; then
        log "ERROR" "Drive formatting failed"
        exit 1
    fi
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "DRY RUN completed - no changes were made"
        log "INFO" "To execute for real, run without --dry-run flag"
        log "INFO" ""
        log "INFO" "⚠️  WARNING: This will permanently destroy all data on non-system drives!"
        log "INFO" "   Make sure you have backups of any important data."
        log "INFO" ""
        log "INFO" "The following operations will be performed:"
        log "INFO" "1. Stop and remove existing RAID arrays (md0, etc.)"
        log "INFO" "2. Wipe filesystem signatures from all non-system drives"
        log "INFO" "3. Clear partition tables"
        log "INFO" "4. Drives will be ready for fresh RAID configuration"
    else
        log "INFO" "✅ Drive Formatting Complete!"
        log "INFO" "All non-system drives have been formatted and are ready for use"
        log "INFO" ""
        log "INFO" "Next Steps:"
        log "INFO" "1. Run drive preparation: $0 --preparedrives --dry-run"
        log "INFO" "2. Review suggested RAID configuration"
        log "INFO" "3. Apply RAID configuration: $0 --preparedrives --config <suggested>"
        log "INFO" "4. Continue with network setup: $0 --network"
        log "INFO" ""
        log "INFO" "Important Notes:"
        log "INFO" "- All previous RAID arrays have been removed"
        log "INFO" "- Drive partition tables have been cleared"
        log "INFO" "- Drives are now ready for fresh configuration"
        log "INFO" ""
        log "INFO" "Logs are available at: $LOG_FILE"
    fi
}

# Create format-drives.sh script if it doesn't exist
create_format_drives_script() {
    local script_path="$SCRIPT_DIR/scripts/format-drives.sh"
    
    cat > "$script_path" << 'EOF'
#!/bin/bash

# Format Non-System Drives Script
# This script safely formats all non-system drives and removes RAID arrays

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/common.sh"

# Default values
DRY_RUN=false
VERBOSE=false

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                export LOG_LEVEL="DEBUG"
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Format all non-system drives and remove existing RAID arrays.

OPTIONS:
    --dry-run       Show what would be done without executing
    --verbose       Enable verbose logging
    -h, --help      Show this help message

WARNING: This will permanently destroy all data on non-system drives!

EOF
}

# Detect system drive (the one with mounted partitions)
detect_system_drive() {
    log "INFO" "Detecting system drive..."
    
    # Find drives with mounted partitions
    local system_drives=()
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            system_drives+=("$line")
        fi
    done < <(lsblk -ndo NAME,MOUNTPOINT | awk '$2 != "" {print "/dev/" $1}' | sed 's/[0-9]*$//' | sort -u)
    
    if [[ ${#system_drives[@]} -eq 0 ]]; then
        log "ERROR" "No system drive detected"
        exit 1
    fi
    
    log "INFO" "System drives detected: ${system_drives[*]}"
    printf '%s\n' "${system_drives[@]}"
}

# Get all block devices
get_all_drives() {
    lsblk -ndo NAME | grep -E '^(sd|nvme|vd)' | sed 's|^|/dev/|'
}

# Get non-system drives
get_non_system_drives() {
    local system_drives
    mapfile -t system_drives < <(detect_system_drive)
    
    local all_drives
    mapfile -t all_drives < <(get_all_drives)
    
    local non_system_drives=()
    for drive in "${all_drives[@]}"; do
        local is_system=false
        for sys_drive in "${system_drives[@]}"; do
            if [[ "$drive" == "$sys_drive" ]]; then
                is_system=true
                break
            fi
        done
        if [[ "$is_system" == "false" ]]; then
            non_system_drives+=("$drive")
        fi
    done
    
    printf '%s\n' "${non_system_drives[@]}"
}

# Stop and remove RAID arrays
stop_raid_arrays() {
    log "INFO" "Checking for existing RAID arrays..."
    
    if [[ ! -f /proc/mdstat ]]; then
        log "INFO" "No RAID arrays found"
        return 0
    fi
    
    local raid_devices
    mapfile -t raid_devices < <(awk '/^md/ {print "/dev/" $1}' /proc/mdstat)
    
    if [[ ${#raid_devices[@]} -eq 0 ]]; then
        log "INFO" "No active RAID arrays found"
        return 0
    fi
    
    for raid_dev in "${raid_devices[@]}"; do
        log "INFO" "Processing RAID device: $raid_dev"
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log "INFO" "[DRY-RUN] Would stop RAID array: $raid_dev"
        else
            log "INFO" "Stopping RAID array: $raid_dev"
            if mdadm --stop "$raid_dev" 2>/dev/null; then
                log "INFO" "Successfully stopped: $raid_dev"
            else
                log "WARN" "Failed to stop or already stopped: $raid_dev"
            fi
        fi
    done
    
    # Remove RAID configuration
    if [[ "$DRY_RUN" == "true" ]]; then
        log "INFO" "[DRY-RUN] Would remove RAID configuration from drives"
    else
        log "INFO" "Removing RAID configuration from drives..."
        local non_system_drives
        mapfile -t non_system_drives < <(get_non_system_drives)
        
        for drive in "${non_system_drives[@]}"; do
            if mdadm --zero-superblock "$drive" 2>/dev/null; then
                log "INFO" "Removed RAID superblock from: $drive"
            else
                log "DEBUG" "No RAID superblock found on: $drive"
            fi
        done
    fi
}

# Format a single drive
format_drive() {
    local drive="$1"
    
    log "INFO" "Formatting drive: $drive"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "INFO" "[DRY-RUN] Would format: $drive"
        log "INFO" "[DRY-RUN]   - Clear partition table"
        log "INFO" "[DRY-RUN]   - Wipe filesystem signatures"
        return 0
    fi
    
    # Clear partition table
    log "INFO" "Clearing partition table on: $drive"
    if wipefs -af "$drive" 2>/dev/null; then
        log "INFO" "Partition table cleared: $drive"
    else
        log "WARN" "Failed to clear partition table: $drive"
    fi
    
    # Zero out the beginning of the drive
    log "INFO" "Zeroing beginning of drive: $drive"
    if dd if=/dev/zero of="$drive" bs=1M count=100 2>/dev/null; then
        log "INFO" "Drive beginning zeroed: $drive"
    else
        log "WARN" "Failed to zero drive beginning: $drive"
    fi
    
    # Make sure kernel recognizes the changes
    if command -v partprobe &> /dev/null; then
        partprobe "$drive" 2>/dev/null || true
    fi
    
    log "INFO" "Drive formatted successfully: $drive"
}

# Run drive preparation
run_drive_preparation() {
    log "INFO" "Starting Hetzner Proxmox drive preparation..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "DRY RUN MODE - No changes will be made"
    fi
    
    # Run drive preparation script
    local script_path="$SCRIPT_DIR/scripts/prepare-drives.sh"
    
    if [[ ! -f "$script_path" ]]; then
        log "ERROR" "Drive preparation script not found: $script_path"
        exit 1
    fi
    
    # Build arguments for the drive preparation script
    local prep_args=()
    
    # Add dry-run flag if set
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        prep_args+=("--dry-run")
    fi
    
    # Add verbose flag if set
    if [[ "${LOG_LEVEL:-}" == "DEBUG" ]]; then
        prep_args+=("--verbose")
    fi
    
    # Add any additional drive args passed through
    if [[ -n "${DRIVE_ARGS:-}" ]]; then
        # Split DRIVE_ARGS and add to array
        IFS=' ' read -ra additional_args <<< "${DRIVE_ARGS}"
        prep_args+=("${additional_args[@]}")
    fi
    
    log "INFO" "Executing drive preparation script..."
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "Command: bash $script_path ${prep_args[*]}"
    fi
    
    if ! bash "$script_path" "${prep_args[@]}"; then
        log "ERROR" "Drive preparation failed"
        exit 1
    fi
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "DRY RUN completed - no changes were made"
        log "INFO" "To execute for real, run without --dry-run flag"
    else
        log "INFO" "✅ Drive Preparation Complete!"
        log "INFO" "Drive preparation has been completed successfully"
        log "INFO" ""
        log "INFO" "Next Steps:"
        log "INFO" "1. Review any RAID configurations that were created"
        log "INFO" "2. Continue with network setup: $0 --network"
        log "INFO" "3. Install Caddy: $0 --caddy"
        log "INFO" ""
        log "INFO" "Logs are available at: $LOG_FILE"
    fi
}

# Run network setup
run_network_setup() {
    log "INFO" "Starting Hetzner Proxmox network configuration..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
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
        log "INFO" "Network bridges have been configured successfully"
        log "INFO" ""
        log "INFO" "Next Steps:"
        log "INFO" "1. Install Caddy: $0 --caddy"
        log "INFO" "2. Create pfSense VM: $0 --pfsense"
        log "INFO" ""
        log "INFO" "Logs are available at: $LOG_FILE"
    fi
}

# Run pfSense setup
run_pfsense_setup() {
    log "INFO" "Starting Hetzner Proxmox pfSense setup..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "DRY RUN MODE - No changes will be made"
    fi
    
    # Run pfSense setup script
    run_script "scripts/setup-pfsense.sh"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "DRY RUN completed - no changes were made"
        log "INFO" "To execute for real, run without --dry-run flag"
    else
        log "INFO" "✅ pfSense Setup Complete!"
        log "INFO" "pfSense VM has been created successfully"
        log "INFO" ""
        log "INFO" "Next Steps:"
        log "INFO" "1. Access pfSense via Proxmox console to complete initial setup"
        log "INFO" "2. Create firewall admin VM: $0 --firewalladmin"
        log "INFO" ""
        log "INFO" "Logs are available at: $LOG_FILE"
    fi
}

# Run firewall admin setup
run_firewall_admin_setup() {
    log "INFO" "Starting Hetzner Proxmox firewall admin setup..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "DRY RUN MODE - No changes will be made"
    fi
    
    # Run firewall admin setup script
    run_script "scripts/setup-firewall-admin.sh"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "DRY RUN completed - no changes were made"
        log "INFO" "To execute for real, run without --dry-run flag"
    else
        log "INFO" "✅ Firewall Admin Setup Complete!"
        log "INFO" "Firewall admin VM has been created successfully"
        log "INFO" ""
        log "INFO" "Next Steps:"
        log "INFO" "1. Access the admin VM via Proxmox console"
        log "INFO" "2. Use the admin VM to configure pfSense via web interface"
        log "INFO" ""
        log "INFO" "Logs are available at: $LOG_FILE"
    fi
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

# Main installation function
main() {
    case "${COMMAND:-}" in
        "preparedrives")
            # shellcheck disable=SC2119
            run_drive_preparation
            ;;
        "format-drives")
            run_drive_formatting
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
        *)
            # No command specified - show usage and exit safely
            log "INFO" "Hetzner Proxmox Setup Script"
            log "INFO" "=============================="
            echo
            log "INFO" "⚠️  No command specified. This script requires explicit commands for safety."
            echo
            log "INFO" "Available commands:"
            log "INFO" "  --check-mac      ⭐ START HERE - Verify MAC address configuration"
            log "INFO" "  --format-drives  ⚠️  Format all non-system drives and remove RAID arrays"
            log "INFO" "  --preparedrives  🔧 Prepare drives and configure RAID arrays"
            log "INFO" "  --caddy          🌐 Install Caddy reverse proxy with HTTPS"
            log "INFO" "  --network        🔗 Configure network interfaces for additional IPs"
            log "INFO" "  --pfsense        🔥 Create pfSense firewall VM (requires --network first)"
            log "INFO" "  --firewalladmin  🖥️  Create firewall admin container (requires --pfsense first)"
            echo
            log "INFO" "Safety features:"
            log "INFO" "  --dry-run        Preview changes without executing"
            log "INFO" "  --verbose        Enable detailed logging"
            log "INFO" "  --help           Show detailed usage information"
            echo
            log "INFO" "Recommended first-time workflow:"
            log "INFO" "  1. $0 --check-mac --dry-run     # Verify your configuration"
            log "INFO" "  2. $0 --network --dry-run       # Preview network changes"
            log "INFO" "  3. $0 --caddy --dry-run         # Preview Caddy installation"
            log "INFO" "  4. Remove --dry-run to execute for real"
            echo
            log "INFO" "⚠️  NEVER run without specifying a command - this prevents accidental execution!"
            exit 0
            ;;
    esac
}
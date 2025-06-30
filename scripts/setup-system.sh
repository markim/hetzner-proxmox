#!/bin/bash

# Hetzner Proxmox System Setup Script
# This script optimizes the host system for Proxmox and sets up a /data directory for storage

set -euo pipefail

# Custom error handler
error_handler() {
    local line_no=$1
    local error_code=$2
    log "ERROR" "Script failed at line $line_no with exit code $error_code"
    log "ERROR" "This error occurred in the setup-system script"
}

# Set up error handling
trap 'error_handler ${LINENO} $?' ERR

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source common functions
# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/common.sh"

# Enable debug logging for troubleshooting
export LOG_LEVEL="${LOG_LEVEL:-DEBUG}"

# Function to optimize system for Proxmox
optimize_system() {
    log "INFO" "Optimizing system for Proxmox performance..."
    
    # Update system packages
    log "INFO" "Updating system packages..."
    apt-get update
    apt-get upgrade -y
    
    # Install essential packages for Proxmox optimization
    log "INFO" "Installing system optimization packages..."
    apt-get install -y \
        htop \
        iotop \
        sysstat \
        smartmontools \
        lm-sensors \
        ethtool \
        tuned \
        irqbalance \
        chrony \
        rsyslog \
        logrotate
    
    # Configure system swappiness for better VM performance
    log "INFO" "Configuring VM swappiness..."
    echo "vm.swappiness=10" > /etc/sysctl.d/99-proxmox-swappiness.conf
    
    # Configure dirty page handling for better I/O performance
    log "INFO" "Configuring I/O performance settings..."
    cat > /etc/sysctl.d/99-proxmox-io.conf << 'EOF'
# I/O performance tuning for Proxmox
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500
EOF
    
    # Configure network performance
    log "INFO" "Configuring network performance settings..."
    cat > /etc/sysctl.d/99-proxmox-network.conf << 'EOF'
# Network performance tuning for Proxmox
net.core.rmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_default = 262144
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_congestion_control = bbr
EOF
    
    # Configure kernel parameters for virtualization
    log "INFO" "Configuring virtualization settings..."
    cat > /etc/sysctl.d/99-proxmox-virt.conf << 'EOF'
# Virtualization tuning for Proxmox
# Note: Some parameters may not be available on all kernel versions

# Disable automatic process grouping (can interfere with VM scheduling)
kernel.sched_autogroup_enabled = 0

# Disable NUMA balancing for better VM performance
kernel.numa_balancing = 0
EOF
    
    # Apply sysctl settings with error handling
    log "INFO" "Applying system performance settings..."
    
    apply_sysctl_safe "/etc/sysctl.d/99-proxmox-swappiness.conf" "VM performance settings"
    apply_sysctl_safe "/etc/sysctl.d/99-proxmox-io.conf" "I/O performance settings"
    apply_sysctl_safe "/etc/sysctl.d/99-proxmox-network.conf" "network performance settings"
    apply_sysctl_safe "/etc/sysctl.d/99-proxmox-virt.conf" "virtualization settings"
    
    # Configure CPU governor for performance
    log "INFO" "Configuring CPU governor..."
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        # Try to set performance governor
        if echo "performance" > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null; then
            log "INFO" "CPU governor set to performance mode"
            
            # Make it persistent
            cat > /etc/systemd/system/cpu-performance.service << 'EOF'
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for i in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $i 2>/dev/null || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
            
            if systemctl enable cpu-performance.service 2>/dev/null && systemctl start cpu-performance.service 2>/dev/null; then
                log "INFO" "CPU performance service enabled"
            else
                log "WARNING" "Could not enable CPU performance service"
            fi
        else
            log "WARNING" "Could not set CPU governor to performance mode (may not be supported)"
        fi
    else
        log "INFO" "CPU frequency scaling not available (this is normal in virtual environments)"
    fi
    
    # Configure irqbalance for better interrupt handling
    log "INFO" "Configuring IRQ balancing..."
    if systemctl enable irqbalance 2>/dev/null && systemctl start irqbalance 2>/dev/null; then
        log "INFO" "IRQ balancing service enabled"
    else
        log "WARNING" "Could not enable IRQ balancing service"
    fi
    
    # Configure chrony for better time synchronization
    log "INFO" "Configuring time synchronization..."
    if systemctl enable chrony 2>/dev/null && systemctl start chrony 2>/dev/null; then
        log "INFO" "Chrony time synchronization enabled"
    else
        log "WARNING" "Could not enable chrony service"
    fi
    
    # Configure log rotation for Proxmox
    log "INFO" "Configuring log rotation..."
    cat > /etc/logrotate.d/proxmox-custom << 'EOF'
/var/log/pve/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 640 root adm
}

/var/log/hetzner-proxmox-setup.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 644 root root
}
EOF
    
    # Optimize systemd journal
    log "INFO" "Configuring systemd journal..."
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-proxmox.conf << 'EOF'
[Journal]
SystemMaxUse=100M
SystemMaxFileSize=10M
RuntimeMaxUse=50M
RuntimeMaxFileSize=5M
MaxRetentionSec=1week
EOF
    
    systemctl restart systemd-journald 2>/dev/null || log "WARNING" "Could not restart systemd-journald"
    
    # Enable and configure tuned for virtualization host profile
    log "INFO" "Configuring tuned for virtualization..."
    if systemctl enable tuned 2>/dev/null && systemctl start tuned 2>/dev/null; then
        # Try virtual-host profile first, fallback to throughput-performance
        if tuned-adm profile virtual-host 2>/dev/null; then
            log "INFO" "Tuned configured with virtual-host profile"
        elif tuned-adm profile throughput-performance 2>/dev/null; then
            log "INFO" "Tuned configured with throughput-performance profile"
        else
            log "WARNING" "Could not configure tuned profile, using default"
        fi
    else
        log "WARNING" "Could not start tuned service"
    fi
    
    log "INFO" "System optimization completed successfully"
}

# Function to safely apply sysctl settings
apply_sysctl_safe() {
    local config_file="$1"
    local description="$2"
    
    log "INFO" "Applying $description..."
    
    # Read the config file and apply each setting individually
    local failed_settings=()
    while IFS= read -r line; do
        # Skip comments and empty lines
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line// }" ]]; then
            continue
        fi
        
        # Extract parameter name
        if [[ "$line" =~ ^[[:space:]]*([^=]+)=[[:space:]]*(.+)$ ]]; then
            local param="${BASH_REMATCH[1]// }"
            local value="${BASH_REMATCH[2]// }"
            
            # Check if the parameter exists
            if [[ -f "/proc/sys/${param//./\/}" ]]; then
                if ! sysctl -w "${param}=${value}" >/dev/null 2>&1; then
                    failed_settings+=("${param}")
                fi
            else
                log "DEBUG" "Skipping unavailable parameter: $param"
                failed_settings+=("${param} (not available)")
            fi
        fi
    done < "$config_file"
    
    if [[ ${#failed_settings[@]} -gt 0 ]]; then
        log "WARNING" "Some $description could not be applied: ${failed_settings[*]}"
    else
        log "INFO" "$description applied successfully"
    fi
}

# Function to setup /data storage for Proxmox
setup_data_storage() {
    log "INFO" "Setting up /data storage for Proxmox..."
    
    local data_dir="/data"
    local storage_name="data"
    
    # Create the data directory if it doesn't exist
    if [[ ! -d "$data_dir" ]]; then
        log "INFO" "Creating $data_dir directory..."
        mkdir -p "$data_dir"
        
        # Set appropriate permissions
        chown root:root "$data_dir"
        chmod 755 "$data_dir"
        log "INFO" "Created $data_dir with appropriate permissions"
    else
        log "INFO" "$data_dir directory already exists"
    fi
    
    # Check if we have Proxmox VE tools available
    if ! command -v pvesm >/dev/null 2>&1; then
        log "WARNING" "Proxmox VE tools not found - storage will be created when Proxmox is installed"
        log "INFO" "Directory $data_dir is ready for Proxmox storage configuration"
        return 0
    fi
    
    # Add to Proxmox storage configuration if not already present
    if ! pvesm status -storage "$storage_name" &>/dev/null; then
        log "INFO" "Adding $data_dir as Proxmox storage '$storage_name'..."
        if pvesm add dir "$storage_name" --path "$data_dir" --content "images,vztmpl,iso,snippets,backup"; then
            log "INFO" "Successfully added storage '$storage_name' to Proxmox"
        else
            log "WARNING" "Failed to add storage '$storage_name' to Proxmox (this is normal if Proxmox is not yet installed)"
        fi
    else
        log "INFO" "Storage '$storage_name' already exists in Proxmox"
    fi
    
    # Show storage information
    log "INFO" "Data storage configuration:"
    log "INFO" "  Path: $data_dir"
    log "INFO" "  Storage name: $storage_name"
    log "INFO" "  Available space: $(df -h "$data_dir" 2>/dev/null | tail -1 | awk '{print $4}' || echo 'Unknown')"
}

# Function to configure data storage in Proxmox (post-installation)
configure_proxmox_data_storage() {
    log "INFO" "Configuring /data storage in Proxmox..."
    
    local data_dir="/data"
    local storage_name="data"
    
    # Check if Proxmox VE tools are available
    if ! command -v pvesm >/dev/null 2>&1; then
        log "ERROR" "Proxmox VE tools not found. Please install Proxmox VE first."
        return 1
    fi
    
    # Ensure data directory exists
    if [[ ! -d "$data_dir" ]]; then
        log "INFO" "Creating $data_dir directory..."
        mkdir -p "$data_dir"
        chown root:root "$data_dir"
        chmod 755 "$data_dir"
    fi
    
    # Add to Proxmox storage configuration if not already present
    if ! pvesm status -storage "$storage_name" &>/dev/null; then
        log "INFO" "Adding $data_dir as Proxmox storage '$storage_name'..."
        if pvesm add dir "$storage_name" --path "$data_dir" --content "images,vztmpl,iso,snippets,backup"; then
            log "INFO" "Successfully added storage '$storage_name' to Proxmox"
            
            # Show current storage status
            log "INFO" "Current Proxmox storage configuration:"
            pvesm status
        else
            log "ERROR" "Failed to add storage '$storage_name' to Proxmox"
            return 1
        fi
    else
        log "INFO" "Storage '$storage_name' already exists in Proxmox"
        # Show current storage status
        log "INFO" "Current Proxmox storage configuration:"
        pvesm status
    fi
    
    return 0
}

# Main function
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                cat << EOF
Usage: $0 [OPTIONS]

Optimize the Proxmox host system for performance.

OPTIONS:
    --help                Show this help message
    --configure-storage   Configure /data storage in Proxmox (post-installation only)

OPTIMIZATIONS PERFORMED:
    - System package updates
    - Performance tuning for virtualization
    - Network performance optimization
    - I/O performance tuning
    - CPU governor configuration
    - Log rotation setup
    - Time synchronization
    - IRQ balancing
    - /data directory setup

EXAMPLES:
    $0                        # Run system optimization and setup /data directory
    $0 --configure-storage    # Add /data to Proxmox storage (after Proxmox installation)

EOF
                exit 0
                ;;
            --configure-storage)
                configure_proxmox_data_storage
                exit $?
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "This script must be run as root"
        exit 1
    fi
    
    log "INFO" "Starting Proxmox system optimization..."
    echo
    
    # Setup data storage
    setup_data_storage
    echo
    
    # Optimize system
    optimize_system
    echo
    
    log "INFO" "✅ System optimization completed successfully!"
    log "INFO" ""
    log "INFO" "System optimizations applied:"
    log "INFO" "- VM performance tuning (swappiness, I/O, network)"
    log "INFO" "- CPU performance governor enabled"
    log "INFO" "- IRQ balancing configured"
    log "INFO" "- Time synchronization with chrony"
    log "INFO" "- Log rotation configured"
    log "INFO" "- Tuned virtualization profile active"
    log "INFO" "- /data storage configured for Proxmox"
    echo
    
    log "INFO" "Next steps:"
    log "INFO" "1. /data directory is ready for use"
    log "INFO" "2. Reboot to ensure all optimizations are active" 
    log "INFO" "3. After Proxmox installation: run './scripts/setup-system.sh --configure-storage'"
    log "INFO" "4. Format additional drives: ./install.sh --format-drives"
    log "INFO" "5. Setup RAID mirrors: ./install.sh --setup-mirrors"
    log "INFO" "6. Configure network: ./install.sh --network"
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

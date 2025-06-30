#!/bin/bash

# Hetzner Proxmox System Setup Script
# This script optimizes the host system for Proxmox and ensures a /data partition exists

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

# Function to detect system drive
detect_system_drive() {
    local root_device
    root_device=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    
    if [[ -z "$root_device" ]]; then
        log "ERROR" "Could not detect root filesystem device"
        return 1
    fi
    
    # Handle LVM devices - trace back to physical volumes
    if [[ "$root_device" =~ ^/dev/mapper/ || "$root_device" =~ ^/dev/.*-.*$ ]]; then
        # This is an LVM device, find the underlying physical volumes
        local vg_name
        if [[ "$root_device" =~ /dev/mapper/(.*)-root ]]; then
            vg_name="${BASH_REMATCH[1]}"
        elif [[ "$root_device" =~ /dev/(.*)-root ]]; then
            vg_name="${BASH_REMATCH[1]}"
        fi
        
        if [[ -n "$vg_name" ]] && command -v pvs >/dev/null 2>&1; then
            # Get the first physical volume for this volume group
            local pv_device
            pv_device=$(pvs --noheadings -o pv_name -S vg_name="$vg_name" 2>/dev/null | head -1 | tr -d ' ' || true)
            if [[ -n "$pv_device" ]]; then
                # Get the parent disk
                local parent_disk
                parent_disk=$(lsblk -no PKNAME "$pv_device" 2>/dev/null || true)
                if [[ -n "$parent_disk" ]]; then
                    echo "$parent_disk"
                    return 0
                else
                    # Fallback: extract disk name from partition
                    parent_disk=$(basename "$pv_device")
                    if [[ "$parent_disk" =~ [0-9]$ ]]; then
                        parent_disk="${parent_disk%[0-9]*}"
                    fi
                    echo "$parent_disk"
                    return 0
                fi
            fi
        fi
    else
        # Regular device - get parent disk
        if [[ "$root_device" =~ [0-9]$ ]]; then
            root_device="${root_device%[0-9]*}"
        fi
        echo "$(basename "$root_device")"
        return 0
    fi
    
    log "ERROR" "Could not determine system drive"
    return 1
}

# Function to check free space on system drive
get_system_drive_free_space() {
    local drive="$1"
    
    # Get total size of drive
    local total_size_bytes
    total_size_bytes=$(lsblk -no SIZE -b "/dev/$drive" 2>/dev/null | head -1 || echo "0")
    
    # Get used space by summing all partitions
    local used_space_bytes=0
    while IFS= read -r partition_line; do
        if [[ -n "$partition_line" ]]; then
            local part_size
            part_size=$(echo "$partition_line" | awk '{print $2}')
            if [[ "$part_size" =~ ^[0-9]+$ ]]; then
                used_space_bytes=$((used_space_bytes + part_size))
            fi
        fi
    done < <(lsblk -no NAME,SIZE -b "/dev/$drive" 2>/dev/null | tail -n +2 | grep -E "^\s*${drive}[0-9]+" || true)
    
    # Calculate free space (leave 1GB buffer for partition table, etc.)
    local buffer_bytes=$((1024 * 1024 * 1024))
    local free_space_bytes=$((total_size_bytes - used_space_bytes - buffer_bytes))
    
    # Only return if we have at least 10GB free
    local min_space_bytes=$((10 * 1024 * 1024 * 1024))
    if [[ $free_space_bytes -ge $min_space_bytes ]]; then
        echo "$free_space_bytes"
    else
        echo "0"
    fi
}

# Function to create /data partition
create_data_partition() {
    local drive="$1"
    local free_space_bytes="$2"
    
    log "INFO" "Creating /data partition on /dev/$drive..."
    
    # Convert bytes to human readable
    local free_space_gb=$((free_space_bytes / 1024 / 1024 / 1024))
    log "INFO" "Available space: ${free_space_gb}GB"
    
    # Get the next available partition number
    local next_partition
    local existing_partitions
    existing_partitions=$(lsblk -no NAME "/dev/$drive" 2>/dev/null | grep -E "^${drive}[0-9]+" | wc -l || echo "0")
    next_partition=$((existing_partitions + 1))
    
    # Create the partition using all remaining space
    log "INFO" "Creating partition ${next_partition} for /data..."
    if ! parted "/dev/$drive" --script mkpart primary ext4 -- -${free_space_bytes}B -1 2>/dev/null; then
        log "ERROR" "Failed to create data partition on /dev/$drive"
        return 1
    fi
    
    # Wait for partition to be created
    sleep 2
    partprobe "/dev/$drive" 2>/dev/null || true
    sleep 1
    
    # Determine partition device name
    local partition_device
    if [[ "$drive" =~ nvme ]]; then
        partition_device="/dev/${drive}p${next_partition}"
    else
        partition_device="/dev/${drive}${next_partition}"
    fi
    
    # Wait for partition device to appear
    local retries=0
    while [[ ! -b "$partition_device" && $retries -lt 10 ]]; do
        log "INFO" "Waiting for partition device $partition_device to appear..."
        sleep 1
        ((retries++))
    done
    
    if [[ ! -b "$partition_device" ]]; then
        log "ERROR" "Partition device $partition_device did not appear after partitioning"
        return 1
    fi
    
    # Format the partition as ext4
    log "INFO" "Formatting $partition_device as ext4..."
    if ! mkfs.ext4 -F -L "data" "$partition_device" 2>/dev/null; then
        log "ERROR" "Failed to format $partition_device"
        return 1
    fi
    
    # Create mount point
    log "INFO" "Creating /data mount point..."
    mkdir -p /data
    
    # Add to fstab
    log "INFO" "Adding /data to /etc/fstab..."
    local uuid
    uuid=$(blkid -s UUID -o value "$partition_device" 2>/dev/null || true)
    
    if [[ -n "$uuid" ]]; then
        # Remove any existing /data entries
        sed -i '\|/data|d' /etc/fstab
        # Add new entry
        echo "UUID=$uuid /data ext4 defaults,noatime 0 2" >> /etc/fstab
    else
        log "WARNING" "Could not get UUID for $partition_device, using device path"
        # Remove any existing /data entries
        sed -i '\|/data|d' /etc/fstab
        # Add new entry
        echo "$partition_device /data ext4 defaults,noatime 0 2" >> /etc/fstab
    fi
    
    # Mount the partition
    log "INFO" "Mounting /data..."
    if ! mount /data; then
        log "ERROR" "Failed to mount /data"
        return 1
    fi
    
    # Set appropriate permissions
    log "INFO" "Setting permissions on /data..."
    chown root:root /data
    chmod 755 /data
    
    # Create subdirectories for container data
    log "INFO" "Creating container data directories..."
    mkdir -p /data/containers
    mkdir -p /data/backups
    mkdir -p /data/templates
    mkdir -p /data/logs
    
    log "INFO" "Successfully created and mounted /data partition"
    log "INFO" "Available space in /data: $(df -h /data | tail -1 | awk '{print $4}')"
    
    return 0
}

# Function to setup data partition
setup_data_partition() {
    log "INFO" "Setting up /data partition for container storage..."
    
    # Check if /data is already mounted
    if findmnt /data >/dev/null 2>&1; then
        log "INFO" "/data is already mounted"
        local data_size
        data_size=$(df -h /data | tail -1 | awk '{print $2}')
        local data_avail
        data_avail=$(df -h /data | tail -1 | awk '{print $4}')
        log "INFO" "/data partition: ${data_size} total, ${data_avail} available"
        
        # Ensure container directories exist
        log "INFO" "Ensuring container data directories exist..."
        mkdir -p /data/containers
        mkdir -p /data/backups
        mkdir -p /data/templates
        mkdir -p /data/logs
        
        return 0
    fi
    
    # Detect system drive
    log "INFO" "Detecting system drive..."
    local system_drive
    system_drive=$(detect_system_drive)
    
    if [[ -z "$system_drive" ]]; then
        log "ERROR" "Could not detect system drive"
        return 1
    fi
    
    log "INFO" "System drive detected: /dev/$system_drive"
    
    # Check for free space
    log "INFO" "Checking for available free space..."
    local free_space_bytes
    free_space_bytes=$(get_system_drive_free_space "$system_drive")
    
    if [[ "$free_space_bytes" -eq 0 ]]; then
        log "WARNING" "No sufficient free space (minimum 10GB) on system drive for /data partition"
        log "INFO" "Current drive layout:"
        lsblk "/dev/$system_drive" 2>/dev/null || true
        
        # Create /data directory anyway for manual mounting
        log "INFO" "Creating /data directory for manual use..."
        mkdir -p /data
        chown root:root /data
        chmod 755 /data
        
        # Create subdirectories
        mkdir -p /data/containers
        mkdir -p /data/backups
        mkdir -p /data/templates
        mkdir -p /data/logs
        
        log "INFO" "/data directory created, but no partition was created due to insufficient space"
        return 0
    fi
    
    local free_space_gb=$((free_space_bytes / 1024 / 1024 / 1024))
    log "INFO" "Found ${free_space_gb}GB of free space on /dev/$system_drive"
    
    # Ask for confirmation before creating partition
    echo
    log "WARNING" "This will create a new partition on your system drive!"
    log "INFO" "Drive: /dev/$system_drive"
    log "INFO" "Size: ${free_space_gb}GB"
    log "INFO" "Purpose: Container data storage (/data)"
    echo
    read -p "Do you want to create the /data partition? (y/N): " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "INFO" "Skipping /data partition creation"
        
        # Create /data directory anyway
        mkdir -p /data
        chown root:root /data
        chmod 755 /data
        mkdir -p /data/containers /data/backups /data/templates /data/logs
        
        return 0
    fi
    
    # Create the partition
    if create_data_partition "$system_drive" "$free_space_bytes"; then
        log "INFO" "✅ /data partition created and mounted successfully"
    else
        log "ERROR" "❌ Failed to create /data partition"
        return 1
    fi
    
    return 0
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

# Main function
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                cat << EOF
Usage: $0 [OPTIONS]

Optimize the Proxmox host system and ensure /data partition exists.

OPTIONS:
    --help      Show this help message

OPTIMIZATIONS PERFORMED:
    - System package updates
    - Performance tuning for virtualization
    - Network performance optimization
    - I/O performance tuning
    - CPU governor configuration
    - Log rotation setup
    - Time synchronization
    - IRQ balancing

DATA PARTITION:
    - Detects system drive automatically
    - Creates /data partition from free space (if available)
    - Mounts /data and adds to /etc/fstab
    - Creates container data directories
    - Minimum 10GB free space required

EXAMPLES:
    $0                  # Run system optimization and setup /data partition

EOF
                exit 0
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
    
    log "INFO" "Starting Proxmox system optimization and setup..."
    echo
    
    # Optimize system
    optimize_system
    echo
    
    # Setup data partition
    setup_data_partition
    echo
    
    log "INFO" "✅ System setup completed successfully!"
    log "INFO" ""
    log "INFO" "System optimizations applied:"
    log "INFO" "- VM performance tuning (swappiness, I/O, network)"
    log "INFO" "- CPU performance governor enabled"
    log "INFO" "- IRQ balancing configured"
    log "INFO" "- Time synchronization with chrony"
    log "INFO" "- Log rotation configured"
    log "INFO" "- Tuned virtualization profile active"
    echo
    
    if findmnt /data >/dev/null 2>&1; then
        local data_info
        data_info=$(df -h /data | tail -1)
        log "INFO" "/data partition status:"
        log "INFO" "  Mount: $(echo "$data_info" | awk '{print $1}')"
        log "INFO" "  Size: $(echo "$data_info" | awk '{print $2}')"
        log "INFO" "  Available: $(echo "$data_info" | awk '{print $4}')"
        log "INFO" "  Usage: $(echo "$data_info" | awk '{print $5}')"
    else
        log "INFO" "/data directory created (no partition - insufficient space)"
    fi
    echo
    
    log "INFO" "Next steps:"
    log "INFO" "1. Reboot to ensure all optimizations are active"
    log "INFO" "2. Format additional drives: ./install.sh --format-drives"
    log "INFO" "3. Setup RAID mirrors: ./install.sh --setup-mirrors"
    log "INFO" "4. Configure network: ./install.sh --network"
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

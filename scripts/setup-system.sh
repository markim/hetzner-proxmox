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

# Global variable for data backup directory
DATA_BACKUP_DIR=""

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

# Function to detect system drive
detect_system_drive() {
    local root_device
    root_device=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    
    log "DEBUG" "Root device from findmnt: $root_device"
    
    if [[ -z "$root_device" ]]; then
        log "ERROR" "Could not detect root filesystem device"
        return 1
    fi
    
    # Handle LVM devices - trace back to physical volumes
    if [[ "$root_device" =~ ^/dev/mapper/ || "$root_device" =~ ^/dev/.*-.*$ ]]; then
        log "DEBUG" "Detected LVM root device: $root_device"
        # This is an LVM device, find the underlying physical volumes
        local vg_name
        if [[ "$root_device" =~ /dev/mapper/(.*)-root ]]; then
            vg_name="${BASH_REMATCH[1]}"
        elif [[ "$root_device" =~ /dev/(.*)-root ]]; then
            vg_name="${BASH_REMATCH[1]}"
        fi
        
        log "DEBUG" "Extracted VG name: $vg_name"
        
        if [[ -n "$vg_name" ]] && command -v pvs >/dev/null 2>&1; then
            # Get the first physical volume for this volume group
            local pv_device
            pv_device=$(pvs --noheadings -o pv_name -S vg_name="$vg_name" 2>/dev/null | head -1 | tr -d ' ' || true)
            log "DEBUG" "First PV device for VG $vg_name: $pv_device"
            if [[ -n "$pv_device" ]]; then
                # Get the parent disk
                local parent_disk
                parent_disk=$(lsblk -no PKNAME "$pv_device" 2>/dev/null || true)
                log "DEBUG" "Parent disk for PV $pv_device: $parent_disk"
                if [[ -n "$parent_disk" ]]; then
                    echo "$parent_disk"
                    return 0
                else
                    # Fallback: extract disk name from partition
                    parent_disk=$(basename "$pv_device")
                    if [[ "$parent_disk" =~ [0-9]$ ]]; then
                        parent_disk="${parent_disk%[0-9]*}"
                    fi
                    log "DEBUG" "Fallback parent disk: $parent_disk"
                    echo "$parent_disk"
                    return 0
                fi
            fi
        fi
    else
        log "DEBUG" "Detected regular root device: $root_device"
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
    
    log "DEBUG" "Checking free space on drive: $drive"
    
    # First check if this drive is part of an LVM setup
    local lvm_free_space
    lvm_free_space=$(get_lvm_free_space "$drive")
    
    log "DEBUG" "LVM free space returned: '$lvm_free_space' bytes"
    
    if [[ "$lvm_free_space" =~ ^[0-9]+$ ]] && [[ "$lvm_free_space" -gt 0 ]]; then
        log "DEBUG" "Using LVM free space: $lvm_free_space bytes"
        echo "$lvm_free_space"
        return 0
    else
        log "DEBUG" "LVM free space invalid or zero: '$lvm_free_space'"
    fi
    
    # Fall back to regular partition-based calculation
    log "DEBUG" "Checking regular partition free space"
    
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

# Function to check LVM free space
get_lvm_free_space() {
    local drive="$1"
    
    log "DEBUG" "Checking LVM free space for drive: $drive"
    
    # Check if this drive/partition has LVM physical volumes
    if ! command -v pvs >/dev/null 2>&1; then
        log "DEBUG" "LVM tools not available"
        echo "0"
        return 0
    fi
    
    # Check if the drive itself or any of its partitions are PVs
    local pv_devices=()
    
    # Check the drive itself
    if pvs "/dev/$drive" >/dev/null 2>&1; then
        log "DEBUG" "Drive /dev/$drive is a PV"
        pv_devices+=("/dev/$drive")
    fi
    
    # Check all partitions of the drive
    while IFS= read -r partition; do
        if [[ -n "$partition" && -b "/dev/$partition" ]]; then
            log "DEBUG" "Checking partition: /dev/$partition"
            if pvs "/dev/$partition" >/dev/null 2>&1; then
                log "DEBUG" "Partition /dev/$partition is a PV"
                pv_devices+=("/dev/$partition")
            fi
        fi
    done < <(lsblk -no NAME "/dev/$drive" 2>/dev/null | tail -n +2 | grep -E "^${drive}[0-9p]+" | sed 's/^[[:space:]]*//')
    
    log "DEBUG" "Found PV devices: ${pv_devices[*]}"
    
    if [[ ${#pv_devices[@]} -eq 0 ]]; then
        log "DEBUG" "No LVM physical volumes found"
        echo "0"
        return 0
    fi
    
    # Get the volume group(s) for these physical volumes and sum free space
    local total_free_bytes=0
    local processed_vgs=()
    
    for pv_device in "${pv_devices[@]}"; do
        local vg_name
        vg_name=$(pvs --noheadings -o vg_name "$pv_device" 2>/dev/null | tr -d ' ' || true)
        
        log "DEBUG" "PV $pv_device belongs to VG: $vg_name"
        
        if [[ -n "$vg_name" ]]; then
            # Check if we've already processed this VG (avoid double counting)
            local already_processed=false
            for processed_vg in "${processed_vgs[@]}"; do
                if [[ "$processed_vg" == "$vg_name" ]]; then
                    already_processed=true
                    break
                fi
            done
            
            if [[ "$already_processed" == "false" ]]; then
                processed_vgs+=("$vg_name")
                
                # Get free space in this volume group (in bytes)
                local vg_free_bytes
                vg_free_bytes=$(vgs --noheadings -o vg_free --units B "$vg_name" 2>/dev/null | sed 's/[^0-9]//g' || echo "0")
                
                log "DEBUG" "VG $vg_name has free space: $vg_free_bytes bytes (raw)"
                
                # Ensure we have a valid number
                if [[ "$vg_free_bytes" =~ ^[0-9]+$ ]] && [[ "$vg_free_bytes" -gt 0 ]]; then
                    total_free_bytes=$((total_free_bytes + vg_free_bytes))
                    log "DEBUG" "Added $vg_free_bytes bytes to total, new total: $total_free_bytes bytes"
                else
                    log "DEBUG" "Invalid or zero vg_free_bytes: '$vg_free_bytes'"
                fi
            fi
        fi
    done
    
    log "DEBUG" "Total LVM free space calculated: $total_free_bytes bytes"
    
    # Only return if we have at least 10GB free
    local min_space_bytes=$((10 * 1024 * 1024 * 1024))
    log "DEBUG" "Minimum space required: $min_space_bytes bytes (10GB)"
    log "DEBUG" "Comparison: $total_free_bytes >= $min_space_bytes"
    
    if [[ $total_free_bytes -ge $min_space_bytes ]]; then
        log "DEBUG" "LVM free space meets minimum requirement, returning: $total_free_bytes"
        echo "$total_free_bytes"
    else
        log "DEBUG" "LVM free space below minimum threshold (10GB): $total_free_bytes < $min_space_bytes"
        echo "0"
    fi
}

# Function to create /data storage (LVM logical volume or physical partition)
create_data_storage() {
    local drive="$1"
    local free_space_bytes="$2"
    
    # Convert bytes to human readable
    local free_space_gb=$((free_space_bytes / 1024 / 1024 / 1024))
    log "INFO" "Available space: ${free_space_gb}GB"
    
    # Check if this is an LVM setup
    local vg_name
    vg_name=$(get_volume_group_for_drive "$drive")
    
    if [[ -n "$vg_name" ]]; then
        log "INFO" "Creating LVM logical volume for /data in volume group: $vg_name"
        create_lvm_data_volume "$vg_name" "$free_space_bytes"
    else
        log "INFO" "Creating physical partition for /data on /dev/$drive"
        create_physical_data_partition "$drive" "$free_space_bytes"
    fi
}

# Function to get volume group name for a drive
get_volume_group_for_drive() {
    local drive="$1"
    
    if ! command -v pvs >/dev/null 2>&1; then
        echo ""
        return 0
    fi
    
    # Check if the drive itself is a PV
    local vg_name
    vg_name=$(pvs --noheadings -o vg_name "/dev/$drive" 2>/dev/null | tr -d ' ' || true)
    if [[ -n "$vg_name" ]]; then
        echo "$vg_name"
        return 0
    fi
    
    # Check all partitions of the drive
    while IFS= read -r partition; do
        if [[ -n "$partition" && -b "/dev/$partition" ]]; then
            vg_name=$(pvs --noheadings -o vg_name "/dev/$partition" 2>/dev/null | tr -d ' ' || true)
            if [[ -n "$vg_name" ]]; then
                echo "$vg_name"
                return 0
            fi
        fi
    done < <(lsblk -no NAME "/dev/$drive" 2>/dev/null | tail -n +2 | grep -E "^${drive}[0-9p]+" | sed 's/^[[:space:]]*//')
    
    echo ""
    return 0
}

# Function to create LVM logical volume for /data
create_lvm_data_volume() {
    local vg_name="$1"
    local free_space_bytes="$2"
    
    # Check if data logical volume already exists
    if lvs "$vg_name/data" >/dev/null 2>&1; then
        log "INFO" "Logical volume 'data' already exists in volume group '$vg_name'"
        local current_size
        current_size=$(lvs --noheadings -o lv_size --units B "$vg_name/data" 2>/dev/null | tr -d ' B' || echo "0")
        
        if [[ "$current_size" =~ ^[0-9]+$ ]] && [[ $current_size -gt 0 ]]; then
            log "INFO" "Current data LV size: $((current_size / 1024 / 1024 / 1024))GB"
            
            # Ask if user wants to extend it
            echo
            log "INFO" "Do you want to extend the existing /data logical volume to use all available space?"
            
            # Check if we're running interactively
            if [[ -t 0 ]]; then
                read -p "Extend /data logical volume? (y/N): " -r
            else
                log "INFO" "Running non-interactively, auto-extending /data logical volume..."
                REPLY="y"
            fi
            
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                log "INFO" "Extending logical volume to use all free space..."
                if lvextend -l +100%FREE "$vg_name/data" 2>/dev/null; then
                    log "INFO" "Resizing filesystem..."
                    if resize2fs "/dev/$vg_name/data" 2>/dev/null; then
                        log "INFO" "✅ Successfully extended /data logical volume"
                        return 0
                    else
                        log "WARNING" "Extended LV but filesystem resize failed - you may need to run: resize2fs /dev/$vg_name/data"
                        return 0
                    fi
                else
                    log "ERROR" "Failed to extend logical volume"
                    return 1
                fi
            else
                log "INFO" "Keeping existing /data logical volume as-is"
                return 0
            fi
        fi
    fi
    
    # Create new logical volume using all free space
    log "INFO" "Creating logical volume 'data' using all free space in volume group '$vg_name'..."
    
    # Backup existing /data contents if they exist
    backup_and_prepare_data_directory
    
    if ! lvcreate -l 100%FREE -n data "$vg_name" 2>/dev/null; then
        log "ERROR" "Failed to create logical volume 'data'"
        restore_data_directory_backup
        return 1
    fi
    
    local lv_device="/dev/$vg_name/data"
    
    # Format the logical volume as ext4
    log "INFO" "Formatting $lv_device as ext4..."
    if ! mkfs.ext4 -F -L "data" "$lv_device" 2>/dev/null; then
        log "ERROR" "Failed to format $lv_device"
        lvremove -y "$vg_name/data" 2>/dev/null || true
        restore_data_directory_backup
        return 1
    fi
    
    # Mount and configure the new volume
    mount_and_configure_data_storage "$lv_device"
    
    # Restore backed up contents
    restore_data_directory_backup
    
    return 0
}

# Function to create physical partition for /data
create_physical_data_partition() {
    local drive="$1"
    local free_space_bytes="$2"
    
    log "INFO" "Creating physical partition for /data on /dev/$drive..."
    
    # Get the next available partition number
    local next_partition
    local existing_partitions
    existing_partitions=$(lsblk -no NAME "/dev/$drive" 2>/dev/null | grep -E "^${drive}[0-9]+" | wc -l || echo "0")
    next_partition=$((existing_partitions + 1))
    
    # Backup existing /data contents if they exist
    backup_and_prepare_data_directory
    
    # Create the partition using all remaining space
    log "INFO" "Creating partition ${next_partition} for /data..."
    if ! parted "/dev/$drive" --script mkpart primary ext4 -- -${free_space_bytes}B -1 2>/dev/null; then
        log "ERROR" "Failed to create data partition on /dev/$drive"
        restore_data_directory_backup
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
        restore_data_directory_backup
        return 1
    fi
    
    # Format the partition as ext4
    log "INFO" "Formatting $partition_device as ext4..."
    if ! mkfs.ext4 -F -L "data" "$partition_device" 2>/dev/null; then
        log "ERROR" "Failed to format $partition_device"
        restore_data_directory_backup
        return 1
    fi
    
    # Mount and configure the new partition
    mount_and_configure_data_storage "$partition_device"
    
    # Restore backed up contents
    restore_data_directory_backup
    
    return 0
}

# Function to backup existing /data directory contents
backup_and_prepare_data_directory() {
    DATA_BACKUP_DIR=""
    
    # Check if /data exists and has contents
    if [[ -d /data ]] && [[ -n "$(ls -A /data 2>/dev/null)" ]]; then
        log "INFO" "Backing up existing /data contents..."
        
        # Create temporary backup directory
        DATA_BACKUP_DIR=$(mktemp -d "/tmp/data-backup-XXXXXX")
        
        # Copy contents to backup
        if cp -a /data/* "$DATA_BACKUP_DIR/" 2>/dev/null; then
            log "INFO" "Backed up /data contents to: $DATA_BACKUP_DIR"
        else
            log "WARNING" "Failed to backup some /data contents"
        fi
        
        # Unmount /data if it's mounted
        if findmnt /data >/dev/null 2>&1; then
            log "INFO" "Unmounting existing /data..."
            umount /data 2>/dev/null || umount -l /data 2>/dev/null || true
        fi
        
        # Remove existing contents
        rm -rf /data/* 2>/dev/null || true
    else
        log "INFO" "No existing /data contents to backup"
    fi
    
    # Ensure /data directory exists
    mkdir -p /data
}

# Function to restore backed up /data directory contents
restore_data_directory_backup() {
    if [[ -n "${DATA_BACKUP_DIR:-}" ]] && [[ -d "$DATA_BACKUP_DIR" ]]; then
        log "INFO" "Restoring backed up /data contents..."
        
        if [[ -d /data ]] && findmnt /data >/dev/null 2>&1; then
            # /data is mounted, restore contents
            if cp -a "$DATA_BACKUP_DIR"/* /data/ 2>/dev/null; then
                log "INFO" "Successfully restored /data contents"
            else
                log "WARNING" "Failed to restore some /data contents from backup"
                log "INFO" "Backup location: $DATA_BACKUP_DIR (not automatically deleted)"
                return 1
            fi
        else
            # /data is not properly mounted, restore to directory
            log "WARNING" "/data is not mounted, restoring to directory"
            if cp -a "$DATA_BACKUP_DIR"/* /data/ 2>/dev/null; then
                log "INFO" "Restored contents to /data directory"
            else
                log "WARNING" "Failed to restore contents to /data directory"
            fi
        fi
        
        # Clean up backup
        rm -rf "$DATA_BACKUP_DIR" 2>/dev/null || true
        DATA_BACKUP_DIR=""
    fi
}

# Function to mount and configure data storage
mount_and_configure_data_storage() {
    local device="$1"
    
    # Add to fstab
    log "INFO" "Adding /data to /etc/fstab..."
    local uuid
    uuid=$(blkid -s UUID -o value "$device" 2>/dev/null || true)
    
    # Remove any existing /data entries
    sed -i '\|/data|d' /etc/fstab
    
    if [[ -n "$uuid" ]]; then
        # Add new entry with UUID
        echo "UUID=$uuid /data ext4 defaults,noatime 0 2" >> /etc/fstab
    else
        log "WARNING" "Could not get UUID for $device, using device path"
        # Add new entry with device path
        echo "$device /data ext4 defaults,noatime 0 2" >> /etc/fstab
    fi
    
    # Mount the storage
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
    
    log "INFO" "Successfully created and mounted /data storage"
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
    
    log "DEBUG" "Free space detected: $free_space_bytes bytes"
    
    if [[ "$free_space_bytes" -eq 0 ]]; then
        log "WARNING" "No sufficient free space (minimum 10GB) on system drive for /data partition"
        log "INFO" "Current drive layout:"
        lsblk "/dev/$system_drive" 2>/dev/null || true
        
        # Let's check LVM info directly for debugging
        if command -v vgs >/dev/null 2>&1; then
            log "DEBUG" "LVM Volume Groups:"
            vgs 2>/dev/null || true
            log "DEBUG" "LVM Physical Volumes:"
            pvs 2>/dev/null || true
        fi
        
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
        
        log "INFO" "/data directory created, but no storage was created due to insufficient space"
        return 0
    fi
    
    local free_space_gb=$((free_space_bytes / 1024 / 1024 / 1024))
    log "INFO" "Found ${free_space_gb}GB of free space on /dev/$system_drive"
    
    # Determine if this is LVM or physical partition setup
    local vg_name
    vg_name=$(get_volume_group_for_drive "$system_drive")
    
    if [[ -n "$vg_name" ]]; then
        log "INFO" "Detected LVM setup with volume group: $vg_name"
        
        # Ask for confirmation before creating LVM logical volume
        echo
        log "WARNING" "This will create a new logical volume in volume group '$vg_name'!"
        log "INFO" "Volume Group: $vg_name"
        log "INFO" "Available Space: ${free_space_gb}GB"
        log "INFO" "Purpose: Container data storage (/data)"
        log "INFO" "Type: LVM Logical Volume"
        echo
        
        # Check if we're running interactively
        if [[ -t 0 ]]; then
            read -p "Do you want to create the /data logical volume? (y/N): " -r
        else
            log "INFO" "Running non-interactively, auto-creating /data logical volume..."
            REPLY="y"
        fi
    else
        log "INFO" "Detected physical partition setup"
        
        # Ask for confirmation before creating partition
        echo
        log "WARNING" "This will create a new partition on your system drive!"
        log "INFO" "Drive: /dev/$system_drive"
        log "INFO" "Size: ${free_space_gb}GB"
        log "INFO" "Purpose: Container data storage (/data)"
        log "INFO" "Type: Physical Partition"
        echo
        
        # Check if we're running interactively
        if [[ -t 0 ]]; then
            read -p "Do you want to create the /data partition? (y/N): " -r
        else
            log "INFO" "Running non-interactively, auto-creating /data partition..."
            REPLY="y"
        fi
    fi
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "INFO" "Skipping /data storage creation"
        
        # Create /data directory anyway
        mkdir -p /data
        chown root:root /data
        chmod 755 /data
        mkdir -p /data/containers /data/backups /data/templates /data/logs
        
        return 0
    fi
    
    # Create the storage (LVM logical volume or physical partition)
    if create_data_storage "$system_drive" "$free_space_bytes"; then
        log "INFO" "✅ /data storage created and mounted successfully"
    else
        log "ERROR" "❌ Failed to create /data storage"
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
    - Detects system drive automatically (LVM and physical partition support)
    - Creates /data logical volume (LVM) or partition from free space
    - Backs up and restores existing /data contents safely
    - Mounts /data and adds to /etc/fstab
    - Creates container data directories
    - Minimum 10GB free space required
    - Can extend existing LVM volumes to use all available space

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
        local mount_source
        mount_source=$(echo "$data_info" | awk '{print $1}')
        
        log "INFO" "/data storage status:"
        log "INFO" "  Mount: $mount_source"
        log "INFO" "  Size: $(echo "$data_info" | awk '{print $2}')"
        log "INFO" "  Available: $(echo "$data_info" | awk '{print $4}')"
        log "INFO" "  Usage: $(echo "$data_info" | awk '{print $5}')"
        
        # Determine if it's LVM or physical partition
        if [[ "$mount_source" =~ /dev/mapper/ ]] || [[ "$mount_source" =~ /dev/.*-.*$ ]]; then
            log "INFO" "  Type: LVM Logical Volume"
        else
            log "INFO" "  Type: Physical Partition"
        fi
    else
        log "INFO" "/data directory created (no storage volume - insufficient space)"
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

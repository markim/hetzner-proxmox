#!/bin/bash

# Hetzner Proxmox Drive Setup Script
# This script configures drive mirrors and sets up storage for Proxmox

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source common functions
# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/common.sh"

# Global variables
AVAILABLE_DRIVES=()
DRIVE_SIZES=()
MIRROR_GROUPS=()

# Function to detect all available drives
detect_drives() {
    log "INFO" "Detecting available drives..."
    
    # Get all block devices that are disks (not partitions or loop devices)
    local drives
    drives=$(lsblk -dpno NAME,SIZE,TYPE,MOUNTPOINT | grep -E "disk" | grep -v "loop" || true)
    
    if [[ -z "$drives" ]]; then
        log "ERROR" "No drives detected"
        exit 1
    fi
    
    log "INFO" "Found the following drives:"
    
    # Use process substitution to avoid subshell and preserve array assignments
    while IFS= read -r line; do
        local drive_name size mountpoint
        read -r drive_name size _ mountpoint <<< "$line"
        
        # Check if this is the system drive
        local is_system_drive=false
        
        # Check if mounted at root or has system partitions
        if [[ -n "$mountpoint" ]] && [[ "$mountpoint" == "/" ]]; then
            is_system_drive=true
        elif lsblk "$drive_name" -no MOUNTPOINT | grep -qE "^(/|/boot|/var|/usr|/home)$" 2>/dev/null; then
            is_system_drive=true
        elif lsblk "$drive_name" -no LABEL 2>/dev/null | grep -qE "(proxmox|pve)" 2>/dev/null; then
            is_system_drive=true
        fi
        
        # For system drives, we'll allow them but mark them specially
        if $is_system_drive; then
            log "INFO" "  $drive_name ($size) - SYSTEM DRIVE (available for mirroring)"
            AVAILABLE_DRIVES+=("$drive_name")
            DRIVE_SIZES+=("$size")
            continue
        fi
        
        # Check if drive has any other mounted partitions
        local has_mounted_partitions=false
        if lsblk "$drive_name" -no MOUNTPOINT | grep -q "^/" 2>/dev/null; then
            has_mounted_partitions=true
        fi
        
        if [[ "$has_mounted_partitions" == "true" ]]; then
            log "INFO" "  $drive_name ($size) - HAS OTHER MOUNTED PARTITIONS (skipping)"
        else
            log "INFO" "  $drive_name ($size) - AVAILABLE"
            AVAILABLE_DRIVES+=("$drive_name")
            DRIVE_SIZES+=("$size")
        fi
    done < <(echo "$drives")
    
    if [[ ${#AVAILABLE_DRIVES[@]} -eq 0 ]]; then
        log "ERROR" "No available drives found for configuration"
        log "DEBUG" "Debug: All detected drives were filtered out"
        log "DEBUG" "This usually means all drives contain mounted partitions or are system drives"
        exit 1
    fi
    
    log "INFO" "Found ${#AVAILABLE_DRIVES[@]} available drives for configuration"
    
    # Debug: Show what drives were selected
    for i in "${!AVAILABLE_DRIVES[@]}"; do
        log "DEBUG" "Available drive $((i+1)): ${AVAILABLE_DRIVES[i]} (${DRIVE_SIZES[i]})"
    done
}

# Function to group drives by size for mirroring
group_drives_by_size() {
    log "INFO" "Grouping drives by size for optimal mirroring..."
    
    declare -A size_groups
    
    # Group drives by size
    for i in "${!AVAILABLE_DRIVES[@]}"; do
        local drive="${AVAILABLE_DRIVES[i]}"
        local size="${DRIVE_SIZES[i]}"
        
        if [[ -z "${size_groups[$size]:-}" ]]; then
            size_groups["$size"]="$drive"
        else
            size_groups["$size"]+=" $drive"
        fi
    done
    
    # Display grouping results
    log "INFO" "Drive grouping results:"
    for size in "${!size_groups[@]}"; do
        IFS=' ' read -ra drives_in_group <<< "${size_groups[$size]}"
        local count=${#drives_in_group[@]}
        
        log "INFO" "  Size $size: ${count} drives (${drives_in_group[*]})"
        
        if [[ $count -ge 2 ]]; then
            # Can create mirrors with pairs
            local pairs=$((count / 2))
            log "INFO" "    -> Can create $pairs RAID1 mirror(s)"
            
            # Store mirror groups
            for ((j=0; j<pairs*2; j+=2)); do
                if [[ $((j+1)) -lt ${#drives_in_group[@]} ]]; then
                    MIRROR_GROUPS+=("${drives_in_group[j]} ${drives_in_group[j+1]}")
                fi
            done
            
            # Handle odd drive
            if [[ $((count % 2)) -eq 1 ]]; then
                log "INFO" "    -> 1 drive will remain as single drive: ${drives_in_group[-1]}"
                MIRROR_GROUPS+=("${drives_in_group[-1]}")
            fi
        else
            log "INFO" "    -> Will be configured as single drive"
            MIRROR_GROUPS+=("${drives_in_group[0]}")
        fi
    done
}

# Function to check current RAID status
check_current_raid() {
    log "INFO" "Checking current RAID configuration..."
    
    if ! command -v mdadm &> /dev/null; then
        log "WARN" "mdadm not installed. Installing mdadm..."
        apt-get update
        apt-get install -y mdadm
    fi
    
    # Check for existing RAID arrays
    local existing_arrays
    existing_arrays=$(grep "^md" /proc/mdstat || true)
    
    if [[ -n "$existing_arrays" ]]; then
        log "INFO" "Found existing RAID arrays:"
        cat /proc/mdstat
        echo
        
        # List detailed information about each array
        while read -r line; do
            local array_name
            array_name=$(echo "$line" | cut -d' ' -f1)
            if [[ -n "$array_name" ]]; then
                log "INFO" "Details for /dev/$array_name:"
                mdadm --detail "/dev/$array_name" 2>/dev/null || log "WARN" "Could not get details for /dev/$array_name"
                echo
            fi
        done <<< "$existing_arrays"
    else
        log "INFO" "No existing RAID arrays found"
    fi
}

# Function to create RAID mirrors
create_raid_mirrors() {
    log "INFO" "Creating RAID mirrors..."
    
    local mirror_index=0
    for mirror_group in "${MIRROR_GROUPS[@]}"; do
        IFS=' ' read -ra drives_in_mirror <<< "$mirror_group"
        
        if [[ ${#drives_in_mirror[@]} -eq 2 ]]; then
            # Create RAID1 mirror
            local md_device="/dev/md$mirror_index"
            local drive1="${drives_in_mirror[0]}"
            local drive2="${drives_in_mirror[1]}"
            
            # Check if this involves the system drive
            local has_system_drive=false
            for drive in "$drive1" "$drive2"; do
                if lsblk "$drive" -no MOUNTPOINT | grep -qE "^(/|/boot|/var|/usr|/home)$" 2>/dev/null; then
                    has_system_drive=true
                    break
                fi
            done
            
            if $has_system_drive; then
                log "WARN" "⚠️  SYSTEM DRIVE MIRROR DETECTED ⚠️"
                log "WARN" "This will create a RAID1 mirror that includes your system drive."
                log "WARN" "This is a complex operation that requires special handling."
                log "WARN" "Mirror: $drive1 + $drive2"
                echo
                read -p "Are you sure you want to proceed with system drive mirroring? (y/N): " -r sys_confirm
                if [[ ! "$sys_confirm" =~ ^[Yy]$ ]]; then
                    log "INFO" "Skipping system drive mirror configuration"
                    continue
                fi
                
                log "INFO" "Setting up system drive mirror - this requires careful handling..."
                setup_system_drive_mirror "$drive1" "$drive2" "$md_device" "$mirror_index"
            else
                log "INFO" "Creating RAID1 mirror $md_device with drives: $drive1, $drive2"
                
                # Check if drives are clean
                for drive in "$drive1" "$drive2"; do
                    if lsblk "$drive" -no FSTYPE 2>/dev/null | grep -q "."; then
                        log "WARN" "Drive $drive appears to have existing filesystem. Wiping..."
                        wipefs -a "$drive"
                    fi
                done
                
                # Create the RAID array
                if mdadm --create "$md_device" --level=1 --raid-devices=2 "$drive1" "$drive2" --assume-clean; then
                    log "INFO" "Successfully created RAID1 array $md_device"
                    
                    # Wait for array to be ready
                    log "INFO" "Waiting for RAID array to initialize..."
                    mdadm --wait "$md_device"
                    
                    # Create filesystem
                    log "INFO" "Creating ext4 filesystem on $md_device..."
                    mkfs.ext4 -F "$md_device"
                    
                    # Add to Proxmox storage
                    add_to_proxmox_storage "$md_device" "raid-mirror-$mirror_index"
                else
                    log "ERROR" "Failed to create RAID array $md_device"
                fi
            fi
            
            mirror_index=$((mirror_index + 1))
            
        elif [[ ${#drives_in_mirror[@]} -eq 1 ]]; then
            # Single drive setup
            local drive="${drives_in_mirror[0]}"
            
            # Check if this is a system drive
            if lsblk "$drive" -no MOUNTPOINT | grep -qE "^(/|/boot|/var|/usr|/home)$" 2>/dev/null; then
                log "INFO" "Skipping single system drive: $drive (already in use by system)"
                continue
            fi
            
            log "INFO" "Configuring single drive: $drive"
            
            # Wipe drive if needed
            if lsblk "$drive" -no FSTYPE 2>/dev/null | grep -q "."; then
                log "WARN" "Drive $drive appears to have existing filesystem. Wiping..."
                wipefs -a "$drive"
            fi
            
            # Create filesystem directly on drive
            log "INFO" "Creating ext4 filesystem on $drive..."
            mkfs.ext4 -F "$drive"
            
            # Add to Proxmox storage
            add_to_proxmox_storage "$drive" "single-drive-$mirror_index"
            
            mirror_index=$((mirror_index + 1))
        fi
    done
}

# Function to add storage to Proxmox
add_to_proxmox_storage() {
    local device="$1"
    local storage_name="$2"
    
    log "INFO" "Adding $device to Proxmox as storage '$storage_name'..."
    
    # Create mount point
    local mount_point="/mnt/pve/$storage_name"
    mkdir -p "$mount_point"
    
    # Get UUID of the filesystem
    local uuid
    uuid=$(blkid -s UUID -o value "$device")
    
    if [[ -z "$uuid" ]]; then
        log "ERROR" "Could not get UUID for device $device"
        return 1
    fi
    
    # Add to fstab
    if ! grep -q "$uuid" /etc/fstab; then
        echo "UUID=$uuid $mount_point ext4 defaults 0 2" >> /etc/fstab
        log "INFO" "Added $device to /etc/fstab"
    fi
    
    # Mount the filesystem
    if ! mountpoint -q "$mount_point"; then
        mount "$mount_point"
        log "INFO" "Mounted $device at $mount_point"
    fi
    
    # Add to Proxmox storage configuration
    if ! pvesm status -storage "$storage_name" &>/dev/null; then
        pvesm add dir "$storage_name" --path "$mount_point" --content "images,vztmpl,iso,snippets,backup"
        log "INFO" "Added storage '$storage_name' to Proxmox"
    else
        log "INFO" "Storage '$storage_name' already exists in Proxmox"
    fi
}

# Function to save RAID configuration
save_raid_config() {
    log "INFO" "Saving RAID configuration..."
    
    # Update mdadm configuration
    if [[ -f /etc/mdadm/mdadm.conf ]]; then
        cp /etc/mdadm/mdadm.conf /etc/mdadm/mdadm.conf.backup
    fi
    
    mdadm --detail --scan > /etc/mdadm/mdadm.conf
    update-initramfs -u
    
    log "INFO" "RAID configuration saved"
}

# Function to display final status
display_final_status() {
    log "INFO" "=== DRIVE CONFIGURATION COMPLETE ==="
    echo
    
    # Show RAID status
    log "INFO" "RAID Array Status:"
    if [[ -f /proc/mdstat ]]; then
        cat /proc/mdstat
    fi
    echo
    
    # Show Proxmox storage
    log "INFO" "Proxmox Storage Status:"
    pvesm status
    echo
    
    # Show mounted filesystems
    log "INFO" "Mounted Storage:"
    df -h | grep "/mnt/pve" || log "INFO" "No /mnt/pve mounts found"
    echo
    
    log "INFO" "Drive configuration completed successfully!"
    log "INFO" "You can now use the configured storage in Proxmox VE"
}

# Function to show detailed drive information for debugging
show_drive_details() {
    log "INFO" "=== DETAILED DRIVE INFORMATION ==="
    
    log "INFO" "All block devices:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL
    echo
    
    log "INFO" "Drive partition details:"
    for drive in /dev/nvme*n1 /dev/sd*; do
        if [[ -b "$drive" ]]; then
            log "INFO" "Drive: $drive"
            lsblk "$drive" -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL 2>/dev/null || log "WARN" "Could not read $drive"
            echo
        fi
    done
}

# Function to setup system drive mirror (complex operation)
setup_system_drive_mirror() {
    local drive1="$1"
    local drive2="$2"
    local md_device="$3"
    local mirror_index="$4"
    
    log "INFO" "Setting up system drive mirror: $drive1 + $drive2 -> $md_device"
    
    # Determine which drive is the system drive and which is the target
    local system_drive=""
    local target_drive=""
    
    if lsblk "$drive1" -no MOUNTPOINT | grep -qE "^(/|/boot|/var|/usr|/home)$" 2>/dev/null; then
        system_drive="$drive1"
        target_drive="$drive2"
    else
        system_drive="$drive2"
        target_drive="$drive1"
    fi
    
    log "INFO" "System drive: $system_drive"
    log "INFO" "Target drive: $target_drive"
    
    # For system drive mirroring, we need to:
    # 1. Clean the target drive
    # 2. Create a degraded RAID array with just the target drive
    # 3. Copy the system to the RAID array
    # 4. Add the original system drive to the array
    # This is complex and requires careful handling
    
    log "WARN" "System drive mirroring is a complex operation that should be done manually."
    log "WARN" "For safety, we'll set up the target drive as a single drive instead."
    log "WARN" "You can manually convert to RAID later using mdadm."
    
    # Clean the target drive
    if lsblk "$target_drive" -no FSTYPE 2>/dev/null | grep -q "."; then
        log "INFO" "Cleaning target drive $target_drive..."
        wipefs -a "$target_drive"
    fi
    
    # Set up target drive as single storage for now
    log "INFO" "Creating ext4 filesystem on target drive $target_drive..."
    mkfs.ext4 -F "$target_drive"
    
    # Add to Proxmox storage
    add_to_proxmox_storage "$target_drive" "system-mirror-ready-$mirror_index"
    
    log "INFO" "Target drive $target_drive is ready for manual system mirroring"
    log "INFO" "To complete system mirroring, you'll need to:"
    log "INFO" "1. Create a degraded RAID1 array with the target drive"
    log "INFO" "2. Copy your system partitions to the RAID array"
    log "INFO" "3. Update bootloader and fstab"
    log "INFO" "4. Add the original system drive to the RAID array"
    log "INFO" "This process requires advanced knowledge and should be done carefully."
}

# Main function
main() {
    log "INFO" "Starting Hetzner Proxmox drive configuration..."
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "This script must be run as root"
        exit 1
    fi
    
    # Show detailed drive information if verbose logging is enabled
    if [[ "${LOG_LEVEL:-}" == "DEBUG" ]]; then
        show_drive_details
    fi
    
    # Detect available drives
    detect_drives
    
    # Group drives by size
    group_drives_by_size
    
    # Check current RAID status
    check_current_raid
    
    # Ask for confirmation
    echo
    log "INFO" "=== PROPOSED CONFIGURATION ==="
    log "INFO" "The following RAID configuration will be created:"
    
    local mirror_index=0
    for mirror_group in "${MIRROR_GROUPS[@]}"; do
        IFS=' ' read -ra drives_in_mirror <<< "$mirror_group"
        
        if [[ ${#drives_in_mirror[@]} -eq 2 ]]; then
            # Check if this involves a system drive
            local has_system_drive=false
            for drive in "${drives_in_mirror[@]}"; do
                if lsblk "$drive" -no MOUNTPOINT | grep -qE "^(/|/boot|/var|/usr|/home)$" 2>/dev/null; then
                    has_system_drive=true
                    break
                fi
            done
            
            if $has_system_drive; then
                log "INFO" "  SYSTEM MIRROR $mirror_index: ${drives_in_mirror[0]} + ${drives_in_mirror[1]} ⚠️"
            else
                log "INFO" "  RAID1 Mirror $mirror_index: ${drives_in_mirror[0]} + ${drives_in_mirror[1]}"
            fi
        else
            # Check if this is a system drive
            if lsblk "${drives_in_mirror[0]}" -no MOUNTPOINT | grep -qE "^(/|/boot|/var|/usr|/home)$" 2>/dev/null; then
                log "INFO" "  System Drive $mirror_index: ${drives_in_mirror[0]} (will be skipped)"
            else
                log "INFO" "  Single Drive $mirror_index: ${drives_in_mirror[0]}"
            fi
        fi
        mirror_index=$((mirror_index + 1))
    done
    
    echo
    read -p "Do you want to proceed with this configuration? (y/N): " -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "INFO" "Configuration cancelled by user"
        exit 0
    fi
    
    # Create RAID mirrors
    create_raid_mirrors
    
    # Save RAID configuration
    save_raid_config
    
    # Display final status
    display_final_status
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

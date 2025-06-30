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
        local is_raid_drive=false
        
        # Check if mounted at root or has system partitions
        if [[ -n "$mountpoint" ]] && [[ "$mountpoint" == "/" ]]; then
            is_system_drive=true
        elif lsblk "$drive_name" -no MOUNTPOINT | grep -qE "^(/|/boot|/var|/usr|/home)$" 2>/dev/null; then
            is_system_drive=true
        elif lsblk "$drive_name" -no LABEL 2>/dev/null | grep -qE "(proxmox|pve)" 2>/dev/null; then
            is_system_drive=true
        fi
        
        # Check if this drive is already part of a RAID array
        if is_drive_in_raid "$drive_name"; then
            is_raid_drive=true
        fi
        
        # For system drives, we'll allow them but mark them specially
        if $is_system_drive; then
            log "INFO" "  $drive_name ($size) - SYSTEM DRIVE (available for mirroring)"
            AVAILABLE_DRIVES+=("$drive_name")
            DRIVE_SIZES+=("$size")
            continue
        fi
        
        # For drives already in RAID, mark them but still include for potential storage setup
        if $is_raid_drive; then
            local raid_device
            raid_device=$(get_raid_device_for_drive "$drive_name")
            log "INFO" "  $drive_name ($size) - IN RAID ARRAY /dev/$raid_device (available for storage setup)"
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
    
    # Check if any mirrors will affect the /var/lib/vz data storage
    local data_storage_affected=false
    if check_if_mirrors_affect_data_storage; then
        data_storage_affected=true
        log "INFO" "Mirror configuration will affect /var/lib/vz storage"
        # Remove existing data storage configuration before creating mirrors
        remove_data_storage_from_proxmox
    fi
    
    local mirror_index=0
    for mirror_group in "${MIRROR_GROUPS[@]}"; do
        IFS=' ' read -ra drives_in_mirror <<< "$mirror_group"
        
        if [[ ${#drives_in_mirror[@]} -eq 2 ]]; then
            # Create RAID1 mirror
            local md_device="/dev/md$mirror_index"
            local drive1="${drives_in_mirror[0]}"
            local drive2="${drives_in_mirror[1]}"
            
            # Check if these drives are already part of an existing RAID array
            local drive1_in_raid=false
            local drive2_in_raid=false
            local existing_array=""
            
            if is_drive_in_raid "$drive1"; then
                drive1_in_raid=true
                existing_array=$(get_raid_device_for_drive "$drive1")
            fi
            
            if is_drive_in_raid "$drive2"; then
                drive2_in_raid=true
                if [[ -z "$existing_array" ]]; then
                    existing_array=$(get_raid_device_for_drive "$drive2")
                fi
            fi
            
            # Skip if both drives are already in the same RAID array
            if $drive1_in_raid && $drive2_in_raid; then
                log "INFO" "Drives $drive1 and $drive2 are already part of RAID array /dev/$existing_array"
                log "INFO" "Skipping RAID creation and setting up storage for existing array..."
                
                # Set up storage for the existing array
                if [[ -b "/dev/$existing_array" ]]; then
                    # Check if it already has a filesystem
                    if ! lsblk "/dev/$existing_array" -no FSTYPE | grep -q "ext4"; then
                        log "INFO" "Creating ext4 filesystem on existing array /dev/$existing_array..."
                        if ! mkfs.ext4 -F "/dev/$existing_array"; then
                            log "ERROR" "Failed to create filesystem on /dev/$existing_array"
                            mirror_index=$((mirror_index + 1))
                            continue
                        fi
                    else
                        log "INFO" "Existing array /dev/$existing_array already has filesystem"
                    fi
                    
                    # Add to Proxmox storage
                    if ! add_to_proxmox_storage "/dev/$existing_array" "raid-mirror-$mirror_index"; then
                        log "ERROR" "Failed to add existing RAID array to Proxmox storage"
                    fi
                else
                    log "ERROR" "Expected RAID device /dev/$existing_array not found"
                fi
                
                mirror_index=$((mirror_index + 1))
                continue
            fi
            
            # Skip if one or both drives are in different RAID arrays
            if $drive1_in_raid || $drive2_in_raid; then
                log "WARN" "One or both drives ($drive1, $drive2) are already part of a RAID array"
                log "WARN" "Cannot create new RAID with drives that are already in use"
                mirror_index=$((mirror_index + 1))
                continue
            fi
            
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
                    if ! mdadm --wait "$md_device"; then
                        log "WARN" "mdadm --wait failed, but array may still be functional. Continuing..."
                    fi
                    
                    # Give it a moment to settle
                    sleep 2
                    
                    # Check if the array is actually available
                    if [[ ! -b "$md_device" ]]; then
                        log "ERROR" "RAID device $md_device is not available"
                        continue
                    fi
                    
                    # Create filesystem
                    log "INFO" "Creating ext4 filesystem on $md_device..."
                    if ! mkfs.ext4 -F "$md_device"; then
                        log "ERROR" "Failed to create filesystem on $md_device"
                        continue
                    fi
                    
                    # Wait for filesystem to be fully created and UUID to be available
                    sleep 3
                    sync
                    
                    # Add to Proxmox storage
                    if ! add_to_proxmox_storage "$md_device" "raid-mirror-$mirror_index"; then
                        log "ERROR" "Failed to add RAID array to Proxmox storage"
                        # Continue with next mirror instead of failing completely
                    fi
                else
                    log "ERROR" "Failed to create RAID array $md_device"
                fi
            fi
            
            mirror_index=$((mirror_index + 1))
            
        elif [[ ${#drives_in_mirror[@]} -eq 1 ]]; then
            # Single drive setup
            local drive="${drives_in_mirror[0]}"
            
            # Check if this drive is already part of a RAID array
            if is_drive_in_raid "$drive"; then
                local raid_device
                raid_device=$(get_raid_device_for_drive "$drive")
                log "INFO" "Drive $drive is already part of RAID array /dev/$raid_device"
                log "INFO" "Setting up storage for existing RAID array..."
                
                # Set up storage for the existing array
                if [[ -b "/dev/$raid_device" ]]; then
                    # Check if it already has a filesystem
                    if ! lsblk "/dev/$raid_device" -no FSTYPE | grep -q "ext4"; then
                        log "INFO" "Creating ext4 filesystem on existing array /dev/$raid_device..."
                        if ! mkfs.ext4 -F "/dev/$raid_device"; then
                            log "ERROR" "Failed to create filesystem on /dev/$raid_device"
                            mirror_index=$((mirror_index + 1))
                            continue
                        fi
                    else
                        log "INFO" "Existing array /dev/$raid_device already has filesystem"
                    fi
                    
                    # Add to Proxmox storage
                    if ! add_to_proxmox_storage "/dev/$raid_device" "existing-raid-$mirror_index"; then
                        log "ERROR" "Failed to add existing RAID array to Proxmox storage"
                    fi
                else
                    log "ERROR" "Expected RAID device /dev/$raid_device not found"
                fi
                
                mirror_index=$((mirror_index + 1))
                continue
            fi
            
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
            if ! mkfs.ext4 -F "$drive"; then
                log "ERROR" "Failed to create filesystem on $drive"
                continue
            fi
            
            # Add to Proxmox storage
            if ! add_to_proxmox_storage "$drive" "single-drive-$mirror_index"; then
                log "ERROR" "Failed to add single drive to Proxmox storage"
                # Continue with next drive instead of failing completely
            fi
            
            mirror_index=$((mirror_index + 1))
        fi
    done
    
    # Re-add data storage configuration if it was affected by mirroring
    if $data_storage_affected; then
        log "INFO" "Re-adding /var/lib/vz storage configuration after mirroring..."
        readd_data_storage_to_proxmox
    fi
}

# Function to add storage to Proxmox
add_to_proxmox_storage() {
    local device="$1"
    local storage_name="$2"
    
    log "INFO" "Adding $device to Proxmox as storage '$storage_name'..."
    
    # Create mount point
    local mount_point="/mnt/pve/$storage_name"
    mkdir -p "$mount_point"
    
    # Get UUID of the filesystem (with retry)
    local uuid
    local retry_count=0
    while [[ $retry_count -lt 5 ]]; do
        uuid=$(blkid -s UUID -o value "$device" 2>/dev/null)
        if [[ -n "$uuid" ]]; then
            break
        fi
        log "INFO" "Waiting for filesystem UUID to be available (attempt $((retry_count + 1))/5)..."
        sleep 2
        sync
        ((retry_count++))
    done
    
    if [[ -z "$uuid" ]]; then
        log "ERROR" "Could not get UUID for device $device"
        return 1
    fi
    
    # Add to fstab
    if ! grep -q "$uuid" /etc/fstab; then
        echo "UUID=$uuid $mount_point ext4 defaults 0 2" >> /etc/fstab
        log "INFO" "Added $device to /etc/fstab"
        
        # Reload systemd to pick up fstab changes
        systemctl daemon-reload
    fi
    
    # Mount the filesystem
    if ! mountpoint -q "$mount_point"; then
        if ! mount "$mount_point"; then
            log "ERROR" "Failed to mount $device at $mount_point"
            return 1
        fi
        log "INFO" "Mounted $device at $mount_point"
    fi
    
    # Add to Proxmox storage configuration
    if ! pvesm status -storage "$storage_name" &>/dev/null; then
        if ! pvesm add dir "$storage_name" --path "$mount_point" --content "images,vztmpl,iso,snippets,backup"; then
            log "ERROR" "Failed to add storage '$storage_name' to Proxmox"
            return 1
        fi
        log "INFO" "Added storage '$storage_name' to Proxmox"
    else
        log "INFO" "Storage '$storage_name' already exists in Proxmox"
    fi
}

# Function to remove existing data storage from Proxmox
remove_data_storage_from_proxmox() {
    local storage_name="data"
    
    log "INFO" "Checking if '$storage_name' storage needs to be removed from Proxmox..."
    
    # Check if Proxmox VE tools are available
    if ! command -v pvesm >/dev/null 2>&1; then
        log "DEBUG" "Proxmox VE tools not found - storage removal not needed"
        return 0
    fi
    
    # Check if the storage exists
    if pvesm status -storage "$storage_name" &>/dev/null; then
        log "INFO" "Removing existing '$storage_name' storage from Proxmox configuration..."
        
        # First try to disable the storage
        if pvesm set "$storage_name" --disable 1 2>/dev/null; then
            log "DEBUG" "Disabled '$storage_name' storage"
        fi
        
        # Remove the storage
        if pvesm remove "$storage_name" 2>/dev/null; then
            log "INFO" "Successfully removed '$storage_name' storage from Proxmox"
        else
            log "WARN" "Failed to remove '$storage_name' storage from Proxmox (this may be normal)"
        fi
    else
        log "DEBUG" "Storage '$storage_name' not found in Proxmox configuration"
    fi
}

# Function to re-add data storage to Proxmox after mirroring
readd_data_storage_to_proxmox() {
    local data_dir="/var/lib/vz"
    local storage_name="data"
    
    log "INFO" "Re-adding '$storage_name' storage to Proxmox configuration..."
    
    # Check if Proxmox VE tools are available
    if ! command -v pvesm >/dev/null 2>&1; then
        log "DEBUG" "Proxmox VE tools not found - will configure when Proxmox is installed"
        return 0
    fi
    
    # Ensure the data directory exists
    if [[ ! -d "$data_dir" ]]; then
        log "INFO" "Creating $data_dir directory..."
        mkdir -p "$data_dir"
        chown root:root "$data_dir"
        chmod 755 "$data_dir"
    fi
    
    # Add to Proxmox storage configuration if not already present
    if ! pvesm status -storage "$storage_name" &>/dev/null; then
        log "INFO" "Adding $data_dir as Proxmox storage '$storage_name'..."
        # Add comprehensive content types for the data storage
        if pvesm add dir "$storage_name" --path "$data_dir" --content "images,vztmpl,iso,snippets,backup,rootdir"; then
            log "INFO" "Successfully added storage '$storage_name' to Proxmox"
            
            # Enable the storage if it's not enabled
            if pvesm set "$storage_name" --disable 0 2>/dev/null; then
                log "DEBUG" "Storage '$storage_name' enabled"
            fi
        else
            log "ERROR" "Failed to add storage '$storage_name' to Proxmox"
            return 1
        fi
    else
        log "INFO" "Storage '$storage_name' already exists in Proxmox"
        
        # Ensure existing storage has all content types and is enabled
        log "DEBUG" "Updating storage '$storage_name' configuration..."
        if pvesm set "$storage_name" --content "images,vztmpl,iso,snippets,backup,rootdir" --disable 0 2>/dev/null; then
            log "DEBUG" "Storage '$storage_name' configuration updated"
        fi
    fi
    
    # Show storage information
    log "INFO" "Data storage configuration:"
    log "INFO" "  Path: $data_dir"
    log "INFO" "  Storage name: $storage_name"
    log "INFO" "  Content types: images, vztmpl, iso, snippets, backup, rootdir"
    log "INFO" "  Available space: $(df -h "$data_dir" 2>/dev/null | tail -1 | awk '{print $4}' || echo 'Unknown')"
    
    return 0
}

# Function to check if mirrors will affect the /var/lib/vz directory
check_if_mirrors_affect_data_storage() {
    local data_dir="/var/lib/vz"
    local affects_data_storage=false
    
    # Check if /var/lib/vz is on any of the drives being mirrored
    local data_storage_device
    data_storage_device=$(df "$data_dir" 2>/dev/null | tail -1 | awk '{print $1}' || echo "")
    
    if [[ -n "$data_storage_device" ]]; then
        # Get the base device (remove partition numbers)
        local base_device
        base_device=$(echo "$data_storage_device" | sed 's/[0-9]*$//' | sed 's/p$//')
        
        # Check if this base device is in our mirror groups
        for mirror_group in "${MIRROR_GROUPS[@]}"; do
            IFS=' ' read -ra drives_in_mirror <<< "$mirror_group"
            for drive in "${drives_in_mirror[@]}"; do
                if [[ "$drive" == "$base_device"* ]] || [[ "$base_device" == "$drive"* ]]; then
                    affects_data_storage=true
                    log "INFO" "Mirror configuration will affect $data_dir (currently on $data_storage_device)"
                    break 2
                fi
            done
        done
    fi
    
    if $affects_data_storage; then
        return 0  # true
    else
        return 1  # false
    fi
}

# Function to check if a drive is already in a RAID array
is_drive_in_raid() {
    local drive="$1"
    local drive_basename
    drive_basename=$(basename "$drive")
    
    # Check if the drive appears in /proc/mdstat
    if grep -q "$drive_basename" /proc/mdstat 2>/dev/null; then
        return 0  # Drive is in RAID
    fi
    
    # Also check lsblk output for raid type
    if lsblk "$drive" -no TYPE 2>/dev/null | grep -q "raid1"; then
        return 0  # Drive is in RAID
    fi
    
    return 1  # Drive is not in RAID
}

# Function to get the RAID device name for a drive
get_raid_device_for_drive() {
    local drive="$1"
    local drive_basename
    drive_basename=$(basename "$drive")
    
    # Parse /proc/mdstat to find which md device contains this drive
    while read -r line; do
        if [[ "$line" =~ ^(md[0-9]+) ]]; then
            local md_name="${BASH_REMATCH[1]}"
            # Check if the drive is mentioned in this line or the next few lines
            local found=false
            echo "$line" | grep -q "$drive_basename" && found=true
            
            if $found; then
                echo "$md_name"
                return 0
            fi
        fi
    done < /proc/mdstat
    
    return 1
}

# Function to clean up failed RAID arrays
cleanup_failed_raid() {
    local md_device="$1"
    
    log "INFO" "Cleaning up failed RAID array $md_device..."
    
    # Stop the array if it exists
    if [[ -b "$md_device" ]]; then
        mdadm --stop "$md_device" || log "WARN" "Failed to stop $md_device"
    fi
    
    # Remove from mdadm.conf if present
    if [[ -f /etc/mdadm/mdadm.conf ]]; then
        sed -i "\|$md_device|d" /etc/mdadm/mdadm.conf
    fi
    
    # Remove any stale entries from fstab
    local device_name
    device_name=$(basename "$md_device")
    sed -i "/md.*$device_name/d" /etc/fstab
    
    log "INFO" "Cleaned up $md_device"
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
    
    # Show summary of what was added to Proxmox
    log "INFO" "Storage Added to Proxmox:"
    local storage_count=0
    while read -r line; do
        if [[ "$line" =~ ^[[:space:]]*([^[:space:]]+)[[:space:]]+dir[[:space:]]+([^[:space:]]+)[[:space:]]+.*$ ]]; then
            local storage_name="${BASH_REMATCH[1]}"
            local storage_path="${BASH_REMATCH[2]}"
            if [[ "$storage_path" =~ ^/mnt/pve/ ]]; then
                log "INFO" "  - $storage_name: $storage_path"
                ((storage_count++))
            fi
        fi
    done < <(pvesm status)
    
    if [[ $storage_count -eq 0 ]]; then
        log "INFO" "  No additional storage was added to Proxmox"
    else
        log "INFO" "  Total: $storage_count storage locations added"
    fi
    echo
    
    log "INFO" "Drive configuration completed successfully!"
    log "INFO" "You can now use the configured storage in Proxmox VE"
    log "INFO" "Access storage in Proxmox web interface under Datacenter > Storage"
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

# Function to setup system drive mirror using mdadm RAID1
# This function creates a full drive mirror that preserves the LVM structure
setup_system_drive_mirror() {
    local drive1="$1"
    local drive2="$2"
    local md_device="$3"
    local mirror_index="$4"
    
    log "INFO" "Setting up automated system drive mirror: $drive1 + $drive2 -> $md_device"
    
    # Determine which drive is the system drive and which is the target
    local system_drive=""
    local target_drive=""
    
    if lsblk "$drive1" -lno MOUNTPOINT | grep -qE "^(/|/boot|/var|/usr|/home)$" 2>/dev/null; then
        system_drive="$drive1"
        target_drive="$drive2"
    else
        system_drive="$drive2"
        target_drive="$drive1"
    fi
    
    log "INFO" "System drive: $system_drive"
    log "INFO" "Target drive: $target_drive"
    
    # Check if the system uses LVM
    local uses_lvm=false
    if lsblk "$system_drive" -lno TYPE | grep -q "lvm"; then
        uses_lvm=true
        log "INFO" "System uses LVM - will create partition-level mirrors"
    else
        log "INFO" "System does not use LVM - will create full drive mirror"
    fi
    
    if $uses_lvm; then
        # For LVM systems, we need to mirror each partition separately
        setup_lvm_system_mirror "$system_drive" "$target_drive" "$md_device" "$mirror_index"
    else
        # For non-LVM systems, mirror the entire drive
        setup_full_drive_mirror "$system_drive" "$target_drive" "$md_device" "$mirror_index"
    fi
}

# Function to setup LVM system mirror (partition-level mirroring)
setup_lvm_system_mirror() {
    local system_drive="$1"
    local target_drive="$2"
    local md_device="$3"
    local mirror_index="$4"
    
    log "INFO" "Setting up LVM system mirror with partition-level RAID"
    
    # Step 1: Clone partition table to target drive
    log "INFO" "Cloning partition table from $system_drive to $target_drive..."
    if ! sfdisk -d "$system_drive" | sfdisk "$target_drive"; then
        log "ERROR" "Failed to clone partition table"
        return 1
    fi
    
    # Wait for partition table to be recognized
    partprobe "$target_drive"
    sleep 3
    
    # Step 2: Get all partitions from system drive
    local system_partitions
    system_partitions=$(lsblk "$system_drive" -lno NAME,TYPE | grep "part" | awk '{print $1}')
    
    if [[ -z "$system_partitions" ]]; then
        log "ERROR" "No partitions found on system drive $system_drive"
        return 1
    fi
    
    # Step 3: Create RAID arrays for each partition
    local partition_index=0
    local boot_md_device=""
    local lvm_md_device=""
    
    for part_name in $system_partitions; do
        local system_partition="/dev/$part_name"
        local target_partition=""
        
        # Find corresponding target partition
        local partition_num
        partition_num=$(echo "$part_name" | grep -o '[0-9]*$')
        
        # Try different naming schemes for target partition
        for candidate in "${target_drive}${partition_num}" "${target_drive}p${partition_num}"; do
            if [[ -b "$candidate" ]]; then
                target_partition="$candidate"
                break
            fi
        done
        
        if [[ -z "$target_partition" ]]; then
            log "ERROR" "Could not find target partition for $system_partition"
            continue
        fi
        
        # Determine partition type and create appropriate RAID device
        local partition_md_device
        local partition_type=""
        
        # Check if this is the boot partition
        if lsblk "$system_partition" -lno MOUNTPOINT | grep -q "^/boot$"; then
            partition_type="boot"
            partition_md_device="/dev/md${mirror_index}"
            boot_md_device="$partition_md_device"
        # Check if this is an LVM partition
        elif lsblk "$system_partition" -lno TYPE | grep -q "part" && \
             lsblk "$system_partition" -lno FSTYPE | grep -q "LVM2_member"; then
            partition_type="lvm"
            partition_md_device="/dev/md$((mirror_index + 10))"  # Offset to avoid conflicts
            lvm_md_device="$partition_md_device"
        else
            # Skip BIOS boot partitions and other special partitions
            log "INFO" "Skipping special partition $system_partition"
            continue
        fi
        
        log "INFO" "Creating RAID1 for $partition_type partition: $system_partition -> $partition_md_device"
        
        # Create degraded RAID1 array with target partition
        if ! mdadm --create "$partition_md_device" --level=1 --raid-devices=2 missing "$target_partition" --force; then
            log "ERROR" "Failed to create RAID array $partition_md_device"
            continue
        fi
        
        # Wait for array to be ready
        sleep 3
        
        # Copy data from system partition to RAID array
        log "INFO" "Copying data from $system_partition to $partition_md_device..."
        if ! dd if="$system_partition" of="$partition_md_device" bs=64K status=progress; then
            log "ERROR" "Failed to copy data to $partition_md_device"
            continue
        fi
        
        # Add original partition to RAID array
        log "INFO" "Adding $system_partition to RAID array $partition_md_device..."
        if ! mdadm --add "$partition_md_device" "$system_partition"; then
            log "ERROR" "Failed to add $system_partition to RAID array"
            continue
        fi
        
        log "INFO" "Successfully created RAID1 mirror for $partition_type partition"
        
        ((partition_index++))
    done
    
    # Step 3.5: Handle any additional data partitions for Proxmox storage
    log "INFO" "Checking for additional data partitions on system drive..."
    for part_name in $system_partitions; do
        local system_partition="/dev/$part_name"
        local target_partition=""
        
        # Find corresponding target partition
        local partition_num
        partition_num=$(echo "$part_name" | grep -o '[0-9]*$')
        
        # Try different naming schemes for target partition
        for candidate in "${target_drive}${partition_num}" "${target_drive}p${partition_num}"; do
            if [[ -b "$candidate" ]]; then
                target_partition="$candidate"
                break
            fi
        done
        
        if [[ -z "$target_partition" ]]; then
            continue
        fi
        
        # Check if this is a data partition (not boot, not LVM, not special)
        local is_data_partition=false
        local partition_fstype
        partition_fstype=$(lsblk "$system_partition" -lno FSTYPE 2>/dev/null || echo "")
        
        # Skip if it's a boot partition, LVM partition, or system partition
        if lsblk "$system_partition" -lno MOUNTPOINT | grep -q "^/boot$"; then
            continue  # Boot partition already handled
        elif lsblk "$system_partition" -lno FSTYPE | grep -q "LVM2_member"; then
            continue  # LVM partition already handled
        elif lsblk "$system_partition" -lno MOUNTPOINT | grep -qE "^(/|/var|/usr|/home)$"; then
            continue  # System partition
        elif [[ "$partition_fstype" == "ext4" ]] || [[ "$partition_fstype" == "xfs" ]] || [[ -z "$partition_fstype" ]]; then
            # This could be a data partition
            is_data_partition=true
        fi
        
        if $is_data_partition; then
            log "INFO" "Found potential data partition: $system_partition (fstype: $partition_fstype)"
            
            # Create RAID device for data partition
            local data_md_device="/dev/md$((mirror_index + 20 + partition_index))"  # Offset to avoid conflicts
            
            log "INFO" "Creating RAID1 for data partition: $system_partition -> $data_md_device"
            
            # Create degraded RAID1 array with target partition
            if mdadm --create "$data_md_device" --level=1 --raid-devices=2 missing "$target_partition" --force; then
                # Wait for array to be ready
                sleep 3
                
                # If source partition has data, copy it
                if [[ -n "$partition_fstype" ]]; then
                    log "INFO" "Copying data from $system_partition to $data_md_device..."
                    if dd if="$system_partition" of="$data_md_device" bs=64K status=progress; then
                        # Add original partition to RAID array
                        log "INFO" "Adding $system_partition to RAID array $data_md_device..."
                        mdadm --add "$data_md_device" "$system_partition"
                    else
                        log "ERROR" "Failed to copy data to $data_md_device"
                        continue
                    fi
                else
                    # No filesystem, create one and add original partition
                    log "INFO" "Creating filesystem on $data_md_device..."
                    if mkfs.ext4 -F "$data_md_device"; then
                        mdadm --add "$data_md_device" "$system_partition"
                    else
                        log "ERROR" "Failed to create filesystem on $data_md_device"
                        continue
                    fi
                fi
                
                # Add to Proxmox storage
                if ! add_to_proxmox_storage "$data_md_device" "system-data-$partition_index"; then
                    log "ERROR" "Failed to add system data RAID to Proxmox storage"
                fi
                
                log "INFO" "Successfully created RAID1 mirror for data partition"
                ((partition_index++))
            else
                log "ERROR" "Failed to create RAID array $data_md_device for data partition"
            fi
        fi
    done
    
    # Step 4: Re-add the main /var/lib/vz data storage after system mirroring
    log "INFO" "Re-configuring /var/lib/vz data storage after system mirroring..."
    readd_data_storage_to_proxmox
    
    # Step 5: Update system configuration for RAID boot
    if [[ -n "$boot_md_device" ]]; then
        log "INFO" "Updating system configuration for RAID boot..."
        update_system_for_raid_boot "$boot_md_device" "$lvm_md_device" "$system_drive" "$target_drive"
    fi
    
    log "INFO" "LVM system mirroring completed successfully!"
    log "INFO" "RAID arrays are now syncing. This may take some time."
    log "WARN" "You should reboot the system to test RAID boot functionality."
    log "INFO" "After reboot, you can check RAID status with: cat /proc/mdstat"
}

# Function to setup full drive mirror (for non-LVM systems)
setup_full_drive_mirror() {
    local system_drive="$1"
    local target_drive="$2"
    local md_device="$3"
    local mirror_index="$4"
    
    log "INFO" "Setting up full drive mirror (not implemented for LVM systems)"
    log "ERROR" "Full drive mirroring is not recommended for LVM systems"
    log "ERROR" "Use partition-level mirroring instead"
    return 1
}

# Function to update system configuration for RAID boot
update_system_for_raid_boot() {
    local boot_md_device="$1"
    local lvm_md_device="$2"
    local system_drive="$3"
    local target_drive="$4"
    
    log "INFO" "Updating system configuration for RAID boot..."
    
    # Update fstab for boot partition
    if [[ -n "$boot_md_device" ]]; then
        log "INFO" "Updating fstab for RAID boot partition..."
        update_fstab_for_raid_partition "/boot" "$boot_md_device"
    fi
    
    # Update LVM configuration if we have LVM RAID
    if [[ -n "$lvm_md_device" ]]; then
        log "INFO" "Updating LVM configuration for RAID..."
        update_lvm_for_raid "$lvm_md_device"
    fi
    
    # Update GRUB configuration
    log "INFO" "Updating GRUB configuration..."
    update_grub_for_raid "$boot_md_device"
    
    # Install GRUB on both drives
    log "INFO" "Installing GRUB on both drives..."
    grub-install "$system_drive" || log "WARN" "Failed to install GRUB on $system_drive"
    grub-install "$target_drive" || log "WARN" "Failed to install GRUB on $target_drive"
    update-grub || log "WARN" "Failed to update GRUB configuration"
}

# Function to update fstab for a specific RAID partition
update_fstab_for_raid_partition() {
    local mount_point="$1"
    local raid_device="$2"
    
    log "INFO" "Updating /etc/fstab for $mount_point -> $raid_device..."
    
    # Backup fstab
    local backup_file
    backup_file="/etc/fstab.backup.$(date +%Y%m%d_%H%M%S)"
    cp /etc/fstab "$backup_file"
    log "INFO" "Backed up fstab to $backup_file"
    
    # Get UUID of RAID device
    local raid_uuid
    raid_uuid=$(blkid -s UUID -o value "$raid_device")
    
    if [[ -z "$raid_uuid" ]]; then
        log "ERROR" "Could not get UUID for RAID device $raid_device"
        return 1
    fi
    
    log "INFO" "RAID device UUID: $raid_uuid"
    
    # Find the current entry for the mount point and replace it
    local current_device
    current_device=$(grep " $mount_point " /etc/fstab | awk '{print $1}' | head -n1)
    
    if [[ -n "$current_device" ]]; then
        log "INFO" "Replacing $current_device with UUID=$raid_uuid in fstab"
        sed -i "s|$current_device|UUID=$raid_uuid|g" /etc/fstab
    else
        log "WARN" "Could not find existing entry for $mount_point in fstab"
    fi
}

# Function to update LVM configuration for RAID
update_lvm_for_raid() {
    local lvm_md_device="$1"
    
    log "INFO" "Updating LVM configuration for RAID device $lvm_md_device..."
    
    # The LVM physical volume will now be on the RAID device
    # We need to update the LVM metadata to recognize the new location
    
    # First, scan for physical volumes
    pvscan
    
    # Update LVM device filter if needed
    log "INFO" "LVM will automatically detect the RAID device after reboot"
    log "INFO" "You may need to update /etc/lvm/lvm.conf if there are issues"
}

# Function to update GRUB for RAID boot
update_grub_for_raid() {
    local raid_device="$1"
    
    log "INFO" "Updating GRUB configuration for RAID boot..."
    
    # Ensure mdadm is in initramfs modules
    log "INFO" "Adding RAID modules to initramfs..."
    if [[ ! -f /etc/initramfs-tools/modules ]]; then
        touch /etc/initramfs-tools/modules
    fi
    
    if ! grep -q "raid1" /etc/initramfs-tools/modules; then
        echo "raid1" >> /etc/initramfs-tools/modules
    fi
    
    if ! grep -q "md_mod" /etc/initramfs-tools/modules; then
        echo "md_mod" >> /etc/initramfs-tools/modules
    fi
    
    # Update initramfs
    log "INFO" "Updating initramfs..."
    if ! update-initramfs -u -k all; then
        log "WARN" "Failed to update initramfs, but continuing..."
    fi
    
    # Configure GRUB for RAID
    if [[ -f /etc/default/grub ]]; then
        # Backup GRUB config
        local grub_backup
        grub_backup="/etc/default/grub.backup.$(date +%Y%m%d_%H%M%S)"
        cp /etc/default/grub "$grub_backup"
        log "INFO" "Backed up GRUB config to $grub_backup"
        
        # Ensure GRUB can handle RAID
        if ! grep -q "GRUB_PRELOAD_MODULES.*raid" /etc/default/grub; then
            if grep -q "^GRUB_PRELOAD_MODULES=" /etc/default/grub; then
                sed -i 's/^GRUB_PRELOAD_MODULES=.*/GRUB_PRELOAD_MODULES="raid mdraid1x"/' /etc/default/grub
            else
                echo 'GRUB_PRELOAD_MODULES="raid mdraid1x"' >> /etc/default/grub
            fi
            log "INFO" "Added RAID modules to GRUB preload"
        fi
        
        # Ensure GRUB can find RAID devices
        if ! grep -q "GRUB_DEVICE_BOOT" /etc/default/grub; then
            local raid_uuid
            raid_uuid=$(blkid -s UUID -o value "$raid_device")
            if [[ -n "$raid_uuid" ]]; then
                echo "GRUB_DEVICE_BOOT=UUID=$raid_uuid" >> /etc/default/grub
                log "INFO" "Set GRUB boot device to RAID UUID: $raid_uuid"
            fi
        fi
    fi
    
    # Install GRUB on both drives of the RAID array
    log "INFO" "Installing GRUB on RAID member drives..."
    local drives
    drives=$(mdadm --detail "$raid_device" 2>/dev/null | grep -E "/dev/" | grep -oE "/dev/[a-z]+" | sort -u)
    
    for drive in $drives; do
        if [[ -b "$drive" ]]; then
            log "INFO" "Installing GRUB on $drive..."
            if ! grub-install "$drive"; then
                log "WARN" "Failed to install GRUB on $drive"
            fi
        fi
    done
    
    log "INFO" "GRUB configuration updated for RAID boot"
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
    log "INFO" "The following RAID configuration will be created and added to Proxmox storage:"
    
    local mirror_index=0
    local storage_to_add=0
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
                log "INFO" "    └─ System mirror (boot/LVM), may include data partitions for Proxmox"
            else
                log "INFO" "  RAID1 Mirror $mirror_index: ${drives_in_mirror[0]} + ${drives_in_mirror[1]}"
                log "INFO" "    └─ Will be added to Proxmox as 'raid-mirror-$mirror_index'"
                ((storage_to_add++))
            fi
        else
            # Check if this is a system drive
            if lsblk "${drives_in_mirror[0]}" -no MOUNTPOINT | grep -qE "^(/|/boot|/var|/usr|/home)$" 2>/dev/null; then
                log "INFO" "  System Drive $mirror_index: ${drives_in_mirror[0]} (will be skipped for storage)"
            elif is_drive_in_raid "${drives_in_mirror[0]}"; then
                local existing_raid
                existing_raid=$(get_raid_device_for_drive "${drives_in_mirror[0]}")
                log "INFO" "  Existing RAID Drive $mirror_index: ${drives_in_mirror[0]} (part of /dev/$existing_raid)"
                log "INFO" "    └─ Will be added to Proxmox as 'existing-raid-$mirror_index'"
                ((storage_to_add++))
            else
                log "INFO" "  Single Drive $mirror_index: ${drives_in_mirror[0]}"
                log "INFO" "    └─ Will be added to Proxmox as 'single-drive-$mirror_index'"
                ((storage_to_add++))
            fi
        fi
        mirror_index=$((mirror_index + 1))
    done
    
    echo
    log "INFO" "Summary: $storage_to_add storage location(s) will be added to Proxmox"
    log "INFO" "Note: System drives already provide 'local' and 'local-lvm' storage"
    
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

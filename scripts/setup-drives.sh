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
                log "INFO" "Drive $drive is already part of RAID array /dev/$raid_device, skipping single drive configuration"
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

# Function to setup system drive mirror using mdadm RAID1
# Function to setup system drive mirror using mdadm RAID1 (fully automated)
setup_system_drive_mirror() {
    local drive1="$1"
    local drive2="$2"
    local md_device="$3"
    local mirror_index="$4"
    
    log "INFO" "Setting up automated system drive mirror: $drive1 + $drive2 -> $md_device"
    
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
    
    # Get the main system partition (typically the first partition)
    local system_partition=""
    local system_partitions
    system_partitions=$(lsblk "$system_drive" -no NAME,TYPE | grep "part" | awk '{print "/dev/"$1}')
    
    # Find the root partition
    for part in $system_partitions; do
        if lsblk "$part" -no MOUNTPOINT | grep -q "^/$"; then
            system_partition="$part"
            break
        fi
    done
    
    # If no root partition found, use the first partition
    if [[ -z "$system_partition" ]]; then
        system_partition=$(echo "$system_partitions" | head -n1)
    fi
    
    if [[ -z "$system_partition" ]]; then
        log "ERROR" "Could not find system partition on $system_drive"
        return 1
    fi
    
    log "INFO" "Found main system partition: $system_partition"
    
    # Step 1: Clone partition table to target drive
    log "INFO" "Cloning partition table from $system_drive to $target_drive..."
    if ! sfdisk -d "$system_drive" | sfdisk "$target_drive"; then
        log "ERROR" "Failed to clone partition table"
        return 1
    fi
    
    # Wait for partition table to be recognized
    partprobe "$target_drive"
    sleep 3
    
    # Get the corresponding target partition
    local target_partition=""
    local partition_num
    # Extract partition number using parameter expansion
    local temp="${system_partition##*[!0-9]}"
    partition_num="${temp:-1}"
    
    # Try different naming schemes
    for candidate in "${target_drive}${partition_num}" "${target_drive}p${partition_num}"; do
        if [[ -b "$candidate" ]]; then
            target_partition="$candidate"
            break
        fi
    done
    
    if [[ -z "$target_partition" ]]; then
        log "ERROR" "Could not find target partition on $target_drive"
        return 1
    fi
    
    log "INFO" "Target partition: $target_partition"
    
    # Step 2: Create degraded RAID1 array with target partition only
    log "INFO" "Creating degraded RAID1 array $md_device with target partition..."
    if ! mdadm --create "$md_device" --level=1 --raid-devices=2 missing "$target_partition" --force; then
        log "ERROR" "Failed to create degraded RAID array"
        return 1
    fi
    
    # Wait for array to be ready
    sleep 3
    
    # Step 3: Copy system data to RAID array
    log "INFO" "Copying system data from $system_partition to $md_device..."
    log "INFO" "This may take a long time depending on the size of your system partition..."
    if ! dd if="$system_partition" of="$md_device" bs=64K status=progress; then
        log "ERROR" "Failed to copy system data"
        return 1
    fi
    
    # Step 4: Add original system partition to RAID array
    log "INFO" "Adding original system partition $system_partition to RAID array..."
    if ! mdadm --add "$md_device" "$system_partition"; then
        log "ERROR" "Failed to add system partition to RAID array"
        return 1
    fi
    
    # Step 5: Update fstab for RAID
    log "INFO" "Updating fstab for RAID boot..."
    update_fstab_for_raid "$system_partition" "$md_device"
    
    # Step 6: Update GRUB for RAID boot
    log "INFO" "Updating GRUB for RAID boot..."
    update_grub_for_raid "$md_device"
    
    # Step 7: Install GRUB on both drives
    log "INFO" "Installing GRUB on both drives..."
    grub-install "$system_drive" || log "WARN" "Failed to install GRUB on $system_drive"
    grub-install "$target_drive" || log "WARN" "Failed to install GRUB on $target_drive"
    update-grub || log "WARN" "Failed to update GRUB configuration"
    
    log "INFO" "System drive mirroring completed successfully!"
    log "INFO" "RAID array $md_device is now syncing. This may take some time."
    log "WARN" "You should reboot the system to test RAID boot functionality."
    log "INFO" "After reboot, you can check RAID status with: cat /proc/mdstat"
}

# Function to update fstab for RAID boot
update_fstab_for_raid() {
    local old_partition="$1"
    local raid_device="$2"
    
    log "INFO" "Updating /etc/fstab to use RAID device..."
    
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
    
    # Get UUID or device path of old partition
    local old_uuid
    old_uuid=$(blkid -s UUID -o value "$old_partition" 2>/dev/null || echo "")
    
    if [[ -n "$old_uuid" ]]; then
        # Replace by UUID
        log "INFO" "Replacing UUID=$old_uuid with UUID=$raid_uuid in fstab"
        sed -i "s/UUID=$old_uuid/UUID=$raid_uuid/g" /etc/fstab
    else
        # Replace by device name
        log "INFO" "Replacing $old_partition with $raid_device in fstab"
        sed -i "s|$old_partition|$raid_device|g" /etc/fstab
    fi
    
    log "INFO" "Updated fstab to use RAID device"
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

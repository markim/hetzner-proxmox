#!/bin/bash

# Hetzner Proxmox RAID Mirror Removal Script
# This script removes ALL RAID mirror configurations (including system mirrors)
# Data is preserved on individual drives

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source common functions
# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/common.sh"

# Function to get all RAID arrays using multiple methods for maximum reliability
get_all_raid_arrays() {
    local arrays=()
    local temp_arrays=()
    
    # Method 1: Use lsblk to find md devices - most reliable
    if command -v lsblk >/dev/null 2>&1; then
        log "DEBUG" "Scanning for RAID arrays using lsblk..."
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                local device
                local type
                device=$(echo "$line" | awk '{print $1}')
                type=$(echo "$line" | awk '{print $2}')
                if [[ "$device" =~ ^md[0-9]+$ ]] && [[ "$type" =~ raid ]]; then
                    temp_arrays+=("$device")
                fi
            fi
        done < <(lsblk -no NAME,TYPE 2>/dev/null | grep -E 'md[0-9]+.*raid' || true)
    fi
    
    # Method 2: Check /proc/mdstat as fallback
    if [[ -f /proc/mdstat ]]; then
        log "DEBUG" "Scanning for RAID arrays using /proc/mdstat..."
        while IFS= read -r line; do
            if [[ "$line" =~ ^(md[0-9]+) ]]; then
                temp_arrays+=("${BASH_REMATCH[1]}")
            fi
        done < <(grep -E '^md[0-9]+' /proc/mdstat 2>/dev/null || true)
    fi
    
    # Method 3: Check /dev for md devices
    log "DEBUG" "Scanning for RAID arrays in /dev..."
    for device in /dev/md[0-9]*; do
        if [[ -b "$device" ]]; then
            local md_name
            md_name=$(basename "$device")
            temp_arrays+=("$md_name")
        fi
    done
    
    # Remove duplicates and verify devices actually exist
    for array in "${temp_arrays[@]}"; do
        if [[ -n "$array" ]] && [[ -b "/dev/$array" ]]; then
            # Check if we already have this array
            local found=false
            for existing in "${arrays[@]}"; do
                if [[ "$existing" == "$array" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == "false" ]]; then
                arrays+=("$array")
            fi
        fi
    done
    
    # Sort and output
    if [[ ${#arrays[@]} -gt 0 ]]; then
        printf '%s\n' "${arrays[@]}" | sort -V
    fi
}

# Function to get drives in a RAID array using mdadm
get_raid_members() {
    local md_device="$1"
    local members=()
    
    # Use mdadm to get detailed information
    if [[ -b "/dev/$md_device" ]] && command -v mdadm >/dev/null 2>&1; then
        # Get member devices using mdadm --detail
        while IFS= read -r line; do
            # Look for lines with device paths like /dev/sda1, /dev/nvme0n1p1, etc.
            if [[ "$line" =~ /dev/([a-zA-Z0-9]+) ]]; then
                local device="${BASH_REMATCH[1]}"
                # Skip if it looks like the md device itself
                if [[ ! "$device" =~ ^md[0-9]+$ ]]; then
                    members+=("$device")
                fi
            fi
        done < <(mdadm --detail "/dev/$md_device" 2>/dev/null | grep -E '^\s+[0-9]+\s+[0-9]+\s+[0-9]+\s+[0-9]+\s+active' || true)
    fi
    
    # Fallback: try to extract from /proc/mdstat
    if [[ ${#members[@]} -eq 0 ]] && [[ -f /proc/mdstat ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^$md_device ]]; then
                # Extract drive names from the line
                # Format: md0 : active raid1 sdb1[1] sda1[0]
                while [[ "$line" =~ ([a-zA-Z0-9]+)\[[0-9]+\] ]]; do
                    local device="${BASH_REMATCH[1]}"
                    if [[ ! "$device" =~ ^md[0-9]+$ ]]; then
                        members+=("$device")
                    fi
                    line="${line/${BASH_REMATCH[0]}/}"
                done
                break
            fi
        done < <(grep -E "^$md_device" /proc/mdstat 2>/dev/null || true)
    fi
    
    # Remove duplicates and output
    if [[ ${#members[@]} -gt 0 ]]; then
        printf '%s\n' "${members[@]}" | sort -u
    fi
}

# Function to check if array is system array
is_system_array() {
    local md_device="$1"
    
    # Check if the array is mounted on system paths
    local mount_points
    mount_points=$(findmnt -n -o TARGET -S "/dev/$md_device" 2>/dev/null || true)
    
    if [[ -n "$mount_points" ]]; then
        while IFS= read -r mount_point; do
            if [[ -n "$mount_point" ]]; then
                case "$mount_point" in
                    "/" | "/boot" | "/var" | "/usr" | "/home" | "/opt" | "/tmp")
                        return 0
                        ;;
                esac
            fi
        done <<< "$mount_points"
    fi
    
    # Check if root filesystem is on this array
    local root_device
    root_device=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    if [[ "$root_device" == "/dev/$md_device" ]] || [[ "$root_device" =~ ^/dev/${md_device}p?[0-9]+$ ]]; then
        return 0
    fi
    
    return 1
}

# Function to safely remove a RAID array
remove_raid_array() {
    local md_device="$1"
    local force="${2:-false}"
    
    log "INFO" "Removing RAID array: $md_device"
    
    # Check if device exists
    if [[ ! -b "/dev/$md_device" ]]; then
        log "WARNING" "Device /dev/$md_device does not exist, skipping"
        return 0
    fi
    
    # Get array details before removal
    local members
    mapfile -t members < <(get_raid_members "$md_device")
    
    if [[ ${#members[@]} -eq 0 ]]; then
        log "WARNING" "No members found for array $md_device, attempting removal anyway"
    else
        log "INFO" "Array $md_device contains drives: ${members[*]}"
    fi
    
    # Check if array is mounted and unmount if needed
    local mount_points
    mount_points=$(findmnt -n -o TARGET -S "/dev/$md_device" 2>/dev/null || true)
    
    if [[ -n "$mount_points" ]]; then
        log "INFO" "Unmounting filesystems on $md_device..."
        while IFS= read -r mount_point; do
            if [[ -n "$mount_point" ]]; then
                log "INFO" "Unmounting: $mount_point"
                if ! umount "$mount_point" 2>/dev/null; then
                    if [[ "$force" == "true" ]]; then
                        log "WARNING" "Force unmounting: $mount_point"
                        umount -f "$mount_point" 2>/dev/null || umount -l "$mount_point" 2>/dev/null || log "ERROR" "Failed to force unmount $mount_point"
                    else
                        log "ERROR" "Failed to unmount $mount_point. Use --force to force unmount."
                        return 1
                    fi
                fi
            fi
        done <<< "$mount_points"
    fi
    
    # Remove from Proxmox storage configuration if it exists
    local storage_name="data-$md_device"
    if command -v pvesm >/dev/null 2>&1 && pvesm status "$storage_name" >/dev/null 2>&1; then
        log "INFO" "Removing Proxmox storage: $storage_name"
        pvesm remove "$storage_name" 2>/dev/null || log "WARNING" "Failed to remove Proxmox storage $storage_name"
    fi
    
    # Stop the array
    log "INFO" "Stopping RAID array: $md_device"
    if ! mdadm --stop "/dev/$md_device" 2>/dev/null; then
        log "WARNING" "Failed to stop RAID array $md_device normally, trying force stop"
        # Try force stop
        if ! mdadm --stop --force "/dev/$md_device" 2>/dev/null; then
            log "ERROR" "Failed to stop RAID array $md_device even with force"
            return 1
        fi
    fi
    
    # Zero superblocks on member drives
    if [[ ${#members[@]} -gt 0 ]]; then
        log "INFO" "Clearing RAID superblocks from member drives..."
        for member in "${members[@]}"; do
            if [[ -n "$member" ]] && [[ -b "/dev/$member" ]]; then
                log "INFO" "Clearing superblock from /dev/$member"
                mdadm --zero-superblock "/dev/$member" 2>/dev/null || log "WARNING" "Failed to clear superblock from /dev/$member"
            fi
        done
    else
        log "WARNING" "No member drives found to clear superblocks from"
    fi
    
    log "INFO" "Successfully removed RAID array: $md_device"
    return 0
}

# Function to show current RAID status
show_raid_status() {
    log "INFO" "Current RAID status:"
    echo "======================"
    
    # Get arrays using the reliable method
    local arrays
    mapfile -t arrays < <(get_all_raid_arrays)
    
    if [[ ${#arrays[@]} -eq 0 ]]; then
        log "INFO" "No RAID arrays found"
        
        # Show /proc/mdstat for reference if it exists
        if [[ -f /proc/mdstat ]]; then
            log "INFO" "Contents of /proc/mdstat:"
            cat /proc/mdstat 2>/dev/null || log "WARNING" "Could not read /proc/mdstat"
        fi
        return 0
    fi
    
    # Process each array
    for array in "${arrays[@]}"; do
        if [[ -z "$array" ]]; then
            continue
        fi
        
        local members
        mapfile -t members < <(get_raid_members "$array")
        
        local status="DATA"
        if is_system_array "$array"; then
            status="SYSTEM"
        fi
        
        log "INFO" "  $array [$status]: ${members[*]:-No members found}"
        
        # Show mount points if any
        local mount_points
        mount_points=$(findmnt -n -o TARGET -S "/dev/$array" 2>/dev/null || true)
        if [[ -n "$mount_points" ]]; then
            while IFS= read -r mount_point; do
                if [[ -n "$mount_point" ]]; then
                    log "INFO" "    └─ Mounted at: $mount_point"
                fi
            done <<< "$mount_points"
        fi
    done
    
    echo
    log "INFO" "Full /proc/mdstat output:"
    if [[ -f /proc/mdstat ]]; then
        cat /proc/mdstat 2>/dev/null || log "WARNING" "Could not read /proc/mdstat"
    else
        log "INFO" "No /proc/mdstat file found"
    fi
}

# Function to remove all RAID mirrors (including system mirrors)
remove_all_mirrors() {
    local force="${1:-false}"
    
    log "INFO" "Scanning for ALL RAID arrays to remove (including system mirrors)..."
    
    local arrays
    mapfile -t arrays < <(get_all_raid_arrays)
    
    if [[ ${#arrays[@]} -eq 0 ]]; then
        log "INFO" "No RAID arrays found"
        return 0
    fi
    
    local system_arrays=()
    local data_arrays=()
    
    # Categorize arrays for information only
    for array in "${arrays[@]}"; do
        if [[ -z "$array" ]]; then
            continue
        fi
        
        if is_system_array "$array"; then
            system_arrays+=("$array")
        else
            data_arrays+=("$array")
        fi
    done
    
    # Show what will be removed
    log "INFO" "⚠️  ALL arrays will be removed (including system arrays):"
    if [[ ${#system_arrays[@]} -gt 0 ]]; then
        log "INFO" "System arrays (will be removed):"
        for array in "${system_arrays[@]}"; do
            local members
            mapfile -t members < <(get_raid_members "$array")
            log "INFO" "  $array: ${members[*]:-No members} [SYSTEM]"
        done
    fi
    
    if [[ ${#data_arrays[@]} -gt 0 ]]; then
        log "INFO" "Data arrays (will be removed):"
        for array in "${data_arrays[@]}"; do
            local members
            mapfile -t members < <(get_raid_members "$array")
            log "INFO" "  $array: ${members[*]:-No members} [DATA]"
        done
    fi
    
    # Confirm removal unless force flag is set
    if [[ "$force" != "true" ]]; then
        echo
        log "WARNING" "⚠️  This will remove ALL ${#arrays[@]} RAID array(s) including SYSTEM arrays!"
        log "WARNING" "⚠️  Your system may not boot properly after this operation!"
        log "WARNING" "⚠️  Ensure you have a way to boot from individual drives!"
        echo
        read -p "⚠️  Continue with removing ALL RAID arrays including system? (y/N): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "INFO" "Operation cancelled by user"
            return 0
        fi
        
        echo
        read -p "⚠️  Are you absolutely sure? This cannot be undone! (y/N): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "INFO" "Operation cancelled by user"
            return 0
        fi
    fi
    
    # Remove ALL arrays
    local success_count=0
    local failed_arrays=()
    
    for array in "${arrays[@]}"; do
        if [[ -z "$array" ]]; then
            continue
        fi
        
        if remove_raid_array "$array" "$force"; then
            ((success_count++))
        else
            failed_arrays+=("$array")
            log "ERROR" "Failed to remove array: $array"
        fi
    done
    
    log "INFO" "Successfully removed $success_count of ${#arrays[@]} RAID arrays"
    
    if [[ ${#failed_arrays[@]} -gt 0 ]]; then
        log "WARNING" "Failed to remove arrays: ${failed_arrays[*]}"
    fi
    
    if [[ $success_count -gt 0 ]]; then
        log "INFO" "Updating mdadm configuration..."
        # Clear the mdadm.conf since we removed everything
        echo "# All RAID arrays have been removed on $(date)" > /etc/mdadm/mdadm.conf 2>/dev/null || log "WARNING" "Failed to update mdadm.conf"
        
        log "INFO" "Updating initramfs..."
        update-initramfs -u 2>/dev/null || log "WARNING" "Failed to update initramfs"
        
        log "WARNING" "⚠️  System reboot may be required to boot from individual drives"
    fi
}

# ========================================================================
# ADVANCED SYSTEM MIRRORING FUNCTIONS
# ========================================================================
# These functions provide proper system drive mirroring for advanced users
# WARNING: Use these functions with extreme caution!

# Function to setup system drive mirroring (Proxmox with LVM)
setup_proxmox_system_mirror() {
    local system_drive="$1"
    local target_drive="$2"
    
    log "WARN" "⚠️  ADVANCED SYSTEM MIRRORING FOR PROXMOX ⚠️"
    log "WARN" "This function sets up proper mirroring for Proxmox systems with LVM."
    log "WARN" "This is an ADVANCED operation that can make your system unbootable!"
    log "WARN" "System drive: $system_drive"
    log "WARN" "Target drive: $target_drive"
    echo
    
    # Verify this is a Proxmox system
    if ! command -v pveversion >/dev/null 2>&1; then
        log "ERROR" "This function is for Proxmox systems only"
        return 1
    fi
    
    # Check system setup
    log "INFO" "Analyzing current Proxmox system setup..."
    local boot_partition=""
    local lvm_partition=""
    
    # Get partitions on system drive
    local partitions
    partitions=$(lsblk "$system_drive" -lno NAME,TYPE | grep "part" | awk '{print "/dev/"$1}')
    
    log "INFO" "System drive partitions:"
    for part in $partitions; do
        local mountpoint size fstype
        mountpoint=$(lsblk "$part" -no MOUNTPOINT 2>/dev/null || echo "")
        size=$(lsblk "$part" -no SIZE 2>/dev/null || echo "")
        fstype=$(lsblk "$part" -no FSTYPE 2>/dev/null || echo "")
        
        log "INFO" "  $part ($size, $fstype) -> $mountpoint"
        
        if [[ "$mountpoint" == "/boot" ]]; then
            boot_partition="$part"
        elif [[ "$fstype" == "LVM2_member" ]]; then
            lvm_partition="$part"
            log "INFO" "    LVM partition detected: $lvm_partition"
        fi
    done
    
    if [[ -z "$boot_partition" ]] || [[ -z "$lvm_partition" ]]; then
        log "ERROR" "Could not identify boot partition and LVM partition"
        log "ERROR" "Boot: $boot_partition, LVM: $lvm_partition"
        return 1
    fi
    
    log "INFO" "Identified partitions:"
    log "INFO" "  Boot partition: $boot_partition"
    log "INFO" "  LVM partition: $lvm_partition"
    
    # Create the mirror setup
    if ! create_proxmox_mirror_setup "$system_drive" "$target_drive" "$boot_partition" "$lvm_partition"; then
        log "ERROR" "Failed to create Proxmox mirror setup"
        return 1
    fi
    
    log "INFO" "Proxmox system mirroring setup completed successfully!"
    log "WARN" "System will need to be rebooted to activate RAID boot."
    log "INFO" "Check RAID status after reboot with: cat /proc/mdstat"
    
    return 0
}

# Function to create Proxmox mirror setup
create_proxmox_mirror_setup() {
    local system_drive="$1"
    local target_drive="$2"
    local boot_partition="$3"
    local lvm_partition="$4"
    
    log "INFO" "Creating Proxmox mirror setup..."
    
    # Step 1: Clone partition table
    log "INFO" "Step 1: Cloning partition table from $system_drive to $target_drive..."
    if ! sfdisk -d "$system_drive" | sfdisk "$target_drive"; then
        log "ERROR" "Failed to clone partition table"
        return 1
    fi
    
    # Wait for partitions to be recognized
    partprobe "$target_drive"
    sleep 5
    
    # Step 2: Determine target partitions
    local target_boot=""
    local target_lvm=""
    local boot_part_num=""
    local lvm_part_num=""
    
    # Extract partition numbers
    boot_part_num=$(echo "$boot_partition" | grep -o '[0-9]*$')
    lvm_part_num=$(echo "$lvm_partition" | grep -o '[0-9]*$')
    
    # Determine target partition naming scheme
    if [[ "$target_drive" =~ nvme ]]; then
        target_boot="${target_drive}p${boot_part_num}"
        target_lvm="${target_drive}p${lvm_part_num}"
    else
        target_boot="${target_drive}${boot_part_num}"
        target_lvm="${target_drive}${lvm_part_num}"
    fi
    
    # Wait for target partitions to be available
    log "INFO" "Waiting for target partitions to be available..."
    for i in {1..10}; do
        if [[ -b "$target_boot" ]] && [[ -b "$target_lvm" ]]; then
            break
        fi
        log "INFO" "Waiting for partitions... ($i/10)"
        sleep 2
    done
    
    if [[ ! -b "$target_boot" ]] || [[ ! -b "$target_lvm" ]]; then
        log "ERROR" "Target partitions not available"
        log "ERROR" "Expected: $target_boot, $target_lvm"
        return 1
    fi
    
    log "INFO" "Target partitions ready:"
    log "INFO" "  Boot: $target_boot"
    log "INFO" "  LVM: $target_lvm"
    
    # Step 3: Create RAID arrays
    log "INFO" "Step 3: Creating RAID arrays..."
    
    # Create boot RAID (md126)
    log "INFO" "Creating boot RAID array..."
    if ! mdadm --create /dev/md126 --level=1 --raid-devices=2 missing "$target_boot" --force; then
        log "ERROR" "Failed to create boot RAID array"
        return 1
    fi
    
    # Create LVM RAID (md127)
    log "INFO" "Creating LVM RAID array..."
    if ! mdadm --create /dev/md127 --level=1 --raid-devices=2 missing "$target_lvm" --force; then
        log "ERROR" "Failed to create LVM RAID array"
        return 1
    fi
    
    # Wait for arrays to initialize
    sleep 5
    
    # Step 4: Copy data
    log "INFO" "Step 4: Copying boot partition data..."
    if ! dd if="$boot_partition" of=/dev/md126 bs=64K status=progress; then
        log "ERROR" "Failed to copy boot partition data"
        return 1
    fi
    
    log "INFO" "Copying LVM partition data (this may take a long time)..."
    if ! dd if="$lvm_partition" of=/dev/md127 bs=64K status=progress; then
        log "ERROR" "Failed to copy LVM partition data"
        return 1
    fi
    
    # Step 5: Add original partitions to RAID arrays
    log "INFO" "Step 5: Adding original partitions to RAID arrays..."
    
    if ! mdadm --add /dev/md126 "$boot_partition"; then
        log "ERROR" "Failed to add boot partition to RAID"
        return 1
    fi
    
    if ! mdadm --add /dev/md127 "$lvm_partition"; then
        log "ERROR" "Failed to add LVM partition to RAID"
        return 1
    fi
    
    # Step 6: Update system configuration
    log "INFO" "Step 6: Updating system configuration..."
    
    # Update fstab
    update_fstab_for_proxmox_raid "$boot_partition" "$lvm_partition"
    
    # Update GRUB
    update_grub_for_proxmox_raid "$system_drive" "$target_drive"
    
    # Update mdadm configuration
    mdadm --detail --scan > /etc/mdadm/mdadm.conf
    update-initramfs -u -k all
    
    log "INFO" "System configuration updated successfully"
    
    return 0
}

# Function to update fstab for Proxmox RAID
update_fstab_for_proxmox_raid() {
    local boot_partition="$1"
    local lvm_partition="$2"
    
    log "INFO" "Updating /etc/fstab for Proxmox RAID setup..."
    
    # Backup fstab
    local backup_file
    backup_file="/etc/fstab.backup.$(date +%Y%m%d_%H%M%S)"
    cp /etc/fstab "$backup_file"
    log "INFO" "Backed up fstab to $backup_file"
    
    # Get UUIDs
    local boot_uuid boot_raid_uuid
    boot_uuid=$(blkid -s UUID -o value "$boot_partition" 2>/dev/null || echo "")
    
    # Wait for RAID devices to have UUIDs
    sleep 3
    boot_raid_uuid=$(blkid -s UUID -o value /dev/md126 2>/dev/null || echo "")
    
    # Update boot partition entry
    if [[ -n "$boot_uuid" ]] && [[ -n "$boot_raid_uuid" ]]; then
        log "INFO" "Updating boot partition UUID in fstab"
        sed -i "s/UUID=$boot_uuid/UUID=$boot_raid_uuid/g" /etc/fstab
    else
        log "INFO" "Updating boot partition device in fstab"
        sed -i "s|$boot_partition|/dev/md126|g" /etc/fstab
    fi
    
    # Note: LVM will automatically use the RAID device once PVs are updated
    log "INFO" "fstab updated for Proxmox RAID"
}

# Function to update GRUB for Proxmox RAID
update_grub_for_proxmox_raid() {
    local system_drive="$1"
    local target_drive="$2"
    
    log "INFO" "Updating GRUB for Proxmox RAID boot..."
    
    # Ensure RAID modules are loaded
    if [[ ! -f /etc/initramfs-tools/modules ]]; then
        touch /etc/initramfs-tools/modules
    fi
    
    # Add RAID modules
    for module in raid1 md_mod; do
        if ! grep -q "^$module$" /etc/initramfs-tools/modules; then
            echo "$module" >> /etc/initramfs-tools/modules
            log "INFO" "Added $module to initramfs modules"
        fi
    done
    
    # Update GRUB configuration
    if [[ -f /etc/default/grub ]]; then
        local grub_backup
        grub_backup="/etc/default/grub.backup.$(date +%Y%m%d_%H%M%S)"
        cp /etc/default/grub "$grub_backup"
        log "INFO" "Backed up GRUB config to $grub_backup"
        
        # Add RAID preload modules
        if ! grep -q "GRUB_PRELOAD_MODULES.*raid" /etc/default/grub; then
            if grep -q "^GRUB_PRELOAD_MODULES=" /etc/default/grub; then
                sed -i 's/^GRUB_PRELOAD_MODULES=.*/GRUB_PRELOAD_MODULES="raid mdraid1x"/' /etc/default/grub
            else
                echo 'GRUB_PRELOAD_MODULES="raid mdraid1x"' >> /etc/default/grub
            fi
            log "INFO" "Added RAID modules to GRUB preload"
        fi
    fi
    
    # Install GRUB on both drives
    log "INFO" "Installing GRUB on both drives..."
    grub-install "$system_drive" || log "WARN" "Failed to install GRUB on $system_drive"
    grub-install "$target_drive" || log "WARN" "Failed to install GRUB on $target_drive"
    
    # Update GRUB configuration
    update-grub || log "WARN" "Failed to update GRUB configuration"
    
    log "INFO" "GRUB configuration updated for RAID boot"
}

# Function to fix broken system RAID (like the current md1 issue)
fix_broken_system_raid() {
    log "INFO" "Checking for broken system RAID arrays..."
    
    # Get all RAID arrays
    local arrays
    arrays=$(get_all_raid_arrays)
    
    if [[ -z "$arrays" ]]; then
        log "INFO" "No RAID arrays found"
        return 0
    fi
    
    for array in $arrays; do
        log "INFO" "Checking RAID array: $array"
        
        # Check if array is degraded or has issues
        local status
        status=$(mdadm --detail "/dev/$array" 2>/dev/null | grep "State :" | awk '{print $3}' || echo "unknown")
        
        if [[ "$status" =~ (degraded|failed|inactive) ]]; then
            log "WARN" "Found problematic RAID array: $array (status: $status)"
            
            # Ask user what to do
            echo
            log "INFO" "Options for $array:"
            log "INFO" "1. Remove the broken array"
            log "INFO" "2. Try to repair the array"
            log "INFO" "3. Skip this array"
            
            read -p "What would you like to do? (1/2/3): " -r choice
            
            case $choice in
                1)
                    log "INFO" "Removing broken RAID array $array..."
                    remove_single_array "$array" true
                    ;;
                2)
                    log "INFO" "Attempting to repair RAID array $array..."
                    repair_raid_array "$array"
                    ;;
                3)
                    log "INFO" "Skipping array $array"
                    ;;
                *)
                    log "WARN" "Invalid choice, skipping array $array"
                    ;;
            esac
        else
            log "INFO" "Array $array appears healthy (status: $status)"
        fi
    done
}

# Function to repair a RAID array
repair_raid_array() {
    local array="$1"
    
    log "INFO" "Attempting to repair RAID array: $array"
    
    # Try to reassemble the array
    if mdadm --stop "/dev/$array" 2>/dev/null; then
        log "INFO" "Stopped array $array"
        
        # Try to scan and assemble
        if mdadm --assemble "/dev/$array" --scan; then
            log "INFO" "Successfully reassembled array $array"
        else
            log "WARN" "Failed to reassemble array $array"
            log "INFO" "Manual intervention may be required"
        fi
    else
        log "WARN" "Could not stop array $array for repair"
    fi
}

# Function to clean up broken system mirror (like the current md1)
cleanup_broken_system_mirror() {
    log "INFO" "=== CLEANING UP BROKEN SYSTEM MIRROR ==="
    log "INFO" "This will remove the broken system RAID and restore normal operation."
    echo
    
    # Check for the specific broken array mentioned in the user's log
    if [[ -b /dev/md1 ]]; then
        log "INFO" "Found broken system RAID array: md1"
        
        # Show current status
        log "INFO" "Current md1 status:"
        mdadm --detail /dev/md1 2>/dev/null || log "WARN" "Could not get md1 details"
        
        echo
        read -p "Remove the broken md1 array? (y/N): " -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            log "INFO" "Removing broken md1 array..."
            
            # Stop and remove the array
            mdadm --stop /dev/md1 2>/dev/null || log "WARN" "Could not stop md1"
            mdadm --zero-superblock /dev/nvme1n1p1 2>/dev/null || log "WARN" "Could not zero superblock on nvme1n1p1"
            
            # Update mdadm configuration
            mdadm --detail --scan > /etc/mdadm/mdadm.conf
            update-initramfs -u -k all
            
            log "INFO" "Broken system mirror cleaned up successfully"
            log "INFO" "System should now boot normally from individual drives"
        else
            log "INFO" "Cleanup cancelled"
        fi
    else
        log "INFO" "No broken md1 array found"
    fi
}

# Function for interactive array selection and removal
interactive_array_selection() {
    log "INFO" "Interactive RAID array removal mode"
    
    local arrays
    mapfile -t arrays < <(get_all_raid_arrays)
    
    if [[ ${#arrays[@]} -eq 0 ]]; then
        log "INFO" "No RAID arrays found"
        return 0
    fi
    
    echo
    log "INFO" "Available RAID arrays:"
    
    # Display arrays with information
    for i in "${!arrays[@]}"; do
        local array="${arrays[$i]}"
        local members
        mapfile -t members < <(get_raid_members "$array")
        local is_system=""
        
        if is_system_array "$array"; then
            is_system=" [SYSTEM]"
        fi
        
        echo "$((i+1)). /dev/$array - Members: ${members[*]:-No members}$is_system"
        
        # Show mount points if any
        local mount_points
        mount_points=$(findmnt -n -o TARGET -S "/dev/$array" 2>/dev/null || true)
        if [[ -n "$mount_points" ]]; then
            echo "   Mounted at: $mount_points"
        fi
        
        # Show detailed status
        if command -v mdadm >/dev/null 2>&1 && [[ -b "/dev/$array" ]]; then
            local status
            status=$(mdadm --detail "/dev/$array" 2>/dev/null | grep -E "State|Active Devices|Working Devices" | head -3 | sed 's/^/   /' || echo "   Status: Unknown")
            echo "$status"
        fi
        echo
    done
    
    while true; do
        echo "Select arrays to remove:"
        echo "  📝 Enter array numbers separated by spaces (e.g., '1 3 4' for arrays 1, 3, and 4)"
        echo "  📝 Enter 'all' to remove all arrays (including system arrays)"
        echo "  📝 Enter 'data' to remove only data arrays (skip system arrays)"
        echo "  📝 Enter 'quit' or 'exit' to cancel"
        echo "  📝 Valid range: 1-${#arrays[@]}"
        echo
        read -p "Your selection: " -r selection
        
        if [[ "$selection" == "quit" ]] || [[ "$selection" == "exit" ]] || [[ "$selection" == "q" ]]; then
            log "INFO" "Operation cancelled by user"
            return 0
        fi
        
        local arrays_to_remove=()
        
        if [[ "$selection" == "all" ]]; then
            arrays_to_remove=("${arrays[@]}")
        elif [[ "$selection" == "data" ]]; then
            # Only include non-system arrays
            for array in "${arrays[@]}"; do
                if ! is_system_array "$array"; then
                    arrays_to_remove+=("$array")
                fi
            done
            
            if [[ ${#arrays_to_remove[@]} -eq 0 ]]; then
                log "INFO" "No data arrays found (all arrays appear to be system arrays)"
                continue
            fi
        else
            # Parse individual array numbers
            local invalid_selections=()
            local valid_count=0
            
            for num in $selection; do
                if [[ "$num" =~ ^[0-9]+$ ]] && [[ $num -ge 1 ]] && [[ $num -le ${#arrays[@]} ]]; then
                    # Check for duplicates
                    local duplicate=false
                    for existing_array in "${arrays_to_remove[@]}"; do
                        if [[ "$existing_array" == "${arrays[$((num-1))]}" ]]; then
                            duplicate=true
                            break
                        fi
                    done
                    
                    if [[ "$duplicate" == "false" ]]; then
                        arrays_to_remove+=("${arrays[$((num-1))]}")
                        ((valid_count++))
                    else
                        log "WARNING" "Array $num already selected (ignoring duplicate)"
                    fi
                else
                    invalid_selections+=("$num")
                fi
            done
            
            # Report any invalid selections but continue if we have valid ones
            if [[ ${#invalid_selections[@]} -gt 0 ]]; then
                log "WARNING" "Invalid selections: ${invalid_selections[*]} (valid range: 1-${#arrays[@]})"
            fi
            
            # If we have some valid selections, continue; otherwise, go back to selection
            if [[ $valid_count -eq 0 ]]; then
                log "ERROR" "No valid arrays selected"
                continue
            elif [[ ${#invalid_selections[@]} -gt 0 ]]; then
                log "INFO" "Proceeding with $valid_count valid array selection(s)"
            fi
        fi
        
        # Show selected arrays and categorize them
        echo
        log "INFO" "Selected arrays for removal:"
        local system_arrays_selected=()
        local data_arrays_selected=()
        
        for array in "${arrays_to_remove[@]}"; do
            local members
            mapfile -t members < <(get_raid_members "$array")
            
            if is_system_array "$array"; then
                system_arrays_selected+=("$array")
                log "WARNING" "  ⚠️  /dev/$array - Members: ${members[*]:-No members} [SYSTEM]"
            else
                data_arrays_selected+=("$array")
                log "INFO" "  📀 /dev/$array - Members: ${members[*]:-No members} [DATA]"
            fi
        done
        
        # Warn about system arrays
        if [[ ${#system_arrays_selected[@]} -gt 0 ]]; then
            echo
            log "WARNING" "⚠️  WARNING: You have selected ${#system_arrays_selected[@]} SYSTEM array(s)!"
            log "WARNING" "⚠️  Removing system arrays may make your system unbootable!"
            log "WARNING" "⚠️  System arrays: ${system_arrays_selected[*]}"
        fi
        
        echo
        log "WARNING" "⚠️  This will remove ${#arrays_to_remove[@]} RAID array(s)"
        if [[ ${#system_arrays_selected[@]} -gt 0 ]]; then
            log "WARNING" "⚠️  Including ${#system_arrays_selected[@]} SYSTEM array(s) that may affect boot!"
        fi
        echo
        read -p "⚠️  Continue with removing these ${#arrays_to_remove[@]} array(s)? (y/N): " -r confirm
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            log "INFO" "Operation cancelled"
            continue
        fi
        
        # Additional confirmation for system arrays
        if [[ ${#system_arrays_selected[@]} -gt 0 ]]; then
            echo
            read -p "⚠️  You selected SYSTEM arrays. Type 'REMOVE SYSTEM' to confirm: " -r system_confirm
            if [[ "$system_confirm" != "REMOVE SYSTEM" ]]; then
                log "INFO" "System array removal cancelled (you must type exactly 'REMOVE SYSTEM')"
                continue
            fi
        fi
        
        # Remove selected arrays
        remove_selected_arrays "${arrays_to_remove[@]}"
        break
    done
}

# Function to remove selected arrays
remove_selected_arrays() {
    local arrays_to_remove=("$@")
    
    log "INFO" "🚀 Starting removal of ${#arrays_to_remove[@]} selected array(s)..."
    
    local success_count=0
    local failed_arrays=()
    local array_counter=1
    
    for array in "${arrays_to_remove[@]}"; do
        echo
        log "INFO" "📀 [$array_counter/${#arrays_to_remove[@]}] Removing RAID array: /dev/$array"
        
        if remove_raid_array "$array" "false"; then
            ((success_count++))
            log "INFO" "✅ [$array_counter/${#arrays_to_remove[@]}] Successfully removed /dev/$array"
        else
            failed_arrays+=("$array")
            log "ERROR" "❌ [$array_counter/${#arrays_to_remove[@]}] Failed to remove /dev/$array"
        fi
        
        ((array_counter++))
    done
    
    echo
    log "INFO" "Removal completed!"
    log "INFO" "Successfully removed: $success_count of ${#arrays_to_remove[@]} arrays"
    
    if [[ ${#failed_arrays[@]} -gt 0 ]]; then
        log "WARNING" "Failed to remove the following arrays:"
        for failed_array in "${failed_arrays[@]}"; do
            log "WARNING" "  - /dev/$failed_array"
        done
        echo
        log "INFO" "Common reasons for removal failures:"
        log "INFO" "  - Array is still mounted and cannot be unmounted"
        log "INFO" "  - Array is part of active LVM or other storage system"
        log "INFO" "  - Hardware or driver issues"
        log "INFO" "  - Insufficient permissions"
        log "INFO" "Try using --force flag or manually investigate the failed arrays"
    fi
    
    if [[ $success_count -gt 0 ]]; then
        log "INFO" "Updating mdadm configuration..."
        # Update mdadm.conf to remove the deleted arrays
        if [[ -f /etc/mdadm/mdadm.conf ]]; then
            # Create backup
            cp /etc/mdadm/mdadm.conf "/etc/mdadm/mdadm.conf.backup.$(date +%Y%m%d_%H%M%S)"
            
            # Regenerate configuration with remaining arrays
            echo "# Updated after removing arrays on $(date)" > /etc/mdadm/mdadm.conf
            mdadm --detail --scan >> /etc/mdadm/mdadm.conf 2>/dev/null || log "WARNING" "No arrays left for mdadm.conf"
        fi
        
        log "INFO" "Updating initramfs..."
        update-initramfs -u 2>/dev/null || log "WARNING" "Failed to update initramfs"
        
        # Check if any system arrays were removed
        local system_removed=false
        for removed_array in "${arrays_to_remove[@]}"; do
            local was_successful=true
            for failed_array in "${failed_arrays[@]}"; do
                if [[ "$removed_array" == "$failed_array" ]]; then
                    was_successful=false
                    break
                fi
            done
            
            if $was_successful && is_system_array "$removed_array"; then
                system_removed=true
                break
            fi
        done
        
        if $system_removed; then
            log "WARNING" "⚠️  System RAID arrays were removed - reboot may be required!"
        fi
    fi
    
    echo
    log "INFO" "📊 Final RAID status:"
    show_raid_status
}

# Main function
main() {
    local force=false
    local show_status=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                force=true
                shift
                ;;
            --status)
                show_status=true
                shift
                ;;
            --interactive|-i)
                # Interactive is now default behavior when not using --force
                # This option is kept for clarity but doesn't change behavior
                shift
                ;;
            --cleanup-broken)
                cleanup_broken_system_mirror
                exit 0
                ;;
            --fix-raid)
                fix_broken_system_raid
                exit 0
                ;;
            --setup-system-mirror)
                if [[ $# -lt 3 ]]; then
                    log "ERROR" "Usage: $0 --setup-system-mirror <system_drive> <target_drive>"
                    log "ERROR" "Example: $0 --setup-system-mirror /dev/nvme0n1 /dev/nvme1n1"
                    exit 1
                fi
                setup_proxmox_system_mirror "$2" "$3"
                exit 0
                ;;
            --help|-h)
                cat << EOF
Usage: $0 [OPTIONS] [ARGS]

Remove RAID mirror configurations, preserving data on individual drives.
Also provides advanced system mirroring functions for experienced users.

OPTIONS:
    --interactive, -i             Select specific arrays to remove (default mode)
    --force                       Skip confirmation prompts and force unmount if needed
    --status                      Show current RAID status and exit
    --cleanup-broken              Clean up broken/degraded system RAID arrays
    --fix-raid                    Attempt to fix broken RAID arrays interactively
    --setup-system-mirror <sys> <tgt> Set up proper system mirroring (ADVANCED)
    --help                        Show this help message

EXAMPLES:
    $0                                       # Interactive mode - select arrays to remove
    $0 --interactive                         # Same as above (explicit)
    $0 --status                              # Show current RAID arrays
    $0 --force                               # Remove ALL RAID mirrors including system (no confirmation)
    $0 --cleanup-broken                      # Clean up broken system RAID arrays (like degraded md1)
    $0 --fix-raid                            # Interactively fix broken RAID arrays
    $0 --setup-system-mirror /dev/nvme0n1 /dev/nvme1n1  # Set up proper system mirroring

MODES:
    Interactive (default): Select specific RAID arrays to remove
    Force: Remove ALL RAID arrays including system arrays (dangerous)

SAFETY:
    - Interactive mode allows selective removal of arrays
    - Force mode removes ALL RAID arrays including system/root arrays
    - Original data remains accessible on individual drives
    - System may need to be rebooted to boot from individual drives
    - Prompts for confirmation unless --force is used
    - Updates mdadm configuration after removal

ADVANCED SYSTEM MIRRORING:
    - --setup-system-mirror provides proper Proxmox system mirroring
    - Creates separate RAID arrays for boot and LVM partitions
    - Updates GRUB and fstab configurations automatically
    - Requires manual verification and testing after setup

WARNING:
    System mirroring operations can make your system unbootable if not done correctly!
    Always test in a development environment first.

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
    
    if [[ "$show_status" == "true" ]]; then
        show_raid_status
        exit 0
    fi
    
    log "INFO" "Starting RAID mirror removal process..."
    
    # Show current status first
    show_raid_status
    echo
    
    # Determine mode based on force flag
    if [[ "$force" == "true" ]]; then
        # Force mode: Remove ALL arrays (including system arrays) without interaction
        log "WARNING" "Force mode: Removing ALL arrays including system arrays"
        remove_all_mirrors "$force"
    else
        # Interactive mode: Let user select arrays to remove
        interactive_array_selection
    fi
    
    echo
    log "INFO" "✅ RAID mirror removal completed (ALL mirrors including system)"
    log "INFO" ""
    log "INFO" "⚠️  IMPORTANT: System may need to be rebooted to boot from individual drives"
    log "INFO" ""
    log "INFO" "Next steps:"
    log "INFO" "1. Reboot system if it was using RAID for boot drive"
    log "INFO" "2. Run: ./install.sh --setup-mirrors  # To reconfigure drives from clean state"
    log "INFO" "3. Verify: cat /proc/mdstat     # To check final RAID status"
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

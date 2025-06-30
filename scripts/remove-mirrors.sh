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
            --help|-h)
                cat << EOF
Usage: $0 [OPTIONS]

Remove ALL RAID mirror configurations (including system mirrors), preserving data on individual drives.

OPTIONS:
    --force     Skip confirmation prompts and force unmount if needed
    --status    Show current RAID status and exit
    --help      Show this help message

EXAMPLES:
    $0 --status         # Show current RAID arrays
    $0                  # Remove ALL RAID mirrors including system (with confirmation)
    $0 --force          # Remove ALL RAID mirrors including system (no confirmation)

SAFETY:
    - Removes ALL RAID arrays including system/root arrays
    - Original data remains accessible on individual drives
    - System may need to be rebooted to boot from individual drives
    - Prompts for confirmation unless --force is used
    - Updates mdadm configuration after removal

WARNING:
    This will remove system RAID mirrors! Ensure you can boot from individual drives.

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
    
    # Remove ALL arrays (including system arrays)
    remove_all_mirrors "$force"
    
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

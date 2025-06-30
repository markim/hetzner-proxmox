#!/bin/bash

# Hetzner Proxmox RAID Removal Script
# This script safely removes all non-system RAID arrays

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source common functions
# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/common.sh"

# Function to detect system drive
detect_system_drive() {
    log "DEBUG" "Detecting system drive..."
    
    # Get the root filesystem mount point
    local root_device
    root_device=$(findmnt -n -o SOURCE /)
    
    if [[ -z "$root_device" ]]; then
        log "ERROR" "Cannot determine root filesystem device"
        return 1
    fi
    
    # If it's a partition, get the parent disk
    if [[ "$root_device" =~ [0-9]$ ]]; then
        # Remove partition number to get disk
        root_device="${root_device%[0-9]*}"
    fi
    
    # If it's an md device, resolve to underlying drives
    if [[ "$root_device" =~ ^/dev/md ]]; then
        local md_name
        md_name=$(basename "$root_device")
        log "INFO" "System is on RAID device: $md_name"
        echo "$md_name"
        return 0
    fi
    
    log "DEBUG" "System drive: $root_device"
    basename "$root_device"
}

# Function to get all RAID arrays
get_all_raid_arrays() {
    local arrays=()
    
    if [[ ! -f /proc/mdstat ]]; then
        log "DEBUG" "No /proc/mdstat found - no RAID arrays"
        return 0
    fi
    
    # Parse /proc/mdstat to get all md devices
    while read -r line; do
        if [[ "$line" =~ ^(md[0-9]+) ]]; then
            arrays+=("${BASH_REMATCH[1]}")
        fi
    done < /proc/mdstat
    
    printf '%s\n' "${arrays[@]}"
}

# Function to get drives in a RAID array
get_raid_members() {
    local md_device="$1"
    local members=()
    
    if [[ ! -f /proc/mdstat ]]; then
        return 0
    fi
    
    # Find the line for this md device and extract member drives
    while read -r line; do
        if [[ "$line" =~ ^$md_device ]]; then
            # Extract drive names from the line
            # Format: md0 : active raid1 sdb1[1] sda1[0]
            if [[ "$line" =~ raid1.*([a-z]+[0-9]*\[[0-9]+\].*) ]]; then
                local drives_part="${BASH_REMATCH[1]}"
                # Extract individual drives
                while [[ "$drives_part" =~ ([a-z]+[0-9]*)\[[0-9]+\] ]]; do
                    members+=("${BASH_REMATCH[1]}")
                    drives_part="${drives_part/${BASH_REMATCH[0]}/}"
                done
            fi
            break
        fi
    done < /proc/mdstat
    
    printf '%s\n' "${members[@]}"
}

# Function to check if array is system array
is_system_array() {
    local md_device="$1"
    local system_drive="$2"
    
    # If system drive is an md device, check if it matches
    if [[ "$system_drive" == "$md_device" ]]; then
        return 0
    fi
    
    # Check if the array is mounted on system paths
    local mount_points
    mount_points=$(findmnt -n -o TARGET -S "/dev/$md_device" 2>/dev/null || true)
    
    if [[ -n "$mount_points" ]]; then
        while read -r mount_point; do
            case "$mount_point" in
                "/" | "/boot" | "/var" | "/usr" | "/home" | "/opt" | "/tmp")
                    return 0
                    ;;
            esac
        done <<< "$mount_points"
    fi
    
    # Check if any member drives contain system partitions
    local members
    mapfile -t members < <(get_raid_members "$md_device")
    
    for member in "${members[@]}"; do
        if [[ -z "$member" ]]; then
            continue
        fi
        
        # Get the parent disk
        local parent_disk="/dev/$member"
        if [[ "$member" =~ [0-9]$ ]]; then
            parent_disk="${parent_disk%[0-9]*}"
        fi
        
        # Check if this disk has system mounts
        local disk_mounts
        disk_mounts=$(lsblk "$parent_disk" -no MOUNTPOINT 2>/dev/null | grep -E "^(/|/boot|/var|/usr|/home)$" || true)
        if [[ -n "$disk_mounts" ]]; then
            return 0
        fi
    done
    
    return 1
}

# Function to safely remove a RAID array
remove_raid_array() {
    local md_device="$1"
    local force="${2:-false}"
    
    log "INFO" "Removing RAID array: $md_device"
    
    # Get array details before removal
    local members
    mapfile -t members < <(get_raid_members "$md_device")
    
    if [[ ${#members[@]} -eq 0 ]]; then
        log "WARNING" "No members found for array $md_device"
        return 0
    fi
    
    log "INFO" "Array $md_device contains drives: ${members[*]}"
    
    # Check if array is mounted and unmount if needed
    local mount_points
    mount_points=$(findmnt -n -o TARGET -S "/dev/$md_device" 2>/dev/null || true)
    
    if [[ -n "$mount_points" ]]; then
        log "INFO" "Unmounting filesystems on $md_device..."
        while read -r mount_point; do
            if [[ -n "$mount_point" ]]; then
                log "INFO" "Unmounting: $mount_point"
                if ! umount "$mount_point" 2>/dev/null; then
                    if [[ "$force" == "true" ]]; then
                        log "WARNING" "Force unmounting: $mount_point"
                        umount -f "$mount_point" || log "ERROR" "Failed to force unmount $mount_point"
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
    if pvesm status "$storage_name" >/dev/null 2>&1; then
        log "INFO" "Removing Proxmox storage: $storage_name"
        pvesm remove "$storage_name" || log "WARNING" "Failed to remove Proxmox storage $storage_name"
    fi
    
    # Stop the array
    log "INFO" "Stopping RAID array: $md_device"
    if ! mdadm --stop "/dev/$md_device"; then
        log "ERROR" "Failed to stop RAID array $md_device"
        return 1
    fi
    
    # Zero superblocks on member drives
    log "INFO" "Clearing RAID superblocks from member drives..."
    for member in "${members[@]}"; do
        if [[ -n "$member" ]] && [[ -b "/dev/$member" ]]; then
            log "INFO" "Clearing superblock from /dev/$member"
            mdadm --zero-superblock "/dev/$member" || log "WARNING" "Failed to clear superblock from /dev/$member"
        fi
    done
    
    log "INFO" "Successfully removed RAID array: $md_device"
}

# Function to show current RAID status
show_raid_status() {
    log "INFO" "Current RAID status:"
    echo "======================"
    
    if [[ ! -f /proc/mdstat ]]; then
        log "INFO" "No RAID arrays found (no /proc/mdstat)"
        return 0
    fi
    
    local arrays
    mapfile -t arrays < <(get_all_raid_arrays)
    
    if [[ ${#arrays[@]} -eq 0 ]]; then
        log "INFO" "No RAID arrays found"
        return 0
    fi
    
    local system_drive
    system_drive=$(detect_system_drive)
    
    for array in "${arrays[@]}"; do
        if [[ -z "$array" ]]; then
            continue
        fi
        
        local members
        mapfile -t members < <(get_raid_members "$array")
        
        local status="DATA"
        if is_system_array "$array" "$system_drive"; then
            status="SYSTEM"
        fi
        
        log "INFO" "  $array [$status]: ${members[*]}"
        
        # Show mount points if any
        local mount_points
        mount_points=$(findmnt -n -o TARGET -S "/dev/$array" 2>/dev/null || true)
        if [[ -n "$mount_points" ]]; then
            while read -r mount_point; do
                if [[ -n "$mount_point" ]]; then
                    log "INFO" "    └─ Mounted at: $mount_point"
                fi
            done <<< "$mount_points"
        fi
    done
    
    echo
    log "INFO" "Full /proc/mdstat:"
    cat /proc/mdstat
}

# Function to remove all non-system RAID arrays
remove_all_non_system_raids() {
    local force="${1:-false}"
    
    log "INFO" "Scanning for RAID arrays to remove..."
    
    local arrays
    mapfile -t arrays < <(get_all_raid_arrays)
    
    if [[ ${#arrays[@]} -eq 0 ]]; then
        log "INFO" "No RAID arrays found"
        return 0
    fi
    
    local system_drive
    system_drive=$(detect_system_drive)
    log "INFO" "System drive detected: $system_drive"
    
    local arrays_to_remove=()
    local system_arrays=()
    
    # Categorize arrays
    for array in "${arrays[@]}"; do
        if [[ -z "$array" ]]; then
            continue
        fi
        
        if is_system_array "$array" "$system_drive"; then
            system_arrays+=("$array")
        else
            arrays_to_remove+=("$array")
        fi
    done
    
    # Show what will be preserved
    if [[ ${#system_arrays[@]} -gt 0 ]]; then
        log "INFO" "System arrays (will be preserved):"
        for array in "${system_arrays[@]}"; do
            local members
            mapfile -t members < <(get_raid_members "$array")
            log "INFO" "  $array: ${members[*]}"
        done
    fi
    
    # Show what will be removed
    if [[ ${#arrays_to_remove[@]} -eq 0 ]]; then
        log "INFO" "No non-system RAID arrays found to remove"
        return 0
    fi
    
    log "INFO" "Non-system arrays (will be removed):"
    for array in "${arrays_to_remove[@]}"; do
        local members
        mapfile -t members < <(get_raid_members "$array")
        log "INFO" "  $array: ${members[*]}"
    done
    
    # Confirm removal unless force flag is set
    if [[ "$force" != "true" ]]; then
        echo
        read -p "⚠️  This will permanently remove ${#arrays_to_remove[@]} RAID array(s) and all data on them. Continue? (y/N): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "INFO" "Operation cancelled by user"
            return 0
        fi
    fi
    
    # Remove arrays
    local success_count=0
    for array in "${arrays_to_remove[@]}"; do
        if remove_raid_array "$array" "$force"; then
            ((success_count++))
        else
            log "ERROR" "Failed to remove array: $array"
        fi
    done
    
    log "INFO" "Successfully removed $success_count of ${#arrays_to_remove[@]} RAID arrays"
    
    if [[ $success_count -gt 0 ]]; then
        log "INFO" "Updating mdadm configuration..."
        mdadm --detail --scan > /etc/mdadm/mdadm.conf || log "WARNING" "Failed to update mdadm.conf"
        
        log "INFO" "Updating initramfs..."
        update-initramfs -u || log "WARNING" "Failed to update initramfs"
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

Remove all non-system RAID arrays, preserving system/root arrays.

OPTIONS:
    --force     Skip confirmation prompts and force unmount if needed
    --status    Show current RAID status and exit
    --help      Show this help message

EXAMPLES:
    $0 --status         # Show current RAID arrays
    $0                  # Remove non-system arrays (with confirmation)
    $0 --force          # Remove non-system arrays (no confirmation)

SAFETY:
    - System/root RAID arrays are automatically detected and preserved
    - Data RAID arrays are identified and safely removed
    - Prompts for confirmation unless --force is used
    - Updates mdadm configuration after removal

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
    
    log "INFO" "Starting RAID removal process..."
    
    # Show current status first
    show_raid_status
    echo
    
    # Remove non-system arrays
    remove_all_non_system_raids "$force"
    
    echo
    log "INFO" "✅ RAID removal completed"
    log "INFO" ""
    log "INFO" "Next steps:"
    log "INFO" "1. Run: ./install.sh --drives  # To reconfigure drives from clean state"
    log "INFO" "2. Verify: cat /proc/mdstat     # To check final RAID status"
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

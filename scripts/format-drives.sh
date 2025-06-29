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

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose)
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

# Main function
main() {
    log "INFO" "Starting drive formatting process..."
    
    # Get non-system drives
    local non_system_drives
    mapfile -t non_system_drives < <(get_non_system_drives)
    
    if [[ ${#non_system_drives[@]} -eq 0 ]]; then
        log "INFO" "No non-system drives found to format"
        return 0
    fi
    
    log "INFO" "Non-system drives to be formatted:"
    for drive in "${non_system_drives[@]}"; do
        local size model
        size=$(lsblk -ndo SIZE "$drive" 2>/dev/null || echo "Unknown")
        model=$(lsblk -ndo MODEL "$drive" 2>/dev/null || echo "Unknown")
        log "INFO" "  📀 $drive ($size) - $model"
    done
    
    if [[ "$DRY_RUN" == "false" ]]; then
        log "WARN" "⚠️  WARNING: This will permanently destroy all data on the above drives!"
        log "WARN" "⚠️  Are you sure you want to continue? (Type 'yes' to confirm)"
        read -r confirmation
        if [[ "$confirmation" != "yes" ]]; then
            log "INFO" "Operation cancelled by user"
            exit 0
        fi
    fi
    
    # Stop RAID arrays first
    stop_raid_arrays
    
    # Format each non-system drive
    for drive in "${non_system_drives[@]}"; do
        format_drive "$drive"
    done
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "INFO" "DRY RUN completed - no changes were made"
    else
        log "INFO" "✅ All non-system drives have been formatted successfully"
        log "INFO" "Drives are now ready for fresh RAID configuration"
    fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    parse_args "$@"
    main
fi

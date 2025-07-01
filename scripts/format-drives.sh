#!/bin/bash

# Hetzner Proxmox Drive Formatting Script (ZFS)
# This script helps format non-system drives safely with ZFS

set -euo pipefail

# Custom error handler
error_handler() {
    local line_no=$1
    local error_code=$2
    log "ERROR" "Script failed at line $line_no with exit code $error_code"
    log "ERROR" "This error occurred in the format-drives script"
    exit "$error_code"
}

# Set up error handling
trap 'error_handler ${LINENO} $?' ERR

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source common functions
# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/common.sh"

# Function to detect system drives
detect_system_drives() {
    local system_drives=()
    
    # Get root filesystem device
    local root_device
    root_device=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    if [[ -n "$root_device" ]]; then
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
                # Get physical volumes for this volume group
                while IFS= read -r pv_device; do
                    if [[ -n "$pv_device" ]]; then
                        # Get the parent disk
                        local parent_disk
                        parent_disk=$(lsblk -no PKNAME "$pv_device" 2>/dev/null || true)
                        if [[ -n "$parent_disk" ]]; then
                            system_drives+=("$parent_disk")
                        else
                            # Fallback: extract disk name from partition
                            parent_disk=$(basename "$pv_device")
                            # Handle both regular drives (sda1) and NVMe drives (nvme0n1p1)
                            if [[ "$parent_disk" =~ ^nvme[0-9]+n[0-9]+p[0-9]+$ ]]; then
                                parent_disk="${parent_disk%p[0-9]*}"
                            elif [[ "$parent_disk" =~ [0-9]$ ]]; then
                                parent_disk="${parent_disk%[0-9]*}"
                            fi
                            system_drives+=("$parent_disk")
                        fi
                    fi
                done < <(pvs --noheadings -o pv_name 2>/dev/null | grep -v "^\s*$" || true)
            fi
        else
            # Regular device
            # If it's a partition, get the parent disk
            # Handle both regular drives (sda1) and NVMe drives (nvme0n1p1)
            if [[ "$root_device" =~ ^nvme[0-9]+n[0-9]+p[0-9]+$ ]]; then
                root_device="${root_device%p[0-9]*}"
            elif [[ "$root_device" =~ [0-9]$ ]]; then
                root_device="${root_device%[0-9]*}"
            fi
            # Remove /dev/ prefix for consistency
            root_device=$(basename "$root_device")
            system_drives+=("$root_device")
        fi
    fi
    
    # Get boot filesystem device if different
    local boot_device
    boot_device=$(findmnt -n -o SOURCE /boot 2>/dev/null || true)
    if [[ -n "$boot_device" && "$boot_device" != "$(findmnt -n -o SOURCE / 2>/dev/null)" ]]; then
        # If it's a partition, get the parent disk
        # Handle both regular drives (sda1) and NVMe drives (nvme0n1p1)
        if [[ "$boot_device" =~ ^/dev/nvme[0-9]+n[0-9]+p[0-9]+$ ]]; then
            boot_device="${boot_device%p[0-9]*}"
        elif [[ "$boot_device" =~ [0-9]$ ]]; then
            boot_device="${boot_device%[0-9]*}"
        fi
        boot_device=$(basename "$boot_device")
        # Add if not already in the list
        local found=false
        for drive in "${system_drives[@]}"; do
            if [[ "$drive" == "$boot_device" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" == "false" ]]; then
            system_drives+=("$boot_device")
        fi
    fi
    
    # Check for any drives used in system RAID arrays
    if [[ -f /proc/mdstat ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^(md[0-9]+) ]]; then
                local md_device="${BASH_REMATCH[1]}"
                # Check if this RAID array is used for system paths
                local mount_points
                mount_points=$(findmnt -n -o TARGET -S "/dev/$md_device" 2>/dev/null || true)
                if [[ -n "$mount_points" ]]; then
                    while IFS= read -r mount_point; do
                        if [[ -n "$mount_point" ]]; then
                            case "$mount_point" in
                                "/" | "/boot" | "/var" | "/usr" | "/home" | "/opt" | "/tmp")
                                    # This is a system RAID array, get its member drives
                                    while IFS= read -r member_line; do
                                        if [[ "$member_line" =~ ^$md_device ]]; then
                                            while [[ "$member_line" =~ ([a-zA-Z0-9]+)\[[0-9]+\] ]]; do
                                                local member_device="${BASH_REMATCH[1]}"
                                                # Get parent disk
                                                # Handle both regular drives (sda1) and NVMe drives (nvme0n1p1)
                                                if [[ "$member_device" =~ ^nvme[0-9]+n[0-9]+p[0-9]+$ ]]; then
                                                    member_device="${member_device%p[0-9]*}"
                                                elif [[ "$member_device" =~ [0-9]$ ]]; then
                                                    member_device="${member_device%[0-9]*}"
                                                fi
                                                # Add if not already in the list
                                                local member_found=false
                                                for drive in "${system_drives[@]}"; do
                                                    if [[ "$drive" == "$member_device" ]]; then
                                                        member_found=true
                                                        break
                                                    fi
                                                done
                                                if [[ "$member_found" == "false" ]]; then
                                                    system_drives+=("$member_device")
                                                fi
                                                member_line="${member_line/${BASH_REMATCH[0]}/}"
                                            done
                                            break
                                        fi
                                    done < <(grep -E "^$md_device" /proc/mdstat 2>/dev/null || true)
                                    ;;
                            esac
                        fi
                    done <<< "$mount_points"
                fi
            fi
        done < <(grep -E '^md[0-9]+' /proc/mdstat 2>/dev/null || true)
    fi
    
    printf '%s\n' "${system_drives[@]}" | sort -u
}

# Function to get all available drives
get_all_drives() {
    local drives=()
    
    # Get all block devices that are disks (not partitions, not loop devices, etc.)
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            local device
            local type
            local size
            device=$(echo "$line" | awk '{print $1}')
            type=$(echo "$line" | awk '{print $2}')
            size=$(echo "$line" | awk '{print $3}')
            
            # Only include physical disks
            if [[ "$type" == "disk" && -n "$size" && "$size" != "0B" ]]; then
                drives+=("$device")
            fi
        fi
    done < <(lsblk -no NAME,TYPE,SIZE 2>/dev/null | grep -E '^\S+\s+disk\s+' || true)
    
    printf '%s\n' "${drives[@]}"
}

# Function to get drive information
get_drive_info() {
    local drive="$1"
    local size
    local model
    local serial
    
    size=$(lsblk -no SIZE "/dev/$drive" 2>/dev/null | head -1 || echo "Unknown")
    model=$(lsblk -no MODEL "/dev/$drive" 2>/dev/null | head -1 || echo "Unknown")
    
    # Try to get serial number
    if command -v smartctl >/dev/null 2>&1; then
        serial=$(smartctl -i "/dev/$drive" 2>/dev/null | grep -i "serial number" | awk '{print $NF}' || echo "Unknown")
    else
        serial="Unknown"
    fi
    
    echo "$size | $model | $serial"
}

# Function to show drive usage
show_drive_usage() {
    local drive="$1"
    
    echo "  Partitions and usage:"
    
    # Show partitions
    local partitions
    partitions=$(lsblk -no NAME,SIZE,FSTYPE,MOUNTPOINT "/dev/$drive" 2>/dev/null | tail -n +2 || true)
    
    if [[ -n "$partitions" ]]; then
        while IFS= read -r partition_line; do
            if [[ -n "$partition_line" ]]; then
                echo "    $partition_line"
            fi
        done <<< "$partitions"
    else
        echo "    No partitions found"
    fi
    
    # Check if used in ZFS pools
    if command -v zpool >/dev/null 2>&1; then
        local zfs_usage
        zfs_usage=$(zpool status 2>/dev/null | grep -B5 -A5 "/dev/$drive" | grep "pool:" | awk '{print $2}' || true)
        if [[ -n "$zfs_usage" ]]; then
            echo "  ZFS pool usage:"
            while IFS= read -r pool_line; do
                if [[ -n "$pool_line" ]]; then
                    echo "    Pool: $pool_line"
                fi
            done <<< "$zfs_usage"
        fi
    fi
    
    # Check if used in RAID
    if [[ -f /proc/mdstat ]]; then
        local raid_usage
        raid_usage=$(grep -E "${drive}[0-9]*\[" /proc/mdstat 2>/dev/null || true)
        if [[ -n "$raid_usage" ]]; then
            echo "  RAID usage:"
            while IFS= read -r raid_line; do
                if [[ -n "$raid_line" ]]; then
                    echo "    $raid_line"
                fi
            done <<< "$raid_usage"
        fi
    fi
}

# Function to format a drive for ZFS
format_drive() {
    local drive="$1"
    local pool_name="${2:-storage}"
    
    log "INFO" "Preparing drive /dev/$drive for ZFS pool '$pool_name'..."
    
    # Verify drive exists
    if [[ ! -b "/dev/$drive" ]]; then
        log "ERROR" "Drive /dev/$drive does not exist"
        return 1
    fi
    
    # Check if drive is already part of a ZFS pool
    if command -v zpool >/dev/null 2>&1; then
        local existing_pool
        existing_pool=$(zpool status 2>/dev/null | grep -B5 -A5 "/dev/$drive" | grep "pool:" | awk '{print $2}' || true)
        if [[ -n "$existing_pool" ]]; then
            log "ERROR" "Drive /dev/$drive is already part of ZFS pool: $existing_pool"
            log "ERROR" "Use './scripts/remove-mirrors.sh' to remove from existing pools first"
            return 1
        fi
    fi
    
    # Unmount any mounted partitions first
    local mounted_partitions
    mounted_partitions=$(findmnt -rn -o TARGET -S "/dev/$drive" 2>/dev/null || true)
    if [[ -n "$mounted_partitions" ]]; then
        log "INFO" "Unmounting partitions on /dev/$drive..."
        while IFS= read -r mount_point; do
            if [[ -n "$mount_point" ]]; then
                log "INFO" "Unmounting: $mount_point"
                if ! umount "$mount_point" 2>/dev/null; then
                    log "WARNING" "Failed to unmount $mount_point, trying force unmount"
                    umount -l "$mount_point" 2>/dev/null || log "WARNING" "Failed to force unmount $mount_point"
                fi
            fi
        done <<< "$mounted_partitions"
    fi
    
    # Check for and unmount any partitions of this drive
    log "INFO" "Checking for existing partitions to unmount..."
    # shellcheck disable=SC2231
    for partition in /dev/${drive}*; do
        if [[ -b "$partition" && "$partition" != "/dev/$drive" ]]; then
            local part_mount
            part_mount=$(findmnt -n -o TARGET "$partition" 2>/dev/null || true)
            if [[ -n "$part_mount" ]]; then
                log "INFO" "Unmounting partition: $partition from $part_mount"
                umount "$partition" 2>/dev/null || umount -l "$partition" 2>/dev/null || log "WARNING" "Failed to unmount $partition"
            fi
        fi
    done
    
    # Remove from any RAID arrays
    if [[ -f /proc/mdstat ]]; then
        local raid_usage
        raid_usage=$(grep -E "${drive}[0-9]*\[" /proc/mdstat 2>/dev/null || true)
        if [[ -n "$raid_usage" ]]; then
            log "ERROR" "Drive /dev/$drive appears to be part of RAID arrays:"
            echo "$raid_usage"
            log "ERROR" "Cannot format drive that is part of active RAID arrays"
            log "ERROR" "Please remove from RAID first using: ./scripts/remove-mirrors.sh"
            return 1
        fi
    fi
    
    # Wait a moment for unmounts to complete
    sleep 1
    
    # Clear any existing ZFS labels
    log "INFO" "Clearing existing ZFS labels..."
    if command -v zpool >/dev/null 2>&1; then
        zpool labelclear -f "/dev/$drive" 2>/dev/null || true
    fi
    
    # Wipe any existing filesystem signatures
    log "INFO" "Wiping existing filesystem signatures..."
    if ! wipefs -a "/dev/$drive" 2>/dev/null; then
        log "WARNING" "Failed to wipe signatures, continuing anyway"
    fi
    
    # Create new GPT partition table
    log "INFO" "Creating new GPT partition table..."
    if ! parted "/dev/$drive" --script mklabel gpt 2>/dev/null; then
        log "ERROR" "Failed to create partition table on /dev/$drive"
        return 1
    fi
    
    # Create partition using all available space for ZFS
    log "INFO" "Creating ZFS partition..."
    if ! parted "/dev/$drive" --script mkpart primary 0% 100% 2>/dev/null; then
        log "ERROR" "Failed to create partition on /dev/$drive"
        return 1
    fi
    
    # Set partition type to ZFS (Solaris root)
    log "INFO" "Setting partition type to ZFS..."
    if ! parted "/dev/$drive" --script set 1 type 6a945a3b-1dd2-11b2-99a6-080020736631 2>/dev/null; then
        log "WARNING" "Failed to set ZFS partition type, continuing anyway"
    fi
    
    # Wait for partition to be created and inform kernel
    sleep 2
    partprobe "/dev/$drive" 2>/dev/null || true
    sleep 1
    
    # Determine partition device name
    local partition_device
    if [[ "$drive" =~ nvme ]]; then
        partition_device="/dev/${drive}p1"
    else
        partition_device="/dev/${drive}1"
    fi
    
    # Wait for partition device to appear
    local retries=0
    while [[ ! -b "$partition_device" && $retries -lt 10 ]]; do
        log "INFO" "Waiting for partition device $partition_device to appear..."
        sleep 1
        retries=$((retries + 1))
    done
    
    if [[ ! -b "$partition_device" ]]; then
        log "ERROR" "Partition device $partition_device did not appear after partitioning"
        return 1
    fi
    
    log "INFO" "Successfully prepared /dev/$drive for ZFS"
    log "INFO" "Partition ready: $partition_device"
    
    # Show the result
    log "INFO" "New partition information:"
    local lsblk_output
    if lsblk_output=$(lsblk "/dev/$drive" 2>/dev/null); then
        echo "$lsblk_output"
    else
        log "WARNING" "Could not display partition info for /dev/$drive"
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

Prepare non-system drives for ZFS pools with user confirmation.

OPTIONS:
    --help      Show this help message

EXAMPLES:
    $0                  # Interactive ZFS drive preparation

SAFETY:
    - Automatically detects and protects system drives
    - Shows drive information before preparation
    - Requires explicit confirmation for each drive
    - Prepares drives for ZFS pool creation
    - Unmounts drives and removes RAID/ZFS associations

ZFS FEATURES:
    - Enterprise-grade filesystem with data integrity
    - Built-in compression and deduplication
    - Snapshots and cloning capabilities
    - RAID-Z redundancy options
    - Self-healing and error detection

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
    
    # Check for required tools
    local missing_tools=()
    local required_tools=("lsblk" "findmnt" "wipefs" "parted" "blkid")
    
    # Check for ZFS tools
    if ! command -v zpool >/dev/null 2>&1; then
        missing_tools+=("zfs-utils")
    fi
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log "ERROR" "Missing required tools: ${missing_tools[*]}"
        log "ERROR" "Please install the missing packages:"
        log "ERROR" "  apt update && apt install -y util-linux parted zfsutils-linux"
        exit 1
    fi
    
    log "INFO" "Starting ZFS drive preparation process..."
    log "INFO" "This script will help you safely prepare non-system drives for ZFS"
    echo
    
    # Detect system drives
    local system_drives
    mapfile -t system_drives < <(detect_system_drives)
    
    if [[ ${#system_drives[@]} -gt 0 ]]; then
        log "INFO" "Detected system drives (will be protected):"
        for drive in "${system_drives[@]}"; do
            local drive_info
            drive_info=$(get_drive_info "$drive")
            log "INFO" "  /dev/$drive - $drive_info"
        done
        echo
    fi
    
    # Get all drives
    local all_drives
    mapfile -t all_drives < <(get_all_drives)
    
    if [[ ${#all_drives[@]} -eq 0 ]]; then
        log "ERROR" "No drives found"
        exit 1
    fi
    
    # Filter out system drives
    local available_drives=()
    for drive in "${all_drives[@]}"; do
        local is_system=false
        for system_drive in "${system_drives[@]}"; do
            if [[ "$drive" == "$system_drive" ]]; then
                is_system=true
                break
            fi
        done
        if [[ "$is_system" == "false" ]]; then
            available_drives+=("$drive")
        fi
    done
    
    if [[ ${#available_drives[@]} -eq 0 ]]; then
        echo
        log "INFO" "ℹ️  No non-system drives available for ZFS preparation"
        log "INFO" ""
        log "INFO" "All detected drives are currently:"
        log "INFO" "  • System drives (used for OS/boot)"
        log "INFO" "  • Already mounted with active data"
        log "INFO" "  • Part of RAID arrays or ZFS pools"
        log "INFO" ""
        log "INFO" "If you need to prepare system drives or remove existing pools:"
        log "INFO" "  • Remove ZFS pools first: ./scripts/remove-mirrors.sh"
        log "INFO" "  • Use manual tools with extreme caution"
        log "INFO" ""
        log "INFO" "Current system drives:"
        for drive in "${system_drives[@]}"; do
            local drive_info
            drive_info=$(get_drive_info "$drive")
            log "INFO" "  • /dev/$drive - $drive_info"
        done
        exit 0
    fi
    
    log "INFO" "Available drives for ZFS preparation:"
    for i in "${!available_drives[@]}"; do
        local drive="${available_drives[$i]}"
        local drive_info
        drive_info=$(get_drive_info "$drive")
        echo
        log "INFO" "$((i+1)). /dev/$drive - $drive_info"
        show_drive_usage "$drive"
    done
    
    echo
    log "WARNING" "⚠️  PREPARING DRIVES WILL WIPE ALL DATA AND PREPARE FOR ZFS!"
    echo
    
    # Drive selection loop
    while true; do
        echo "Select drives to prepare for ZFS:"
        echo "  📝 Enter drive numbers separated by spaces (e.g., '1 3 4' for drives 1, 3, and 4)"
        echo "  📝 Enter 'all' to prepare all available drives"
        echo "  📝 Enter 'quit' or 'exit' to cancel without preparing"
        echo "  📝 Valid range: 1-${#available_drives[@]}"
        echo
        read -p "Your selection: " -r selection
        
        if [[ "$selection" == "quit" ]] || [[ "$selection" == "exit" ]] || [[ "$selection" == "q" ]]; then
            log "INFO" "Exiting without preparing any drives for ZFS"
            exit 0
        fi
        
        local drives_to_format=()
        
        if [[ "$selection" == "all" ]]; then
            drives_to_format=("${available_drives[@]}")
        else
            # Parse individual drive numbers
            local invalid_selections=()
            local valid_count=0
            
            for num in $selection; do
                if [[ "$num" =~ ^[0-9]+$ ]] && [[ $num -ge 1 ]] && [[ $num -le ${#available_drives[@]} ]]; then
                    # Check for duplicates
                    local duplicate=false
                    for existing_drive in "${drives_to_format[@]}"; do
                        if [[ "$existing_drive" == "${available_drives[$((num-1))]}" ]]; then
                            duplicate=true
                            break
                        fi
                    done
                    
                    if [[ "$duplicate" == "false" ]]; then
                        drives_to_format+=("${available_drives[$((num-1))]}")
                        valid_count=$((valid_count + 1))
                    else
                        log "WARNING" "Drive $num already selected (ignoring duplicate)"
                    fi
                else
                    invalid_selections+=("$num")
                fi
            done
            
            # Report any invalid selections but continue if we have valid ones
            if [[ ${#invalid_selections[@]} -gt 0 ]]; then
                log "WARNING" "Invalid selections: ${invalid_selections[*]} (valid range: 1-${#available_drives[@]})"
            fi
            
            # If we have some valid selections, continue; otherwise, go back to selection
            if [[ $valid_count -eq 0 ]]; then
                log "ERROR" "No valid drives selected"
                continue
            elif [[ ${#invalid_selections[@]} -gt 0 ]]; then
                log "INFO" "Proceeding with $valid_count valid drive selection(s)"
            fi
        fi
        
        # Show selected drives
        echo
        log "INFO" "Selected drives for ZFS preparation:"
        for drive in "${drives_to_format[@]}"; do
            local drive_info
            drive_info=$(get_drive_info "$drive")
            log "INFO" "  /dev/$drive - $drive_info"
        done
        
        echo
        log "WARNING" "⚠️  This will PERMANENTLY DELETE ALL DATA on ${#drives_to_format[@]} drive(s)!"
        echo
        log "WARNING" "📋 Drives to be prepared for ZFS:"
        for drive in "${drives_to_format[@]}"; do
            local drive_info
            drive_info=$(get_drive_info "$drive")
            log "WARNING" "     • /dev/$drive - $drive_info"
        done
        echo
        log "WARNING" "❗ This action cannot be undone!"
        echo
        read -p "⚠️  Type 'yes' to proceed with preparing these ${#drives_to_format[@]} drive(s) for ZFS: " -r confirm_format
        if [[ "$confirm_format" != "yes" ]]; then
            log "INFO" "Operation cancelled (you must type exactly 'yes' to proceed)"
            continue
        fi
        
        # Pool name selection
        echo
        local pool_name="storage"
        while true; do
            read -p "Enter ZFS pool name (default: storage): " -r pool_input
            if [[ -z "$pool_input" ]]; then
                pool_name="storage"
                break
            elif [[ "$pool_input" =~ ^[a-zA-Z0-9_-]+$ ]] && [[ ${#pool_input} -le 32 ]]; then
                # Check if pool already exists
                if command -v zpool >/dev/null 2>&1 && zpool list "$pool_input" >/dev/null 2>&1; then
                    log "ERROR" "ZFS pool '$pool_input' already exists. Choose a different name."
                    continue
                fi
                pool_name="$pool_input"
                break
            else
                log "ERROR" "Invalid pool name. Use only letters, numbers, hyphens, and underscores (max 32 chars)."
            fi
        done
        
        log "INFO" "Using ZFS pool name: $pool_name"
        
        # Prepare drives
        echo
        log "INFO" "🚀 Starting ZFS drive preparation for ${#drives_to_format[@]} drive(s)..."
        log "INFO" "Pool name: $pool_name"
        echo
        
        local success_count=0
        local failed_drives=()
        local drive_counter=1
        
        # Temporarily disable exit on error to handle drive formatting failures gracefully
        set +e
        
        for drive in "${drives_to_format[@]}"; do
            echo
            log "INFO" "📀 [$drive_counter/${#drives_to_format[@]}] Preparing /dev/$drive for ZFS..."
            log "DEBUG" "About to prepare drive: $drive"
            
            # Format the drive
            if format_drive "$drive" "$pool_name"; then
                success_count=$((success_count + 1))
                log "INFO" "✅ [$drive_counter/${#drives_to_format[@]}] Successfully prepared /dev/$drive for ZFS"
                log "DEBUG" "Drive $drive preparation completed successfully"
            else
                failed_drives+=("$drive")
                log "ERROR" "❌ [$drive_counter/${#drives_to_format[@]}] Failed to prepare /dev/$drive for ZFS"
                log "DEBUG" "Drive $drive preparation failed"
            fi
            
            drive_counter=$((drive_counter + 1))
            log "DEBUG" "Moving to next drive, counter now: $drive_counter"
        done
        
        # Re-enable exit on error
        set -e
        
        log "DEBUG" "All drives processed, success_count: $success_count, failed: ${#failed_drives[@]}"
        
        echo
        log "INFO" "Drive preparation completed!"
        log "INFO" "Successfully prepared: $success_count of ${#drives_to_format[@]} drives"
        
        if [[ ${#failed_drives[@]} -gt 0 ]]; then
            log "WARNING" "Failed to prepare the following drives:"
            for failed_drive in "${failed_drives[@]}"; do
                log "WARNING" "  - /dev/$failed_drive"
            done
            echo
            log "INFO" "Common reasons for preparation failures:"
            log "INFO" "  - Drive is part of an active ZFS pool (use remove-mirrors.sh first)"
            log "INFO" "  - Drive is part of an active RAID array (use remove-mirrors.sh first)"
            log "INFO" "  - Drive is mounted and cannot be unmounted"
            log "INFO" "  - Drive has hardware issues"
            log "INFO" "  - Insufficient permissions"
        fi
        
        echo
        log "INFO" "📊 Final drive status:"
        for drive in "${drives_to_format[@]}"; do
            echo
            log "INFO" "Drive /dev/$drive:"
            # Use more robust error handling for status display
            local lsblk_output
            if lsblk_output=$(lsblk "/dev/$drive" -o NAME,SIZE,FSTYPE,LABEL 2>/dev/null); then
                echo "$lsblk_output"
            else
                log "WARNING" "Could not display detailed status for /dev/$drive"
                # Try basic info as fallback
                if [[ -b "/dev/$drive" ]]; then
                    log "INFO" "  Drive exists but status unavailable"
                else
                    log "WARNING" "  Drive no longer exists"
                fi
            fi
        done
        
        # Show summary of successful operations
        if [[ $success_count -gt 0 ]]; then
            echo
            log "INFO" "📈 Summary of successfully prepared drives:"
            for drive in "${drives_to_format[@]}"; do
                # Check if this drive was successfully prepared
                local was_successful=true
                for failed_drive in "${failed_drives[@]}"; do
                    if [[ "$drive" == "$failed_drive" ]]; then
                        was_successful=false
                        break
                    fi
                done
                
                if $was_successful; then
                    local drive_info
                    drive_info=$(get_drive_info "$drive" 2>/dev/null || echo "info unavailable")
                    log "INFO" "  ✅ /dev/$drive - Ready for ZFS"
                    log "INFO" "     Pool name: $pool_name"
                fi
            done
        fi
        
        break
    done
    
    echo
    log "INFO" "✅ ZFS drive preparation completed!"
    log "INFO" ""
    log "INFO" "Next steps:"
    log "INFO" "1. Create ZFS pools/mirrors: ./scripts/setup-mirrors.sh"
    log "INFO" "2. Configure network: ./install.sh --network"
    log "INFO" "3. Install Caddy: ./install.sh --caddy"
    
    # Explicitly exit with success code
    exit 0
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

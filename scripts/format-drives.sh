#!/bin/bash

# Hetzner Proxmox Drive Formatting Script
# This script helps format non-system drives safely with user confirmation

set -euo pipefail

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
        # If it's a partition, get the parent disk
        if [[ "$root_device" =~ [0-9]$ ]]; then
            root_device="${root_device%[0-9]*}"
        fi
        # Remove /dev/ prefix for consistency
        root_device=$(basename "$root_device")
        system_drives+=("$root_device")
    fi
    
    # Get boot filesystem device if different
    local boot_device
    boot_device=$(findmnt -n -o SOURCE /boot 2>/dev/null || true)
    if [[ -n "$boot_device" && "$boot_device" != "$root_device" ]]; then
        if [[ "$boot_device" =~ [0-9]$ ]]; then
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
                                                if [[ "$member_device" =~ [0-9]$ ]]; then
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

# Function to format a drive
format_drive() {
    local drive="$1"
    local filesystem="${2:-ext4}"
    local label="$3"
    
    log "INFO" "Formatting drive /dev/$drive with $filesystem filesystem..."
    
    # Unmount any mounted partitions first
    local mounted_partitions
    mounted_partitions=$(findmnt -rn -o TARGET -S "/dev/$drive" 2>/dev/null || true)
    if [[ -n "$mounted_partitions" ]]; then
        log "INFO" "Unmounting partitions on /dev/$drive..."
        while IFS= read -r mount_point; do
            if [[ -n "$mount_point" ]]; then
                log "INFO" "Unmounting: $mount_point"
                umount "$mount_point" || log "WARNING" "Failed to unmount $mount_point"
            fi
        done <<< "$mounted_partitions"
    fi
    
    # Remove from any RAID arrays
    local raid_devices
    raid_devices=$(grep -l "${drive}" /proc/mdstat 2>/dev/null || true)
    if [[ -n "$raid_devices" ]]; then
        log "WARNING" "Drive /dev/$drive appears to be part of RAID arrays"
        log "WARNING" "Please remove from RAID first using: ./install.sh --remove-mirrors"
        return 1
    fi
    
    # Wipe any existing filesystem signatures
    log "INFO" "Wiping existing filesystem signatures..."
    wipefs -a "/dev/$drive" 2>/dev/null || log "WARNING" "Failed to wipe signatures"
    
    # Create new partition table
    log "INFO" "Creating new GPT partition table..."
    parted "/dev/$drive" --script mklabel gpt || {
        log "ERROR" "Failed to create partition table"
        return 1
    }
    
    # Create partition using all available space
    log "INFO" "Creating partition..."
    parted "/dev/$drive" --script mkpart primary 0% 100% || {
        log "ERROR" "Failed to create partition"
        return 1
    }
    
    # Wait for partition to be created
    sleep 2
    
    # Determine partition device name
    local partition_device
    if [[ "$drive" =~ nvme ]]; then
        partition_device="/dev/${drive}p1"
    else
        partition_device="/dev/${drive}1"
    fi
    
    # Format the partition
    log "INFO" "Creating $filesystem filesystem..."
    case "$filesystem" in
        ext4)
            if [[ -n "$label" ]]; then
                mkfs.ext4 -F -L "$label" "$partition_device" || {
                    log "ERROR" "Failed to format with ext4"
                    return 1
                }
            else
                mkfs.ext4 -F "$partition_device" || {
                    log "ERROR" "Failed to format with ext4"
                    return 1
                }
            fi
            ;;
        xfs)
            if [[ -n "$label" ]]; then
                mkfs.xfs -f -L "$label" "$partition_device" || {
                    log "ERROR" "Failed to format with xfs"
                    return 1
                }
            else
                mkfs.xfs -f "$partition_device" || {
                    log "ERROR" "Failed to format with xfs"
                    return 1
                }
            fi
            ;;
        btrfs)
            if [[ -n "$label" ]]; then
                mkfs.btrfs -f -L "$label" "$partition_device" || {
                    log "ERROR" "Failed to format with btrfs"
                    return 1
                }
            else
                mkfs.btrfs -f "$partition_device" || {
                    log "ERROR" "Failed to format with btrfs"
                    return 1
                }
            fi
            ;;
        *)
            log "ERROR" "Unsupported filesystem: $filesystem"
            return 1
            ;;
    esac
    
    log "INFO" "Successfully formatted /dev/$drive as $filesystem"
    
    # Show the result
    log "INFO" "New partition information:"
    lsblk "/dev/$drive" 2>/dev/null || log "WARNING" "Could not display partition info"
    
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

Format non-system drives safely with user confirmation.

OPTIONS:
    --help      Show this help message

EXAMPLES:
    $0                  # Interactive drive formatting

SAFETY:
    - Automatically detects and protects system drives
    - Shows drive information before formatting
    - Requires explicit confirmation for each drive
    - Supports multiple filesystem types (ext4, xfs, btrfs)
    - Unmounts drives and removes RAID associations

FILESYSTEM SUPPORT:
    - ext4 (default, recommended for most use cases)
    - xfs (good for large files and high performance)
    - btrfs (advanced features, snapshots, compression)

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
    
    log "INFO" "Starting drive formatting process..."
    log "INFO" "This script will help you safely format non-system drives"
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
        log "INFO" "No non-system drives available for formatting"
        exit 0
    fi
    
    log "INFO" "Available drives for formatting:"
    for i in "${!available_drives[@]}"; do
        local drive="${available_drives[$i]}"
        local drive_info
        drive_info=$(get_drive_info "$drive")
        echo
        log "INFO" "$((i+1)). /dev/$drive - $drive_info"
        show_drive_usage "$drive"
    done
    
    echo
    log "WARNING" "⚠️  FORMATTING WILL PERMANENTLY DELETE ALL DATA ON SELECTED DRIVES!"
    echo
    
    # Drive selection loop
    while true; do
        echo "Select drives to format:"
        echo "  Enter drive numbers separated by spaces (e.g., 1 3 4)"
        echo "  Enter 'all' to format all available drives"
        echo "  Enter 'quit' to exit without formatting"
        echo
        read -p "Selection: " -r selection
        
        if [[ "$selection" == "quit" ]]; then
            log "INFO" "Exiting without formatting any drives"
            exit 0
        fi
        
        local drives_to_format=()
        
        if [[ "$selection" == "all" ]]; then
            drives_to_format=("${available_drives[@]}")
        else
            # Parse individual drive numbers
            for num in $selection; do
                if [[ "$num" =~ ^[0-9]+$ ]] && [[ $num -ge 1 ]] && [[ $num -le ${#available_drives[@]} ]]; then
                    drives_to_format+=("${available_drives[$((num-1))]}")
                else
                    log "ERROR" "Invalid selection: $num"
                    continue 2
                fi
            done
        fi
        
        if [[ ${#drives_to_format[@]} -eq 0 ]]; then
            log "ERROR" "No valid drives selected"
            continue
        fi
        
        # Show selected drives
        echo
        log "INFO" "Selected drives for formatting:"
        for drive in "${drives_to_format[@]}"; do
            local drive_info
            drive_info=$(get_drive_info "$drive")
            log "INFO" "  /dev/$drive - $drive_info"
        done
        
        echo
        log "WARNING" "⚠️  This will PERMANENTLY DELETE ALL DATA on ${#drives_to_format[@]} drive(s)!"
        read -p "⚠️  Are you absolutely sure you want to continue? (y/N): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "INFO" "Operation cancelled"
            continue
        fi
        
        # Filesystem selection
        echo
        echo "Select filesystem type:"
        echo "  1. ext4 (recommended for most use cases)"
        echo "  2. xfs (good for large files and high performance)"
        echo "  3. btrfs (advanced features, snapshots, compression)"
        echo
        read -p "Filesystem choice (1-3, default: 1): " -r fs_choice
        
        local filesystem="ext4"
        case "$fs_choice" in
            2) filesystem="xfs" ;;
            3) filesystem="btrfs" ;;
            *) filesystem="ext4" ;;
        esac
        
        # Optional label
        echo
        read -p "Enter optional label for drives (leave empty for no label): " -r label
        
        # Format drives
        echo
        log "INFO" "Starting formatting process..."
        local success_count=0
        local failed_drives=()
        
        for drive in "${drives_to_format[@]}"; do
            echo
            log "INFO" "Formatting /dev/$drive..."
            if format_drive "$drive" "$filesystem" "$label"; then
                ((success_count++))
                log "INFO" "✅ Successfully formatted /dev/$drive"
            else
                failed_drives+=("$drive")
                log "ERROR" "❌ Failed to format /dev/$drive"
            fi
        done
        
        echo
        log "INFO" "Formatting completed!"
        log "INFO" "Successfully formatted: $success_count of ${#drives_to_format[@]} drives"
        
        if [[ ${#failed_drives[@]} -gt 0 ]]; then
            log "WARNING" "Failed to format: ${failed_drives[*]}"
        fi
        
        echo
        log "INFO" "Final drive status:"
        for drive in "${drives_to_format[@]}"; do
            echo
            log "INFO" "/dev/$drive:"
            lsblk "/dev/$drive" 2>/dev/null || log "WARNING" "Could not display status for /dev/$drive"
        done
        
        break
    done
    
    echo
    log "INFO" "✅ Drive formatting process completed!"
    log "INFO" ""
    log "INFO" "Next steps:"
    log "INFO" "1. Create RAID mirrors: ./install.sh --setup-mirrors"
    log "INFO" "2. Configure network: ./install.sh --network"
    log "INFO" "3. Install Caddy: ./install.sh --caddy"
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

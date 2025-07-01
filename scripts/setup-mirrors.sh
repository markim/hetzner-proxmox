#!/bin/bash

# Hetzner Proxmox ZFS Storage Setup Script (Streamlined)
# This script configures ZFS mirrors and sets up storage for Proxmox
# Focuses on ZFS-only setup, removing legacy RAID complexity

set -euo pipefail

# Error handler
error_handler() {
    local line_no=$1 error_code=$2
    log "ERROR" "Script failed at line $line_no with exit code $error_code"
    log "ERROR" "Last command: ${BASH_COMMAND}"
    log "ERROR" "This error occurred in the setup-mirrors script"
    
    # Show context around the failing line
    if [[ -f "${BASH_SOURCE[0]}" ]]; then
        log "DEBUG" "Context around line $line_no:"
        sed -n "$((line_no-2)),$((line_no+2))p" "${BASH_SOURCE[0]}" | nl -v$((line_no-2)) 2>/dev/null || true
    fi
    exit "$error_code"
}
trap 'error_handler ${LINENO} $?' ERR

# Get script directory and source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/common.sh"

# Global variables
declare -a AVAILABLE_DRIVES=()
declare -a DRIVE_SIZES=()
declare -a MIRROR_GROUPS=()

# Enhanced drive detection with better filtering
detect_drives() {
    log "INFO" "Detecting available drives..."
    
    local drives
    drives=$(lsblk -dpno NAME,SIZE,TYPE | awk '$3=="disk" && $1!~/loop/ {print $1,$2}')
    
    [[ -z "$drives" ]] && { log "ERROR" "No drives detected"; exit 1; }
    
    log "INFO" "Analyzing drives for mirroring eligibility:"
    
    # First pass - categorize all drives
    local available_drives=()
    local available_sizes=()
    local zfs_drives=()
    local zfs_sizes=()
    local system_drives=()
    local mounted_drives=()
    
    while read -r drive_name size; do
        # Check for system usage
        if lsblk "$drive_name" -no MOUNTPOINT | grep -qE "^(/|/boot|/var|/usr|/home)"; then
            log "INFO" "  $drive_name ($size) - SYSTEM_DRIVE (skipping)"
            system_drives+=("$drive_name ($size)")
        # Check for existing ZFS pool membership
        elif is_drive_in_zfs_pool "$drive_name"; then
            log "INFO" "  $drive_name ($size) - IN_ZFS_POOL"
            zfs_drives+=("$drive_name")
            zfs_sizes+=("$size")
        # Check for mounted partitions
        elif lsblk "$drive_name" -no MOUNTPOINT | grep -q "^/"; then
            log "INFO" "  $drive_name ($size) - HAS_MOUNTED_PARTITIONS (skipping)"
            mounted_drives+=("$drive_name ($size)")
        else
            log "INFO" "  $drive_name ($size) - AVAILABLE"
            available_drives+=("$drive_name")
            available_sizes+=("$size")
        fi
    done <<< "$drives"
    
    # Show summary and ask user what to do
    echo
    log "INFO" "=== DRIVE SUMMARY ==="
    log "INFO" "Available drives (not in use): ${#available_drives[@]}"
    for i in "${!available_drives[@]}"; do
        log "INFO" "  ${available_drives[i]} (${available_sizes[i]})"
    done
    
    if [[ ${#zfs_drives[@]} -gt 0 ]]; then
        log "INFO" "Drives already in ZFS pools: ${#zfs_drives[@]}"
        for i in "${!zfs_drives[@]}"; do
            log "INFO" "  ${zfs_drives[i]} (${zfs_sizes[i]})"
        done
    fi
    
    if [[ ${#system_drives[@]} -gt 0 ]]; then
        log "INFO" "System drives (will be skipped): ${#system_drives[@]}"
        for drive in "${system_drives[@]}"; do
            log "INFO" "  $drive"
        done
    fi
    
    if [[ ${#mounted_drives[@]} -gt 0 ]]; then
        log "INFO" "Drives with mounted partitions (will be skipped): ${#mounted_drives[@]}"
        for drive in "${mounted_drives[@]}"; do
            log "INFO" "  $drive"
        done
    fi
    
    echo
    
    # Decide what to work with
    if [[ ${#available_drives[@]} -eq 0 && ${#zfs_drives[@]} -eq 0 ]]; then
        log "ERROR" "No drives available for ZFS mirror creation"
        log "INFO" "All drives are either system drives or have mounted partitions"
        exit 1
    elif [[ ${#available_drives[@]} -eq 0 ]]; then
        log "INFO" "No unused drives found. Only drives already in ZFS pools are available."
        echo
        read -p "Do you want to work with drives already in ZFS pools? (y/N): " -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            AVAILABLE_DRIVES=("${zfs_drives[@]}")
            DRIVE_SIZES=("${zfs_sizes[@]}")
            export FORCE_ZFS_DRIVES="true"
        else
            log "INFO" "No drives selected for configuration"
            exit 0
        fi
    elif [[ ${#zfs_drives[@]} -gt 0 ]]; then
        log "INFO" "You can work with:"
        log "INFO" "  1) Only unused drives (${#available_drives[@]} drives)"
        log "INFO" "  2) Both unused drives AND drives already in ZFS pools (${#available_drives[@]} + ${#zfs_drives[@]} drives)"
        echo
        read -p "Choose option (1-2): " -r choice
        case $choice in
            1)
                AVAILABLE_DRIVES=("${available_drives[@]}")
                DRIVE_SIZES=("${available_sizes[@]}")
                ;;
            2)
                AVAILABLE_DRIVES=("${available_drives[@]}" "${zfs_drives[@]}")
                DRIVE_SIZES=("${available_sizes[@]}" "${zfs_sizes[@]}")
                export FORCE_ZFS_DRIVES="true"
                ;;
            *)
                log "INFO" "Invalid choice. Using only unused drives."
                AVAILABLE_DRIVES=("${available_drives[@]}")
                DRIVE_SIZES=("${available_sizes[@]}")
                ;;
        esac
    else
        # Only available drives, use them
        AVAILABLE_DRIVES=("${available_drives[@]}")
        DRIVE_SIZES=("${available_sizes[@]}")
    fi
    
    [[ ${#AVAILABLE_DRIVES[@]} -eq 0 ]] && {
        log "ERROR" "No drives selected for configuration"
        exit 1
    }
    
    log "INFO" "Selected ${#AVAILABLE_DRIVES[@]} drives for configuration"
}

# Optimized drive grouping
group_drives_by_size() {
    log "INFO" "Grouping drives by size for optimal mirroring..."
    
    if [[ ${#AVAILABLE_DRIVES[@]} -eq 0 ]]; then
        log "ERROR" "No available drives to group"
        return 1
    fi
    
    log "DEBUG" "Available drives: ${AVAILABLE_DRIVES[*]}"
    log "DEBUG" "Drive sizes: ${DRIVE_SIZES[*]}"
    
    declare -A size_groups
    
    # Group drives by size
    for i in "${!AVAILABLE_DRIVES[@]}"; do
        local size="${DRIVE_SIZES[i]}"
        size_groups["$size"]+="${AVAILABLE_DRIVES[i]} "
        log "DEBUG" "Added ${AVAILABLE_DRIVES[i]} to size group $size"
    done
    
    # Clear mirror groups before populating
    MIRROR_GROUPS=()
    
    # Create mirror groups
    for size in "${!size_groups[@]}"; do
        read -ra drives <<< "${size_groups[$size]}"
        local count=${#drives[@]}
        
        log "INFO" "Size $size: $count drives (${drives[*]})"
        
        if [[ $count -ge 2 ]]; then
            # Create pairs for mirroring
            local pairs=$((count / 2))
            log "INFO" "  -> Creating $pairs ZFS mirror(s)"
            
            for ((j=0; j<pairs*2; j+=2)); do
                local mirror_pair="${drives[j]} ${drives[j+1]}"
                MIRROR_GROUPS+=("$mirror_pair")
                log "DEBUG" "Created mirror group: $mirror_pair"
            done
            
            # Handle remaining single drive
            if [[ $((count % 2)) -eq 1 ]]; then
                log "INFO" "  -> 1 single drive pool: ${drives[-1]}"
                MIRROR_GROUPS+=("${drives[-1]}")
                log "DEBUG" "Created single drive group: ${drives[-1]}"
            fi
        else
            log "INFO" "  -> Single drive pool"
            MIRROR_GROUPS+=("${drives[0]}")
            log "DEBUG" "Created single drive group: ${drives[0]}"
        fi
    done
    
    log "DEBUG" "Final mirror groups: ${MIRROR_GROUPS[*]}"
    return 0
}

# Check current storage status
check_current_storage() {
    log "INFO" "Current storage status:"
    
    # ZFS pools
    if command -v zpool >/dev/null 2>&1; then
        local pools
        pools=$(zpool list -H 2>/dev/null || true)
        if [[ -n "$pools" ]]; then
            log "INFO" "Existing ZFS pools:"
            zpool list 2>/dev/null || true
        else
            log "INFO" "No existing ZFS pools"
        fi
    else
        log "INFO" "ZFS not installed"
    fi
}

# Install ZFS if needed
install_zfs() {
    if command -v zpool >/dev/null && command -v zfs >/dev/null; then
        log "INFO" "ZFS already available"
        return 0
    fi
    
    log "INFO" "Installing ZFS..."
    apt update && apt install -y zfsutils-linux
    modprobe zfs || { log "ERROR" "Failed to load ZFS module"; return 1; }
    log "INFO" "ZFS installed successfully"
}

# Create ZFS pools efficiently
create_zfs_pools() {
    log "INFO" "Creating ZFS pools..."
    
    # Check if we have any mirror groups
    if [[ ${#MIRROR_GROUPS[@]} -eq 0 ]]; then
        log "ERROR" "No mirror groups defined. This should not happen."
        return 1
    fi
    
    log "DEBUG" "Processing ${#MIRROR_GROUPS[@]} mirror groups: ${MIRROR_GROUPS[*]}"
    
    install_zfs || { log "ERROR" "Failed to install/setup ZFS"; return 1; }
    
    local pool_index=0 success_count=0
    declare -a failed_groups=()
    
    for mirror_group in "${MIRROR_GROUPS[@]}"; do
        log "DEBUG" "Processing mirror group: '$mirror_group'"
        read -ra drives <<< "$mirror_group"
        log "DEBUG" "Drives in group: ${drives[*]} (count: ${#drives[@]})"
        
        # Generate unique pool name
        local pool_name
        while true; do
            pool_name="zpool$pool_index"
            if ! zpool list -H "$pool_name" 2>/dev/null | grep -q "^$pool_name"; then
                break
            fi
            ((pool_index++))
        done
        
        log "DEBUG" "Using pool name: $pool_name"
        
        if [[ ${#drives[@]} -eq 2 ]]; then
            log "INFO" "Creating ZFS mirror: ${drives[0]} + ${drives[1]} -> $pool_name"
            
            # Handle system drives carefully
            if is_system_drive "${drives[0]}" || is_system_drive "${drives[1]}"; then
                if ! confirm_system_mirror "${drives[@]}"; then
                    log "INFO" "Skipping system drive mirror"
                    failed_groups+=("$mirror_group")
                    ((pool_index++))
                    continue
                fi
            fi
            
            if create_zfs_mirror "$pool_name" "${drives[0]}" "${drives[1]}"; then
                if add_to_proxmox_storage "$pool_name" "zfs-mirror-$pool_index"; then
                    ((success_count++))
                    log "INFO" "Successfully created and added mirror: $pool_name"
                else
                    log "WARN" "Mirror created but failed to add to Proxmox storage"
                    ((success_count++))  # Still count as success since pool was created
                fi
            else
                log "ERROR" "Failed to create ZFS mirror: $pool_name"
                failed_groups+=("$mirror_group")
            fi
            
        elif [[ ${#drives[@]} -eq 1 ]]; then
            # Single drive
            local drive="${drives[0]}"
            log "INFO" "Creating single ZFS pool: $drive -> $pool_name"
            
            if is_system_drive "$drive"; then
                log "INFO" "Skipping single system drive: $drive"
                failed_groups+=("$mirror_group")
                ((pool_index++))
                continue
            fi
            
            if create_zfs_single "$pool_name" "$drive"; then
                if add_to_proxmox_storage "$pool_name" "zfs-single-$pool_index"; then
                    ((success_count++))
                    log "INFO" "Successfully created and added single pool: $pool_name"
                else
                    log "WARN" "Pool created but failed to add to Proxmox storage"
                    ((success_count++))  # Still count as success since pool was created
                fi
            else
                log "ERROR" "Failed to create ZFS pool: $pool_name"
                failed_groups+=("$mirror_group")
            fi
        else
            log "ERROR" "Invalid drive count in mirror group: ${#drives[@]} drives"
            failed_groups+=("$mirror_group")
        fi
        
        ((pool_index++))
    done
    
    # Report results
    log "INFO" "ZFS creation completed: $success_count successful, ${#failed_groups[@]} failed"
    if [[ ${#failed_groups[@]} -gt 0 ]]; then
        log "WARN" "Failed groups: ${failed_groups[*]}"
        log "WARN" "Some storage pools could not be created"
    fi
    
    if [[ $success_count -eq 0 ]]; then
        log "ERROR" "No storage pools were created successfully"
        return 1
    fi
    
    log "INFO" "Successfully created $success_count storage pool(s)"
    return 0
}

# Create ZFS mirror with optimal settings
create_zfs_mirror() {
    local pool_name="$1" drive1="$2" drive2="$3"
    
    log "INFO" "Preparing drives for ZFS mirror..."
    
    # Check if drives are already in ZFS pools
    for drive in "$drive1" "$drive2"; do
        if is_drive_in_zfs_pool "$drive" && [[ "${FORCE_ZFS_DRIVES:-false}" != "true" ]]; then
            log "ERROR" "Drive $drive is already in a ZFS pool"
            return 1
        fi
        
        # Wipe drives if they have existing filesystems (with confirmation for important data)
        local fstype
        fstype=$(lsblk "$drive" -no FSTYPE 2>/dev/null || true)
        if [[ -n "$fstype" ]]; then
            log "WARN" "Drive $drive has filesystem: $fstype"
            if [[ "$fstype" =~ ^(ext[234]|xfs|btrfs|ntfs)$ ]]; then
                log "WARN" "This appears to contain data. Continuing will destroy it."
                read -p "Wipe $drive? (y/N): " -r confirm
                [[ "$confirm" =~ ^[Yy]$ ]] || { log "INFO" "Skipping $drive"; return 1; }
            fi
            log "INFO" "Wiping filesystem on $drive..."
            wipefs -a "$drive" || { log "ERROR" "Failed to wipe $drive"; return 1; }
        fi
    done
    
    log "INFO" "Creating ZFS mirror pool: $pool_name"
    
    # Create ZFS mirror with Proxmox-optimized settings
    if ! zpool create -f \
        -o ashift=12 \
        -O compression=lz4 \
        -O atime=off \
        -O relatime=on \
        -O xattr=sa \
        -O dnodesize=auto \
        -O normalization=formD \
        -O mountpoint=none \
        -O canmount=off \
        "$pool_name" mirror "$drive1" "$drive2"; then
        log "ERROR" "Failed to create ZFS mirror $pool_name"
        return 1
    fi
    
    # Create VM storage dataset
    if ! zfs create -o mountpoint="/mnt/pve/$pool_name" -o canmount=on "$pool_name/vmdata"; then
        log "WARN" "Failed to create VM dataset, but pool creation succeeded"
    fi
    
    log "INFO" "Successfully created ZFS mirror: $pool_name"
    return 0
}

# Create single ZFS pool
create_zfs_single() {
    local pool_name="$1" drive="$2"
    
    log "INFO" "Preparing drive for ZFS pool..."
    
    # Check if drive is already in ZFS pool
    if is_drive_in_zfs_pool "$drive" && [[ "${FORCE_ZFS_DRIVES:-false}" != "true" ]]; then
        log "ERROR" "Drive $drive is already in a ZFS pool"
        return 1
    fi
    
    # Wipe drive if it has existing filesystem
    local fstype
    fstype=$(lsblk "$drive" -no FSTYPE 2>/dev/null || true)
    if [[ -n "$fstype" ]]; then
        log "WARN" "Drive $drive has filesystem: $fstype"
        if [[ "$fstype" =~ ^(ext[234]|xfs|btrfs|ntfs)$ ]]; then
            log "WARN" "This appears to contain data. Continuing will destroy it."
            read -p "Wipe $drive? (y/N): " -r confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || { log "INFO" "Skipping $drive"; return 1; }
        fi
        log "INFO" "Wiping filesystem on $drive..."
        wipefs -a "$drive" || { log "ERROR" "Failed to wipe $drive"; return 1; }
    fi
    
    log "INFO" "Creating ZFS pool: $pool_name"
    
    if ! zpool create -f \
        -o ashift=12 \
        -O compression=lz4 \
        -O atime=off \
        -O relatime=on \
        -O xattr=sa \
        -O dnodesize=auto \
        -O normalization=formD \
        -O mountpoint=none \
        -O canmount=off \
        "$pool_name" "$drive"; then
        log "ERROR" "Failed to create ZFS pool $pool_name"
        return 1
    fi
    
    if ! zfs create -o mountpoint="/mnt/pve/$pool_name" -o canmount=on "$pool_name/vmdata"; then
        log "WARN" "Failed to create VM dataset, but pool creation succeeded"
    fi
    
    log "INFO" "Successfully created ZFS pool: $pool_name"
    return 0
}

# Add ZFS pool to Proxmox storage
add_to_proxmox_storage() {
    local pool_name="$1" storage_name="$2"
    local mount_point="/mnt/pve/$pool_name"
    
    log "INFO" "Adding $pool_name to Proxmox as '$storage_name'"
    
    # Verify pool health and mount
    zpool status "$pool_name" >/dev/null 2>&1 || { log "ERROR" "Pool $pool_name not healthy"; return 1; }
    [[ -d "$mount_point" ]] || { log "ERROR" "Mount point $mount_point missing"; return 1; }
    
    # Add to Proxmox if not already present
    if ! pvesm status -storage "$storage_name" &>/dev/null; then
        pvesm add dir "$storage_name" --path "$mount_point" \
            --content "images,vztmpl,iso,snippets,backup" || {
            log "ERROR" "Failed to add storage '$storage_name'"
            return 1
        }
        log "INFO" "Added storage '$storage_name' to Proxmox"
    else
        log "INFO" "Storage '$storage_name' already exists"
    fi
}

# Utility functions
is_drive_in_zfs_pool() {
    local drive="$1"
    zpool status 2>/dev/null | grep -q "$(basename "$drive")"
}

is_system_drive() {
    local drive="$1"
    lsblk "$drive" -no MOUNTPOINT | grep -qE "^(/|/boot|/var|/usr|/home)$"
}

confirm_system_mirror() {
    local drives=("$@")
    log "WARN" "⚠️  SYSTEM DRIVE MIRROR DETECTED ⚠️"
    log "WARN" "Drives: ${drives[*]}"
    log "WARN" "This creates a ZFS mirror including your system drive."
    echo
    read -p "Continue with system drive mirroring? (y/N): " -r confirm
    [[ "$confirm" =~ ^[Yy]$ ]]
}

# Display final status
show_final_status() {
    log "INFO" "=== FINAL STORAGE STATUS ==="
    
    # ZFS status
    log "INFO" "ZFS Pools:"
    zpool list 2>/dev/null || log "INFO" "No ZFS pools"
    echo
    
    # Proxmox storage
    log "INFO" "Proxmox Storage:"
    pvesm status | grep -E "(zfs-|Type)" || log "INFO" "No ZFS storage in Proxmox"
    echo
    
    log "INFO" "✅ ZFS storage setup completed!"
    log "INFO" "Configure network: ./install.sh --network"
    log "INFO" "Install Caddy: ./install.sh --caddy"
}

# Main execution
main() {
    # Parse arguments (keeping for backwards compatibility, but making interactive)
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force-zfs-drives)
                # Legacy option - now handled interactively
                log "INFO" "Note: --force-zfs-drives is now handled interactively"
                shift
                ;;
            --help|-h)
                cat << EOF
Usage: $0 [OPTIONS]

Set up ZFS mirrors for Proxmox storage.

This script is now interactive and will ask you which drives to use.

OPTIONS:
    --help               Show this help message

EOF
                exit 0
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    log "INFO" "Starting streamlined Proxmox ZFS setup..."
    
    # Root check
    [[ $EUID -eq 0 ]] || { log "ERROR" "Must run as root"; exit 1; }
    
    # Execution flow
    detect_drives
    
    if ! group_drives_by_size; then
        log "ERROR" "Failed to group drives by size"
        exit 1
    fi
    
    if [[ ${#MIRROR_GROUPS[@]} -eq 0 ]]; then
        log "ERROR" "No mirror groups were created. Cannot proceed."
        exit 1
    fi
    
    check_current_storage
    
    # Show proposed configuration
    echo
    log "INFO" "=== PROPOSED ZFS CONFIGURATION ==="
    local storage_count=0
    for i in "${!MIRROR_GROUPS[@]}"; do
        read -ra drives <<< "${MIRROR_GROUPS[i]}"
        if [[ ${#drives[@]} -eq 2 ]]; then
            log "INFO" "  ZFS Mirror $i: ${drives[0]} + ${drives[1]}"
            ((storage_count++))
        else
            log "INFO" "  ZFS Pool $i: ${drives[0]}"
            ((storage_count++))
        fi
    done
    log "INFO" "Total: $storage_count storage pools will be created"
    
    echo
    read -p "Proceed with ZFS configuration? (y/N): " -r confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { log "INFO" "Cancelled"; exit 0; }
    
    # Execute configuration
    if ! create_zfs_pools; then
        log "ERROR" "ZFS pool creation failed"
        log "INFO" "Please check the error messages above and try again"
        exit 1
    fi
    
    show_final_status
    
    log "INFO" "✅ Setup completed successfully!"
}

# Run main if executed directly
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"

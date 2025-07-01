#!/bin/bash

# Hetzner Proxmox ZFS Storage Setup Script (Streamlined)
# This script configures ZFS mirrors and sets up storage for Proxmox
# Focuses on ZFS-only setup, removing legacy RAID complexity

# Use proper error handling like format-drives.sh
set -euo pipefail

# Custom error handler
error_handler() {
    local line_no=$1
    local error_code=$2
    
    # Use echo if log function is not available yet
    if command -v log >/dev/null 2>&1; then
        log "ERROR" "Script failed at line $line_no with exit code $error_code"
        log "ERROR" "Last command: ${BASH_COMMAND}"
        log "ERROR" "This error occurred in the setup-mirrors script"
    else
        echo "ERROR: Script failed at line $line_no with exit code $error_code" >&2
        echo "ERROR: Last command: ${BASH_COMMAND}" >&2
        echo "ERROR: This error occurred in the setup-mirrors script" >&2
    fi
    
    exit "$error_code"
}

# Set up error handling
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
FORCE_YES="false"

# Enhanced drive detection with better filtering
detect_drives() {
    log "INFO" "Detecting available drives..."
    
    local drives
    drives=$(lsblk -dpno NAME,SIZE,TYPE | awk '$3=="disk" && $1!~/loop/ {print $1,$2}')
    
    if [[ -z "$drives" ]]; then
        log "ERROR" "No drives detected"
        return 1
    fi
    
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
        return 1
    elif [[ ${#available_drives[@]} -eq 0 ]]; then
        log "INFO" "No unused drives found. Only drives already in ZFS pools are available."
        echo
        if [[ "$FORCE_YES" == "true" ]]; then
            log "INFO" "Auto-selecting option 1: Only unused drives (non-interactive mode)"
            confirm="n"
        else
            read -p "Do you want to work with drives already in ZFS pools? (y/N): " -r confirm
        fi
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            AVAILABLE_DRIVES=("${zfs_drives[@]}")
            DRIVE_SIZES=("${zfs_sizes[@]}")
            export FORCE_ZFS_DRIVES="true"
        else
            log "INFO" "No drives selected for configuration"
            return 1
        fi
    elif [[ ${#zfs_drives[@]} -gt 0 ]]; then
        log "INFO" "You can work with:"
        log "INFO" "  1) Only unused drives (${#available_drives[@]} drives)"
        log "INFO" "  2) Both unused drives AND drives already in ZFS pools (${#available_drives[@]} + ${#zfs_drives[@]} drives)"
        echo
        if [[ "$FORCE_YES" == "true" ]]; then
            log "INFO" "Auto-selecting option 1: Only unused drives (non-interactive mode)"
            choice="1"
        else
            read -p "Choose option (1-2): " -r choice
        fi
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
    
    if [[ ${#AVAILABLE_DRIVES[@]} -eq 0 ]]; then
        log "ERROR" "No drives selected for configuration"
        return 1
    fi
    
    log "INFO" "Selected ${#AVAILABLE_DRIVES[@]} drives for configuration"
    return 0
}

# Optimized drive grouping
group_drives_by_size() {
    log "INFO" "Grouping drives by size for optimal mirroring..."
    
    if [[ ${#AVAILABLE_DRIVES[@]} -eq 0 ]]; then
        log "ERROR" "No available drives to group"
        return 1
    fi
    
    declare -A size_groups
    
    # Group drives by size
    for i in "${!AVAILABLE_DRIVES[@]}"; do
        local size="${DRIVE_SIZES[i]}"
        size_groups["$size"]+="${AVAILABLE_DRIVES[i]} "
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
            done
            
            # Handle remaining single drive
            if [[ $((count % 2)) -eq 1 ]]; then
                log "INFO" "  -> 1 single drive pool: ${drives[-1]}"
                MIRROR_GROUPS+=("${drives[-1]}")
            fi
        else
            log "INFO" "  -> Single drive pool"
            MIRROR_GROUPS+=("${drives[0]}")
        fi
    done
    
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
    
    return 0
}

# Install ZFS if needed
install_zfs() {
    if command -v zpool >/dev/null && command -v zfs >/dev/null; then
        log "INFO" "ZFS already available"
        return 0
    fi
    
    log "INFO" "Installing ZFS..."
    
    # Temporarily disable strict error handling for package installation
    set +e
    apt update
    local apt_result=$?
    set -e
    
    if [[ $apt_result -ne 0 ]]; then
        log "WARN" "apt update had some issues, but continuing..."
    fi
    
    set +e
    apt install -y zfsutils-linux
    apt_result=$?
    set -e
    
    if [[ $apt_result -ne 0 ]]; then
        log "ERROR" "Failed to install zfsutils-linux"
        return 1
    fi
    
    set +e
    modprobe zfs
    local modprobe_result=$?
    set -e
    
    if [[ $modprobe_result -ne 0 ]]; then
        log "ERROR" "Failed to load ZFS module"
        return 1
    fi
    
    log "INFO" "ZFS installed successfully"
    return 0
}

# Create ZFS pools efficiently
create_zfs_pools() {
    log "INFO" "Creating ZFS pools..."
    
    # Check if we have any mirror groups
    if [[ ${#MIRROR_GROUPS[@]} -eq 0 ]]; then
        log "ERROR" "No mirror groups defined. This should not happen."
        return 1
    fi
    
    install_zfs || { log "ERROR" "Failed to install/setup ZFS"; return 1; }
    
    local pool_index=0 success_count=0
    declare -a failed_groups=()
    
    for mirror_group in "${MIRROR_GROUPS[@]}"; do
        read -ra drives <<< "$mirror_group"
        
        # Generate unique pool name
        local pool_name
        while true; do
            pool_name="zpool$pool_index"
            if ! zpool list -H "$pool_name" 2>/dev/null | grep -q "^$pool_name"; then
                break
            fi
            pool_index=$((pool_index + 1))
        done
        
        if [[ ${#drives[@]} -eq 2 ]]; then
            log "INFO" "Creating ZFS mirror: ${drives[0]} + ${drives[1]} -> $pool_name"
            
            # Handle system drives carefully
            if is_system_drive "${drives[0]}" || is_system_drive "${drives[1]}"; then
                if ! confirm_system_mirror "${drives[@]}"; then
                    log "INFO" "Skipping system drive mirror"
                    failed_groups+=("$mirror_group")
                    pool_index=$((pool_index + 1))
                    continue
                fi
            fi
            
            if create_zfs_mirror "$pool_name" "${drives[0]}" "${drives[1]}"; then
                if add_to_proxmox_storage "$pool_name" "zfs-mirror-$pool_index"; then
                    success_count=$((success_count + 1))
                    log "INFO" "Successfully created and added mirror: $pool_name"
                else
                    log "WARN" "Mirror created but failed to add to Proxmox storage"
                    success_count=$((success_count + 1))  # Still count as success since pool was created
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
                pool_index=$((pool_index + 1))
                continue
            fi
            
            if create_zfs_single "$pool_name" "$drive"; then
                if add_to_proxmox_storage "$pool_name" "zfs-single-$pool_index"; then
                    success_count=$((success_count + 1))
                    log "INFO" "Successfully created and added single pool: $pool_name"
                else
                    log "WARN" "Pool created but failed to add to Proxmox storage"
                    success_count=$((success_count + 1))  # Still count as success since pool was created
                fi
            else
                log "ERROR" "Failed to create ZFS pool: $pool_name"
                failed_groups+=("$mirror_group")
            fi
        else
            log "ERROR" "Invalid drive count in mirror group: ${#drives[@]} drives"
            failed_groups+=("$mirror_group")
        fi
        
        pool_index=$((pool_index + 1))
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
                if [[ "$FORCE_YES" == "true" ]]; then
                    log "INFO" "Auto-confirming drive wipe (non-interactive mode)"
                    confirm="y"
                else
                    read -p "Wipe $drive? (y/N): " -r confirm
                fi
                if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                    log "INFO" "Skipping $drive"
                    return 1
                fi
            fi
            log "INFO" "Wiping filesystem on $drive..."
            
            # Use more resilient wiping
            set +e
            wipefs -a "$drive"
            local wipe_result=$?
            set -e
            
            if [[ $wipe_result -ne 0 ]]; then
                log "ERROR" "Failed to wipe $drive"
                return 1
            fi
        fi
    done
    
    log "INFO" "Creating ZFS mirror pool: $pool_name"
    
    # Create ZFS mirror with Proxmox-optimized settings
    set +e
    zpool create -f \
        -o ashift=12 \
        -O compression=lz4 \
        -O atime=off \
        -O relatime=on \
        -O xattr=sa \
        -O dnodesize=auto \
        -O normalization=formD \
        "$pool_name" mirror "$drive1" "$drive2"
    local create_result=$?
    set -e
    
    if [[ $create_result -ne 0 ]]; then
        log "ERROR" "Failed to create ZFS mirror $pool_name"
        return 1
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
            if [[ "$FORCE_YES" == "true" ]]; then
                log "INFO" "Auto-confirming drive wipe (non-interactive mode)"
                confirm="y"
            else
                read -p "Wipe $drive? (y/N): " -r confirm
            fi
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                log "INFO" "Skipping $drive"
                return 1
            fi
        fi
        log "INFO" "Wiping filesystem on $drive..."
        
        # Use more resilient wiping
        set +e
        wipefs -a "$drive"
        local wipe_result=$?
        set -e
        
        if [[ $wipe_result -ne 0 ]]; then
            log "ERROR" "Failed to wipe $drive"
            return 1
        fi
    fi
    
    log "INFO" "Creating ZFS pool: $pool_name"
    
    # Create single ZFS pool with resilient error handling
    set +e
    zpool create -f \
        -o ashift=12 \
        -O compression=lz4 \
        -O atime=off \
        -O relatime=on \
        -O xattr=sa \
        -O dnodesize=auto \
        -O normalization=formD \
        "$pool_name" "$drive"
    local create_result=$?
    set -e
    
    if [[ $create_result -ne 0 ]]; then
        log "ERROR" "Failed to create ZFS pool $pool_name"
        return 1
    fi
    
    log "INFO" "Successfully created ZFS pool: $pool_name"
    return 0
}

# Add ZFS pool to Proxmox storage
add_to_proxmox_storage() {
    local pool_name="$1" storage_name="$2"
    
    log "INFO" "Adding $pool_name to Proxmox as ZFS storage '$storage_name'"
    
    # Verify pool health
    set +e
    zpool status "$pool_name" >/dev/null 2>&1
    local pool_status=$?
    set -e
    
    if [[ $pool_status -ne 0 ]]; then
        log "ERROR" "Pool $pool_name not healthy"
        return 1
    fi
    
    # Add to Proxmox if not already present
    set +e
    pvesm status -storage "$storage_name" &>/dev/null
    local storage_exists=$?
    set -e
    
    if [[ $storage_exists -ne 0 ]]; then
        log "INFO" "Adding new ZFS storage '$storage_name' to Proxmox..."
        
        set +e
        pvesm add zfspool "$storage_name" --pool "$pool_name" \
            --content "images,vztmpl,rootdir"
        local add_result=$?
        set -e
        
        if [[ $add_result -ne 0 ]]; then
            log "ERROR" "Failed to add ZFS storage '$storage_name' to Proxmox"
            log "WARN" "You may need to add it manually via the Proxmox web interface"
            return 1
        fi
        
        log "INFO" "Successfully added ZFS storage '$storage_name' to Proxmox"
    else
        log "INFO" "Storage '$storage_name' already exists in Proxmox"
    fi
    
    return 0
}

# Utility functions
is_drive_in_zfs_pool() {
    local drive="$1"
    
    # Use more reliable checking
    set +e
    zpool status 2>/dev/null | grep -q "$(basename "$drive")"
    local result=$?
    set -e
    
    return $result
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
    if [[ "$FORCE_YES" == "true" ]]; then
        log "INFO" "Auto-confirming system drive mirroring (non-interactive mode)"
        confirm="y"
    else
        read -p "Continue with system drive mirroring? (y/N): " -r confirm
    fi
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
    pvesm status 2>/dev/null | grep -E "(zfspool|Type)" || log "INFO" "No ZFS storage in Proxmox"
    echo
    
    log "INFO" "✅ ZFS storage setup completed!"
    log "INFO" "Configure network: ./install.sh --network"
    log "INFO" "Install Caddy: ./install.sh --caddy"
    
    return 0
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
            --yes|-y|--force)
                # Non-interactive mode - automatically confirm prompts
                FORCE_YES="true"
                log "INFO" "Running in non-interactive mode"
                shift
                ;;
            --help|-h)
                cat << EOF
Usage: $0 [OPTIONS]

Set up ZFS mirrors for Proxmox storage.

This script will:
  • Detect available drives
  • Create ZFS mirrors from drives of the same size
  • Add ZFS pools to Proxmox as native ZFS storage
  • Require confirmation before making changes

SAFETY FEATURES:
  • Automatically detects and skips system drives
  • Shows drive information before configuration
  • Requires explicit confirmation before creating pools
  • Uses ZFS native storage in Proxmox (not directory mounts)

OPTIONS:
    --yes, -y, --force  Run in non-interactive mode (auto-confirm prompts)
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
    if ! detect_drives; then
        log "ERROR" "Failed to detect drives properly"
        log "INFO" "Please check the system and try again"
        exit 1
    fi
    
    if ! group_drives_by_size; then
        log "ERROR" "Failed to group drives by size"
        log "INFO" "This might be due to no available drives or configuration issues"
        exit 1
    fi
    
    if [[ ${#MIRROR_GROUPS[@]} -eq 0 ]]; then
        log "ERROR" "No mirror groups were created. Cannot proceed."
        log "INFO" "This usually means no drives are available for configuration"
        exit 1
    fi
    
    if ! check_current_storage; then
        log "WARN" "Could not check current storage status, but continuing..."
    fi
    
    # Show proposed configuration
    echo
    log "INFO" "=== PROPOSED ZFS CONFIGURATION ==="
    local storage_count=0
    for i in "${!MIRROR_GROUPS[@]}"; do
        local mirror_group="${MIRROR_GROUPS[i]}"
        
        # Safely parse drives from mirror group
        local drives=()
        if [[ -n "$mirror_group" ]]; then
            read -ra drives <<< "$mirror_group"
        fi
        
        if [[ ${#drives[@]} -eq 2 ]]; then
            log "INFO" "  ZFS Mirror $i: ${drives[0]} + ${drives[1]}"
            storage_count=$((storage_count + 1))
        elif [[ ${#drives[@]} -eq 1 ]]; then
            log "INFO" "  ZFS Pool $i: ${drives[0]}"
            storage_count=$((storage_count + 1))
        else
            log "WARN" "Skipping invalid mirror group $i with ${#drives[@]} drives"
        fi
    done
    log "INFO" "Total: $storage_count storage pools will be created"
    
    echo
    log "INFO" "⚠️  WARNING: This will create ZFS pools on the selected drives ⚠️"
    log "INFO" "This operation will:"
    log "INFO" "  • Create ZFS pools on unused drives"
    log "INFO" "  • Wipe any existing filesystems on selected drives"
    log "INFO" "  • Add storage pools to Proxmox configuration"
    log "INFO" "  • This action cannot be easily undone"
    echo
    
    # Simple confirmation logic
    if [[ "$FORCE_YES" == "true" ]]; then
        log "INFO" "Auto-confirming ZFS configuration (non-interactive mode)"
        confirm="y"
    else
        read -p "Are you sure you want to proceed with ZFS pool creation? (y/N): " -r confirm
    fi
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "INFO" "Configuration cancelled by user"
        exit 0
    fi
    
    # Execute configuration
    log "INFO" "Starting ZFS pool creation process..."
    if ! create_zfs_pools; then
        log "ERROR" "ZFS pool creation encountered failures"
        log "INFO" "Some pools may have been created successfully"
        log "INFO" "Check the logs above for details"
        
        # Don't exit here - show final status even if some pools failed
        log "INFO" "Proceeding to show final status..."
    else
        log "INFO" "All ZFS pools created successfully!"
    fi
    
    show_final_status
    
    log "INFO" "✅ Setup completed!"
    log "INFO" "Check the final status above for details of what was created"
    
    # Explicitly exit with success code
    exit 0
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

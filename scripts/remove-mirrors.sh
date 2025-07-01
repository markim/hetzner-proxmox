#!/bin/bash

# Hetzner Proxmox ZFS Storage Removal Script (Streamlined)
# This script removes ZFS pools and cleans up Proxmox storage configurations
# Focuses on ZFS-only removal, replacing legacy RAID functionality

# Note: We intentionally don't use 'set -e' here to handle errors gracefully
set -uo pipefail

# Error handler for unexpected errors only
error_handler() {
    local line_no=$1 error_code=$2
    echo "ERROR: Script failed unexpectedly at line $line_no with exit code $error_code" >&2
    exit "$error_code"
}

# Get script directory and source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/common.sh"

# Get ZFS mirrors from rpool
get_rpool_mirrors() {
    if ! command -v zpool >/dev/null 2>&1; then
        return 0
    fi
    
    if ! zpool list -H rpool >/dev/null 2>&1; then
        return 0
    fi
    
    # Get all mirror vdevs from rpool
    zpool status rpool | grep -E "^\s+mirror-[0-9]+" | awk '{print $1}' 2>/dev/null || true
}

# Get mirror details from rpool
get_mirror_info() {
    local mirror="$1"
    local info=""
    
    if zpool status rpool >/dev/null 2>&1; then
        local status health drives
        status=$(zpool status rpool | grep -A 10 "^\s*$mirror" | grep -E "^\s+/dev/" | awk '{print $1}' | tr '\n' ' ' || echo "unknown")
        health=$(zpool status rpool | grep -A 1 "^\s*$mirror" | tail -1 | awk '{print $2}' || echo "unknown")
        drives=$(echo "$status" | wc -w)
        info="$drives drives ($status), $health"
        
        # Check if used by Proxmox
        local storage_names
        storage_names=$(pvesm status 2>/dev/null | awk '/rpool/ {print $1}' || true)
        [[ -n "$storage_names" ]] && info="$info, Proxmox: $storage_names"
    fi
    
    echo "$info"
}

# Check if mirror is system-critical
is_system_mirror() {
    local mirror="$1"
    
    # Check if mirror contains system datasets
    if zfs list -H -o name,mountpoint rpool 2>/dev/null | grep -qE '\s(/|/boot|/var|/usr|/home|/root)$'; then
        # If rpool has system mounts, check if this is the root mirror
        if zpool status rpool | grep -A 5 "^\s*$mirror" | grep -q "rpool"; then
            return 0
        fi
    fi
    
    # Check if this is the primary mirror (usually mirror-0)
    if [[ "$mirror" == "mirror-0" ]]; then
        return 0
    fi
    
    return 1
}

# Remove ZFS mirror from rpool
remove_mirror_from_rpool() {
    local mirror="$1"
    
    log "INFO" "Removing ZFS mirror '$mirror' from rpool..."
    
    # Safety check - don't remove system mirrors
    if is_system_mirror "$mirror"; then
        log "ERROR" "Cannot remove system mirror '$mirror' - it contains critical system data"
        return 1
    fi
    
    # Get devices in the mirror before removal
    local devices
    devices=$(zpool status rpool | grep -A 10 "^\s*$mirror" | grep -E "^\s+/dev/" | awk '{print $1}' | tr '\n' ' ')
    
    log "INFO" "Mirror '$mirror' contains devices: $devices"
    
    # Remove the mirror from rpool
    if zpool remove rpool "$mirror" 2>/dev/null; then
        log "INFO" "Successfully removed mirror '$mirror' from rpool"
        
        # Clean the devices that were in the mirror
        for device in $devices; do
            [[ -n "$device" ]] && clean_drive "$device"
        done
        
        return 0
    else
        log "ERROR" "Failed to remove mirror '$mirror' from rpool"
        return 1
    fi
}

# Safely destroy ZFS pool
destroy_zfs_pool() {
    local pool="$1" force="$2"
    
    log "INFO" "Destroying ZFS pool: $pool"
    
    # Export pool first to ensure clean state
    if zpool export "$pool" 2>/dev/null; then
        log "DEBUG" "Exported pool: $pool"
    else
        log "WARN" "Failed to export pool: $pool (may already be exported)"
    fi
    
    # Import and destroy
    local success=false
    if zpool import "$pool" 2>/dev/null; then
        log "DEBUG" "Re-imported pool: $pool"
        
        # Destroy with force if needed
        if [[ "$force" == "true" ]]; then
            if zpool destroy -f "$pool" 2>/dev/null; then
                log "INFO" "Force destroyed pool: $pool"
                success=true
            fi
        else
            if zpool destroy "$pool" 2>/dev/null; then
                log "INFO" "Destroyed pool: $pool"
                success=true
            fi
        fi
    fi
    
    if [[ "$success" == "true" ]]; then
        return 0
    else
        log "ERROR" "Failed to destroy pool: $pool"
        return 1
    fi
}

# Clean drive after pool removal
clean_drive() {
    local drive="$1"
    
    log "INFO" "Cleaning ZFS labels from drive: $drive"
    
    # Clear ZFS labels
    if command -v zpool >/dev/null 2>&1; then
        zpool labelclear -f "$drive" 2>/dev/null || true
    fi
    
    # Wipe filesystem signatures
    if command -v wipefs >/dev/null 2>&1; then
        wipefs -a "$drive" 2>/dev/null || true
    fi
    
    log "DEBUG" "Cleaned drive: $drive"
}

# Get drives used by a ZFS pool
get_pool_drives() {
    local pool="$1"
    
    if ! zpool status "$pool" >/dev/null 2>&1; then
        return 1
    fi
    
    # Extract device names from zpool status
    zpool status "$pool" | grep -oE '/dev/[a-zA-Z0-9/]+' | sort -u
}

# Show current ZFS status
show_zfs_status() {
    log "INFO" "=== CURRENT ZFS STATUS ==="
    
    if ! command -v zpool >/dev/null 2>&1; then
        log "INFO" "ZFS not installed or available"
        return 0
    fi
    
    if ! zpool list -H rpool >/dev/null 2>&1; then
        log "INFO" "rpool not found"
        return 0
    fi
    
    log "INFO" "rpool Status:"
    zpool list rpool 2>/dev/null || true
    echo
    
    log "INFO" "rpool Mirrors:"
    local mirrors
    mirrors=$(get_rpool_mirrors)
    
    if [[ -z "$mirrors" ]]; then
        log "INFO" "  No mirrors found in rpool"
        return 0
    fi
    
    while read -r mirror; do
        [[ -n "$mirror" ]] || continue
        local info
        info=$(get_mirror_info "$mirror")
        local system_marker=""
        is_system_mirror "$mirror" && system_marker=" ⚠️ SYSTEM"
        log "INFO" "  $mirror: $info$system_marker"
    done <<< "$mirrors"
    
    echo
    log "INFO" "Proxmox Storage using rpool:"
    pvesm status 2>/dev/null | grep -E "(rpool|Type)" || log "INFO" "No rpool storage in Proxmox"
}

# Interactive mirror selection
interactive_mirror_selection() {
    local mirrors
    mirrors=$(get_rpool_mirrors)
    
    if [[ -z "$mirrors" ]]; then
        log "INFO" "No ZFS mirrors found in rpool to remove"
        return 0
    fi
    
    log "INFO" "=== INTERACTIVE ZFS MIRROR REMOVAL ==="
    log "INFO" "Select mirrors to remove from rpool (data will be permanently lost!)"
    echo
    
    declare -a selected_mirrors=()
    local mirror_array=()
    
    # Build array and show options
    while read -r mirror; do
        [[ -n "$mirror" ]] || continue
        mirror_array+=("$mirror")
    done <<< "$mirrors"
    
    for i in "${!mirror_array[@]}"; do
        local mirror="${mirror_array[i]}"
        local info
        info=$(get_mirror_info "$mirror")
        local system_marker=""
        is_system_mirror "$mirror" && system_marker=" ⚠️ SYSTEM"
        echo "$((i+1)). $mirror ($info)$system_marker"
    done
    
    echo
    echo "0. Remove ALL non-system mirrors"
    echo "a. Remove ALL mirrors (including system) - DANGEROUS"
    echo "q. Quit without changes"
    echo
    
    while true; do
        read -p "Select mirrors to remove (e.g., 1,3 or 0 or a): " -r selection
        
        case "$selection" in
            q|Q)
                log "INFO" "Operation cancelled"
                return 0
                ;;
            0)
                # Remove all non-system mirrors
                for mirror in "${mirror_array[@]}"; do
                    if ! is_system_mirror "$mirror"; then
                        selected_mirrors+=("$mirror")
                    fi
                done
                break
                ;;
            a|A)
                # Remove ALL mirrors (dangerous)
                log "WARN" "⚠️ WARNING: This will remove ALL ZFS mirrors including system mirrors!"
                read -p "Are you absolutely sure? Type 'YES' to confirm: " -r confirm
                if [[ "$confirm" == "YES" ]]; then
                    selected_mirrors=("${mirror_array[@]}")
                    break
                else
                    log "INFO" "Operation cancelled"
                    return 0
                fi
                ;;
            *)
                # Parse comma-separated numbers
                selected_mirrors=()
                IFS=',' read -ra selections <<< "$selection"
                local valid=true
                
                for sel in "${selections[@]}"; do
                    if [[ "$sel" =~ ^[0-9]+$ ]] && [[ $sel -ge 1 ]] && [[ $sel -le ${#mirror_array[@]} ]]; then
                        local idx=$((sel-1))
                        selected_mirrors+=("${mirror_array[idx]}")
                    else
                        log "ERROR" "Invalid selection: $sel"
                        valid=false
                        break
                    fi
                done
                
                if [[ "$valid" == "true" ]] && [[ ${#selected_mirrors[@]} -gt 0 ]]; then
                    break
                fi
                ;;
        esac
    done
    
    if [[ ${#selected_mirrors[@]} -eq 0 ]]; then
        log "INFO" "No mirrors selected for removal"
        return 0
    fi
    
    # Show selected mirrors and confirm
    echo
    log "INFO" "Selected mirrors for removal:"
    for mirror in "${selected_mirrors[@]}"; do
        local info
        info=$(get_mirror_info "$mirror")
        local system_marker=""
        is_system_mirror "$mirror" && system_marker=" ⚠️ SYSTEM"
        log "WARN" "  $mirror ($info)$system_marker"
    done
    
    echo
    log "WARN" "⚠️ This will permanently destroy all data in these mirrors!"
    read -p "Continue with removal? (y/N): " -r confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "INFO" "Operation cancelled"
        return 0
    fi
    
    # Remove selected mirrors
    if remove_selected_mirrors "${selected_mirrors[@]}"; then
        return 0
    else
        return 1
    fi
}

# Remove selected mirrors
remove_selected_mirrors() {
    local mirrors=("$@")
    local success_count=0
    local failed_mirrors=()
    
    log "INFO" "Removing ${#mirrors[@]} ZFS mirror(s) from rpool..."
    
    for mirror in "${mirrors[@]}"; do
        log "INFO" "Processing mirror: $mirror"
        
        # Remove the mirror from rpool
        if remove_mirror_from_rpool "$mirror"; then
            log "INFO" "✅ Successfully removed mirror: $mirror"
            ((success_count++))
        else
            log "ERROR" "❌ Failed to remove mirror: $mirror"
            failed_mirrors+=("$mirror")
        fi
    done
    
    # Report results
    log "INFO" "Mirror removal completed: $success_count successful, ${#failed_mirrors[@]} failed"
    if [[ ${#failed_mirrors[@]} -gt 0 ]]; then
        log "WARN" "Failed mirrors: ${failed_mirrors[*]}"
        return 1
    fi
    
    return 0
}

# Remove all mirrors (force mode)
remove_all_mirrors() {
    local force="$1"
    local mirrors
    mirrors=$(get_rpool_mirrors)
    
    if [[ -z "$mirrors" ]]; then
        log "INFO" "No ZFS mirrors found in rpool to remove"
        return 0
    fi
    
    log "WARN" "Force mode: Removing ALL ZFS mirrors from rpool"
    
    if [[ "$force" != "true" ]]; then
        echo
        log "WARN" "⚠️ This will permanently destroy ALL ZFS mirrors in rpool!"
        read -p "Continue? (y/N): " -r confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && { log "INFO" "Cancelled"; return 0; }
    fi
    
    declare -a mirror_array=()
    while read -r mirror; do
        [[ -n "$mirror" ]] && mirror_array+=("$mirror")
    done <<< "$mirrors"
    
    if remove_selected_mirrors "${mirror_array[@]}"; then
        return 0
    else
        return 1
    fi
}

# Show help
show_help() {
    cat << 'EOF'
Usage: remove-mirrors.sh [OPTIONS]

Remove ZFS mirrors from the rpool and clean up associated storage.

OPTIONS:
    --interactive, -i    Select specific mirrors to remove (default)
    --force             Remove ALL mirrors without confirmation
    --status            Show current ZFS status and exit
    --help, -h          Show this help message

EXAMPLES:
    remove-mirrors.sh                    # Interactive mirror selection
    remove-mirrors.sh --status           # Show current ZFS mirrors
    remove-mirrors.sh --force            # Remove ALL mirrors (dangerous)

SAFETY:
    - Interactive mode allows selective mirror removal
    - Force mode removes ALL mirrors including system mirrors
    - Data is permanently destroyed when mirrors are removed
    - System mirrors (mirror-0) are protected by default
    - Drives are wiped clean for reuse

WARNING:
    Removing system mirrors can make your system unbootable!
    Always backup important data before running this script.
EOF
}

# Main execution
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
                # Interactive is default mode, just consume the flag
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Root check
    [[ $EUID -eq 0 ]] || { log "ERROR" "Must run as root"; exit 1; }
    
    if [[ "$show_status" == "true" ]]; then
        show_zfs_status
        exit 0
    fi
    
    log "INFO" "Starting ZFS mirror removal process..."
    
    # Show current status
    show_zfs_status
    echo
    
    # Execute based on mode
    local exit_code=0
    if [[ "$force" == "true" ]]; then
        if ! remove_all_mirrors "true"; then
            exit_code=1
        fi
    else
        if ! interactive_mirror_selection; then
            exit_code=1
        fi
    fi
    
    echo
    show_zfs_status
    
    if [[ $exit_code -eq 0 ]]; then
        log "INFO" "✅ ZFS mirror removal completed!"
        log "INFO" ""
        log "INFO" "Next steps:"
        log "INFO" "1. Run: ./setup-mirrors.sh        # To add new mirrors to rpool"
        log "INFO" "2. Verify: zpool status rpool      # Check final ZFS status"
    else
        log "ERROR" "❌ ZFS mirror removal completed with errors!"
    fi
    
    # Explicitly exit with the determined code
    exit $exit_code
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

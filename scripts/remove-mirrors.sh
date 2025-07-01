#!/bin/bash

# Hetzner Proxmox ZFS Storage Removal Script (Streamlined)
# This script removes ZFS pools and cleans up Proxmox storage configurations
# Focuses on ZFS-only removal, replacing legacy RAID functionality

set -euo pipefail

# Error handler
error_handler() {
    local line_no=$1 error_code=$2
    echo "ERROR: Script failed at line $line_no with exit code $error_code" >&2
    exit "$error_code"
}
trap 'error_handler ${LINENO} $?' ERR

# Get script directory and source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/common.sh"

# Get all ZFS pools
get_zfs_pools() {
    if ! command -v zpool >/dev/null 2>&1; then
        return 0
    fi
    
    zpool list -H -o name 2>/dev/null || true
}

# Get ZFS pool details
get_pool_info() {
    local pool="$1"
    local info=""
    
    if zpool status "$pool" >/dev/null 2>&1; then
        local size health
        size=$(zpool list -H -o size "$pool" 2>/dev/null || echo "unknown")
        health=$(zpool list -H -o health "$pool" 2>/dev/null || echo "unknown")
        info="$size, $health"
        
        # Check if used by Proxmox
        local storage_names
        storage_names=$(pvesm status 2>/dev/null | awk -v pool="$pool" '$3 ~ pool {print $1}' || true)
        [[ -n "$storage_names" ]] && info="$info, Proxmox: $storage_names"
    fi
    
    echo "$info"
}

# Check if pool is system-critical
is_system_pool() {
    local pool="$1"
    
    # Check if any datasets are mounted on system paths
    if zfs list -H -o name,mountpoint "$pool" 2>/dev/null | grep -qE '\s(/|/boot|/var|/usr|/home|/root)$'; then
        return 0
    fi
    
    # Check if pool name suggests system usage
    if [[ "$pool" =~ ^(rpool|bpool|system|root|boot)$ ]]; then
        return 0
    fi
    
    return 1
}

# Remove ZFS pool from Proxmox storage
remove_from_proxmox() {
    local pool="$1"
    
    log "INFO" "Removing ZFS pool '$pool' from Proxmox storage..."
    
    # Find all Proxmox storage entries using this pool
    local storage_entries
    storage_entries=$(pvesm status 2>/dev/null | awk -v pool="$pool" '$3 ~ pool {print $1}' || true)
    
    if [[ -n "$storage_entries" ]]; then
        while read -r storage_name; do
            [[ -n "$storage_name" ]] || continue
            log "INFO" "Removing Proxmox storage: $storage_name"
            
            # Disable first, then remove
            if pvesm set "$storage_name" --disable 1 2>/dev/null; then
                log "DEBUG" "Disabled storage: $storage_name"
            fi
            
            if pvesm remove "$storage_name" 2>/dev/null; then
                log "INFO" "Removed storage: $storage_name"
            else
                log "WARN" "Failed to remove storage: $storage_name"
            fi
        done <<< "$storage_entries"
    else
        log "DEBUG" "No Proxmox storage entries found for pool: $pool"
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
    if zpool import "$pool" 2>/dev/null; then
        log "DEBUG" "Re-imported pool: $pool"
        
        # Destroy with force if needed
        if [[ "$force" == "true" ]]; then
            if zpool destroy -f "$pool" 2>/dev/null; then
                log "INFO" "Force destroyed pool: $pool"
                return 0
            fi
        else
            if zpool destroy "$pool" 2>/dev/null; then
                log "INFO" "Destroyed pool: $pool"
                return 0
            fi
        fi
    fi
    
    log "ERROR" "Failed to destroy pool: $pool"
    return 1
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
    
    local pools
    pools=$(get_zfs_pools)
    
    if [[ -z "$pools" ]]; then
        log "INFO" "No ZFS pools found"
        return 0
    fi
    
    log "INFO" "ZFS Pools:"
    zpool list 2>/dev/null || true
    echo
    
    log "INFO" "Pool Details:"
    while read -r pool; do
        [[ -n "$pool" ]] || continue
        local info
        info=$(get_pool_info "$pool")
        local system_marker=""
        is_system_pool "$pool" && system_marker=" ⚠️ SYSTEM"
        log "INFO" "  $pool: $info$system_marker"
    done <<< "$pools"
    
    echo
    log "INFO" "Proxmox Storage using ZFS:"
    pvesm status 2>/dev/null | grep -E "(zfs|Type)" || log "INFO" "No ZFS storage in Proxmox"
}

# Interactive pool selection
interactive_pool_selection() {
    local pools
    pools=$(get_zfs_pools)
    
    if [[ -z "$pools" ]]; then
        log "INFO" "No ZFS pools found to remove"
        return 0
    fi
    
    log "INFO" "=== INTERACTIVE ZFS POOL REMOVAL ==="
    log "INFO" "Select pools to remove (data will be permanently lost!)"
    echo
    
    declare -a selected_pools=()
    local pool_array=()
    
    # Build array and show options
    while read -r pool; do
        [[ -n "$pool" ]] || continue
        pool_array+=("$pool")
    done <<< "$pools"
    
    for i in "${!pool_array[@]}"; do
        local pool="${pool_array[i]}"
        local info
        info=$(get_pool_info "$pool")
        local system_marker=""
        is_system_pool "$pool" && system_marker=" ⚠️ SYSTEM"
        echo "$((i+1)). $pool ($info)$system_marker"
    done
    
    echo
    echo "0. Remove ALL non-system pools"
    echo "a. Remove ALL pools (including system) - DANGEROUS"
    echo "q. Quit without changes"
    echo
    
    while true; do
        read -p "Select pools to remove (e.g., 1,3 or 0 or a): " -r selection
        
        case "$selection" in
            q|Q)
                log "INFO" "Operation cancelled"
                return 0
                ;;
            0)
                # Remove all non-system pools
                for pool in "${pool_array[@]}"; do
                    if ! is_system_pool "$pool"; then
                        selected_pools+=("$pool")
                    fi
                done
                break
                ;;
            a|A)
                # Remove ALL pools (dangerous)
                log "WARN" "⚠️ WARNING: This will remove ALL ZFS pools including system pools!"
                read -p "Are you absolutely sure? Type 'YES' to confirm: " -r confirm
                if [[ "$confirm" == "YES" ]]; then
                    selected_pools=("${pool_array[@]}")
                    break
                else
                    log "INFO" "Operation cancelled"
                    return 0
                fi
                ;;
            *)
                # Parse comma-separated numbers
                selected_pools=()
                IFS=',' read -ra selections <<< "$selection"
                local valid=true
                
                for sel in "${selections[@]}"; do
                    if [[ "$sel" =~ ^[0-9]+$ ]] && [[ $sel -ge 1 ]] && [[ $sel -le ${#pool_array[@]} ]]; then
                        local idx=$((sel-1))
                        selected_pools+=("${pool_array[idx]}")
                    else
                        log "ERROR" "Invalid selection: $sel"
                        valid=false
                        break
                    fi
                done
                
                if [[ "$valid" == "true" ]] && [[ ${#selected_pools[@]} -gt 0 ]]; then
                    break
                fi
                ;;
        esac
    done
    
    if [[ ${#selected_pools[@]} -eq 0 ]]; then
        log "INFO" "No pools selected for removal"
        return 0
    fi
    
    # Show selected pools and confirm
    echo
    log "INFO" "Selected pools for removal:"
    for pool in "${selected_pools[@]}"; do
        local info
        info=$(get_pool_info "$pool")
        local system_marker=""
        is_system_pool "$pool" && system_marker=" ⚠️ SYSTEM"
        log "WARN" "  $pool ($info)$system_marker"
    done
    
    echo
    log "WARN" "⚠️ This will permanently destroy all data in these pools!"
    read -p "Continue with removal? (y/N): " -r confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "INFO" "Operation cancelled"
        return 0
    fi
    
    # Remove selected pools
    remove_selected_pools "${selected_pools[@]}"
}

# Remove selected pools
remove_selected_pools() {
    local pools=("$@")
    local success_count=0
    local failed_pools=()
    
    log "INFO" "Removing ${#pools[@]} ZFS pool(s)..."
    
    for pool in "${pools[@]}"; do
        log "INFO" "Processing pool: $pool"
        
        # Get drives before removal for cleanup
        local drives
        drives=$(get_pool_drives "$pool" 2>/dev/null || true)
        
        # Remove from Proxmox first
        remove_from_proxmox "$pool"
        
        # Destroy the pool
        if destroy_zfs_pool "$pool" "false"; then
            log "INFO" "✅ Successfully removed pool: $pool"
            
            # Clean drives
            if [[ -n "$drives" ]]; then
                while read -r drive; do
                    [[ -n "$drive" ]] && clean_drive "$drive"
                done <<< "$drives"
            fi
            
            ((success_count++))
        else
            log "ERROR" "❌ Failed to remove pool: $pool"
            failed_pools+=("$pool")
        fi
    done
    
    # Report results
    log "INFO" "Pool removal completed: $success_count successful, ${#failed_pools[@]} failed"
    [[ ${#failed_pools[@]} -gt 0 ]] && {
        log "WARN" "Failed pools: ${failed_pools[*]}"
    }
}

# Remove all pools (force mode)
remove_all_pools() {
    local force="$1"
    local pools
    pools=$(get_zfs_pools)
    
    if [[ -z "$pools" ]]; then
        log "INFO" "No ZFS pools found to remove"
        return 0
    fi
    
    log "WARN" "Force mode: Removing ALL ZFS pools"
    
    if [[ "$force" != "true" ]]; then
        echo
        log "WARN" "⚠️ This will permanently destroy ALL ZFS pools and data!"
        read -p "Continue? (y/N): " -r confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && { log "INFO" "Cancelled"; return 0; }
    fi
    
    declare -a pool_array=()
    while read -r pool; do
        [[ -n "$pool" ]] && pool_array+=("$pool")
    done <<< "$pools"
    
    remove_selected_pools "${pool_array[@]}"
}

# Show help
show_help() {
    cat << 'EOF'
Usage: remove-mirrors.sh [OPTIONS]

Remove ZFS pools and clean up Proxmox storage configurations.

OPTIONS:
    --interactive, -i    Select specific pools to remove (default)
    --force             Remove ALL pools without confirmation
    --status            Show current ZFS status and exit
    --help, -h          Show this help message

EXAMPLES:
    remove-mirrors.sh                    # Interactive pool selection
    remove-mirrors.sh --status           # Show current ZFS pools
    remove-mirrors.sh --force            # Remove ALL pools (dangerous)

SAFETY:
    - Interactive mode allows selective pool removal
    - Force mode removes ALL pools including system pools
    - Data is permanently destroyed when pools are removed
    - Proxmox storage configurations are automatically cleaned up
    - Drives are wiped clean for reuse

WARNING:
    Removing system pools can make your system unbootable!
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
    
    log "INFO" "Starting ZFS pool removal process..."
    
    # Show current status
    show_zfs_status
    echo
    
    # Execute based on mode
    if [[ "$force" == "true" ]]; then
        remove_all_pools "true"
    else
        interactive_pool_selection
    fi
    
    echo
    show_zfs_status
    
    log "INFO" "✅ ZFS pool removal completed!"
    log "INFO" ""
    log "INFO" "Next steps:"
    log "INFO" "1. Run: ./install.sh --setup-mirrors  # To reconfigure drives"
    log "INFO" "2. Verify: zpool list                 # Check final ZFS status"
}

# Run main if executed directly
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"

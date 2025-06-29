#!/bin/bash

# Simplified mdadm Interface for Drive Setup
# Interactive tool for creating RAID arrays with mdadm

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source common functions
if [[ ! -f "$PROJECT_ROOT/lib/common.sh" ]]; then
    echo "[ERROR] Common library not found: $PROJECT_ROOT/lib/common.sh" >&2
    exit 1
fi
# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/common.sh"

# Global variables
DRY_RUN=false

# Usage information
usage() {
    cat << EOF_USAGE
Usage: $0 [OPTIONS]

Interactive mdadm interface for RAID setup.

OPTIONS:
    -d, --dry-run          Show commands without executing
    -h, --help             Show this help message

DESCRIPTION:
    This script provides an interactive interface for setting up RAID arrays
    using mdadm. It will:
    
    1. Scan for available drives
    2. Ask what type of RAID you want to set up
    3. Let you select drives for the array
    4. Execute the mdadm commands (or show them with --dry-run)

SAFETY:
    - Always backup important data first
    - Use --dry-run to preview commands before execution
    - This will destroy data on selected drives

EOF_USAGE
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Detect available drives
detect_drives() {
    log "INFO" "Scanning for available drives..."
    
    # Get all block devices that are disks (not partitions)
    local drives=()
    while IFS= read -r line; do
        local name size model
        read -r name size _ model <<< "$line"
        local drive="/dev/$name"
        
        # Skip if not a block device or if it's a partition
        if [[ ! -b "$drive" ]] || [[ "$name" =~ [0-9]+$ ]]; then
            continue
        fi
        
        # Skip loop, ram, and other virtual devices
        if [[ "$name" =~ ^(loop|ram|dm-|sr) ]]; then
            continue
        fi
        
        # Check if drive is in use
        local status=""
        if mount | grep -q "^$drive"; then
            status=" [MOUNTED]"
        elif grep -q "$(basename "$drive")" /proc/mdstat 2>/dev/null; then
            status=" [IN RAID]"
        elif command -v pvdisplay >/dev/null 2>&1 && pvdisplay 2>/dev/null | grep -q "$drive"; then
            status=" [IN LVM]"
        fi
        
        drives+=("$drive:$size:$model$status")
        log "INFO" "  Found: $drive ($size) - $model$status"
    done < <(lsblk -dn -o NAME,SIZE,TYPE,MODEL 2>/dev/null || true)
    
    if [[ ${#drives[@]} -eq 0 ]]; then
        log "WARNING" "No suitable drives found for new RAID arrays"
        log "INFO" "All drives appear to be in use or partitioned"
        return 1
    fi
    
    printf "%s\n" "${drives[@]}"
}

# Show current RAID status
show_raid_status() {
    log "INFO" "Current RAID arrays:"
    if [[ -f /proc/mdstat ]] && grep -q "^md" /proc/mdstat 2>/dev/null; then
        cat /proc/mdstat
    else
        log "INFO" "  No RAID arrays found"
    fi
    echo
}

# Get RAID level choice from user
get_raid_level() {
    echo "Available RAID levels:"
    echo "  1) RAID 0 (Stripe) - No redundancy, maximum performance"
    echo "  2) RAID 1 (Mirror) - 2 drives, full redundancy"
    echo "  3) RAID 5 (Parity) - 3+ drives, single drive failure tolerance"
    echo "  4) RAID 6 (Double Parity) - 4+ drives, dual drive failure tolerance"
    echo "  5) RAID 10 (Stripe+Mirror) - 4+ drives (even number), fast + redundant"
    echo "  6) Linear - Concatenate drives (no striping)"
    echo
    
    local choice
    while true; do
        read -p "Select RAID level (1-6): " choice
        case $choice in
            1) echo "0"; return ;;
            2) echo "1"; return ;;
            3) echo "5"; return ;;
            4) echo "6"; return ;;
            5) echo "10"; return ;;
            6) echo "linear"; return ;;
            *) echo "Invalid choice. Please select 1-6." ;;
        esac
    done
}

# Main menu
main_menu() {
    while true; do
        echo
        log "INFO" "=== mdadm RAID Management ==="
        echo "1) Show current RAID status"
        echo "2) Create new RAID array"
        echo "3) Stop/remove RAID array"
        echo "4) Show drive information"
        echo "5) Exit"
        echo
        
        local choice
        read -p "Select option (1-5): " choice
        
        case $choice in
            1)
                show_raid_status
                ;;
            2)
                log "INFO" "RAID creation functionality - implement as needed"
                ;;
            3)
                log "INFO" "RAID stop functionality - implement as needed"
                ;;
            4)
                log "INFO" "=== Drive Information ==="
                echo "Block devices:"
                lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,MODEL 2>/dev/null || echo "lsblk not available"
                echo
                echo "Available drives for RAID:"
                if ! detect_drives; then
                    log "INFO" "💡 Tips for RAID setup:"
                    log "INFO" "  • Drives with existing partitions/data cannot be used for new RAID"
                    log "INFO" "  • To reuse drives, you would need to wipe them first (DESTROYS DATA)"
                    log "INFO" "  • Consider adding new drives for RAID arrays"
                fi
                ;;
            5)
                log "INFO" "Exiting"
                exit 0
                ;;
            *)
                log "ERROR" "Invalid choice"
                ;;
        esac
        
        echo
        read -p "Press Enter to continue..."
    done
}

# Main function
main() {
    parse_args "$@"
    
    # Check if mdadm is installed
    if ! command -v mdadm >/dev/null 2>&1; then
        log "ERROR" "mdadm is not installed. Install it with: apt install mdadm"
        exit 1
    fi
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "This script must be run as root"
        exit 1
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "INFO" "Running in DRY RUN mode - no changes will be made"
    fi
    
    main_menu
}

# Run main function
main "$@"

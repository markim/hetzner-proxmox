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
FORCE=false
COMMAND=""
COMMAND_ARGS=()

# Usage information
usage() {
    cat << EOF_USAGE
Usage: $0 [OPTIONS] [COMMAND]

Interactive mdadm interface for RAID setup, or command-line mode.

OPTIONS:
    -d, --dry-run          Show commands without executing
    -f, --force            Skip confirmation prompts (dangerous!)
    -h, --help             Show this help message

COMMANDS:
    list                   List all drives and current RAID status
    clear-all              Stop and remove all RAID arrays
    clear ARRAY            Stop and remove specific RAID array (e.g., /dev/md0)
    create LEVEL DRIVES    Create RAID array with specified level and drives
    
RAID LEVELS:
    0, 1, 5, 6, 10, linear

EXAMPLES:
    $0                                    # Interactive mode
    $0 list                               # List drives and RAID status
    $0 clear-all                          # Remove all RAID arrays
    $0 clear /dev/md0                     # Remove specific array
    $0 create 1 /dev/nvme1n1 /dev/nvme2n1 # Create RAID 1 mirror with two drives
    $0 create 1 /dev/sda /dev/sdb         # Create RAID 1 mirror with SATA drives
    $0 create 5 /dev/sd{a,b,c}            # Create RAID 5 with three drives
    $0 --dry-run create 1 /dev/sd{a,b}    # Preview RAID 1 creation

COMMON MIRRORING SCENARIOS:
    Data drives:
        $0 create 1 /dev/sdb /dev/sdc     # Mirror two data drives
    
    Multiple data drives:
        $0 create 10 /dev/sd{b,c,d,e}     # RAID 10 for performance + redundancy
    
    Check if drive can be mirrored:
        $0 list                           # See current drive usage

SAFETY:
    - Always backup important data first
    - Use --dry-run to preview commands before execution
    - Use --force to skip confirmation prompts (be careful!)
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
            -f|--force)
                FORCE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            list|clear-all|clear|create)
                COMMAND="$1"
                shift
                # Collect remaining arguments for the command
                COMMAND_ARGS=("$@")
                break
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# List drives and RAID status
cmd_list() {
    log "INFO" "=== System Drive and RAID Status ==="
    echo
    
    log "INFO" "Block devices:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,MODEL 2>/dev/null || echo "lsblk not available"
    echo
    
    log "INFO" "Current RAID arrays:"
    if [[ -f /proc/mdstat ]] && grep -q "^md" /proc/mdstat 2>/dev/null; then
        cat /proc/mdstat
    else
        log "INFO" "  No RAID arrays found"
    fi
    echo
    
    log "INFO" "Available drives for new RAID:"
    if ! detect_drives >/dev/null 2>&1; then
        log "INFO" "💡 All drives appear to be in use or partitioned"
    else
        detect_drives | while IFS= read -r drive_info; do
            local drive size model status
            drive=$(echo "$drive_info" | cut -d: -f1)
            size=$(echo "$drive_info" | cut -d: -f2)
            model=$(echo "$drive_info" | cut -d: -f3-)
            log "INFO" "  Found: $drive ($size) - $model"
        done
    fi
}

# Clear all RAID arrays
cmd_clear_all() {
    log "INFO" "=== Clear All RAID Arrays ==="
    
    if [[ ! -f /proc/mdstat ]] || ! grep -q "^md" /proc/mdstat 2>/dev/null; then
        log "INFO" "No RAID arrays to clear"
        return 0
    fi
    
    # Get list of arrays
    local arrays=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^(md[0-9]+) ]]; then
            arrays+=("/dev/${BASH_REMATCH[1]}")
        fi
    done < /proc/mdstat
    
    if [[ ${#arrays[@]} -eq 0 ]]; then
        log "INFO" "No arrays found to clear"
        return 0
    fi
    
    log "WARNING" "This will stop and remove ALL RAID arrays:"
    for array in "${arrays[@]}"; do
        log "WARNING" "  $array"
    done
    
    if [[ "$FORCE" != "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
        read -r -p "Type 'YES' to confirm: " confirmation
        if [[ "$confirmation" != "YES" ]]; then
            log "INFO" "Operation cancelled"
            return 1
        fi
    fi
    
    # Stop each array
    for array in "${arrays[@]}"; do
        cmd_clear_single "$array"
    done
    
    log "INFO" "✅ All RAID arrays cleared"
}

# Clear single RAID array
cmd_clear_single() {
    local array="$1"
    
    if [[ -z "$array" ]]; then
        log "ERROR" "No array specified for clearing"
        return 1
    fi
    
    # Validate array exists
    if [[ ! -e "$array" ]] && [[ ! -f /proc/mdstat ]] || ! grep -q "$(basename "$array")" /proc/mdstat 2>/dev/null; then
        log "ERROR" "Array $array not found"
        return 1
    fi
    
    log "INFO" "Clearing RAID array: $array"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "INFO" "[DRY RUN] Would stop array: $array"
        log "INFO" "[DRY RUN] Would remove from mdadm.conf"
        return 0
    fi
    
    # Stop the array
    if mdadm --stop "$array" 2>/dev/null; then
        log "INFO" "✅ Array $array stopped successfully"
    else
        log "WARNING" "Failed to stop $array (may already be stopped)"
    fi
    
    # Remove from mdadm.conf if it exists
    if [[ -f /etc/mdadm/mdadm.conf ]]; then
        log "INFO" "Removing from /etc/mdadm/mdadm.conf..."
        if grep -q "$array" /etc/mdadm/mdadm.conf; then
            grep -v "$array" /etc/mdadm/mdadm.conf > /tmp/mdadm.conf.new
            mv /tmp/mdadm.conf.new /etc/mdadm/mdadm.conf
        fi
    fi
}

# Create RAID array
cmd_create() {
    local raid_level="$1"
    shift
    local drives=("$@")
    
    if [[ -z "$raid_level" ]] || [[ ${#drives[@]} -eq 0 ]]; then
        log "ERROR" "Usage: create LEVEL DRIVE1 DRIVE2 [DRIVE3...]"
        log "ERROR" "Example: create 1 /dev/nvme1n1 /dev/nvme2n1"
        return 1
    fi
    
    # Validate RAID level
    case "$raid_level" in
        0|1|5|6|10|linear) ;;
        *)
            log "ERROR" "Invalid RAID level: $raid_level"
            log "ERROR" "Valid levels: 0, 1, 5, 6, 10, linear"
            return 1
            ;;
    esac
    
    # Validate minimum drives for RAID level
    local min_drives
    case "$raid_level" in
        "0"|"1"|"linear") min_drives=2 ;;
        "5") min_drives=3 ;;
        "6"|"10") min_drives=4 ;;
    esac
    
    if [[ ${#drives[@]} -lt $min_drives ]]; then
        log "ERROR" "RAID $raid_level requires at least $min_drives drives. Provided: ${#drives[@]}"
        return 1
    fi
    
    # Special validation for RAID 10 (must be even number of drives)
    if [[ "$raid_level" == "10" ]] && [[ $((${#drives[@]} % 2)) -ne 0 ]]; then
        log "ERROR" "RAID 10 requires an even number of drives. Provided: ${#drives[@]}"
        return 1
    fi
    
    # Validate drives exist
    for drive in "${drives[@]}"; do
        if [[ ! -b "$drive" ]]; then
            log "ERROR" "Drive $drive does not exist or is not a block device"
            return 1
        fi
    done
    
    # Find next available md device
    local i=0
    while [[ -e "/dev/md$i" ]]; do
        ((i++))
    done
    local array_name="/dev/md$i"
    
    log "INFO" "Creating RAID $raid_level array $array_name with drives: ${drives[*]}"
    
    # Check if drives are busy
    local busy_drives=()
    for drive in "${drives[@]}"; do
        if mount | grep -q "^$drive"; then
            busy_drives+=("$drive [MOUNTED]")
        elif grep -q "$(basename "$drive")" /proc/mdstat 2>/dev/null; then
            busy_drives+=("$drive [IN RAID]")
        elif command -v pvdisplay >/dev/null 2>&1 && pvdisplay 2>/dev/null | grep -q "$drive"; then
            busy_drives+=("$drive [IN LVM]")
        fi
    done
    
    if [[ ${#busy_drives[@]} -gt 0 ]]; then
        log "ERROR" "Some drives are in use:"
        for busy in "${busy_drives[@]}"; do
            log "ERROR" "  $busy"
        done
        log "ERROR" "Cannot create RAID with drives that are in use"
        return 1
    fi
    
    # Confirm destructive operation
    if [[ "$FORCE" != "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
        log "WARNING" "This will DESTROY all data on the selected drives!"
        log "WARNING" "Drives: ${drives[*]}"
        read -r -p "Type 'YES' to confirm: " confirmation
        if [[ "$confirmation" != "YES" ]]; then
            log "INFO" "Operation cancelled"
            return 1
        fi
    fi
    
    # Prepare drives (wipe signatures)
    for drive in "${drives[@]}"; do
        local cmd="wipefs -fa $drive"
        if [[ "$DRY_RUN" == "true" ]]; then
            log "INFO" "[DRY RUN] Would run: $cmd"
        else
            log "INFO" "Wiping $drive..."
            if ! $cmd; then
                log "ERROR" "Failed to wipe $drive"
                return 1
            fi
        fi
    done
    
    # Build mdadm command
    local mdadm_cmd="mdadm --create $array_name --level=$raid_level --raid-devices=${#drives[@]}"
    
    # Add drives to command
    for drive in "${drives[@]}"; do
        mdadm_cmd="$mdadm_cmd $drive"
    done
    
    # Execute or show command
    if [[ "$DRY_RUN" == "true" ]]; then
        log "INFO" "[DRY RUN] Would run: $mdadm_cmd"
        log "INFO" "[DRY RUN] Array $array_name would be created with RAID level $raid_level"
    else
        log "INFO" "Creating RAID array..."
        if $mdadm_cmd; then
            log "INFO" "✅ RAID array $array_name created successfully"
            
            # Show array details
            log "INFO" "Array details:"
            mdadm --detail "$array_name" || log "WARNING" "Could not show array details"
            
            # Update mdadm.conf
            if [[ -f /etc/mdadm/mdadm.conf ]]; then
                log "INFO" "Updating /etc/mdadm/mdadm.conf..."
                mdadm --detail --scan >> /etc/mdadm/mdadm.conf
            fi
        else
            log "ERROR" "Failed to create RAID array"
            return 1
        fi
    fi
}

# Detect available drives
detect_drives() {
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
    done < <(lsblk -dn -o NAME,SIZE,TYPE,MODEL 2>/dev/null || true)
    
    if [[ ${#drives[@]} -eq 0 ]]; then
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
        read -r -p "Select RAID level (1-6): " choice
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

# Interactive RAID creation
interactive_create_raid() {
    log "INFO" "=== Create New RAID Array ==="
    
    # Check for available drives
    log "INFO" "Scanning for available drives..."
    local available_drives=()
    while IFS= read -r drive_info; do
        local drive
        drive=$(echo "$drive_info" | cut -d: -f1)
        # Only include drives not in use
        if [[ ! "$drive_info" =~ \[(MOUNTED|IN\ RAID|IN\ LVM)\] ]]; then
            available_drives+=("$drive_info")
        fi
    done < <(detect_drives 2>/dev/null || true)
    
    if [[ ${#available_drives[@]} -eq 0 ]]; then
        log "ERROR" "No available drives found for RAID creation"
        log "INFO" "All drives appear to be in use. Consider:"
        log "INFO" "  • Adding new drives to the system"
        log "INFO" "  • Removing existing RAID arrays if no longer needed"
        log "INFO" "  • Backing up and wiping drives to reuse them"
        return 1
    fi
    
    log "INFO" "Available drives for RAID:"
    for i in "${!available_drives[@]}"; do
        local drive_info="${available_drives[$i]}"
        local drive size model
        drive=$(echo "$drive_info" | cut -d: -f1)
        size=$(echo "$drive_info" | cut -d: -f2)
        model=$(echo "$drive_info" | cut -d: -f3)
        printf "%2d) %s (%s) - %s\n" $((i+1)) "$drive" "$size" "$model"
    done
    echo
    
    # Get RAID level
    local raid_level
    raid_level=$(get_raid_level)
    
    # Determine minimum drives required
    local min_drives=2
    case "$raid_level" in
        "0"|"1"|"linear") min_drives=2 ;;
        "5") min_drives=3 ;;
        "6"|"10") min_drives=4 ;;
    esac
    
    if [[ ${#available_drives[@]} -lt $min_drives ]]; then
        log "ERROR" "RAID $raid_level requires at least $min_drives drives"
        log "ERROR" "Only ${#available_drives[@]} available drives found"
        return 1
    fi
    
    # Select drives
    log "INFO" "Select drives for RAID $raid_level (minimum $min_drives):"
    local selected_drives=()
    local drive_indices=()
    
    while true; do
        if [[ ${#selected_drives[@]} -gt 0 ]]; then
            echo "Selected drives: ${selected_drives[*]}"
        fi
        
        if [[ ${#selected_drives[@]} -ge $min_drives ]]; then
            read -r -p "Enter drive number (1-${#available_drives[@]}) or 'done' to proceed: " input
        else
            read -r -p "Enter drive number (1-${#available_drives[@]}): " input
        fi
        
        if [[ "$input" == "done" ]] && [[ ${#selected_drives[@]} -ge $min_drives ]]; then
            break
        elif [[ "$input" =~ ^[0-9]+$ ]] && [[ "$input" -ge 1 ]] && [[ "$input" -le ${#available_drives[@]} ]]; then
            local idx=$((input-1))
            local drive_info="${available_drives[$idx]}"
            local drive
            drive=$(echo "$drive_info" | cut -d: -f1)
            
            # Check if already selected
            if [[ " ${drive_indices[*]} " =~ [[:space:]]${idx}[[:space:]] ]]; then
                log "WARNING" "Drive $drive already selected"
                continue
            fi
            
            # Special check for RAID 10 - must be even number
            if [[ "$raid_level" == "10" ]] && [[ ${#selected_drives[@]} -ge 4 ]] && [[ $(((${#selected_drives[@]} + 1) % 2)) -ne 0 ]]; then
                log "WARNING" "RAID 10 requires an even number of drives"
                continue
            fi
            
            selected_drives+=("$drive")
            drive_indices+=("$idx")
            log "INFO" "Added $drive to selection"
        else
            if [[ ${#selected_drives[@]} -lt $min_drives ]]; then
                log "ERROR" "Invalid selection. Need at least $min_drives drives for RAID $raid_level"
            else
                log "ERROR" "Invalid input. Enter a number or 'done'"
            fi
        fi
    done
    
    # Final validation for RAID 10
    if [[ "$raid_level" == "10" ]] && [[ $((${#selected_drives[@]} % 2)) -ne 0 ]]; then
        log "ERROR" "RAID 10 requires an even number of drives. Selected: ${#selected_drives[@]}"
        return 1
    fi
    
    # Show summary and confirm
    echo
    log "INFO" "RAID Configuration Summary:"
    log "INFO" "  RAID Level: $raid_level"
    log "INFO" "  Number of drives: ${#selected_drives[@]}"
    log "INFO" "  Drives: ${selected_drives[*]}"
    echo
    log "WARNING" "This will DESTROY all data on the selected drives!"
    
    if [[ "$FORCE" != "true" ]]; then
        read -r -p "Type 'YES' to confirm: " confirmation
        if [[ "$confirmation" != "YES" ]]; then
            log "INFO" "Operation cancelled"
            return 1
        fi
    fi
    
    # Create the RAID array
    cmd_create "$raid_level" "${selected_drives[@]}"
}

# Interactive RAID removal
interactive_remove_raid() {
    log "INFO" "=== Remove RAID Array ==="
    
    # Check for existing arrays
    if [[ ! -f /proc/mdstat ]] || ! grep -q "^md" /proc/mdstat 2>/dev/null; then
        log "INFO" "No RAID arrays found to remove"
        return 0
    fi
    
    # Get list of arrays
    local arrays=()
    local array_info=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^(md[0-9]+) ]]; then
            local array_name="/dev/${BASH_REMATCH[1]}"
            arrays+=("$array_name")
            
            # Get additional info if possible
            local info=""
            if command -v mdadm >/dev/null 2>&1; then
                info=$(mdadm --detail "$array_name" 2>/dev/null | grep -E "(RAID Level|Array Size)" | tr '\n' ' ' || echo "")
            fi
            array_info+=("$info")
        fi
    done < /proc/mdstat
    
    if [[ ${#arrays[@]} -eq 0 ]]; then
        log "INFO" "No RAID arrays found"
        return 0
    fi
    
    # Show current arrays
    log "INFO" "Current RAID arrays:"
    for i in "${!arrays[@]}"; do
        printf "%2d) %s %s\n" $((i+1)) "${arrays[$i]}" "${array_info[$i]}"
    done
    echo
    printf "%2d) Remove ALL arrays\n" $((${#arrays[@]}+1))
    echo
    
    # Get selection
    local choice
    while true; do
        read -r -p "Select array to remove (1-$((${#arrays[@]}+1))): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le $((${#arrays[@]}+1)) ]]; then
            break
        else
            log "ERROR" "Invalid choice. Please select 1-$((${#arrays[@]}+1))"
        fi
    done
    
    if [[ "$choice" -eq $((${#arrays[@]}+1)) ]]; then
        # Remove all arrays
        cmd_clear_all
    else
        # Remove specific array
        local array_to_remove="${arrays[$((choice-1))]}"
        cmd_clear_single "$array_to_remove"
    fi
}

# Check if a drive can be mirrored
check_mirror_capability() {
    local drive="$1"
    
    if [[ -z "$drive" ]]; then
        log "ERROR" "No drive specified"
        return 1
    fi
    
    # Check if drive exists
    if [[ ! -b "$drive" ]]; then
        log "ERROR" "Drive $drive does not exist"
        return 1
    fi
    
    # Check current status
    local status=""
    if mount | grep -q "^$drive"; then
        status="MOUNTED"
    elif grep -q "$(basename "$drive")" /proc/mdstat 2>/dev/null; then
        status="IN_RAID"
        # Get RAID details
        local md_device
        md_device=$(grep -l "$(basename "$drive")" /sys/block/md*/md/raid_disks 2>/dev/null | head -1)
        if [[ -n "$md_device" ]]; then
            local array_name raid_level
            array_name="/dev/$(basename "$(dirname "$(dirname "$md_device")")")"
            raid_level=$(cat "$(dirname "$md_device")/level" 2>/dev/null || echo "unknown")
            log "INFO" "Drive $drive is part of $array_name (RAID $raid_level)"
        fi
    elif command -v pvdisplay >/dev/null 2>&1 && pvdisplay 2>/dev/null | grep -q "$drive"; then
        status="IN_LVM"
    else
        status="AVAILABLE"
    fi
    
    log "INFO" "Drive $drive status: $status"
    
    case "$status" in
        "AVAILABLE")
            log "INFO" "✅ Drive can be used for new RAID array"
            return 0
            ;;
        "IN_RAID")
            log "INFO" "⚠️  Drive is already in a RAID array"
            log "INFO" "   To mirror this, you would need to convert/migrate the existing array"
            return 1
            ;;
        "MOUNTED")
            log "INFO" "⚠️  Drive is mounted and in use"
            log "INFO" "   To mirror this, you would need to:"
            log "INFO" "   1. Backup the data"
            log "INFO" "   2. Unmount the drive"
            log "INFO" "   3. Create a RAID 1 array"
            log "INFO" "   4. Restore the data"
            return 1
            ;;
        "IN_LVM")
            log "INFO" "⚠️  Drive is part of LVM"
            log "INFO" "   LVM can provide mirroring functionality"
            return 1
            ;;
    esac
}

# Quick mirror setup for system drive
quick_mirror_setup() {
    log "INFO" "=== Quick System Drive Mirroring Setup ==="
    log "WARNING" "This is for reference only - actual system drive mirroring"
    log "WARNING" "requires careful planning and usually involves:"
    log "WARNING" "1. Backing up all data first"
    log "WARNING" "2. Using specialized tools or procedures"
    log "WARNING" "3. Potentially reinstalling the system"
    echo
    
    # Show current root filesystem
    local root_device
    root_device=$(df / | tail -1 | awk '{print $1}')
    log "INFO" "Current root filesystem: $root_device"
    
    # Check what type of device this is
    if [[ "$root_device" =~ /dev/md ]]; then
        log "INFO" "✅ Root is already on RAID device: $root_device"
        mdadm --detail "$root_device" 2>/dev/null || log "WARNING" "Could not get RAID details"
    elif [[ "$root_device" =~ /dev/mapper/ ]]; then
        log "INFO" "Root is on LVM device: $root_device"
        log "INFO" "Consider using LVM mirroring instead of mdadm"
    else
        log "INFO" "Root is on regular partition: $root_device"
        local base_device
        base_device="${root_device%[0-9]*}"
        log "INFO" "Base device: $base_device"
        
        log "INFO" "To mirror the system drive, you would typically:"
        log "INFO" "1. Add a second drive of equal or larger size"
        log "INFO" "2. Create a degraded RAID 1 array on the new drive"
        log "INFO" "3. Copy the system to the RAID array"
        log "INFO" "4. Update bootloader and fstab"
        log "INFO" "5. Add the original drive to complete the mirror"
        log "INFO" "⚠️  This process is complex and risky - consider professional assistance"
    fi
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
        echo "5) Check drive mirror capability"
        echo "6) System drive mirroring guide"
        echo "7) Exit"
        echo
        
        local choice
        read -r -p "Select option (1-7): " choice
        
        case $choice in
            1)
                show_raid_status
                ;;
            2)
                interactive_create_raid
                ;;
            3)
                interactive_remove_raid
                ;;
            4)
                log "INFO" "=== Drive Information ==="
                echo "Block devices:"
                lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,MODEL 2>/dev/null || echo "lsblk not available"
                echo
                echo "Available drives for RAID:"
                if ! detect_drives >/dev/null 2>&1; then
                    log "INFO" "💡 Tips for RAID setup:"
                    log "INFO" "  • Drives with existing partitions/data cannot be used for new RAID"
                    log "INFO" "  • To reuse drives, you would need to wipe them first (DESTROYS DATA)"
                    log "INFO" "  • Consider adding new drives for RAID arrays"
                else
                    detect_drives | while IFS= read -r drive_info; do
                        local drive size model
                        drive=$(echo "$drive_info" | cut -d: -f1)
                        size=$(echo "$drive_info" | cut -d: -f2)
                        model=$(echo "$drive_info" | cut -d: -f3-)
                        log "INFO" "  Found: $drive ($size) - $model"
                    done
                fi
                ;;
            5)
                echo
                read -r -p "Enter drive path (e.g., /dev/sda, /dev/nvme0n1): " drive_path
                if [[ -n "$drive_path" ]]; then
                    check_mirror_capability "$drive_path"
                else
                    log "ERROR" "No drive path provided"
                fi
                ;;
            6)
                quick_mirror_setup
                ;;
            7)
                log "INFO" "Exiting"
                exit 0
                ;;
            *)
                log "ERROR" "Invalid choice"
                ;;
        esac
        
        echo
        read -r -p "Press Enter to continue..."
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
    
    # Handle command-line mode
    if [[ -n "$COMMAND" ]]; then
        case "$COMMAND" in
            list)
                cmd_list
                ;;
            clear-all)
                cmd_clear_all
                ;;
            clear)
                if [[ ${#COMMAND_ARGS[@]} -eq 0 ]]; then
                    log "ERROR" "Usage: clear ARRAY_NAME"
                    log "ERROR" "Example: clear /dev/md0"
                    exit 1
                fi
                cmd_clear_single "${COMMAND_ARGS[0]}"
                ;;
            create)
                if [[ ${#COMMAND_ARGS[@]} -lt 2 ]]; then
                    log "ERROR" "Usage: create LEVEL DRIVE1 DRIVE2 [DRIVE3...]"
                    log "ERROR" "Example: create 1 /dev/nvme1n1 /dev/nvme2n1"
                    exit 1
                fi
                cmd_create "${COMMAND_ARGS[@]}"
                ;;
            *)
                log "ERROR" "Unknown command: $COMMAND"
                usage
                exit 1
                ;;
        esac
    else
        # Interactive mode
        main_menu
    fi
}

# Run main function
main "$@"

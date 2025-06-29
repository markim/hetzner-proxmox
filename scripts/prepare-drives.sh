#!/bin/bash

# LVM Mirroring Interface for Drive Setup
# Interactive tool for creating LVM mirrored volumes

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

Interactive LVM mirroring interface for drive setup, or command-line mode.

OPTIONS:
    -d, --dry-run          Show commands without executing
    -f, --force            Skip confirmation prompts (dangerous!)
    -h, --help             Show this help message

COMMANDS:
    list                   List all drives and current LVM status
    clear-all              Remove all LVM mirrors
    clear VG/LV            Remove specific mirror (e.g., data/storage)
    create VG LV DRIVES    Create mirrored LV with specified VG, LV name and drives
    
EXAMPLES:
    $0                                    # Interactive mode
    $0 list                               # List drives and LVM status
    $0 clear-all                          # Remove all LVM volumes
    $0 clear data/storage                 # Remove specific volume
    $0 create data storage /dev/sdb /dev/sdc  # Create mirrored LV 'storage' in VG 'data'
    $0 --dry-run create data storage /dev/sd{b,c}  # Preview mirror creation

COMMON MIRRORING SCENARIOS:
    Data drives:
        $0 create data storage /dev/sdb /dev/sdc  # Mirror two data drives
    
    Multiple volumes:
        $0 create data vol1 /dev/sdb /dev/sdc     # First mirrored volume
        # Then extend the same VG with more drives for additional volumes
    
    Check current setup:
        $0 list                                   # See current LVM status

SAFETY:
    - Always backup important data first
    - Use --dry-run to preview commands before execution
    - Use --force to skip confirmation prompts (be careful!)
    - This will destroy data on selected drives

LVM ADVANTAGES:
    - Simpler management than mdadm
    - Better integration with modern systems
    - Easier to resize and manage
    - Built-in snapshot capabilities

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

# List drives and LVM status
cmd_list() {
    log "INFO" "=== System Drive and LVM Status ==="
    echo
    
    log "INFO" "Block devices:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,MODEL 2>/dev/null || echo "lsblk not available"
    echo
    
    log "INFO" "LVM Physical Volumes:"
    if command -v pvdisplay >/dev/null 2>&1; then
        if pvs --noheadings 2>/dev/null | grep -q .; then
            pvs -o +pv_used,pv_free,attr 2>/dev/null || pvs 2>/dev/null
        else
            log "INFO" "  No LVM physical volumes found"
        fi
    else
        log "WARNING" "LVM tools not available"
    fi
    echo
    
    log "INFO" "LVM Volume Groups:"
    if command -v vgdisplay >/dev/null 2>&1; then
        if vgs --noheadings 2>/dev/null | grep -q .; then
            vgs -o +vg_free 2>/dev/null || vgs 2>/dev/null
        else
            log "INFO" "  No LVM volume groups found"
        fi
    else
        log "WARNING" "LVM tools not available"
    fi
    echo
    
    log "INFO" "LVM Logical Volumes:"
    if command -v lvdisplay >/dev/null 2>&1; then
        if lvs --noheadings 2>/dev/null | grep -q .; then
            lvs -o +lv_layout,mirror_log,copy_percent,convert_lv 2>/dev/null || lvs 2>/dev/null
            echo
            
            # Show detailed information for mirrored volumes
            log "INFO" "Detailed mirror information:"
            while IFS= read -r line; do
                local vg lv attr
                read -r lv vg attr _ <<< "$line"
                if [[ "$attr" =~ m.*$ ]]; then  # 'm' indicates mirrored
                    echo "--- /dev/$vg/$lv (MIRRORED) ---"
                    lvdisplay "/dev/$vg/$lv" 2>/dev/null | grep -E "(LV Status|LV Size|Current LE|Mirrored volumes|Mirror status)" || true
                    echo
                fi
            done < <(lvs --noheadings -o lv_name,vg_name,lv_attr 2>/dev/null || true)
        else
            log "INFO" "  No LVM logical volumes found"
        fi
    else
        log "WARNING" "LVM tools not available"
    fi
    
    log "INFO" "Available drives for new mirrors:"
    local available_drives=()
    while IFS= read -r drive_info; do
        local drive
        drive=$(echo "$drive_info" | cut -d: -f1)
        # Only include drives not in use
        if [[ ! "$drive_info" =~ \[(MOUNTED|IN\ LVM|IN\ RAID)\] ]]; then
            available_drives+=("$drive_info")
        fi
    done < <(detect_drives 2>/dev/null || true)
    
    if [[ ${#available_drives[@]} -eq 0 ]]; then
        log "INFO" "💡 All drives appear to be in use or partitioned"
    else
        for drive_info in "${available_drives[@]}"; do
            local drive size model
            drive=$(echo "$drive_info" | cut -d: -f1)
            size=$(echo "$drive_info" | cut -d: -f2)
            model=$(echo "$drive_info" | cut -d: -f3-)
            log "INFO" "  Available: $drive ($size) - $model"
        done
    fi
}

# Clear all LVM volumes
cmd_clear_all() {
    log "INFO" "=== Clear All LVM Volumes ==="
    
    # Check for existing LVs
    if ! command -v lvs >/dev/null 2>&1; then
        log "ERROR" "LVM tools not available"
        return 1
    fi
    
    local volumes=()
    while IFS= read -r line; do
        local lv vg
        read -r lv vg _ <<< "$line"
        if [[ -n "$lv" && -n "$vg" ]]; then
            volumes+=("$vg/$lv")
        fi
    done < <(lvs --noheadings -o lv_name,vg_name 2>/dev/null || true)
    
    if [[ ${#volumes[@]} -eq 0 ]]; then
        log "INFO" "No LVM volumes to clear"
        return 0
    fi
    
    log "WARNING" "This will remove ALL LVM volumes and volume groups:"
    for volume in "${volumes[@]}"; do
        log "WARNING" "  /dev/$volume"
    done
    
    if [[ "$FORCE" != "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
        read -r -p "Type 'YES' to confirm: " confirmation
        if [[ "$confirmation" != "YES" ]]; then
            log "INFO" "Operation cancelled"
            return 1
        fi
    fi
    
    # Remove each LV
    for volume in "${volumes[@]}"; do
        local lv_path="/dev/$volume"
        if [[ "$DRY_RUN" == "true" ]]; then
            log "INFO" "[DRY RUN] Would remove: $lv_path"
        else
            log "INFO" "Removing LV: $lv_path"
            if lvremove -f "$lv_path" 2>/dev/null; then
                log "INFO" "✅ LV $lv_path removed"
            else
                log "WARNING" "Failed to remove $lv_path"
            fi
        fi
    done
    
    # Remove volume groups
    local vgs_list=()
    while IFS= read -r line; do
        local vg
        read -r vg _ <<< "$line"
        if [[ -n "$vg" ]]; then
            vgs_list+=("$vg")
        fi
    done < <(vgs --noheadings -o vg_name 2>/dev/null || true)
    
    for vg in "${vgs_list[@]}"; do
        if [[ "$DRY_RUN" == "true" ]]; then
            log "INFO" "[DRY RUN] Would remove VG: $vg"
        else
            log "INFO" "Removing VG: $vg"
            if vgremove -f "$vg" 2>/dev/null; then
                log "INFO" "✅ VG $vg removed"
            else
                log "WARNING" "Failed to remove VG $vg"
            fi
        fi
    done
    
    # Remove physical volumes
    local pvs_list=()
    while IFS= read -r line; do
        local pv
        read -r pv _ <<< "$line"
        if [[ -n "$pv" ]]; then
            pvs_list+=("$pv")
        fi
    done < <(pvs --noheadings -o pv_name 2>/dev/null || true)
    
    for pv in "${pvs_list[@]}"; do
        if [[ "$DRY_RUN" == "true" ]]; then
            log "INFO" "[DRY RUN] Would remove PV: $pv"
        else
            log "INFO" "Removing PV: $pv"
            if pvremove -f "$pv" 2>/dev/null; then
                log "INFO" "✅ PV $pv removed"
            else
                log "WARNING" "Failed to remove PV $pv"
            fi
        fi
    done
    
    log "INFO" "✅ All LVM volumes cleared"
}

# Clear single LVM volume
cmd_clear_single() {
    local volume="$1"
    
    if [[ -z "$volume" ]]; then
        log "ERROR" "No volume specified for clearing (format: vg/lv)"
        return 1
    fi
    
    # Validate volume format (should be vg/lv)
    if [[ ! "$volume" =~ ^[^/]+/[^/]+$ ]]; then
        log "ERROR" "Invalid volume format. Use: vg_name/lv_name"
        return 1
    fi
    
    local lv_path="/dev/$volume"
    
    # Check if volume exists
    if ! lvs "$lv_path" >/dev/null 2>&1; then
        log "ERROR" "Volume $lv_path not found"
        return 1
    fi
    
    log "INFO" "Clearing LVM volume: $lv_path"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "INFO" "[DRY RUN] Would remove volume: $lv_path"
        return 0
    fi
    
    # Remove the logical volume
    if lvremove -f "$lv_path" 2>/dev/null; then
        log "INFO" "✅ Volume $lv_path removed successfully"
    else
        log "ERROR" "Failed to remove $lv_path"
        return 1
    fi
}

# Create LVM mirrored volume
cmd_create() {
    local vg_name="$1"
    local lv_name="$2"
    shift 2
    local drives=("$@")
    
    if [[ -z "$vg_name" ]] || [[ -z "$lv_name" ]] || [[ ${#drives[@]} -eq 0 ]]; then
        log "ERROR" "Usage: create VG_NAME LV_NAME DRIVE1 DRIVE2 [DRIVE3...]"
        log "ERROR" "Example: create data storage /dev/sdb /dev/sdc"
        return 1
    fi
    
    # Validate minimum drives for mirroring (need at least 2)
    if [[ ${#drives[@]} -lt 2 ]]; then
        log "ERROR" "LVM mirroring requires at least 2 drives. Provided: ${#drives[@]}"
        return 1
    fi
    
    # Validate drives exist
    for drive in "${drives[@]}"; do
        if [[ ! -b "$drive" ]]; then
            log "ERROR" "Drive $drive does not exist or is not a block device"
            return 1
        fi
    done
    
    log "INFO" "Creating LVM mirrored volume: $vg_name/$lv_name with drives: ${drives[*]}"
    
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
        log "ERROR" "Cannot create LVM mirror with drives that are in use"
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
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "INFO" "[DRY RUN] Would create physical volumes on: ${drives[*]}"
        log "INFO" "[DRY RUN] Would create volume group: $vg_name"
        log "INFO" "[DRY RUN] Would create mirrored logical volume: $lv_name"
        return 0
    fi
    
    # Create physical volumes
    log "INFO" "Creating physical volumes..."
    for drive in "${drives[@]}"; do
        if pvcreate "$drive"; then
            log "INFO" "✅ PV created on $drive"
        else
            log "ERROR" "Failed to create PV on $drive"
            return 1
        fi
    done
    
    # Create or extend volume group
    if vgs "$vg_name" >/dev/null 2>&1; then
        log "INFO" "Volume group $vg_name exists, extending with new drives..."
        if vgextend "$vg_name" "${drives[@]}"; then
            log "INFO" "✅ VG $vg_name extended"
        else
            log "ERROR" "Failed to extend VG $vg_name"
            return 1
        fi
    else
        log "INFO" "Creating volume group: $vg_name"
        if vgcreate "$vg_name" "${drives[@]}"; then
            log "INFO" "✅ VG $vg_name created"
        else
            log "ERROR" "Failed to create VG $vg_name"
            return 1
        fi
    fi
    
    # Calculate size for mirrored volume (use most of available space)
    local total_size
    total_size=$(vgs --noheadings --units g -o vg_free "$vg_name" | tr -d ' G' | cut -d. -f1)
    
    if [[ -z "$total_size" ]] || [[ "$total_size" -eq 0 ]]; then
        log "ERROR" "No free space available in VG $vg_name"
        return 1
    fi
    
    # Leave some space for metadata, use 95% of available
    local lv_size=$((total_size * 95 / 100))
    
    # Create mirrored logical volume
    local mirrors=$((${#drives[@]} - 1))  # Number of mirrors (copies - 1)
    log "INFO" "Creating mirrored LV: $lv_name (${lv_size}G, $mirrors mirrors)"
    
    if lvcreate -L "${lv_size}G" -m "$mirrors" -n "$lv_name" "$vg_name"; then
        log "INFO" "✅ Mirrored LV /dev/$vg_name/$lv_name created successfully"
        
        # Show volume details
        log "INFO" "Volume details:"
        lvdisplay "/dev/$vg_name/$lv_name" || log "WARNING" "Could not show volume details"
        
        # Show status
        log "INFO" "Mirror status:"
        lvs -o +lv_layout,copy_percent "/dev/$vg_name/$lv_name" || log "WARNING" "Could not show mirror status"
    else
        log "ERROR" "Failed to create mirrored LV"
        return 1
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
        elif command -v pvdisplay >/dev/null 2>&1 && pvdisplay 2>/dev/null | grep -q "$drive"; then
            status=" [IN LVM]"
        elif grep -q "$(basename "$drive")" /proc/mdstat 2>/dev/null; then
            status=" [IN RAID]"
        fi
        
        drives+=("$drive:$size:$model$status")
    done < <(lsblk -dn -o NAME,SIZE,TYPE,MODEL 2>/dev/null || true)
    
    if [[ ${#drives[@]} -eq 0 ]]; then
        return 1
    fi
    
    printf "%s\n" "${drives[@]}"
}

# Show current LVM status
show_lvm_status() {
    log "INFO" "Current LVM configuration:"
    
    # Show physical volumes
    if command -v pvdisplay >/dev/null 2>&1; then
        if pvs --noheadings 2>/dev/null | grep -q .; then
            log "INFO" "Physical Volumes:"
            pvs -o +pv_used,pv_free,attr 2>/dev/null || pvs 2>/dev/null
            echo
        else
            log "INFO" "  No LVM physical volumes found"
        fi
    else
        log "WARNING" "LVM tools not available"
        return 1
    fi
    
    # Show volume groups
    if vgs --noheadings 2>/dev/null | grep -q .; then
        log "INFO" "Volume Groups:"
        vgs -o +vg_free 2>/dev/null || vgs 2>/dev/null
        echo
    else
        log "INFO" "  No LVM volume groups found"
    fi
    
    # Show logical volumes with mirror information
    if lvs --noheadings 2>/dev/null | grep -q .; then
        log "INFO" "Logical Volumes:"
        lvs -o +lv_layout,mirror_log,copy_percent,convert_lv 2>/dev/null || lvs 2>/dev/null
        echo
        
        # Show detailed information for mirrored volumes
        log "INFO" "Mirror status details:"
        while IFS= read -r line; do
            local vg lv attr
            read -r lv vg attr _ <<< "$line"
            if [[ "$attr" =~ m.*$ ]]; then  # 'm' indicates mirrored
                echo "--- /dev/$vg/$lv (MIRRORED) ---"
                lvdisplay "/dev/$vg/$lv" 2>/dev/null | grep -E "(LV Status|LV Size|Current LE|Mirrored volumes|Mirror status)" || true
                echo
            fi
        done < <(lvs --noheadings -o lv_name,vg_name,lv_attr 2>/dev/null || true)
    else
        log "INFO" "  No LVM logical volumes found"
    fi
}

# Interactive LVM mirror creation
interactive_create_mirror() {
    log "INFO" "=== Create New LVM Mirror ==="
    
    # Check for available drives
    log "INFO" "Scanning for available drives..."
    local available_drives=()
    while IFS= read -r drive_info; do
        local drive
        drive=$(echo "$drive_info" | cut -d: -f1)
        # Only include drives not in use
        if [[ ! "$drive_info" =~ \[(MOUNTED|IN\ LVM|IN\ RAID)\] ]]; then
            available_drives+=("$drive_info")
        fi
    done < <(detect_drives 2>/dev/null || true)
    
    if [[ ${#available_drives[@]} -lt 2 ]]; then
        log "ERROR" "Need at least 2 available drives for LVM mirroring"
        log "INFO" "Available drives: ${#available_drives[@]}"
        if [[ ${#available_drives[@]} -gt 0 ]]; then
            log "INFO" "Available drives for LVM:"
            for drive_info in "${available_drives[@]}"; do
                local drive size model
                drive=$(echo "$drive_info" | cut -d: -f1)
                size=$(echo "$drive_info" | cut -d: -f2)
                model=$(echo "$drive_info" | cut -d: -f3)
                log "INFO" "  $drive ($size) - $model"
            done
        fi
        log "INFO" "Consider:"
        log "INFO" "  • Adding more drives to the system"
        log "INFO" "  • Removing existing LVM volumes if no longer needed"
        log "INFO" "  • Backing up and wiping drives to reuse them"
        return 1
    fi
    
    log "INFO" "Available drives for LVM mirror:"
    for i in "${!available_drives[@]}"; do
        local drive_info="${available_drives[$i]}"
        local drive size model
        drive=$(echo "$drive_info" | cut -d: -f1)
        size=$(echo "$drive_info" | cut -d: -f2)
        model=$(echo "$drive_info" | cut -d: -f3)
        printf "%2d) %s (%s) - %s\n" $((i+1)) "$drive" "$size" "$model"
    done
    echo
    
    # Get volume group name
    local vg_name
    read -r -p "Enter volume group name (e.g., 'data'): " vg_name
    if [[ -z "$vg_name" ]] || [[ ! "$vg_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log "ERROR" "Invalid volume group name. Use only letters, numbers, underscore, and dash."
        return 1
    fi
    
    # Get logical volume name
    local lv_name
    read -r -p "Enter logical volume name (e.g., 'storage'): " lv_name
    if [[ -z "$lv_name" ]] || [[ ! "$lv_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log "ERROR" "Invalid logical volume name. Use only letters, numbers, underscore, and dash."
        return 1
    fi
    
    # Select drives
    log "INFO" "Select drives for LVM mirror (minimum 2):"
    local selected_drives=()
    local drive_indices=()
    
    while [[ ${#selected_drives[@]} -lt 2 ]]; do
        if [[ ${#selected_drives[@]} -gt 0 ]]; then
            echo "Selected drives: ${selected_drives[*]}"
        fi
        
        read -r -p "Enter drive number (1-${#available_drives[@]}): " input
        
        if [[ "$input" =~ ^[0-9]+$ ]] && [[ "$input" -ge 1 ]] && [[ "$input" -le ${#available_drives[@]} ]]; then
            local idx=$((input-1))
            local drive_info="${available_drives[$idx]}"
            local drive
            drive=$(echo "$drive_info" | cut -d: -f1)
            
            # Check if already selected
            if [[ " ${drive_indices[*]} " =~ [[:space:]]${idx}[[:space:]] ]]; then
                log "WARNING" "Drive $drive already selected"
                continue
            fi
            
            selected_drives+=("$drive")
            drive_indices+=("$idx")
            log "INFO" "Added $drive to selection"
        else
            log "ERROR" "Invalid selection. Enter a number between 1-${#available_drives[@]}"
        fi
    done
    
    # Ask if more drives should be added
    while [[ ${#selected_drives[@]} -lt ${#available_drives[@]} ]]; do
        read -r -p "Add another drive? (y/n): " add_more
        case "$add_more" in
            y|Y|yes|YES)
                echo "Remaining drives:"
                for i in "${!available_drives[@]}"; do
                    if [[ ! " ${drive_indices[*]} " =~ [[:space:]]${i}[[:space:]] ]]; then
                        local drive_info="${available_drives[$i]}"
                        local drive size model
                        drive=$(echo "$drive_info" | cut -d: -f1)
                        size=$(echo "$drive_info" | cut -d: -f2)
                        model=$(echo "$drive_info" | cut -d: -f3)
                        printf "%2d) %s (%s) - %s\n" $((i+1)) "$drive" "$size" "$model"
                    fi
                done
                
                read -r -p "Enter drive number: " input
                if [[ "$input" =~ ^[0-9]+$ ]] && [[ "$input" -ge 1 ]] && [[ "$input" -le ${#available_drives[@]} ]]; then
                    local idx=$((input-1))
                    if [[ ! " ${drive_indices[*]} " =~ [[:space:]]${idx}[[:space:]] ]]; then
                        local drive_info="${available_drives[$idx]}"
                        local drive
                        drive=$(echo "$drive_info" | cut -d: -f1)
                        selected_drives+=("$drive")
                        drive_indices+=("$idx")
                        log "INFO" "Added $drive to selection"
                    else
                        log "WARNING" "Drive already selected"
                    fi
                else
                    log "ERROR" "Invalid selection"
                fi
                ;;
            *)
                break
                ;;
        esac
    done
    
    # Show summary and confirm
    echo
    log "INFO" "LVM Mirror Configuration Summary:"
    log "INFO" "  Volume Group: $vg_name"
    log "INFO" "  Logical Volume: $lv_name"
    log "INFO" "  Number of drives: ${#selected_drives[@]}"
    log "INFO" "  Drives: ${selected_drives[*]}"
    log "INFO" "  Mirror copies: $((${#selected_drives[@]} - 1))"
    echo
    log "WARNING" "This will DESTROY all data on the selected drives!"
    
    if [[ "$FORCE" != "true" ]]; then
        read -r -p "Type 'YES' to confirm: " confirmation
        if [[ "$confirmation" != "YES" ]]; then
            log "INFO" "Operation cancelled"
            return 1
        fi
    fi
    
    # Create the LVM mirror
    cmd_create "$vg_name" "$lv_name" "${selected_drives[@]}"
}

# Interactive LVM volume removal
interactive_remove_mirror() {
    log "INFO" "=== Remove LVM Volume ==="
    
    # Check for existing LVs
    if ! command -v lvs >/dev/null 2>&1; then
        log "ERROR" "LVM tools not available"
        return 1
    fi
    
    local volumes=()
    local volume_info=()
    while IFS= read -r line; do
        local lv vg attr size
        read -r lv vg attr size _ <<< "$line"
        if [[ -n "$lv" && -n "$vg" ]]; then
            volumes+=("$vg/$lv")
            local mirror_info=""
            if [[ "$attr" =~ m.*$ ]]; then
                mirror_info=" [MIRRORED]"
            fi
            volume_info+=("$size$mirror_info")
        fi
    done < <(lvs --noheadings -o lv_name,vg_name,lv_attr,lv_size 2>/dev/null || true)
    
    if [[ ${#volumes[@]} -eq 0 ]]; then
        log "INFO" "No LVM volumes found to remove"
        return 0
    fi
    
    # Show current volumes
    log "INFO" "Current LVM volumes:"
    for i in "${!volumes[@]}"; do
        printf "%2d) /dev/%s %s\n" $((i+1)) "${volumes[$i]}" "${volume_info[$i]}"
    done
    echo
    printf "%2d) Remove ALL volumes\n" $((${#volumes[@]}+1))
    echo
    
    # Get selection
    local choice
    while true; do
        read -r -p "Select volume to remove (1-$((${#volumes[@]}+1))): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le $((${#volumes[@]}+1)) ]]; then
            break
        else
            log "ERROR" "Invalid choice. Please select 1-$((${#volumes[@]}+1))"
        fi
    done
    
    if [[ "$choice" -eq $((${#volumes[@]}+1)) ]]; then
        # Remove all volumes
        cmd_clear_all
    else
        # Remove specific volume
        local volume_to_remove="${volumes[$((choice-1))]}"
        cmd_clear_single "$volume_to_remove"
    fi
}

# Check if a drive can be mirrored with LVM
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
        local mount_point
        mount_point=$(mount | grep "^$drive" | awk '{print $3}')
        log "INFO" "Drive $drive is mounted at: $mount_point"
    elif command -v pvdisplay >/dev/null 2>&1 && pvdisplay 2>/dev/null | grep -q "$drive"; then
        status="IN_LVM"
        # Get LVM details
        local vg_name
        vg_name=$(pvs --noheadings -o vg_name "$drive" 2>/dev/null | tr -d ' ' || echo "unknown")
        log "INFO" "Drive $drive is part of LVM volume group: $vg_name"
        
        # Check for existing mirrors in this VG
        if [[ "$vg_name" != "unknown" ]]; then
            local mirrors
            mirrors=$(lvs --noheadings -o lv_name,lv_attr "$vg_name" 2>/dev/null | grep -c 'm' || echo "0")
            if [[ "$mirrors" -gt 0 ]]; then
                log "INFO" "Volume group $vg_name already has $mirrors mirrored volume(s)"
            fi
        fi
    elif grep -q "$(basename "$drive")" /proc/mdstat 2>/dev/null; then
        status="IN_RAID"
        local md_device
        md_device=$(grep -l "$(basename "$drive")" /sys/block/md*/md/raid_disks 2>/dev/null | head -1)
        if [[ -n "$md_device" ]]; then
            local array_name raid_level
            array_name="/dev/$(basename "$(dirname "$(dirname "$md_device")")")"
            raid_level=$(cat "$(dirname "$md_device")/level" 2>/dev/null || echo "unknown")
            log "INFO" "Drive $drive is part of $array_name (RAID $raid_level)"
        fi
    else
        status="AVAILABLE"
    fi
    
    log "INFO" "Drive $drive status: $status"
    
    case "$status" in
        "AVAILABLE")
            log "INFO" "✅ Drive can be used for new LVM mirror"
            return 0
            ;;
        "IN_LVM")
            log "INFO" "⚠️  Drive is already in LVM"
            log "INFO" "   You can:"
            log "INFO" "   1. Extend existing volume group with additional drives"
            log "INFO" "   2. Convert existing LVs to mirrored volumes (if space allows)"
            log "INFO" "   3. Create new mirrored LVs in the same VG"
            return 1
            ;;
        "MOUNTED")
            log "INFO" "⚠️  Drive is mounted and in use"
            log "INFO" "   To mirror this drive with LVM:"
            log "INFO" "   1. Backup the data"
            log "INFO" "   2. Unmount the drive"
            log "INFO" "   3. Create LVM physical volume"
            log "INFO" "   4. Create mirrored logical volume"
            log "INFO" "   5. Restore the data"
            return 1
            ;;
        "IN_RAID")
            log "INFO" "⚠️  Drive is part of mdadm RAID array"
            log "INFO" "   Consider migrating from mdadm to LVM for easier management"
            return 1
            ;;
    esac
}

# LVM mirroring setup guide
lvm_mirror_setup_guide() {
    log "INFO" "=== LVM Mirroring Setup Guide ==="
    log "INFO" "LVM provides flexible mirroring capabilities with several advantages:"
    log "INFO" "• Easier management than mdadm"
    log "INFO" "• Dynamic resizing and reconfiguration"
    log "INFO" "• Built-in snapshot support"
    log "INFO" "• Better integration with modern Linux systems"
    echo
    
    # Show current root filesystem
    local root_device
    root_device=$(df / | tail -1 | awk '{print $1}')
    log "INFO" "Current root filesystem: $root_device"
    
    # Check what type of device this is
    if [[ "$root_device" =~ /dev/mapper/ ]]; then
        log "INFO" "✅ Root is already on LVM device: $root_device"
        
        # Check if it's mirrored
        local lv_path="${root_device#/dev/mapper/}"
        local vg="${lv_path%-*}"
        local lv="${lv_path#*-}"
        
        if lvs --noheadings -o lv_attr "/dev/$vg/$lv" 2>/dev/null | grep -q 'm'; then
            log "INFO" "✅ Root volume is already mirrored!"
            lvs -o +lv_layout,copy_percent "/dev/$vg/$lv" 2>/dev/null || true
        else
            log "INFO" "⚠️  Root volume is not mirrored"
            log "INFO" "   To mirror the root volume:"
            log "INFO" "   1. Add a second drive of equal or larger size"
            log "INFO" "   2. Create a PV on the new drive: pvcreate /dev/sdX"
            log "INFO" "   3. Extend the VG: vgextend $vg /dev/sdX"
            log "INFO" "   4. Convert to mirror: lvconvert -m1 /dev/$vg/$lv"
        fi
    elif [[ "$root_device" =~ /dev/md ]]; then
        log "INFO" "Root is on mdadm RAID device: $root_device"
        log "INFO" "Consider migrating to LVM for better flexibility"
    else
        log "INFO" "Root is on regular partition: $root_device"
        local base_device
        base_device="${root_device%[0-9]*}"
        log "INFO" "Base device: $base_device"
        
        log "INFO" "To migrate to LVM mirroring:"
        log "INFO" "1. Add a second drive of equal or larger size"
        log "INFO" "2. Create LVM mirror on the new drive"
        log "INFO" "3. Copy system to the LVM mirror"
        log "INFO" "4. Update bootloader and fstab"
        log "INFO" "5. Migrate original drive to complete the mirror"
        log "INFO" "⚠️  This process requires careful planning - consider professional assistance"
    fi
    
    echo
    log "INFO" "For data drives, LVM mirroring is straightforward:"
    log "INFO" "• Use this script to create mirrored volumes"
    log "INFO" "• Format with your preferred filesystem (ext4, xfs, etc.)"
    log "INFO" "• Mount and use normally"
    echo
    log "INFO" "LVM Mirror Advantages:"
    log "INFO" "• Online resizing: lvextend/lvreduce"
    log "INFO" "• Snapshots: lvcreate -s"
    log "INFO" "• Easy monitoring: lvs, vgs, pvs"
    log "INFO" "• Flexible configuration changes"
}

# Main menu
main_menu() {
    while true; do
        echo
        log "INFO" "=== LVM Mirroring Management ==="
        echo "1) Show current LVM status"
        echo "2) Create new LVM mirror"
        echo "3) Remove LVM volume"
        echo "4) Show drive information"
        echo "5) Check drive mirror capability"
        echo "6) LVM mirroring setup guide"
        echo "7) Exit"
        echo
        
        local choice
        read -r -p "Select option (1-7): " choice
        
        case $choice in
            1)
                show_lvm_status
                ;;
            2)
                interactive_create_mirror
                ;;
            3)
                interactive_remove_mirror
                ;;
            4)
                log "INFO" "=== Drive Information ==="
                echo "Block devices:"
                lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,MODEL 2>/dev/null || echo "lsblk not available"
                echo
                echo "Available drives for LVM:"
                local available_drives=()
                while IFS= read -r drive_info; do
                    local drive
                    drive=$(echo "$drive_info" | cut -d: -f1)
                    # Only include drives not in use
                    if [[ ! "$drive_info" =~ \[(MOUNTED|IN\ LVM|IN\ RAID)\] ]]; then
                        available_drives+=("$drive_info")
                    fi
                done < <(detect_drives 2>/dev/null || true)
                
                if [[ ${#available_drives[@]} -eq 0 ]]; then
                    log "INFO" "💡 Tips for LVM setup:"
                    log "INFO" "  • Drives with existing partitions/data cannot be used for new LVM"
                    log "INFO" "  • To reuse drives, you would need to wipe them first (DESTROYS DATA)"
                    log "INFO" "  • Consider adding new drives for LVM mirrors"
                    log "INFO" "  • Existing LVM volumes can be extended or converted to mirrors"
                else
                    for drive_info in "${available_drives[@]}"; do
                        local drive size model
                        drive=$(echo "$drive_info" | cut -d: -f1)
                        size=$(echo "$drive_info" | cut -d: -f2)
                        model=$(echo "$drive_info" | cut -d: -f3-)
                        log "INFO" "  Available: $drive ($size) - $model"
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
                lvm_mirror_setup_guide
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
    
    # Check if LVM tools are installed
    if ! command -v lvm >/dev/null 2>&1; then
        log "ERROR" "LVM tools are not installed. Install them with: apt install lvm2"
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
                    log "ERROR" "Usage: clear VG/LV"
                    log "ERROR" "Example: clear data/storage"
                    exit 1
                fi
                cmd_clear_single "${COMMAND_ARGS[0]}"
                ;;
            create)
                if [[ ${#COMMAND_ARGS[@]} -lt 3 ]]; then
                    log "ERROR" "Usage: create VG_NAME LV_NAME DRIVE1 DRIVE2 [DRIVE3...]"
                    log "ERROR" "Example: create data storage /dev/sdb /dev/sdc"
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

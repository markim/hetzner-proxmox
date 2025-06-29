#!/bin/bash

# Advanced Storage Setup for Proxmox
# Interactive tool for creating ZFS mirrors, LVM-thin pools, and LVM mirrored volumes

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
STORAGE_TYPE=""
AUTO_PAIR=false

# Usage information
usage() {
    cat << EOF_USAGE
Usage: $0 [OPTIONS] [COMMAND]

Advanced storage setup for Proxmox with ZFS mirrors, LVM-thin pools, and LVM mirroring.
Automatically detects drive pairs and creates optimal storage configurations.

OPTIONS:
    -d, --dry-run          Show commands without executing
    -f, --force            Skip confirmation prompts (dangerous!)
    -t, --type TYPE        Storage type: zfs, lvm-thin, lvm (default: auto-detect)
    --auto-pair            Automatically pair drives of same size for mirrors
    -h, --help             Show this help message

COMMANDS:
    list                   List all drives and current storage status
    clear-all              Remove all storage pools/volumes
    clear POOL/VOL         Remove specific pool or volume
    create-zfs NAME DRIVES Create ZFS mirror pool with specified drives
    create-lvm NAME DRIVES Create LVM mirrored volume with specified drives
    create-thin NAME DRIVES Create LVM-thin pool with specified drives
    auto-setup             Automatically setup storage based on available drives
    
EXAMPLES:
    $0                                    # Interactive mode
    $0 list                               # List drives and storage status
    $0 auto-setup                         # Auto-configure all available drives
    $0 --auto-pair auto-setup             # Auto-pair drives by size
    $0 create-zfs tank /dev/sdb /dev/sdc   # Create ZFS mirror 'tank'
    $0 create-lvm data /dev/sdd /dev/sde   # Create LVM mirror 'data'
    $0 create-thin storage /dev/sdf /dev/sdg  # Create LVM-thin pool 'storage'
    $0 --dry-run auto-setup               # Preview auto-setup

STORAGE TYPES:
    ZFS:        - Copy-on-write filesystem with built-in RAID
                - Checksumming, compression, snapshots
                - Best for: VM storage, databases, critical data
                - Requires: zfsutils-linux package
    
    LVM-thin:   - Thin provisioning with snapshots
                - Space-efficient, over-provisioning
                - Best for: VM storage with many similar VMs
                - Native Proxmox integration
    
    LVM:        - Traditional mirroring with device-mapper
                - Simple, reliable, well-supported
                - Best for: Basic redundancy, older systems

AUTO-SETUP LOGIC:
    - Detects drives not used by Proxmox installation
    - Groups drives by size for optimal pairing
    - Creates ZFS mirrors for same-size pairs (preferred)
    - Falls back to LVM-thin or LVM for mixed sizes
    - Integrates with Proxmox storage configuration

SAFETY:
    - Always backup important data first
    - Use --dry-run to preview commands before execution
    - Only formats drives not containing Proxmox installation
    - Confirms destructive operations unless --force used

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
            -t|--type)
                STORAGE_TYPE="$2"
                if [[ ! "$STORAGE_TYPE" =~ ^(zfs|lvm-thin|lvm|auto)$ ]]; then
                    log "ERROR" "Invalid storage type: $STORAGE_TYPE. Use: zfs, lvm-thin, lvm, auto"
                    exit 1
                fi
                shift 2
                ;;
            --auto-pair)
                AUTO_PAIR=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            list|clear-all|clear|create-zfs|create-lvm|create-thin|auto-setup)
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

# Check system requirements
check_requirements() {
    log "INFO" "Checking system requirements..."
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "This script must be run as root"
        exit 1
    fi
    
    # Check for required packages
    local missing_packages=()
    
    # Check LVM tools
    if ! command -v lvm >/dev/null 2>&1; then
        missing_packages+=("lvm2")
    fi
    
    # Check if ZFS is requested or auto-detect
    local check_zfs=false
    if [[ "$STORAGE_TYPE" == "zfs" ]] || [[ "$STORAGE_TYPE" == "auto" ]] || [[ -z "$STORAGE_TYPE" ]]; then
        check_zfs=true
    fi
    
    if [[ "$check_zfs" == "true" ]] && ! command -v zpool >/dev/null 2>&1; then
        if command -v apt >/dev/null 2>&1; then
            missing_packages+=("zfsutils-linux")
        else
            log "WARNING" "ZFS tools not found. ZFS features will be disabled."
        fi
    fi
    
    # Install missing packages if possible
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        log "INFO" "Installing required packages: ${missing_packages[*]}"
        if [[ "$DRY_RUN" == "true" ]]; then
            log "INFO" "[DRY RUN] Would install: ${missing_packages[*]}"
        else
            if command -v apt >/dev/null 2>&1; then
                apt update && apt install -y "${missing_packages[@]}"
            else
                log "ERROR" "Cannot install packages automatically. Please install: ${missing_packages[*]}"
                exit 1
            fi
        fi
    fi
    
    log "INFO" "✅ System requirements satisfied"
}

# Detect available drives and exclude Proxmox installation drive
detect_drives() {
    local drives=()
    local proxmox_drive=""
    
    # Find Proxmox installation drive
    local root_device
    root_device=$(df / | tail -1 | awk '{print $1}')
    
    # Extract base device from root partition
    if [[ "$root_device" =~ ^/dev/(sd[a-z]|nvme[0-9]+n[0-9]+|vd[a-z]) ]]; then
        if [[ "$root_device" =~ nvme ]]; then
            proxmox_drive="${root_device%p[0-9]*}"  # Remove partition number for NVMe
        else
            proxmox_drive="${root_device%[0-9]*}"   # Remove partition number for SATA/SCSI
        fi
    fi
    
    log "INFO" "Proxmox installation drive detected: $proxmox_drive"
    
    # Get all block devices that are disks (not partitions)
    while IFS= read -r line; do
        local name size type model
        read -r name size type model <<< "$line"
        local drive="/dev/$name"
        
        # Skip if not a disk or if it's the Proxmox drive
        if [[ "$type" != "disk" ]] || [[ "$drive" == "$proxmox_drive" ]]; then
            continue
        fi
        
        # Skip loop, ram, and other virtual devices
        if [[ "$name" =~ ^(loop|ram|dm-|sr) ]]; then
            continue
        fi
        
        # Check if drive is in use
        local status=""
        local usage_info=""
        
        # Check for mount points
        if mount | grep -q "^$drive"; then
            status="MOUNTED"
            usage_info=$(mount | grep "^$drive" | awk '{print $3}' | head -1)
        # Check for ZFS usage
        elif command -v zpool >/dev/null 2>&1 && zpool status 2>/dev/null | grep -q "$drive"; then
            status="IN_ZFS"
            usage_info=$(zpool status 2>/dev/null | grep -B5 "$drive" | grep "pool:" | awk '{print $2}' | head -1)
        # Check for LVM usage
        elif command -v pvdisplay >/dev/null 2>&1 && pvdisplay 2>/dev/null | grep -q "$drive"; then
            status="IN_LVM"
            usage_info=$(pvs --noheadings -o vg_name "$drive" 2>/dev/null | tr -d ' ')
        # Check for mdadm RAID
        elif grep -q "$(basename "$drive")" /proc/mdstat 2>/dev/null; then
            status="IN_RAID"
            usage_info=$(grep "$(basename "$drive")" /proc/mdstat | awk '{print $1}' | head -1)
        # Check for partitions
        elif [[ -n "$(lsblk -rno NAME "$drive" | tail -n +2)" ]]; then
            status="PARTITIONED"
            usage_info="Has partitions"
        else
            status="AVAILABLE"
            usage_info="Ready for use"
        fi
        
        # Get size in bytes for sorting
        local size_bytes
        size_bytes=$(lsblk -b -dn -o SIZE "$drive" 2>/dev/null || echo "0")
        
        drives+=("$drive:$size:$size_bytes:$model:$status:$usage_info")
    done < <(lsblk -dn -o NAME,SIZE,TYPE,MODEL 2>/dev/null || true)
    
    if [[ ${#drives[@]} -eq 0 ]]; then
        log "WARNING" "No additional drives found (excluding Proxmox installation drive)"
        return 1
    fi
    
    # Sort drives by size (bytes) for better pairing
    local sorted_drives
    mapfile -t sorted_drives < <(printf "%s\n" "${drives[@]}" | sort -t: -k3 -n)
    drives=("${sorted_drives[@]}")
    
    printf "%s\n" "${drives[@]}"
}

# Group drives by size for intelligent pairing
group_drives_by_size() {
    local tolerance_percent=5  # Allow 5% size difference for pairing
    local drives=()
    local groups=()
    
    # Read available drives
    while IFS= read -r drive_info; do
        local status
        status=$(echo "$drive_info" | cut -d: -f5)
        if [[ "$status" == "AVAILABLE" ]]; then
            drives+=("$drive_info")
        fi
    done < <(detect_drives 2>/dev/null || true)
    
    if [[ ${#drives[@]} -eq 0 ]]; then
        log "WARNING" "No available drives for grouping"
        return 1
    fi
    
    # Group drives by similar size
    local processed=()
    for i in "${!drives[@]}"; do
        if [[ " ${processed[*]} " =~ [[:space:]]${i}[[:space:]] ]]; then
            continue
        fi
        
        local drive1="${drives[$i]}"
        local size1_bytes
        size1_bytes=$(echo "$drive1" | cut -d: -f3)
        local group=("$drive1")
        processed+=("$i")
        
        # Find drives with similar size
        for j in "${!drives[@]}"; do
            if [[ $i -eq $j ]] || [[ " ${processed[*]} " =~ [[:space:]]${j}[[:space:]] ]]; then
                continue
            fi
            
            local drive2="${drives[$j]}"
            local size2_bytes
            size2_bytes=$(echo "$drive2" | cut -d: -f3)
            
            # Calculate size difference percentage
            local size_diff
            if [[ $size1_bytes -gt $size2_bytes ]]; then
                size_diff=$(( (size1_bytes - size2_bytes) * 100 / size1_bytes ))
            else
                size_diff=$(( (size2_bytes - size1_bytes) * 100 / size2_bytes ))
            fi
            
            if [[ $size_diff -le $tolerance_percent ]]; then
                group+=("$drive2")
                processed+=("$j")
            fi
        done
        
        # Add group if it has drives
        if [[ ${#group[@]} -gt 0 ]]; then
            local group_key="SIZE_GROUP_$((${#groups[@]} + 1))"
            groups+=("$group_key:${group[*]}")
        fi
    done
    
    printf "%s\n" "${groups[@]}"
}

# List drives and storage status
cmd_list() {
    log "INFO" "=== System Storage Status ==="
    echo
    
    log "INFO" "Block devices:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,MODEL 2>/dev/null || echo "lsblk not available"
    echo
    
    # ZFS pools
    if command -v zpool >/dev/null 2>&1; then
        log "INFO" "ZFS pools:"
        if zpool list 2>/dev/null | grep -q "NAME"; then
            zpool list -v 2>/dev/null || zpool list 2>/dev/null
            echo
            log "INFO" "ZFS pool status:"
            zpool status 2>/dev/null || log "INFO" "  No ZFS pools or status unavailable"
        else
            log "INFO" "  No ZFS pools found"
        fi
        echo
    fi
    
    # LVM status
    if command -v pvdisplay >/dev/null 2>&1; then
        log "INFO" "LVM Physical Volumes:"
        if pvs --noheadings 2>/dev/null | grep -q .; then
            pvs -o +pv_used,pv_free,attr 2>/dev/null || pvs 2>/dev/null
        else
            log "INFO" "  No LVM physical volumes found"
        fi
        echo
        
        log "INFO" "LVM Volume Groups:"
        if vgs --noheadings 2>/dev/null | grep -q .; then
            vgs -o +vg_free 2>/dev/null || vgs 2>/dev/null
        else
            log "INFO" "  No LVM volume groups found"
        fi
        echo
        
        log "INFO" "LVM Logical Volumes:"
        if lvs --noheadings 2>/dev/null | grep -q .; then
            lvs -o +lv_layout,copy_percent 2>/dev/null || lvs 2>/dev/null
        else
            log "INFO" "  No LVM logical volumes found"
        fi
        echo
    fi
    
    # Available drives
    log "INFO" "Available drives (excluding Proxmox installation):"
    local available_drives=()
    local used_drives=()
    
    while IFS= read -r drive_info; do
        local drive size status usage
        drive=$(echo "$drive_info" | cut -d: -f1)
        size=$(echo "$drive_info" | cut -d: -f2)
        status=$(echo "$drive_info" | cut -d: -f5)
        usage=$(echo "$drive_info" | cut -d: -f6)
        
        if [[ "$status" == "AVAILABLE" ]]; then
            available_drives+=("$drive_info")
            log "INFO" "  ✅ $drive ($size) - Ready for use"
        else
            used_drives+=("$drive_info")
            log "INFO" "  ⚠️  $drive ($size) - $status ($usage)"
        fi
    done < <(detect_drives 2>/dev/null || true)
    
    if [[ ${#available_drives[@]} -eq 0 ]]; then
        log "INFO" "💡 No drives available for new storage pools"
        if [[ ${#used_drives[@]} -gt 0 ]]; then
            log "INFO" "   All additional drives are already in use"
        else
            log "INFO" "   Consider adding more drives to the system"
        fi
    else
        log "INFO" "📊 Drive pairing analysis:"
        if command -v bash >/dev/null 2>&1; then
            while IFS= read -r group_info; do
                local group_name drives_in_group
                IFS=':' read -r group_name drives_in_group <<< "$group_info"
                local drive_count
                drive_count=$(echo "$drives_in_group" | wc -w)
                log "INFO" "   $group_name: $drive_count drives of similar size"
                
                if [[ $drive_count -ge 2 ]]; then
                    log "INFO" "     → Can create mirror(s)"
                else
                    log "INFO" "     → Single drive (no mirroring)"
                fi
            done < <(group_drives_by_size 2>/dev/null || true)
        fi
    fi
}

# Clear all storage pools/volumes
cmd_clear_all() {
    log "INFO" "=== Clear All Storage Pools/Volumes ==="
    
    local has_storage=false
    
    # Check for ZFS pools
    if command -v zpool >/dev/null 2>&1; then
        local zfs_pools=()
        while IFS= read -r pool; do
            if [[ -n "$pool" ]]; then
                zfs_pools+=("$pool")
                has_storage=true
            fi
        done < <(zpool list -H -o name 2>/dev/null || true)
        
        if [[ ${#zfs_pools[@]} -gt 0 ]]; then
            log "WARNING" "Found ZFS pools to remove:"
            for pool in "${zfs_pools[@]}"; do
                log "WARNING" "  ZFS pool: $pool"
            done
        fi
    fi
    
    # Check for LVM volumes
    if command -v lvs >/dev/null 2>&1; then
        local lvm_volumes=()
        while IFS= read -r line; do
            local lv vg
            read -r lv vg _ <<< "$line"
            if [[ -n "$lv" && -n "$vg" ]]; then
                lvm_volumes+=("$vg/$lv")
                has_storage=true
            fi
        done < <(lvs --noheadings -o lv_name,vg_name 2>/dev/null || true)
        
        if [[ ${#lvm_volumes[@]} -gt 0 ]]; then
            log "WARNING" "Found LVM volumes to remove:"
            for volume in "${lvm_volumes[@]}"; do
                log "WARNING" "  LVM volume: /dev/$volume"
            done
        fi
    fi
    
    if [[ "$has_storage" == "false" ]]; then
        log "INFO" "No storage pools or volumes to clear"
        return 0
    fi
    
    if [[ "$FORCE" != "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
        read -r -p "Type 'YES' to confirm removal of ALL storage: " confirmation
        if [[ "$confirmation" != "YES" ]]; then
            log "INFO" "Operation cancelled"
            return 1
        fi
    fi
    
    # Remove ZFS pools
    if command -v zpool >/dev/null 2>&1; then
        local zfs_pools=()
        while IFS= read -r pool; do
            if [[ -n "$pool" ]]; then
                zfs_pools+=("$pool")
            fi
        done < <(zpool list -H -o name 2>/dev/null || true)
        
        for pool in "${zfs_pools[@]}"; do
            if [[ "$DRY_RUN" == "true" ]]; then
                log "INFO" "[DRY RUN] Would destroy ZFS pool: $pool"
            else
                log "INFO" "Destroying ZFS pool: $pool"
                if zpool destroy "$pool" 2>/dev/null; then
                    log "INFO" "✅ ZFS pool $pool destroyed"
                else
                    log "WARNING" "Failed to destroy ZFS pool $pool"
                fi
            fi
        done
    fi
    
    # Remove LVM volumes (same as before)
    if command -v lvs >/dev/null 2>&1; then
        local volumes=()
        while IFS= read -r line; do
            local lv vg
            read -r lv vg _ <<< "$line"
            if [[ -n "$lv" && -n "$vg" ]]; then
                volumes+=("$vg/$lv")
            fi
        done < <(lvs --noheadings -o lv_name,vg_name 2>/dev/null || true)
        
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
    fi
    
    log "INFO" "✅ All storage pools/volumes cleared"
}

# Clear single storage pool/volume
cmd_clear_single() {
    local target="$1"
    
    if [[ -z "$target" ]]; then
        log "ERROR" "No target specified for clearing"
        log "ERROR" "Format for LVM: vg/lv"
        log "ERROR" "Format for ZFS: pool_name"
        return 1
    fi
    
    # Check if it's a ZFS pool
    if command -v zpool >/dev/null 2>&1 && zpool list "$target" >/dev/null 2>&1; then
        log "INFO" "Clearing ZFS pool: $target"
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log "INFO" "[DRY RUN] Would destroy ZFS pool: $target"
            return 0
        fi
        
        if [[ "$FORCE" != "true" ]]; then
            read -r -p "Type 'YES' to confirm destruction of ZFS pool '$target': " confirmation
            if [[ "$confirmation" != "YES" ]]; then
                log "INFO" "Operation cancelled"
                return 1
            fi
        fi
        
        if zpool destroy "$target" 2>/dev/null; then
            log "INFO" "✅ ZFS pool $target destroyed successfully"
        else
            log "ERROR" "Failed to destroy ZFS pool $target"
            return 1
        fi
        return 0
    fi
    
    # Check if it's an LVM volume (vg/lv format)
    if [[ "$target" =~ ^[^/]+/[^/]+$ ]]; then
        local lv_path="/dev/$target"
        
        if ! lvs "$lv_path" >/dev/null 2>&1; then
            log "ERROR" "LVM volume $lv_path not found"
            return 1
        fi
        
        log "INFO" "Clearing LVM volume: $lv_path"
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log "INFO" "[DRY RUN] Would remove volume: $lv_path"
            return 0
        fi
        
        if [[ "$FORCE" != "true" ]]; then
            read -r -p "Type 'YES' to confirm removal of LVM volume '$target': " confirmation
            if [[ "$confirmation" != "YES" ]]; then
                log "INFO" "Operation cancelled"
                return 1
            fi
        fi
        
        if lvremove -f "$lv_path" 2>/dev/null; then
            log "INFO" "✅ Volume $lv_path removed successfully"
        else
            log "ERROR" "Failed to remove $lv_path"
            return 1
        fi
        return 0
    fi
    
    log "ERROR" "Invalid target format: $target"
    log "ERROR" "Use: pool_name (for ZFS) or vg_name/lv_name (for LVM)"
    return 1
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

# Create ZFS mirror pool
cmd_create_zfs() {
    local pool_name="$1"
    shift
    local drives=("$@")
    
    if [[ -z "$pool_name" ]] || [[ ${#drives[@]} -eq 0 ]]; then
        log "ERROR" "Usage: create-zfs POOL_NAME DRIVE1 DRIVE2 [DRIVE3...]"
        log "ERROR" "Example: create-zfs tank /dev/sdb /dev/sdc"
        return 1
    fi
    
    # Check ZFS availability
    if ! command -v zpool >/dev/null 2>&1; then
        log "ERROR" "ZFS tools not available. Install with: apt install zfsutils-linux"
        return 1
    fi
    
    # Validate minimum drives for mirroring
    if [[ ${#drives[@]} -lt 2 ]]; then
        log "ERROR" "ZFS mirroring requires at least 2 drives. Provided: ${#drives[@]}"
        return 1
    fi
    
    # Validate drives exist and are available
    for drive in "${drives[@]}"; do
        if [[ ! -b "$drive" ]]; then
            log "ERROR" "Drive $drive does not exist or is not a block device"
            return 1
        fi
        
        # Check if drive is busy
        local drive_info
        drive_info=$(detect_drives | grep "^$drive:" || true)
        if [[ -n "$drive_info" ]]; then
            local status
            status=$(echo "$drive_info" | cut -d: -f5)
            if [[ "$status" != "AVAILABLE" ]]; then
                log "ERROR" "Drive $drive is not available (status: $status)"
                return 1
            fi
        fi
    done
    
    log "INFO" "Creating ZFS mirror pool: $pool_name with drives: ${drives[*]}"
    
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
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "INFO" "[DRY RUN] Would create ZFS mirror pool:"
        log "INFO" "[DRY RUN]   Pool: $pool_name"
        log "INFO" "[DRY RUN]   Type: mirror"
        log "INFO" "[DRY RUN]   Drives: ${drives[*]}"
        log "INFO" "[DRY RUN]   Command: zpool create $pool_name mirror ${drives[*]}"
        return 0
    fi
    
    # Create ZFS mirror pool
    log "INFO" "Creating ZFS pool..."
    if zpool create "$pool_name" mirror "${drives[@]}"; then
        log "INFO" "✅ ZFS mirror pool '$pool_name' created successfully"
        
        # Set optimal properties for Proxmox
        log "INFO" "Configuring ZFS properties for Proxmox..."
        zfs set compression=lz4 "$pool_name"
        zfs set atime=off "$pool_name"
        zfs set relatime=on "$pool_name"
        
        # Show pool status
        log "INFO" "ZFS pool details:"
        zpool status "$pool_name"
        echo
        zfs list "$pool_name"
        
        # Add to Proxmox storage if possible
        if command -v pvesm >/dev/null 2>&1; then
            log "INFO" "Adding ZFS pool to Proxmox storage configuration..."
            if pvesm add zfspool "$pool_name" --pool "$pool_name" --content images,rootdir 2>/dev/null; then
                log "INFO" "✅ ZFS pool added to Proxmox storage"
            else
                log "WARNING" "Could not add ZFS pool to Proxmox automatically"
                log "INFO" "You can add it manually with: pvesm add zfspool $pool_name --pool $pool_name --content images,rootdir"
            fi
        fi
    else
        log "ERROR" "Failed to create ZFS mirror pool"
        return 1
    fi
}

# Create LVM-thin pool
cmd_create_thin() {
    local pool_name="$1"
    shift
    local drives=("$@")
    
    if [[ -z "$pool_name" ]] || [[ ${#drives[@]} -eq 0 ]]; then
        log "ERROR" "Usage: create-thin POOL_NAME DRIVE1 DRIVE2 [DRIVE3...]"
        log "ERROR" "Example: create-thin storage /dev/sdb /dev/sdc"
        return 1
    fi
    
    # Validate drives
    for drive in "${drives[@]}"; do
        if [[ ! -b "$drive" ]]; then
            log "ERROR" "Drive $drive does not exist or is not a block device"
            return 1
        fi
    done
    
    local vg_name="${pool_name}_vg"
    local thin_pool_name="${pool_name}_tpool"
    
    log "INFO" "Creating LVM-thin pool: $pool_name with drives: ${drives[*]}"
    
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
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "INFO" "[DRY RUN] Would create LVM-thin pool:"
        log "INFO" "[DRY RUN]   VG: $vg_name"
        log "INFO" "[DRY RUN]   Pool: $thin_pool_name"
        log "INFO" "[DRY RUN]   Drives: ${drives[*]}"
        return 0
    fi
    
    # Wipe drives
    for drive in "${drives[@]}"; do
        log "INFO" "Wiping $drive..."
        wipefs -fa "$drive"
    done
    
    # Create physical volumes
    log "INFO" "Creating physical volumes..."
    pvcreate "${drives[@]}"
    
    # Create volume group
    log "INFO" "Creating volume group: $vg_name"
    vgcreate "$vg_name" "${drives[@]}"
    
    # Create thin pool (use 95% of space)
    local vg_size
    vg_size=$(vgs --noheadings --units g -o vg_free "$vg_name" | tr -d ' G' | cut -d. -f1)
    local pool_size=$((vg_size * 95 / 100))
    
    log "INFO" "Creating thin pool: $thin_pool_name (${pool_size}G)"
    lvcreate -L "${pool_size}G" --thinpool "$thin_pool_name" "$vg_name"
    
    log "INFO" "✅ LVM-thin pool created successfully"
    
    # Show status
    lvs "$vg_name/$thin_pool_name"
    
    # Add to Proxmox storage if possible
    if command -v pvesm >/dev/null 2>&1; then
        log "INFO" "Adding LVM-thin to Proxmox storage configuration..."
        if pvesm add lvmthin "$pool_name" --vgname "$vg_name" --thinpool "$thin_pool_name" --content images,rootdir 2>/dev/null; then
            log "INFO" "✅ LVM-thin pool added to Proxmox storage"
        else
            log "WARNING" "Could not add LVM-thin to Proxmox automatically"
            log "INFO" "You can add it manually with: pvesm add lvmthin $pool_name --vgname $vg_name --thinpool $thin_pool_name"
        fi
    fi
}

# Auto-setup storage based on available drives
cmd_auto_setup() {
    log "INFO" "=== Auto Storage Setup ==="
    
    check_requirements
    
    # Get available drives
    local available_drives=()
    while IFS= read -r drive_info; do
        local status
        status=$(echo "$drive_info" | cut -d: -f5)
        if [[ "$status" == "AVAILABLE" ]]; then
            available_drives+=("$drive_info")
        fi
    done < <(detect_drives 2>/dev/null || true)
    
    if [[ ${#available_drives[@]} -eq 0 ]]; then
        log "INFO" "No available drives found for auto-setup"
        return 0
    fi
    
    log "INFO" "Found ${#available_drives[@]} available drives"
    for drive_info in "${available_drives[@]}"; do
        local drive size model
        drive=$(echo "$drive_info" | cut -d: -f1)
        size=$(echo "$drive_info" | cut -d: -f2)
        model=$(echo "$drive_info" | cut -d: -f4)
        log "INFO" "  $drive ($size) - $model"
    done
    
    # Group drives by size for optimal pairing
    local storage_configs=()
    local config_count=1
    
    if [[ "$AUTO_PAIR" == "true" ]] || [[ ${#available_drives[@]} -ge 4 ]]; then
        log "INFO" "Analyzing drive groups for optimal pairing..."
        
        while IFS= read -r group_info; do
            local group_name drives_in_group
            IFS=':' read -r group_name drives_in_group <<< "$group_info"
            
            # Convert space-separated drives to array
            local group_drives=()
            read -ra group_drives <<< "$drives_in_group"
            
            if [[ ${#group_drives[@]} -ge 2 ]]; then
                # Create mirrors from pairs
                for ((i=0; i<${#group_drives[@]}; i+=2)); do
                    if [[ $((i+1)) -lt ${#group_drives[@]} ]]; then
                        local drive1 drive2
                        drive1=$(echo "${group_drives[$i]}" | cut -d: -f1)
                        drive2=$(echo "${group_drives[$((i+1))]}" | cut -d: -f1)
                        storage_configs+=("mirror$config_count:$drive1:$drive2")
                        ((config_count++))
                    else
                        # Odd drive, handle separately
                        local lone_drive
                        lone_drive=$(echo "${group_drives[$i]}" | cut -d: -f1)
                        storage_configs+=("single$config_count:$lone_drive")
                        ((config_count++))
                    fi
                done
            else
                # Single drive
                local single_drive
                single_drive=$(echo "${group_drives[0]}" | cut -d: -f1)
                storage_configs+=("single$config_count:$single_drive")
                ((config_count++))
            fi
        done < <(group_drives_by_size 2>/dev/null || true)
    else
        # Simple setup - use all drives for one pool
        local all_drives=()
        for drive_info in "${available_drives[@]}"; do
            local drive
            drive=$(echo "$drive_info" | cut -d: -f1)
            all_drives+=("$drive")
        done
        
        if [[ ${#all_drives[@]} -ge 2 ]]; then
            storage_configs+=("mirror1:${all_drives[*]}")
        else
            storage_configs+=("single1:${all_drives[0]}")
        fi
    fi
    
    # Show proposed configuration
    log "INFO" "Proposed storage configuration:"
    for config in "${storage_configs[@]}"; do
        local config_name config_drives
        IFS=':' read -r config_name config_drives <<< "$config"
        
        if [[ "$config_name" =~ ^mirror ]]; then
            local drive_array=()
            read -ra drive_array <<< "${config_drives//:/ }"
            log "INFO" "  📀 $config_name: ZFS/LVM mirror with ${#drive_array[@]} drives (${drive_array[*]})"
        else
            log "INFO" "  📀 $config_name: Single drive ($config_drives)"
        fi
    done
    
    # Determine storage type
    local final_storage_type="$STORAGE_TYPE"
    if [[ -z "$final_storage_type" ]] || [[ "$final_storage_type" == "auto" ]]; then
        if command -v zpool >/dev/null 2>&1; then
            final_storage_type="zfs"
            log "INFO" "Auto-selected storage type: ZFS (recommended for Proxmox)"
        else
            final_storage_type="lvm-thin"
            log "INFO" "Auto-selected storage type: LVM-thin (ZFS not available)"
        fi
    fi
    
    log "INFO" "Storage type: $final_storage_type"
    
    # Confirm setup
    if [[ "$FORCE" != "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
        echo
        log "WARNING" "This will create storage pools and DESTROY data on selected drives!"
        read -r -p "Continue with auto-setup? (y/N): " confirmation
        if [[ ! "$confirmation" =~ ^[Yy] ]]; then
            log "INFO" "Auto-setup cancelled"
            return 1
        fi
    fi
    
    # Execute configuration
    for config in "${storage_configs[@]}"; do
        local config_name config_drives
        IFS=':' read -r config_name config_drives <<< "$config"
        
        if [[ "$config_name" =~ ^mirror ]]; then
            local drive_array=()
            read -ra drive_array <<< "${config_drives//:/ }"
            
            case "$final_storage_type" in
                zfs)
                    cmd_create_zfs "$config_name" "${drive_array[@]}"
                    ;;
                lvm-thin)
                    cmd_create_thin "$config_name" "${drive_array[@]}"
                    ;;
                lvm)
                    cmd_create "$config_name" "data" "${drive_array[@]}"
                    ;;
            esac
        else
            # Single drive - create simple storage
            log "INFO" "Creating single-drive storage: $config_name ($config_drives)"
            if [[ "$DRY_RUN" != "true" ]]; then
                case "$final_storage_type" in
                    zfs)
                        if command -v zpool >/dev/null 2>&1; then
                            zpool create "$config_name" "$config_drives"
                        fi
                        ;;
                    *)
                        # For single drives, create simple LVM
                        wipefs -fa "$config_drives"
                        pvcreate "$config_drives"
                        vgcreate "${config_name}_vg" "$config_drives"
                        lvcreate -l 100%FREE -n "data" "${config_name}_vg"
                        ;;
                esac
            fi
        fi
    done
    
    log "INFO" "✅ Auto-setup completed!"
    echo
    log "INFO" "Storage summary:"
    cmd_list
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

# Interactive storage removal
interactive_remove_storage() {
    log "INFO" "=== Remove Storage Pool/Volume ==="
    
    local storage_items=()
    local storage_info=()
    
    # Check for ZFS pools
    if command -v zpool >/dev/null 2>&1; then
        while IFS= read -r pool; do
            if [[ -n "$pool" ]]; then
                storage_items+=("zfs:$pool")
                local pool_size
                pool_size=$(zpool list -H -o size "$pool" 2>/dev/null || echo "unknown")
                storage_info+=("ZFS pool ($pool_size)")
            fi
        done < <(zpool list -H -o name 2>/dev/null || true)
    fi
    
    # Check for LVM volumes
    if command -v lvs >/dev/null 2>&1; then
        while IFS= read -r line; do
            local lv vg attr size
            read -r lv vg attr size _ <<< "$line"
            if [[ -n "$lv" && -n "$vg" ]]; then
                storage_items+=("lvm:$vg/$lv")
                local vol_info="LVM volume ($size)"
                if [[ "$attr" =~ m.*$ ]]; then
                    vol_info="$vol_info [MIRRORED]"
                elif [[ "$attr" =~ t.*$ ]]; then
                    vol_info="$vol_info [THIN]"
                fi
                storage_info+=("$vol_info")
            fi
        done < <(lvs --noheadings -o lv_name,vg_name,lv_attr,lv_size 2>/dev/null || true)
    fi
    
    if [[ ${#storage_items[@]} -eq 0 ]]; then
        log "INFO" "No storage pools or volumes found to remove"
        return 0
    fi
    
    # Show storage items
    log "INFO" "Current storage:"
    for i in "${!storage_items[@]}"; do
        local item="${storage_items[$i]}"
        local type_and_name
        IFS=':' read -r _ type_and_name <<< "$item"
        printf "%2d) %s - %s\n" $((i+1)) "$type_and_name" "${storage_info[$i]}"
    done
    echo
    printf "%2d) Remove ALL storage\n" $((${#storage_items[@]}+1))
    echo
    
    # Get selection
    local choice
    while true; do
        read -r -p "Select item to remove (1-$((${#storage_items[@]}+1))): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le $((${#storage_items[@]}+1)) ]]; then
            break
        else
            log "ERROR" "Invalid choice. Please select 1-$((${#storage_items[@]}+1))"
        fi
    done
    
    if [[ "$choice" -eq $((${#storage_items[@]}+1)) ]]; then
        # Remove all storage
        cmd_clear_all
    else
        # Remove specific item
        local selected_item="${storage_items[$((choice-1))]}"
        local type target
        IFS=':' read -r type target <<< "$selected_item"
        cmd_clear_single "$target"
    fi
}

# Create ZFS pool with mirrored vdevs
create_zfs_mirror_pool() {
    local pool_name="$1"
    shift
    local drives=("$@")
    
    if [[ ${#drives[@]} -lt 2 ]]; then
        log "ERROR" "At least 2 drives are required for a mirrored ZFS pool"
        return 1
    fi
    
    log "INFO" "Creating ZFS mirror pool: $pool_name with drives: ${drives[*]}"
    
    # Create ZFS pool with mirrored vdevs
    if ! zpool create "$pool_name" mirror "${drives[@]}"; then
        log "ERROR" "Failed to create ZFS mirror pool"
        return 1
    fi
    
    log "INFO" "✅ ZFS mirror pool '$pool_name' created successfully"
    
    # Set optimal properties for Proxmox
    log "INFO" "Configuring ZFS properties for Proxmox..."
    zfs set compression=lz4 "$pool_name"
    zfs set atime=off "$pool_name"
    zfs set relatime=on "$pool_name"
    
    # Show pool status
    log "INFO" "ZFS pool details:"
    zpool status "$pool_name"
    echo
    zfs list "$pool_name"
    
    # Add to Proxmox storage if possible
    if command -v pvesm >/dev/null 2>&1; then
        log "INFO" "Adding ZFS pool to Proxmox storage configuration..."
        if pvesm add zfspool "$pool_name" --pool "$pool_name" --content images,rootdir 2>/dev/null; then
            log "INFO" "✅ ZFS pool added to Proxmox storage"
        else
            log "WARNING" "Could not add ZFS pool to Proxmox automatically"
            log "INFO" "You can add it manually with: pvesm add zfspool $pool_name --pool $pool_name --content images,rootdir"
        fi
    fi
}

# Create LVM-thin pool with automatic VG and LV naming
create_lvm_thin_pool() {
    local pool_name="$1"
    shift
    local drives=("$@")
    
    if [[ ${#drives[@]} -eq 0 ]]; then
        log "ERROR" "No drives specified for LVM-thin pool"
        return 1
    fi
    
    local vg_name="${pool_name}_vg"
    local thin_pool_name="${pool_name}_tpool"
    
    log "INFO" "Creating LVM-thin pool: $pool_name with drives: ${drives[*]}"
    
    # Create physical volumes
    if ! pvcreate "${drives[@]}"; then
        log "ERROR" "Failed to create physical volumes on drives: ${drives[*]}"
        return 1
    fi
    
    # Create volume group
    if ! vgcreate "$vg_name" "${drives[@]}"; then
        log "ERROR" "Failed to create volume group $vg_name"
        return 1
    fi
    
    # Create thin pool (use 95% of space)
    local vg_free_size
    vg_free_size=$(vgs --noheadings --units g -o vg_free "$vg_name" | tr -d ' G' | cut -d. -f1)
    local pool_size=$((vg_free_size * 95 / 100))
    
    if ! lvcreate -L "${pool_size}G" --thinpool "$thin_pool_name" "$vg_name"; then
        log "ERROR" "Failed to create thin pool $thin_pool_name"
        return 1
    fi
    
    log "INFO" "✅ LVM-thin pool created successfully"
    
    # Show status
    lvs "$vg_name/$thin_pool_name"
    
    # Add to Proxmox storage if possible
    if command -v pvesm >/dev/null 2>&1; then
        log "INFO" "Adding LVM-thin to Proxmox storage configuration..."
        if pvesm add lvmthin "$pool_name" --vgname "$vg_name" --thinpool "$thin_pool_name" --content images,rootdir 2>/dev/null; then
            log "INFO" "✅ LVM-thin pool added to Proxmox storage"
        else
            log "WARNING" "Could not add LVM-thin to Proxmox automatically"
            log "INFO" "You can add it manually with: pvesm add lvmthin $pool_name --vgname $vg_name --thinpool $thin_pool_name"
        fi
    fi
}

# Main menu
main_menu() {
    while true; do
        echo
        log "INFO" "=== Advanced Storage Management for Proxmox ==="
        echo "1) Show current storage status"
        echo "2) Auto-setup storage (recommended)"
        echo "3) Create ZFS mirror pool"
        echo "4) Create LVM-thin pool"
        echo "5) Create LVM mirror"
        echo "6) Remove storage pool/volume"
        echo "7) Show drive information"
        echo "8) Storage setup guide"
        echo "9) Exit"
        echo
        
        local choice
        read -r -p "Select option (1-9): " choice
        
        case $choice in
            1)
                cmd_list
                ;;
            2)
                cmd_auto_setup
                ;;
            3)
                interactive_create_zfs
                ;;
            4)
                interactive_create_thin
                ;;
            5)
                interactive_create_mirror
                ;;
            6)
                interactive_remove_storage
                ;;
            7)
                show_drive_info
                ;;
            8)
                storage_setup_guide
                ;;
            9)
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

# Interactive ZFS creation
interactive_create_zfs() {
    log "INFO" "=== Create ZFS Mirror Pool ==="
    
    if ! command -v zpool >/dev/null 2>&1; then
        log "ERROR" "ZFS tools not available. Install with: apt install zfsutils-linux"
        return 1
    fi
    
    # Get available drives
    local available_drives=()
    while IFS= read -r drive_info; do
        local status
        status=$(echo "$drive_info" | cut -d: -f5)
        if [[ "$status" == "AVAILABLE" ]]; then
            available_drives+=("$drive_info")
        fi
    done < <(detect_drives 2>/dev/null || true)
    
    if [[ ${#available_drives[@]} -lt 2 ]]; then
        log "ERROR" "Need at least 2 available drives for ZFS mirroring"
        return 1
    fi
    
    show_available_drives "${available_drives[@]}"
    
    # Get pool name
    local pool_name
    read -r -p "Enter ZFS pool name (e.g., 'tank'): " pool_name
    if [[ -z "$pool_name" ]] || [[ ! "$pool_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log "ERROR" "Invalid pool name. Use only letters, numbers, underscore, and dash."
        return 1
    fi
    
    # Select drives
    local selected_drives
    selected_drives=$(select_drives "${available_drives[@]}")
    if [[ -z "$selected_drives" ]]; then
        return 1
    fi
    
    # Convert to array
    local drive_array=()
    read -ra drive_array <<< "$selected_drives"
    
    # Create ZFS pool
    cmd_create_zfs "$pool_name" "${drive_array[@]}"
}

# Interactive LVM-thin creation
interactive_create_thin() {
    log "INFO" "=== Create LVM-Thin Pool ==="
    
    # Get available drives
    local available_drives=()
    while IFS= read -r drive_info; do
        local status
        status=$(echo "$drive_info" | cut -d: -f5)
        if [[ "$status" == "AVAILABLE" ]]; then
            available_drives+=("$drive_info")
        fi
    done < <(detect_drives 2>/dev/null || true)
    
    if [[ ${#available_drives[@]} -eq 0 ]]; then
        log "ERROR" "No available drives for LVM-thin"
        return 1
    fi
    
    show_available_drives "${available_drives[@]}"
    
    # Get pool name
    local pool_name
    read -r -p "Enter pool name (e.g., 'storage'): " pool_name
    if [[ -z "$pool_name" ]] || [[ ! "$pool_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log "ERROR" "Invalid pool name. Use only letters, numbers, underscore, and dash."
        return 1
    fi
    
    # Select drives
    local selected_drives
    selected_drives=$(select_drives "${available_drives[@]}")
    if [[ -z "$selected_drives" ]]; then
        return 1
    fi
    
    # Convert to array
    local drive_array=()
    read -ra drive_array <<< "$selected_drives"
    
    # Create LVM-thin pool
    cmd_create_thin "$pool_name" "${drive_array[@]}"
}

# Show available drives helper
show_available_drives() {
    local drives=("$@")
    
    log "INFO" "Available drives:"
    for i in "${!drives[@]}"; do
        local drive_info="${drives[$i]}"
        local drive size model
        drive=$(echo "$drive_info" | cut -d: -f1)
        size=$(echo "$drive_info" | cut -d: -f2)
        model=$(echo "$drive_info" | cut -d: -f4)
        printf "%2d) %s (%s) - %s\n" $((i+1)) "$drive" "$size" "$model"
    done
    echo
}

# Drive selection helper
select_drives() {
    local available_drives=("$@")
    local selected_drives=()
    local drive_indices=()
    
    while true; do
        if [[ ${#selected_drives[@]} -gt 0 ]]; then
            log "INFO" "Selected drives: ${selected_drives[*]}"
        fi
        
        read -r -p "Enter drive number (1-${#available_drives[@]}) or 'done' when finished: " input
        
        if [[ "$input" == "done" ]]; then
            if [[ ${#selected_drives[@]} -eq 0 ]]; then
                log "ERROR" "No drives selected"
                continue
            fi
            break
        fi
        
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
            log "ERROR" "Invalid selection. Enter a number between 1-${#available_drives[@]} or 'done'"
        fi
    done
    
    echo "${selected_drives[*]}"
}

# Show drive information
show_drive_info() {
    log "INFO" "=== Drive Information ==="
    echo "Block devices:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,MODEL 2>/dev/null || echo "lsblk not available"
    echo
    
    log "INFO" "Drive analysis:"
    while IFS= read -r drive_info; do
        local drive size status usage model
        drive=$(echo "$drive_info" | cut -d: -f1)
        size=$(echo "$drive_info" | cut -d: -f2)
        model=$(echo "$drive_info" | cut -d: -f4)
        status=$(echo "$drive_info" | cut -d: -f5)
        usage=$(echo "$drive_info" | cut -d: -f6)
        
        case "$status" in
            "AVAILABLE")
                log "INFO" "  ✅ $drive ($size) - $model - Ready for use"
                ;;
            *)
                log "INFO" "  ⚠️  $drive ($size) - $model - $status ($usage)"
                ;;
        esac
    done < <(detect_drives 2>/dev/null || true)
    
    # Show grouping potential
    echo
    log "INFO" "Drive pairing potential:"
    group_drives_by_size | while IFS= read -r group_info; do
        local group_name drives_in_group
        IFS=':' read -r group_name drives_in_group <<< "$group_info"
        local drive_count
        drive_count=$(echo "$drives_in_group" | wc -w)
        log "INFO" "  📊 $group_name: $drive_count drives of similar size"
        if [[ $drive_count -ge 2 ]]; then
            log "INFO" "     → Perfect for mirroring"
        fi
    done
}

# Storage setup guide
storage_setup_guide() {
    log "INFO" "=== Storage Setup Guide for Proxmox ==="
    echo
    log "INFO" "🎯 RECOMMENDED APPROACH:"
    log "INFO" "1. Use 'Auto-setup storage' for automatic configuration"
    log "INFO" "2. Script will detect drive pairs and create optimal mirrors"
    log "INFO" "3. ZFS is preferred for Proxmox (if available)"
    log "INFO" "4. LVM-thin is good alternative for VM storage"
    echo
    
    log "INFO" "📚 STORAGE TYPE COMPARISON:"
    echo
    log "INFO" "ZFS (Recommended):"
    log "INFO" "  ✅ Built-in RAID, checksumming, compression"
    log "INFO" "  ✅ Copy-on-write snapshots"
    log "INFO" "  ✅ Excellent Proxmox integration"
    log "INFO" "  ✅ Data integrity verification"
    log "INFO" "  ⚠️  Requires more RAM (1GB per TB recommended)"
    echo
    
    log "INFO" "LVM-Thin:"
    log "INFO" "  ✅ Thin provisioning and snapshots"
    log "INFO" "  ✅ Space-efficient for VMs"
    log "INFO" "  ✅ Native Proxmox support"
    log "INFO" "  ⚠️  No built-in redundancy (use with RAID)"
    echo
    
    log "INFO" "LVM Mirror:"
    log "INFO" "  ✅ Simple, reliable mirroring"
    log "INFO" "  ✅ Lower memory overhead"
    log "INFO" "  ✅ Works everywhere"
    log "INFO" "  ⚠️  No compression or advanced features"
    echo
    
    log "INFO" "🔧 SETUP SCENARIOS:"
    log "INFO" "2 drives of same size → ZFS mirror (ideal)"
    log "INFO" "4 drives (2+2 same size) → 2 ZFS mirrors"
    log "INFO" "Mixed drive sizes → LVM-thin with largest drives"
    log "INFO" "Single drives → LVM or ZFS single-disk pools"
    echo
    
    log "INFO" "⚠️  IMPORTANT NOTES:"
    log "INFO" "• Always backup important data first"
    log "INFO" "• Proxmox installation drive is automatically excluded"
    log "INFO" "• Use --dry-run to preview changes"
    log "INFO" "• ZFS pools are automatically added to Proxmox storage"
}

# Main function
main() {
    parse_args "$@"
    
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
                check_requirements
                cmd_clear_all
                ;;
            clear)
                if [[ ${#COMMAND_ARGS[@]} -eq 0 ]]; then
                    log "ERROR" "Usage: clear POOL_NAME or clear VG/LV"
                    log "ERROR" "Example: clear tank (ZFS) or clear data/storage (LVM)"
                    exit 1
                fi
                check_requirements
                cmd_clear_single "${COMMAND_ARGS[0]}"
                ;;
            create-zfs)
                if [[ ${#COMMAND_ARGS[@]} -lt 2 ]]; then
                    log "ERROR" "Usage: create-zfs POOL_NAME DRIVE1 DRIVE2 [DRIVE3...]"
                    log "ERROR" "Example: create-zfs tank /dev/sdb /dev/sdc"
                    exit 1
                fi
                check_requirements
                cmd_create_zfs "${COMMAND_ARGS[@]}"
                ;;
            create-lvm)
                if [[ ${#COMMAND_ARGS[@]} -lt 3 ]]; then
                    log "ERROR" "Usage: create-lvm VG_NAME LV_NAME DRIVE1 DRIVE2 [DRIVE3...]"
                    log "ERROR" "Example: create-lvm data storage /dev/sdb /dev/sdc"
                    exit 1
                fi
                check_requirements
                cmd_create "${COMMAND_ARGS[@]}"
                ;;
            create-thin)
                if [[ ${#COMMAND_ARGS[@]} -lt 2 ]]; then
                    log "ERROR" "Usage: create-thin POOL_NAME DRIVE1 DRIVE2 [DRIVE3...]"
                    log "ERROR" "Example: create-thin storage /dev/sdb /dev/sdc"
                    exit 1
                fi
                check_requirements
                cmd_create_thin "${COMMAND_ARGS[@]}"
                ;;
            auto-setup)
                check_requirements
                cmd_auto_setup
                ;;
            *)
                log "ERROR" "Unknown command: $COMMAND"
                usage
                exit 1
                ;;
        esac
    else
        # Interactive mode
        check_requirements
        main_menu
    fi
}

# Run main function
main "$@"

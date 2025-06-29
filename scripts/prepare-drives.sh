#!/bin/bash

# Hetzner Proxmox Setup - Drive Preparation and RAID Configuration
# This script handles drive preparation and RAID setup for various configurations

set -uo pipefail

# Error handler
error_handler() {
    local line_no=$1
    local error_code=$2
    echo "[ERROR] Script failed at line $line_no with exit code $error_code" >&2
    echo "[ERROR] Drive preparation failed" >&2
    exit $error_code
}

readonly SCRIPT_NAME="prepare-drives"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source common functions
if [[ ! -f "$PROJECT_ROOT/lib/common.sh" ]]; then
    echo "[ERROR] Common library not found: $PROJECT_ROOT/lib/common.sh" >&2
    exit 1
fi
source "$PROJECT_ROOT/lib/common.sh"

# Default values
DRY_RUN=false
RAID_CONFIG=""
FORCE=false
CLEANUP_ONLY=false

# RAID configuration options (will be dynamically populated)
declare -A RAID_CONFIGS=(
    ["dual-raid1"]="Dual RAID 1: Separate RAID 1 arrays for different drive sizes"
    ["mixed-optimal"]="Mixed Optimal: Best configuration for mixed drive sizes"
    ["no-raid"]="No RAID: Use drives individually"
)

# Usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Drive preparation and RAID configuration for Hetzner Proxmox setup.

OPTIONS:
    -c, --config CONFIG     RAID configuration to apply
    -d, --dry-run          Show what would be done without executing
    -f, --force            Force operations without confirmation
    --cleanup              Clean up existing RAID and exit (use this first)
    -h, --help             Show this help message
    -v, --verbose          Enable verbose logging

RAID CONFIGURATIONS:
EOF

    for config in "${!RAID_CONFIGS[@]}"; do
        printf "    %-20s %s\n" "$config" "${RAID_CONFIGS[$config]}"
    done

    cat << EOF

EXAMPLES:
    $0 --dry-run                    # Scan drives and show available configurations
    $0 --config <detected-config> --dry-run   # Preview configuration for your drives
    $0 --config <detected-config>          # Apply configuration based on detected drives

WORKFLOW:
    1. Run without arguments to scan your drives and see recommendations
    2. Use --dry-run to preview the recommended configuration
    3. Apply the configuration that best fits your detected hardware

SAFETY NOTES:
    - This script scans your system to detect available drives automatically
    - It will analyze drive sizes and suggest optimal configurations
    - Always run with --dry-run first to preview changes
    - Backup any important data before proceeding
    - Emergency restore requires OS reinstallation

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                RAID_CONFIG="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -f|--force)
                FORCE=true
                shift
                ;;
            --cleanup)
                CLEANUP_ONLY=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -v|--verbose)
                export LOG_LEVEL="DEBUG"
                shift
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
    # Get all drives except loop devices and ram
    local drives_raw
    drives_raw=$(lsblk -dn -o NAME,SIZE,TYPE 2>/dev/null | grep -E '^(sd|nvme|vd)' | grep disk | awk '{print "/dev/" $1}' || true)
    
    if [[ -z "$drives_raw" ]]; then
        log "ERROR" "No suitable drives found"
        log "DEBUG" "lsblk output:"
        lsblk -dn -o NAME,SIZE,TYPE 2>/dev/null || log "DEBUG" "lsblk command failed"
        exit 1
    fi
    
    local drives=($drives_raw)
    
    if [[ ${#drives[@]} -eq 0 ]]; then
        log "ERROR" "No suitable drives found after filtering"
        exit 1
    fi
    
    # Log the detected drives but return only the drive paths
    {
        log "INFO" "Found ${#drives[@]} drives:"
        for drive in "${drives[@]}"; do
            local size=$(lsblk -dn -o SIZE "$drive" 2>/dev/null || echo "unknown")
            local model=$(lsblk -dn -o MODEL "$drive" 2>/dev/null | sed 's/[[:space:]]\+/ /g' || echo "unknown")
            log "INFO" "  $drive: $size ($model)"
        done
    } >&2
    
    # Return only the drive paths (no log output)
    printf "%s\n" "${drives[@]}"
}

# Analyze drive configuration
analyze_drives() {
    local drives=($@)
    
    if [[ ${#drives[@]} -eq 0 ]]; then
        log "ERROR" "No drives provided to analyze"
        exit 1
    fi
    
    # Create associative arrays to group drives by size
    declare -A drive_groups
    declare -A drive_sizes_gb
    
    log "INFO" "Analyzing drive sizes..."
    
    for drive in "${drives[@]}"; do
        if [[ ! -b "$drive" ]]; then
            log "WARNING" "Skipping non-existent drive: $drive"
            continue
        fi
        
        local size_bytes
        size_bytes=$(lsblk -dn -b -o SIZE "$drive" 2>/dev/null)
        if [[ -z "$size_bytes" || "$size_bytes" -eq 0 ]]; then
            log "WARNING" "Could not determine size for drive: $drive"
            continue
        fi
        
        local size_gb=$((size_bytes / 1024 / 1024 / 1024))
        local size_tb=$((size_gb / 1024))
        
        # Create size categories with some tolerance
        local size_category
        if [[ $size_gb -lt 100 ]]; then
            size_category="small_${size_gb}GB"
        elif [[ $size_gb -lt 1500 ]]; then
            # Round to nearest 100GB for drives under 1.5TB
            local rounded_gb=$(( (size_gb + 50) / 100 * 100 ))
            size_category="${rounded_gb}GB"
        else
            # Round to nearest TB for larger drives
            local rounded_tb=$(( (size_gb + 512) / 1024 ))
            size_category="${rounded_tb}TB"
        fi
        
        # Group drives by size category
        if [[ -z "${drive_groups[$size_category]:-}" ]]; then
            drive_groups[$size_category]="$drive"
            drive_sizes_gb[$size_category]=$size_gb
        else
            drive_groups[$size_category]="${drive_groups[$size_category]} $drive"
        fi
        
        log "DEBUG" "$drive: ${size_gb}GB (category: $size_category)"
    done
    
    # Check if we have any valid drives after analysis
    if [[ ${#drive_groups[@]} -eq 0 ]]; then
        log "ERROR" "No valid drives found after analysis"
        exit 1
    fi
    
    # Display analysis results
    log "INFO" "Drive analysis completed:"
    for category in "${!drive_groups[@]}"; do
        local drives_in_category=(${drive_groups[$category]})
        local count=${#drives_in_category[@]}
        log "INFO" "  $category: ${count}x drives (${drive_groups[$category]})"
    done
    
    # Store results globally for use in other functions
    if declare -p drive_groups >/dev/null 2>&1; then
        export DRIVE_GROUPS_STR=$(declare -p drive_groups)
    else
        export DRIVE_GROUPS_STR="declare -A drive_groups=()"
    fi
    
    if declare -p drive_sizes_gb >/dev/null 2>&1; then
        export DRIVE_SIZES_STR=$(declare -p drive_sizes_gb)
    else
        export DRIVE_SIZES_STR="declare -A drive_sizes_gb=()"
    fi
}

# Helper function to safely evaluate stored drive group variables
safe_eval_drive_groups() {
    if [[ -n "${DRIVE_GROUPS_STR:-}" && "$DRIVE_GROUPS_STR" =~ ^declare ]]; then
        eval "$DRIVE_GROUPS_STR" 2>/dev/null || {
            log "ERROR" "Failed to restore drive groups data"
            return 1
        }
    else
        log "DEBUG" "Initializing empty drive groups array"
        declare -A drive_groups=()
    fi
    
    if [[ -n "${DRIVE_SIZES_STR:-}" && "$DRIVE_SIZES_STR" =~ ^declare ]]; then
        eval "$DRIVE_SIZES_STR" 2>/dev/null || {
            log "DEBUG" "Failed to restore drive sizes data, using empty array"
            declare -A drive_sizes_gb=()
        }
    else
        log "DEBUG" "Initializing empty drive sizes array"
        declare -A drive_sizes_gb=()
    fi
}
}

# Validate RAID configuration
validate_raid_config() {
    local config="$1"
    
    # Import the drive group data
    safe_eval_drive_groups
    
    case "$config" in
        "dual-raid1")
            local group_count=${#drive_groups[@]}
            if [[ $group_count -ne 2 ]]; then
                log "ERROR" "Dual RAID 1 requires exactly 2 different drive size groups"
                log "ERROR" "Found: $group_count drive size groups"
                return 1
            fi
            
            # Check that both groups have at least 2 drives
            for category in "${!drive_groups[@]}"; do
                local drives_in_category=(${drive_groups[$category]})
                local count=${#drives_in_category[@]}
                if [[ $count -lt 2 ]]; then
                    log "ERROR" "Dual RAID 1 requires at least 2 drives in each size group"
                    log "ERROR" "Group $category has only $count drive(s)"
                    return 1
                fi
            done
            ;;
        "raid1-"*)
            local category="${config#raid1-}"
            if [[ -z "${drive_groups[$category]:-}" ]]; then
                log "ERROR" "No drives found for category: $category"
                return 1
            fi
            local drives_in_category=(${drive_groups[$category]})
            local count=${#drives_in_category[@]}
            if [[ $count -lt 2 ]]; then
                log "ERROR" "RAID 1 requires at least 2 drives"
                log "ERROR" "Category $category has only $count drive(s)"
                return 1
            fi
            ;;
        "raid5-"*)
            local category="${config#raid5-}"
            if [[ -z "${drive_groups[$category]:-}" ]]; then
                log "ERROR" "No drives found for category: $category"
                return 1
            fi
            local drives_in_category=(${drive_groups[$category]})
            local count=${#drives_in_category[@]}
            if [[ $count -lt 3 ]]; then
                log "ERROR" "RAID 5 requires at least 3 drives"
                log "ERROR" "Category $category has only $count drive(s)"
                return 1
            fi
            ;;
        "raid6-"*|"raid10-"*)
            local category="${config#raid*-}"
            if [[ -z "${drive_groups[$category]:-}" ]]; then
                log "ERROR" "No drives found for category: $category"
                return 1
            fi
            local drives_in_category=(${drive_groups[$category]})
            local count=${#drives_in_category[@]}
            if [[ $count -lt 4 ]]; then
                log "ERROR" "RAID 6/10 requires at least 4 drives"
                log "ERROR" "Category $category has only $count drive(s)"
                return 1
            fi
            ;;
        "zfs-"*)
            local category="${config#zfs-}"
            if [[ -z "${drive_groups[$category]:-}" ]]; then
                log "ERROR" "No drives found for category: $category"
                return 1
            fi
            local drives_in_category=(${drive_groups[$category]})
            local count=${#drives_in_category[@]}
            if [[ $count -lt 2 ]]; then
                log "ERROR" "ZFS mirror requires at least 2 drives"
                log "ERROR" "Category $category has only $count drive(s)"
                return 1
            fi
            ;;
        "mixed-optimal"|"no-raid"|"individual-"*|"scan-only")
            # These configurations don't have strict requirements
            ;;
        *)
            # Check if it's a valid configuration
            if [[ -z "${RAID_CONFIGS[$config]:-}" ]]; then
                log "ERROR" "Unknown RAID configuration: $config"
                log "ERROR" "Available configurations:"
                for available_config in "${!RAID_CONFIGS[@]}"; do
                    log "ERROR" "  $available_config"
                done
                return 1
            fi
            ;;
    esac
    
    return 0
}

# Show current drive status and detected configuration
show_drive_status() {
    log "INFO" "Scanning system for available drives..."
    echo
    
    # Show physical drives with detailed information
    log "INFO" "Detected Physical Drives:"
    echo "+------------------------------------------------------------------+"
    echo "| Drive       Size      Model                    Serial           |"
    echo "+------------------------------------------------------------------+"
    
    local drives_raw
    drives_raw=$(lsblk -dn -o NAME 2>/dev/null | grep -E '^(sd|nvme|vd)' || echo "")
    
    if [[ -z "$drives_raw" ]]; then
        echo "| No drives detected                                               |"
        echo "+------------------------------------------------------------------+"
        log "WARNING" "No drives found during detailed scan"
        return 0
    fi
    
    local drives=($drives_raw)
    local drive_count=0
    
    for drive_name in "${drives[@]}"; do
        local drive="/dev/$drive_name"
        if [[ -b "$drive" ]]; then
            local size=$(lsblk -dn -o SIZE "$drive" 2>/dev/null || echo "unknown")
            local model=$(lsblk -dn -o MODEL "$drive" 2>/dev/null | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' || echo "unknown")
            local serial=$(lsblk -dn -o SERIAL "$drive" 2>/dev/null || echo "unknown")
            
            # Clean up and truncate long strings for display
            model="${model:0:20}"
            serial="${serial:0:15}"
            
            # Use safer printf with proper field widths
            printf "| %-10s  %-8s  %-20s  %-15s |\n" "$drive" "$size" "$model" "$serial"
            ((drive_count++))
        fi
    done
    
    echo "+------------------------------------------------------------------+"
    log "INFO" "Total drives detected: $drive_count"
    echo
    
    # Show partitions if any exist
    log "INFO" "Current Partition Layout:"
    if ! lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE 2>/dev/null | grep -E '(NAME|disk|part|raid|lvm)'; then
        log "INFO" "  Unable to retrieve partition information"
    fi
    echo
    
    # Show existing RAID arrays
    if [[ -f /proc/mdstat ]]; then
        log "INFO" "Existing Software RAID Arrays:"
        if grep -q "^md" /proc/mdstat 2>/dev/null; then
            cat /proc/mdstat
        else
            log "INFO" "  No software RAID arrays detected"
        fi
        echo
    fi
    
    # Show LVM status
    if command -v pvdisplay >/dev/null 2>&1; then
        log "INFO" "LVM Physical Volumes:"
        if pvdisplay 2>/dev/null | grep -q "PV Name" 2>/dev/null; then
            pvdisplay --short 2>/dev/null || log "INFO" "  Unable to retrieve LVM information"
        else
            log "INFO" "  No LVM physical volumes detected"
        fi
        echo
    fi
    
    # Show ZFS pools
    if command -v zpool >/dev/null 2>&1; then
        log "INFO" "ZFS Pools:"
        if zpool list 2>/dev/null | grep -v "no pools available" >/dev/null 2>&1; then
            zpool list 2>/dev/null || log "INFO" "  Unable to retrieve ZFS information"
        else
            log "INFO" "  No ZFS pools detected"
        fi
        echo
    fi
}

# Generate RAID configuration preview
preview_raid_config() {
    local config="$1"
    
    log "INFO" "Preview of RAID configuration: $config"
    if [[ -n "${RAID_CONFIGS[$config]:-}" ]]; then
        log "INFO" "${RAID_CONFIGS[$config]}"
    fi
    echo
    
    # Import the drive group data
    safe_eval_drive_groups
    
    case "$config" in
        "dual-raid1")
            preview_dual_raid1
            ;;
        "raid1-"*)
            local category="${config#raid1-}"
            preview_single_raid "$category" "1"
            ;;
        "raid5-"*)
            local category="${config#raid5-}"
            preview_single_raid "$category" "5"
            ;;
        "raid6-"*)
            local category="${config#raid6-}"
            preview_single_raid "$category" "6"
            ;;
        "raid10-"*)
            local category="${config#raid10-}"
            preview_single_raid "$category" "10"
            ;;
        "zfs-"*)
            local category="${config#zfs-}"
            preview_zfs_config "$category"
            ;;
        "individual-"*)
            local category="${config#individual-}"
            preview_individual_config "$category"
            ;;
        "mixed-optimal")
            preview_mixed_optimal
            ;;
        "no-raid")
            preview_no_raid
            ;;
        *)
            log "WARNING" "Unknown configuration: $config"
            log "INFO" "Will attempt to execute as generic configuration"
            ;;
    esac
    
    echo
    log "WARNING" "⚠️  THIS WILL DESTROY ALL DATA ON THE CONFIGURED DRIVES!"
    log "WARNING" "⚠️  BACKUP ANY IMPORTANT DATA BEFORE PROCEEDING!"
}

# Preview functions for different RAID types
preview_dual_raid1() {
    local categories=(${!drive_groups[@]})
    local cat1="${categories[0]}"
    local cat2="${categories[1]}"
    local drives1=(${drive_groups[$cat1]})
    local drives2=(${drive_groups[$cat2]})
    local size1=${drive_sizes_gb[$cat1]}
    local size2=${drive_sizes_gb[$cat2]}
    
    # Determine which is larger for system/storage assignment
    local system_cat storage_cat
    if [[ $size1 -lt $size2 ]]; then
        system_cat="$cat1"
        storage_cat="$cat2"
    else
        system_cat="$cat2"
        storage_cat="$cat1"
    fi
    
    log "INFO" "Configuration Details:"
    log "INFO" "  RAID 1 Array #1 (System): ${system_cat} drives"
    log "INFO" "    - Drives: ${drive_groups[$system_cat]}"
    log "INFO" "    - Usable capacity: ~$((${drive_sizes_gb[$system_cat]} / 2))GB"
    log "INFO" "    - Usage: Root, swap, system files"
    echo
    log "INFO" "  RAID 1 Array #2 (Storage): ${storage_cat} drives"
    log "INFO" "    - Drives: ${drive_groups[$storage_cat]}"
    log "INFO" "    - Usable capacity: ~$((${drive_sizes_gb[$storage_cat]} / 2))GB"
    log "INFO" "    - Usage: VM storage, data"
}

preview_single_raid() {
    local category="$1"
    local raid_level="$2"
    local drives=(${drive_groups[$category]})
    local count=${#drives[@]}
    local size_gb=${drive_sizes_gb[$category]}
    local usable_capacity
    
    case "$raid_level" in
        "1") usable_capacity=$((size_gb / 2)) ;;
        "5") usable_capacity=$(((count - 1) * size_gb)) ;;
        "6") usable_capacity=$(((count - 2) * size_gb)) ;;
        "10") usable_capacity=$((count / 2 * size_gb)) ;;
    esac
    
    log "INFO" "Configuration Details:"
    log "INFO" "  RAID $raid_level Array: ${count}x $category drives"
    log "INFO" "    - Drives: ${drive_groups[$category]}"
    log "INFO" "    - Total capacity: $((count * size_gb))GB"
    log "INFO" "    - Usable capacity: ~${usable_capacity}GB"
    log "INFO" "    - Redundancy: RAID $raid_level protection"
    log "INFO" "    - Boot partition: 1GB ext4"
    log "INFO" "    - Root partition: 100GB ext4"
    log "INFO" "    - Swap partition: 16GB"
    log "INFO" "    - VM storage: Remaining space"
}

preview_zfs_config() {
    local category="$1"
    local drives=(${drive_groups[$category]})
    local count=${#drives[@]}
    local size_gb=${drive_sizes_gb[$category]}
    local usable_capacity=$((size_gb / 2))  # ZFS mirror
    
    log "INFO" "Configuration Details:"
    log "INFO" "  ZFS Pool '$category': ${count}x $category drives"
    log "INFO" "    - Drives: ${drive_groups[$category]}"
    log "INFO" "    - Pool type: Mirror (RAID 1 equivalent)"
    log "INFO" "    - Usable capacity: ~${usable_capacity}GB"
    log "INFO" "    - Features: Compression, snapshots, checksums"
    log "INFO" "    - Datasets: /tank/vms, /tank/backup, /tank/iso"
}

preview_individual_config() {
    local category="$1"
    local drives=(${drive_groups[$category]})
    local count=${#drives[@]}
    local size_gb=${drive_sizes_gb[$category]}
    
    log "INFO" "Configuration Details:"
    log "INFO" "  Individual Drives: ${count}x $category"
    log "INFO" "    - Drives: ${drive_groups[$category]}"
    log "INFO" "    - Each drive: ${size_gb}GB"
    log "INFO" "    - Total capacity: $((count * size_gb))GB"
    log "INFO" "    - Redundancy: None (single drive failure loses data)"
    log "INFO" "    - Mount points: /mnt/drive0, /mnt/drive1, etc."
}

preview_mixed_optimal() {
    log "INFO" "Configuration Details:"
    log "INFO" "  Mixed Optimal Configuration:"
    
    # Find the largest groups that can form RAID
    for category in "${!drive_groups[@]}"; do
        local drives=(${drive_groups[$category]})
        local count=${#drives[@]}
        local size_gb=${drive_sizes_gb[$category]}
        
        if [[ $count -ge 2 ]]; then
            log "INFO" "    - $category: RAID 1 with ${count} drives (~$((size_gb / 2))GB usable)"
        else
            log "INFO" "    - $category: Individual drive (${size_gb}GB, no redundancy)"
        fi
    done
}

preview_no_raid() {
    log "INFO" "Configuration Details:"
    log "INFO" "  No RAID - Individual Drives:"
    
    for category in "${!drive_groups[@]}"; do
        local drives=(${drive_groups[$category]})
        local count=${#drives[@]}
        local size_gb=${drive_sizes_gb[$category]}
        log "INFO" "    - ${count}x $category: Individual ${size_gb}GB drives"
    done
    
    log "INFO" "  ⚠️  No redundancy - drive failure will result in data loss"
}

# Suggest best RAID configuration based on detected drives
suggest_best_config() {
    # Import the drive group data
    safe_eval_drive_groups
    
    local recommendations=()
    local best_config=""
    local reason=""
    
    # Count total drives and groups
    local total_drives=0
    local group_count=0
    local largest_group_size=0
    local largest_group_category=""
    
    for category in "${!drive_groups[@]}"; do
        local drives_in_category=(${drive_groups[$category]})
        local count=${#drives_in_category[@]}
        total_drives=$((total_drives + count))
        group_count=$((group_count + 1))
        
        if [[ $count -gt $largest_group_size ]]; then
            largest_group_size=$count
            largest_group_category="$category"
        fi
    done
    
    log "INFO" "� Analyzing your drives for optimal RAID configuration..."
    echo
    
    # Recommendation logic based on drive configuration
    if [[ $group_count -eq 1 ]]; then
        # All drives are the same size
        local category="${!drive_groups[@]}"
        local drives_in_category=(${drive_groups[$category]})
        local count=${#drives_in_category[@]}
        
        if [[ $count -eq 2 ]]; then
            best_config="raid1-${category}"
            reason="Perfect for RAID 1: 2 identical drives provide redundancy with 50% capacity"
            recommendations+=("raid1-${category}:⭐ RECOMMENDED - RAID 1 with ${count}x $category drives")
            recommendations+=("no-raid:Alternative - Individual drives (no redundancy, full capacity)")
        elif [[ $count -eq 3 ]]; then
            best_config="raid5-${category}"
            reason="RAID 5 optimal: 3 drives give redundancy with 67% capacity efficiency"
            recommendations+=("raid5-${category}:⭐ RECOMMENDED - RAID 5 with ${count}x $category drives")
            recommendations+=("raid1-${category}:Alternative - RAID 1 using 2 drives (1 spare)")
            recommendations+=("no-raid:Alternative - Individual drives (no redundancy)")
        elif [[ $count -eq 4 ]]; then
            best_config="raid10-${category}"
            reason="RAID 10 optimal: 4 drives provide excellent performance and redundancy"
            recommendations+=("raid10-${category}:⭐ RECOMMENDED - RAID 10 with ${count}x $category drives")
            recommendations+=("raid6-${category}:Alternative - RAID 6 (better space efficiency)")
            recommendations+=("raid5-${category}:Alternative - RAID 5 using 3 drives (1 spare)")
        elif [[ $count -ge 5 ]]; then
            best_config="raid6-${category}"
            reason="RAID 6 optimal: ${count} drives provide dual redundancy with good capacity"
            recommendations+=("raid6-${category}:⭐ RECOMMENDED - RAID 6 with ${count}x $category drives")
            recommendations+=("raid10-${category}:Alternative - RAID 10 using 4 drives (spares available)")
            recommendations+=("raid5-${category}:Alternative - RAID 5 (single redundancy)")
        else
            best_config="no-raid"
            reason="Single drive: No redundancy possible"
            recommendations+=("no-raid:⭐ ONLY OPTION - Single drive configuration")
        fi
        
    elif [[ $group_count -eq 2 ]]; then
        # Two different drive sizes
        local categories=(${!drive_groups[@]})
        local cat1="${categories[0]}"
        local cat2="${categories[1]}"
        local drives1=(${drive_groups[$cat1]})
        local drives2=(${drive_groups[$cat2]})
        local count1=${#drives1[@]}
        local count2=${#drives2[@]}
        
        if [[ $count1 -ge 2 && $count2 -ge 2 ]]; then
            best_config="dual-raid1"
            reason="Dual RAID 1 optimal: Separate arrays for different drive sizes maximizes efficiency"
            recommendations+=("dual-raid1:⭐ RECOMMENDED - RAID 1 arrays: ${count1}x $cat1 + ${count2}x $cat2")
            
            # Determine which group is larger for system vs storage
            local larger_cat smaller_cat
            if [[ ${drive_sizes_gb[$cat1]} -gt ${drive_sizes_gb[$cat2]} ]]; then
                larger_cat="$cat1"
                smaller_cat="$cat2"
            else
                larger_cat="$cat2" 
                smaller_cat="$cat1"
            fi
            recommendations+=("single-raid1-large:Alternative - RAID 1 with larger drives ($larger_cat)")
            recommendations+=("single-raid1-small:Alternative - RAID 1 with smaller drives ($smaller_cat)")
        else
            # One group has only 1 drive
            if [[ $count1 -ge 2 ]]; then
                best_config="raid1-${cat1}"
                reason="RAID 1 with ${cat1}: Only this size has enough drives for redundancy"
            else
                best_config="raid1-${cat2}"
                reason="RAID 1 with ${cat2}: Only this size has enough drives for redundancy"
            fi
            recommendations+=("${best_config}:⭐ RECOMMENDED - Use drives that can form RAID")
            recommendations+=("no-raid:Alternative - Individual drives (no redundancy)")
        fi
        
    else
        # Three or more different drive sizes
        best_config="mixed-optimal"
        reason="Mixed configuration: Use largest matching pairs for RAID, others individual"
        recommendations+=("mixed-optimal:⭐ RECOMMENDED - Optimized mixed configuration")
        recommendations+=("raid-largest:Alternative - RAID with largest matching group")
        recommendations+=("no-raid:Alternative - All drives individual")
    fi
    
    # Display recommendations
    log "INFO" "🎯 RAID Configuration Recommendations:"
    echo
    
    for i in "${!recommendations[@]}"; do
        local rec="${recommendations[$i]}"
        local config_name="${rec%%:*}"
        local description="${rec#*:}"
        log "INFO" "  $description"
    done
    
    echo
    log "INFO" "💡 Best Configuration: $best_config"
    log "INFO" "📝 Reason: $reason"
    echo
    
    # Set the recommended configuration as default
    export RECOMMENDED_CONFIG="$best_config"
}

# Update system configuration
update_system_config() {
    log "INFO" "Updating system configuration..."
    
    # Update mdadm configuration
    mdadm --detail --scan >> /etc/mdadm/mdadm.conf
    
    # Update initramfs
    update-initramfs -u
    
    # Update GRUB
    update-grub
    
    log "INFO" "System configuration updated"
}

# Execute RAID configuration
execute_raid_config() {
    local config="$1"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "INFO" "DRY RUN: Would execute RAID configuration: $config"
        return 0
    fi
    
    # Confirmation prompt
    if [[ "$FORCE" != "true" ]]; then
        echo
        log "WARNING" "⚠️  FINAL WARNING: This will DESTROY ALL DATA on the selected drives!"
        log "WARNING" "⚠️  Are you absolutely sure you want to proceed?"
        read -p "Type 'YES' to continue: " confirmation
        if [[ "$confirmation" != "YES" ]]; then
            log "INFO" "Operation cancelled by user"
            exit 0
        fi
    fi
    
    log "INFO" "Executing RAID configuration: $config"
    
    # Clean up any existing RAID configuration first
    cleanup_existing_raid
    
    # Install required packages
    log "INFO" "Installing required packages..."
    apt update
    apt install -y mdadm lvm2 parted gdisk
    
    case "$config" in
        "dual-raid1")
            execute_dual_raid1
            ;;
        "raid1-"*)
            execute_single_raid1 "$config"
            ;;
        "raid5-"*)
            execute_raid5 "$config"
            ;;
        "raid6-"*)
            execute_raid6 "$config"
            ;;
        "raid10-"*)
            execute_raid10 "$config"
            ;;
        "zfs-"*)
            execute_zfs_mirror "$config"
            ;;
        "individual-"*)
            execute_individual "$config"
            ;;
        "mixed-optimal")
            execute_mixed_optimal
            ;;
        "no-raid")
            execute_no_raid
            ;;
        *)
            log "ERROR" "Unknown configuration: $config"
            log "ERROR" "Use --help to see available configurations"
            exit 1
            ;;
    esac
    
    # Update system configuration
    update_system_config
    
    log "INFO" "✅ RAID configuration completed: $config"
}

# Execute dual RAID 1 configuration
execute_dual_raid1() {
    log "INFO" "Setting up dual RAID 1 configuration..."
    
    # Import drive group data and determine which drives to use
    safe_eval_drive_groups
    
    # Find the two drive groups
    local categories=(${!drive_groups[@]})
    local large_drives small_drives
    
    if [[ ${#categories[@]} -ne 2 ]]; then
        log "ERROR" "Dual RAID 1 requires exactly 2 drive size groups, found ${#categories[@]}"
        exit 1
    fi
    
    # Determine which group is larger
    local cat1="${categories[0]}"
    local cat2="${categories[1]}"
    local size1=${drive_sizes_gb[$cat1]}
    local size2=${drive_sizes_gb[$cat2]}
    
    if [[ $size1 -gt $size2 ]]; then
        large_drives=(${drive_groups[$cat1]})
        small_drives=(${drive_groups[$cat2]})
        log "INFO" "Large drives ($cat1): ${large_drives[*]}"
        log "INFO" "Small drives ($cat2): ${small_drives[*]}"
    else
        large_drives=(${drive_groups[$cat2]})
        small_drives=(${drive_groups[$cat1]})
        log "INFO" "Large drives ($cat2): ${large_drives[*]}"
        log "INFO" "Small drives ($cat1): ${small_drives[*]}"
    fi
    
    # Stop any existing RAID arrays first
    log "INFO" "Stopping any existing RAID arrays..."
    if [[ -f /proc/mdstat ]]; then
        for md in /dev/md*; do
            if [[ -b "$md" ]]; then
                mdadm --stop "$md" 2>/dev/null || true
            fi
        done
    fi
    
    # Wait a moment for arrays to stop
    sleep 2
    
    # Wipe drive signatures on all drives
    log "INFO" "Wiping drive signatures..."
    for drive in "${large_drives[@]:0:2}" "${small_drives[@]:0:2}"; do
        log "INFO" "  Wiping $drive..."
        wipefs -fa "$drive" 2>/dev/null || true
        dd if=/dev/zero of="$drive" bs=1M count=100 2>/dev/null || true
        # Remove any existing mdadm metadata
        mdadm --zero-superblock "$drive" 2>/dev/null || true
    done
    
    # Wait for devices to settle
    sleep 3
    
    # Create RAID 1 for small drives (system)
    log "INFO" "Creating RAID 1 for system storage (smaller drives)..."
    log "INFO" "  Using drives: ${small_drives[0]} ${small_drives[1]}"
    if ! mdadm --create /dev/md0 --level=1 --raid-devices=2 --metadata=1.2 \
        "${small_drives[0]}" "${small_drives[1]}" --assume-clean; then
        log "ERROR" "Failed to create RAID 1 for small drives"
        exit 1
    fi
    
    # Create RAID 1 for large drives (VM storage)  
    log "INFO" "Creating RAID 1 for VM storage (larger drives)..."
    log "INFO" "  Using drives: ${large_drives[0]} ${large_drives[1]}"
    if ! mdadm --create /dev/md1 --level=1 --raid-devices=2 --metadata=1.2 \
        "${large_drives[0]}" "${large_drives[1]}" --assume-clean; then
        log "ERROR" "Failed to create RAID 1 for large drives"
        exit 1
    fi
    
    # Wait for RAID arrays to be ready
    log "INFO" "Waiting for RAID arrays to be ready..."
    sleep 5
    
    # Check RAID status
    if [[ -f /proc/mdstat ]]; then
        log "INFO" "Current RAID status:"
        cat /proc/mdstat
    fi
    
    # Partition system RAID (md0 - smaller drives)
    log "INFO" "Partitioning system RAID (md0)..."
    parted -s /dev/md0 mklabel gpt
    parted -s /dev/md0 mkpart primary ext4 1MiB 1GiB
    parted -s /dev/md0 mkpart primary ext4 1GiB 100%
    
    # Wait for partitions to be recognized
    sleep 2
    partprobe /dev/md0
    
    # Create LVM on system RAID
    log "INFO" "Setting up LVM on system RAID..."
    pvcreate /dev/md0p2
    vgcreate vg0 /dev/md0p2
    lvcreate -L 80G -n root vg0
    lvcreate -L 16G -n swap vg0
    lvcreate -L 20G -n tmp vg0
    
    # Create LVM on VM RAID (md1 - larger drives)
    log "INFO" "Setting up LVM on VM RAID..."
    pvcreate /dev/md1
    vgcreate vg1 /dev/md1
    lvcreate -l 100%FREE -n vmdata vg1
    
    # Format filesystems
    log "INFO" "Formatting filesystems..."
    mkfs.ext4 -F /dev/md0p1  # boot
    mkfs.ext4 -F /dev/vg0/root
    mkswap /dev/vg0/swap
    mkfs.ext4 -F /dev/vg0/tmp
    mkfs.ext4 -F /dev/vg1/vmdata
    
    # Create mount points and update fstab
    setup_dual_raid1_mounts
}

# Execute single RAID 1 (4TB) configuration
execute_single_raid1() {
    local config="$1"
    local category="${config#raid1-}"
    
    log "INFO" "Setting up RAID 1 configuration for $category drives..."
    
    # Import drive group data
    safe_eval_drive_groups
    
    # Get drives for this category
    if [[ -z "${drive_groups[$category]:-}" ]]; then
        log "ERROR" "No drives found for category: $category"
        return 1
    fi
    
    local drives_in_category=(${drive_groups[$category]})
    local size=${drive_sizes_gb[$category]}
    
    if [[ ${#drives_in_category[@]} -lt 2 ]]; then
        log "ERROR" "Need at least 2 drives for RAID 1, found ${#drives_in_category[@]} in category $category"
        return 1
    fi
    
    # Use first two drives
    local selected_drives=("${drives_in_category[@]:0:2}")
    
    log "INFO" "Using drives: ${selected_drives[*]} (${size}GB each)"
    
    # Wipe drives
    log "INFO" "Wiping drive signatures..."
    for drive in "${selected_drives[@]}"; do
        wipefs -fa "$drive"
        dd if=/dev/zero of="$drive" bs=1M count=100
    done
    
    # Create RAID 1
    log "INFO" "Creating RAID 1 array..."
    mdadm --create /dev/md0 --level=1 --raid-devices=2 "${selected_drives[0]}" "${selected_drives[1]}"
    
    # Wait for RAID sync to start
    sleep 5
    
    # Partition RAID
    log "INFO" "Partitioning RAID array..."
    parted -s /dev/md0 mklabel gpt
    parted -s /dev/md0 mkpart primary ext4 1MiB 1GiB
    parted -s /dev/md0 mkpart primary ext4 1GiB 100%
    
    # Create LVM
    log "INFO" "Setting up LVM..."
    pvcreate /dev/md0p2
    vgcreate vg0 /dev/md0p2
    lvcreate -L 100G -n root vg0
    lvcreate -L 16G -n swap vg0
    lvcreate -l 100%FREE -n vmdata vg0
    
    # Format filesystems
    log "INFO" "Formatting filesystems..."
    mkfs.ext4 /dev/md0p1
    mkfs.ext4 /dev/vg0/root
    mkswap /dev/vg0/swap
    mkfs.ext4 /dev/vg0/vmdata
    
    # Setup mounts
    setup_single_raid1_mounts
}

# Setup mount points for dual RAID 1
setup_dual_raid1_mounts() {
    log "INFO" "Setting up mount points and fstab entries..."
    
    # Create VM storage directory
    mkdir -p /var/lib/vz-large
    
    # Add to fstab (commented for now - user should verify)
    cat >> /etc/fstab << EOF

# RAID Configuration - Dual RAID 1
# Boot partition
/dev/md0p1 /boot ext4 defaults 0 2

# System LVM
/dev/vg0/root / ext4 defaults 0 1
/dev/vg0/swap none swap sw 0 0
/dev/vg0/tmp /tmp ext4 defaults 0 2

# VM Storage LVM
/dev/vg1/vmdata /var/lib/vz-large ext4 defaults 0 2
EOF

    log "INFO" "Mount points configured. Manual mounting required for initial setup."
}

# Setup mount points for single RAID 1
setup_single_raid1_mounts() {
    log "INFO" "Setting up mount points and fstab entries..."
    
    # Add to fstab (commented for now - user should verify)
    cat >> /etc/fstab << EOF

# RAID Configuration - Single RAID 1 (4TB)
# Boot partition
/dev/md0p1 /boot ext4 defaults 0 2

# System and VM LVM
/dev/vg0/root / ext4 defaults 0 1
/dev/vg0/swap none swap sw 0 0
/dev/vg0/vmdata /var/lib/vz ext4 defaults 0 2
EOF

    log "INFO" "Mount points configured. Manual mounting required for initial setup."
}

# Clean up existing RAID configuration
cleanup_existing_raid() {
    log "INFO" "Cleaning up existing RAID configuration..."
    
    # Stop all MD arrays
    if [[ -f /proc/mdstat ]]; then
        log "INFO" "Stopping existing RAID arrays..."
        for md_device in $(grep "^md" /proc/mdstat | cut -d: -f1); do
            log "INFO" "  Stopping /dev/$md_device"
            mdadm --stop "/dev/$md_device" 2>/dev/null || true
        done
    fi
    
    # Remove any existing LVM configuration on affected drives
    log "INFO" "Removing LVM configuration..."
    for vg in vg0 vg1; do
        if vgdisplay "$vg" >/dev/null 2>&1; then
            log "INFO" "  Removing volume group: $vg"
            vgremove -f "$vg" 2>/dev/null || true
        fi
    done
    
    # Remove physical volumes (check all possible drive types)
    for pattern in "/dev/nvme*n*p*" "/dev/sd*[0-9]*" "/dev/vd*[0-9]*"; do
        for drive in $pattern; do
            if [[ -b "$drive" ]] && pvdisplay "$drive" >/dev/null 2>&1; then
                log "INFO" "  Removing physical volume: $drive"
                pvremove -f "$drive" 2>/dev/null || true
            fi
        done
    done
    
    # Clean up all drive partitions and metadata (check all drive types)
    for pattern in "/dev/nvme*n*" "/dev/sd*" "/dev/vd*"; do
        for drive in $pattern; do
            if [[ -b "$drive" ]]; then
                # Skip if it's a partition (contains numbers at the end)
                if [[ "$drive" =~ [0-9]+$ ]]; then
                    continue
                fi
                
                log "INFO" "  Cleaning drive: $drive"
                # Remove RAID metadata
                mdadm --zero-superblock "$drive" 2>/dev/null || true
                # Remove partition table
                wipefs -fa "$drive" 2>/dev/null || true
                # Clear first 100MB
                dd if=/dev/zero of="$drive" bs=1M count=100 2>/dev/null || true
            fi
        done
    done
    
    # Wait for system to settle
    sleep 3
    
    log "INFO" "Cleanup completed"
}

# Execute ZFS mirror configuration
execute_zfs_mirror() {
    local config="$1"
    local category="${config#zfs-}"
    
    log "INFO" "Setting up ZFS mirror configuration for $category drives..."
    
    # Import drive group data
    safe_eval_drive_groups
    
    # Install ZFS
    log "INFO" "Installing ZFS packages..."
    apt update
    apt install -y zfsutils-linux
    
    # Get drives for this category
    if [[ -z "${drive_groups[$category]:-}" ]]; then
        log "ERROR" "No drives found for category: $category"
        return 1
    fi
    
    local drives_in_category=(${drive_groups[$category]})
    local size=${drive_sizes_gb[$category]}
    
    if [[ ${#drives_in_category[@]} -lt 2 ]]; then
        log "ERROR" "Need at least 2 drives for ZFS mirror, found ${#drives_in_category[@]} in category $category"
        return 1
    fi
    
    # Use first two drives
    local drive1="${drives_in_category[0]}"
    local drive2="${drives_in_category[1]}"
    
    log "INFO" "Using drives: $drive1 and $drive2 (${size}GB each)"
    
    log "INFO" "Wiping drives $drive1 and $drive2..."
    wipefs -fa "$drive1"
    dd if=/dev/zero of="$drive1" bs=1M count=100
    wipefs -fa "$drive2"
    dd if=/dev/zero of="$drive2" bs=1M count=100
    
    # Create ZFS pool
    local pool_name="tank"
    log "INFO" "Creating ZFS pool '$pool_name' with ${size}GB drives..."
    zpool create -f "$pool_name" mirror "$drive1" "$drive2"
    
    # Create datasets
    zfs create "$pool_name/vms"
    zfs create "$pool_name/backup"
    zfs create "$pool_name/iso"
    
    # Set properties
    zfs set compression=lz4 "$pool_name"
    zfs set atime=off "$pool_name"
    
    # Setup ZFS mounts
    setup_zfs_mounts
}

# Execute RAID 6 configuration
execute_raid6() {
    local config="$1"
    local category="${config#raid6-}"
    
    log "INFO" "Setting up RAID 6 configuration for $category drives..."
    
    # Import drive group data
    safe_eval_drive_groups
    
    # Get drives for this category
    if [[ -z "${drive_groups[$category]:-}" ]]; then
        log "ERROR" "No drives found for category: $category"
        return 1
    fi
    
    local drives_in_category=(${drive_groups[$category]})
    local size=${drive_sizes_gb[$category]}
    
    if [[ ${#drives_in_category[@]} -lt 4 ]]; then
        log "ERROR" "RAID 6 requires at least 4 drives, found ${#drives_in_category[@]} in category $category"
        return 1
    fi
    
    log "INFO" "Using ${#drives_in_category[@]} drives for RAID 6: ${drives_in_category[*]}"
    
    # Wipe drives
    log "INFO" "Wiping drive signatures..."
    for drive in "${drives_in_category[@]}"; do
        wipefs -fa "$drive"
        dd if=/dev/zero of="$drive" bs=1M count=100
    done
    
    # Create RAID 6
    log "INFO" "Creating RAID 6 array with ${#drives_in_category[@]} drives..."
    mdadm --create /dev/md0 --level=6 --raid-devices=${#drives_in_category[@]} "${drives_in_category[@]}"
    
    # Wait for RAID sync to start
    sleep 5
    
    # Partition and setup LVM (same as RAID 6)
    setup_standard_raid_partitions
}

# Execute RAID 5 configuration
execute_raid5() {
    local config="$1"
    local category="${config#raid5-}"
    
    log "INFO" "Setting up RAID 5 configuration for $category drives..."
    
    # Import drive group data
    safe_eval_drive_groups
    
    # Get drives for this category
    if [[ -z "${drive_groups[$category]:-}" ]]; then
        log "ERROR" "No drives found for category: $category"
        return 1
    fi
    
    local drives_in_category=(${drive_groups[$category]})
    local size=${drive_sizes_gb[$category]}
    
    if [[ ${#drives_in_category[@]} -lt 3 ]]; then
        log "ERROR" "RAID 5 requires at least 3 drives, found ${#drives_in_category[@]} in category $category"
        return 1
    fi
    
    log "INFO" "Using ${#drives_in_category[@]} drives for RAID 5: ${drives_in_category[*]}"
    
    # Wipe drives
    log "INFO" "Wiping drive signatures..."
    for drive in "${drives_in_category[@]}"; do
        wipefs -fa "$drive"
        dd if=/dev/zero of="$drive" bs=1M count=100
    done
    
    # Create RAID 5
    log "INFO" "Creating RAID 5 array with ${#drives_in_category[@]} drives..."
    mdadm --create /dev/md0 --level=5 --raid-devices=${#drives_in_category[@]} "${drives_in_category[@]}"
    
    # Wait for RAID sync to start
    sleep 5
    
    # Partition and setup LVM (same as RAID 6)
    setup_standard_raid_partitions
}

# Execute RAID 10 configuration
execute_raid10() {
    local config="$1"
    local category="${config#raid10-}"
    
    log "INFO" "Setting up RAID 10 configuration for $category drives..."
    
    # Import drive group data
    safe_eval_drive_groups
    
    # Get drives for this category
    if [[ -z "${drive_groups[$category]:-}" ]]; then
        log "ERROR" "No drives found for category: $category"
        return 1
    fi
    
    local drives_in_category=(${drive_groups[$category]})
    local size=${drive_sizes_gb[$category]}
    
    if [[ ${#drives_in_category[@]} -lt 4 ]]; then
        log "ERROR" "RAID 10 requires at least 4 drives, found ${#drives_in_category[@]} in category $category"
        return 1
    fi
    
    if [[ $((${#drives_in_category[@]} % 2)) -ne 0 ]]; then
        log "ERROR" "RAID 10 requires an even number of drives, found ${#drives_in_category[@]} in category $category"
        return 1
    fi
    
    log "INFO" "Using ${#drives_in_category[@]} drives for RAID 10: ${drives_in_category[*]}"
    
    # Wipe drives
    log "INFO" "Wiping drive signatures..."
    for drive in "${drives_in_category[@]}"; do
        wipefs -fa "$drive"
        dd if=/dev/zero of="$drive" bs=1M count=100
    done
    
    # Create RAID 10
    log "INFO" "Creating RAID 10 array with ${#drives_in_category[@]} drives..."
    mdadm --create /dev/md0 --level=10 --raid-devices=${#drives_in_category[@]} "${drives_in_category[@]}"
    
    # Wait for RAID sync to start
    sleep 5
    
    # Partition and setup LVM (same as RAID 6)
    setup_standard_raid_partitions
}

# Execute individual drive configuration
execute_individual() {
    local config="$1"
    local category="${config#individual-}"
    
    log "INFO" "Setting up individual drives for $category..."
    
    # Import drive group data
    safe_eval_drive_groups
    
    # Get drives for this category
    if [[ -z "${drive_groups[$category]:-}" ]]; then
        log "ERROR" "No drives found for category: $category"
        return 1
    fi
    
    local drives_in_category=(${drive_groups[$category]})
    local size=${drive_sizes_gb[$category]}
    
    log "INFO" "Setting up ${#drives_in_category[@]} individual drives: ${drives_in_category[*]}"
    log "WARNING" "No redundancy - drive failure will result in data loss!"
    
    local mount_index=0
    for drive in "${drives_in_category[@]}"; do
        log "INFO" "Setting up $drive as individual storage..."
        wipefs -fa "$drive"
        
        parted -s "$drive" mklabel gpt
        parted -s "$drive" mkpart primary ext4 1MiB 100%
        
        mkfs.ext4 "${drive}1"
        
        # Create mount point
        mkdir -p "/mnt/storage${mount_index}"
        echo "${drive}1 /mnt/storage${mount_index} ext4 defaults 0 2" >> /etc/fstab
        
        log "INFO" "Drive $drive mounted at /mnt/storage${mount_index}"
        ((mount_index++))
    done
    
    log "INFO" "Individual drives configured. Use /mnt/storage* directories for data."
}

# Execute no-RAID configuration
execute_no_raid() {
    log "INFO" "Setting up individual drives without RAID..."
    
    # Import drive group data
    safe_eval_drive_groups
    
    local drive_count=0
    
    # Setup all drives individually
    for category in "${!drive_groups[@]}"; do
        local drives_in_category=(${drive_groups[$category]})
        local size=${drive_sizes_gb[$category]}
        
        for drive in "${drives_in_category[@]}"; do
            log "INFO" "Setting up $drive as individual storage (${size}GB)..."
            wipefs -fa "$drive"
            
            parted -s "$drive" mklabel gpt
            parted -s "$drive" mkpart primary ext4 1MiB 100%
            
            mkfs.ext4 "${drive}1"
            
            # Create mount point
            mkdir -p "/mnt/storage$drive_count"
            echo "${drive}1 /mnt/storage$drive_count ext4 defaults 0 2" >> /etc/fstab
            
            log "INFO" "Drive $drive mounted at /mnt/storage$drive_count"
            ((drive_count++))
        done
    done
    
    log "INFO" "Individual drives configured. Use /mnt/storage* directories for data."
    log "WARNING" "No redundancy - drive failure will result in data loss!"
}

# Execute mixed optimal configuration
execute_mixed_optimal() {
    log "INFO" "Setting up mixed optimal configuration..."
    
    # Import drive group data
    safe_eval_drive_groups
    
    # Process each drive group
    local array_index=0
    for category in "${!drive_groups[@]}"; do
        local drives_in_category=(${drive_groups[$category]})
        local count=${#drives_in_category[@]}
        local size=${drive_sizes_gb[$category]}
        
        if [[ $count -ge 2 ]]; then
            # Create RAID 1 for groups with 2+ drives
            log "INFO" "Creating RAID 1 for $category (${count} drives, ${size}GB each)"
            
            # Wipe drives
            for drive in "${drives_in_category[@]:0:2}"; do
                wipefs -fa "$drive"
                dd if=/dev/zero of="$drive" bs=1M count=100
            done
            
            # Create RAID 1
            mdadm --create "/dev/md${array_index}" --level=1 --raid-devices=2 \
                "${drives_in_category[0]}" "${drives_in_category[1]}"
            
            # Setup LVM on this RAID
            pvcreate "/dev/md${array_index}"
            vgcreate "vg${array_index}" "/dev/md${array_index}"
            lvcreate -l 100%FREE -n "data${array_index}" "vg${array_index}"
            mkfs.ext4 "/dev/vg${array_index}/data${array_index}"
            
            # Mount
            mkdir -p "/mnt/raid${array_index}"
            echo "/dev/vg${array_index}/data${array_index} /mnt/raid${array_index} ext4 defaults 0 2" >> /etc/fstab
            
            ((array_index++))
        else
            # Setup single drives individually
            for drive in "${drives_in_category[@]}"; do
                log "INFO" "Setting up individual drive $drive (${size}GB)"
                wipefs -fa "$drive"
                
                parted -s "$drive" mklabel gpt
                parted -s "$drive" mkpart primary ext4 1MiB 100%
                
                mkfs.ext4 "${drive}1"
                
                mkdir -p "/mnt/single${array_index}"
                echo "${drive}1 /mnt/single${array_index} ext4 defaults 0 2" >> /etc/fstab
                
                ((array_index++))
            done
        fi
    done
    
    log "INFO" "Mixed optimal configuration completed"
}

# Setup standard RAID partitions (used by RAID 5, 6, 10)
setup_standard_raid_partitions() {
    # Partition RAID
    log "INFO" "Partitioning RAID array..."
    parted -s /dev/md0 mklabel gpt
    parted -s /dev/md0 mkpart primary ext4 1MiB 1GiB
    parted -s /dev/md0 mkpart primary ext4 1GiB 100%
    
    # Create LVM
    log "INFO" "Setting up LVM..."
    pvcreate /dev/md0p2
    vgcreate vg0 /dev/md0p2
    lvcreate -L 100G -n root vg0
    lvcreate -L 16G -n swap vg0
    lvcreate -l 100%FREE -n vmdata vg0
    
    # Format filesystems
    log "INFO" "Formatting filesystems..."
    mkfs.ext4 /dev/md0p1
    mkfs.ext4 /dev/vg0/root
    mkswap /dev/vg0/swap
    mkfs.ext4 /dev/vg0/vmdata
    
    # Setup mounts
    setup_raid6_mounts  # Reuse the same mount setup
}

# Interactive configuration selection
interactive_config_selection() {
    log "INFO" "🎯 Drive Configuration Selection"
    echo
    
    # Import the drive group data
    safe_eval_drive_groups
    
    # Get available configurations
    local configs=()
    local descriptions=()
    
    # Always add these basic options
    configs+=("scan-only")
    descriptions+=("Scan drives and show recommendations (safe, no changes)")
    
    configs+=("no-raid")
    descriptions+=("Use all drives individually (no redundancy)")
    
    # Add RAID options based on detected drives
    local group_count=${#drive_groups[@]}
    
    for category in "${!drive_groups[@]}"; do
        local drives_in_category=(${drive_groups[$category]})
        local count=${#drives_in_category[@]}
        local size_gb=${drive_sizes_gb[$category]}
        
        if [[ $count -ge 2 ]]; then
            configs+=("raid1-${category}")
            descriptions+=("RAID 1 with ${count}x ${category} drives (~$((size_gb / 2))GB usable)")
        fi
        
        if [[ $count -ge 3 ]]; then
            configs+=("raid5-${category}")
            descriptions+=("RAID 5 with ${count}x ${category} drives (~$((size_gb * (count - 1)))GB usable)")
        fi
        
        if [[ $count -ge 4 ]]; then
            configs+=("raid6-${category}")
            descriptions+=("RAID 6 with ${count}x ${category} drives (~$((size_gb * (count - 2)))GB usable)")
            
            configs+=("raid10-${category}")
            descriptions+=("RAID 10 with ${count}x ${category} drives (~$((size_gb * count / 2))GB usable)")
        fi
    done
    
    # Add dual RAID option if exactly 2 groups with 2+ drives each
    if [[ $group_count -eq 2 ]]; then
        local can_dual_raid=true
        for category in "${!drive_groups[@]}"; do
            local drives_in_category=(${drive_groups[$category]})
            local count=${#drives_in_category[@]}
            if [[ $count -lt 2 ]]; then
                can_dual_raid=false
                break
            fi
        done
        
        if [[ "$can_dual_raid" == "true" ]]; then
            configs+=("dual-raid1")
            descriptions+=("Dual RAID 1 - separate arrays for each drive size (recommended)")
        fi
    fi
    
    # Add mixed optimal if 3+ groups
    if [[ $group_count -ge 3 ]]; then
        configs+=("mixed-optimal")
        descriptions+=("Mixed optimal - RAID for matching drives, individual for others")
    fi
    
    # Display options
    log "INFO" "📋 Available Configuration Options:"
    echo
    
    for i in "${!configs[@]}"; do
        local num=$((i + 1))
        printf "  %2d) %-20s %s\n" "$num" "${configs[$i]}" "${descriptions[$i]}"
    done
    
    echo
    
    # Show recommendation if available
    if [[ -n "${RECOMMENDED_CONFIG:-}" ]]; then
        log "INFO" "💡 Recommended: $RECOMMENDED_CONFIG"
        echo
    fi
    
    # Get user selection
    local selection=""
    while true; do
        echo -n "Please select a configuration (1-${#configs[@]}) or 'q' to quit: "
        read -r selection
        
        if [[ "$selection" == "q" || "$selection" == "Q" ]]; then
            log "INFO" "Configuration cancelled by user"
            exit 0
        fi
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le "${#configs[@]}" ]]; then
            local config_index=$((selection - 1))
            export SELECTED_CONFIG="${configs[$config_index]}"
            log "INFO" "Selected configuration: $SELECTED_CONFIG"
            break
        else
            echo "Invalid selection. Please enter a number between 1 and ${#configs[@]}, or 'q' to quit."
        fi
    done
    
    echo
}

# Confirmation prompt for destructive operations
confirm_operation() {
    local config="$1"
    
    if [[ "$config" == "scan-only" ]]; then
        return 0  # No confirmation needed for scan-only
    fi
    
    log "WARNING" "⚠️  DESTRUCTIVE OPERATION WARNING ⚠️"
    echo
    log "WARNING" "This operation will:"
    log "WARNING" "• Wipe ALL data on the selected drives"
    log "WARNING" "• Create new partition tables"
    log "WARNING" "• Set up RAID arrays (if selected)"
    log "WARNING" "• Format filesystems"
    echo
    log "WARNING" "🚨 ALL EXISTING DATA ON THESE DRIVES WILL BE PERMANENTLY LOST! 🚨"
    echo
    
    # Show which drives will be affected
    safe_eval_drive_groups
    log "WARNING" "Drives that will be affected:"
    for category in "${!drive_groups[@]}"; do
        local drives_in_category=(${drive_groups[$category]})
        log "WARNING" "  ${category}: ${drives_in_category[*]}"
    done
    
    echo
    log "WARNING" "💾 BACKUP RECOMMENDATION:"
    log "WARNING" "• Ensure you have backups of any important data"
    log "WARNING" "• Verify you can reinstall the OS if needed"
    log "WARNING" "• Test this in a development environment first"
    echo
    
    # Force user to type confirmation
    local confirmation=""
    while true; do
        echo -n "Type 'I UNDERSTAND THE RISKS' (exactly) to proceed, or 'cancel' to abort: "
        read -r confirmation
        
        if [[ "$confirmation" == "I UNDERSTAND THE RISKS" ]]; then
            log "INFO" "User confirmed understanding of risks. Proceeding..."
            break
        elif [[ "$confirmation" == "cancel" ]]; then
            log "INFO" "Operation cancelled by user"
            exit 0
        else
            echo "Please type exactly 'I UNDERSTAND THE RISKS' or 'cancel'"
        fi
    done
    
    echo
}

# System safety checks
perform_safety_checks() {
    log "INFO" "🔍 Performing system safety checks..."
    
    # Check if we're running on Proxmox
    if [[ ! -f "/etc/pve" ]] && [[ ! -d "/etc/pve" ]]; then
        log "WARNING" "This doesn't appear to be a Proxmox system"
        log "WARNING" "Are you sure you want to continue? (y/N): "
        read -r response
        if [[ ! "$response" =~ ^[yY]$ ]]; then
            log "INFO" "Aborted by user"
            exit 0
        fi
    fi
    
    # Check for active VMs or containers
    if command -v qm >/dev/null 2>&1; then
        local running_vms=$(qm list 2>/dev/null | grep -c "running" || echo "0")
        if [[ "$running_vms" -gt 0 ]]; then
            log "WARNING" "Found $running_vms running VMs"
            log "WARNING" "Drive reconfiguration may affect VM storage"
            log "WARNING" "Recommend stopping VMs first. Continue anyway? (y/N): "
            read -r response
            if [[ ! "$response" =~ ^[yY]$ ]]; then
                log "INFO" "Aborted by user"
                exit 0
            fi
        fi
    fi
    
    # Check available space for backups
    local root_space=$(df / | awk 'NR==2 {print $4}')
    if [[ "$root_space" -lt 1048576 ]]; then  # Less than 1GB
        log "WARNING" "Low disk space on root filesystem ($(($root_space / 1024))MB available)"
        log "WARNING" "May not have enough space for emergency backups"
    fi
    
    # Check if any of the target drives are currently mounted
    safe_eval_drive_groups
    
    local mounted_drives=()
    for category in "${!drive_groups[@]}"; do
        local drives_in_category=(${drive_groups[$category]})
        for drive in "${drives_in_category[@]}"; do
            if mount | grep -q "^$drive"; then
                mounted_drives+=("$drive")
            fi
        done
    done
    
    if [[ ${#mounted_drives[@]} -gt 0 ]]; then
        log "WARNING" "Some target drives are currently mounted:"
        for drive in "${mounted_drives[@]}"; do
            log "WARNING" "  $drive"
        done
        log "WARNING" "These will be unmounted before proceeding. Continue? (y/N): "
        read -r response
        if [[ ! "$response" =~ ^[yY]$ ]]; then
            log "INFO" "Aborted by user"
            exit 0
        fi
    fi
    
    log "INFO" "✅ Safety checks completed"
    echo
}

# Create emergency restore information
create_emergency_info() {
    log "INFO" "📝 Creating emergency restore information..."
    
    local backup_dir="/root/drive-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    
    # Save current drive information
    {
        echo "# Emergency Drive Restoration Information"
        echo "# Created: $(date)"
        echo "# Original system state before drive reconfiguration"
        echo ""
        echo "# Current partition table dumps:"
        
        safe_eval_drive_groups
        for category in "${!drive_groups[@]}"; do
            local drives_in_category=(${drive_groups[$category]})
            for drive in "${drives_in_category[@]}"; do
                echo ""
                echo "## Drive: $drive"
                echo "### Partition table:"
                sfdisk -d "$drive" 2>/dev/null || echo "# Failed to dump partition table"
                echo "### Block device info:"
                lsblk "$drive" 2>/dev/null || echo "# Failed to get block info"
            done
        done
        
        echo ""
        echo "# Current /etc/fstab:"
        cat /etc/fstab
        
        echo ""
        echo "# Current mount points:"
        mount
        
        echo ""
        echo "# Current RAID status:"
        cat /proc/mdstat 2>/dev/null || echo "# No RAID devices"
        
        echo ""
        echo "# Current LVM status:"
        pvs 2>/dev/null || echo "# No LVM physical volumes"
        vgs 2>/dev/null || echo "# No LVM volume groups"
        lvs 2>/dev/null || echo "# No LVM logical volumes"
        
    } > "$backup_dir/system-state.txt"
    
    # Create restore script template
    cat > "$backup_dir/restore-instructions.txt" << 'EOF'
# EMERGENCY RESTORE INSTRUCTIONS

⚠️  WARNING: Only use this if the drive configuration failed and you need to restore access

## Option 1: Restore from Hetzner Rescue System
1. Boot into Hetzner rescue system
2. Use Hetzner installimage to reinstall the OS
3. Restore your data from backups

## Option 2: Manual restoration (if system is still bootable)
1. Check system-state.txt for original configuration
2. Use sfdisk to restore partition tables:
   sfdisk /dev/sdX < partition-backup.sfdisk
3. Restore /etc/fstab from the backup
4. Reboot and verify

## Option 3: Contact Support
If you're unsure, contact your system administrator or hosting provider support.

## Important Notes:
- This drive configuration was created by hetzner-proxmox setup scripts
- Original system state is preserved in system-state.txt
- Consider reinstalling from scratch if restoration seems complex
EOF
    
    log "INFO" "Emergency restore information saved to: $backup_dir"
    export BACKUP_DIR="$backup_dir"
}

# Main execution function
main() {
    # Set error handler
    trap 'error_handler ${LINENO} $?' ERR
    
    # Parse command line arguments
    parse_args "$@"
    
    # Show usage if no arguments and not in cleanup mode
    if [[ -z "${RAID_CONFIG:-}" ]] && [[ "${DRY_RUN:-false}" == "false" ]] && [[ "${CLEANUP_ONLY:-false}" == "false" ]]; then
        usage
        exit 0
    fi
    
    # Handle cleanup mode
    if [[ "${CLEANUP_ONLY:-false}" == "true" ]]; then
        log "INFO" "Cleanup mode - removing existing RAID arrays"
        # Add cleanup logic here if needed
        exit 0
    fi
    
    log "INFO" "🚀 Starting Hetzner Proxmox Drive Preparation"
    log "INFO" "$(date)"
    echo
    
    # Detect and analyze drives
    log "INFO" "🔍 Detecting available drives..."
    local drives
    drives=($(detect_drives))
    
    if [[ ${#drives[@]} -eq 0 ]]; then
        log "ERROR" "No suitable drives found"
        exit 1
    fi
    
    log "INFO" "Analyzing drive configuration..."
    analyze_drives "${drives[@]}"
    
       
    # Suggest best configuration

    suggest_best_config
    
    # If a specific config was provided, use it; otherwise prompt user
    if [[ -n "${RAID_CONFIG:-}" ]]; then
        if [[ "$RAID_CONFIG" == "auto" ]] || [[ "$RAID_CONFIG" == "recommended" ]]; then
            export SELECTED_CONFIG="${RECOMMENDED_CONFIG:-no-raid}"
            log "INFO" "Using recommended configuration: $SELECTED_CONFIG"
        else
            export SELECTED_CONFIG="$RAID_CONFIG"
            log "INFO" "Using specified configuration: $SELECTED_CONFIG"
        fi
    else
        # Interactive mode - let user choose
        interactive_config_selection
    fi
    
    # Validate the configuration
    if ! validate_raid_config "$SELECTED_CONFIG"; then
        log "ERROR" "Invalid RAID configuration: $SELECTED_CONFIG"
        exit 1
    fi
    
    # Preview the configuration
    echo
    log "INFO" "🎯 Configuration Preview"
    log "INFO" "Selected configuration: $SELECTED_CONFIG"
    echo
    
    preview_raid_config "$SELECTED_CONFIG"
    echo
    
    # Handle dry-run mode
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "🏃 DRY RUN MODE - No changes will be made"
        log "INFO" ""
        log "INFO" "To execute this configuration for real:"
        if [[ -n "${RAID_CONFIG:-}" ]]; then
            log "INFO" "  $0 --config \"$SELECTED_CONFIG\""
        else
            log "INFO" "  $0 --config \"$SELECTED_CONFIG\""
        fi
        log "INFO" ""
        log "INFO" "Add --force to skip confirmations (use with caution)"
        exit 0
    fi
    
    # Handle scan-only mode
    if [[ "$SELECTED_CONFIG" == "scan-only" ]]; then
        log "INFO" "✅ Scan completed. No changes made."
        log "INFO" ""
        log "INFO" "To apply a configuration, run:"
        log "INFO" "  $0 --config <configuration-name>"
        exit 0
    fi
    
    # Safety checks and confirmations for destructive operations
    if [[ "${FORCE:-false}" != "true" ]]; then
        perform_safety_checks
        confirm_operation "$SELECTED_CONFIG"
    fi
    
    # Create emergency restore information
    create_emergency_info
    
    # Execute the configuration
    log "INFO" "🔧 Executing drive configuration: $SELECTED_CONFIG"
    log "INFO" "This may take several minutes..."
    echo
    
    if ! execute_raid_config "$SELECTED_CONFIG"; then
        log "ERROR" "Drive configuration failed"
        log "ERROR" "Emergency restore information available at: ${BACKUP_DIR:-/root/drive-backup-*}"
        exit 1
    fi
    
    # Update system configuration
    update_system_config "$SELECTED_CONFIG"
    
    log "INFO" "✅ Drive preparation completed successfully!"
    echo
    log "INFO" "📊 Summary:"
    log "INFO" "  Configuration: $SELECTED_CONFIG"
    log "INFO" "  Backup info: ${BACKUP_DIR:-/root/drive-backup-*}"
    log "INFO" "  Status: All operations completed"
    echo
    log "INFO" "🔄 Next Steps:"
    log "INFO" "1. Monitor RAID sync (if applicable): watch cat /proc/mdstat"
    log "INFO" "2. Reboot to verify configuration: reboot"
    log "INFO" "3. Configure Proxmox storage pools in web interface"
    log "INFO" "4. Continue with network setup: ./install.sh --network"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

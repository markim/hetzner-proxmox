#!/bin/bash

# Hetzner Proxmox Setup - Drive Preparation and RAID Configuration
# This script handles drive preparation and RAID setup for various configurations

set -euo pipefail

readonly SCRIPT_NAME="prepare-drives"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source common functions
source "$PROJECT_ROOT/lib/common.sh"

# Default values
DRY_RUN=false
RAID_CONFIG=""
FORCE=false

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
    log "INFO" "Detecting available drives..."
    
    # Get all drives except loop devices and ram
    local drives=($(lsblk -dn -o NAME,SIZE,TYPE | grep -E '^(sd|nvme|vd)' | grep disk | awk '{print "/dev/" $1}'))
    
    if [[ ${#drives[@]} -eq 0 ]]; then
        log "ERROR" "No suitable drives found"
        exit 1
    fi
    
    log "INFO" "Found ${#drives[@]} drives:"
    for drive in "${drives[@]}"; do
        local size=$(lsblk -dn -o SIZE "$drive" 2>/dev/null || echo "unknown")
        local model=$(lsblk -dn -o MODEL "$drive" 2>/dev/null || echo "unknown")
        log "INFO" "  $drive: $size ($model)"
    done
    
    echo "${drives[@]}"
}

# Analyze drive configuration
analyze_drives() {
    local drives=($@)
    
    # Create associative arrays to group drives by size
    declare -A drive_groups
    declare -A drive_sizes_gb
    
    log "INFO" "Analyzing drive sizes..."
    
    for drive in "${drives[@]}"; do
        local size_bytes=$(lsblk -dn -b -o SIZE "$drive")
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
    
    # Display analysis results
    log "INFO" "Drive analysis results:"
    for category in "${!drive_groups[@]}"; do
        local drives_in_category=(${drive_groups[$category]})
        local count=${#drives_in_category[@]}
        local size_gb=${drive_sizes_gb[$category]}
        log "INFO" "  $category: ${count}x drives (${drive_groups[$category]})"
    done
    
    # Store results globally for compatibility and recommendations
    export DRIVE_GROUPS_STR=$(declare -p drive_groups)
    export DRIVE_SIZES_STR=$(declare -p drive_sizes_gb)
    
    # For backward compatibility, still populate old variables
    local drive_4tb=()
    local drive_1tb=()
    local drive_other=()
    
    for drive in "${drives[@]}"; do
        local size_bytes=$(lsblk -dn -b -o SIZE "$drive")
        local size_gb=$((size_bytes / 1024 / 1024 / 1024))
        
        if [[ $size_gb -gt 3500 && $size_gb -lt 4500 ]]; then
            drive_4tb+=("$drive")
        elif [[ $size_gb -gt 800 && $size_gb -lt 1200 ]]; then
            drive_1tb+=("$drive")
        else
            drive_other+=("$drive")
        fi
    done
    
    DRIVES_4TB=("${drive_4tb[@]}")
    DRIVES_1TB=("${drive_1tb[@]}")
    DRIVES_OTHER=("${drive_other[@]}")
}

# Validate RAID configuration
validate_raid_config() {
    local config="$1"
    
    # Import the drive group data
    eval "$DRIVE_GROUPS_STR"
    
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
        "mixed-optimal"|"no-raid"|"individual-"*)
            # These configurations don't have strict requirements
            ;;
        # Legacy configurations for backward compatibility
        "single-raid1-4tb"|"single-raid1-1tb"|"raid6-all"|"zfs-mirror")
            # Use old validation logic
            if [[ ${#DRIVES_4TB[@]} -lt 2 && ${#DRIVES_1TB[@]} -lt 2 ]] && [[ "$config" != "no-raid" ]]; then
                log "ERROR" "Legacy configuration $config requires specific drive sizes"
                log "ERROR" "Consider using the generic configurations instead"
                return 1
            fi
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
    echo "╭────────────────────────────────────────────────────────────────╮"
    echo "│ Drive       Size      Model                    Serial           │"
    echo "├────────────────────────────────────────────────────────────────┤"
    
    local drives=($(lsblk -dn -o NAME | grep -E '^(sd|nvme|vd)'))
    local drive_count=0
    
    for drive_name in "${drives[@]}"; do
        local drive="/dev/$drive_name"
        if [[ -b "$drive" ]]; then
            local size=$(lsblk -dn -o SIZE "$drive" 2>/dev/null || echo "unknown")
            local model=$(lsblk -dn -o MODEL "$drive" 2>/dev/null | tr -s ' ' || echo "unknown")
            local serial=$(lsblk -dn -o SERIAL "$drive" 2>/dev/null || echo "unknown")
            
            # Truncate long strings for display
            model="${model:0:20}"
            serial="${serial:0:15}"
            
            printf "│ %-10s  %-8s  %-20s  %-15s │\n" "$drive" "$size" "$model" "$serial"
            ((drive_count++))
        fi
    done
    
    echo "╰────────────────────────────────────────────────────────────────╯"
    log "INFO" "Total drives detected: $drive_count"
    echo
    
    # Show partitions if any exist
    log "INFO" "Current Partition Layout:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE | grep -E '(NAME|disk|part|raid|lvm)'
    echo
    
    # Show existing RAID arrays
    if [[ -f /proc/mdstat ]]; then
        log "INFO" "Existing Software RAID Arrays:"
        if grep -q "^md" /proc/mdstat; then
            cat /proc/mdstat
        else
            log "INFO" "  No software RAID arrays detected"
        fi
        echo
    fi
    
    # Show LVM status
    if command -v pvdisplay >/dev/null 2>&1; then
        log "INFO" "LVM Physical Volumes:"
        if pvdisplay 2>/dev/null | grep -q "PV Name"; then
            pvdisplay --short 2>/dev/null || log "INFO" "  No LVM physical volumes detected"
        else
            log "INFO" "  No LVM physical volumes detected"
        fi
        echo
    fi
    
    # Show ZFS pools
    if command -v zpool >/dev/null 2>&1; then
        log "INFO" "ZFS Pools:"
        if zpool list 2>/dev/null | grep -v "no pools available" >/dev/null 2>&1; then
            zpool list 2>/dev/null || log "INFO" "  No ZFS pools detected"
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
    eval "$DRIVE_GROUPS_STR"
    eval "$DRIVE_SIZES_STR"
    
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
        # Legacy configurations
        "single-raid1-4tb"|"single-raid1-1tb"|"raid6-all"|"zfs-mirror")
            preview_legacy_config "$config"
            ;;
        *)
            log "WARNING" "Unknown configuration: $config"
            log "INFO" "Will attempt generic configuration"
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

preview_legacy_config() {
    local config="$1"
    
    # Use the old preview logic for backward compatibility
    case "$config" in
        "single-raid1-4tb"|"single-raid1-1tb"|"raid6-all"|"zfs-mirror")
            log "INFO" "Legacy configuration - see original preview logic"
            ;;
    esac
}

# Suggest best RAID configuration based on detected drives
suggest_best_config() {
    log "INFO" "🔍 Analyzing your detected drives to suggest optimal RAID configuration..."
    echo
    
    # Import the drive group data
    eval "$DRIVE_GROUPS_STR"
    eval "$DRIVE_SIZES_STR"
    
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
    
    log "INFO" "📊 Drive Configuration Analysis Results:"
    log "INFO" "  Total drives detected: $total_drives"
    log "INFO" "  Drive size groups found: $group_count"
    log "INFO" "  Largest group: ${largest_group_size}x $largest_group_category"
    echo
    
    # Show detailed breakdown of detected drives
    log "INFO" "🔍 Detected Drive Groups:"
    for category in "${!drive_groups[@]}"; do
        local drives_in_category=(${drive_groups[$category]})
        local count=${#drives_in_category[@]}
        local size_gb=${drive_sizes_gb[$category]}
        log "INFO" "  Group: $category"
        log "INFO" "    Count: ${count}x drives"
        log "INFO" "    Size: ~${size_gb}GB each"
        log "INFO" "    Drives: ${drives_in_category[*]}"
        echo
    done
    
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
        
        if [[ "$description" =~ ⭐ ]]; then
            log "INFO" "  $description"
        else
            log "INFO" "  $description"
        fi
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
    
    # Install required packages
    log "INFO" "Installing required packages..."
    apt update
    apt install -y mdadm lvm2 parted gdisk
    
    case "$config" in
        "dual-raid1")
            execute_dual_raid1
            ;;
        "single-raid1-4tb")
            execute_single_raid1_4tb
            ;;
        "single-raid1-1tb")
            execute_single_raid1_1tb
            ;;
        "raid6-all")
            execute_raid6_all
            ;;
        "zfs-mirror")
            execute_zfs_mirror
            ;;
        "no-raid")
            execute_no_raid
            ;;
        *)
            log "ERROR" "Unknown configuration: $config"
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
    
    # Wipe drives
    log "INFO" "Wiping drive signatures..."
    for drive in "${DRIVES_4TB[@]:0:2}" "${DRIVES_1TB[@]:0:2}"; do
        wipefs -fa "$drive"
        dd if=/dev/zero of="$drive" bs=1M count=100
    done
    
    # Create RAID 1 for 1TB drives (system)
    log "INFO" "Creating RAID 1 for system storage (1TB drives)..."
    mdadm --create /dev/md0 --level=1 --raid-devices=2 "${DRIVES_1TB[0]}" "${DRIVES_1TB[1]}"
    
    # Create RAID 1 for 4TB drives (VM storage)
    log "INFO" "Creating RAID 1 for VM storage (4TB drives)..."
    mdadm --create /dev/md1 --level=1 --raid-devices=2 "${DRIVES_4TB[0]}" "${DRIVES_4TB[1]}"
    
    # Wait for RAID sync to start
    sleep 5
    
    # Partition system RAID
    log "INFO" "Partitioning system RAID..."
    parted -s /dev/md0 mklabel gpt
    parted -s /dev/md0 mkpart primary ext4 1MiB 1GiB
    parted -s /dev/md0 mkpart primary ext4 1GiB 100%
    
    # Create LVM on system RAID
    log "INFO" "Setting up LVM on system RAID..."
    pvcreate /dev/md0p2
    vgcreate vg0 /dev/md0p2
    lvcreate -L 80G -n root vg0
    lvcreate -L 16G -n swap vg0
    lvcreate -L 20G -n tmp vg0
    
    # Create LVM on VM RAID
    log "INFO" "Setting up LVM on VM RAID..."
    pvcreate /dev/md1
    vgcreate vg1 /dev/md1
    lvcreate -l 100%FREE -n vmdata vg1
    
    # Format filesystems
    log "INFO" "Formatting filesystems..."
    mkfs.ext4 /dev/md0p1  # boot
    mkfs.ext4 /dev/vg0/root
    mkswap /dev/vg0/swap
    mkfs.ext4 /dev/vg0/tmp
    mkfs.ext4 /dev/vg1/vmdata
    
    # Create mount points and update fstab
    setup_dual_raid1_mounts
}

# Execute single RAID 1 (4TB) configuration
execute_single_raid1_4tb() {
    log "INFO" "Setting up single RAID 1 configuration (4TB drives)..."
    
    # Wipe drives
    log "INFO" "Wiping drive signatures..."
    for drive in "${DRIVES_4TB[@]:0:2}"; do
        wipefs -fa "$drive"
        dd if=/dev/zero of="$drive" bs=1M count=100
    done
    
    # Create RAID 1
    log "INFO" "Creating RAID 1 array..."
    mdadm --create /dev/md0 --level=1 --raid-devices=2 "${DRIVES_4TB[0]}" "${DRIVES_4TB[1]}"
    
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

# Execute ZFS mirror configuration
execute_zfs_mirror() {
    log "INFO" "Setting up ZFS mirror configuration..."
    
    # Install ZFS
    log "INFO" "Installing ZFS packages..."
    apt update
    apt install -y zfsutils-linux
    
    # Wipe drives
    log "INFO" "Wiping drive signatures..."
    for drive in "${DRIVES_4TB[@]:0:2}"; do
        wipefs -fa "$drive"
        dd if=/dev/zero of="$drive" bs=1M count=100
    done
    
    if [[ ${#DRIVES_1TB[@]} -ge 2 ]]; then
        for drive in "${DRIVES_1TB[@]:0:2}"; do
            wipefs -fa "$drive"
            dd if=/dev/zero of="$drive" bs=1M count=100
        done
    fi
    
    # Create ZFS pools
    if [[ ${#DRIVES_4TB[@]} -ge 2 ]]; then
        log "INFO" "Creating ZFS pool 'tank' with 4TB drives..."
        zpool create -f tank mirror "${DRIVES_4TB[0]}" "${DRIVES_4TB[1]}"
        
        # Create datasets
        zfs create tank/vms
        zfs create tank/backup
        zfs create tank/iso
        
        # Set properties
        zfs set compression=lz4 tank
        zfs set atime=off tank
    fi
    
    if [[ ${#DRIVES_1TB[@]} -ge 2 ]]; then
        log "INFO" "Creating ZFS pool 'system' with 1TB drives..."
        zpool create -f system mirror "${DRIVES_1TB[0]}" "${DRIVES_1TB[1]}"
        
        # Create datasets
        zfs create system/home
        zfs create system/logs
        
        # Set properties
        zfs set compression=lz4 system
        zfs set atime=off system
    fi
    
    # Setup ZFS mounts
    setup_zfs_mounts
}

# Execute RAID 6 configuration
execute_raid6_all() {
    log "INFO" "Setting up RAID 6 configuration with all drives..."
    log "WARNING" "This will significantly underutilize your 4TB drives!"
    
    local all_drives=("${DRIVES_4TB[@]}" "${DRIVES_1TB[@]}" "${DRIVES_OTHER[@]}")
    
    # Wipe drives
    log "INFO" "Wiping drive signatures..."
    for drive in "${all_drives[@]}"; do
        wipefs -fa "$drive"
        dd if=/dev/zero of="$drive" bs=1M count=100
    done
    
    # Create RAID 6
    log "INFO" "Creating RAID 6 array with all drives..."
    mdadm --create /dev/md0 --level=6 --raid-devices=${#all_drives[@]} "${all_drives[@]}"
    
    # Wait for RAID sync to start
    sleep 5
    
    # Partition RAID
    log "INFO" "Partitioning RAID 6 array..."
    parted -s /dev/md0 mklabel gpt
    parted -s /dev/md0 mkpart primary ext4 1MiB 1GiB
    parted -s /dev/md0 mkpart primary ext4 1GiB 100%
    
    # Create LVM
    log "INFO" "Setting up LVM on RAID 6..."
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
    setup_raid6_mounts
}

# Execute no-RAID configuration
execute_no_raid() {
    log "INFO" "Setting up individual drives without RAID..."
    
    local drive_count=0
    
    # Setup 4TB drives individually
    for drive in "${DRIVES_4TB[@]}"; do
        log "INFO" "Setting up $drive as individual storage..."
        wipefs -fa "$drive"
        
        parted -s "$drive" mklabel gpt
        parted -s "$drive" mkpart primary ext4 1MiB 100%
        
        mkfs.ext4 "${drive}1"
        
        # Create mount point
        mkdir -p "/mnt/storage$drive_count"
        echo "${drive}1 /mnt/storage$drive_count ext4 defaults 0 2" >> /etc/fstab
        
        ((drive_count++))
    done
    
    # Setup 1TB drives individually
    for drive in "${DRIVES_1TB[@]}"; do
        log "INFO" "Setting up $drive as individual storage..."
        wipefs -fa "$drive"
        
        parted -s "$drive" mklabel gpt
        parted -s "$drive" mkpart primary ext4 1MiB 100%
        
        mkfs.ext4 "${drive}1"
        
        # Create mount point
        mkdir -p "/mnt/storage$drive_count"
        echo "${drive}1 /mnt/storage$drive_count ext4 defaults 0 2" >> /etc/fstab
        
        ((drive_count++))
    done
    
    log "INFO" "Individual drives configured. Use /mnt/storage* directories for data."
}

# Setup ZFS mounts
setup_zfs_mounts() {
    log "INFO" "Configuring ZFS mount points..."
    
    # ZFS handles its own mounting, but we can set legacy mount points if needed
    if zpool list tank >/dev/null 2>&1; then
        zfs set mountpoint=/tank tank
        zfs set mountpoint=/tank/vms tank/vms
        zfs set mountpoint=/tank/backup tank/backup
        zfs set mountpoint=/tank/iso tank/iso
    fi
    
    if zpool list system >/dev/null 2>&1; then
        zfs set mountpoint=/system system
        zfs set mountpoint=/system/home system/home
        zfs set mountpoint=/system/logs system/logs
    fi
    
    log "INFO" "ZFS mount points configured"
}

# Setup RAID 6 mounts
setup_raid6_mounts() {
    log "INFO" "Setting up mount points for RAID 6..."
    
    cat >> /etc/fstab << EOF

# RAID Configuration - RAID 6 All Drives
# Boot partition
/dev/md0p1 /boot ext4 defaults 0 2

# System and VM LVM
/dev/vg0/root / ext4 defaults 0 1
/dev/vg0/swap none swap sw 0 0
/dev/vg0/vmdata /var/lib/vz ext4 defaults 0 2
EOF

    log "INFO" "RAID 6 mount points configured"
}

# Show RAID status after configuration
show_raid_status() {
    log "INFO" "RAID Configuration Status:"
    echo
    
    if [[ -f /proc/mdstat ]]; then
        log "INFO" "Software RAID Arrays:"
        cat /proc/mdstat
        echo
    fi
    
    log "INFO" "LVM Configuration:"
    pvdisplay --short 2>/dev/null || true
    echo
    vgdisplay --short 2>/dev/null || true
    echo
    lvdisplay --short 2>/dev/null || true
    echo
    
    log "INFO" "Filesystem Layout:"
    lsblk -f
}

# Populate RAID configurations based on detected drives
populate_raid_configs() {
    # Import the drive group data
    eval "$DRIVE_GROUPS_STR"
    eval "$DRIVE_SIZES_STR"
    
    # Clear existing configs except base ones
    RAID_CONFIGS=()
    
    # Always available
    RAID_CONFIGS["no-raid"]="No RAID: Use drives individually (no redundancy)"
    
    # Generate configurations based on detected drives
    for category in "${!drive_groups[@]}"; do
        local drives_in_category=(${drive_groups[$category]})
        local count=${#drives_in_category[@]}
        local size_gb=${drive_sizes_gb[$category]}
        local usable_capacity=""
        
        # Calculate usable capacity for different RAID levels
        if [[ $count -ge 2 ]]; then
            local raid1_capacity=$((size_gb / 2))
            usable_capacity="~${raid1_capacity}GB usable"
            RAID_CONFIGS["raid1-${category}"]="RAID 1: ${count}x $category drives ($usable_capacity, 1 drive redundancy)"
        fi
        
        if [[ $count -ge 3 ]]; then
            local raid5_capacity=$(((count - 1) * size_gb))
            usable_capacity="~${raid5_capacity}GB usable"
            RAID_CONFIGS["raid5-${category}"]="RAID 5: ${count}x $category drives ($usable_capacity, 1 drive redundancy)"
        fi
        
        if [[ $count -ge 4 ]]; then
            local raid6_capacity=$(((count - 2) * size_gb))
            local raid10_capacity=$((count / 2 * size_gb))
            RAID_CONFIGS["raid6-${category}"]="RAID 6: ${count}x $category drives (~${raid6_capacity}GB usable, 2 drive redundancy)"
            RAID_CONFIGS["raid10-${category}"]="RAID 10: ${count}x $category drives (~${raid10_capacity}GB usable, high performance)"
        fi
        
        # Individual drive option
        RAID_CONFIGS["individual-${category}"]="Individual: ${count}x $category drives (no redundancy, full capacity)"
    done
    
    # Multi-group configurations
    local group_count=${#drive_groups[@]}
    if [[ $group_count -eq 2 ]]; then
        local categories=(${!drive_groups[@]})
        local cat1="${categories[0]}"
        local cat2="${categories[1]}"
        local drives1=(${drive_groups[$cat1]})
        local drives2=(${drive_groups[$cat2]})
        local count1=${#drives1[@]}
        local count2=${#drives2[@]}
        
        if [[ $count1 -ge 2 && $count2 -ge 2 ]]; then
            RAID_CONFIGS["dual-raid1"]="Dual RAID 1: ${count1}x $cat1 + ${count2}x $cat2 (optimal for mixed sizes)"
        fi
    fi
    
    # Mixed optimal configuration
    if [[ $group_count -gt 1 ]]; then
        RAID_CONFIGS["mixed-optimal"]="Mixed Optimal: Best RAID for largest groups, individual for others"
    fi
    
    # ZFS configurations for drives with RAID capability
    for category in "${!drive_groups[@]}"; do
        local drives_in_category=(${drive_groups[$category]})
        local count=${#drives_in_category[@]}
        
        if [[ $count -ge 2 ]]; then
            RAID_CONFIGS["zfs-${category}"]="ZFS Mirror: ${count}x $category drives (advanced features, snapshots)"
        fi
    done
}

# Main function
main() {
    log "INFO" "Hetzner Proxmox Drive Preparation Script"
    log "INFO" "========================================"
    log "INFO" "Scanning system hardware to detect available drives..."
    echo
    
    # Detect and analyze drives
    local drives=($(detect_drives))
    
    if [[ ${#drives[@]} -eq 0 ]]; then
        log "ERROR" "No suitable drives found for RAID configuration"
        log "ERROR" "Ensure drives are properly connected and recognized by the system"
        exit 1
    fi
    
    analyze_drives "${drives[@]}"
    
    # Populate available configurations based on detected drives
    populate_raid_configs
    
    # Show current status with detailed drive information
    show_drive_status
    
    # Suggest best configuration based on what we found
    suggest_best_config
    
    # If no configuration specified, show options and exit
    if [[ -z "$RAID_CONFIG" ]]; then
        log "INFO" "🔧 Available RAID configurations for your detected drives:"
        echo
        
        # Show recommended configuration first
        if [[ -n "${RECOMMENDED_CONFIG:-}" && -n "${RAID_CONFIGS[$RECOMMENDED_CONFIG]:-}" ]]; then
            printf "  %-25s %s\n" "⭐ $RECOMMENDED_CONFIG" "${RAID_CONFIGS[$RECOMMENDED_CONFIG]}"
            echo
            log "INFO" "Other available configurations:"
        fi
        
        # Show other configurations
        for config in "${!RAID_CONFIGS[@]}"; do
            if [[ "$config" != "${RECOMMENDED_CONFIG:-}" ]]; then
                printf "  %-25s %s\n" "$config" "${RAID_CONFIGS[$config]}"
            fi
        done
        echo
        
        log "INFO" "📋 Usage examples:"
        log "INFO" "  --config ${RECOMMENDED_CONFIG:-raid1}  # Apply recommended configuration for your drives"
        log "INFO" "  --config <option> --dry-run      # Preview any configuration"
        log "INFO" "  --config <option>                # Apply any configuration"
        echo
        log "INFO" "💡 Recommendation: Use '${RECOMMENDED_CONFIG:-raid1}' for your detected drive setup"
        log "INFO" "    This configuration was selected based on your specific hardware."
        exit 0
    fi
    
    # Validate configuration against detected drives
    if ! validate_raid_config "$RAID_CONFIG"; then
        log "ERROR" "Configuration '$RAID_CONFIG' is not compatible with your detected drives"
        exit 1
    fi
    
    # Show preview of what will be done
    preview_raid_config "$RAID_CONFIG"
    
    # Execute configuration
    execute_raid_config "$RAID_CONFIG"
    
    # Show final status
    if [[ "$DRY_RUN" != "true" ]]; then
        show_raid_status
        
        log "INFO" "✅ Drive preparation completed!"
        log "INFO" "Configuration applied based on your system's detected drives."
        log "INFO" ""
        log "INFO" "Next steps:"
        log "INFO" "1. Verify RAID sync completion: watch cat /proc/mdstat"
        log "INFO" "2. Reboot to ensure everything mounts correctly"
        log "INFO" "3. Configure Proxmox storage pools"
        log "INFO" "4. Set up your VMs and containers"
    fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Parse arguments
    parse_args "$@"
    
    # Check if running as root (unless dry-run)
    if [[ "$DRY_RUN" != "true" ]]; then
        if [[ $EUID -ne 0 ]]; then
            log "ERROR" "This script must be run as root"
            log "INFO" "Use: sudo $0 $*"
            exit 1
        fi
    fi
    
    # Run main function
    main
fi

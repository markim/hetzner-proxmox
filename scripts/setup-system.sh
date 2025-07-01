#!/bin/bash

# Hetzner Proxmox System Setup Script
# This script optimizes the host system for Proxmox and sets up a /var/lib/vz directory for storage

set -euo pipefail

# Global variables for configuration management
declare -A BACKUP_FILES=()         # Track backed up files for rollback (used in backup_file function)
declare -A CREATED_FILES=()        # Track newly created files for rollback (used in backup_file function)  
declare -A INSTALLED_SERVICES=()   # Track enabled services for rollback (used in service config functions)

# Configurable paths - can be overridden by environment variables
SETUP_BASE_DIR="${SETUP_BASE_DIR:-/root/hetzner-proxmox}"
BACKUP_DIR="${BACKUP_DIR:-$SETUP_BASE_DIR/backups}"
ROLLBACK_SCRIPT="${ROLLBACK_SCRIPT:-$SETUP_BASE_DIR/rollback.sh}"
SETUP_STATE_FILE="${SETUP_STATE_FILE:-$SETUP_BASE_DIR/setup.state}"
SYSCTL_DIR="${SYSCTL_DIR:-/etc/sysctl.d}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
LOGROTATE_DIR="${LOGROTATE_DIR:-/etc/logrotate.d}"
MODPROBE_DIR="${MODPROBE_DIR:-/etc/modprobe.d}"
MODULES_FILE="${MODULES_FILE:-/etc/modules}"
ROLLBACK_COMMAND_PATH="${ROLLBACK_COMMAND_PATH:-/usr/local/bin/proxmox-setup-rollback}"

# System paths (these are standard Linux paths and shouldn't be changed)
readonly PROC_SYS_DIR="/proc/sys"
readonly SYS_MODULE_DIR="/sys/module"
readonly PROC_MEMINFO="/proc/meminfo"
readonly OS_RELEASE_FILE="/etc/os-release"

# Configuration optimization parameters (consolidated to avoid duplication)
declare -A SYSCTL_CONFIGS=(        # Used in create_sysctl_configs function
    ["vm_performance"]="vm.swappiness=1"
    ["io_background_ratio"]="vm.dirty_background_ratio=5"
    ["io_dirty_ratio"]="vm.dirty_ratio=10"
    ["io_expire_centisecs"]="vm.dirty_expire_centisecs=3000"
    ["io_writeback_centisecs"]="vm.dirty_writeback_centisecs=500"
    ["io_cache_pressure"]="vm.vfs_cache_pressure=50"
    ["io_min_free_kbytes"]="vm.min_free_kbytes=131072"
    ["net_rmem_default"]="net.core.rmem_default=262144"
    ["net_rmem_max"]="net.core.rmem_max=16777216"
    ["net_wmem_default"]="net.core.wmem_default=262144"
    ["net_wmem_max"]="net.core.wmem_max=16777216"
    ["net_tcp_rmem"]="net.ipv4.tcp_rmem=4096 87380 16777216"
    ["net_tcp_wmem"]="net.ipv4.tcp_wmem=4096 65536 16777216"
    ["net_netdev_backlog"]="net.core.netdev_max_backlog=5000"
    ["net_tcp_congestion"]="net.ipv4.tcp_congestion_control=bbr"
    ["net_tcp_window_scaling"]="net.ipv4.tcp_window_scaling=1"
    ["net_tcp_timestamps"]="net.ipv4.tcp_timestamps=1"
    ["net_tcp_sack"]="net.ipv4.tcp_sack=1"
    ["net_somaxconn"]="net.core.somaxconn=8192"
    ["nf_conntrack_max"]="net.netfilter.nf_conntrack_max=1048576"
    ["nf_tcp_timeout_established"]="net.netfilter.nf_conntrack_tcp_timeout_established=28800"
    ["nf_tcp_timeout_time_wait"]="net.netfilter.nf_conntrack_tcp_timeout_time_wait=30"
    ["nf_tcp_timeout_close_wait"]="net.netfilter.nf_conntrack_tcp_timeout_close_wait=15"
    ["nf_tcp_timeout_fin_wait"]="net.netfilter.nf_conntrack_tcp_timeout_fin_wait=30"
    ["sched_autogroup_enabled"]="kernel.sched_autogroup_enabled=0"
    ["numa_balancing"]="kernel.numa_balancing=0"
    ["zone_reclaim_mode"]="vm.zone_reclaim_mode=0"
    ["max_map_count"]="vm.max_map_count=262144"
    ["sched_migration_cost_ns"]="kernel.sched_migration_cost_ns=5000000"
    ["sched_min_granularity_ns"]="kernel.sched_min_granularity_ns=10000000"
    ["sched_wakeup_granularity_ns"]="kernel.sched_wakeup_granularity_ns=15000000"
)

# Enhanced error handler with cleanup
error_handler() {
    local line_no=$1
    local error_code=$2
    log "ERROR" "Script failed at line $line_no with exit code $error_code"
    log "ERROR" "This error occurred in the setup-system script"
    
    # Offer rollback on critical failures
    if [[ -f "$ROLLBACK_SCRIPT" ]]; then
        log "WARNING" "Rollback script available at: $ROLLBACK_SCRIPT"
        log "WARNING" "Run '$ROLLBACK_SCRIPT' to undo changes if needed"
    fi
}

# Set up error handling
trap 'error_handler ${LINENO} $?' ERR

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source common functions
# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/common.sh"

# Enable debug logging for troubleshooting
export LOG_LEVEL="${LOG_LEVEL:-DEBUG}"

# Function to optimize system for Proxmox
optimize_system() {
    log "INFO" "Optimizing system for Proxmox performance..."
    
    # Create backup infrastructure first
    create_backup_infrastructure
    
    # Update system packages with error handling
    log "INFO" "Updating system packages..."
    if ! apt-get update; then
        log "WARNING" "Package update failed, continuing with existing packages"
    fi
    
    if ! apt-get upgrade -y; then
        log "WARNING" "Package upgrade failed, continuing with current versions"
    fi
    
    # Install essential packages for Proxmox optimization
    log "INFO" "Installing system optimization packages..."
    local packages=(
        htop iotop sysstat smartmontools lm-sensors ethtool tuned
        irqbalance chrony rsyslog logrotate parted curl
        debian-keyring debian-archive-keyring apt-transport-https gnupg
        zfsutils-linux nvme-cli fio
    )
    
    local failed_packages=()
    for package in "${packages[@]}"; do
        if ! apt-get install -y "$package" 2>/dev/null; then
            failed_packages+=("$package")
            log "WARNING" "Failed to install package: $package"
        else
            log "DEBUG" "Successfully installed: $package"
        fi
    done
    
    if [[ ${#failed_packages[@]} -gt 0 ]]; then
        log "WARNING" "Some packages failed to install: ${failed_packages[*]}"
        log "WARNING" "System optimization will continue with available packages"
    fi
    
    # Configure ZFS optimizations
    optimize_zfs
    
    # Create optimized sysctl configuration files
    create_sysctl_configs
    
    # Apply sysctl settings with enhanced error handling
    log "INFO" "Applying system performance settings..."
    
    apply_sysctl_safe "$SYSCTL_DIR/99-proxmox-vm.conf" "VM performance settings"
    apply_sysctl_safe "$SYSCTL_DIR/99-proxmox-io.conf" "I/O performance settings"
    apply_sysctl_safe "$SYSCTL_DIR/99-proxmox-network.conf" "network performance settings"
    apply_sysctl_safe "$SYSCTL_DIR/99-proxmox-virt.conf" "virtualization settings"
    
    # Configure CPU governor for performance
    configure_cpu_governor
    
    # Configure system services
    configure_system_services
    
    # Configure log rotation for Proxmox
    configure_log_rotation
    
    # Record successful setup
    echo "$(date): System optimization completed successfully" >> "$SETUP_STATE_FILE"
    
    log "INFO" "System optimization completed successfully"
}

# Function to optimize ZFS for Proxmox
optimize_zfs() {
    log "INFO" "Configuring ZFS optimizations for Proxmox..."
    
    # Check if ZFS is available
    if ! command -v zfs &> /dev/null; then
        log "WARNING" "ZFS not found, skipping ZFS optimizations"
        return 0
    fi
    
    # Detect system memory for ZFS ARC sizing
    local total_memory_kb
    if ! total_memory_kb=$(grep MemTotal "$PROC_MEMINFO" | awk '{print $2}'); then
        log "ERROR" "Could not determine system memory, using conservative ZFS settings"
        total_memory_kb=8388608  # 8GB default
    fi
    
    local total_memory_gb=$((total_memory_kb / 1024 / 1024))
    
    # Calculate ARC limits (more conservative for Proxmox)
    local arc_min_gb=6
    local arc_max_gb=12
    
    # Adjust based on system memory with more granular control
    if [[ $total_memory_gb -lt 16 ]]; then
        arc_min_gb=1
        arc_max_gb=4
        log "INFO" "Adjusting ZFS ARC limits for low memory system: ${total_memory_gb}GB RAM"
    elif [[ $total_memory_gb -lt 32 ]]; then
        arc_min_gb=2
        arc_max_gb=8
        log "INFO" "Adjusting ZFS ARC limits for system with ${total_memory_gb}GB RAM"
    elif [[ $total_memory_gb -gt 64 ]]; then
        arc_min_gb=8
        arc_max_gb=24
        log "INFO" "Adjusting ZFS ARC limits for high memory system: ${total_memory_gb}GB RAM"
    else
        log "INFO" "Using standard ZFS ARC limits for system with ${total_memory_gb}GB RAM"
    fi
    
    # Backup and configure ZFS module parameters
    log "INFO" "Configuring ZFS module parameters..."
    local zfs_conf="$MODPROBE_DIR/99-zfs.conf"
    
    # Remove old config if it exists
    rm -f "$MODPROBE_DIR/zfs.conf"
    
    backup_file "$zfs_conf"
    cat > "$zfs_conf" << EOF
# ZFS ARC memory limits for Proxmox (${arc_min_gb}GB-${arc_max_gb}GB)
options zfs zfs_arc_min=$((arc_min_gb * 1024 * 1024 * 1024))
options zfs zfs_arc_max=$((arc_max_gb * 1024 * 1024 * 1024))

# ZFS performance optimizations
options zfs zfs_txg_timeout=5
options zfs zfs_vdev_scheduler=deadline
options zfs zfs_prefetch_disable=0
options zfs zfs_vdev_cache_size=10485760
options zfs metaslab_debug_load=0
options zfs metaslab_debug_unload=0
options zfs zfs_dirty_data_max_percent=25
options zfs zfs_delay_min_dirty_percent=60
options zfs zfs_dirty_data_sync_percent=20
options zfs l2arc_write_max=134217728
options zfs l2arc_write_boost=268435456
options zfs l2arc_headroom=8
options zfs l2arc_feed_secs=1
options zfs l2arc_feed_min_ms=200

# Increase default recordsize for better performance
options zfs zfs_max_recordsize=16777216
EOF
    
    # Backup and configure kernel modules
    log "INFO" "Configuring kernel modules..."
    local modules_file="$MODULES_FILE"
    backup_file "$modules_file"
    
    # Add required modules if not present
    if ! grep -q "^nf_conntrack$" "$modules_file" 2>/dev/null; then
        echo "nf_conntrack" >> "$modules_file"
        log "DEBUG" "Added nf_conntrack to kernel modules"
    fi
    
    if ! grep -q "^zfs$" "$modules_file" 2>/dev/null; then
        echo "zfs" >> "$modules_file"
        log "DEBUG" "Added zfs to kernel modules"
    fi
    
    # Update initramfs to apply ZFS settings
    log "INFO" "Updating initramfs with ZFS configuration..."
    if update-initramfs -u 2>/dev/null; then
        log "INFO" "Initramfs updated successfully"
    else
        log "WARNING" "Failed to update initramfs - ZFS settings may not be active until reboot"
    fi
    
    # Apply ZFS runtime parameters if ZFS is already loaded
    if lsmod | grep -q "^zfs "; then
        log "INFO" "Applying ZFS runtime parameters..."
        
        # Apply ARC settings with validation
        local arc_min_bytes=$((arc_min_gb * 1024 * 1024 * 1024))
        local arc_max_bytes=$((arc_max_gb * 1024 * 1024 * 1024))
        
        if [[ -f "$SYS_MODULE_DIR/zfs/parameters/zfs_arc_min" ]]; then
            if echo "$arc_min_bytes" > "$SYS_MODULE_DIR/zfs/parameters/zfs_arc_min" 2>/dev/null; then
                log "DEBUG" "Applied ZFS ARC min: ${arc_min_gb}GB"
            else
                log "WARNING" "Could not set ZFS ARC min parameter"
            fi
        fi
        
        if [[ -f "$SYS_MODULE_DIR/zfs/parameters/zfs_arc_max" ]]; then
            if echo "$arc_max_bytes" > "$SYS_MODULE_DIR/zfs/parameters/zfs_arc_max" 2>/dev/null; then
                log "DEBUG" "Applied ZFS ARC max: ${arc_max_gb}GB"
            else
                log "WARNING" "Could not set ZFS ARC max parameter"
            fi
        fi
        
        # Apply other runtime parameters with error handling
        local zfs_params=(
            "zfs_txg_timeout=5"
            "zfs_dirty_data_max_percent=25"
            "zfs_delay_min_dirty_percent=60"
            "zfs_dirty_data_sync_percent=20"
        )
        
        local applied_params=0
        for param in "${zfs_params[@]}"; do
            local param_name
            local param_value
            param_name=$(echo "$param" | cut -d'=' -f1)
            param_value=$(echo "$param" | cut -d'=' -f2)
            local param_file="$SYS_MODULE_DIR/zfs/parameters/$param_name"
            
            if [[ -f "$param_file" ]]; then
                if echo "$param_value" > "$param_file" 2>/dev/null; then
                    ((applied_params++))
                    log "DEBUG" "Applied ZFS parameter: ${param_name}=${param_value}"
                else
                    log "WARNING" "Could not set ZFS parameter: $param_name"
                fi
            else
                log "DEBUG" "ZFS parameter not available: $param_name"
            fi
        done
        
        log "INFO" "Applied $applied_params ZFS runtime parameters"
    else
        log "INFO" "ZFS module not currently loaded - parameters will be applied on next boot"
    fi
    
    # Optimize existing ZFS datasets if any exist
    if zfs list &>/dev/null; then
        optimize_zfs_datasets
    else
        log "INFO" "No ZFS datasets found to optimize"
    fi
    
    log "INFO" "ZFS optimization completed (ARC: ${arc_min_gb}GB-${arc_max_gb}GB)"
}

# Function to optimize existing ZFS datasets
optimize_zfs_datasets() {
    log "INFO" "Optimizing existing ZFS datasets..."
    
    local datasets
    if ! datasets=$(zfs list -H -o name 2>/dev/null | grep -v "^$"); then
        log "DEBUG" "No ZFS datasets found or ZFS not accessible"
        return 0
    fi
    
    local optimized_count=0
    local failed_count=0
    
    while IFS= read -r dataset; do
        # Skip if dataset doesn't exist or is a snapshot
        if [[ "$dataset" == *"@"* ]] || ! zfs get name "$dataset" &>/dev/null; then
            continue
        fi
        
        log "DEBUG" "Optimizing ZFS dataset: $dataset"
        
        # Apply performance optimizations with error handling
        local optimizations=(
            "compression=lz4"
            "atime=off"
            "relatime=on"
            "logbias=throughput"
            "primarycache=all"
            "secondarycache=all"
        )
        
        for optimization in "${optimizations[@]}"; do
            if zfs set "$optimization" "$dataset" 2>/dev/null; then
                log "DEBUG" "Applied $optimization to $dataset"
            else
                log "DEBUG" "Could not apply $optimization to $dataset"
                ((failed_count++))
            fi
        done
        
        # Apply dataset-specific optimizations
        if [[ "$dataset" == "rpool" ]] || [[ "$dataset" == "rpool/ROOT"* ]]; then
            # Root filesystem optimizations
            zfs set sync=standard "$dataset" 2>/dev/null || true
            zfs set recordsize=128K "$dataset" 2>/dev/null || true
            log "DEBUG" "Applied root filesystem optimizations to $dataset"
        elif [[ "$dataset" == *"/vm-"* ]] || [[ "$dataset" == *"/base-"* ]]; then
            # VM storage optimizations
            zfs set sync=always "$dataset" 2>/dev/null || true
            zfs set recordsize=64K "$dataset" 2>/dev/null || true
            zfs set volblocksize=16K "$dataset" 2>/dev/null || true
            log "DEBUG" "Applied VM storage optimizations to $dataset"
        fi
        
        ((optimized_count++))
    done <<< "$datasets"
    
    if [[ $optimized_count -gt 0 ]]; then
        log "INFO" "Optimized $optimized_count ZFS datasets"
        if [[ $failed_count -gt 0 ]]; then
            log "WARNING" "Some optimizations failed ($failed_count issues)"
        fi
    fi
}

# Backup and rollback functions
create_backup_infrastructure() {
    log "INFO" "Creating backup infrastructure..."
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$(dirname "$SETUP_STATE_FILE")"
    
    # Initialize rollback script
    cat > "$ROLLBACK_SCRIPT" << 'EOF'
#!/bin/bash
# Auto-generated rollback script for Hetzner Proxmox Setup

set -euo pipefail

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" | tee -a "${LOG_DIR:-/var/log}/hetzner-proxmox-rollback.log"
}

log "INFO" "Starting rollback of Hetzner Proxmox Setup changes..."
EOF
    chmod +x "$ROLLBACK_SCRIPT"
}

backup_file() {
    local file_path="$1"
    local backup_name="${2:-$(basename "$file_path")}"
    
    if [[ -f "$file_path" ]]; then
        local backup_path
        backup_path="${BACKUP_DIR}/${backup_name}.$(date +%Y%m%d_%H%M%S)"
        cp "$file_path" "$backup_path"
        BACKUP_FILES["$file_path"]="$backup_path"
        
        # Add to rollback script
        cat >> "$ROLLBACK_SCRIPT" << EOF

# Restore $file_path
if [[ -f "$backup_path" ]]; then
    log "INFO" "Restoring $file_path from backup"
    cp "$backup_path" "$file_path"
else
    log "WARNING" "Backup not found for $file_path"
fi
EOF
        log "DEBUG" "Backed up $file_path to $backup_path"
        return 0
    else
        # File doesn't exist, mark for deletion on rollback
        CREATED_FILES["$file_path"]="new"
        cat >> "$ROLLBACK_SCRIPT" << EOF

# Remove newly created file $file_path
if [[ -f "$file_path" ]]; then
    log "INFO" "Removing created file $file_path"
    rm -f "$file_path"
fi
EOF
        log "DEBUG" "Marked $file_path for creation tracking"
        return 1
    fi
}

validate_sysctl_parameter() {
    local param="$1"
    local value="$2"
    
    # Check if parameter exists in /proc/sys
    local proc_path="$PROC_SYS_DIR/${param//./\/}"
    if [[ ! -f "$proc_path" ]]; then
        log "DEBUG" "Parameter $param not available on this system"
        return 1
    fi
    
    # Try to read current value to ensure it's readable
    if ! cat "$proc_path" >/dev/null 2>&1; then
        log "DEBUG" "Parameter $param is not readable"
        return 1
    fi
    
    # Validate value format for common parameter types
    case "$param" in
        *.max|*.min|*_max|*_min|*.size|*_size|*.timeout|*_timeout|*.count|*_count)
            if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                log "WARNING" "Invalid numeric value '$value' for parameter $param"
                return 1
            fi
            ;;
        *.enabled|*_enabled)
            if ! [[ "$value" =~ ^[01]$ ]]; then
                log "WARNING" "Invalid boolean value '$value' for parameter $param (must be 0 or 1)"
                return 1
            fi
            ;;
        *tcp_rmem|*tcp_wmem)
            if ! [[ "$value" =~ ^[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+$ ]]; then
                log "WARNING" "Invalid TCP memory value '$value' for parameter $param"
                return 1
            fi
            ;;
    esac
    
    return 0
}

# Pre-flight system checks
validate_system_requirements() {
    log "INFO" "Validating system requirements..."
    
    local errors=()
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        errors+=("Must be run as root")
    fi
    
    # Check if systemctl is available
    if ! command -v systemctl &> /dev/null; then
        errors+=("systemctl not found - systemd required")
    fi
    
    # Check if we're on a supported distribution
    if [[ -f "$OS_RELEASE_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$OS_RELEASE_FILE"
        case "$ID" in
            debian|ubuntu)
                log "DEBUG" "Detected supported OS: $PRETTY_NAME"
                ;;
            *)
                errors+=("Unsupported distribution: $PRETTY_NAME (Debian/Ubuntu required)")
                ;;
        esac
    else
        errors+=("Cannot detect distribution - /etc/os-release missing")
    fi
    
    # Check available disk space
    local available_space
    available_space=$(df / | awk 'NR==2 {print $4}')
    if [[ $available_space -lt 1048576 ]]; then  # Less than 1GB
        errors+=("Insufficient disk space (less than 1GB available)")
    fi
    
    # Check if critical directories are writable
    local critical_dirs=("$SYSCTL_DIR" "$SYSTEMD_DIR" "$LOGROTATE_DIR")
    for dir in "${critical_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir" 2>/dev/null || errors+=("Cannot create directory: $dir")
        elif [[ ! -w "$dir" ]]; then
            errors+=("Directory not writable: $dir")
        fi
    done
    
    # Validate sysctl parameters availability
    local unavailable_params=0
    for param_key in "${!SYSCTL_CONFIGS[@]}"; do
        local param_line="${SYSCTL_CONFIGS[$param_key]}"
        local param="${param_line%%=*}"
        if ! validate_sysctl_parameter "$param" "test"; then
            ((unavailable_params++))
        fi
    done
    
    if [[ $unavailable_params -gt $((${#SYSCTL_CONFIGS[@]} / 2)) ]]; then
        errors+=("More than 50% of sysctl parameters unavailable - system may not be compatible")
    fi
    
    # Report validation results
    if [[ ${#errors[@]} -gt 0 ]]; then
        log "ERROR" "System validation failed:"
        for error in "${errors[@]}"; do
            log "ERROR" "  - $error"
        done
        return 1
    fi
    
    log "INFO" "System validation passed"
    return 0
}

# Enhanced safe sysctl application with better error handling
apply_sysctl_safe() {
    local config_file="$1"
    local description="$2"
    
    if [[ ! -f "$config_file" ]]; then
        log "ERROR" "Configuration file not found: $config_file"
        return 1
    fi
    
    log "INFO" "Applying $description..."
    
    local applied_count=0
    local failed_count=0
    local failed_settings=()
    
    while IFS= read -r line; do
        # Skip comments and empty lines
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line// }" ]]; then
            continue
        fi
        
        # Extract parameter name and value
        if [[ "$line" =~ ^[[:space:]]*([^=]+)=[[:space:]]*(.+)$ ]]; then
            local param="${BASH_REMATCH[1]// }"
            local value="${BASH_REMATCH[2]// }"
            
            # Validate parameter before applying
            if validate_sysctl_parameter "$param" "$value"; then
                if sysctl -w "${param}=${value}" >/dev/null 2>&1; then
                    ((applied_count++))
                    log "DEBUG" "Applied: ${param}=${value}"
                else
                    ((failed_count++))
                    failed_settings+=("${param}")
                    log "DEBUG" "Failed to apply: ${param}=${value}"
                fi
            else
                ((failed_count++))
                failed_settings+=("${param} (invalid/unavailable)")
                log "DEBUG" "Skipped invalid parameter: ${param}=${value}"
            fi
        fi
    done < "$config_file"
    
    # Report results
    log "INFO" "$description: Applied $applied_count parameters"
    if [[ $failed_count -gt 0 ]]; then
        log "WARNING" "$description: Failed to apply $failed_count parameters: ${failed_settings[*]}"
    fi
    
    return 0
}

# Function to create optimized sysctl configuration files
create_sysctl_configs() {
    log "INFO" "Creating optimized sysctl configuration files..."
    
    # VM Performance settings
    local vm_file="$SYSCTL_DIR/99-proxmox-vm.conf"
    backup_file "$vm_file"
    cat > "$vm_file" << EOF
# VM performance tuning for Proxmox
# Optimized for virtualization workloads
${SYSCTL_CONFIGS[vm_performance]}
EOF
    
    # I/O Performance settings
    local io_file="$SYSCTL_DIR/99-proxmox-io.conf"
    backup_file "$io_file"
    cat > "$io_file" << EOF
# I/O performance tuning for Proxmox with ZFS
# Optimized for storage-intensive virtualization workloads
${SYSCTL_CONFIGS[io_background_ratio]}
${SYSCTL_CONFIGS[io_dirty_ratio]}
${SYSCTL_CONFIGS[io_expire_centisecs]}
${SYSCTL_CONFIGS[io_writeback_centisecs]}
${SYSCTL_CONFIGS[io_cache_pressure]}
${SYSCTL_CONFIGS[io_min_free_kbytes]}
EOF
    
    # Network Performance settings
    local net_file="$SYSCTL_DIR/99-proxmox-network.conf"
    backup_file "$net_file"
    cat > "$net_file" << EOF
# Network performance tuning for Proxmox
# Optimized for high-throughput virtualized networking
${SYSCTL_CONFIGS[net_rmem_default]}
${SYSCTL_CONFIGS[net_rmem_max]}
${SYSCTL_CONFIGS[net_wmem_default]}
${SYSCTL_CONFIGS[net_wmem_max]}
${SYSCTL_CONFIGS[net_tcp_rmem]}
${SYSCTL_CONFIGS[net_tcp_wmem]}
${SYSCTL_CONFIGS[net_netdev_backlog]}
${SYSCTL_CONFIGS[net_tcp_congestion]}
${SYSCTL_CONFIGS[net_tcp_window_scaling]}
${SYSCTL_CONFIGS[net_tcp_timestamps]}
${SYSCTL_CONFIGS[net_tcp_sack]}
${SYSCTL_CONFIGS[net_somaxconn]}

# Netfilter connection tracking optimizations
${SYSCTL_CONFIGS[nf_conntrack_max]}
${SYSCTL_CONFIGS[nf_tcp_timeout_established]}
${SYSCTL_CONFIGS[nf_tcp_timeout_time_wait]}
${SYSCTL_CONFIGS[nf_tcp_timeout_close_wait]}
${SYSCTL_CONFIGS[nf_tcp_timeout_fin_wait]}
EOF
    
    # Virtualization settings
    local virt_file="$SYSCTL_DIR/99-proxmox-virt.conf"
    backup_file "$virt_file"
    cat > "$virt_file" << EOF
# Virtualization tuning for Proxmox
# Note: Some parameters may not be available on all kernel versions
${SYSCTL_CONFIGS[sched_autogroup_enabled]}
${SYSCTL_CONFIGS[numa_balancing]}
${SYSCTL_CONFIGS[zone_reclaim_mode]}
${SYSCTL_CONFIGS[max_map_count]}
${SYSCTL_CONFIGS[sched_migration_cost_ns]}
${SYSCTL_CONFIGS[sched_min_granularity_ns]}
${SYSCTL_CONFIGS[sched_wakeup_granularity_ns]}
EOF
    
    log "INFO" "Sysctl configuration files created successfully"
}

# Function to configure CPU governor
configure_cpu_governor() {
    log "INFO" "Configuring CPU governor..."
    
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        # Backup current governor setting
        local current_governor
        current_governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
        echo "# Previous governor: $current_governor" > "$SETUP_BASE_DIR/cpu_governor.backup"
        
        # Try to set performance governor
        if echo "performance" > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null; then
            log "INFO" "CPU governor set to performance mode"
            
            # Create persistent service
            local service_file="$SYSTEMD_DIR/cpu-performance.service"
            backup_file "$service_file"
            cat > "$service_file" << 'EOF'
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for i in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $i 2>/dev/null || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
            
            if systemctl enable cpu-performance.service 2>/dev/null && systemctl start cpu-performance.service 2>/dev/null; then
                log "INFO" "CPU performance service enabled"
                INSTALLED_SERVICES["cpu-performance"]="enabled"
                
                # Add to rollback script  
                cat >> "$ROLLBACK_SCRIPT" << EOF

# Disable CPU performance service
if systemctl is-enabled cpu-performance.service &>/dev/null; then
    log "INFO" "Disabling CPU performance service"
    systemctl disable cpu-performance.service 2>/dev/null || true
    systemctl stop cpu-performance.service 2>/dev/null || true
fi
EOF
            else
                log "WARNING" "Could not enable CPU performance service"
            fi
        else
            log "WARNING" "Could not set CPU governor to performance mode (may not be supported)"
        fi
    else
        log "INFO" "CPU frequency scaling not available (this is normal in virtual environments)"
    fi
}

# Function to configure system services
configure_system_services() {
    log "INFO" "Configuring system services..."
    
    # Configure irqbalance for better interrupt handling
    log "INFO" "Configuring IRQ balancing..."
    if systemctl enable irqbalance 2>/dev/null && systemctl start irqbalance 2>/dev/null; then
        log "INFO" "IRQ balancing service enabled"
        INSTALLED_SERVICES["irqbalance"]="enabled"
    else
        log "WARNING" "Could not enable IRQ balancing service"
    fi
    
    # Configure chrony for better time synchronization
    log "INFO" "Configuring time synchronization..."
    if systemctl enable chrony 2>/dev/null && systemctl start chrony 2>/dev/null; then
        log "INFO" "Chrony time synchronization enabled"
        INSTALLED_SERVICES["chrony"]="enabled"
    else
        log "WARNING" "Could not enable chrony service"
    fi
    
    # Optimize systemd journal
    log "INFO" "Configuring systemd journal..."
    local journal_conf="/etc/systemd/journald.conf.d/99-proxmox.conf"
    mkdir -p "$(dirname "$journal_conf")"
    backup_file "$journal_conf"
    cat > "$journal_conf" << 'EOF'
[Journal]
SystemMaxUse=100M
SystemMaxFileSize=10M
RuntimeMaxUse=50M
RuntimeMaxFileSize=5M
MaxRetentionSec=1week
EOF
    
    if systemctl restart systemd-journald 2>/dev/null; then
        log "INFO" "Systemd journal configuration applied"
    else
        log "WARNING" "Could not restart systemd-journald"
    fi
    
    # Enable and configure tuned for virtualization host profile
    log "INFO" "Configuring tuned for virtualization..."
    if systemctl enable tuned 2>/dev/null && systemctl start tuned 2>/dev/null; then
        INSTALLED_SERVICES["tuned"]="enabled"
        
        # Store current profile for rollback
        local current_profile
        current_profile=$(tuned-adm active 2>/dev/null | awk '{print $NF}' || echo "balanced")
        echo "$current_profile" > "$SETUP_BASE_DIR/tuned_profile.backup"
        
        # Try virtual-host profile first, fallback to throughput-performance
        if tuned-adm profile virtual-host 2>/dev/null; then
            log "INFO" "Tuned configured with virtual-host profile"
        elif tuned-adm profile throughput-performance 2>/dev/null; then
            log "INFO" "Tuned configured with throughput-performance profile"
        else
            log "WARNING" "Could not configure tuned profile, using default"
        fi
        
        # Add tuned rollback to script
        cat >> "$ROLLBACK_SCRIPT" << EOF

# Restore tuned profile
if [[ -f "$SETUP_BASE_DIR/tuned_profile.backup" ]]; then
    original_profile=\$(cat "$SETUP_BASE_DIR/tuned_profile.backup")
    log "INFO" "Restoring tuned profile to: \$original_profile"
    tuned-adm profile "\$original_profile" 2>/dev/null || true
fi
EOF
    else
        log "WARNING" "Could not start tuned service"
    fi
}

# Function to configure log rotation
configure_log_rotation() {
    log "INFO" "Configuring log rotation..."
    
    local logrotate_conf="$LOGROTATE_DIR/proxmox-custom"
    backup_file "$logrotate_conf"
    cat > "$logrotate_conf" << 'EOF'
/var/log/pve/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 640 root adm
}

/var/log/hetzner-proxmox-setup.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 644 root root
}

${LOG_DIR:-/var/log}/hetzner-proxmox-rollback.log {
    daily
    missingok
    rotate 10
    compress
    delaycompress
    notifempty
    create 644 root root
}
EOF
    
    # Test logrotate configuration
    if logrotate -d "$logrotate_conf" >/dev/null 2>&1; then
        log "INFO" "Log rotation configured successfully"
    else
        log "WARNING" "Log rotation configuration may have issues"
    fi
}

# Function to create rollback script
create_rollback_command() {
    log "INFO" "Creating rollback functionality..."
    
    # Add summary of tracked changes to rollback script
    cat >> "$ROLLBACK_SCRIPT" << EOF

# Summary of tracked changes:
# Backed up files: ${!BACKUP_FILES[@]}
# Created files: ${!CREATED_FILES[@]} 
# Enabled services: ${!INSTALLED_SERVICES[@]}

EOF

    # Finalize rollback script
    cat >> "$ROLLBACK_SCRIPT" << 'EOF'

log "INFO" "Rollback completed. Please reboot to ensure all changes are reverted."
EOF
    
    # Make it executable
    chmod +x "$ROLLBACK_SCRIPT"
    
    # Create a simple rollback command
    cat > "$ROLLBACK_COMMAND_PATH" << EOF
#!/bin/bash
# Rollback script for Hetzner Proxmox Setup

if [[ \$EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
    exit 1
fi

echo "This will rollback all changes made by the Hetzner Proxmox Setup script."
echo "Are you sure you want to continue? (y/N)"
read -r response

if [[ "\$response" =~ ^[Yy]$ ]]; then
    if [[ -f "$ROLLBACK_SCRIPT" ]]; then
        echo "Running rollback script..."
        bash "$ROLLBACK_SCRIPT"
        echo "Rollback completed. A reboot is recommended."
    else
        echo "Error: Rollback script not found at $ROLLBACK_SCRIPT"
        exit 1
    fi
else
    echo "Rollback cancelled."
fi
EOF
    
    chmod +x "$ROLLBACK_COMMAND_PATH"
    log "INFO" "Rollback command created: $(basename "$ROLLBACK_COMMAND_PATH")"
}

# Main function
main() {
    # Parse arguments
    local rollback_mode=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                cat << EOF
Usage: $0 [OPTIONS]

Optimize the Proxmox host system for performance, including ZFS optimizations.

OPTIONS:
    --help                Show this help message
    --rollback           Rollback all changes made by this script

OPTIMIZATIONS PERFORMED:
    - System package updates with error handling
    - ZFS performance tuning (ARC limits, module parameters)
    - Performance tuning for virtualization
    - Network performance optimization  
    - I/O performance tuning
    - CPU governor configuration
    - Log rotation setup
    - Time synchronization
    - IRQ balancing
    - Netfilter connection tracking optimization

RESILIENCE FEATURES:
    - Pre-flight system validation
    - Configuration file backup
    - Rollback functionality
    - Graceful error handling
    - Parameter validation

EXAMPLES:
    $0                    # Run system optimization
    $0 --rollback        # Rollback all changes

ROLLBACK:
    After running the script, you can rollback changes using:
    - $0 --rollback
    - proxmox-setup-rollback

EOF
                exit 0
                ;;
            --rollback)
                rollback_mode=true
                shift
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # Handle rollback mode
    if [[ "$rollback_mode" == true ]]; then
        if [[ $EUID -ne 0 ]]; then
            log "ERROR" "Rollback must be run as root"
            exit 1
        fi
        
        if [[ -f "$ROLLBACK_SCRIPT" ]]; then
            log "INFO" "Starting rollback of Hetzner Proxmox Setup changes..."
            bash "$ROLLBACK_SCRIPT"
            log "INFO" "Rollback completed. A reboot is recommended."
        else
            log "ERROR" "Rollback script not found. No previous installation detected."
            exit 1
        fi
        exit 0
    fi
    
    # Validate system requirements before making any changes
    if ! validate_system_requirements; then
        log "ERROR" "System validation failed. Aborting optimization."
        exit 1
    fi
    
    log "INFO" "Starting Proxmox system optimization with resilience features..."
    echo
    
    # Run system optimization
    if ! optimize_system; then
        log "ERROR" "System optimization failed"
        if [[ -f "$ROLLBACK_SCRIPT" ]]; then
            log "INFO" "Rollback script available at: $ROLLBACK_SCRIPT"
            log "INFO" "Run 'proxmox-setup-rollback' to undo changes"
        fi
        exit 1
    fi
    
    # Create rollback functionality
    create_rollback_command
    
    echo
    log "INFO" "✅ System optimization completed successfully!"
    log "INFO" ""
    log "INFO" "System optimizations applied:"
    log "INFO" "- ZFS performance tuning (ARC limits, module parameters, datasets)"
    log "INFO" "- VM performance tuning (swappiness, I/O, network)"
    log "INFO" "- CPU performance governor enabled (if available)"
    log "INFO" "- IRQ balancing configured"
    log "INFO" "- Time synchronization with chrony"
    log "INFO" "- Log rotation configured"
    log "INFO" "- Tuned virtualization profile active"
    log "INFO" "- Netfilter connection tracking optimized"
    echo
    
    log "INFO" "Resilience features:"
    log "INFO" "- Configuration backup created in: $BACKUP_DIR"
    log "INFO" "- Rollback script available: $ROLLBACK_SCRIPT"
    log "INFO" "- Rollback command: proxmox-setup-rollback"
    echo
    
    log "INFO" "Next steps:"
    log "INFO" "1. Reboot to ensure all optimizations are active"
    log "INFO" "2. Format additional drives: ./install.sh --format-drives"
    log "INFO" "3. Setup RAID mirrors: ./install.sh --setup-mirrors" 
    log "INFO" "4. Configure network: ./install.sh --network"
    echo
    
    log "INFO" "If you experience issues, run 'proxmox-setup-rollback' to undo changes"
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

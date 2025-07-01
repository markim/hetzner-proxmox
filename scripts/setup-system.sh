#!/bin/bash

# Hetzner Proxmox System Setup Script
# This script optimizes the host system for Proxmox and sets up a /var/lib/vz directory for storage

set -euo pipefail

# Custom error handler
error_handler() {
    local line_no=$1
    local error_code=$2
    log "ERROR" "Script failed at line $line_no with exit code $error_code"
    log "ERROR" "This error occurred in the setup-system script"
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
    
    # Update system packages
    log "INFO" "Updating system packages..."
    apt-get update
    apt-get upgrade -y
    
    # Install essential packages for Proxmox optimization
    log "INFO" "Installing system optimization packages..."
    apt-get install -y \
        htop \
        iotop \
        sysstat \
        smartmontools \
        lm-sensors \
        ethtool \
        tuned \
        irqbalance \
        chrony \
        rsyslog \
        logrotate \
        parted \
        curl \
        debian-keyring \
        debian-archive-keyring \
        apt-transport-https \
        gnupg \
        zfsutils-linux \
        nvme-cli \
        fio
    
    # Configure ZFS optimizations
    optimize_zfs
    
    # Configure system swappiness for better VM performance
    log "INFO" "Configuring VM swappiness..."
    echo "vm.swappiness=1" > /etc/sysctl.d/99-proxmox-swappiness.conf
    
    # Configure dirty page handling for better I/O performance
    log "INFO" "Configuring I/O performance settings..."
    cat > /etc/sysctl.d/99-proxmox-io.conf << 'EOF'
# I/O performance tuning for Proxmox with ZFS
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500
vm.vfs_cache_pressure = 50
vm.min_free_kbytes = 131072
EOF
    
    # Configure network performance and netfilter
    log "INFO" "Configuring network performance settings..."
    cat > /etc/sysctl.d/99-proxmox-network.conf << 'EOF'
# Network performance tuning for Proxmox
net.core.rmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_default = 262144
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.core.somaxconn = 8192

# Netfilter connection tracking optimizations
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 28800
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
EOF
    
    # Configure kernel parameters for virtualization
    log "INFO" "Configuring virtualization settings..."
    cat > /etc/sysctl.d/99-proxmox-virt.conf << 'EOF'
# Virtualization tuning for Proxmox
# Note: Some parameters may not be available on all kernel versions

# Disable automatic process grouping (can interfere with VM scheduling)
kernel.sched_autogroup_enabled = 0

# Disable NUMA balancing for better VM performance
kernel.numa_balancing = 0

# Memory management optimizations
vm.zone_reclaim_mode = 0
vm.max_map_count = 262144

# KVM optimizations
kernel.sched_migration_cost_ns = 5000000
kernel.sched_min_granularity_ns = 10000000
kernel.sched_wakeup_granularity_ns = 15000000
EOF
    
    # Apply sysctl settings with error handling
    log "INFO" "Applying system performance settings..."
    
    apply_sysctl_safe "/etc/sysctl.d/99-proxmox-swappiness.conf" "VM performance settings"
    apply_sysctl_safe "/etc/sysctl.d/99-proxmox-io.conf" "I/O performance settings"
    apply_sysctl_safe "/etc/sysctl.d/99-proxmox-network.conf" "network performance settings"
    apply_sysctl_safe "/etc/sysctl.d/99-proxmox-virt.conf" "virtualization settings"
    
    # Configure CPU governor for performance
    log "INFO" "Configuring CPU governor..."
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        # Try to set performance governor
        if echo "performance" > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null; then
            log "INFO" "CPU governor set to performance mode"
            
            # Make it persistent
            cat > /etc/systemd/system/cpu-performance.service << 'EOF'
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
            else
                log "WARNING" "Could not enable CPU performance service"
            fi
        else
            log "WARNING" "Could not set CPU governor to performance mode (may not be supported)"
        fi
    else
        log "INFO" "CPU frequency scaling not available (this is normal in virtual environments)"
    fi
    
    # Configure irqbalance for better interrupt handling
    log "INFO" "Configuring IRQ balancing..."
    if systemctl enable irqbalance 2>/dev/null && systemctl start irqbalance 2>/dev/null; then
        log "INFO" "IRQ balancing service enabled"
    else
        log "WARNING" "Could not enable IRQ balancing service"
    fi
    
    # Configure chrony for better time synchronization
    log "INFO" "Configuring time synchronization..."
    if systemctl enable chrony 2>/dev/null && systemctl start chrony 2>/dev/null; then
        log "INFO" "Chrony time synchronization enabled"
    else
        log "WARNING" "Could not enable chrony service"
    fi
    
    # Configure log rotation for Proxmox
    log "INFO" "Configuring log rotation..."
    cat > /etc/logrotate.d/proxmox-custom << 'EOF'
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
EOF
    
    # Optimize systemd journal
    log "INFO" "Configuring systemd journal..."
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-proxmox.conf << 'EOF'
[Journal]
SystemMaxUse=100M
SystemMaxFileSize=10M
RuntimeMaxUse=50M
RuntimeMaxFileSize=5M
MaxRetentionSec=1week
EOF
    
    systemctl restart systemd-journald 2>/dev/null || log "WARNING" "Could not restart systemd-journald"
    
    # Enable and configure tuned for virtualization host profile
    log "INFO" "Configuring tuned for virtualization..."
    if systemctl enable tuned 2>/dev/null && systemctl start tuned 2>/dev/null; then
        # Try virtual-host profile first, fallback to throughput-performance
        if tuned-adm profile virtual-host 2>/dev/null; then
            log "INFO" "Tuned configured with virtual-host profile"
        elif tuned-adm profile throughput-performance 2>/dev/null; then
            log "INFO" "Tuned configured with throughput-performance profile"
        else
            log "WARNING" "Could not configure tuned profile, using default"
        fi
    else
        log "WARNING" "Could not start tuned service"
    fi
    
    log "INFO" "System optimization completed successfully"
}

# Function to optimize ZFS for Proxmox
optimize_zfs() {
    log "INFO" "Configuring ZFS optimizations for Proxmox..."
    
    # Check if ZFS is available
    if ! command -v zfs &> /dev/null; then
        log "WARNING" "ZFS not found, skipping ZFS optimizations"
        return
    fi
    
    # Detect system memory for ZFS ARC sizing
    local total_memory_kb
    total_memory_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_memory_gb=$((total_memory_kb / 1024 / 1024))
    
    # Calculate ARC limits (more conservative for Proxmox)
    local arc_min_gb=6
    local arc_max_gb=12
    
    # Adjust based on system memory
    if [[ $total_memory_gb -lt 32 ]]; then
        arc_min_gb=2
        arc_max_gb=8
        log "INFO" "Adjusting ZFS ARC limits for system with ${total_memory_gb}GB RAM"
    elif [[ $total_memory_gb -gt 64 ]]; then
        arc_min_gb=8
        arc_max_gb=24
        log "INFO" "Adjusting ZFS ARC limits for system with ${total_memory_gb}GB RAM"
    fi
    
    # Configure ZFS module parameters
    log "INFO" "Configuring ZFS module parameters..."
    rm -f /etc/modprobe.d/zfs.conf
    cat > /etc/modprobe.d/99-zfs.conf << EOF
# ZFS ARC memory limits for Proxmox
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
    
    # Configure kernel modules
    log "INFO" "Configuring kernel modules..."
    echo "nf_conntrack" >> /etc/modules
    
    # Ensure ZFS module is loaded at boot
    if ! grep -q "^zfs$" /etc/modules 2>/dev/null; then
        echo "zfs" >> /etc/modules
    fi
    
    # Update initramfs to apply ZFS settings
    log "INFO" "Updating initramfs with ZFS configuration..."
    if ! update-initramfs -u; then
        log "WARNING" "Failed to update initramfs - ZFS settings may not be active until reboot"
    fi
    
    # Set ZFS runtime parameters if ZFS is already loaded
    if lsmod | grep -q zfs; then
        log "INFO" "Applying ZFS runtime parameters..."
        
        # Apply ARC settings
        if [[ -f /sys/module/zfs/parameters/zfs_arc_min ]]; then
            echo $((arc_min_gb * 1024 * 1024 * 1024)) > /sys/module/zfs/parameters/zfs_arc_min 2>/dev/null || true
        fi
        if [[ -f /sys/module/zfs/parameters/zfs_arc_max ]]; then
            echo $((arc_max_gb * 1024 * 1024 * 1024)) > /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null || true
        fi
        
        # Apply other runtime parameters
        local zfs_params=(
            "zfs_txg_timeout=5"
            "zfs_dirty_data_max_percent=25"
            "zfs_delay_min_dirty_percent=60"
            "zfs_dirty_data_sync_percent=20"
        )
        
        for param in "${zfs_params[@]}"; do
            local param_name
            local param_value
            param_name=$(echo "$param" | cut -d'=' -f1)
            param_value=$(echo "$param" | cut -d'=' -f2)
            local param_file="/sys/module/zfs/parameters/$param_name"
            
            if [[ -f "$param_file" ]]; then
                echo "$param_value" > "$param_file" 2>/dev/null || true
            fi
        done
    fi
    
    # Optimize ZFS datasets if any exist
    if zfs list &>/dev/null; then
        log "INFO" "Optimizing existing ZFS datasets..."
        
        # Get all ZFS datasets
        local datasets
        datasets=$(zfs list -H -o name 2>/dev/null | grep -v "^$" || true)
        
        if [[ -n "$datasets" ]]; then
            while IFS= read -r dataset; do
                # Skip if dataset doesn't exist or is a snapshot
                if [[ "$dataset" == *"@"* ]] || ! zfs get name "$dataset" &>/dev/null; then
                    continue
                fi
                
                log "DEBUG" "Optimizing ZFS dataset: $dataset"
                
                # Apply performance optimizations
                zfs set compression=lz4 "$dataset" 2>/dev/null || true
                zfs set atime=off "$dataset" 2>/dev/null || true
                zfs set relatime=on "$dataset" 2>/dev/null || true
                zfs set logbias=throughput "$dataset" 2>/dev/null || true
                zfs set primarycache=all "$dataset" 2>/dev/null || true
                zfs set secondarycache=all "$dataset" 2>/dev/null || true
                
                # For root datasets, set specific optimizations
                if [[ "$dataset" == "rpool" ]] || [[ "$dataset" == "rpool/ROOT"* ]]; then
                    zfs set sync=standard "$dataset" 2>/dev/null || true
                    zfs set recordsize=128K "$dataset" 2>/dev/null || true
                elif [[ "$dataset" == *"/vm-"* ]] || [[ "$dataset" == *"/base-"* ]]; then
                    # VM storage optimizations
                    zfs set sync=always "$dataset" 2>/dev/null || true
                    zfs set recordsize=64K "$dataset" 2>/dev/null || true
                    zfs set volblocksize=16K "$dataset" 2>/dev/null || true
                fi
            done <<< "$datasets"
        fi
    fi
    
    log "INFO" "ZFS optimization completed (ARC: ${arc_min_gb}GB-${arc_max_gb}GB)"
}

# Function to safely apply sysctl settings
apply_sysctl_safe() {
    local config_file="$1"
    local description="$2"
    
    log "INFO" "Applying $description..."
    
    # Read the config file and apply each setting individually
    local failed_settings=()
    while IFS= read -r line; do
        # Skip comments and empty lines
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line// }" ]]; then
            continue
        fi
        
        # Extract parameter name
        if [[ "$line" =~ ^[[:space:]]*([^=]+)=[[:space:]]*(.+)$ ]]; then
            local param="${BASH_REMATCH[1]// }"
            local value="${BASH_REMATCH[2]// }"
            
            # Check if the parameter exists
            if [[ -f "/proc/sys/${param//./\/}" ]]; then
                if ! sysctl -w "${param}=${value}" >/dev/null 2>&1; then
                    failed_settings+=("${param}")
                fi
            else
                log "DEBUG" "Skipping unavailable parameter: $param"
                failed_settings+=("${param} (not available)")
            fi
        fi
    done < "$config_file"
    
    if [[ ${#failed_settings[@]} -gt 0 ]]; then
        log "WARNING" "Some $description could not be applied: ${failed_settings[*]}"
    else
        log "INFO" "$description applied successfully"
    fi
}



# Main function
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                cat << EOF
Usage: $0 [OPTIONS]

Optimize the Proxmox host system for performance, including ZFS optimizations.

OPTIONS:
    --help                Show this help message

OPTIMIZATIONS PERFORMED:
    - System package updates
    - ZFS performance tuning (ARC limits, module parameters)
    - Performance tuning for virtualization
    - Network performance optimization
    - I/O performance tuning
    - CPU governor configuration
    - Log rotation setup
    - Time synchronization
    - IRQ balancing
    - Netfilter connection tracking optimization

EXAMPLES:
    $0                        # Run system optimization

EOF
                exit 0
                ;;

            *)
                log "ERROR" "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "This script must be run as root"
        exit 1
    fi
    
    log "INFO" "Starting Proxmox system optimization..."
    echo
    
    # Optimize system
    optimize_system
    echo
    
    log "INFO" "✅ System optimization completed successfully!"
    log "INFO" ""
    log "INFO" "System optimizations applied:"
    log "INFO" "- ZFS performance tuning (ARC limits, module parameters, datasets)"
    log "INFO" "- VM performance tuning (swappiness, I/O, network)"
    log "INFO" "- CPU performance governor enabled"
    log "INFO" "- IRQ balancing configured"
    log "INFO" "- Time synchronization with chrony"
    log "INFO" "- Log rotation configured"
    log "INFO" "- Tuned virtualization profile active"
    log "INFO" "- Netfilter connection tracking optimized"
    echo
    
    log "INFO" "Next steps:"
    log "INFO" "1. Reboot to ensure all optimizations are active" 
    log "INFO" "2. Format additional drives: ./install.sh --format-drives"
    log "INFO" "3. Setup RAID mirrors: ./install.sh --setup-mirrors"
    log "INFO" "4. Configure network: ./install.sh --network"
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

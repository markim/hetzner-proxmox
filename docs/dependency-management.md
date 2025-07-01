# Dependency Management Guide

This document outlines the centralized dependency management approach used in the Hetzner Proxmox Setup scripts.

## Overview

All system dependencies are now managed centrally through the `setup-system.sh` script to ensure consistency and prevent conflicts. Other scripts no longer install packages independently.

## Centralized Installation

### Primary Dependency Script: `setup-system.sh`

The `setup-system.sh` script installs all required dependencies for the entire project:

#### System Optimization Packages
- `htop`, `iotop`, `sysstat` - System monitoring tools
- `smartmontools` - Hard drive health monitoring
- `lm-sensors` - Hardware sensors
- `ethtool` - Network interface configuration
- `tuned` - Performance tuning daemon
- `irqbalance` - Interrupt balancing
- `chrony` - Time synchronization
- `rsyslog`, `logrotate` - Logging management
- `fio` - Storage performance testing
- `nvme-cli` - NVMe drive management

#### Core Dependencies for All Scripts
- `util-linux` - Provides: `lsblk`, `findmnt`, `wipefs`, `blkid`
- `parted` - Disk partitioning tool
- `zfsutils-linux` - ZFS filesystem tools (`zpool`, `zfs`)
- `lvm2` - Logical Volume Manager tools (`pvs`)
- `systemd` - System service management (`systemctl`)
- `iputils-ping` - Network connectivity testing (`ping`)
- `curl`, `wget` - Download tools
- `coreutils` - Basic system utilities

#### Development and Build Tools
- `build-essential` - Compilation tools
- `git` - Version control
- `debian-keyring`, `debian-archive-keyring` - Package verification
- `apt-transport-https`, `gnupg` - Secure package management

## Script-Specific Dependency Handling

### Scripts Without Package Installation

The following scripts now rely on `setup-system.sh` for dependencies:

1. **`format-drives.sh`**
   - Requires: `lsblk`, `parted`, `zpool`, `wipefs`, `blkid`
   - Error message refers users to run `./install.sh --setup-system`

2. **`setup-mirrors.sh`**
   - Requires: `lsblk`, `zpool`, `zfs`
   - Checks for ZFS tools and fails with helpful message if missing

3. **`remove-mirrors.sh`**
   - Requires: `findmnt`, `zpool`
   - Validation handled by `install.sh`

4. **`setup-network.sh`**
   - Requires: `ping`, `systemctl`
   - Basic tools usually available on Debian systems

### Scripts With Special Installation Requirements

1. **`setup-caddy.sh`**
   - Installs Caddy from official repository
   - Requires special GPG key and repository setup
   - Keeps its own installation logic due to non-standard package source

## Workflow Integration

### Recommended Setup Order

1. **First Run**: `./install.sh --setup-system`
   - Installs all dependencies
   - Optimizes system for Proxmox
   - Sets up backup and rollback infrastructure

2. **Subsequent Operations**: Any other script
   - Dependencies already available
   - Fast execution without installation delays

### Validation Process

The `install.sh` script validates required tools before running operations:

```bash
# Example validation for format-drives
local missing_tools=()
local required_tools=("lsblk" "parted" "zpool")
for tool in "${required_tools[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        missing_tools+=("$tool")
    fi
done
if [[ ${#missing_tools[@]} -gt 0 ]]; then
    log "ERROR" "Missing required tools: ${missing_tools[*]}"
    log "ERROR" "Please run system setup first: $0 --setup-system"
    exit 1
fi
```

## Benefits of Centralized Dependency Management

### 1. **Consistency**
- All dependencies installed with compatible versions
- No conflicts between different installation attempts
- Single source of truth for package requirements

### 2. **Performance**
- Faster script execution (no repeated package installations)
- Single `apt update` operation
- Bulk installation more efficient than individual installs

### 3. **Reliability**
- Pre-validation prevents partial script failures
- Clear error messages with resolution steps
- Rollback capability for all installed packages

### 4. **Maintenance**
- Easy to update dependency lists in one location
- Version pinning possible if needed
- Centralized troubleshooting

## Error Handling

### Missing Dependencies
When dependencies are missing, scripts provide helpful error messages:

```
ERROR: Missing required tools: zpool zfs
ERROR: Please run system setup first: ./install.sh --setup-system
```

### Installation Failures
The `setup-system.sh` script handles installation failures gracefully:
- Continues with available packages
- Reports failed installations
- Provides detailed logging

### Recovery Options
- Complete rollback available via `proxmox-setup-rollback`
- Individual package installation possible if needed
- Clear dependency chain for troubleshooting

## Environment Variables

Dependencies can be customized via environment variables:

```bash
# Skip certain packages (advanced usage)
export SKIP_PACKAGES="fio nvme-cli"
./install.sh --setup-system

# Custom package repositories
export ADDITIONAL_REPOS="custom-repo-url"
```

## Troubleshooting

### Common Issues

1. **Package Not Found**
   ```bash
   # Update package list
   apt update
   # Run setup again
   ./install.sh --setup-system
   ```

2. **Permission Denied**
   ```bash
   # Ensure running as root
   sudo ./install.sh --setup-system
   ```

3. **Network Issues**
   ```bash
   # Check connectivity
   ping -c 1 8.8.8.8
   # Check DNS resolution
   nslookup debian.org
   ```

### Dependency Verification

To verify all dependencies are installed:

```bash
# Check ZFS tools
zpool status
zfs version

# Check system tools
lsblk --version
parted --version

# Check Proxmox tools
pvesh --version
qm --version
```

## Migration Notes

### From Previous Versions
- Old installations may have scattered dependencies
- Run `./install.sh --setup-system` to consolidate
- Use rollback if issues occur

### Custom Environments
- Test in non-production environment first
- Backup existing package state if needed
- Verify all tools after migration

This centralized approach ensures reliable, maintainable, and efficient dependency management across the entire Hetzner Proxmox Setup project.

# Setup System Configuration Guide

This document describes the configurable paths and environment variables for the Hetzner Proxmox setup scripts.

## Core System Configuration (setup-system.sh)

### Configurable Paths

The setup-system.sh script uses configurable paths that can be overridden by environment variables for maximum portability and customization.

#### Setup and Backup Directories

| Variable | Default Value | Description |
|----------|---------------|-------------|
| `SETUP_BASE_DIR` | `/var/lib/hetzner-proxmox-setup` | Base directory for setup files |
| `BACKUP_DIR` | `$SETUP_BASE_DIR/backups` | Directory for configuration backups |
| `ROLLBACK_SCRIPT` | `$SETUP_BASE_DIR/rollback.sh` | Path to rollback script |
| `SETUP_STATE_FILE` | `$SETUP_BASE_DIR/setup.state` | Setup state tracking file |

#### System Configuration Directories

| Variable | Default Value | Description |
|----------|---------------|-------------|
| `SYSCTL_DIR` | `/etc/sysctl.d` | Directory for sysctl configuration files |
| `SYSTEMD_DIR` | `/etc/systemd/system` | Directory for systemd service files |
| `LOGROTATE_DIR` | `/etc/logrotate.d` | Directory for logrotate configuration |
| `MODPROBE_DIR` | `/etc/modprobe.d` | Directory for kernel module configuration |
| `MODULES_FILE` | `/etc/modules` | File listing kernel modules to load |

#### Command Paths

| Variable | Default Value | Description |
|----------|---------------|-------------|
| `ROLLBACK_COMMAND_PATH` | `/usr/local/bin/proxmox-setup-rollback` | Path for rollback command |

#### Log Directory

| Variable | Default Value | Description |
|----------|---------------|-------------|
| `LOG_DIR` | `/var/log` | Directory for log files |

## Network Configuration (setup-network.sh)

| Variable | Default Value | Description |
|----------|---------------|-------------|
| `NETWORK_BACKUP_DIR` | `/root/network-backups` | Directory for network configuration backups |
| `INTERFACES_FILE` | `/etc/network/interfaces` | Main network interfaces configuration file |
| `SYSCTL_DIR` | `/etc/sysctl.d` | Directory for sysctl configuration files (pfSense integration) |
| `MODULES_FILE` | `/etc/modules` | File for loading bridge netfilter module |

## VM Setup Scripts

### pfSense Setup (setup-pfsense.sh)

| Variable | Default Value | Description |
|----------|---------------|-------------|
| `PFSENSE_ISO_PATH` | `/var/lib/vz/template/iso/pfSense-CE-2.7.2-RELEASE-amd64.iso` | Path to pfSense ISO file |

### Firewall Admin Setup (setup-firewall-admin.sh)

| Variable | Default Value | Description |
|----------|---------------|-------------|
| `VM_ISO_PATH` | `/var/lib/vz/template/iso/BookwormPup64_10.0.11.iso` | Path to Firewall Admin VM ISO file |

## System Paths (Read-Only)

These paths are standard Linux system paths and should not be changed:

- `PROC_SYS_DIR`: `/proc/sys` - Kernel parameter interface
- `SYS_MODULE_DIR`: `/sys/module` - Kernel module parameters
- `PROC_MEMINFO`: `/proc/meminfo` - System memory information
- `OS_RELEASE_FILE`: `/etc/os-release` - Operating system identification

## Usage Examples

### Default Configuration

```bash
# Uses default paths
./scripts/setup-system.sh
```

### Custom Base Directory

```bash
# Use custom setup directory
export SETUP_BASE_DIR="/opt/proxmox-setup"
./scripts/setup-system.sh
```

### Custom Backup Location

```bash
# Use custom backup directory
export BACKUP_DIR="/backup/proxmox-setup"
./scripts/setup-system.sh
```

### Testing with Alternative Paths

```bash
# For testing without affecting system
export SETUP_BASE_DIR="/tmp/test-setup"
export SYSCTL_DIR="/tmp/test-setup/sysctl.d"
export SYSTEMD_DIR="/tmp/test-setup/systemd"
export LOGROTATE_DIR="/tmp/test-setup/logrotate.d"
export ROLLBACK_COMMAND_PATH="/tmp/test-setup/rollback-command"
./scripts/setup-system.sh --help
```

## Rollback Functionality

The script creates comprehensive rollback functionality:

### Automatic Backup

- All modified configuration files are automatically backed up
- Backup files include timestamps
- Original service states are preserved

### Rollback Options

1. **Automatic Rollback Script**: `$ROLLBACK_SCRIPT`
2. **Command Line Tool**: `$ROLLBACK_COMMAND_PATH` (default: `proxmox-setup-rollback`)
3. **Script Argument**: `./setup-system.sh --rollback`

### Rollback Process

The rollback process:
1. Restores all backed-up configuration files
2. Removes newly created files
3. Restores original service states
4. Restores tuned profiles
5. Recommends a system reboot

## Resilience Features

### Pre-flight Validation

- System compatibility checks
- Required tools verification
- Directory permissions validation
- Parameter availability testing

### Error Handling

- Graceful degradation on parameter failures
- Detailed logging of all operations
- Safe parameter validation before application
- Rollback information on failures

### Safety Measures

- No destructive operations without backup
- Validation of all sysctl parameters
- Service state preservation
- Complete audit trail in logs

## Configuration Validation

The script validates:

- System memory detection
- Sysctl parameter availability
- Directory writability
- Service availability
- ZFS module presence
- Distribution compatibility

## Log Files

- **Setup Log**: `$LOG_FILE` (from common.sh)
- **Rollback Log**: `$LOG_DIR/hetzner-proxmox-rollback.log`
- **State File**: `$SETUP_STATE_FILE`

## Environment Override Examples

Create a custom configuration file:

```bash
# custom-paths.env
export SETUP_BASE_DIR="/opt/custom-setup"
export BACKUP_DIR="/backup/proxmox"
export LOG_DIR="/var/log/custom"
export ROLLBACK_COMMAND_PATH="/usr/local/bin/custom-rollback"
```

Then source it before running:

```bash
source custom-paths.env
./scripts/setup-system.sh
```

This approach ensures the script is portable across different environments while maintaining security and reliability.

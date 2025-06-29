# Drive Preparation and RAID Configuration

This document describes the intelligent drive preparation functionality for the Hetzner Proxmox setup script.

## Overview

The `--preparedrives` command performs intelligent drive scanning and analysis to suggest the optimal RAID configuration based on the drives actually detected in your system. It automatically adapts to any hardware configuration without requiring manual drive specification or assumptions about drive sizes.

**Key Principle: Scan First, Then Configure**
The script never assumes what drives you have. Instead, it:
1. Scans your system to discover all available drives
2. Analyzes their sizes and capabilities
3. Groups them intelligently
4. Suggests the best RAID configuration for YOUR specific hardware
5. Shows you exactly what it found and why it's recommending specific configurations

## Key Features

- 🔍 **Automatic Drive Scanning**: Detects all available drives and analyzes their specifications
- 🎯 **Intelligent Recommendations**: Suggests optimal RAID configurations based on detected hardware
- 📊 **Real-time Analysis**: Shows capacity, redundancy, and performance implications for your specific drives
- 🛡️ **Safety First**: Always run `--dry-run` to preview changes before applying
- ⚙️ **Universal Compatibility**: Works with any drive sizes, brands, and combinations

## Usage

```bash
# STEP 1: Always start by scanning your system to see what drives you have
sudo ./install.sh --preparedrives

# STEP 2: Review the detected drives and recommendations
# The script will show you:
# - All drives found in your system
# - How they're grouped by size
# - Recommended RAID configurations based on YOUR hardware
# - Capacity and performance implications

# STEP 3: Preview the recommended configuration
sudo ./install.sh --preparedrives --config <recommended-from-scan> --dry-run

# STEP 4: Apply the configuration that works for your setup
sudo ./install.sh --preparedrives --config <recommended-from-scan>

# STEP 5: Force application without confirmation (if needed)
sudo ./install.sh --preparedrives --config <recommended-from-scan> --force
```

## How It Works

1. **Drive Detection**: Scans all available drives and automatically determines their sizes
2. **Intelligent Grouping**: Groups drives by size with reasonable tolerance for minor differences
3. **Configuration Analysis**: Evaluates all possible RAID configurations for detected drive groups
4. **Smart Recommendation**: Suggests the optimal configuration based on:
   - Actual drive count and sizes found on your system
   - Redundancy requirements
   - Performance characteristics
   - Capacity efficiency
5. **Preview & Apply**: Shows detailed preview before making any changes

## Example Scenarios

### Scenario 1: 4 Identical Drives
**Detected**: 4x drives of the same size
**Recommendation**: `raid10-<size>` (RAID 10)
- **Why**: Excellent performance and redundancy
- **Capacity**: ~50% usable capacity
- **Alternative**: `raid6-<size>` for better space efficiency

### Scenario 2: 2 Large + 2 Small Drives  
**Detected**: Two groups of different sized drives
**Recommendation**: `dual-raid1` (Dual RAID 1)
- **Why**: Optimal use of different drive sizes
- **Capacity**: Separate optimized arrays
- **Performance**: Dedicated arrays for different workloads

### Scenario 3: 3 Identical Drives
**Detected**: 3x drives of the same size
**Recommendation**: `raid5-<size>` (RAID 5)
- **Why**: Good redundancy with efficient capacity use
- **Capacity**: ~67% usable capacity
- **Alternative**: `raid1-<size>` using 2 drives (1 spare)

### Scenario 4: 6 Mixed Drives
**Detected**: Multiple groups of different sized drives
**Recommendation**: `mixed-optimal`
- **Configuration**: 
  - Largest group → RAID 1 or RAID 5/6 (depending on count)
  - Medium group → RAID 1 (if 2+ drives)
  - Small group → Individual or RAID 1 (if 2+ drives)
- **Why**: Maximizes redundancy across all drive groups

### Scenario 5: Single Large Drive
**Detected**: Only one drive available
**Recommendation**: `no-raid`
- **Why**: No redundancy possible with single drive
- **Note**: Consider adding identical drives for redundancy

## Available RAID Levels

The script automatically determines which RAID levels are possible based on your drives:

| RAID Level | Min Drives | Redundancy | Capacity | Performance | Use Case |
|------------|------------|------------|----------|-------------|----------|
| RAID 1     | 2          | 1 drive    | 50%      | Good read   | Small setups, boot drives |
| RAID 5     | 3          | 1 drive    | 67-90%   | Good        | Balanced redundancy/capacity |
| RAID 6     | 4          | 2 drives   | 50-80%   | Moderate    | High redundancy needs |
| RAID 10    | 4 (even)   | 50% drives | 50%      | Excellent   | Performance critical |
| ZFS Mirror | 2          | 50% drives | 50%      | Good        | Advanced features needed |

## Configuration Types

### Single-Group Configurations
When all drives are the same size:
- `raid1-<size>`: RAID 1 with drives of specified size
- `raid5-<size>`: RAID 5 with drives of specified size  
- `raid6-<size>`: RAID 6 with drives of specified size
- `raid10-<size>`: RAID 10 with drives of specified size
- `zfs-<size>`: ZFS mirror with drives of specified size

### Multi-Group Configurations
When you have different drive sizes:
- `dual-raid1`: Optimal for 2 different drive sizes
- `mixed-optimal`: Best configuration for 3+ different sizes

### Special Configurations
- `no-raid`: Individual drives without redundancy
- `individual-<size>`: Specific drive size as individual drives

## Safety Features

- **Dry-run mode**: Always preview before applying
- **Intelligent analysis**: Warns about suboptimal configurations
- **Confirmation prompts**: Prevents accidental data loss
- **Drive validation**: Ensures drives are suitable for chosen RAID level
- **Capacity calculations**: Shows exactly what you'll get

## Best Practices

1. **Always start by scanning**: Run `--preparedrives` first to see what drives your system actually has
2. **Follow system-specific recommendations**: The script analyzes YOUR hardware, not generic scenarios
3. **Use dry-run mode**: Always preview with `--dry-run` before applying any configuration
4. **Consider your use case**: 
   - Performance critical: Choose RAID 10 (if 4+ drives detected)
   - Capacity critical: Choose RAID 5/6 (if 3+ drives detected)
   - Mixed workloads: Use dual-RAID setups (if multiple drive sizes detected)
5. **Trust the scanner**: The script knows your hardware better than guesswork
6. **Plan for growth**: Leave some drives as spares if the scanner detects extras
7. **Backup first**: Always backup critical data before any RAID changes

## Examples

```bash
# STEP 1: Scan your actual system to discover available drives
sudo ./install.sh --preparedrives

# Example output for a system with 4x identical drives:
# 🔍 Drive Scan Results:
#   Found 4 drives: /dev/sdb (1.8TB), /dev/sdc (1.8TB), /dev/sdd (1.8TB), /dev/sde (1.8TB)
#   
# 🎯 RAID Configuration Recommendations:
#   ⭐ RECOMMENDED - RAID 10 with 4x 1.8TB drives
#   Alternative - RAID 6 with 4x 1.8TB drives (better space efficiency)  
#   Alternative - RAID 5 using 3x 1.8TB drives (1 spare)
# 
# 💡 Best Configuration: raid10-1.8TB
# 📝 Reason: RAID 10 optimal: 4 identical drives provide excellent performance and redundancy

# STEP 2: Preview the system-recommended configuration
sudo ./install.sh --preparedrives --config raid10-1.8TB --dry-run

# STEP 3: Apply the configuration based on your scanned hardware
sudo ./install.sh --preparedrives --config raid10-1.8TB
```

## Integration with Hetzner installimage

1. **Boot into rescue system**
2. **Run installimage with single drive or no RAID** (let the script handle RAID later)
3. **After OS installation, scan your system and configure drives optimally**:
   ```bash
   # IMPORTANT: Always scan first to see what drives your system actually has
   sudo ./install.sh --preparedrives
   
   # The script will discover your drives and show intelligent recommendations
   # Example output might show:
   # 🔍 Found drives: 2x 4TB drives, 2x 1TB drives  
   # 🎯 Recommendation: dual-raid1 (optimal for mixed drive sizes)
   
   # Follow the specific recommendations for YOUR detected hardware
   sudo ./install.sh --preparedrives --config <system-detected-recommendation> --dry-run
   sudo ./install.sh --preparedrives --config <system-detected-recommendation>
   ```

## Post-Configuration

1. **Monitor RAID sync**: `watch cat /proc/mdstat`
2. **Verify configuration**: `lsblk` and check mount points
3. **Reboot to test**: Ensure everything mounts correctly  
4. **Configure Proxmox storage**: Add new storage pools
5. **Continue setup**: Run network and other configuration steps

The script intelligently scans your actual hardware configuration, discovers whatever drives you have (regardless of size or brand), and adapts to provide optimal recommendations based on what it finds in your specific system!

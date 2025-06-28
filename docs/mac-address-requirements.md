# MAC Address Requirements for Hetzner Proxmox Setup

## Critical Information

**MAC addresses are MANDATORY for Hetzner additional IPs!** This setup will NOT work without proper MAC address configuration.

## Why MAC Addresses are Required

Hetzner's network infrastructure uses MAC addresses to route traffic to the correct additional IPs. When you create VMs or containers that use additional IPs, they must use the specific MAC addresses assigned by Hetzner, otherwise:

- Traffic to additional IPs will be dropped
- VMs/containers cannot reach the internet via additional IPs
- pfSense WAN interface will not work
- Firewall admin container cannot access the internet

## Getting MAC Addresses from Hetzner

### Hetzner Cloud
1. Login to https://console.hetzner.cloud/
2. Select your project and server
3. Go to "Networking" tab
4. Additional IPs section will show associated MAC addresses

### Hetzner Robot (Dedicated Servers)
1. Login to https://robot.hetzner.com/
2. Select your server
3. Go to "IPs" tab
4. Each additional IP will show its MAC address

### No MAC Address Shown?
If MAC addresses are not visible in your control panel:
1. Contact Hetzner support
2. Request MAC addresses for your additional IPs
3. Explain you need them for VM/container setup

## Configuration Methods

### Method 1: Config File (Recommended)
Create `config/additional-ips.conf`:
```
# IMPORTANT: Use your actual MAC addresses from Hetzner!
IP=203.0.113.10 MAC=00:50:56:00:01:02 GATEWAY=203.0.113.1 NETMASK=255.255.255.192
IP=203.0.113.11 MAC=00:50:56:00:01:03 GATEWAY=203.0.113.1 NETMASK=255.255.255.192
IP=203.0.113.12 MAC=00:50:56:00:01:04 GATEWAY=203.0.113.1 NETMASK=255.255.255.192
```

### Method 2: Environment Variables
Set in `.env` file:
```
ADDITIONAL_IP_1=203.0.113.10
ADDITIONAL_MAC_1=00:50:56:00:01:02
ADDITIONAL_GATEWAY_1=203.0.113.1
ADDITIONAL_NETMASK_1=255.255.255.192

ADDITIONAL_IP_2=203.0.113.11
ADDITIONAL_MAC_2=00:50:56:00:01:03
ADDITIONAL_GATEWAY_2=203.0.113.1
ADDITIONAL_NETMASK_2=255.255.255.192
```

### Method 3: Legacy Format
Set in `.env` file:
```
ADDITIONAL_IPS=203.0.113.10:00:50:56:00:01:02:203.0.113.1:255.255.255.192,203.0.113.11:00:50:56:00:01:03:203.0.113.1:255.255.255.192
```

## Verification Process

**ALWAYS run this before proceeding:**
```bash
./install.sh --check-mac
```

This script will:
- Verify MAC addresses are configured
- Check MAC address format (XX:XX:XX:XX:XX:XX)
- Validate that VMs/containers use correct MAC addresses
- Provide detailed error messages if issues are found

## Setup Process with MAC Address Verification

1. **Get MAC addresses from Hetzner** (see above)
2. **Configure additional IPs** with MAC addresses
3. **Verify configuration**:
   ```bash
   ./install.sh --check-mac
   ```
4. **Proceed with setup** (only if MAC check passes):
   ```bash
   ./install.sh --network
   ./install.sh --pfsense  
   ./install.sh --firewalladmin
   ./install.sh --caddy
   ```

## What Gets MAC Addresses

The setup automatically assigns MAC addresses to:

- **pfSense VM WAN interface**: Uses MAC address from first additional IP
- **Firewall Admin Container WAN interface**: Uses MAC address from second additional IP

Internal interfaces (LAN, DMZ) use auto-generated MAC addresses since they don't route through Hetzner's network.

## Troubleshooting

### "No MAC address specified" Warning
```
WARN: No MAC address specified for WAN interface - using auto-generated
WARN: This may cause routing issues with Hetzner additional IPs
```

**Solution**: Configure MAC addresses as described above and recreate VMs/containers.

### "MAC address issues found" Error
Run `./install.sh --check-mac` for detailed error information and follow the provided guidance.

### VMs/Containers Can't Access Internet
1. Check that MAC addresses are configured: `./install.sh --check-mac`
2. Verify VM/container network configuration: `qm config <vmid>` or `pct config <ctid>`
3. Check that interface shows correct MAC address
4. Recreate VM/container if MAC address is wrong

## Manual Proxmox Configuration

If you need to manually configure MAC addresses in Proxmox:

### For VMs:
```bash
# Set MAC address for VM network interface
qm set <vmid> --net0 virtio,bridge=vmbr0,macaddr=00:50:56:00:6E:D9
```

### For Containers:
```bash
# Set MAC address for container network interface  
pct set <ctid> --net0 name=eth0,bridge=vmbr0,hwaddr=00:50:56:00:6E:D9,ip=<ip>/<cidr>,gw=<gateway>
```

## Summary

- **MAC addresses are mandatory** for Hetzner additional IPs
- **Get them from Hetzner** control panel or support
- **Configure before setup** using one of the methods above
- **Always verify** with `./install.sh --check-mac`
- **Don't proceed** with setup until MAC check passes

This ensures your Proxmox setup will work correctly with Hetzner's network infrastructure.

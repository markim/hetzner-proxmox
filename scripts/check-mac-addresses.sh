#!/bin/bash

# MAC Address Verification Script for Hetzner Proxmox Setup
# This script helps verify that MAC addresses are properly configured for additional IPs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source common functions
source "$SCRIPT_DIR/lib/common.sh"

# Load environment
load_env "$SCRIPT_DIR/.env"

# Check if MAC addresses are configured
check_mac_configuration() {
    log "INFO" "Checking MAC address configuration for additional IPs..."
    
    # Parse additional IPs
    if [[ -f "$SCRIPT_DIR/scripts/configure-network.sh" ]]; then
        source "$SCRIPT_DIR/scripts/configure-network.sh" >/dev/null 2>&1 || true
        if command -v parse_additional_ips >/dev/null 2>&1; then
            parse_additional_ips 2>/dev/null || true
        fi
    fi
    
    local has_issues=false
    
    echo
    echo "=== MAC Address Configuration Check ==="
    echo
    
    if [[ -n "${ADDITIONAL_IPS_ARRAY[*]:-}" && ${#ADDITIONAL_IPS_ARRAY[@]} -gt 0 ]]; then
        echo "Found ${#ADDITIONAL_IPS_ARRAY[@]} additional IP(s) configured:"
        echo
        
        for i in "${!ADDITIONAL_IPS_ARRAY[@]}"; do
            local ip="${ADDITIONAL_IPS_ARRAY[$i]}"
            local mac="${ADDITIONAL_MACS_ARRAY[$i]:-}"
            local gateway="${ADDITIONAL_GATEWAYS_ARRAY[$i]:-}"
            local netmask="${ADDITIONAL_NETMASKS_ARRAY[$i]:-}"
            
            printf "IP %d: %s\n" $((i+1)) "$ip"
            
            if [[ -n "$mac" ]]; then
                if is_valid_mac "$mac"; then
                    printf "${GREEN}✓ MAC: %s${NC}\n" "$mac"
                else
                    printf "${RED}✗ MAC: %s (INVALID FORMAT)${NC}\n" "$mac"
                    has_issues=true
                fi
            else
                printf "%s✗ MAC: NOT CONFIGURED%s\n" "$RED" "$NC"
                has_issues=true
            fi
            
            printf "  Gateway: %s\n" "${gateway:-N/A}"
            printf "  Netmask: %s\n" "${netmask:-N/A}"
            echo
        done
    else
        echo "${RED}✗ No additional IPs configured${NC}"
        echo
        echo "Please configure additional IPs in one of these ways:"
        echo "1. Create config/additional-ips.conf"
        echo "2. Set ADDITIONAL_IP_1, ADDITIONAL_MAC_1, etc. in .env"
        return 1
    fi
    
    if [[ "$has_issues" == "true" ]]; then
        echo "${RED}⚠️  MAC ADDRESS ISSUES DETECTED${NC}"
        echo
        echo "This setup will NOT work properly with Hetzner additional IPs!"
        echo "Hetzner requires specific MAC addresses for each additional IP."
        echo
        show_mac_help
        return 1
    else
        echo "${GREEN}✓ All MAC addresses are properly configured${NC}"
        echo
        return 0
    fi
}

# Validate MAC address format
is_valid_mac() {
    local mac="$1"
    [[ "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]
}

# Show help for finding MAC addresses
show_mac_help() {
    cat << 'EOF'
HOW TO GET MAC ADDRESSES FROM HETZNER:

1. HETZNER CLOUD:
   - Login to https://console.hetzner.cloud/
   - Select your project and server
   - Go to "Networking" tab
   - Additional IPs section will show MAC addresses

2. HETZNER ROBOT (Dedicated Servers):
   - Login to https://robot.hetzner.com/
   - Select your server
   - Go to "IPs" tab
   - Each additional IP will show associated MAC address

3. CONTACT SUPPORT:
   If MAC addresses are not visible:
   - Open support ticket with Hetzner
   - Request MAC addresses for your additional IPs
   - Mention you need them for VM/container setup

CONFIGURATION FORMATS:

Method 1 - Config file (config/additional-ips.conf):
IP=203.0.113.10 MAC=00:50:56:00:01:02 GATEWAY=203.0.113.1 NETMASK=255.255.255.192
IP=203.0.113.11 MAC=00:50:56:00:01:03 GATEWAY=203.0.113.1 NETMASK=255.255.255.192

Method 2 - Environment variables (.env):
ADDITIONAL_IP_1=203.0.113.10
ADDITIONAL_MAC_1=00:50:56:00:01:02
ADDITIONAL_GATEWAY_1=203.0.113.1
ADDITIONAL_NETMASK_1=255.255.255.192

ADDITIONAL_IP_2=203.0.113.11
ADDITIONAL_MAC_2=00:50:56:00:01:03
ADDITIONAL_GATEWAY_2=203.0.113.1
ADDITIONAL_NETMASK_2=255.255.255.192

EOF
}

# Check if VMs/containers are using correct MAC addresses
check_vm_mac_addresses() {
    log "INFO" "Checking VM/container MAC address assignments..."
    
    echo
    echo "=== Proxmox VM/Container MAC Check ==="
    echo
    
    # Check pfSense VM
    local pfsense_vm_id="${PFSENSE_VM_ID:-100}"
    if qm status "$pfsense_vm_id" >/dev/null 2>&1; then
        echo "pfSense VM (ID: $pfsense_vm_id):"
        local vm_config
        vm_config=$(qm config "$pfsense_vm_id" 2>/dev/null || echo "")
        
        if [[ -n "$vm_config" ]]; then
            # Check WAN interface (net0)
            local net0_config
            net0_config=$(echo "$vm_config" | grep "^net0:" || echo "")
            if [[ -n "$net0_config" ]]; then
                local vm_mac
                vm_mac=$(echo "$net0_config" | grep -o 'macaddr=[^,]*' | cut -d= -f2 || echo "")
                if [[ -n "$vm_mac" ]]; then
                    printf "  WAN interface MAC: %s" "$vm_mac"
                    if [[ -n "${ADDITIONAL_MACS_ARRAY[0]:-}" ]] && [[ "$vm_mac" == "${ADDITIONAL_MACS_ARRAY[0]}" ]]; then
                        printf " %s✓ MATCHES%s\n" "$GREEN" "$NC"
                    else
                        printf " %s✗ MISMATCH%s\n" "$RED" "$NC"
                        if [[ -n "${ADDITIONAL_MACS_ARRAY[0]:-}" ]]; then
                            printf "    Expected: %s\n" "${ADDITIONAL_MACS_ARRAY[0]}"
                        fi
                    fi
                else
                    printf "  WAN interface MAC: %sauto-generated%s\n" "$YELLOW" "$NC"
                fi
            fi
        fi
        echo
    else
        echo "pfSense VM (ID: $pfsense_vm_id): Not found"
        echo
    fi
    
    # Check firewall admin VM
    local vm_id="${FIREWALL_ADMIN_VM_ID:-200}"
    if qm status "$vm_id" >/dev/null 2>&1; then
        echo "Firewall Admin VM (ID: $vm_id):"
        local vm_config
        vm_config=$(qm config "$vm_id" 2>/dev/null || echo "")
        
        if [[ -n "$vm_config" ]]; then
            # Check WAN interface (net1)
            local net1_config
            net1_config=$(echo "$vm_config" | grep "^net1:" || echo "")
            if [[ -n "$net1_config" ]]; then
                local vm_mac
                vm_mac=$(echo "$net1_config" | grep -o 'macaddr=[^,]*' | cut -d= -f2 || echo "")
                if [[ -n "$vm_mac" ]]; then
                    printf "  WAN interface MAC: %s" "$vm_mac"
                    if [[ -n "${ADDITIONAL_MACS_ARRAY[1]:-}" ]] && [[ "$vm_mac" == "${ADDITIONAL_MACS_ARRAY[1]}" ]]; then
                        printf " %s✓ MATCHES%s\n" "$GREEN" "$NC"
                    else
                        printf " %s✗ MISMATCH%s\n" "$RED" "$NC"
                        if [[ -n "${ADDITIONAL_MACS_ARRAY[1]:-}" ]]; then
                            printf "    Expected: %s\n" "${ADDITIONAL_MACS_ARRAY[1]}"
                        fi
                    fi
                else
                    printf "  WAN interface MAC: %sauto-generated%s\n" "$YELLOW" "$NC"
                fi
            fi
        fi
        echo
    else
        echo "Firewall Admin VM (ID: $vm_id): Not found"
        echo
    fi
}

# Main function
main() {
    echo "Hetzner Proxmox MAC Address Verification"
    echo "========================================"
    
    local config_ok=true
    
    # Check configuration
    if ! check_mac_configuration; then
        config_ok=false
    fi
    
    # Check VM/container assignments if VMs exist
    if command -v qm >/dev/null 2>&1; then
        check_vm_mac_addresses || true  # Don't fail if VMs don't exist yet
    fi
    
    echo
    echo "=== SUMMARY ==="
    
    if [[ "$config_ok" == "true" ]]; then
        echo "${GREEN}✓ Configuration: MAC addresses properly configured${NC}"
    else
        echo "${RED}✗ Configuration: MAC address issues found${NC}"
    fi
    
    echo
    if [[ "$config_ok" == "true" ]]; then
        echo "${GREEN}Ready to proceed with Proxmox setup!${NC}"
        echo
        echo "Next steps:"
        echo "1. Run: ./install.sh --network --dry-run"
        echo "2. Run: ./install.sh --network"
        echo "3. Run: ./install.sh --pfsense"
        echo "4. Run: ./install.sh --firewalladmin"
    else
        echo "${RED}Please fix MAC address configuration before proceeding${NC}"
        echo
        echo "The setup will not work properly without correct MAC addresses!"
    fi
    
    if [[ "$config_ok" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# Help function
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Check MAC address configuration for Hetzner additional IPs.

OPTIONS:
    --help, -h          Show this help message

DESCRIPTION:
    This script verifies that MAC addresses are properly configured
    for Hetzner additional IP addresses. MAC addresses are required
    for proper routing of additional IPs in Hetzner's network.

EXAMPLES:
    $0                  # Check current configuration
    $0 --help           # Show this help

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            log "ERROR" "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

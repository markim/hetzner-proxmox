#!/bin/bash

# Debug script to test drive detection
set -uo pipefail

echo "Testing drive detection commands..."

echo "1. Testing lsblk -dn -o NAME:"
lsblk -dn -o NAME 2>/dev/null || echo "Failed"

echo "2. Testing grep for nvme/sd/vd:"
lsblk -dn -o NAME 2>/dev/null | grep -E '^(sd|nvme|vd)' || echo "No matches found"

echo "3. Testing full drive list:"
drives_raw=$(lsblk -dn -o NAME 2>/dev/null | grep -E '^(sd|nvme|vd)' || echo "")
echo "Raw drives: '$drives_raw'"

if [[ -n "$drives_raw" ]]; then
    drives=($drives_raw)
    echo "Drive array: ${drives[@]}"
    
    echo "4. Testing drive info for each drive:"
    for drive_name in "${drives[@]}"; do
        drive="/dev/$drive_name"
        echo "  Testing $drive:"
        
        if [[ -b "$drive" ]]; then
            echo "    Block device exists: yes"
            
            size=$(lsblk -dn -o SIZE "$drive" 2>/dev/null || echo "unknown")
            echo "    Size: $size"
            
            model=$(lsblk -dn -o MODEL "$drive" 2>/dev/null || echo "unknown")
            echo "    Model: '$model'"
            
            # Test the sed command that was failing
            model_clean=$(echo "$model" | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' 2>/dev/null || echo "sed_failed")
            echo "    Model after sed: '$model_clean'"
            
            serial=$(lsblk -dn -o SERIAL "$drive" 2>/dev/null || echo "unknown")
            echo "    Serial: '$serial'"
            
            # Test printf
            printf "    Printf test: | %-10s  %-8s  %-20s  %-15s |\n" "$drive" "$size" "${model_clean:0:20}" "${serial:0:15}" || echo "    Printf failed"
        else
            echo "    Block device exists: no"
        fi
        echo
    done
fi

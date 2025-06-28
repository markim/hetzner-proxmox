#!/bin/bash

# Test script for configuration validation
# This script performs basic validation of the setup

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# Test results
TESTS_PASSED=0
TESTS_FAILED=0

# Logging function
log_test() {
    local result="$1"
    local message="$2"
    
    if [[ "$result" == "PASS" ]]; then
        echo -e "${GREEN}✅ PASS${NC}: $message"
        ((TESTS_PASSED++))
    elif [[ "$result" == "FAIL" ]]; then
        echo -e "${RED}❌ FAIL${NC}: $message"
        ((TESTS_FAILED++))
    elif [[ "$result" == "SKIP" ]]; then
        echo -e "${YELLOW}⚠️ SKIP${NC}: $message"
    fi
}

# Test if file exists and is readable
test_file_exists() {
    local file="$1"
    local description="$2"
    
    if [[ -f "$file" && -r "$file" ]]; then
        log_test "PASS" "$description exists and is readable"
    else
        log_test "FAIL" "$description is missing or not readable"
    fi
}

# Test if script is executable
test_script_executable() {
    local script="$1"
    local description="$2"
    
    if [[ -f "$script" && -x "$script" ]]; then
        log_test "PASS" "$description is executable"
    else
        log_test "FAIL" "$description is not executable"
    fi
}

# Test script syntax
test_script_syntax() {
    local script="$1"
    local description="$2"
    
    if [[ -f "$script" ]]; then
        if bash -n "$script" 2>/dev/null; then
            log_test "PASS" "$description has valid syntax"
        else
            log_test "FAIL" "$description has syntax errors"
        fi
    else
        log_test "SKIP" "$description not found"
    fi
}

# Test environment variables
test_env_file() {
    if [[ -f "$SCRIPT_DIR/../.env" ]]; then
        log_test "PASS" "Environment file exists"
        
        # Source and test required variables
        source "$SCRIPT_DIR/../.env" 2>/dev/null || {
            log_test "FAIL" "Environment file has syntax errors"
            return
        }
        
        # Test required variables
        if [[ -n "${DOMAIN:-}" ]]; then
            log_test "PASS" "DOMAIN variable is set"
        else
            log_test "FAIL" "DOMAIN variable is not set"
        fi
        
        if [[ -n "${EMAIL:-}" ]]; then
            log_test "PASS" "EMAIL variable is set"
        else
            log_test "FAIL" "EMAIL variable is not set"
        fi
        
    else
        log_test "FAIL" "Environment file (.env) not found"
    fi
}

# Test template files
test_templates() {
    test_file_exists "$SCRIPT_DIR/../config/Caddyfile.template" "Caddyfile template"
    
    # Test if template has required variables
    if [[ -f "$SCRIPT_DIR/../config/Caddyfile.template" ]]; then
        if grep -q '\${DOMAIN}' "$SCRIPT_DIR/../config/Caddyfile.template"; then
            log_test "PASS" "Caddyfile template contains DOMAIN variable"
        else
            log_test "FAIL" "Caddyfile template missing DOMAIN variable"
        fi
    fi
}

# Test dependencies
test_dependencies() {
    local deps=("curl" "systemctl" "apt-get")
    
    for dep in "${deps[@]}"; do
        if command -v "$dep" &> /dev/null; then
            log_test "PASS" "Dependency $dep is available"
        else
            log_test "FAIL" "Dependency $dep is missing"
        fi
    done
}

# Test network connectivity
test_network() {
    if ping -c 1 8.8.8.8 &> /dev/null; then
        log_test "PASS" "Internet connectivity is working"
    else
        log_test "FAIL" "No internet connectivity"
    fi
}

# Main test function
main() {
    echo "Hetzner Proxmox Setup - Configuration Tests"
    echo "==========================================="
    echo ""
    
    # Test core files
    echo "Testing core files..."
    test_file_exists "$SCRIPT_DIR/../install.sh" "Main installation script"
    test_script_executable "$SCRIPT_DIR/../install.sh" "Main installation script"
    test_script_syntax "$SCRIPT_DIR/../install.sh" "Main installation script"
    
    test_file_exists "$SCRIPT_DIR/../lib/common.sh" "Common library"
    test_script_syntax "$SCRIPT_DIR/../lib/common.sh" "Common library"
    
    echo ""
    
    # Test individual scripts
    echo "Testing individual scripts..."
    for script in "$SCRIPT_DIR"/../scripts/*.sh; do
        if [[ -f "$script" ]]; then
            local script_name=$(basename "$script")
            test_script_executable "$script" "$script_name"
            test_script_syntax "$script" "$script_name"
        fi
    done
    
    echo ""
    
    # Test configuration
    echo "Testing configuration..."
    test_env_file
    test_templates
    
    echo ""
    
    # Test system requirements
    echo "Testing system requirements..."
    test_dependencies
    test_network
    
    echo ""
    
    # Test summary
    echo "Test Summary"
    echo "============"
    echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
    echo ""
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed! ✅${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed! ❌${NC}"
        echo "Please fix the issues before running the installation."
        exit 1
    fi
}

# Run tests
main "$@"

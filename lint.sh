#!/bin/bash

# lint.sh - Bash script linter for the hetzner-proxmox project
# This script validates all bash scripts in the project for common issues

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
TOTAL_FILES=0
PASSED_FILES=0
FAILED_FILES=0
WARNINGS=0

# Get the project root directory
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Function to print colored output
print_status() {
    local status="$1"
    local message="$2"
    case "$status" in
        "PASS")
            echo -e "${GREEN}✓ PASS${NC}: $message"
            ;;
        "FAIL")
            echo -e "${RED}✗ FAIL${NC}: $message"
            ;;
        "WARN")
            echo -e "${YELLOW}⚠ WARN${NC}: $message"
            ;;
        "INFO")
            echo -e "${BLUE}ℹ INFO${NC}: $message"
            ;;
    esac
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check shebang
check_shebang() {
    local file="$1"
    local first_line
    first_line=$(head -n1 "$file")
    
    if [[ "$first_line" =~ ^#!.*bash$ ]] || [[ "$first_line" =~ ^#!/bin/sh$ ]]; then
        return 0
    else
        print_status "WARN" "$file: Missing or incorrect shebang (found: $first_line)"
        WARNINGS=$((WARNINGS + 1))
        return 1
    fi
}

# Function to check basic syntax
check_syntax() {
    local file="$1"
    if bash -n "$file" 2>/dev/null; then
        return 0
    else
        print_status "FAIL" "$file: Syntax errors detected"
        bash -n "$file"
        return 1
    fi
}

# Function to check for common issues
check_common_issues() {
    local file="$1"
    local issues=0
    
    # Temporarily disable exit on error for grep operations
    set +e
    
    # Check for unquoted variables in simple command contexts (basic check)
    # Only flag very obvious cases to reduce false positives
    local unquoted_vars
    unquoted_vars=$(grep -n '^[[:space:]]*echo[[:space:]]\+\$[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$' "$file" 2>/dev/null)
    if [[ -n "$unquoted_vars" ]]; then
        print_status "WARN" "$file: Unquoted variables in echo commands found"
        WARNINGS=$((WARNINGS + 1))
        issues=$((issues + 1))
    fi
    
    # Check for use of == in [ ] (should use = for POSIX compliance)
    # Only check for single [ ], not [[ ]] where == is acceptable
    if grep -n '^\s*if \[ [^]]*== [^]]*\]' "$file" >/dev/null 2>&1; then
        print_status "WARN" "$file: Use of '==' in [ ] found (use '=' for POSIX compliance)"
        WARNINGS=$((WARNINGS + 1))
        issues=$((issues + 1))
    fi
    
    # Check for missing error handling in scripts that don't have set -e
    if ! grep -q 'set.*-e' "$file" 2>/dev/null && ! grep -q 'set.*-o.*errexit' "$file" 2>/dev/null; then
        print_status "WARN" "$file: No 'set -e' found (consider adding error handling)"
        WARNINGS=$((WARNINGS + 1))
        issues=$((issues + 1))
    fi
    
    # Check for hard-coded paths that might not be portable (exclude grep patterns)
    local hardcoded_paths
    hardcoded_paths=$(grep -n '/usr/local\|/opt/' "$file" | grep -v '^\s*#' | grep -v 'grep.*usr/local\|grep.*opt' 2>/dev/null)
    if [[ -n "$hardcoded_paths" ]]; then
        print_status "WARN" "$file: Hard-coded paths found (may not be portable)"
        WARNINGS=$((WARNINGS + 1))
        issues=$((issues + 1))
    fi
    
    # Re-enable exit on error
    set -e
    
    return $issues
}

# Function to run shellcheck if available
run_shellcheck() {
    local file="$1"
    if command_exists shellcheck; then
        # Run shellcheck and capture output, excluding informational SC1091 (source file not found)
        local shellcheck_output
        if shellcheck_output=$(shellcheck --exclude=SC1091 "$file" 2>&1); then
            return 0
        else
            print_status "FAIL" "$file: ShellCheck found issues"
            echo "$shellcheck_output"
            return 1
        fi
    else
        print_status "INFO" "ShellCheck not available (install with: brew install shellcheck)"
        return 0
    fi
}

# Function to check file permissions
check_permissions() {
    local file="$1"
    if [[ -x "$file" ]]; then
        return 0
    else
        print_status "WARN" "$file: Not executable (may need chmod +x)"
        WARNINGS=$((WARNINGS + 1))
        return 1
    fi
}

# Function to lint a single file
lint_file() {
    local file="$1"
    local relative_path
    # Get relative path (compatible with macOS)
    relative_path="${file#"$PROJECT_ROOT"/}"
    
    echo
    echo "=== Linting $relative_path ==="
    
    local file_passed=true
    
    # Check shebang
    if ! check_shebang "$file"; then
        file_passed=false
    fi
    
    # Check syntax
    if ! check_syntax "$file"; then
        file_passed=false
    fi
    
    # Check permissions
    if ! check_permissions "$file"; then
        # Permissions warning already printed, no need to fail the file
        true
    fi
    
    # Run shellcheck
    if ! run_shellcheck "$file"; then
        file_passed=false
    fi
    
    # Check common issues
    if ! check_common_issues "$file"; then
        # Common issues warnings already printed, no need to fail the file
        true
    fi
    
    if $file_passed; then
        print_status "PASS" "$relative_path: All checks passed"
        PASSED_FILES=$((PASSED_FILES + 1))
    else
        print_status "FAIL" "$relative_path: Some checks failed"
        FAILED_FILES=$((FAILED_FILES + 1))
    fi
    
    TOTAL_FILES=$((TOTAL_FILES + 1))
}

# Main function
main() {
    echo "Hetzner Proxmox Project - Bash Script Linter"
    echo "============================================="
    
    # Check if shellcheck is available
    if command_exists shellcheck; then
        print_status "INFO" "Using ShellCheck $(shellcheck --version | sed -n '2p' | cut -d' ' -f2)"
    else
        print_status "WARN" "ShellCheck not found. Install it for better linting: brew install shellcheck"
    fi
    
    # Find all bash scripts
    local scripts=()
    while IFS=  read -r -d $'\0' file; do
        scripts+=("$file")
    done < <(find "$PROJECT_ROOT" -name "*.sh" -type f -print0)
    
    if [[ ${#scripts[@]} -eq 0 ]]; then
        print_status "WARN" "No bash scripts found in project"
        exit 1
    fi
    
    print_status "INFO" "Found ${#scripts[@]} bash scripts to lint"
    
    # Lint each script
    for script in "${scripts[@]}"; do
        lint_file "$script"
    done
    
    # Print summary
    echo
    echo "============================="
    echo "LINTING SUMMARY"
    echo "============================="
    echo "Total files checked: $TOTAL_FILES"
    echo -e "Passed: ${GREEN}$PASSED_FILES${NC}"
    echo -e "Failed: ${RED}$FAILED_FILES${NC}"
    echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"
    
    if [[ $FAILED_FILES -gt 0 ]]; then
        echo
        print_status "FAIL" "Some scripts have issues that need to be addressed"
        exit 1
    elif [[ $WARNINGS -gt 0 ]]; then
        echo
        print_status "WARN" "All scripts passed, but there are warnings to consider"
        exit 0
    else
        echo
        print_status "PASS" "All scripts passed linting successfully!"
        exit 0
    fi
}

# Show help
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Lint all bash scripts in the hetzner-proxmox project"
    echo
    echo "OPTIONS:"
    echo "  -h, --help    Show this help message"
    echo
    echo "This script checks for:"
    echo "  - Correct shebang usage"
    echo "  - Bash syntax errors"
    echo "  - File permissions"
    echo "  - Common bash scripting issues"
    echo "  - ShellCheck violations (if installed)"
    echo
    echo "To install ShellCheck:"
    echo "  macOS: brew install shellcheck"
    echo "  Ubuntu/Debian: apt-get install shellcheck"
    echo "  Other: https://github.com/koalaman/shellcheck#installing"
    exit 0
fi

# Run main function
main "$@"

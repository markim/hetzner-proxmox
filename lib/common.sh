#!/bin/bash

# Shared library functions for Hetzner Proxmox Setup
# Source this file in other scripts: source "$(dirname "$0")/lib/common.sh"

set -euo pipefail

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Default values
readonly DEFAULT_LOG_FILE="/var/log/hetzner-proxmox-setup.log"
readonly DEFAULT_LOG_LEVEL="INFO"

# Load environment variables
load_env() {
    local env_file="${1:-.env}"
    
    if [[ -f "$env_file" ]]; then
        log "INFO" "Loading environment from $env_file"
        set -a
        # shellcheck disable=SC1090
        source "$env_file"
        set +a
    else
        log "WARN" "Environment file $env_file not found. Using defaults."
    fi
    
    # Set defaults for required variables
    export LOG_FILE="${LOG_FILE:-$DEFAULT_LOG_FILE}"
    export LOG_LEVEL="${LOG_LEVEL:-$DEFAULT_LOG_LEVEL}"
    export CADDY_CONFIG_DIR="${CADDY_CONFIG_DIR:-/etc/caddy}"
    export PROXMOX_PORT="${PROXMOX_PORT:-8006}"
    export INTERNAL_IP="${INTERNAL_IP:-127.0.0.1}"
}

# Logging function with multiple outputs
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local script_name="${SCRIPT_NAME:-$(basename "$0")}"
    
    # Color output for terminal
    case "$level" in
        "INFO")  echo -e "${GREEN}[INFO]${NC} $message" ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC} $message" ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} $message" ;;
        "DEBUG") [[ "${LOG_LEVEL:-INFO}" == "DEBUG" ]] && echo -e "${BLUE}[DEBUG]${NC} $message" ;;
    esac
    
    # Log to file
    if [[ -n "${LOG_FILE:-}" ]]; then
        mkdir -p "$(dirname "$LOG_FILE")"
        echo "[$timestamp] [$script_name] [$level] $message" >> "$LOG_FILE"
    fi
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "This script must be run as root"
        exit 1
    fi
}

# Check if required commands exist
check_dependencies() {
    local deps=("$@")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log "ERROR" "Missing required dependencies: ${missing[*]}"
        log "INFO" "Please install missing dependencies and try again"
        exit 1
    fi
}

# Validate environment variables
validate_env() {
    local required_vars=("$@")
    local missing=()
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log "ERROR" "Missing required environment variables: ${missing[*]}"
        log "INFO" "Please check your .env file and ensure all required variables are set"
        exit 1
    fi
}

# Process template file with environment variables
process_template() {
    local template_file="$1"
    local output_file="$2"
    
    if [[ ! -f "$template_file" ]]; then
        log "ERROR" "Template file not found: $template_file"
        return 1
    fi
    
    log "INFO" "Processing template: $template_file -> $output_file"
    
    # Use envsubst to replace environment variables
    if envsubst < "$template_file" > "$output_file"; then
        log "INFO" "Template processed successfully"
    else
        log "ERROR" "Failed to process template"
        return 1
    fi
}

# Backup existing file
backup_file() {
    local file="$1"
    local backup_dir="${2:-$(dirname "$file")}"
    
    if [[ -f "$file" ]]; then
        local backup_name
        backup_name="$(basename "$file").backup.$(date +%Y%m%d_%H%M%S)"
        local backup_path="$backup_dir/$backup_name"
        
        log "INFO" "Backing up $file to $backup_path"
        if cp "$file" "$backup_path"; then
            log "INFO" "Backup created successfully"
        else
            log "ERROR" "Failed to create backup"
            return 1
        fi
    fi
}

# Test if a service is active
is_service_active() {
    local service="$1"
    systemctl is-active --quiet "$service"
}

# Enable and start a service
enable_service() {
    local service="$1"
    
    log "INFO" "Enabling and starting service: $service"
    
    systemctl enable "$service" >/dev/null 2>&1
    systemctl start "$service" >/dev/null 2>&1
    
    if is_service_active "$service"; then
        log "INFO" "Service $service is running"
    else
        log "ERROR" "Failed to start service: $service"
        return 1
    fi
}

# Reload a service
reload_service() {
    local service="$1"
    
    log "INFO" "Reloading service: $service"
    
    if systemctl reload "$service" >/dev/null 2>&1; then
        log "INFO" "Service $service reloaded successfully"
    else
        log "WARN" "Failed to reload service $service, attempting restart"
        systemctl restart "$service" >/dev/null 2>&1
        
        if is_service_active "$service"; then
            log "INFO" "Service $service restarted successfully"
        else
            log "ERROR" "Failed to restart service: $service"
            return 1
        fi
    fi
}

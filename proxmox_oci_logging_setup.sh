#!/bin/bash
# =============================================================================
# Proxmox OCI Container Logging Setup
# =============================================================================
# This script configures OCI/Docker-based containers in Proxmox to forward
# stdout/stderr to the host's syslog, making logs accessible to Alloy.
#
# How it works:
# 1. Bind-mounts host's /dev/log socket into container
# 2. Creates a log-wrapper script that pipes stdout/stderr to logger
# 3. Modifies the container's entrypoint to use the wrapper
# 4. Adds LOG_TAG environment variable for identification
#
# The Proxmox host's Alloy instance will then collect logs via journald.
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Show usage
show_usage() {
    cat << 'EOF'
=============================================
   Proxmox OCI Container Logging Setup
=============================================

This script configures OCI/Docker-based containers to forward their
stdout/stderr logs to the Proxmox host's syslog (journald).

Usage:
  sudo ./proxmox_oci_logging_setup.sh [OPTIONS]

Options:
  -h, --help              Show this help message
  -c, --container ID      Container ID to configure (required unless --all)
  -a, --all               Configure all OCI/Alpine containers
  -r, --revert ID         Revert changes for a specific container
  -l, --list              List OCI containers and their logging status
  -t, --tag TAG           Custom log tag (default: ct<ID>_<hostname>)

Examples:
  # Configure a specific container
  sudo ./proxmox_oci_logging_setup.sh --container 122

  # Configure all OCI containers
  sudo ./proxmox_oci_logging_setup.sh --all

  # Configure with custom tag
  sudo ./proxmox_oci_logging_setup.sh --container 122 --tag myapp_nginx

  # List OCI containers
  sudo ./proxmox_oci_logging_setup.sh --list

  # Revert changes
  sudo ./proxmox_oci_logging_setup.sh --revert 122

After setup, logs will appear in journald with the configured tag:
  journalctl -t ct122_nginx --follow

EOF
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Check if pct command is available
check_pct() {
    if ! command -v pct &> /dev/null; then
        log_error "pct command not found. Run this on a Proxmox host."
        exit 1
    fi
}

# Check if container is OCI/Alpine (no systemd)
is_oci_container() {
    local ctid=$1
    local config="/etc/pve/lxc/${ctid}.conf"
    
    [[ ! -f "$config" ]] && return 1
    
    # Check for OCI indicators
    local ostype=$(grep -E "^ostype:" "$config" | awk '{print $2}' || echo "")
    local entrypoint=$(grep -E "^entrypoint:" "$config" || echo "")
    
    # Alpine or has custom entrypoint = OCI container
    if [[ "$ostype" == "alpine" ]] || [[ -n "$entrypoint" ]]; then
        return 0
    fi
    
    return 1
}

# Check if container already has logging configured
has_logging_configured() {
    local ctid=$1
    local config="/etc/pve/lxc/${ctid}.conf"
    
    grep -q "dev/log" "$config" 2>/dev/null && \
    grep -q "log-wrapper" "$config" 2>/dev/null
}

# Get container hostname
get_container_hostname() {
    local ctid=$1
    local config="/etc/pve/lxc/${ctid}.conf"
    
    grep -E "^hostname:" "$config" | awk '{print $2}' | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_'
}

# Get current entrypoint
get_entrypoint() {
    local ctid=$1
    local config="/etc/pve/lxc/${ctid}.conf"
    
    grep -E "^entrypoint:" "$config" | sed 's/^entrypoint: //'
}

# Try to detect original Docker entrypoint from container filesystem
detect_docker_entrypoint() {
    local ctid=$1
    
    # Start container temporarily if needed
    local was_stopped=false
    if ! pct status "$ctid" | grep -q "running"; then
        pct start "$ctid" >/dev/null 2>&1
        sleep 3
        was_stopped=true
    fi
    
    local entrypoint=""
    
    # Common Docker entrypoint locations and patterns
    if pct exec "$ctid" -- test -f /docker-entrypoint.sh 2>/dev/null; then
        # Most common for nginx, postgres, redis, etc.
        entrypoint="/docker-entrypoint.sh"
        
        # Try to detect the default CMD
        # Check for common patterns
        if pct exec "$ctid" -- test -x /usr/sbin/nginx 2>/dev/null; then
            entrypoint="/docker-entrypoint.sh nginx -g 'daemon off;'"
        elif pct exec "$ctid" -- test -x /usr/local/bin/docker-entrypoint.sh 2>/dev/null; then
            entrypoint="/usr/local/bin/docker-entrypoint.sh"
        fi
    elif pct exec "$ctid" -- test -f /entrypoint.sh 2>/dev/null; then
        entrypoint="/entrypoint.sh"
    elif pct exec "$ctid" -- test -f /usr/local/bin/entrypoint.sh 2>/dev/null; then
        entrypoint="/usr/local/bin/entrypoint.sh"
    elif pct exec "$ctid" -- test -f /init 2>/dev/null; then
        entrypoint="/init"
    fi
    
    # Stop container if we started it
    if [[ "$was_stopped" == "true" ]]; then
        pct stop "$ctid" >/dev/null 2>&1
        sleep 2
    fi
    
    echo "$entrypoint"
}

# List OCI containers
list_oci_containers() {
    log "Scanning for OCI/Alpine containers..."
    echo
    printf "%-8s %-20s %-10s %-15s %s\n" "CTID" "NAME" "STATUS" "LOGGING" "TAG"
    printf "%s\n" "--------------------------------------------------------------------------------"
    
    for config in /etc/pve/lxc/*.conf; do
        [[ ! -f "$config" ]] && continue
        
        local ctid=$(basename "$config" .conf)
        [[ ! "$ctid" =~ ^[0-9]+$ ]] && continue
        
        if is_oci_container "$ctid"; then
            local hostname=$(get_container_hostname "$ctid")
            local status=$(pct status "$ctid" 2>/dev/null | awk '{print $2}' || echo "unknown")
            local logging="❌ No"
            local tag="-"
            
            if has_logging_configured "$ctid"; then
                logging="✅ Yes"
                tag=$(grep "LOG_TAG=" "/etc/pve/lxc/${ctid}.conf" | sed 's/.*LOG_TAG=//' || echo "ct${ctid}")
            fi
            
            printf "%-8s %-20s %-10s %-15s %s\n" "$ctid" "$hostname" "$status" "$logging" "$tag"
        fi
    done
    echo
}

# Create log-wrapper script inside container
create_log_wrapper() {
    local ctid=$1
    
    log "Creating log-wrapper script in CT $ctid..."
    
    # Check if container is running
    if ! pct status "$ctid" | grep -q "running"; then
        log "Starting container $ctid temporarily..."
        pct start "$ctid"
        sleep 3
        local was_stopped=true
    fi
    
    # Create the wrapper script
    pct exec "$ctid" -- sh -c 'cat > /usr/local/bin/log-wrapper << "WRAPPER"
#!/bin/sh
# =============================================================================
# Log Wrapper - Forwards stdout/stderr to syslog
# Part of alloy-aio (https://github.com/IT-BAER/alloy-aio)
# =============================================================================
# Usage: log-wrapper <command> [args...]
# Environment: LOG_TAG - syslog tag (default: container)
# =============================================================================

TAG="${LOG_TAG:-container}"

# Use exec to replace shell, pipe output to logger
# The -s flag also prints to stderr for container console visibility
exec "$@" 2>&1 | logger -t "$TAG" -s 2>&1
WRAPPER
chmod +x /usr/local/bin/log-wrapper'

    if [[ "${was_stopped:-false}" == "true" ]]; then
        log "Stopping container $ctid..."
        pct stop "$ctid"
    fi
}

# Configure container for logging
configure_container() {
    local ctid=$1
    local custom_tag=$2
    local config="/etc/pve/lxc/${ctid}.conf"
    
    log "Configuring CT $ctid for syslog logging..."
    
    # Check if already configured
    if has_logging_configured "$ctid"; then
        log_warning "CT $ctid already has logging configured. Use --revert first to reconfigure."
        return 0
    fi
    
    # Get container info
    local hostname=$(get_container_hostname "$ctid")
    local entrypoint=$(get_entrypoint "$ctid")
    local tag="${custom_tag:-ct${ctid}_${hostname}}"
    
    if [[ -z "$entrypoint" ]]; then
        log "No entrypoint in config, attempting to detect Docker entrypoint..."
        entrypoint=$(detect_docker_entrypoint "$ctid")
        
        if [[ -z "$entrypoint" ]]; then
            log_error "CT $ctid has no entrypoint and could not auto-detect one."
            log_error "Please specify entrypoint manually in /etc/pve/lxc/${ctid}.conf"
            log_error "Example: entrypoint: /docker-entrypoint.sh nginx -g 'daemon off;'"
            return 1
        fi
        
        log "Detected entrypoint: $entrypoint"
    fi
    
    # Check if container is running
    local was_running=false
    if pct status "$ctid" | grep -q "running"; then
        was_running=true
        log "Stopping CT $ctid..."
        pct stop "$ctid"
        sleep 2
    fi
    
    # Create log wrapper inside container (need to start temporarily)
    pct start "$ctid"
    sleep 3
    create_log_wrapper "$ctid"
    pct stop "$ctid"
    sleep 2
    
    # Backup original config
    cp "$config" "${config}.backup.$(date +%Y%m%d%H%M%S)"
    
    # Add syslog socket bind-mount (if not present)
    if ! grep -q "dev/log" "$config"; then
        echo "lxc.mount.entry: /run/systemd/journal/dev-log dev/log none bind,create=file 0 0" >> "$config"
        log "Added syslog socket bind-mount"
    fi
    
    # Add LOG_TAG environment variable
    if ! grep -q "LOG_TAG=" "$config"; then
        echo "lxc.environment.runtime: LOG_TAG=${tag}" >> "$config"
        log "Added LOG_TAG=${tag}"
    fi
    
    # Store original entrypoint as comment for revert (use pipe delimiter to avoid colon issues)
    if ! grep -q "# Original-entrypoint|" "$config"; then
        echo "# Original-entrypoint|${entrypoint}" >> "$config"
    fi
    
    # Modify entrypoint to use wrapper
    if grep -q "^entrypoint:" "$config"; then
        # Update existing entrypoint
        sed -i "s|^entrypoint:.*|entrypoint: /usr/local/bin/log-wrapper ${entrypoint}|" "$config"
    else
        # Add new entrypoint line (for containers where we detected it)
        echo "entrypoint: /usr/local/bin/log-wrapper ${entrypoint}" >> "$config"
    fi
    log "Modified entrypoint to use log-wrapper"
    
    # Restart if was running
    if [[ "$was_running" == "true" ]]; then
        log "Restarting CT $ctid..."
        pct start "$ctid"
    fi
    
    log_success "CT $ctid configured! Logs will appear with tag: $tag"
    log "View logs with: journalctl -t $tag --follow"
}

# Revert container configuration
revert_container() {
    local ctid=$1
    local config="/etc/pve/lxc/${ctid}.conf"
    
    log "Reverting CT $ctid logging configuration..."
    
    if ! has_logging_configured "$ctid"; then
        log_warning "CT $ctid doesn't have logging configured."
        return 0
    fi
    
    # Check if container is running
    local was_running=false
    if pct status "$ctid" | grep -q "running"; then
        was_running=true
        log "Stopping CT $ctid..."
        pct stop "$ctid"
        sleep 2
    fi
    
    # Get original entrypoint from comment (check both old and new format)
    local original_entrypoint=""
    original_entrypoint=$(grep "# Original-entrypoint|" "$config" 2>/dev/null | sed 's/# Original-entrypoint|//') || true
    
    # Fallback to old format (with space and possibly URL-encoded colon)
    if [[ -z "$original_entrypoint" ]]; then
        original_entrypoint=$(grep "^# Original entrypoint" "$config" 2>/dev/null | sed 's/^# Original entrypoint%3A //') || true
    fi
    
    if [[ -z "$original_entrypoint" ]]; then
        log_error "Cannot find original entrypoint. Manual intervention required."
        return 1
    fi
    
    log "Found original entrypoint: $original_entrypoint"
    
    # Remove log-wrapper from entrypoint
    sed -i "s|^entrypoint:.*|entrypoint: ${original_entrypoint}|" "$config"
    
    # Remove our additions (both old and new comment format)
    sed -i '/^# Original.entrypoint/d' "$config"
    sed -i '/LOG_TAG=/d' "$config"
    sed -i '/dev\/log.*bind/d' "$config"
    
    log "Removed logging configuration"
    
    # Restart if was running
    if [[ "$was_running" == "true" ]]; then
        log "Restarting CT $ctid..."
        pct start "$ctid"
    fi
    
    log_success "CT $ctid reverted to original configuration"
}

# Main
main() {
    local container_id=""
    local all_containers=false
    local revert_id=""
    local list_only=false
    local custom_tag=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -c|--container)
                container_id="$2"
                shift 2
                ;;
            -a|--all)
                all_containers=true
                shift
                ;;
            -r|--revert)
                revert_id="$2"
                shift 2
                ;;
            -l|--list)
                list_only=true
                shift
                ;;
            -t|--tag)
                custom_tag="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    check_root
    check_pct
    
    echo "============================================="
    echo "   Proxmox OCI Container Logging Setup"
    echo "============================================="
    echo
    
    # List mode
    if [[ "$list_only" == "true" ]]; then
        list_oci_containers
        exit 0
    fi
    
    # Revert mode
    if [[ -n "$revert_id" ]]; then
        revert_container "$revert_id"
        exit 0
    fi
    
    # Configure all OCI containers
    if [[ "$all_containers" == "true" ]]; then
        local count=0
        for config in /etc/pve/lxc/*.conf; do
            [[ ! -f "$config" ]] && continue
            local ctid=$(basename "$config" .conf)
            [[ ! "$ctid" =~ ^[0-9]+$ ]] && continue
            
            if is_oci_container "$ctid"; then
                configure_container "$ctid" ""
                ((count++)) || true
            fi
        done
        
        if [[ $count -eq 0 ]]; then
            log_warning "No OCI containers found"
        else
            log_success "Configured $count OCI container(s)"
        fi
        exit 0
    fi
    
    # Configure specific container
    if [[ -n "$container_id" ]]; then
        if ! is_oci_container "$container_id"; then
            log_warning "CT $container_id doesn't appear to be an OCI container."
            read -p "Configure anyway? [y/N] " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 0
            fi
        fi
        configure_container "$container_id" "$custom_tag"
        exit 0
    fi
    
    # No action specified
    show_usage
    exit 1
}

main "$@"

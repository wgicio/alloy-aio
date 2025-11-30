#!/bin/bash
# =============================================================================
# Proxmox Container Deployment Script for Grafana Alloy
# =============================================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Minimal logging for user-facing output
log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}
log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}
log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}
log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Show usage information
show_usage() {
    echo "============================================="
    echo "        Proxmox Container Deployment"
    echo "============================================="
    echo
    echo "This script simplifies the deployment of Grafana Alloy to all running Proxmox containers."
    echo
    echo "Usage:"
    echo "  $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -h, --help                    Show this help message"
    echo "  -l, --loki-url URL           Loki endpoint URL (required)"
    echo "  -c, --container ID           Specific container ID to deploy to (optional, deploys to all running if not specified)"
    echo "  --setup-oci                   Setup OCI/Alpine container logging (requires proxmox_oci_logging_setup.sh)"
    echo
    echo "Supported Containers:"
    echo "  - Debian, Ubuntu, Kali Linux (apt/systemd)"
    echo "  - RHEL, Fedora, CentOS, Rocky, Alma, Oracle Linux (dnf/yum/systemd)"
    echo "  - openSUSE, SLES (zypper/systemd)"
    echo
    echo "OCI/Docker Container Logging:"
    echo "  For OCI containers (Docker images), logs are collected via host journald."
    echo "  Use --setup-oci to automatically configure OCI containers for logging."
    echo "  The host running Alloy will collect these logs from journald."
    echo
    echo "Unsupported Containers (auto-skipped):"
    echo "  - Alpine Linux (uses OpenRC, not systemd) - Use --setup-oci for logging"
    echo "  - Docker/OCI application containers (no init system) - Use --setup-oci for logging"
    echo "  - Any container without systemd"
    echo
    echo "Examples:"
    echo "  # Deploy to all running containers:"
    echo "  sudo $0 --loki-url 'https://loki.example.com/loki/api/v1/push'"
    echo
    echo "  # Deploy to a specific container:"
    echo "  sudo $0 --loki-url 'https://loki.example.com/loki/api/v1/push' --container 100"
    echo
    echo "  # Deploy + setup OCI logging for incompatible containers:"
    echo "  sudo $0 --loki-url 'https://loki.example.com/loki/api/v1/push' --setup-oci"
    echo
}

# Parse command line arguments
LOKI_URL=""
CONTAINER_ID=""
SETUP_OCI=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -l|--loki-url)
                LOKI_URL="$2"
                shift 2
                ;;
            -c|--container)
                CONTAINER_ID="$2"
                shift 2
                ;;
            --setup-oci)
                SETUP_OCI=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Check if LOKI_URL is provided
    if [[ -z "$LOKI_URL" ]]; then
        log_error "Loki URL is required. Use --loki-url to specify it."
        show_usage
        exit 1
    fi
}

# Check if running with appropriate privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Check if pct command is available
check_pct() {
    if ! command -v pct &> /dev/null; then
        log_error "pct command not found. This script must be run on a Proxmox host."
        exit 1
    fi
}

# Check if container is compatible (has systemd)
# Also tracks skipped OCI containers for potential logging setup
OCI_CONTAINERS=()

check_container_compatibility() {
    local container=$1
    
    # Get OS type from container config
    local ostype
    ostype=$(pct config "$container" | grep -E "^ostype:" | awk '{print $2}' || echo "unknown")
    
    # Check for Alpine Linux (common in OCI/Docker images)
    if [[ "$ostype" == "alpine" ]]; then
        log_warning "CT $container is Alpine Linux (uses OpenRC, not systemd)"
        log_warning "  → Alpine requires different setup. Skipping..."
        OCI_CONTAINERS+=("$container")
        return 1
    fi
    
    # For OCI containers or unknown OS, check for systemd inside the container
    if [[ "$ostype" == "unmanaged" || "$ostype" == "unknown" ]]; then
        log "CT $container has ostype '$ostype', checking for systemd..."
        
        # Check if systemd is available
        if ! pct exec "$container" -- test -d /run/systemd/system 2>/dev/null; then
            # Double-check with init system detection
            local init_system
            init_system=$(pct exec "$container" -- cat /proc/1/comm 2>/dev/null || echo "unknown")
            
            if [[ "$init_system" != "systemd" ]]; then
                log_warning "CT $container uses '$init_system' init (not systemd)"
                log_warning "  → Alloy requires systemd. Skipping..."
                OCI_CONTAINERS+=("$container")
                return 1
            fi
        fi
    fi
    
    # Check for Alpine even if ostype doesn't say so (OCI images)
    if pct exec "$container" -- test -f /etc/alpine-release 2>/dev/null; then
        log_warning "CT $container is Alpine Linux (detected via /etc/alpine-release)"
        log_warning "  → Alpine uses OpenRC, not systemd. Skipping..."
        OCI_CONTAINERS+=("$container")
        return 1
    fi
    
    return 0
}

# Setup OCI logging for incompatible containers
setup_oci_logging() {
    local container=$1
    local script_dir
    
    # Find the OCI logging setup script
    if [[ -f "$0" ]]; then
        script_dir="$(dirname "$0")"
    else
        script_dir="."
    fi
    
    local oci_script="$script_dir/proxmox_oci_logging_setup.sh"
    
    if [[ ! -f "$oci_script" ]]; then
        log_error "OCI logging setup script not found: $oci_script"
        return 1
    fi
    
    log "Setting up OCI logging for CT $container..."
    
    if bash "$oci_script" --container "$container"; then
        log_success "OCI logging configured for CT $container"
        return 0
    else
        log_error "Failed to setup OCI logging for CT $container"
        return 1
    fi
}

# Deploy to a specific container
deploy_to_container() {
    local container=$1
    
    log "Processing CT $container..."
    
    # Check if container is running
    if ! pct status $container | grep -q "running"; then
        log_warning "Container $container is not running, skipping..."
        return 0  # Not a failure, just skipped
    fi
    
    # Check container compatibility (systemd requirement)
    if ! check_container_compatibility "$container"; then
        return 2  # Return 2 for "skipped due to incompatibility"
    fi
    
    # Clean up any existing directory in the container
    pct exec $container -- rm -rf /root/alloy-aio 2>/dev/null || true
    
    # Create the directory and copy the files
    pct exec $container -- mkdir -p /root/alloy-aio
    
    # Copy each file individually to avoid directory issues
    # Handle case when script is executed via curl (dirname "$0" would fail)
    if [[ -f "$0" ]]; then
        cd "$(dirname "$0")/alloy-aio"
    else
        # Fallback to current directory if script is executed via curl
        cd "alloy-aio"
    fi
    
    for file in *; do
        if [[ -f "$file" ]]; then
            pct push $container "$file" "/root/alloy-aio/$file" 2>/dev/null || {
                log_error "Failed to copy $file to container $container"
                cd ..
                return 1
            }
        fi
    done
    cd ..
    
    # Execute the setup script in the container with explicit URL
    if pct exec $container -- env LOKI_URL="$LOKI_URL" bash -c 'cd /root/alloy-aio && bash alloy_setup.sh --loki-url "$LOKI_URL"'; then
        log_success "Completed setup for CT $container"
    else
        log_error "Failed to setup Alloy in CT $container"
        return 1
    fi
}

# Main execution
main() {
    parse_args "$@"
    
    echo "============================================="
    echo "        Proxmox Container Deployment"
    echo "============================================="
    echo
    
    check_root
    check_pct
    
    # Check if alloy-aio directory exists
    # Handle case when script is executed via curl
    local alloy_aio_dir="alloy-aio"
    if [[ -f "$0" ]]; then
        alloy_aio_dir="$(dirname "$0")/alloy-aio"
    fi
    
    if [[ ! -d "$alloy_aio_dir" ]]; then
        log "Cloning alloy-aio repository..."
        if git clone https://github.com/IT-BAER/alloy-aio.git "$alloy_aio_dir"; then
            log_success "Repository cloned successfully"
        else
            log_error "Failed to clone repository"
            exit 1
        fi
    else
        log "Updating alloy-aio repository..."
        cd "$alloy_aio_dir"
        if git pull; then
            log_success "Repository updated successfully"
        else
            log_error "Failed to update repository"
            exit 1
        fi
        cd ..
    fi
    
    local success_count=0
    local fail_count=0
    local skipped_count=0
    local deploy_result=0
    
    if [[ -n "$CONTAINER_ID" ]]; then
        # Deploy to specific container
        deploy_result=0
        deploy_to_container "$CONTAINER_ID" || deploy_result=$?
        
        case $deploy_result in
            0) ((success_count++)) || true ;;
            2) ((skipped_count++)) || true ;;  # Incompatible container
            *) ((fail_count++)) || true ;;
        esac
    else
        # Deploy to all running containers
        log "Deploying to all running containers..."
        
        # Get list of running containers
        running_containers=$(pct list | awk 'NR>1 && $2=="running" {print $1}')
        
        if [[ -z "$running_containers" ]]; then
            log_warning "No running containers found"
            exit 0
        fi
        
        log "Found running containers: $running_containers"
        
        # Deploy to each container (continue on failure)
        for container in $running_containers; do
            deploy_result=0
            deploy_to_container "$container" || deploy_result=$?
            
            case $deploy_result in
                0) ((success_count++)) || true ;;
                2) ((skipped_count++)) || true ;;  # Incompatible container
                *) ((fail_count++)) || true ;;
            esac
        done
    fi
    
    # Summary report
    echo
    log "============================================="
    log "Deployment Summary"
    log "============================================="
    log_success "Successful: $success_count"
    [[ $fail_count -gt 0 ]] && log_error "Failed: $fail_count"
    [[ $skipped_count -gt 0 ]] && log_warning "Skipped: $skipped_count"
    
    # OCI logging setup for skipped containers
    if [[ ${#OCI_CONTAINERS[@]} -gt 0 ]]; then
        echo
        if [[ "$SETUP_OCI" == "true" ]]; then
            log "Setting up OCI logging for ${#OCI_CONTAINERS[@]} container(s)..."
            local oci_success=0
            local oci_fail=0
            
            for container in "${OCI_CONTAINERS[@]}"; do
                if setup_oci_logging "$container"; then
                    ((oci_success++)) || true
                else
                    ((oci_fail++)) || true
                fi
            done
            
            echo
            log "OCI Logging Summary:"
            log_success "  Configured: $oci_success"
            [[ $oci_fail -gt 0 ]] && log_error "  Failed: $oci_fail"
            log "  → Logs will appear in host journald with tags like 'ct<ID>_<app>'"
            log "  → Host Alloy will collect these via journald integration"
        else
            log_warning "Skipped OCI/Docker containers: ${OCI_CONTAINERS[*]}"
            log "  → To setup logging for these containers, run with --setup-oci"
            log "  → Or use: ./proxmox_oci_logging_setup.sh --container <ID>"
        fi
    fi
    
    # Exit with error if any failures occurred
    if [[ $fail_count -gt 0 ]]; then
        exit 1
    fi
}

# Run main function
main "$@"

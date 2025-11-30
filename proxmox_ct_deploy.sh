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
    echo
    echo "Examples:"
    echo "  # Deploy to all running containers:"
    echo "  sudo $0 --loki-url 'https://loki.example.com/loki/api/v1/push'"
    echo
    echo "  # Deploy to a specific container:"
    echo "  sudo $0 --loki-url 'https://loki.example.com/loki/api/v1/push' --container 100"
    echo
}

# Parse command line arguments
LOKI_URL=""
CONTAINER_ID=""

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

# Deploy to a specific container
deploy_to_container() {
    local container=$1
    
    log "Processing CT $container..."
    
    # Check if container is running
    if ! pct status $container | grep -q "running"; then
        log_warning "Container $container is not running, skipping..."
        return 0  # Not a failure, just skipped
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
    
    if [[ -n "$CONTAINER_ID" ]]; then
        # Deploy to specific container
        if deploy_to_container "$CONTAINER_ID"; then
            ((success_count++)) || true
        else
            ((fail_count++)) || true
        fi
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
            # Capture result without letting set -e exit the script
            if deploy_to_container "$container"; then
                ((success_count++)) || true
            else
                ((fail_count++)) || true
            fi
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
    
    # Exit with error if any failures occurred
    if [[ $fail_count -gt 0 ]]; then
        exit 1
    fi
}

# Run main function
main "$@"

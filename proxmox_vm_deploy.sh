#!/bin/bash
# =============================================================================
# Proxmox VM Deployment Script for Grafana Alloy
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
    echo "           Proxmox VM Deployment"
    echo "============================================="
    echo
    echo "This script simplifies the deployment of Grafana Alloy to all running Proxmox VMs."
    echo
    echo "Usage:"
    echo "  $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -h, --help                    Show this help message"
    echo "  -l, --loki-url URL           Loki endpoint URL (required)"
    echo "  -v, --vm ID                  Specific VM ID to deploy to (optional, deploys to all running if not specified)"
    echo
    echo "Examples:"
    echo "  # Deploy to all running VMs:"
    echo "  sudo $0 --loki-url 'https://loki.example.com/loki/api/v1/push'"
    echo
    echo "  # Deploy to a specific VM:"
    echo "  sudo $0 --loki-url 'https://loki.example.com/loki/api/v1/push' --vm 100"
    echo
}

# Parse command line arguments
LOKI_URL=""
VM_ID=""

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
            -v|--vm)
                VM_ID="$2"
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

# Check if qm command is available
check_qm() {
    if ! command -v qm &> /dev/null; then
        log_error "qm command not found. This script must be run on a Proxmox host."
        exit 1
    fi
}

# Deploy to a specific VM
deploy_to_vm() {
    local vmid=$1
    
    log "Processing VM $vmid..."
    
    # Check if VM is running
    if ! qm status $vmid | grep -q "running"; then
        log_warning "VM $vmid is not running, skipping..."
        return 0
    fi
    
    # Check if QEMU Guest Agent is available
    if ! qm guest cmd $vmid ping >/dev/null 2>&1; then
        log_warning "QEMU Guest Agent not available for VM $vmid, skipping..."
        return 0
    fi
    
    # Detect OS and deploy accordingly
    if qm guest exec $vmid "cmd.exe" /c ver >/dev/null 2>&1; then
        # Windows VM
        log "🪟 Windows VM detected..."
        deploy_to_windows_vm $vmid
    else
        # Linux VM
        log "🐧 Linux VM detected..."
        deploy_to_linux_vm $vmid
    fi
}

# Spinner for long-running commands
show_spinner() {
    local msg="$1"
    local pid=$2
    local spinner=("|" "/" "-" "\\")
    local delay=0.1
    local i=0
    
    tput civis 2>/dev/null || true
    while kill -0 $pid 2>/dev/null; do
        printf "\r${BLUE}[INFO]${NC} $msg %s" "${spinner[$i]}"
        i=$(( (i+1) % 4 ))
        sleep $delay
    done
    tput cnorm 2>/dev/null || true
}

# Deploy to a Windows VM
deploy_to_windows_vm() {
    local vmid=$1
    
    local deploy_cmd="Set-ExecutionPolicy Bypass -Scope Process -Force; \$ProgressPreference = 'SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Remove-Item -Path 'C:\WINDOWS\TEMP\alloy-install' -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item -Path 'C:\alloy_setup.ps1' -Force -ErrorAction SilentlyContinue; Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/IT-BAER/alloy-aio/main/alloy_setup_windows.ps1' -OutFile 'C:\alloy_setup.ps1'; & 'C:\alloy_setup.ps1' -LokiUrl '$LOKI_URL' -NonInteractive; Remove-Item -Path 'C:\alloy_setup.ps1' -Force -ErrorAction SilentlyContinue;"
    
    # Run the command in background and show spinner
    qm guest exec $vmid --timeout 120 powershell.exe "$deploy_cmd" >/dev/null 2>&1 &
    local pid=$!
    
    show_spinner "Installing Alloy on Windows VM $vmid..." $pid
    
    if wait $pid; then
        printf "\r${BLUE}[INFO]${NC} Installing Alloy on Windows VM $vmid...    \n"
        log_success "Completed setup for Windows VM $vmid"
    else
        printf "\r${BLUE}[INFO]${NC} Installing Alloy on Windows VM $vmid...    \n"
        log_error "Failed to setup Alloy in Windows VM $vmid"
        return 1
    fi
}

# Deploy to a Linux VM
deploy_to_linux_vm() {
    local vmid=$1
    
    local deploy_cmd="cd /tmp && rm -f alloy_setup.sh && wget -q https://raw.githubusercontent.com/IT-BAER/alloy-aio/main/alloy_setup.sh && chmod +x alloy_setup.sh && DEBIAN_FRONTEND=noninteractive sudo bash alloy_setup.sh --loki-url '$LOKI_URL' --non-interactive && rm -f alloy_setup.sh"
    
    # Run the command in background and show spinner
    qm guest exec $vmid --timeout 120 -- bash -c "$deploy_cmd" >/dev/null 2>&1 &
    local pid=$!
    
    show_spinner "Installing Alloy on Linux VM $vmid..." $pid
    
    if wait $pid; then
        printf "\r${BLUE}[INFO]${NC} Installing Alloy on Linux VM $vmid...    \n"
        log_success "Completed setup for Linux VM $vmid"
    else
        printf "\r${BLUE}[INFO]${NC} Installing Alloy on Linux VM $vmid...    \n"
        log_error "Failed to setup Alloy in Linux VM $vmid"
        return 1
    fi
}

# Main execution
main() {
    parse_args "$@"
    
    echo "============================================="
    echo "           Proxmox VM Deployment"
    echo "============================================="
    echo
    
    check_root
    check_qm
    
    local success_count=0
    local fail_count=0
    local skipped_count=0
    
    if [[ -n "$VM_ID" ]]; then
        # Deploy to specific VM
        if deploy_to_vm "$VM_ID"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    else
        # Deploy to all running VMs
        log "Deploying to all running VMs..."
        
        # Get list of running VMs
        running_vms=$(qm list | awk 'NR>1 && $3=="running" {print $1}')
        
        if [[ -z "$running_vms" ]]; then
            log_warning "No running VMs found"
            exit 0
        fi
        
        log "Found running VMs: $running_vms"
        
        # Deploy to each VM (continue on failure)
        for vmid in $running_vms; do
            # Capture result without letting set -e exit the script
            if deploy_to_vm "$vmid"; then
                ((success_count++))
            else
                ((fail_count++))
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

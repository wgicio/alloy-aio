#!/bin/bash
# =============================================================================
# Grafana Alloy Log Permissions Fixer
# =============================================================================
#
# This script fixes log file permissions for Grafana Alloy after new applications
# (like crowdsec-firewall-bouncer) have been installed and created new log files.
#
# Problem: When Alloy is installed, ACL permissions are set on existing files in
# /var/log. However, new log files created afterwards may not inherit these
# permissions, causing "permission denied" errors like:
#   failed to tail the file: open /var/log/crowdsec-firewall-bouncer.log: permission denied
#
# This script can be run:
#   1. Manually after installing new applications
#   2. As a systemd timer (periodic)
#   3. As a post-install hook for package managers
#
# Compatible with: Debian, Ubuntu (systems with ACL support)
# Requirements: root access, acl package installed
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Configuration
ALLOY_USER="alloy"
LOG_DIRS=("/var/log")
VERBOSE=false
DRY_RUN=false
QUIET=false
SYSTEMD_TIMER=false

# Security: Files to exclude from permission changes (contain sensitive auth data)
# These files have restricted permissions by design and should not be readable by services
EXCLUDE_FILES=(
    "btmp"           # Failed login attempts (binary)
    "wtmp"           # Login records (binary)
    "lastlog"        # Last login info (binary)
    "tallylog"       # PAM tally data
    "faillog"        # Failed login data
    "sudo.log"       # Sudo command history
    "sudoers"        # Sudo configuration
    "shadow"         # Should never be in /var/log but exclude anyway
    "gshadow"        # Should never be in /var/log but exclude anyway
)

# Show usage information
show_usage() {
    echo "============================================="
    echo "    Alloy Log Permissions Fixer"
    echo "============================================="
    echo
    echo "Fixes ACL permissions for log files created after Alloy installation."
    echo
    echo "Usage:"
    echo "  $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -h, --help              Show this help message"
    echo "  -v, --verbose           Show detailed output"
    echo "  -n, --dry-run           Show what would be done without making changes"
    echo "  -q, --quiet             Suppress non-error output (for cron/timer use)"
    echo "  -d, --dir DIR           Add additional directory to scan (can be repeated)"
    echo "  -f, --file FILE         Fix permissions for specific file only"
    echo "  --install-timer         Install systemd timer for automatic fixing"
    echo "  --remove-timer          Remove systemd timer"
    echo
    echo "Examples:"
    echo "  # Fix all log permissions:"
    echo "  sudo $0"
    echo
    echo "  # Fix specific file:"
    echo "  sudo $0 -f /var/log/crowdsec-firewall-bouncer.log"
    echo
    echo "  # Dry run to see what would be changed:"
    echo "  sudo $0 --dry-run --verbose"
    echo
    echo "  # Install automatic timer (runs hourly):"
    echo "  sudo $0 --install-timer"
    echo
}

# Check prerequisites
check_prerequisites() {
    # Check root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi

    # Check if alloy user exists
    if ! id "$ALLOY_USER" &>/dev/null; then
        log_error "Alloy user '$ALLOY_USER' does not exist"
        log_error "Please run the Alloy installation script first"
        exit 1
    fi

    # Check if setfacl is available
    if ! command -v setfacl &>/dev/null; then
        log_error "setfacl command not found"
        log_error "Install ACL package:"
        log_error "  Debian/Ubuntu: apt-get install acl"
        log_error "  RHEL/Fedora:   dnf install acl"
        log_error "  openSUSE:      zypper install acl"
        exit 1
    fi

    # Check if getfacl is available
    if ! command -v getfacl &>/dev/null; then
        log_error "getfacl command not found"
        log_error "Install ACL package:"
        log_error "  Debian/Ubuntu: apt-get install acl"
        log_error "  RHEL/Fedora:   dnf install acl"
        log_error "  openSUSE:      zypper install acl"
        exit 1
    fi
}

# Check if file should be excluded for security reasons
is_excluded_file() {
    local file="$1"
    local basename
    basename=$(basename "$file")
    
    for excluded in "${EXCLUDE_FILES[@]}"; do
        if [[ "$basename" == "$excluded" ]]; then
            return 0  # Is excluded
        fi
    done
    return 1  # Not excluded
}

# Check if file/directory needs permission fix
needs_permission_fix() {
    local path="$1"
    
    # Security check: skip excluded sensitive files
    if [[ -f "$path" ]] && is_excluded_file "$path"; then
        [[ "$VERBOSE" == true ]] && log_warning "Skipping sensitive file: $path"
        return 1  # Skip - security exclusion
    fi
    
    # Check if alloy user already has read access via ACL
    if getfacl -p "$path" 2>/dev/null | grep -q "^user:${ALLOY_USER}:r"; then
        return 1  # Already has permissions
    fi
    return 0  # Needs fix
}

# Fix permissions for a single file
fix_file_permissions() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        [[ "$VERBOSE" == true ]] && log_warning "File not found: $file"
        return 1
    fi

    if ! needs_permission_fix "$file"; then
        [[ "$VERBOSE" == true ]] && log "Already has permissions: $file"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        [[ "$QUIET" != true ]] && log "[DRY-RUN] Would fix: $file" || true
        return 0
    fi

    if setfacl -m "u:${ALLOY_USER}:r" "$file" 2>/dev/null; then
        [[ "$QUIET" != true ]] && log_success "Fixed permissions: $file" || true
        return 0
    else
        log_error "Failed to fix: $file"
        return 1
    fi
}

# Fix permissions for a directory (including default ACLs)
fix_directory_permissions() {
    local dir="$1"
    
    if [[ ! -d "$dir" ]]; then
        [[ "$VERBOSE" == true ]] && log_warning "Directory not found: $dir"
        return 1
    fi

    local fixed_count=0
    local failed_count=0

    # Fix the directory itself
    if needs_permission_fix "$dir"; then
        if [[ "$DRY_RUN" == true ]]; then
            [[ "$QUIET" != true ]] && log "[DRY-RUN] Would fix directory: $dir" || true
        else
            if setfacl -m "u:${ALLOY_USER}:rx" "$dir" 2>/dev/null; then
                [[ "$VERBOSE" == true ]] && log_success "Fixed directory: $dir"
                ((fixed_count++))
            else
                log_error "Failed to fix directory: $dir"
                ((failed_count++))
            fi
        fi
    fi

    # Set default ACL on directory (for future files)
    if [[ "$DRY_RUN" != true ]]; then
        setfacl -d -m "u:${ALLOY_USER}:rx" "$dir" 2>/dev/null || true
    fi

    # Find all files and directories that need fixing
    while IFS= read -r -d '' item; do
        if [[ -d "$item" ]]; then
            # Directory: set rx permission and default ACL
            if needs_permission_fix "$item"; then
                if [[ "$DRY_RUN" == true ]]; then
                    [[ "$VERBOSE" == true ]] && log "[DRY-RUN] Would fix subdir: $item"
                else
                    if setfacl -m "u:${ALLOY_USER}:rx" "$item" 2>/dev/null; then
                        setfacl -d -m "u:${ALLOY_USER}:rx" "$item" 2>/dev/null || true
                        [[ "$VERBOSE" == true ]] && log_success "Fixed subdir: $item"
                        ((fixed_count++))
                    else
                        [[ "$VERBOSE" == true ]] && log_error "Failed subdir: $item"
                        ((failed_count++))
                    fi
                fi
            fi
        elif [[ -f "$item" ]]; then
            # Regular file: check if it's a log file we care about
            case "$item" in
                *.log|*/syslog|*/messages|*/auth.log|*/kern.log|*/daemon.log|*/debug|*/cron.log)
                    if needs_permission_fix "$item"; then
                        if [[ "$DRY_RUN" == true ]]; then
                            [[ "$VERBOSE" == true ]] && log "[DRY-RUN] Would fix: $item"
                        else
                            if setfacl -m "u:${ALLOY_USER}:r" "$item" 2>/dev/null; then
                                [[ "$VERBOSE" == true ]] && log_success "Fixed: $item"
                                ((fixed_count++))
                            else
                                [[ "$VERBOSE" == true ]] && log_error "Failed: $item"
                                ((failed_count++))
                            fi
                        fi
                    fi
                    ;;
            esac
        fi
    done < <(find "$dir" -print0 2>/dev/null)

    [[ "$QUIET" != true ]] && log "Directory $dir: $fixed_count fixed, $failed_count failed" || true
}

# Install systemd timer for automatic permission fixing
install_systemd_timer() {
    local script_path="/usr/local/bin/alloy-fix-permissions"
    local service_path="/etc/systemd/system/alloy-fix-permissions.service"
    local timer_path="/etc/systemd/system/alloy-fix-permissions.timer"

    log "Installing systemd timer for automatic permission fixing..."

    # Copy this script to a system location
    cp "$0" "$script_path"
    chmod 755 "$script_path"
    log_success "Installed script to $script_path"

    # Create systemd service unit with security hardening
    cat > "$service_path" << 'EOF'
[Unit]
Description=Fix log file permissions for Grafana Alloy
Documentation=https://github.com/IT-BAER/alloy-aio
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/alloy-fix-permissions --quiet
User=root

# Security hardening - limit what the service can do
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=false
CapabilityBoundingSet=CAP_FOWNER CAP_DAC_OVERRIDE
# Allow write only to /var/log for ACL modifications
ReadWritePaths=/var/log
# Restrict network access (not needed for this service)
PrivateNetwork=true

[Install]
WantedBy=multi-user.target
EOF
    log_success "Created service unit: $service_path"

    # Create systemd timer unit
    cat > "$timer_path" << 'EOF'
[Unit]
Description=Periodically fix log file permissions for Grafana Alloy
Documentation=https://github.com/IT-BAER/alloy-aio

[Timer]
# Run 5 minutes after boot
OnBootSec=5min
# Run every hour
OnUnitActiveSec=1h
# Add randomized delay to prevent thundering herd
RandomizedDelaySec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    log_success "Created timer unit: $timer_path"

    # Reload systemd and enable timer
    systemctl daemon-reload
    systemctl enable --now alloy-fix-permissions.timer
    log_success "Timer enabled and started"

    log "Timer status:"
    systemctl status alloy-fix-permissions.timer --no-pager || true
}

# Remove systemd timer
remove_systemd_timer() {
    log "Removing systemd timer..."

    systemctl stop alloy-fix-permissions.timer 2>/dev/null || true
    systemctl disable alloy-fix-permissions.timer 2>/dev/null || true

    rm -f /etc/systemd/system/alloy-fix-permissions.service
    rm -f /etc/systemd/system/alloy-fix-permissions.timer
    rm -f /usr/local/bin/alloy-fix-permissions

    systemctl daemon-reload

    log_success "Timer and associated files removed"
}

# Parse command line arguments
SPECIFIC_FILE=""
EXTRA_DIRS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -q|--quiet)
            QUIET=true
            shift
            ;;
        -d|--dir)
            EXTRA_DIRS+=("$2")
            shift 2
            ;;
        -f|--file)
            SPECIFIC_FILE="$2"
            shift 2
            ;;
        --install-timer)
            SYSTEMD_TIMER="install"
            shift
            ;;
        --remove-timer)
            SYSTEMD_TIMER="remove"
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Main execution
main() {
    check_prerequisites

    # Handle timer installation/removal
    if [[ "$SYSTEMD_TIMER" == "install" ]]; then
        install_systemd_timer
        exit 0
    elif [[ "$SYSTEMD_TIMER" == "remove" ]]; then
        remove_systemd_timer
        exit 0
    fi

    [[ "$QUIET" != true ]] && log "Starting Alloy log permissions fixer..." || true
    [[ "$DRY_RUN" == true && "$QUIET" != true ]] && log_warning "DRY RUN MODE - no changes will be made" || true

    # Handle specific file
    if [[ -n "$SPECIFIC_FILE" ]]; then
        fix_file_permissions "$SPECIFIC_FILE"
        exit $?
    fi

    # Add extra directories
    LOG_DIRS+=("${EXTRA_DIRS[@]}")

    # Process all directories
    for dir in "${LOG_DIRS[@]}"; do
        if [[ -d "$dir" ]]; then
            [[ "$QUIET" != true ]] && log "Processing directory: $dir" || true
            fix_directory_permissions "$dir"
        else
            [[ "$VERBOSE" == true ]] && log_warning "Directory not found: $dir"
        fi
    done

    [[ "$QUIET" != true ]] && log_success "Permission fix complete" || true
}

main

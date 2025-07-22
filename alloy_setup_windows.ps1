# =============================================================================
# Grafana Alloy Installation Script for Windows
# =============================================================================
# 
# This PowerShell script installs and configures Grafana Alloy on Windows
# with full observability configuration (logs + metrics).
#
# Compatible with: Windows 10+, Windows Server 2019+
# Requirements: Administrator privileges, internet connection
#
# Usage: 
#   # Run as Administrator in PowerShell:
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   .\alloy_setup_windows.ps1
#   
#   # With custom endpoints:
#   .\alloy_setup_windows.ps1 -LokiUrl "https://your-loki.com/loki/api/v1/push" -PrometheusUrl "https://your-prometheus.com/api/v1/write"
# =============================================================================

param(
    [string]$LokiUrl = "",
    [string]$PrometheusUrl = "",
    [string]$ConfigUrl = "",
    [switch]$Help
)

# Define Write-LogMessage function first
function Write-LogMessage {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $prefix = switch ($Level) {
        "SUCCESS" { "[SUCCESS]" }
        "WARNING" { "[WARNING]" }
        "ERROR" { "[ERROR]" }
        default { "[INFO]" }
    }
    $color = switch ($Level) {
        "SUCCESS" { "Green" }
        "WARNING" { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host "$prefix $Message" -ForegroundColor $color
}

# Check if running as Administrator
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "This script must be run as Administrator. Please run PowerShell as Administrator and try again."
    exit 1
}

function Show-Usage {
    Write-Host "=============================================" -ForegroundColor Blue
    Write-Host "    Grafana Alloy Windows Installation" -ForegroundColor Blue
    Write-Host "=============================================" -ForegroundColor Blue
    Write-Host ""
    Write-Host "Usage:"
    Write-Host "  .\alloy_setup_windows.ps1 [OPTIONS]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Help                     Show this help message"
    Write-Host "  -LokiUrl URL             Loki endpoint URL"
    Write-Host "  -PrometheusUrl URL       Prometheus endpoint URL"
    Write-Host "  -ConfigUrl URL           Custom configuration file URL"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  # Basic installation:"
    Write-Host "  .\alloy_setup_windows.ps1"
    Write-Host ""
    Write-Host "  # With custom endpoints:"
    Write-Host "  .\alloy_setup_windows.ps1 -LokiUrl 'https://loki.example.com/loki/api/v1/push' -PrometheusUrl 'https://prometheus.example.com/api/v1/write'"
    Write-Host ""
    Write-Host "Windows Configuration includes:"
    Write-Host "  • Event Logs: Application, System, Security (WARNING+ only)"
    Write-Host "  • Metrics: CPU, Memory, Disk, Network, Services"
    Write-Host ""
}

if ($Help) {
    Show-Usage
    exit 0
}

function Test-IsVirtualMachine {
    # Check specifically for Proxmox VM
    try {
        $bios = Get-WmiObject -Class Win32_BIOS
        if ($bios.Manufacturer -match "Proxmox") {
            Write-LogMessage "Proxmox VM detected via BIOS manufacturer: $($bios.Manufacturer)" "INFO"
            return $true
        }
    } catch {
        Write-LogMessage "Failed to query BIOS information: $($_.Exception.Message)" "WARNING"
    }
    
    return $false
}

# Configuration
$IsVM = Test-IsVirtualMachine
# Override ConfigUrl if not explicitly provided and running in a VM
if (-not $ConfigUrl -and $IsVM) {
    $ConfigUrl = "https://github.com/IT-BAER/alloy-aio/raw/main/aio-windows-logs.alloy"
}
$DefaultConfigUrl = if ($IsVM) {
    "https://github.com/IT-BAER/alloy-aio/raw/main/aio-windows-logs.alloy"
} else {
    "https://github.com/IT-BAER/alloy-aio/raw/main/aio-windows.alloy"
}

# Show appropriate message based on system type
if ($IsVM) {
    Write-LogMessage "Virtual machine detected - installing logs-only configuration" "INFO"
} else {
    Write-LogMessage "Physical machine detected - installing full configuration (logs + metrics)" "INFO"
}

$InstallerUrl = "https://github.com/grafana/alloy/releases/latest/download/alloy-installer-windows-amd64.exe.zip"
$TempDir = "$env:TEMP\alloy-install"
$InstallDir = "$env:ProgramFiles\GrafanaLabs\Alloy"
$ConfigFile = if ($ConfigUrl) {
    $fn = [System.IO.Path]::GetFileName($ConfigUrl)
    if ($fn) { "$InstallDir\$fn" } else { "$InstallDir\aio-windows.alloy" }
} else {
    "$InstallDir\aio-windows.alloy"
}

# Global cleanup function that can be called from anywhere
function Clear-TempFiles {
    if (Test-Path $TempDir) {
        try {
            Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-LogMessage "Temporary files cleaned up" "SUCCESS"
        }
        catch {
            Write-LogMessage "Warning: Could not clean up temporary files at $TempDir" "WARNING"
        }
    }
}

# Set up cleanup on script exit (including Ctrl+C)
$null = Register-EngineEvent PowerShell.Exiting -Action { Clear-TempFiles }

function Install-Alloy {
    Write-LogMessage "Installing Grafana Alloy on Windows..."
    
    # Create temp directory - cleanup any existing one first
    Clear-TempFiles
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    
    # Download installer
    $zipFile = "$TempDir\alloy-installer.zip"
    Write-LogMessage "Downloading latest Alloy installer..."
    try {
        Invoke-WebRequest -Uri $InstallerUrl -OutFile $zipFile
        Write-LogMessage "Installer downloaded successfully" "SUCCESS"
    }
    catch {
        Write-LogMessage "Failed to download installer: $($_.Exception.Message)" "ERROR"
        Clear-TempFiles
        exit 1
    }
    
    # Extract installer
    Write-LogMessage "Extracting installer..."
    try {
        Expand-Archive -Path $zipFile -DestinationPath $TempDir -Force
        $installerExe = Get-ChildItem -Path $TempDir -Name "alloy-installer-windows-amd64.exe" -Recurse | Select-Object -First 1
        if (-not $installerExe) {
            throw "Installer executable not found after extraction"
        }
        $installerPath = "$TempDir\$installerExe"
        Write-LogMessage "Installer extracted successfully" "SUCCESS"
    }
    catch {
        Write-LogMessage "Failed to extract installer: $($_.Exception.Message)" "ERROR"
        Clear-TempFiles
        exit 1
    }
    
    # Run silent installation
    Write-LogMessage "Running silent installation..."
    try {
        $installArgs = "/S /CONFIG=`"$ConfigFile`" /DISABLEREPORTING=yes"
        Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -NoNewWindow
        Write-LogMessage "Alloy installed successfully with reporting disabled" "SUCCESS"
    }
    catch {
        Write-LogMessage "Failed to install Alloy: $($_.Exception.Message)" "ERROR"
        Clear-TempFiles
        exit 1
    }
    
    # Cleanup temporary files after successful installation
    Clear-TempFiles
}

function Deploy-Configuration {
    Write-LogMessage "Deploying Windows configuration..."

    # Ensure install directory exists
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    $configUrl = if ($ConfigUrl) { $ConfigUrl } else { $DefaultConfigUrl }

    Write-LogMessage "Downloading configuration from: $configUrl"

    try {
        Invoke-WebRequest -Uri $configUrl -OutFile $ConfigFile
        Write-LogMessage "Configuration downloaded successfully as $ConfigFile" "SUCCESS"
    }
    catch {
        Write-LogMessage "Failed to download configuration: $($_.Exception.Message)" "ERROR"
        Write-LogMessage "Please check your internet connection and try again" "ERROR"
        exit 1
    }

    # Check config file existence and permissions
    if (Test-Path $ConfigFile) {
        $acl = Get-Acl $ConfigFile
        Write-LogMessage "Configuration file exists: $ConfigFile (Owner: $($acl.Owner))" "SUCCESS"
    } else {
        Write-LogMessage "Configuration file missing after download: $ConfigFile" "ERROR"
        exit 1
    }

    # Set registry Arguments to use the correct config file and storage path
    $regPath = "HKLM:\SOFTWARE\GrafanaLabs\Alloy"
    try {
        if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        $currentArgs = (Get-ItemProperty -Path $regPath -Name Arguments -ErrorAction SilentlyContinue).Arguments
        if ($currentArgs) {
            $configFileName = if ($IsVM) { 'aio-windows-logs.alloy' } else { 'aio-windows.alloy' }
            $newArgs = $currentArgs -replace '(config|aio-windows|aio-windows-logs)\.alloy', $configFileName
            Set-ItemProperty -Path $regPath -Name Arguments -Value $newArgs -Force
            Write-LogMessage "Registry updated: Arguments = $newArgs" "SUCCESS"
        } else {
            # If not set, set to default using appropriate config file
            $configFileName = if ($IsVM) { 'aio-windows-logs.alloy' } else { 'aio-windows.alloy' }
            $defaultArgs = "run`r`nC:\Program Files\GrafanaLabs\Alloy\$configFileName`r`n--storage.path=C:\ProgramData\GrafanaLabs\Alloy\data"
            Set-ItemProperty -Path $regPath -Name Arguments -Value $defaultArgs -Force
            Write-LogMessage "Registry Arguments created: $defaultArgs" "SUCCESS"
        }

    } catch {
        Write-LogMessage "Failed to set registry Arguments: $($_.Exception.Message)" "ERROR"
    }

    # Replace placeholder URLs if provided
    if ($LokiUrl) {
        Write-LogMessage "Updating Loki endpoint: $LokiUrl"
        (Get-Content $ConfigFile) -replace 'https://your-loki-instance.com/loki/api/v1/push', $LokiUrl | Set-Content $ConfigFile
        if ((Get-Content $ConfigFile) -match [regex]::Escape($LokiUrl)) {
            Write-LogMessage "Loki URL replacement verified in config file" "SUCCESS"
        } else {
            Write-LogMessage "Loki URL replacement failed - URL not found in config file" "ERROR"
        }
    }

    # Only update Prometheus URL if not a VM
    if ($PrometheusUrl -and -not $IsVM) {
        Write-LogMessage "Updating Prometheus endpoint: $PrometheusUrl"
        (Get-Content $ConfigFile) -replace 'https://your-prometheus-instance.com/api/v1/write', $PrometheusUrl | Set-Content $ConfigFile
        if ((Get-Content $ConfigFile) -match [regex]::Escape($PrometheusUrl)) {
            Write-LogMessage "Prometheus URL replacement verified in config file" "SUCCESS"
        } else {
            Write-LogMessage "Prometheus URL replacement failed - URL not found in config file" "ERROR"
        }
    }

    Write-LogMessage "Configuration deployed: $ConfigFile" "SUCCESS"
}

function Start-AlloyService {
    Write-LogMessage "Restarting Alloy service to load new configuration..."

    try {
        $service = Get-Service -Name "Alloy" -ErrorAction SilentlyContinue
        if ($service) {
            # Stop the service if it's running
            if ($service.Status -eq "Running") {
                Write-LogMessage "Stopping Alloy service..."
                Stop-Service -Name "Alloy" -Force
                Write-LogMessage "Alloy service stopped" "SUCCESS"
                Start-Sleep -Seconds 2
            }

            # Start the service with the new configuration
            Write-LogMessage "Starting Alloy service with new configuration..."
            try {
                Start-Service -Name "Alloy" -ErrorAction Stop
                # Wait for service to initialize and check stability (5s) with loading animation
                $stable = $true
                $spinner = @('|','/','-','\\')
                Write-Host -NoNewline "Verifying Alloy service status: "
                for ($i=0; $i -lt 10; $i++) {
                    $spinChar = $spinner[$i % $spinner.Length]
                    Write-Host -NoNewline ("`b" + $spinChar)
                    Start-Sleep -Milliseconds 500
                    $svc = Get-Service -Name "Alloy" -ErrorAction SilentlyContinue
                    if (-not ($svc -and $svc.Status -eq "Running")) {
                        $stable = $false
                        Write-Host ""  # Move to new line after spinner
                        Write-LogMessage "Alloy service stopped or restarted!" "ERROR"
                        Write-LogMessage "Last 20 lines of service log (if available):" "WARNING"
                        # Try to get last 20 lines from Windows Event Log
                        Get-WinEvent -LogName Application -MaxEvents 20 | Where-Object { $_.ProviderName -like '*Alloy*' } | Format-Table -AutoSize
                        break
                    }
                }
                Write-Host ""  # Ensure spinner line ends
                if ($stable) {
                    Write-LogMessage "Alloy service verified running correctly after configuration." "SUCCESS"
                }
            }
            catch {
                Write-LogMessage "Failed to start Alloy service: $($_.Exception.Message)" "ERROR"
                Write-LogMessage "Check Event Viewer (Windows Logs > Application) for detailed error messages" "ERROR"
            }
        } else {
            Write-LogMessage "Alloy service not found" "WARNING"
        }
    }
    catch {
        Write-LogMessage "Failed to restart Alloy service: $($_.Exception.Message)" "ERROR"
    }
}

function Show-FinalStatus {
    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host "    Grafana Alloy Windows Installation Complete!" -ForegroundColor Green
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host ""

    $service = Get-Service -Name "Alloy" -ErrorAction SilentlyContinue
    $configType = if ($IsVM) { "logs only (VM-optimized)" } else { "logs + metrics (full observability)" }
    if ($service -and $service.Status -eq "Running") {
        Write-LogMessage "✅ Alloy is installed and running ($configType)" "SUCCESS"
        Write-LogMessage "Configuration file: $ConfigFile"
        Write-LogMessage "Web UI: http://127.0.0.1:12345/"
        Write-LogMessage "Windows Event Logs: Application, System, Security"
        if (-not $IsVM) {
            Write-LogMessage "Windows Metrics: CPU, Memory, Disk, Network, Services, etc."
        }
        Write-Host ""
        Write-Host "Next Steps:" -ForegroundColor Green
        Write-Host "  1. Check your Loki instance for incoming event log data" -ForegroundColor Green
        Write-Host "  2. Verify metrics/logs collection in Grafana/Prometheus/Loki" -ForegroundColor Green
        Write-Host "  3. Open Alloy web UI: http://127.0.0.1:12345/" -ForegroundColor Green
        Write-Host "  4. Verify all components show as 'Healthy'" -ForegroundColor Green
    } elseif (Test-Path $ConfigFile) {
        Write-LogMessage "⚠️  Alloy is installed but not running" "WARNING"
        Write-LogMessage "Configuration file: $ConfigFile" "WARNING"
        Write-Host ""
        Write-Host "Troubleshooting steps:" -ForegroundColor Yellow
        Write-Host "  1. Check Event Viewer (Windows Logs > Application) for error messages" -ForegroundColor Yellow
        Write-Host "  2. Look for syntax errors in the configuration file" -ForegroundColor Yellow
        Write-Host "  3. Try running: Get-Service -Name 'Alloy' | Format-List *" -ForegroundColor Yellow
        Write-Host "  4. Start the service: Start-Service -Name Alloy" -ForegroundColor Yellow
    } else {
        Write-LogMessage "⚠️  Alloy is installed but needs configuration" "WARNING"
        Write-LogMessage "Configuration file missing: $ConfigFile" "ERROR"
        Write-Host ""
        Write-Host "Manual steps required:" -ForegroundColor Red
        Write-Host "  1. Copy your config to: $ConfigFile" -ForegroundColor Red
        Write-Host "  2. Start the service: Start-Service -Name Alloy" -ForegroundColor Red
    }
}

# Main execution
Write-Host "=============================================" -ForegroundColor Blue
Write-Host "    Grafana Alloy Windows Installation" -ForegroundColor Blue
Write-Host "=============================================" -ForegroundColor Blue
Write-Host ""

Install-Alloy
Deploy-Configuration
Start-AlloyService
Show-FinalStatus

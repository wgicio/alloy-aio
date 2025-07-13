# AIO Grafana Alloy Configuration for Cross-Platform Systems

<div align="center">

[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Grafana Alloy](https://img.shields.io/badge/Grafana-Alloy-orange.svg)](https://grafana.com/docs/alloy/)
[![Loki Compatible](https://img.shields.io/badge/Loki-Compatible-blue.svg)](https://grafana.com/oss/loki/)
[![Prometheus Compatible](https://img.shields.io/badge/Prometheus-Compatible-red.svg)](https://prometheus.io/)


**Cross-Platform Grafana Alloy Install & Configuration with Platform-Optimized Monitoring Approach**

</div>

## 📑 Table of Contents

<p align="center">
  <a href="#-features">✨ Features</a> •
  <a href="#-linux">🐧 Linux</a> •
  <a href="#-windows-systems">🪟 Windows</a> •
  <a href="#-proxmox-guest-metrics-exporter-integrated">🏢 Proxmox Exporter</a> •
  <a href="#-requirements">📝 Requirements</a> •
  <a href="#-quick-install">🚀 Install</a> •
  <a href="#-configuration-approach">⚙️ Config</a> •
  <a href="#-what-gets-installed">📦 Installed</a> •
  <a href="#-management">🛠️ Management</a> •
  <a href="#-troubleshooting">🚨 Troubleshooting</a> •
  <a href="#-tested-systems">🖥️ Tested</a> •
  <a href="#-security">🔒 Security</a> •
  <a href="#-automated-deployment">🤖 Deploy</a> •
  <a href="#-learn-more">📚 More</a> •
  <a href="#-faq">❓ FAQ</a> •
  <a href="#-support-development">💜 Support</a> •
  <a href="#-license">📄 License</a> •
  <a href="#-credits">👏 Credits</a>
</p>




## ✨ Features

> **Automatic Detection:** The Installer Automatically Detects Whether the System is Standalone, Proxmox Host or VM/Container, and configures Logs + Metrics or Logs-Only Mode accordingly. No manual selection is required.

<br>

## 🐧 Linux
#### Standalone/Host
- 🎯 **Smart Log Filtering**: Only WARNING+ Logs sent to Loki (Reduces Noise ~80%)
- 📊 **Full Metrics**: System Metrics collection with Prometheus Integration (Bare Metal, Proxmox Host)
- 🔒 **Security Focused**: Non-root operation with minimal Permissions
- 🚀 **Zero Configuration**: Works out-of-the-box with sensible Defaults
- 🛡️ **Hardened Setup**: Dedicated User, ACL Permissions, systemd Integration

#### Virtualized/Container

- 📊 **Logs Only**: Metrics not collected (Kernel/Namespace Limitations)

<br>

## 🪟 Windows Systems
- 📊 **Full Monitoring**: Both Logs and System Metrics Collection
- 🎯 **Advanced Event Log Parsing**: Clean, readable Windows Event Logs with XML Parsing
- 📈 **System Metrics**: CPU, Memory, Disk, Network Monitoring etc.
- 🔧 **Service Integration**: Runs as Windows Service (Alloy)
- 🚀 **PowerShell Install**: Native Windows Installation Experience

<br>

## 🏢 Proxmox Guest Metrics Exporter (Integrated)

**Automated, Secure Proxmox Guest Metrics Exporter for Alloy/Prometheus**

- 📦 **Systemd Service:** `pve-guest-exporter.service` (runs as "alloy" User)
- 🐍 **Python Script:** `/etc/alloy/pve-guest-exporter.py`
- 🔑 **Token Env:** `/etc/alloy/pve-guest-exporter.env`
- 🔄 **Idempotent Installer:** Always refreshes Token, Script, and Service
- 🔒 **Security:** Minimal Permissions
- 🚀 **Zero Configuration:** Fully automated Setup
- 📊 **Prometheus Endpoint:** Exposes Guest Metrics at `http://localhost:9221/pve`

### ⚙️ How It Works

- The Installer creates a Dedicated Proxmox API User and Token
- The Token is stored in `/etc/alloy/pve-guest-exporter.env`
- The Python Script authenticates to the Proxmox API, collects Guest Metrics, and exposes them for Prometheus/Alloy

<br>

## 🚀 Quick Install
> **⚠️ WARNING:** Running the installation script will overwrite the `alloy@pve` Proxmox user and can replace existing Alloy configuration files in `/etc/alloy/`. Back up your configuration if you have made manual changes.

### 🐧 Linux Installation (Standalone/Host: Logs + Metrics)
```bash
# 1. Clone the repository (required for local file usage)
git clone https://github.com/IT-BAER/alloy-aio.git && cd alloy-aio
```
```bash
# 2. Run the setup script (auto-detects system type)
sudo bash alloy_setup.sh --loki-url "https://loki.yourdomain.com/loki/api/v1/push" --prometheus-url "https://prometheus.yourdomain.com/api/v1/write"
```

> **Note:** Metrics are only collected on Standalone/Proxmox Host. In Containers/VMs, only Logs are collected.

<br>

### 🪟 Windows Installation (Logs + Metrics)

```powershell
# Download and run PowerShell Installer (run as Administrator)
Invoke-WebRequest -Uri "https://github.com/IT-BAER/alloy-aio/raw/main/alloy_setup_windows.ps1" -OutFile "alloy_setup_windows.ps1"
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
.\alloy_setup_windows.ps1 -LokiUrl "https://loki.yourdomain.com/loki/api/v1/push" -PrometheusUrl "https://prometheus.yourdomain.com/api/v1/write"
```

<br>

### 📟 Container/Mass Deployment Example


| 🏗️ **System Components** | 📊 **Monitoring Capabilities** | 🔧 **Configuration** |
```bash
# Clone the repo on the host, then copy to each container and run locally
for container in $(pct list | awk 'NR>1 && $2=="running" {print $1}'); do
| Runs as LocalSystem service by default | Smart log filtering (WARNING+ only) | Automated service installation & updates |
  pct push $container ./alloy-aio /root/alloy-aio -r
  pct exec $container -- bash -c 'cd /root/alloy-aio && sudo bash alloy_setup.sh --loki-url "https://loki.yourdomain.com/loki/api/v1/push"'
done
```

<br>

## ⚙️ Configuration Approach

This Project uses a **Platform-Aware** Configuration Strategy:

- ✅ **Validated Config**: All Configurations pass Syntax Validation before being committed
- 🐧 **Linux**: Metrics+Logs/Logs-only Configuration based on Platform
- 🪟 **Windows**:  Monitoring with Logs + Metrics for full System Visibility
- 🎛️ **Custom Override**: Check FAQ
- 🌐 **Internet Required**: Installation requires Internet Connection for Configuration Download

This ensures you always get a working, tested Configuration optimized for each Platform.

<br>

## 📦 What Gets Installed

<div align="center">

### 🐧 Linux Standalone/Proxmox Host (Logs + Metrics)
| 🏗️ **System Components** | 📊 **Monitoring Capabilities** | 🔧 **Configuration** |
| :--: | :--: | :--: |
| Grafana Alloy (latest stable, systemd service) | System & application log collection (journal, files) | Automated config deployment & validation |
| Dedicated `alloy` user with ACLs | Smart log filtering (WARNING+ only) | Secure, non-root operation, minimal permissions |
| Prometheus metrics exporter (node/system) | Full host metrics (CPU, memory, disk, network, uptime, etc.) | Efficient log shipping to Loki, metrics to Prometheus |
| Proxmox guest metrics exporter (if Proxmox host) | Guest VM/CT metrics via local API | Automated Proxmox API user/token/service management |

<br>

### 🐧 Linux Virtualized/Container (Logs Only)
| 🏗️ **System Components** | 📊 **Monitoring Capabilities** | 🔧 **Configuration** |
| :--: | :--: | :--: |
| Grafana Alloy (latest stable, systemd service) | System & application log collection (journal, files) | Automated config deployment & validation |
| Dedicated `alloy` user with ACLs | Smart log filtering (WARNING+ only) | Secure, non-root operation, minimal permissions |
| Lightweight logs-only config | Container/VM-aware hostname labeling | Efficient log shipping to Loki |
| No metrics collection (kernel/namespace limits) | Ephemeral log handling | Resource-efficient configuration |

<br>

### 🪟 Windows Systems (Logs + Metrics)
| 🏗️ **System Components** | 📊 **Monitoring Capabilities** | 🔧 **Configuration** |
| :--: | :--: | :--: |
| Grafana Alloy (latest stable, Windows service) | Structured Event Log collection (Application, System, Security) | Automated config download & deployment |
| System metrics exporter | Full host metrics (CPU, memory, disk, network, services) | Efficient log shipping to Loki, metrics to Prometheus |
| Runs as LocalSystem service by default | Smart log filtering (WARNING+ only) | Automated service installation & updates |
| Event log and metrics forwarding | Windows service integration | Configuration validation & troubleshooting guidance |

</div>

<br>

## 🛠️ Management

### 🐧 Linux Service Control
```bash
# Check status
sudo systemctl status alloy
```
```bash
# View logs  
sudo journalctl -u alloy -f
```
```bash
# Restart service
sudo systemctl restart alloy
```

### 🪟 Windows Service Control
```powershell
# Check status
Get-Service "Alloy"
```
```powershell
# View logs
Get-WinEvent -LogName Application -Source "Alloy" | Select-Object -First 10
```
```powershell
# Restart service
Restart-Service "Alloy"
```

### ⚙️ Configuration Files

#### 🐧 Linux Configuration
```bash
# Edit config (logs only)
sudo nano /etc/alloy/aio-linux-logs.alloy
```
```bash
# Edit config (Full)
sudo nano /etc/alloy/aio-linux.alloy
```
```bash
# Validate syntax
sudo alloy fmt /etc/alloy/aio-linux-logs.alloy --test
```
```bash
# Apply changes
sudo systemctl restart alloy
```

#### 🪟 Windows Configuration
```powershell
# Edit unified config (logs + metrics)
notepad "C:\Program Files\GrafanaLabs\Alloy\aio-windows.alloy"
```
```powershell
# Validate syntax (run as Administrator)
& "C:\Program Files\GrafanaLabs\Alloy\alloy-windows-amd64.exe" fmt "C:\Program Files\GrafanaLabs\Alloy\aio-windows.alloy" --test
```
```powershell
# Apply changes
Restart-Service "Alloy"
```

### 🔍 Health Check

#### 🐧 Linux
```bash
# Alloy metrics endpoint
curl http://localhost:12345/metrics

# Web UI (if enabled)
# http://localhost:12345
```

#### 🪟 Windows
```powershell
# Alloy metrics endpoint
Invoke-WebRequest -Uri "http://localhost:12345/metrics"

# Web UI (if enabled)
# http://localhost:12345
```

## 🚨 Troubleshooting

### 🐧 Linux Issues

**🔍 Service won't start:**
```bash
sudo systemctl status alloy
sudo journalctl -u alloy --no-pager
```

**🔐 Permission errors:**
```bash
sudo usermod -aG adm,systemd-journal alloy
sudo setfacl -R -m u:alloy:rx /var/log/
sudo systemctl restart alloy
```

**✅ Config validation:**
```bash
sudo alloy fmt --test /etc/alloy/aio-linux.alloy
```

<br>

### 🪟 Windows Issues

**🔍 Service won't start:**
```powershell
Get-Service "Alloy"
Get-WinEvent -LogName Application -Source "Alloy" | Select-Object -First 10
```

**🔐 Permission errors:**
```powershell
# Run as Administrator to check service permissions
Get-Acl "C:\Program Files\GrafanaLabs\Alloy\*"
```

**✅ Config validation:**
```powershell
# Run as Administrator
& "C:\Program Files\GrafanaLabs\Alloy\alloy-windows-amd64.exe" fmt "C:\Program Files\GrafanaLabs\Alloy\aio-windows.alloy" --test
```

<br>

### 🏢 Proxmox Issues
**Service won't start or Metrics Endpoint returns error:**
```bash
sudo systemctl status pve-guest-exporter
sudo journalctl -u pve-guest-exporter --no-pager
```

**Token/Authentication Issues:**
- The Installer always refreshes the Proxmox API token and updates `/etc/alloy/pve-guest-exporter.env`
- If you see Authentication Errors, rerun the Installer to regenerate the Token and env file

**Validate Exporter Metrics Endpoint:**
```bash
curl http://localhost:9221/pve
```

**Manual restart after Config/Token changes:**
```bash
sudo systemctl restart pve-guest-exporter
```

<br>

## 🖥️ Tested Systems

| OS | Version | Logs | Metrics | Status |
|---|---------|------|---------|--------|
| Proxmox (Host)| 8.4.1 | ✅ | ✅ | ✅ |
| Debian (Virtualized)| 12+ | ✅ | ❌ | ✅ |
| Windows Server | 2022+ | ✅ | ✅ | ✅ |
| Windows 10/11 | Pro/Enterprise | ✅ | ✅ | ✅ |

<br>

## 🔒 Security

### 🐧 Linux Security
- 🛡️ **Non-root operation**: Alloy runs as Dedicated User
- 🔐 **Minimal permissions**: ACL-based log access only
- 📁 **Secure configuration**: 640 Permissions on Config Files

## 🤖 Automated Deployment

### 🚀 Cross-Platform Deployment

The Installation Scripts are designed for automated Deployment without User Interaction:

#### 🐧 Linux Features
- **🔄 Non-interactive Mode**: Automatically handles Prompts
- **📦 Package Updates**: No manual Confirmation required
- **🧹 Clean Exit**: Removes temporary Files

#### 🪟 Windows Features
- **🔄 Silent Installation**: Automated MSI Installer Download and Deployment
- **📦 Service Setup**: Automatic Service Registration and startup Configuration (Alloy)
- **🧹 Clean Deployment**: PowerShell-based Installation with proper Error handling


<br>

## 📚 Learn More

- [Grafana Alloy Documentation](https://grafana.com/docs/alloy/)
- [Loki Documentation](https://grafana.com/docs/loki/)
- [Prometheus Documentation](https://prometheus.io/docs/)

<br>

## ❓ FAQ

### 🔍 Alloy Service Won't Start After Installation

#### 🐧 Linux
If the Alloy Service fails to start after Installation:

1. **🔍 Check Service Status and Logs**:
   ```bash
   sudo systemctl status alloy
   sudo journalctl -u alloy --no-pager
   ```

2. **🔐 Verify Permissions**:
   ```bash
   sudo usermod -aG adm,systemd-journal alloy
   sudo setfacl -R -m u:alloy:rx /var/log/
   sudo systemctl restart alloy
   ```

3. **✅ Validate Configuration**:
   ```bash
   sudo alloy fmt --test /etc/alloy/aio-linux.alloy
   ```

#### 🪟 Windows
If the Alloy Service fails to start after Installation:

1. **🔍 Check Service Status and Event Logs**:
   ```powershell
   Get-Service "Alloy"
   Get-WinEvent -LogName Application -Source "Alloy" | Select-Object -First 10
   ```

2. **🔐 Verify Service Permissions**:
   ```powershell
   # Run as Administrator
   Get-Acl "C:\Program Files\GrafanaLabs\Alloy\"
   ```

3. **✅ Validate Configuration**:
   ```powershell
   # Run as Administrator
   & "C:\Program Files\GrafanaLabs\Alloy\alloy-windows-amd64.exe" fmt "C:\Program Files\GrafanaLabs\Alloy\aio-windows.alloy" --test
   ```

### 🔍 No Logs/Metrics Appearing in Grafana

If you're not seeing Data in your Monitoring Stack:

1. **🔍 Check Alloy Metrics Endpoint**: `curl http://localhost:12345/metrics` (Linux) or <br>`Invoke-WebRequest http://localhost:12345/metrics` (Windows)
2. **🌐 Verify Endpoint URLs**: Ensure Loki/Prometheus URLs are accessible from the System
3. **🔑 Check Authentication**: Verify API Keys or Basic Auth Credentials are correct
4. **📊 Check Alloy UI**: Visit `http://localhost:12345` for Component Status
5. **🎯 Platform-specific**:
   - **Linux**: Verify Log File Permissions and systemd journal access
   - **Windows**: Check Event Log Permissions and Windows Exporter functionality

### ❓ How to Customize the Configuration?

#### 🐧 Linux
- **🔄 Repository-based**: Default Configs are pulled from the Repository on Installation
- **🎛️ Local override**: Create a new Config other than `aio-linux.alloy` or `aio-linux-log.alloy`. <br> If running multiple Configs, change the `CONFIG_FILE` value in `/etc/default/alloy` to the Config Path.
- **✅ Always validate**: Run `sudo alloy fmt --test` before restarting the Service
- **🔄 Apply changes**: `sudo systemctl restart alloy` after modifications

#### 🪟 Windows
- **🔄 Repository-based**: Default Configs downloaded during PowerShell Installation
- **🎛️ Local override**: Create a new Config other than `aio-windows.alloy` (f.e. your_config.alloy) and change the Registry (regedit) value of **Arguments** in `HKEY_LOCAL_MACHINE\SOFTWARE\GrafanaLabs\Alloy` to <br> `run` <br>
`C:\Program Files\GrafanaLabs\Alloy\your_config.alloy` <br>
`--storage.path=%PROGRAMDATA%\GrafanaLabs\Alloy\data` <br>
**Make sure that each Argument is on its own line!**
- **✅ Always validate**: Run Alloy fmt command as Administrator before restarting
- **🔄 Apply changes**: `Restart-Service "Alloy"` after modifications

### 🔍 High Resource Usage

If Alloy is consuming too many Resources:

#### 🐧 Linux
1. **📊 Monitor usage**: Check Memory and CPU via `top` or `htop`
2. **🎯 Adjust log levels**: Modify Log Collection Rules to be more selective
3. **⚙️ Tune configuration**: Adjust Collection Intervals


#### 🪟 Windows
1. **📊 Monitor metrics**: Check Task Manager or Performance Monitor
2. **🎯 Adjust collection**: Tune Event Log Queries and Metrics scraping Intervals
3. **⚙️ Windows-specific**: Consider disabling specific Performance Counters if not needed

### 🔧 "Which Services Should Be Restarted?" Prompt in Containers (Linux)

If you see a Dialog asking about Service Restarts during Installation (common in Proxmox Containers):

**This is now automatically handled!** The Installation Script:

1. **🤖 Configures non-interactive mode**: Sets `DEBIAN_FRONTEND=noninteractive`
2. **📦 Package handling**: Uses proper dpkg options to avoid prompts
3. **🧹 Clean exit**: Removes temporary files after installation

<br>

## 📚 Learn More

- [Grafana Alloy Documentation](https://grafana.com/docs/alloy/)
- [Loki Documentation](https://grafana.com/docs/loki/)
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Windows Event Log Integration](https://grafana.com/docs/alloy/latest/reference/components/loki.source.windowsevent/)
- [Prometheus Windows Exporter](https://grafana.com/docs/alloy/latest/reference/components/prometheus.exporter.windows/)

<br>

## 💜 Support Development

If you find this Project useful, consider supporting this and future Developments, which heavily relies on Coffee:

<div align="center">
<a href="https://www.buymeacoffee.com/itbaer" target="_blank"><img src="https://github.com/user-attachments/assets/64107f03-ba5b-473e-b8ad-f3696fe06002" alt="Buy Me A Coffee" style="height: 60px !important;max-width: 217px !important;" ></a>
</div>

<br>

## 📄 License

This project is licensed under the [AGPL-3.0](LICENSE) license.

<br>

## 👏 Credits

- [Grafana Labs](https://grafana.com/) - For the amazing Grafana Alloy project
- [Grafana Community](https://grafana.com/community/) - For continuous support and feedback



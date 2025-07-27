# AIO Grafana Alloy Configuration for Cross-Platform Systems

<div align="center">

[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Grafana Alloy](https://img.shields.io/badge/Grafana-Alloy-orange.svg)](https://grafana.com/docs/alloy/)
[![Loki Compatible](https://img.shields.io/badge/Loki-Compatible-blue.svg)](https://grafana.com/oss/loki/)
[![Prometheus Compatible](https://img.shields.io/badge/Prometheus-Compatible-red.svg)](https://prometheus.io/)
![GitHub stars](https://img.shields.io/github/stars/it-baer/alloy-aio?style=social)

**Cross-Platform Grafana Alloy Install & Configuration with Platform-Optimized Monitoring**

</div>

## 📑 Table of Contents

<p align="center">
  <a href="#-key-features">✨ Features</a> •
  <a href="#-quick-install">🚀 Install</a> •
  <a href="#-management">🛠️ Management</a> •
  <a href="#-troubleshooting">🚨 Troubleshooting</a> •
  <a href="#-tested-systems">🖥️ Tested</a> •
  <a href="#-security">🔒 Security</a> •
  <a href="#-learn-more">📚 More</a> •
  <a href="#-license">📄 License</a> •
  <a href="#-credits">👏 Credits</a>
</p>

## ✨ Key Features

> **Automatic Detection:** Installer automatically detects system type (Standalone, Proxmox Host, VM/Container) and configures Logs + Metrics or Logs-Only mode accordingly.

### 🐧 Linux
- **Standalone/Host**: Full logs + metrics monitoring
- **Virtualized**: Logs-only monitoring (kernel limitations)

### 🪟 Windows
- **Physical/Host**: Full logs + metrics monitoring
- **Virtualized**: Logs-only monitoring

### 🏢 Proxmox Guest Metrics Exporter
- Automated, secure metrics exporter for Proxmox guests
- Zero-configuration setup with automatic API user/token management
- Exposes guest metrics at `http://localhost:9221/pve`

<br>

## 🚀 Quick Install

> **⚠️ WARNING:** Running installation scripts can overwrite existing Alloy configurations. Back up your configuration if you have made manual changes.


### 🐧 Linux (Standalone/Host)
```bash
# One-liner installation (replace URLs with your endpoints)
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/IT-BAER/alloy-aio/main/alloy_setup.sh)" -- --loki-url "https://loki.yourdomain.com/loki/api/v1/push" --prometheus-url "https://prometheus.yourdomain.com/api/v1/write"
```

### 🪟 Windows
```powershell
# One-liner installation (replace Loki & Prom URLs)
powershell -ExecutionPolicy Bypass -Command "Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri 'https://github.com/IT-BAER/alloy-aio/raw/main/alloy_setup_windows.ps1' -OutFile 'alloy_setup_windows.ps1'; .\alloy_setup_windows.ps1 -LokiUrl 'https://loki.yourdomain.com/loki/api/v1/push' -PrometheusUrl 'https://prometheus.yourdomain.com/api/v1/write'"
```

### 📟 Proxmox CT Mass Deployment
```bash
# Deploy to all running containers (replace Loki URL)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/IT-BAER/alloy-aio/main/proxmox_ct_deploy.sh)" -- --loki-url "https://loki.yourdomain.com/loki/api/v1/push"
```
```bash
# Deploy to specific container (replace Loki URL & Container ID)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/IT-BAER/alloy-aio/main/proxmox_ct_deploy.sh)" -- --loki-url "https://loki.yourdomain.com/loki/api/v1/push" --container 100
```

### 🤖 Proxmox VM Mass Deployment
> **Note:** Requires QEMU Guest Agent on target VMs.

```bash
# Deploy to all running VMs (replace Loki URL)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/IT-BAER/alloy-aio/main/proxmox_vm_deploy.sh)" -- --loki-url "https://loki.yourdomain.com/loki/api/v1/push"
```
```bash
# Deploy to specific VM (replace Loki URL & VM ID)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/IT-BAER/alloy-aio/main/proxmox_vm_deploy.sh)" -- --loki-url "https://loki.yourdomain.com/loki/api/v1/push" --vm 100
```
<br>

## 🛠️ Management

### 🐧 Linux Service Control
```bash
sudo systemctl status alloy     # Check status
sudo journalctl -u alloy -f     # View logs
sudo systemctl restart alloy    # Restart service
```

### 🪟 Windows Service Control
```powershell
Get-Service "Alloy"             # Check status
Restart-Service "Alloy"         # Restart service
```
<br>

## 🚨 Troubleshooting

### Common Issues

**Service won't start:**
```bash
# Linux
sudo systemctl status alloy
sudo journalctl -u alloy --no-pager

# Windows
Get-Service "Alloy"
Get-WinEvent -LogName Application -Source "Alloy" | Select-Object -First 10
```

**Permission errors (Linux):**
```bash
sudo usermod -aG adm,systemd-journal alloy
sudo setfacl -R -m u:alloy:rx /var/log/
sudo systemctl restart alloy
```

**Validate configuration:**
```bash
# Linux
sudo alloy fmt --test /etc/alloy/aio-linux.alloy

# Windows (run as Administrator)
& "C:\Program Files\GrafanaLabs\Alloy\alloy-windows-amd64.exe" fmt "C:\Program Files\GrafanaLabs\Alloy\aio-windows.alloy" --test
```
<br>

## 🖥️ Tested Systems

| OS | Version | Logs | Metrics | Status |
|---|---------|------|---------|---------|
| Proxmox (Host)| 8.4.1 | ✅ | ✅ | ✅ |
| Debian (Virtualized)| 12+ | ✅ | ❌ | ✅ |
| Windows (Physical)| 10/11/Server 2022+ | ✅ | ✅ | ✅ |
| Windows (Proxmox VM)| 10/11/Server 2022+ | ✅ | ❌ | ✅ |

<br>

## 🔒 Security

### 🐧 Linux Security
- 🛡️ **Non-root operation**: Alloy runs as Dedicated User
- 🔐 **Minimal permissions**: ACL-based log access only
- 📁 **Secure configuration**: 640 Permissions on Config Files

<br>

## 📚 Learn More

- [Grafana Alloy Documentation](https://grafana.com/docs/alloy/)
- [Loki Documentation](https://grafana.com/docs/loki/)
- [Prometheus Documentation](https://prometheus.io/docs/)

<br>

## 📄 License

This project is licensed under the [AGPL-3.0](LICENSE) license.

<br>

## 💜 Support Development

If you find this Project useful, consider supporting this and future Developments, which heavily relies on Coffee:

<div align="center">
<a href="https://www.buymeacoffee.com/itbaer" target="_blank"><img src="https://github.com/user-attachments/assets/64107f03-ba5b-473e-b8ad-f3696fe06002" alt="Buy Me A Coffee" style="height: 60px !important;max-width: 217px !important;" ></a>
</div>

<br>

## 👏 Credits

- [Grafana Labs](https://grafana.com/) - For the amazing Grafana Alloy project
- [Grafana Community](https://grafana.com/community/) - For continuous support and feedback

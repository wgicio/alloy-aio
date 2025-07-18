#!/usr/bin/env python3

"""
Proxmox guest metrics exporter for Prometheus (PERFORMANCE OPTIMIZED)
- Real-time critical metrics, cached non-critical metrics
- Minimal CPU usage while maintaining essential real-time data
"""

import os
import requests
import traceback
import time
import socket
from functools import lru_cache
from flask import Flask, Response
import urllib3
import logging
from threading import Lock

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Config
PROXMOX_HOST = os.environ.get("PROXMOX_HOST", "localhost")
PROXMOX_PASS = os.environ.get("PROXMOX_PASS", "")
VERIFY_SSL = False
PORT = 9221

# Environment variables
PVE_API_TOKEN = os.environ.get("PVE_API_TOKEN")
PROXMOX_USER = os.environ.get("PROXMOX_USER")
PROXMOX_TOKEN_NAME = os.environ.get("PROXMOX_TOKEN_NAME")
PROXMOX_TOKEN_VALUE = os.environ.get("PROXMOX_TOKEN_VALUE")

def load_env_file():
    env_file = "/etc/alloy/pve-guest-exporter/pve-guest-exporter.env"
    if os.path.exists(env_file):
        try:
            with open(env_file, 'r') as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#') and '=' in line:
                        key, value = line.split('=', 1)
                        os.environ[key] = value
        except Exception:
            pass

load_env_file()

# Reload environment variables
PVE_API_TOKEN = os.environ.get("PVE_API_TOKEN")
PROXMOX_USER = os.environ.get("PROXMOX_USER")
PROXMOX_TOKEN_NAME = os.environ.get("PROXMOX_TOKEN_NAME")
PROXMOX_TOKEN_VALUE = os.environ.get("PROXMOX_TOKEN_VALUE")

def parse_pve_api_token(token):
    try:
        if not token:
            return None, None, None
        user, rest = token.split('!', 1)
        tokenid, uuid = rest.split('=')
        return user, tokenid, uuid
    except Exception:
        return None, None, None

app = Flask(__name__)

# Suppress Flask logs
logging.getLogger('werkzeug').setLevel(logging.WARNING)
logging.getLogger('flask').setLevel(logging.WARNING)

# Optimized session - reduced overhead
session = requests.Session()
session.headers.update({'Connection': 'keep-alive'})
adapter = requests.adapters.HTTPAdapter(
    pool_connections=8,    # Reduced from 20
    pool_maxsize=15,       # Reduced from 50
    max_retries=1,         # Reduced from 2
    pool_block=False
)
session.mount('https://', adapter)

# Optimized caching - separate real-time from cached data
_config_cache = {}
_disk_usage_cache = {}
_storage_cache = {}
_ceph_cache = {}
_auth_cache = {"valid_until": 0}
_hostname_cache = None
_swap_rotation_index = 0
_swap_data_cache = {}

# Cache TTLs
CONFIG_CACHE_TTL = 600       
DISK_USAGE_CACHE_TTL = 30
STORAGE_CACHE_TTL = 60
CEPH_CACHE_TTL = 30
AUTH_TTL = 3600
SWAP_CACHE_TTL = 60

def get_hostname():
    global _hostname_cache
    if _hostname_cache is None:
        _hostname_cache = socket.gethostname()
    return _hostname_cache

def authenticate():
    """Optimized authentication with caching"""
    current_time = time.time()
    
    if current_time < _auth_cache["valid_until"]:
        return True
    
    # Try API token first (fastest)
    user = PROXMOX_USER
    token_name = PROXMOX_TOKEN_NAME
    token_value = PROXMOX_TOKEN_VALUE
    
    if not (user and token_name and token_value) and PVE_API_TOKEN:
        user, token_name, token_value = parse_pve_api_token(PVE_API_TOKEN)
    
    if user and token_name and token_value:
        session.headers["Authorization"] = f"PVEAPIToken={user}!{token_name}={token_value}"
        _auth_cache["valid_until"] = current_time + AUTH_TTL
        return True
    
    # Fallback to password auth
    if PROXMOX_PASS and PROXMOX_USER:
        try:
            resp = session.post(
                f"https://{PROXMOX_HOST}:8006/api2/json/access/ticket",
                data={"username": PROXMOX_USER, "password": PROXMOX_PASS},
                verify=VERIFY_SSL, timeout=5
            )
            if resp.ok:
                data = resp.json()["data"]
                session.cookies.set("PVEAuthCookie", data["ticket"])
                session.headers["CSRFPreventionToken"] = data["CSRFPreventionToken"]
                _auth_cache["valid_until"] = current_time + AUTH_TTL
                return True
        except Exception:
            pass
    
    return False

def get_vm_config_cached(node_name, vmid, guest_type):
    """Cache static VM config data only"""
    cache_key = f"{node_name}:{guest_type}:{vmid}"
    current_time = time.time()
    
    if cache_key in _config_cache:
        data, timestamp = _config_cache[cache_key]
        if current_time - timestamp < CONFIG_CACHE_TTL:
            return data
    
    try:
        resp = session.get(
            f"https://{PROXMOX_HOST}:8006/api2/json/nodes/{node_name}/{guest_type}/{vmid}/config",
            verify=VERIFY_SSL, timeout=2
        )
        if resp.ok:
            config = resp.json()["data"]
            ostype = config.get("ostype", "unknown")
            if ostype == "unknown" and guest_type == "lxc":
                ostype = config.get("hostname", "unknown")
            
            cpus = config.get("cores", 1)
            if guest_type == "qemu":
                cpus *= config.get("sockets", 1)
            
            result = {"ostype": ostype, "cpus": cpus}
            _config_cache[cache_key] = (result, current_time)
            return result
    except Exception:
        pass
    
    return {"ostype": "unknown", "cpus": 0}

def get_guest_disk_usage_cached(node_name, vmid, guest_type):
    """Cache expensive guest agent disk usage calls"""
    if guest_type != "qemu":
        return None
    
    cache_key = f"{node_name}:{vmid}:disk"
    current_time = time.time()
    
    if cache_key in _disk_usage_cache:
        data, timestamp = _disk_usage_cache[cache_key]
        if current_time - timestamp < DISK_USAGE_CACHE_TTL:
            return data
    
    try:
        resp = session.get(
            f"https://{PROXMOX_HOST}:8006/api2/json/nodes/{node_name}/qemu/{vmid}/agent/get-fsinfo",
            verify=VERIFY_SSL, timeout=5
        )
        if resp.ok:
            json_data = resp.json()
            if isinstance(json_data, dict) and "data" in json_data:
                result_data = json_data["data"]
                if isinstance(result_data, dict) and "result" in result_data:
                    disk_usage = result_data["result"]
                    _disk_usage_cache[cache_key] = (disk_usage, current_time)
                    return disk_usage
    except Exception:
        pass
    
    _disk_usage_cache[cache_key] = (None, current_time)
    return None

def get_storage_metrics_cached():
    """Cache storage metrics (change slowly)"""
    current_time = time.time()
    
    if "storage" in _storage_cache:
        data, timestamp = _storage_cache["storage"]
        if current_time - timestamp < STORAGE_CACHE_TTL:
            return data
    
    metrics = []
    try:
        resp = session.get(
            f"https://{PROXMOX_HOST}:8006/api2/json/cluster/resources",
            verify=VERIFY_SSL, timeout=5
        )
        if resp.ok:
            resources = resp.json()["data"]
            for resource in resources:
                if resource.get("type") == "storage":
                    node = resource.get("node", "unknown")
                    storage_id = resource.get("storage", "unknown")
                    total = resource.get("maxdisk", 0)
                    used = resource.get("disk", 0)
                    available = total - used if total > used else 0
                    status = 1 if resource.get("status") == "available" else 0
                    
                    labels = f'node="{node}",storage="{storage_id}"'
                    metrics.extend([
                        f'proxmox_storage_total_bytes{{{labels}}} {total}',
                        f'proxmox_storage_used_bytes{{{labels}}} {used}',
                        f'proxmox_storage_available_bytes{{{labels}}} {available}',
                        f'proxmox_storage_status{{{labels}}} {status}'
                    ])
    except Exception:
        pass
    
    _storage_cache["storage"] = (metrics, current_time)
    return metrics

def get_ceph_metrics_cached():
    """Cache Ceph metrics (change slowly)"""
    current_time = time.time()
    
    if "ceph" in _ceph_cache:
        data, timestamp = _ceph_cache["ceph"]
        if current_time - timestamp < CEPH_CACHE_TTL:
            return data
    
    metrics = []
    try:
        resp = session.get(
            f"https://{PROXMOX_HOST}:8006/api2/json/cluster/ceph/status",
            verify=VERIFY_SSL, timeout=5
        )
        if resp.ok:
            status = resp.json().get("data", {})
            
            # Health status
            health = status.get("health", {})
            if "status" in health:
                metrics.append(f'proxmox_ceph_cluster_health{{status="{health["status"]}"}} 1')
            
            # PG map statistics
            pgmap = status.get("pgmap", {})
            if pgmap:
                if "bytes_total" in pgmap:
                    metrics.append(f'proxmox_ceph_cluster_total_bytes{{cluster="ceph"}} {pgmap["bytes_total"]}')
                if "bytes_used" in pgmap:
                    metrics.append(f'proxmox_ceph_cluster_used_bytes{{cluster="ceph"}} {pgmap["bytes_used"]}')
                if "bytes_avail" in pgmap:
                    metrics.append(f'proxmox_ceph_cluster_available_bytes{{cluster="ceph"}} {pgmap["bytes_avail"]}')
                if "num_pgs" in pgmap:
                    metrics.append(f'proxmox_ceph_cluster_pgs_total{{cluster="ceph"}} {pgmap["num_pgs"]}')
            
            # Monitor and OSD status
            monmap = status.get("monmap", {})
            if "mons" in monmap:
                metrics.append(f'proxmox_ceph_monitors_total{{cluster="ceph"}} {len(monmap["mons"])}')
            
            osdmap = status.get("osdmap", {})
            if osdmap:
                if "num_osds" in osdmap:
                    metrics.append(f'proxmox_ceph_osds_total{{cluster="ceph"}} {osdmap["num_osds"]}')
                if "num_up_osds" in osdmap:
                    metrics.append(f'proxmox_ceph_osds_up{{cluster="ceph"}} {osdmap["num_up_osds"]}')
                if "num_in_osds" in osdmap:
                    metrics.append(f'proxmox_ceph_osds_in{{cluster="ceph"}} {osdmap["num_in_osds"]}')
    except Exception:
        pass
    
    _ceph_cache["ceph"] = (metrics, current_time)
    return metrics

def get_realtime_guest_status(node_name):
    """Get real-time guest status with consistent swap data"""
    global _swap_rotation_index
    
    try:
        resp = session.get(
            f"https://{PROXMOX_HOST}:8006/api2/json/cluster/resources",
            verify=VERIFY_SSL, timeout=8
        )
        if not resp.ok:
            return {}
        
        resources = resp.json()["data"]
        guest_status = {}
        running_vms = []
        
        # Step 1: Get bulk data and identify running VMs
        for resource in resources:
            if (resource.get("type") in ["qemu", "lxc"] and 
                resource.get("node") == node_name):
                vmid = resource.get("vmid")
                if vmid:
                    guest_status[vmid] = {
                        "vmid": vmid,
                        "name": resource.get("name", f"vm{vmid}"),
                        "type": resource.get("type"),
                        "status": resource.get("status", "unknown"),
                        "cpu": resource.get("cpu", 0),
                        "mem": resource.get("mem", 0),
                        "maxmem": resource.get("maxmem", 0),
                        "disk": resource.get("disk", 0),
                        "maxdisk": resource.get("maxdisk", 0),
                        "uptime": resource.get("uptime", 0),
                        "netin": resource.get("netin", 0),
                        "netout": resource.get("netout", 0),
                        "diskread": resource.get("diskread", 0),
                        "diskwrite": resource.get("diskwrite", 0),
                        "swap": resource.get("swap", 0),
                        "maxswap": resource.get("maxswap", 0)
                    }
                    
                    if resource.get("status") == "running":
                        running_vms.append(vmid)
        
        # Step 2: Apply cached swap data first (always use if available)
        current_time = time.time()
        for vmid, data in guest_status.items():
            if data.get("status") == "running":
                cache_key = f"{node_name}:{vmid}:swap"
                if cache_key in _swap_data_cache:
                    cached_swap, timestamp = _swap_data_cache[cache_key]
                    # Use cached data regardless of age to ensure consistency
                    data.update(cached_swap)
        
        # Step 3: Smart rotation - only check 2 VMs per scrape for fresh data
        if running_vms:
            # Rotate through VMs, checking only 2 per scrape
            vms_to_check = []
            for i in range(2):  # Only 2 VMs per scrape
                if running_vms:
                    vm_index = (_swap_rotation_index + i) % len(running_vms)
                    vms_to_check.append(running_vms[vm_index])
            
            # Update rotation index for next scrape
            _swap_rotation_index = (_swap_rotation_index + 2) % max(len(running_vms), 1)
            
            # Fetch fresh swap data for selected VMs only
            for vmid in vms_to_check:
                if vmid in guest_status:
                    data = guest_status[vmid]
                    
                    # Always fetch fresh data for rotated VMs
                    try:
                        guest_type = data["type"]
                        status_resp = session.get(
                            f"https://{PROXMOX_HOST}:8006/api2/json/nodes/{node_name}/{guest_type}/{vmid}/status/current",
                            verify=VERIFY_SSL, timeout=1
                        )
                        if status_resp.ok:
                            status_data = status_resp.json()["data"]
                            swap_data = {
                                "swap": status_data.get("swap", 0),
                                "maxswap": status_data.get("maxswap", 0)
                            }
                            # Update VM data and cache with extended TTL
                            data.update(swap_data)
                            cache_key = f"{node_name}:{vmid}:swap"
                            _swap_data_cache[cache_key] = (swap_data, current_time)
                    except Exception:
                        continue
        
        return guest_status
    except Exception:
        return {}

def get_host_resources_realtime(node_name):
    """Get real-time host-level resource metrics - no caching"""
    metrics = []
    try:
        resp = session.get(
            f"https://{PROXMOX_HOST}:8006/api2/json/nodes/{node_name}/status",
            verify=VERIFY_SSL, timeout=3  # Reduced timeout for faster response
        )
        if resp.ok:
            status = resp.json()["data"]
            labels = f'node="{node_name}"'
            
            # CPU metrics
            if "cpu" in status:
                metrics.append(f'proxmox_host_cpu_usage{{{labels}}} {status["cpu"]}')
            if "cpuinfo" in status:
                metrics.append(f'proxmox_host_cpu_total{{{labels}}} {status["cpuinfo"]["cpus"]}')
            
            # Memory metrics
            if "memory" in status:
                memory = status["memory"]
                metrics.extend([
                    f'proxmox_host_mem_used_bytes{{{labels}}} {memory["used"]}',
                    f'proxmox_host_mem_total_bytes{{{labels}}} {memory["total"]}',
                    f'proxmox_host_mem_free_bytes{{{labels}}} {memory["free"]}'
                ])
            
            # Storage metrics
            if "rootfs" in status:
                rootfs = status["rootfs"]
                metrics.extend([
                    f'proxmox_host_storage_used_bytes{{{labels}}} {rootfs["used"]}',
                    f'proxmox_host_storage_total_bytes{{{labels}}} {rootfs["total"]}',
                    f'proxmox_host_storage_available_bytes{{{labels}}} {rootfs["avail"]}'
                ])
    except Exception:
        pass
    
    return metrics

def generate_guest_metrics(node_name, vmid, guest_data, config_data, disk_usage=None):
    status_val = 1 if guest_data.get("status") == "running" else 0
    name = guest_data.get("name", f"vm{vmid}")
    ostype = config_data.get("ostype", "unknown")
    cpus = config_data.get("cpus", 0)
    guest_type = guest_data.get("type", "unknown")
    
    labels = f'node="{node_name}",vmid="{vmid}",name="{name}",ostype="{ostype}",type="{guest_type}"'
    
    # Generate core metrics
    metrics = [
        f'proxmox_guest_status{{{labels}}} {status_val}',
        f'proxmox_guest_cpus{{{labels}}} {cpus}',
        f'proxmox_guest_cpu_ratio{{{labels}}} {guest_data.get("cpu", 0)}',
        f'proxmox_guest_uptime_seconds{{{labels}}} {guest_data.get("uptime", 0)}',
        f'proxmox_guest_mem_bytes{{{labels}}} {guest_data.get("mem", 0)}',
        f'proxmox_guest_maxmem_bytes{{{labels}}} {guest_data.get("maxmem", 0)}',
        f'proxmox_guest_disk_bytes{{{labels}}} {guest_data.get("disk", 0)}',
        f'proxmox_guest_maxdisk_bytes{{{labels}}} {guest_data.get("maxdisk", 0)}',
        f'proxmox_guest_netin_bytes_total{{{labels}}} {guest_data.get("netin", 0)}',
        f'proxmox_guest_netout_bytes_total{{{labels}}} {guest_data.get("netout", 0)}',
        f'proxmox_guest_diskread_bytes_total{{{labels}}} {guest_data.get("diskread", 0)}',
        f'proxmox_guest_diskwrite_bytes_total{{{labels}}} {guest_data.get("diskwrite", 0)}',
        f'proxmox_guest_swap_bytes{{{labels}}} {guest_data.get("swap", 0)}',
        f'proxmox_guest_maxswap_bytes{{{labels}}} {guest_data.get("maxswap", 0)}'
    ]
    
    # Add guest agent disk usage (if available)
    if disk_usage:
        unique_filesystems = {}
        for fs in disk_usage:
            mountpoint = fs.get("mountpoint", "unknown")
            if mountpoint not in unique_filesystems:
                unique_filesystems[mountpoint] = fs
        
        for mountpoint, fs in unique_filesystems.items():
            total_bytes = fs.get("total-bytes", 0)
            used_bytes = fs.get("used-bytes", 0)
            available_bytes = total_bytes - used_bytes if total_bytes > used_bytes else 0
            
            clean_mountpoint = (mountpoint
                              .replace("\\", "\\\\")
                              .replace('"', '\\"')
                              .replace("\n", "\\n")
                              .replace("\t", "\\t"))
            
            filesystem_id = (mountpoint
                           .replace("/", "_")
                           .replace("\\", "_")
                           .replace(":", "_")
                           .replace(" ", "_")
                           .replace('"', "_")
                           .strip("_"))
            
            if not filesystem_id:
                filesystem_id = "root"
            
            fs_lbl = f'{labels},mountpoint="{clean_mountpoint}",filesystem="{filesystem_id}"'
            
            metrics.extend([
                f'proxmox_guest_vm_disk_total_bytes{{{fs_lbl}}} {total_bytes}',
                f'proxmox_guest_vm_disk_used_bytes{{{fs_lbl}}} {used_bytes}',
                f'proxmox_guest_vm_disk_available_bytes{{{fs_lbl}}} {available_bytes}'
            ])
    
    return metrics


@app.route("/pve")
def pve_metrics():
    """Optimized metrics endpoint with selective caching"""
    try:
        if not authenticate():
            return Response("# Auth failed\n", mimetype="text/plain"), 500
        
        all_metrics = []
        node_name = get_hostname()
        
        # Get real-time guest status
        guest_status = get_realtime_guest_status(node_name)
        
        # Process each VM
        for vmid, guest_data in guest_status.items():
            try:
                guest_type = guest_data["type"]
                
                # Get cached config data
                config_data = get_vm_config_cached(node_name, vmid, guest_type)
                
                # Get cached disk usage
                disk_usage = None
                if guest_type == "qemu" and guest_data.get("status") == "running":
                    disk_usage = get_guest_disk_usage_cached(node_name, vmid, guest_type)
                
                # Generate metrics
                guest_metrics = generate_guest_metrics(node_name, vmid, guest_data, config_data, disk_usage)
                all_metrics.extend(guest_metrics)
                
            except Exception:
                continue
        
        # Add cached storage metrics
        all_metrics.extend(get_storage_metrics_cached())
        
        # Add cached Ceph metrics
        all_metrics.extend(get_ceph_metrics_cached())
        
        # Add REAL-TIME host metrics (no caching)
        all_metrics.extend(get_host_resources_realtime(node_name))
        
        return Response("\n".join(all_metrics) + "\n", mimetype="text/plain")
        
    except Exception as e:
        return Response(f"# Error: {str(e)}\n", mimetype="text/plain"), 500


@app.route("/health")
def health_check():
    return Response("OK\n", mimetype="text/plain")

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=PORT, threaded=True)

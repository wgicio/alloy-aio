#!/usr/bin/env python3

"""
Proxmox guest metrics exporter for Prometheus (OPTIMIZED)
- Authenticates to local Proxmox API
- Exposes guest metrics at http://localhost:9221/pve
- Provides comprehensive metrics including CPU, memory, disk, network, utilization stats, swap, OS info
- Requires: requests, flask
"""

import os
import requests
import traceback
import time
from functools import lru_cache
from flask import Flask, Response
import urllib3
import logging
from concurrent.futures import ThreadPoolExecutor, as_completed
from threading import Lock

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Config
PROXMOX_HOST = os.environ.get("PROXMOX_HOST", "localhost")
PROXMOX_PASS = os.environ.get("PROXMOX_PASS", "")
VERIFY_SSL = False
PORT = 9221

# Support both split and single env var for API token
PVE_API_TOKEN = os.environ.get("PVE_API_TOKEN")
PROXMOX_USER = os.environ.get("PROXMOX_USER")
PROXMOX_TOKEN_NAME = os.environ.get("PROXMOX_TOKEN_NAME")
PROXMOX_TOKEN_VALUE = os.environ.get("PROXMOX_TOKEN_VALUE")

# Load environment variables from dedicated config file
def load_env_file():
    env_file = "/etc/alloy/pve-guest-exporter/pve-guest-exporter.env"
    max_retries = 3
    retry_delay = 1
    
    for attempt in range(max_retries):
        if os.path.exists(env_file):
            try:
                with open(env_file, 'r') as f:
                    for line in f:
                        line = line.strip()
                        if line and not line.startswith('#') and '=' in line:
                            key, value = line.split('=', 1)
                            os.environ[key] = value
                return True
            except Exception as e:
                print(f"Error reading env file: {e}")
        
        if attempt < max_retries - 1:
            print(f"Env file not ready, retrying in {retry_delay}s...")
            time.sleep(retry_delay)
    
    return False

# Load environment file at startup
load_env_file()

# Reload environment variables after loading file
PVE_API_TOKEN = os.environ.get("PVE_API_TOKEN")
PROXMOX_USER = os.environ.get("PROXMOX_USER")
PROXMOX_TOKEN_NAME = os.environ.get("PROXMOX_TOKEN_NAME")
PROXMOX_TOKEN_VALUE = os.environ.get("PROXMOX_TOKEN_VALUE")

def parse_pve_api_token(token):
    """Parse PVE API token format: user@realm!tokenid=uuid"""
    try:
        if not token:
            return None, None, None
        user, rest = token.split('!', 1)
        tokenid, uuid = rest.split('=')
        return user, tokenid, uuid
    except Exception:
        return None, None, None

app = Flask(__name__)

# Suppress Flask and Werkzeug debug/info logs in production
logging.getLogger('werkzeug').setLevel(logging.WARNING)
logging.getLogger('flask').setLevel(logging.WARNING)

# Optimized session with connection pooling
session = requests.Session()
session.headers.update({
    'Connection': 'keep-alive',
    'Keep-Alive': 'timeout=60, max=100'
})

# Configure connection pool
adapter = requests.adapters.HTTPAdapter(
    pool_connections=20,
    pool_maxsize=50,
    max_retries=2,
    pool_block=False
)
session.mount('https://', adapter)


# Global caches
os_type_cache = {}
OS_TYPE_CACHE_TTL = 300
auth_valid_until = 0
auth_lock = Lock()
disk_usage_cache = {} 
DISK_USAGE_CACHE_TTL = 60

@lru_cache(maxsize=2000)
def get_cached_vm_config(node_name, vmid, guest_type, cache_time_slot):
    """Cache VM config data (OS type and CPU count) for 5 minutes"""
    cache_key = f"{node_name}:{guest_type}:{vmid}"
    current_time = time.time()
    
    # Check in-memory cache first
    if cache_key in os_type_cache:
        cached_data, timestamp = os_type_cache[cache_key]
        if current_time - timestamp < OS_TYPE_CACHE_TTL:
            return cached_data
    
    # Fetch fresh config data
    try:
        config_resp = session.get(
            f"https://{PROXMOX_HOST}:8006/api2/json/nodes/{node_name}/{guest_type}/{vmid}/config",
            verify=VERIFY_SSL, timeout=3
        )
        
        ostype = "unknown"
        cpus = 0
        
        if config_resp.ok:
            config = config_resp.json()["data"]
            
            # Get OS type
            ostype = config.get("ostype", "unknown")
            if ostype == "unknown" and guest_type == "lxc":
                ostype = config.get("hostname", "unknown")
            
            # Get CPU count
            if guest_type == "qemu":
                # For QEMU VMs
                cpus = config.get("cores", 1) * config.get("sockets", 1)
            else:
                # For LXC containers
                cpus = config.get("cores", 1)
        
        # Cache both values
        result = {"ostype": ostype, "cpus": cpus}
        os_type_cache[cache_key] = (result, current_time)
        return result
        
    except Exception:
        # Return cached value if API fails
        if cache_key in os_type_cache:
            return os_type_cache[cache_key][0]
        return {"ostype": "unknown", "cpus": 0}

def proxmox_login():
    """Optimized authentication with caching"""
    global auth_valid_until
    
    with auth_lock:
        current_time = time.time()
        
        # Check if we have valid authentication
        if current_time < auth_valid_until:
            return True
        
        # Prefer split env vars, fallback to PVE_API_TOKEN
        user = PROXMOX_USER
        token_name = PROXMOX_TOKEN_NAME
        token_value = PROXMOX_TOKEN_VALUE

        if not (user and token_name and token_value) and PVE_API_TOKEN:
            user, token_name, token_value = parse_pve_api_token(PVE_API_TOKEN)

        if user and token_name and token_value:
            session.headers["Authorization"] = f"PVEAPIToken={user}!{token_name}={token_value}"
            auth_valid_until = current_time + 3600  # Valid for 1 hour
            return True
        elif PROXMOX_PASS and PROXMOX_USER:
            try:
                resp = session.post(
                    f"https://{PROXMOX_HOST}:8006/api2/json/access/ticket",
                    data={"username": PROXMOX_USER, "password": PROXMOX_PASS},
                    verify=VERIFY_SSL,
                    timeout=10
                )
                if resp.ok:
                    data = resp.json()["data"]
                    session.cookies.set("PVEAuthCookie", data["ticket"])
                    session.headers["CSRFPreventionToken"] = data["CSRFPreventionToken"]
                    auth_valid_until = current_time + 3600
                    return True
            except Exception as e:
                print(f"Password authentication failed: {e}")
        
        return False

def format_labels(node_name, vmid, name, ostype="unknown"):
    """Pre-format labels for metrics"""
    return f'node="{node_name}",vmid="{vmid}",name="{name}",ostype="{ostype}"'

def get_guest_disk_usage(node_name, vmid, guest_type):
    """Get actual disk usage from inside the guest using QEMU agent."""
    if guest_type != "qemu":
        return None
    
    try:
        url = f"https://{PROXMOX_HOST}:8006/api2/json/nodes/{node_name}/qemu/{vmid}/agent/get-fsinfo"
        fsinfo_resp = session.get(url, verify=VERIFY_SSL, timeout=10)
        
        if fsinfo_resp.status_code == 200:
            json_data = fsinfo_resp.json()
            # FIX: Access the nested 'result' array inside 'data'
            if isinstance(json_data, dict) and "data" in json_data:
                result_data = json_data["data"]
                if isinstance(result_data, dict) and "result" in result_data:
                    return result_data["result"]
            return None
        else:
            if fsinfo_resp.status_code != 200:
                print(f"WARNING: Guest agent unavailable for VM {vmid}")
            return None
            
    except Exception as e:
        print(f"ERROR: Guest agent failed for VM {vmid}: {e}")
        return None

@lru_cache(maxsize=500)
def get_cached_guest_disk_usage(node_name, vmid, guest_type, cache_time_slot):
    """Cache disk usage for 1 minute to improve performance"""
    if guest_type != "qemu":
        return None
        
    cache_key = f"{node_name}:{vmid}:disk"
    current_time = time.time()
    
    # Check in-memory cache first
    if cache_key in disk_usage_cache:
        cached_data, timestamp = disk_usage_cache[cache_key]
        if current_time - timestamp < DISK_USAGE_CACHE_TTL:
            return cached_data
    
    # Get fresh disk usage data
    disk_usage = get_guest_disk_usage(node_name, vmid, guest_type)
    
    # Cache the result
    disk_usage_cache[cache_key] = (disk_usage, current_time)
    return disk_usage


def add_guest_metrics(metrics, lbl, st, disk_usage=None):
    """Enhanced metrics generation with proper filesystem deduplication"""
    # Pre-calculate values to avoid repeated dict lookups
    status_val = 1 if st.get("status") == "running" else 0
    cpu_ratio = st.get("cpu", 0)
    uptime = st.get("uptime", 0)
    mem = st.get("mem", 0)
    maxmem = st.get("maxmem", 0)
    disk = st.get("disk", 0)
    maxdisk = st.get("maxdisk", 0)
    netin = st.get("netin", 0)
    netout = st.get("netout", 0)
    diskread = st.get("diskread", 0)
    diskwrite = st.get("diskwrite", 0)
    swap = st.get("swap", 0)
    maxswap = st.get("maxswap", 0)
    cpus = st.get("cpus", 0)
    
    # Bulk append basic metrics
    metrics.extend([
        f'proxmox_guest_status{{{lbl}}} {status_val}',
        f'proxmox_guest_cpus{{{lbl}}} {cpus}',
        f'proxmox_guest_cpu_ratio{{{lbl}}} {cpu_ratio}',
        f'proxmox_guest_uptime_seconds{{{lbl}}} {uptime}',
        f'proxmox_guest_mem_bytes{{{lbl}}} {mem}',
        f'proxmox_guest_maxmem_bytes{{{lbl}}} {maxmem}',
        f'proxmox_guest_disk_bytes{{{lbl}}} {disk}',
        f'proxmox_guest_maxdisk_bytes{{{lbl}}} {maxdisk}',
        f'proxmox_guest_netin_bytes_total{{{lbl}}} {netin}',
        f'proxmox_guest_netout_bytes_total{{{lbl}}} {netout}',
        f'proxmox_guest_diskread_bytes_total{{{lbl}}} {diskread}',
        f'proxmox_guest_diskwrite_bytes_total{{{lbl}}} {diskwrite}',
        f'proxmox_guest_swap_bytes{{{lbl}}} {swap}',
        f'proxmox_guest_maxswap_bytes{{{lbl}}} {maxswap}'
    ])
    
    # Add internal disk metrics from guest agent with deduplication
    if disk_usage:
        # Use dictionary to deduplicate by mountpoint
        unique_filesystems = {}
        
        for fs in disk_usage:
            mountpoint = fs.get("mountpoint", "unknown")
            
            # Deduplicate by mountpoint - keep the first occurrence
            if mountpoint not in unique_filesystems:
                unique_filesystems[mountpoint] = fs
            else:
                continue
        
        # Process only unique filesystems
        for mountpoint, fs in unique_filesystems.items():
            total_bytes = fs.get("total-bytes", 0)
            used_bytes = fs.get("used-bytes", 0)
            
            # Calculate available bytes
            available_bytes = total_bytes - used_bytes if total_bytes > used_bytes else 0
            
            # FIXED: Proper label sanitization for Prometheus format
            # Clean mountpoint for use in metric labels (escape special chars)
            clean_mountpoint = (mountpoint
                            .replace("\\", "\\\\")  # Escape backslashes first
                            .replace('"', '\\"')    # Escape quotes
                            .replace("\n", "\\n")   # Escape newlines
                            .replace("\t", "\\t"))  # Escape tabs
            
            # Create filesystem identifier (no special chars for filesystem label)
            filesystem_id = (mountpoint
                            .replace("/", "_")
                            .replace("\\", "_")
                            .replace(":", "_")
                            .replace(" ", "_")
                            .replace('"', "_")
                            .strip("_"))
            if not filesystem_id:
                filesystem_id = "root"
            
            # Create properly escaped labels
            fs_lbl = f'{lbl},mountpoint="{clean_mountpoint}",filesystem="{filesystem_id}"'
            
            # Add filesystem metrics
            metrics.extend([
                f'proxmox_guest_vm_disk_total_bytes{{{fs_lbl}}} {total_bytes}',
                f'proxmox_guest_vm_disk_used_bytes{{{fs_lbl}}} {used_bytes}',
                f'proxmox_guest_vm_disk_available_bytes{{{fs_lbl}}} {available_bytes}'
            ])
            
            # Add utilization metric
            if total_bytes > 0:
                utilization = used_bytes / total_bytes
                metrics.append(f'proxmox_guest_vm_disk_utilization{{{fs_lbl}}} {utilization}')

    
    # Calculate utilization metrics only when needed
    if maxmem > 0:
        metrics.append(f'proxmox_guest_mem_utilisation{{{lbl}}} {mem / maxmem}')
    if maxdisk > 0:
        metrics.append(f'proxmox_guest_disk_utilisation{{{lbl}}} {disk / maxdisk}')
    if maxswap > 0:
        metrics.append(f'proxmox_guest_swap_utilisation{{{lbl}}} {swap / maxswap}')


def get_all_guest_status(node_name):
    """Get all guest status using optimized bulk + individual approach"""
    try:
        guest_status = {}
        
        # Step 1: Get bulk resource data (efficient)
        resources_resp = session.get(
            f"https://{PROXMOX_HOST}:8006/api2/json/cluster/resources",
            verify=VERIFY_SSL, timeout=15
        )
        
        if resources_resp.ok:
            resources = resources_resp.json()["data"]
            
            # Filter for guests on this node
            for resource in resources:
                if (resource.get("type") in ["qemu", "lxc"] and 
                    resource.get("node") == node_name):
                    
                    vmid = resource.get("vmid")
                    if vmid:
                        # Use bulk data as base
                        guest_status[vmid] = {
                            "vmid": vmid,
                            "name": resource.get("name", f"{resource.get('type', 'vm')}{vmid}"),
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
        
        # Step 2: Only get individual status for running VMs that need extra data
        missing_data_count = 0
        for vmid, guest_data in guest_status.items():
            if guest_data.get("status") == "running":
                # Check if we're missing MULTIPLE critical runtime data points
                missing_critical_data = (
                    guest_data.get("cpu", 0) == 0 and 
                    guest_data.get("mem", 0) == 0 and 
                    guest_data.get("uptime", 0) == 0
                )
                
                if missing_critical_data:
                    missing_data_count += 1
                    try:
                        guest_type = guest_data["type"]
                        status_resp = session.get(
                            f"https://{PROXMOX_HOST}:8006/api2/json/nodes/{node_name}/{guest_type}/{vmid}/status/current",
                            verify=VERIFY_SSL, timeout=3
                        )
                        
                        if status_resp.ok:
                            status_data = status_resp.json()["data"]
                            # Update only missing fields
                            guest_data.update({
                                "cpu": status_data.get("cpu", guest_data.get("cpu", 0)),
                                "uptime": status_data.get("uptime", guest_data.get("uptime", 0)),
                                "mem": status_data.get("mem", guest_data.get("mem", 0)),
                                "maxmem": status_data.get("maxmem", guest_data.get("maxmem", 0))
                            })
                            
                    except Exception as e:
                        print(f"Error getting detailed status for {guest_type} {vmid}: {e}")
                        continue

        return guest_status
        
    except Exception as e:
        print(f"Error getting guest status for {node_name}: {e}")
        return {}

# Metrics endpoint
@app.route("/pve")
def pve_metrics():
    try:
        if not proxmox_login():
            return Response("# Proxmox API auth failed\n", mimetype="text/plain"), 500

        # Get nodes once
        nodes_resp = session.get(
            f"https://{PROXMOX_HOST}:8006/api2/json/nodes",
            verify=VERIFY_SSL, timeout=10
        )
        
        if not nodes_resp.ok:
            return Response("# Failed to get nodes\n", mimetype="text/plain"), 500
            
        nodes = nodes_resp.json()["data"]
        all_metrics = []
        current_time_slot = int(time.time() / OS_TYPE_CACHE_TTL)
        
        # Get local node name
        import socket
        local_hostname = socket.gethostname()
        
        # Process only the local node
        for node in nodes:
            node_name = node["node"]
            
            # Skip non-local nodes
            if node_name != local_hostname:
                continue
                
            # Get all guest status for this node (already handles individual calls)
            guest_status = get_all_guest_status(node_name)
            
            if not guest_status:
                continue
            
            # Process all guests for this node and generate metrics
            for vmid, guest_data in guest_status.items():
                try:
                    guest_type = guest_data["type"]
                    name = guest_data["name"]
                    
                    # Get cached config data (OS type and CPU count)
                    config_data = get_cached_vm_config(node_name, vmid, guest_type, current_time_slot)
                    ostype = config_data["ostype"]
                    
                    # Override CPU count with cached value
                    guest_data["cpus"] = config_data["cpus"]
                    
                    # Get internal disk usage for running QEMU VMs (cached)
                    disk_usage = None
                    if guest_type == "qemu" and guest_data.get("status") == "running":
                        disk_cache_slot = int(time.time() / DISK_USAGE_CACHE_TTL)
                        disk_usage = get_cached_guest_disk_usage(node_name, vmid, guest_type, disk_cache_slot)
                    
                    # Generate metrics
                    guest_metrics = []
                    add_guest_metrics(guest_metrics, format_labels(node_name, vmid, name, ostype), guest_data, disk_usage)
                    all_metrics.extend(guest_metrics)
                    
                except Exception as e:
                    print(f"Error processing guest {vmid}: {e}")
                    continue

            # Break after processing local node (no need to check other nodes)
            break

        return Response("\n".join(all_metrics) + "\n", mimetype="text/plain")
        
    except Exception as e:
        print(f"Error in pve_metrics: {e}")
        tb = traceback.format_exc()
        return Response(f"# Internal error:\n{tb}", mimetype="text/plain"), 500



# Health check endpoint
@app.route("/health")
def health_check():
    return Response("OK\n", mimetype="text/plain")

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=PORT, threaded=True)
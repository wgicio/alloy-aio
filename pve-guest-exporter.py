#!/usr/bin/env python3
"""
Proxmox guest metrics exporter for Prometheus
- Authenticates to local Proxmox API
- Exposes guest metrics at http://localhost:9221/pve
- Provides comprehensive metrics including CPU, memory, disk, network, utilization stats, swap, OS info, and internal disk usage
- Requires: requests, flask
"""
import os
import requests
import traceback
from flask import Flask, Response
import urllib3
import logging
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


def parse_pve_api_token(token):
    # Format: user@realm!tokenid=uuid
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


# Session for API
session = requests.Session()


def proxmox_login():
    # Prefer split env vars, fallback to PVE_API_TOKEN
    user = PROXMOX_USER
    token_name = PROXMOX_TOKEN_NAME
    token_value = PROXMOX_TOKEN_VALUE
    #print(f"DEBUG: user={user} token_name={token_name} token_value={token_value} PVE_API_TOKEN={PVE_API_TOKEN}")
    if not (user and token_name and token_value) and PVE_API_TOKEN:
        user, token_name, token_value = parse_pve_api_token(PVE_API_TOKEN)
        print(f"DEBUG: parsed user={user} token_name={token_name} token_value={token_value}")
    if user and token_name and token_value:
        session.headers["Authorization"] = f"PVEAPIToken={user}!{token_name}={token_value}"
        return True
    elif PROXMOX_PASS and PROXMOX_USER:
        resp = session.post(f"https://{PROXMOX_HOST}:8006/api2/json/access/ticket", data={"username": PROXMOX_USER, "password": PROXMOX_PASS}, verify=VERIFY_SSL)
        if resp.ok:
            data = resp.json()["data"]
            session.cookies.set("PVEAuthCookie", data["ticket"])
            session.headers["CSRFPreventionToken"] = data["CSRFPreventionToken"]
            return True
    return False


def format_labels(node_name, vmid, name, ostype="unknown"):
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
            print(f"DEBUG: Guest agent API returned {fsinfo_resp.status_code} for VM {vmid}")
            return None
            
    except Exception as e:
        print(f"DEBUG: Exception calling guest agent for VM {vmid}: {e}")
        return None


def add_guest_metrics(metrics, lbl, st):
    """Append one line per metric we want to export."""
    # state & absolute counters straight from the API
    metrics.append(f'proxmox_guest_status{{{lbl}}} {1 if st["status"]=="running" else 0}')
    metrics.append(f'proxmox_guest_cpus{{{lbl}}} {st.get("cpus", 0)}')
    metrics.append(f'proxmox_guest_cpu_ratio{{{lbl}}} {st.get("cpu", 0)}')
    metrics.append(f'proxmox_guest_uptime_seconds{{{lbl}}} {st.get("uptime", 0)}')
    metrics.append(f'proxmox_guest_mem_bytes{{{lbl}}} {st.get("mem", 0)}')
    metrics.append(f'proxmox_guest_maxmem_bytes{{{lbl}}} {st.get("maxmem", 0)}')
    metrics.append(f'proxmox_guest_disk_bytes{{{lbl}}} {st.get("disk", 0)}')
    metrics.append(f'proxmox_guest_maxdisk_bytes{{{lbl}}} {st.get("maxdisk", 0)}')
    metrics.append(f'proxmox_guest_netin_bytes_total{{{lbl}}} {st.get("netin", 0)}')
    metrics.append(f'proxmox_guest_netout_bytes_total{{{lbl}}} {st.get("netout", 0)}')
    metrics.append(f'proxmox_guest_diskread_bytes_total{{{lbl}}} {st.get("diskread", 0)}')
    metrics.append(f'proxmox_guest_diskwrite_bytes_total{{{lbl}}} {st.get("diskwrite", 0)}')

    # Swap metrics (available for both QEMU and LXC)
    metrics.append(f'proxmox_guest_swap_bytes{{{lbl}}} {st.get("swap", 0)}')
    metrics.append(f'proxmox_guest_maxswap_bytes{{{lbl}}} {st.get("maxswap", 0)}')

    # derived utilisation gauges (PromQL ready)
    if st.get("maxmem"):
        mem_perc = st["mem"] / st["maxmem"]
        metrics.append(f'proxmox_guest_mem_utilisation{{{lbl}}} {mem_perc}')
    if st.get("maxdisk"):
        disk_perc = st["disk"] / st["maxdisk"]
        metrics.append(f'proxmox_guest_disk_utilisation{{{lbl}}} {disk_perc}')
    # Swap utilization (only if maxswap > 0)
    if st.get("maxswap") and st.get("maxswap") > 0:
        swap_perc = st.get("swap", 0) / st["maxswap"]
        metrics.append(f'proxmox_guest_swap_utilisation{{{lbl}}} {swap_perc}')


########### Disabled out for now, due to high cpu usage ############
def add_guest_disk_usage_metrics(metrics, lbl, node_name, vmid, guest_type):
    """Add guest-internal disk usage metrics."""
    fsinfo = get_guest_disk_usage(node_name, vmid, guest_type)
    
    if fsinfo and isinstance(fsinfo, list):
        for disk in fsinfo:
            # Get required fields
            mountpoint = disk.get('mountpoint')
            total_bytes = disk.get('total-bytes')
            used_bytes = disk.get('used-bytes')
            fs_type = disk.get('type', 'unknown')
            
            # Skip if no mountpoint or missing size data
            if not mountpoint or total_bytes is None or used_bytes is None:
                continue
                
            # Clean mountpoint for labels
            mountpoint_clean = mountpoint.replace('\\', '').replace(':', '').replace(' ', '_')
            if mountpoint_clean == '':
                mountpoint_clean = 'root'
                
            # Create labels
            disk_labels = f'{lbl},mountpoint="{mountpoint_clean}",fstype="{fs_type}"'
            
            # Add metrics
            available_bytes = total_bytes - used_bytes
            metrics.append(f'proxmox_guest_internal_disk_total_bytes{{{disk_labels}}} {total_bytes}')
            metrics.append(f'proxmox_guest_internal_disk_used_bytes{{{disk_labels}}} {used_bytes}')
            metrics.append(f'proxmox_guest_internal_disk_available_bytes{{{disk_labels}}} {available_bytes}')
            
            # Calculate utilization
            if total_bytes > 0:
                utilization = used_bytes / total_bytes
                metrics.append(f'proxmox_guest_internal_disk_utilization{{{disk_labels}}} {utilization}')


# Metrics endpoint
@app.route("/pve")
def pve_metrics():
    try:
        if not proxmox_login():
            return Response("# Proxmox API auth failed\n", mimetype="text/plain"), 500

        nodes = session.get(f"https://{PROXMOX_HOST}:8006/api2/json/nodes",
                            verify=VERIFY_SSL).json()["data"]
        metrics = []

        for node in nodes:
            node_name = node["node"]

            # Pull both VM lists first, then iterate
            for gtype in ("qemu", "lxc"):
                guests = session.get(
                    f"https://{PROXMOX_HOST}:8006/api2/json/nodes/{node_name}/{gtype}",
                    verify=VERIFY_SSL).json()["data"]

                for guest in guests:
                    vmid = guest["vmid"]
                    name = guest.get("name", f"{gtype}{vmid}")

                    # Get guest status
                    st = session.get(
                        f"https://{PROXMOX_HOST}:8006/api2/json/nodes/{node_name}/{gtype}/{vmid}/status/current",
                        verify=VERIFY_SSL).json()["data"]

                    # Get guest config for OS type
                    config_resp = session.get(
                        f"https://{PROXMOX_HOST}:8006/api2/json/nodes/{node_name}/{gtype}/{vmid}/config",
                        verify=VERIFY_SSL)
                    
                    ostype = "unknown"
                    if config_resp.ok:
                        config = config_resp.json()["data"]
                        # For both QEMU and LXC, check for ostype first
                        ostype = config.get("ostype", "unknown")
                        # For LXC, also check hostname if ostype is not available
                        if ostype == "unknown" and gtype == "lxc":
                            ostype = config.get("hostname", "unknown")

                    # Add standard hypervisor-level metrics
                    add_guest_metrics(metrics, format_labels(node_name, vmid, name, ostype), st)

                    ######### Commented out for now, due to high cpu usage #########                    
                    # # Add guest-internal disk metrics (QEMU VMs only)
                    # if gtype == "qemu":
                    #     add_guest_disk_usage_metrics(metrics, format_labels(node_name, vmid, name, ostype), 
                    #                                node_name, vmid, gtype)

        return Response("\n".join(metrics) + "\n", mimetype="text/plain")

    except Exception:
        tb = traceback.format_exc()
        return Response(f"# Internal error:\n{tb}", mimetype="text/plain"), 500


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=PORT)

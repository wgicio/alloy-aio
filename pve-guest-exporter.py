#!/usr/bin/env python3
"""
Minimal Proxmox guest metrics exporter for Prometheus
- Authenticates to local Proxmox API
- Exposes guest metrics at http://localhost:9221/pve
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

# Auth helper

def proxmox_login():
    # Prefer split env vars, fallback to PVE_API_TOKEN
    user = PROXMOX_USER
    token_name = PROXMOX_TOKEN_NAME
    token_value = PROXMOX_TOKEN_VALUE
    print(f"DEBUG: user={user} token_name={token_name} token_value={token_value} PVE_API_TOKEN={PVE_API_TOKEN}")
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

# Metrics endpoint
@app.route("/pve")
def pve_metrics():
    try:
        if not proxmox_login():
            return Response("# Proxmox API auth failed\n", mimetype="text/plain"), 500
        # Get nodes
        nodes = session.get(f"https://{PROXMOX_HOST}:8006/api2/json/nodes", verify=VERIFY_SSL).json()["data"]
        metrics = []
        for node in nodes:
            node_name = node["node"]
            # Get QEMU guests (VMs)
            qemu_guests = session.get(f"https://{PROXMOX_HOST}:8006/api2/json/nodes/{node_name}/qemu", verify=VERIFY_SSL).json()["data"]
            for guest in qemu_guests:
                vmid = guest["vmid"]
                name = guest.get("name", f"vm{vmid}")
                guest_type = "qemu"
                # Get status
                status = session.get(f"https://{PROXMOX_HOST}:8006/api2/json/nodes/{node_name}/{guest_type}/{vmid}/status/current", verify=VERIFY_SSL).json()["data"]
                # Example metrics
                metrics.append(f'proxmox_guest_status{{node="{node_name}",vmid="{vmid}",name="{name}"}} {1 if status["status"]=="running" else 0}')
                metrics.append(f'proxmox_guest_cpu{{node="{node_name}",vmid="{vmid}",name="{name}"}} {status.get("cpu",0)}')
                metrics.append(f'proxmox_guest_mem{{node="{node_name}",vmid="{vmid}",name="{name}"}} {status.get("mem",0)}')
                metrics.append(f'proxmox_guest_maxmem{{node="{node_name}",vmid="{vmid}",name="{name}"}} {status.get("maxmem",0)}')
                metrics.append(f'proxmox_guest_disk{{node="{node_name}",vmid="{vmid}",name="{name}"}} {status.get("disk",0)}')
                metrics.append(f'proxmox_guest_maxdisk{{node="{node_name}",vmid="{vmid}",name="{name}"}} {status.get("maxdisk",0)}')
            # Get LXC guests (containers)
            lxc_guests = session.get(f"https://{PROXMOX_HOST}:8006/api2/json/nodes/{node_name}/lxc", verify=VERIFY_SSL).json()["data"]
            for guest in lxc_guests:
                vmid = guest["vmid"]
                name = guest.get("name", f"ct{vmid}")
                guest_type = "lxc"
                # Get status
                status = session.get(f"https://{PROXMOX_HOST}:8006/api2/json/nodes/{node_name}/{guest_type}/{vmid}/status/current", verify=VERIFY_SSL).json()["data"]
                # Example metrics
                metrics.append(f'proxmox_guest_status{{node="{node_name}",vmid="{vmid}",name="{name}"}} {1 if status["status"]=="running" else 0}')
                metrics.append(f'proxmox_guest_cpu{{node="{node_name}",vmid="{vmid}",name="{name}"}} {status.get("cpu",0)}')
                metrics.append(f'proxmox_guest_mem{{node="{node_name}",vmid="{vmid}",name="{name}"}} {status.get("mem",0)}')
                metrics.append(f'proxmox_guest_maxmem{{node="{node_name}",vmid="{vmid}",name="{name}"}} {status.get("maxmem",0)}')
                metrics.append(f'proxmox_guest_disk{{node="{node_name}",vmid="{vmid}",name="{name}"}} {status.get("disk",0)}')
                metrics.append(f'proxmox_guest_maxdisk{{node="{node_name}",vmid="{vmid}",name="{name}"}} {status.get("maxdisk",0)}')
        return Response("\n".join(metrics)+"\n", mimetype="text/plain")
    except Exception as e:
        tb = traceback.format_exc()
        print(tb)
        return Response(f"# Internal error:\n{tb}", mimetype="text/plain"), 500

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=PORT)

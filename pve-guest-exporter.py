#!/usr/bin/env python3
"""
Proxmox guest metrics exporter for Prometheus
- Authenticates to local Proxmox API
- Exposes guest metrics at http://localhost:9221/pve
- Provides comprehensive metrics including CPU, memory, disk, network, and utilization stats
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


def format_labels(node_name, vmid, name):
    return f'node="{node_name}",vmid="{vmid}",name="{name}"'


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

    # derived utilisation gauges (PromQL ready)
    if st.get("maxmem"):
        mem_perc = st["mem"] / st["maxmem"]
        metrics.append(f'proxmox_guest_mem_utilisation{{{lbl}}} {mem_perc}')
    if st.get("maxdisk"):
        disk_perc = st["disk"] / st["maxdisk"]
        metrics.append(f'proxmox_guest_disk_utilisation{{{lbl}}} {disk_perc}')


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

                    st = session.get(
                        f"https://{PROXMOX_HOST}:8006/api2/json/nodes/{node_name}/{gtype}/{vmid}/status/current",
                        verify=VERIFY_SSL).json()["data"]

                    add_guest_metrics(metrics, format_labels(node_name, vmid, name), st)

        return Response("\n".join(metrics) + "\n", mimetype="text/plain")

    except Exception:
        tb = traceback.format_exc()
        return Response(f"# Internal error:\n{tb}", mimetype="text/plain"), 500


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=PORT)

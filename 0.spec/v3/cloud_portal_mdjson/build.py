#!/usr/bin/env python3
"""Simple web server for JSON/YAML visualization"""
import os
import sys
import signal
import subprocess
import webbrowser
from http.server import HTTPServer, SimpleHTTPRequestHandler

PORT = 8888
PID_FILE = "/tmp/cloud_portal_mdjson.pid"
DIR = os.path.dirname(os.path.abspath(__file__))

def run():
    """Start web server and open browser"""
    # Kill existing if running
    stop(silent=True)

    # Fork to background
    pid = os.fork()
    if pid > 0:
        # Parent: save PID and open browser
        with open(PID_FILE, 'w') as f:
            f.write(str(pid))
        print(f"Server started on http://localhost:{PORT}")
        print(f"PID: {pid}")
        webbrowser.open(f"http://localhost:{PORT}")
        return

    # Child: run server
    os.chdir(DIR)
    os.setsid()

    # Redirect stdout/stderr
    sys.stdout = open('/dev/null', 'w')
    sys.stderr = open('/dev/null', 'w')

    server = HTTPServer(('', PORT), SimpleHTTPRequestHandler)
    server.serve_forever()

def stop(silent=False):
    """Stop web server"""
    if not os.path.exists(PID_FILE):
        if not silent:
            print("Server not running")
        return

    try:
        with open(PID_FILE, 'r') as f:
            pid = int(f.read().strip())
        os.kill(pid, signal.SIGTERM)
        os.remove(PID_FILE)
        if not silent:
            print(f"Server stopped (PID: {pid})")
    except (ProcessLookupError, ValueError):
        os.remove(PID_FILE)
        if not silent:
            print("Server was not running")

def status():
    """Check server status"""
    if os.path.exists(PID_FILE):
        with open(PID_FILE, 'r') as f:
            pid = f.read().strip()
        print(f"Server running on http://localhost:{PORT} (PID: {pid})")
    else:
        print("Server not running")

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "run"

    if cmd == "run":
        run()
    elif cmd == "stop":
        stop()
    elif cmd == "status":
        status()
    else:
        print("Usage: ./build.py [run|stop|status]")

 
Secure VPS Architecture: Hardening Guide

1. High-Level Philosophy: "Blast Radius Containment"

The core principle of this architecture is Isolation. We assume that any public-facing service (like the website or analytics) could eventually be compromised. The goal is to ensure that if a breach occurs, the attacker is trapped in a tiny, disposable box and cannot access the Host OS or Private Data.

2. Network Security (The Outer Wall)

A. The Firewall (UFW)

We use UFW (Uncomplicated Firewall) as the first line of defense. It operates at the kernel level (iptables).

Policy: Default DENY incoming, ALLOW outgoing.

Open Ports (The "Doors"):

22/tcp (SSH) - Critical: Use Key-based auth only.

80/tcp (HTTP) - Redirects to HTTPS.

443/tcp (HTTPS) - The main entry point.

Blocked Ports: Everything else (e.g., 8080, 3306, 8081) must be blocked from the outside world.

B. The Docker-Firewall Conflict (The Trap)

The Risk: Docker modifies iptables directly. By default, docker run -p 8080:80 bypasses UFW and opens port 8080 to the entire internet.
The Solution (Used in this Arch): Localhost Binding.

We force Docker to listen only on the internal loopback interface.

Config: ports: - "127.0.0.1:8081:80"

Result: The internet cannot reach the container directly. Only the Host NGINX can reach it.

3. Traffic Routing (The Gatekeeper)

Host NGINX (Reverse Proxy)

This is the only software (besides SSH) allowed to talk to the internet.

Role: Termination of SSL/TLS.

Configuration:

Listens on 443.

Checks the Host header (e.g., mysite.com).

proxy_pass http://127.0.0.1:8081 -> Routes to Public Container.

proxy_pass http://127.0.0.1:8082 -> Routes to Private Container.

Benefit: NGINX filters malformed HTTP requests before they ever hit your application containers.

4. Compute Isolation (The Containers)

A. Network Segmentation (Internal Firewalls)

We use Docker Networks to create "Air Gaps" between applications.

public_net:

Members: public-site, matomo-app, matomo-db.

Rule: Allowed to talk to each other.

private_net:

Members: nextcloud-app, nextcloud-db.

Rule: internal: true (Optional). Only allows internal traffic.

Security: A hacker in matomo-app cannot ping nextcloud-db because no network route exists.

B. Container Hardening

Read-Only Filesystems:

For the Static Public Site, we mount the volume as read-only (:ro).

Effect: Even if an attacker finds an exploit, they cannot write a "backdoor" script to the file system.

Stateless vs. Stateful:

Static Site container is disposable. Restarting it wipes any temporary memory attacks.

5. Storage Isolation (The Vaults)

We separate data not just by folder, but by Filesystem Partition to prevent resource exhaustion (DoS).

Structure on Host (/)

System Partition (/): Contains OS, Docker Engine, NGINX Config.

Public Partition (/mnt/public_data):

Quota: Limited (e.g., 20GB).

Risk: If Matomo logs grow uncontrollably, they hit the 20GB limit and stop. The OS does not crash.

Private Partition (/mnt/private_data):

Security: Encrypted at rest (LUKS).

Permissions: chmod 700 (Only Root can read).

Database Separation

NEVER run one MariaDB instance for both public and private data.

Always run two separate DB containers (matomo-db, nextcloud-db).

This prevents configuration errors (granting too many permissions) from exposing private tables to public apps.

6. Implementation Checklist

[ ] Provision VPS with SSH Key access only (Disable Password Auth).

[ ] Setup UFW: Allow 22, 80, 443. Enable firewall.

[ ] Partition Disks: Create LVM logical volumes for /mnt/public and /mnt/private.

[ ] Install Docker & NGINX (Host).

[ ] Create Docker Networks: docker network create public_net etc.

[ ] Deploy Containers: Ensure 127.0.0.1 binding in docker-compose.yml.

[ ] Configure Host NGINX: Set up proxy_pass blocks for each domain.

[ ] SSL: Run Certbot (Let's Encrypt) on the Host NGINX.

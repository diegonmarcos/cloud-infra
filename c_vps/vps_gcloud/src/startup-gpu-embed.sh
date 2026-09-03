#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ GCP GPU-embed VM bootstrap — runs on every boot via metadata      ║
# ║ Source: c_vps/vps_gcloud/src/startup-gpu-embed.sh                 ║
# ║ Wired:  c_vps/vps_gcloud/src/main.tf metadata.startup-script      ║
# ║         (selected instead of bootstrap.sh whenever an instance    ║
# ║         declares a `gpu` block in terraform.json)                 ║
# ║                                                                    ║
# ║ Brings a bare Ubuntu 22.04 + NVIDIA GPU (L4/T4) instance up to     ║
# ║ serving OpenAI-shaped POST /v1/embeddings (ollama + nomic-embed-text)║
# ║ behind a bearer-token Caddy reverse proxy on :443, PLAIN HTTP      ║
# ║ (no TLS — the bearer token is the security boundary here, not     ║
# ║ transport encryption; see project_gpu-embed-t4 memory for why:    ║
# ║ a self-signed cert would need the GHA runner to skip verification,║
# ║ and there is no DNS name here for a real one).                    ║
# ║                                                                    ║
# ║ This VM is NOT a home-manager fleet member — no HM, no WireGuard  ║
# ║ mesh join, no dashboard/watchdog. It exists ONLY to answer the     ║
# ║ octocode `local:` embedding provider from the cgc-db-index.yml     ║
# ║ semantic-phase runner job, and is started/stopped around that job ║
# ║ via the C3 API (devops_vm_start/stop) — see cgc-db-index.yml.      ║
# ║                                                                    ║
# ║ Idempotent + resumable across the one reboot the NVIDIA driver     ║
# ║ install requires: GCE re-invokes this script on EVERY boot, and    ║
# ║ each step is marker-gated (driver) or self-reconciling (docker     ║
# ║ containers, Caddyfile — rm+recreate every boot, cheap once images  ║
# ║ are cached) so a resumed OR repeated run only does what is left,   ║
# ║ and a config fix (this file changing under an unchanged instance)  ║
# ║ actually takes effect on the next `gcloud compute instances reset` ║
# ║ instead of being silently skipped by a blanket "already done"      ║
# ║ marker — see 2026-09-03 cross-container-loopback incident below.   ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eu

log() { echo "[gpu-embed] $1" | systemd-cat -t gpu-embed-bootstrap -p info 2>/dev/null || true; echo "[gpu-embed] $1"; }

MDATA() { curl -sf -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" 2>/dev/null || true; }

MARKER_DRIVER=/var/lib/gpu-embed-driver.done
MARKER_ALL=/var/lib/gpu-embed-bootstrap.done

# ── 1. NVIDIA driver ──────────────────────────────────────────────────
# Ubuntu's own ubuntu-drivers-common picks the right proprietary driver for
# the attached GPU (L4 or T4) — this is Google's documented apt install path
# (cloud.google.com/compute/docs/gpus/install-drivers-gpu, Ubuntu section).
# A driver install needs a reboot before nvidia-smi works; MARKER_DRIVER
# records that the apt step ran so a post-reboot re-invocation of this same
# script (GCE runs startup-script on every boot) does not repeat it and
# instead falls straight through to the nvidia-smi check below.
if ! command -v nvidia-smi >/dev/null 2>&1; then
  if [ ! -f "$MARKER_DRIVER" ]; then
    log "1/5 installing NVIDIA driver (ubuntu-drivers autoinstall)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends ubuntu-drivers-common
    ubuntu-drivers autoinstall
    touch "$MARKER_DRIVER"
    log "driver packages installed — rebooting to load the kernel module"
    systemctl reboot
    exit 0
  fi
  log "1/5 driver was installed pre-reboot but nvidia-smi still absent — check 'nvidia-smi' / dmesg by hand"
  exit 1
fi
log "1/5 NVIDIA driver active: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null || echo present)"

# ── 2. Docker + nvidia-container-toolkit ────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  log "2/5 installing docker"
  curl -fsSL https://get.docker.com | sh
fi
if ! dpkg -l 2>/dev/null | grep -q nvidia-container-toolkit; then
  log "2/5 installing nvidia-container-toolkit"
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -y
  apt-get install -y nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
fi
systemctl enable --now docker

# ── 3. ollama (GPU) — bound to loopback only, Caddy is the only ingress ──
# --network host (not the default bridge + `-p 127.0.0.1:11434:11434`):
# a `-p 127.0.0.1:...` publish binds the HOST's loopback only, which is
# reachable from processes ON the host but NOT from another container on
# the docker bridge network (its "127.0.0.1" is its own netns loopback, a
# different address entirely) — caddy (below) crash-looped trying to
# reverse_proxy there, connection refused every time (2026-09-03, found via
# serial console: dockerd "restarting container ... exitCode=1 ... restart
# Count=8"). --network host makes both containers share the HOST's network
# namespace directly, so ollama's own bind (OLLAMA_HOST, forced to
# 127.0.0.1 here to keep it off the public interface) and caddy's
# 127.0.0.1:11434 upstream are the SAME address for real.
log "3/5 ollama container"
docker rm -f ollama >/dev/null 2>&1 || true
docker run -d --name ollama --restart unless-stopped --gpus all \
  --network host \
  -e OLLAMA_HOST=127.0.0.1:11434 \
  -v ollama_data:/root/.ollama \
  ollama/ollama:latest
for _i in 1 2 3 4 5 6 7 8 9 10; do
  curl -sf http://127.0.0.1:11434/ >/dev/null 2>&1 && break
  sleep 3
done
log "3/5 pulling nomic-embed-text (= nomic-embed-text-v1.5, 768-d — same vectors as the box's fastembed:nomic-ai/nomic-embed-text-v1.5, see cloud-cgc-db-update.sh)"
docker exec ollama ollama pull nomic-embed-text || log "WARNING: model pull failed — will retry on next boot"

# ── 4. Caddy — bearer-auth reverse proxy, PLAIN HTTP on :443 ────────────
log "4/5 caddy bearer-auth proxy"
TOKEN="$(MDATA embed-bearer-token)"
if [ -z "$TOKEN" ]; then
  log "WARNING: no embed-bearer-token in instance metadata — proxy will reject everything until it is set (see main.tf var.gpu_embed_bearer_token)"
  TOKEN="unset-$(date +%s)"
fi
mkdir -p /etc/caddy
cat > /etc/caddy/Caddyfile <<CADDYEOF
http://:443 {
	@authed header Authorization "Bearer ${TOKEN}"
	handle @authed {
		reverse_proxy 127.0.0.1:11434
	}
	handle {
		respond "unauthorized" 401
	}
}
CADDYEOF
docker rm -f caddy-embed >/dev/null 2>&1 || true
# ENTRYPOINT of the official caddy:2 image is already ["caddy"] — passing
# "caddy run ..." as the trailing args here would duplicate it into
# `caddy caddy run ...`, which caddy rejects as an unknown subcommand and
# exits 1 immediately (2026-09-03: this, not --network, was the real crash-
# loop cause — dockerd "restarting container ... exitCode=1" every ~2-7s,
# confirmed via serial console after --network host alone did not fix it).
# Only the CMD portion (run --config ... --adapter caddyfile) belongs here.
docker run -d --name caddy-embed --restart unless-stopped \
  --network host \
  -v /etc/caddy/Caddyfile:/etc/caddy/Caddyfile:ro \
  caddy:2 run --config /etc/caddy/Caddyfile --adapter caddyfile

# ── 5. Done ──────────────────────────────────────────────────────────────
log "5/5 done — POST http://<external-ip>:443/v1/embeddings with 'Authorization: Bearer <token>'"
touch "$MARKER_ALL"

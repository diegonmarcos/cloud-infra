# Vast.ai Ollama - Quick Start Guide

## 🚀 Complete Setup in 5 Steps

### Step 1: Create Vast.ai Account

1. Go to [vast.ai](https://vast.ai/)
2. Sign up with: `me@diegonmarcos.com`
3. Add $10-20 credit at [Billing](https://vast.ai/console/billing/)

### Step 2: Add SSH Key

1. Go to [Account Settings](https://vast.ai/console/account/)
2. Click "Change SSH Key" or "Add SSH Key"
3. Paste your public key:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILHv4vbpBAxwo4C6pLR1r4qbfxDFc2GlOZn2DFNQA7HM diego@diego-surfacepro8
```

### Step 3: Rent GPU Instance

1. **Go to**: [Vast.ai Search](https://vast.ai/console/create/)

2. **Filter**:
   - GPU: `RTX A4000` (or `RTX 4090` for more power)
   - VRAM: ≥ 16GB
   - Disk: ≥ 30GB
   - RAM: ≥ 16GB
   - Sort: **Price (Low to High)**

3. **Template**: Select **"Open WebUI (Ollama)"** (pre-configured)
   - Alternative: Ubuntu 22.04 with CUDA (manual install)

4. **Options**:
   - ✅ Enable SSH
   - ✅ Enable Jupyter (optional)
   - Disk: **30GB minimum**

5. **Click "Rent"** - Expected cost: **$0.08-0.25/hr**

### Step 4: Update SSH Config

Once instance starts (~5 min):

1. **Get connection info** from [Instances Console](https://vast.ai/console/instances/)
2. Click **"Connect"** on your instance
3. Copy the SSH command (looks like: `ssh -p 12345 root@ssh4.vast.ai`)

4. **Update SSH config**:

```bash
# Edit your SSH config
nano ~/git/vault/A0_keys/config_mobile

# Add this entry (update HostName and Port from Vast.ai):
Host vast-ollama
    HostName ssh4.vast.ai          # Replace with your actual host
    Port 12345                      # Replace with your actual port
    User root
    IdentityFile /data/data/com.termux.nix/files/home/git/vault/A0_keys/ssh/id_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 60
```

See template: `~/git/cloud/b_infra/vm_vast-RTX-p_0/1.os/ssh-config-template`

### Step 5: Connect & Setup

```bash
# Test connection
ssh vast-ollama

# Run setup script (on remote instance)
curl -fsSL https://raw.githubusercontent.com/diegonmarcos/cloud/main/b_infra/vm_vast-RTX-p_0/2.setup/vast-ollama-setup.sh | bash

# Or if you already cloned this repo on the instance:
/path/to/cloud/b_infra/vm_vast-RTX-p_0/2.setup/vast-ollama-setup.sh
```

**Manual setup** (if script fails):

```bash
# 1. Verify GPU
nvidia-smi

# 2. Install Ollama (if not using pre-configured template)
curl -fsSL https://ollama.com/install.sh | sh

# 3. Start service
OLLAMA_HOST=0.0.0.0:11434 ollama serve > /var/log/ollama.log 2>&1 &

# 4. Pull a model
ollama pull llama2:13b

# 5. Test
ollama run llama2:13b
```

## 💰 Cost Tracking

| Usage | Hours/Month | Cost @ $0.10/hr | Cost @ $0.25/hr |
|-------|-------------|-----------------|-----------------|
| 4 hrs/day | 120 | **$12/month** | **$30/month** |
| 8 hrs/day | 240 | $24/month | $60/month |
| Always-on | 720 | $72/month | $180/month |

**IMPORTANT**: Stop instance when done!
- Go to [Instances](https://vast.ai/console/instances/) → **Stop**

## 📊 Cloud Infrastructure Integration

This VM is now tracked in your cloud infrastructure:

**Config**: `~/git/cloud/a_solutions/config.json`
```json
{
  "vast-RTX-p_0": {
    "ssh_alias": "vast-ollama",
    "description": "Vast.ai On-Demand - RTX A4000 (16GB VRAM) - Ollama LLM",
    "gpu": "RTX A4000",
    "cost_per_hour": "$0.08-0.25"
  }
}
```

**Service**: Ollama LLM
```json
{
  "ollama": {
    "category": "app",
    "vm": "vast-RTX-p_0",
    "description": "Ollama LLM Server (13B models)",
    "api_port": "11434"
  }
}
```

## 🔧 MCP Integration

Your `cloud-infra` MCP server can now manage this instance:

```typescript
// List all VMs (including Vast.ai)
await mcp.list_vms();

// Check Ollama service
await mcp.get_service_detail("ollama");

// SSH exec on Vast.ai instance
await mcp.ssh_exec("vast-ollama", "ollama list");
```

## 📚 Next Steps

- See full docs: [`README.md`](./README.md)
- Setup script: [`2.setup/vast-ollama-setup.sh`](./2.setup/vast-ollama-setup.sh)
- Model catalog: [ollama.com/library](https://ollama.com/library)

## 🆘 Troubleshooting

**Can't connect via SSH**:
- Check instance is running in [Console](https://vast.ai/console/instances/)
- Verify SSH key is added to your Vast.ai account
- Update HostName/Port in SSH config

**Ollama not found**:
- Use "Open WebUI (Ollama)" template when renting
- Or manually install: `curl -fsSL https://ollama.com/install.sh | sh`

**Out of VRAM**:
- Use smaller models: `ollama pull llama2:7b`
- Rent instance with more VRAM (RTX 4090 = 24GB)

**High costs**:
- **Always stop instance when done!**
- Use spot instances (60-90% cheaper, can be interrupted)
- Consider TensorDock or VAST.ai spot pricing

---

**Total Setup Time**: ~10 minutes
**Monthly Cost**: $9.60-30 (for 4hrs/day usage)
**GPU**: RTX A4000 (16GB VRAM)
**Models**: llama2:13b, mistral:13b, deepseek-r1:14b

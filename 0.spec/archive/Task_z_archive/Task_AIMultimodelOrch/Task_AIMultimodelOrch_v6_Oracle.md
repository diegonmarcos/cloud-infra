# AI VPS Deployment - DeepSeek 14B + ML Brain

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                      YOUR LOCAL MACHINE                         │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ ml-brain/                                                │   │
│  │ ├── brain.py collect    # Runs locally (no GPU)         │   │
│  │ ├── data/brain.db       # Your knowledge DB             │   │
│  │ └── sync to VPS when needed                             │   │
│  └─────────────────────────────────────────────────────────┘   │
│                              │                                  │
│                         rsync / scp                             │
│                              ↓                                  │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                    ORACLE VPS (Pay-per-use)                     │
│  Region: eu-frankfurt-1 (GPU) or eu-paris-1                    │
│                                                                  │
│  ┌──────────────────────┐    ┌──────────────────────┐          │
│  │  VM.GPU.A10.1        │    │  VM.Standard.A1.Flex │          │
│  │  (ON DEMAND)         │    │  (ALWAYS FREE)       │          │
│  │                      │    │                      │          │
│  │  DeepSeek 14B Q4     │    │  ML Brain Server     │          │
│  │  via Ollama          │    │  - Embeddings API    │          │
│  │  24GB VRAM           │    │  - Search API        │          │
│  │  $2/hr when ON       │    │  - 4 OCPU, 24GB RAM  │          │
│  │  $0.02/GB storage    │    │  - FREE TIER         │          │
│  │  when OFF            │    │                      │          │
│  └──────────────────────┘    └──────────────────────┘          │
│           ↓                            ↓                        │
│      Port 11434                   Port 8080                     │
│      (Ollama API)                 (Brain API)                   │
└─────────────────────────────────────────────────────────────────┘
```

## Instance Specifications

### 1. GPU Instance (DeepSeek) - Pay Per Use

| Spec | Value |
|------|-------|
| Shape | VM.GPU.A10.1 |
| Region | eu-frankfurt-1 |
| OCPUs | 15 |
| RAM | 240 GB |
| GPU | 1x NVIDIA A10 (24GB VRAM) |
| Storage | 100 GB boot + 50 GB data |
| **Cost Running** | ~$2.00/hr |
| **Cost Stopped** | ~$0.02/GB/mo = $3/mo for 150GB |

### 2. Free Instance (ML Brain) - Always On

| Spec | Value |
|------|-------|
| Shape | VM.Standard.A1.Flex (ARM) |
| Region | eu-frankfurt-1 |
| OCPUs | 4 (free tier max) |
| RAM | 24 GB (free tier max) |
| Storage | 100 GB boot |
| **Cost** | FREE (Always Free tier) |

## DeepSeek 14B Specs

```
Model: deepseek-coder-v2-lite-instruct (15.7B params)
Quantization: Q4_K_M
VRAM needed: ~9GB (fits easily in A10 24GB)
RAM needed: ~2GB additional
Tokens/sec: ~50-80 tok/s on A10
Context: 128k tokens (massive)
```

Alternative smaller models:
- `deepseek-coder:6.7b` - 4GB VRAM, faster
- `codellama:13b` - 8GB VRAM, good for code
- `qwen2.5-coder:14b` - 9GB VRAM, excellent quality

## Deployment Scripts

### Setup Script (run once)

```bash
#!/bin/bash
# /home/diego/scripts/ai-vps-setup.sh

# Variables
REGION="eu-frankfurt-1"
COMPARTMENT="ocid1.tenancy.oc1..aaaaaaaate22jsouuzgaw65ucwvufcj3lzjxw4ithwcz3cxw6iom6ys2ldsq"
SSH_KEY="/home/diego/Documents/Git/LOCAL_KEYS/00_terminal/ssh/id_rsa.pub"
AVAILABILITY_DOMAIN="${REGION}AD-1"

# GPU Instance (DeepSeek)
GPU_SHAPE="VM.GPU.A10.1"
GPU_IMAGE="ocid1.image.oc1.eu-frankfurt-1..." # Ubuntu 22.04 GPU

# Free Instance (ML Brain)
FREE_SHAPE="VM.Standard.A1.Flex"
FREE_IMAGE="ocid1.image.oc1.eu-frankfurt-1..." # Ubuntu 22.04 ARM

echo "Creating GPU instance for DeepSeek..."
oci compute instance launch \
    --region $REGION \
    --compartment-id $COMPARTMENT \
    --availability-domain $AVAILABILITY_DOMAIN \
    --shape $GPU_SHAPE \
    --display-name "ai-deepseek" \
    --image-id $GPU_IMAGE \
    --ssh-authorized-keys-file $SSH_KEY \
    --boot-volume-size-in-gbs 100 \
    --wait-for-state RUNNING

echo "Creating Free ARM instance for ML Brain..."
oci compute instance launch \
    --region $REGION \
    --compartment-id $COMPARTMENT \
    --availability-domain $AVAILABILITY_DOMAIN \
    --shape $FREE_SHAPE \
    --shape-config '{"ocpus": 4, "memoryInGBs": 24}' \
    --display-name "ai-brain" \
    --image-id $FREE_IMAGE \
    --ssh-authorized-keys-file $SSH_KEY \
    --boot-volume-size-in-gbs 100 \
    --wait-for-state RUNNING
```

### Control Scripts

```bash
#!/bin/bash
# /home/diego/scripts/ai-vps.sh
# Usage: ai-vps.sh [start|stop|status|ssh|sync]

DEEPSEEK_ID="ocid1.instance..." # Fill after creation
BRAIN_ID="ocid1.instance..."    # Fill after creation
SSH_KEY="/home/diego/Documents/Git/LOCAL_KEYS/00_terminal/ssh/id_rsa"

case "$1" in
    start)
        echo "Starting DeepSeek GPU instance..."
        oci compute instance action --action START --instance-id $DEEPSEEK_ID
        echo "Waiting for instance to boot (~2 min)..."
        sleep 120
        IP=$(oci compute instance list-vnics --instance-id $DEEPSEEK_ID --query 'data[0]."public-ip"' --raw-output)
        echo "DeepSeek available at: $IP:11434"
        ;;
    stop)
        echo "Stopping DeepSeek GPU instance..."
        oci compute instance action --action STOP --instance-id $DEEPSEEK_ID
        echo "Stopped. Now paying only for storage (~$3/month)"
        ;;
    status)
        echo "=== DeepSeek GPU Instance ==="
        oci compute instance get --instance-id $DEEPSEEK_ID --query 'data.{"state":"lifecycle-state","name":"display-name"}'
        echo ""
        echo "=== ML Brain Instance ==="
        oci compute instance get --instance-id $BRAIN_ID --query 'data.{"state":"lifecycle-state","name":"display-name"}'
        ;;
    ssh-deepseek)
        IP=$(oci compute instance list-vnics --instance-id $DEEPSEEK_ID --query 'data[0]."public-ip"' --raw-output)
        ssh -i $SSH_KEY ubuntu@$IP
        ;;
    ssh-brain)
        IP=$(oci compute instance list-vnics --instance-id $BRAIN_ID --query 'data[0]."public-ip"' --raw-output)
        ssh -i $SSH_KEY ubuntu@$IP
        ;;
    sync)
        echo "Syncing ML Brain database to VPS..."
        IP=$(oci compute instance list-vnics --instance-id $BRAIN_ID --query 'data[0]."public-ip"' --raw-output)
        rsync -avz ~/ml-brain/data/brain.db ubuntu@$IP:~/ml-brain/data/
        ;;
    *)
        echo "Usage: $0 {start|stop|status|ssh-deepseek|ssh-brain|sync}"
        exit 1
        ;;
esac
```

## Post-Creation Setup

### On GPU Instance (DeepSeek)

```bash
# Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Pull DeepSeek model
ollama pull deepseek-coder-v2-lite-instruct

# Alternatively, smaller/faster models:
# ollama pull deepseek-coder:6.7b
# ollama pull qwen2.5-coder:14b

# Start Ollama server (bind to all interfaces)
OLLAMA_HOST=0.0.0.0 ollama serve &

# Test
curl http://localhost:11434/api/generate -d '{
  "model": "deepseek-coder-v2-lite-instruct",
  "prompt": "Write a Python function to calculate fibonacci"
}'
```

### On Free Instance (ML Brain)

```bash
# Clone project
git clone https://github.com/yourusername/ml-brain.git
cd ml-brain

# Install dependencies (ARM compatible)
pip3 install --user requests

# Create systemd service for Brain API
sudo tee /etc/systemd/system/ml-brain.service << 'EOF'
[Unit]
Description=ML Brain Knowledge Server
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/ml-brain
ExecStart=/usr/bin/python3 /home/ubuntu/ml-brain/server.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable ml-brain
sudo systemctl start ml-brain
```

## Cost Analysis

### Scenario A: Light Usage (2 hrs/day)

| Item | Cost |
|------|------|
| GPU running | 2 hrs × $2 × 30 days = **$120/mo** |
| GPU storage | 150GB × $0.02 = **$3/mo** |
| Brain instance | **FREE** |
| **Total** | **~$123/month** |

### Scenario B: Heavy Usage (8 hrs/day)

| Item | Cost |
|------|------|
| GPU running | 8 hrs × $2 × 30 days = **$480/mo** |
| GPU storage | **$3/mo** |
| Brain instance | **FREE** |
| **Total** | **~$483/month** |

### Scenario C: Weekend Projects (8 hrs/weekend)

| Item | Cost |
|------|------|
| GPU running | 8 hrs × $2 × 4 weekends = **$64/mo** |
| GPU storage | **$3/mo** |
| Brain instance | **FREE** |
| **Total** | **~$67/month** |

## Alternative: CPU-Only (Cheaper but Slower)

If GPU is too expensive, run DeepSeek on CPU:

```bash
# On VM.Standard.E4.Flex (16 OCPUs, 64GB RAM)
# Cost: ~$0.025/OCPU/hr = $0.40/hr

# DeepSeek 14B Q4 on CPU:
# - ~5-10 tokens/sec (usable but slow)
# - Needs ~16GB RAM

# Monthly cost (2 hrs/day): $24/mo
```

## Security

### Firewall Rules

```bash
# On GPU instance - only allow from your IP
sudo ufw allow from YOUR_IP to any port 11434

# On Brain instance - allow from GPU and your IP
sudo ufw allow from GPU_PRIVATE_IP to any port 8080
sudo ufw allow from YOUR_IP to any port 8080
```

### API Keys

Store in `/home/ubuntu/.env`:
```bash
OLLAMA_API_KEY=your_random_key
BRAIN_API_KEY=your_random_key
```

## Quick Reference Commands

```bash
# Start GPU for AI work
~/scripts/ai-vps.sh start

# Query DeepSeek
curl http://GPU_IP:11434/api/generate -d '{
  "model": "deepseek-coder-v2-lite-instruct",
  "prompt": "Explain this code: ..."
}'

# Stop GPU when done (saves money!)
~/scripts/ai-vps.sh stop

# Sync knowledge DB
~/scripts/ai-vps.sh sync

# Check status
~/scripts/ai-vps.sh status
```

## Integration with v5 Philosophy

This setup follows **v5 (Radical Simplicity)**:

1. **No complex orchestration** - Just Ollama + simple API
2. **Pay for what you use** - Stop when not using
3. **Keep knowledge local** - brain.db stays on your machine
4. **API-based embeddings** - Use OpenAI/Voyage, not local GPU
5. **One model for inference** - DeepSeek for experimentation, Sonnet for production

**When to use DeepSeek:**
- Experimentation/learning
- Privacy-sensitive queries
- Offline scenarios
- Cost-sensitive bulk processing

**When to use Claude Sonnet:**
- Production work
- Complex reasoning
- Speed matters

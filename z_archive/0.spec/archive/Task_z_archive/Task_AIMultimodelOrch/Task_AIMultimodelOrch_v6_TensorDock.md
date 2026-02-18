# AI Deployment - TensorDock + Oracle Free Tier

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      YOUR LOCAL MACHINE                         │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ ml-brain/                                                │   │
│  │ ├── brain.py collect    # Collect data locally          │   │
│  │ └── data/brain.db       # Sync to VPS when needed       │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              ↓                               ↓
┌─────────────────────────────┐  ┌─────────────────────────────┐
│     TENSORDOCK (EU)         │  │   ORACLE FREE TIER          │
│     Pay-per-use             │  │   Always Free               │
│                             │  │                             │
│  ┌───────────────────────┐  │  │  ┌───────────────────────┐  │
│  │  RTX 4090 VM          │  │  │  │  VM.Standard.A1.Flex  │  │
│  │  DeepSeek 14B         │  │  │  │  ML Brain Server      │  │
│  │  $0.35/hr             │  │  │  │  4 OCPU, 24GB RAM     │  │
│  │  Full VM access       │  │  │  │  FREE forever         │  │
│  └───────────────────────┘  │  │  └───────────────────────┘  │
│       Port 11434            │  │       Port 8080             │
│       (Ollama API)          │  │       (Brain API)           │
└─────────────────────────────┘  └─────────────────────────────┘
```

## Service Tree

```
ai-multimodel        | AI Orchestration System          | -
  ↳ tensordock-gpu   | DeepSeek 14B Inference          | TensorDock
    ↳ ollama-app     | LLM API Server                  | Ollama
    ↳ deepseek-model | Code LLM (14B Q4)               | DeepSeek-Coder-v2
  ↳ oracle-brain     | ML Brain Knowledge System       | Oracle Free
    ↳ brain-api      | Knowledge API Server            | Flask/Python
    ↳ brain-db       | Knowledge Database              | SQLite
    ↳ embeddings     | Vector Embeddings               | OpenAI API
  ↳ local-collect    | Data Collection (runs locally)  | -
    ↳ claude-collector | Claude Code logs              | Python
    ↳ browser-collector| Browser history              | Python
    ↳ files-collector  | Local code files             | Python

───────────────────────────────────────────────────────────────────
INFRASTRUCTURE
───────────────────────────────────────────────────────────────────
tensordock-vm        | GPU VM (Pay-per-use)            | -
  ↳ gpu              | RTX 4090 24GB VRAM              | NVIDIA
  ↳ cpu              | 4 vCPU                          | x86_64
  ↳ ram              | 16 GB                           | DDR4
  ↳ storage          | 70 GB SSD                       | NVMe
  ↳ location         | EU (DE/FR/NL)                   | TensorDock
  ↳ cost             | $0.35/hr                        | Pay-per-use

oracle-free-vm       | ARM VM (Always Free)            | -
  ↳ cpu              | 4 OCPU ARM64                    | Ampere
  ↳ ram              | 24 GB                           | DDR4
  ↳ storage          | 100 GB                          | Block
  ↳ location         | eu-frankfurt-1                  | Oracle
  ↳ cost             | $0/mo                           | Free Tier
```

## Cost Summary

| Component | Cost |
|-----------|------|
| TensorDock RTX 4090 | **$0.35/hr** |
| TensorDock storage | ~$0.05/GB/mo |
| Oracle ML Brain | **FREE** |

### Monthly Estimates

| Usage | Hours | TensorDock | Oracle | **TOTAL** |
|-------|-------|------------|--------|-----------|
| Weekend hobby | 32h | $11 | $0 | **$11/mo** |
| Light (2h/day) | 60h | $21 | $0 | **$21/mo** |
| Medium (4h/day) | 120h | $42 | $0 | **$42/mo** |
| Heavy (8h/day) | 240h | $84 | $0 | **$84/mo** |

## TensorDock Specs

### GPU VM Configuration

```yaml
GPU Model: geforcertx4090-pcie-24gb
GPU Count: 1
vCPUs: 4
RAM: 16 GB
Storage: 70 GB SSD
OS: Ubuntu 22.04 LTS
Location: EU (DE, FR, NL, etc.)
```

### Available EU Locations

- Germany (DE)
- France (FR)
- Netherlands (NL)
- Poland (PL)
- Czech Republic (CZ)
- Belgium (BE)
- Sweden (SE)
- United Kingdom (GB)
- Switzerland (CH)
- Austria (AT)

## Setup Instructions

### 1. Get TensorDock API Key

1. Sign up at https://tensordock.com
2. Go to https://marketplace.tensordock.com/api
3. Generate API key and token
4. Save to `~/.config/tensordock/credentials`

### 2. Install CLI

```bash
pip install tensordock
# or use the deploy script below
```

### 3. Deploy GPU VM

```bash
# Using the control script
~/scripts/ai-tensordock.sh deploy

# Or via API
curl -X POST "https://marketplace.tensordock.com/api/v0/client/deploy/hostnodes" \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -d '{
    "gpu_model": "geforcertx4090-pcie-24gb",
    "gpu_count": 1,
    "vcpus": 4,
    "ram": 16,
    "storage": 70,
    "os": "Ubuntu 22.04 LTS",
    "location": "eu"
  }'
```

## Control Script Usage

```bash
# Deploy new VM
ai-tensordock.sh deploy

# Start VM
ai-tensordock.sh start

# Stop VM (saves money!)
ai-tensordock.sh stop

# SSH into VM
ai-tensordock.sh ssh

# Check status
ai-tensordock.sh status

# Query DeepSeek
ai-tensordock.sh query "Write a Python function"

# Delete VM (stops all charges)
ai-tensordock.sh destroy
```

## Post-Deploy Setup (On GPU VM)

```bash
# 1. Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# 2. Pull DeepSeek model
ollama pull deepseek-coder-v2-lite-instruct
# Alternative: qwen2.5-coder:14b (also excellent)

# 3. Start Ollama server
OLLAMA_HOST=0.0.0.0 ollama serve &

# 4. Test
curl localhost:11434/api/generate -d '{
  "model": "deepseek-coder-v2-lite-instruct",
  "prompt": "Hello world in Python"
}'
```

## Integration with ML Brain

```bash
# On Oracle Free Tier (ml-brain server)
# Query TensorDock DeepSeek for embeddings or inference

curl "http://TENSORDOCK_IP:11434/api/embeddings" -d '{
  "model": "deepseek-coder-v2-lite-instruct",
  "prompt": "Your text here"
}'
```

## Security

### Firewall (on TensorDock VM)

```bash
# Only allow your IP
sudo ufw allow from YOUR_IP to any port 22
sudo ufw allow from YOUR_IP to any port 11434
sudo ufw allow from ORACLE_BRAIN_IP to any port 11434
sudo ufw enable
```

### SSH Key

```bash
# Use your existing key
ssh -i ~/.ssh/id_rsa root@TENSORDOCK_IP
```

## Comparison: Why TensorDock Won

| Feature | TensorDock | Vast.ai | Oracle |
|---------|------------|---------|--------|
| RTX 4090 price | **$0.35/hr** | $0.45/hr | N/A |
| Full VM | ✅ | Container | ✅ |
| EU locations | ✅ 10+ | Varies | 2-3 |
| API/CLI | ✅ | ✅ | ✅ |
| Reliability | ⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| Stop = $0 | ✅ | ✅ | ✅ |

## Quick Reference

```bash
# Start work session
ai-tensordock.sh start
# Wait 1 min for boot

# Use DeepSeek
ai-tensordock.sh query "Explain this code: ..."

# Done working - STOP TO SAVE MONEY
ai-tensordock.sh stop
```

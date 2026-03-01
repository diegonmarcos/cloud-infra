# Vast.ai On-Demand GPU Instance - Ollama LLM Server

**VM ID**: `vast-RTX-p_0`
**SSH Alias**: `vast-ollama`
**Provider**: Vast.ai
**GPU**: RTX A4000 (16GB VRAM)
**Cost**: $0.08-0.25/hour (~$9.60-30/month for 4hrs/day)

## Quick Start

### 1. Rent Instance on Vast.ai

Visit [Vast.ai Console](https://vast.ai/console/create/) and:

1. **Filter**:
   - GPU: RTX A4000 (or RTX 4090 for more power)
   - VRAM: 16GB minimum
   - Disk: 30GB minimum
   - Sort by: Price (Low to High)

2. **Template**: Select "Open WebUI (Ollama)" or "Ubuntu 22.04 CUDA"

3. **Enable**: SSH + Jupyter (optional)

4. **Rent** the instance (~$0.08-0.25/hr)

### 2. Update SSH Config

Once your instance starts, get connection details from Vast.ai console:

```bash
# Example: ssh -p 12345 root@ssh4.vast.ai
# Update ~/git/vault/A0_keys/config_mobile with actual values
```

### 3. Connect & Verify

```bash
ssh vast-ollama
nvidia-smi  # Verify GPU is available
```

### 4. Install/Verify Ollama

```bash
# If using Ollama template, it's already installed
ollama --version

# If manual install needed:
curl -fsSL https://ollama.com/install.sh | sh
```

### 5. Pull & Run Models

```bash
# Pull a 13B model (choose one)
ollama pull llama2:13b       # Meta's Llama 2
ollama pull mistral:13b      # Mistral AI
ollama pull deepseek-r1:14b  # DeepSeek R1

# Run interactively
ollama run llama2:13b

# Or start API server
OLLAMA_HOST=0.0.0.0:11434 ollama serve
```

## Cost Management

**IMPORTANT**: You're billed per hour when the instance is running!

- **4 hours/day** = **120 hours/month**
- **Cost**: $9.60-30/month depending on GPU chosen
- **Stop when done**: Go to [Vast.ai Console](https://vast.ai/console/instances/) → Stop Instance

## API Access

Once Ollama is running with `OLLAMA_HOST=0.0.0.0:11434`:

```bash
# Get instance public IP from Vast.ai console
VAST_IP="<instance-ip>"
VAST_PORT="<ssh-port>"

# Test API
curl http://$VAST_IP:11434/api/generate -d '{
  "model": "llama2:13b",
  "prompt": "Why is the sky blue?",
  "stream": false
}'
```

## Integration with Your Cloud

This instance is tracked in:
- **Config**: `~/git/cloud/config.json`
- **SSH**: `~/git/vault/A0_keys/config_mobile` (alias: `vast-ollama`)
- **MCP**: Accessible via `cloud-infra` MCP server

## Recommended Models for 16GB VRAM

| Model | Size | VRAM | Best For |
|-------|------|------|----------|
| llama2:13b | 13B | ~13GB | General purpose, balanced |
| mistral:13b | 13B | ~13GB | Fast inference, coding |
| deepseek-r1:14b | 14B | ~14GB | Reasoning, math, analysis |
| codellama:13b | 13B | ~13GB | Code generation |

## Troubleshooting

### GPU Not Detected
```bash
nvidia-smi
# If fails, restart instance or contact Vast.ai support
```

### Out of VRAM
```bash
# Use smaller quantized models
ollama pull llama2:7b    # Only ~7GB
ollama pull mistral:7b   # Only ~7GB
```

### Slow Performance
- Check GPU utilization: `nvidia-smi`
- Try spot instances for cheaper pricing
- Consider RTX 4090 (24GB) for better performance

## References

- [Vast.ai Ollama Guide](https://docs.vast.ai/ollama-webui)
- [Ollama Models](https://ollama.com/library)
- [Setup Script](./2.setup/vast-ollama-setup.sh)

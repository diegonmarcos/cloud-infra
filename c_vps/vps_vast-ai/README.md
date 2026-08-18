# Vast.ai

On-demand GPU marketplace. Instances are rented per-hour from third-party hosts.

## Provider Overview

| Property | Value |
|----------|-------|
| **Type** | GPU marketplace (on-demand, spot) |
| **Billing** | Per-hour while running |
| **Console** | https://cloud.vast.ai |
| **CLI** | `vastai` (PyPI) |
| **No WireGuard mesh** | Dynamic IPs — not part of the 10.0.0.0/24 mesh |

## Instances

| ID | Alias | GPU | VRAM | Use |
|----|-------|-----|------|-----|
| [vast-RTX-p_0](../vm_vast-RTX-p_0/) | `vast-ollama` | RTX A4000 | 16 GB | Ollama LLM |

## CLI

```bash
pip install vastai
vastai set api-key <key>          # from https://cloud.vast.ai/account/

vastai search offers 'gpu_name=RTX_A4000 disk_space>=30'
vastai create instance <offer-id> --image vastai/ollama --disk 30
vastai show instances
vastai ssh-url <instance-id>      # get ssh host:port
vastai destroy instance <id>
```

## SSH

IP and port change every rental. After creating an instance:

```bash
# Get connection string
vastai ssh-url <instance-id>
# → ssh://root@ssh4.vast.ai:12345

# Update vault SSH config
# ~/git/cloud-vault/A0_keys/config_mobile  (Host vast-ollama)
```

## Billing

- Billed **per hour** while instance is running
- **Stop = billed, Destroy = not billed** (but data is lost)
- Typical cost: $0.08–0.25/hr for RTX A4000

```bash
vastai show invoices    # current billing
vastai stop instance <id>     # pause (still billed for storage)
vastai destroy instance <id>  # full stop, no more charges
```

## Notes

- Not on WireGuard mesh — Ollama API is public (use firewall or SSH tunnel)
- No static IP — update SSH config and any API consumers after each rental
- Credentials: `~/git/cloud-vault/A0_keys/providers/vast-ai/`

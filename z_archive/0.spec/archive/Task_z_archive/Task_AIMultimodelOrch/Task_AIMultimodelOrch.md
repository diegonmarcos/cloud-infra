# AI Multi-Model Orchestration Plan

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    ORCHESTRATOR                         │
│              (LangChain / LangGraph)                    │
└─────────────────────┬───────────────────────────────────┘
                      │
        ┌─────────────┼─────────────┐
        ▼             ▼             ▼
   ┌─────────┐   ┌─────────┐   ┌─────────┐
   │ TIER 1  │   │ TIER 2  │   │ TIER 3  │
   │  ARCH   │   │  EXEC   │   │  TASKS  │
   └────┬────┘   └────┬────┘   └────┬────┘
        │             │             │
   ┌────┴────┐   ┌────┴────┐   ┌────┴────┐
   │ Opus    │   │ Sonnet  │   │ Haiku   │
   │ (brain) │   │ (lead)  │   │ (fast)  │
   │    +    │   │    +    │   │    +    │
   │ G.Pro   │   │ G.Pro   │   │ G.Flash │
   │ (memory)│   │ (junior)│   │ (3x vote│
   └─────────┘   └─────────┘   └─────────┘
                      │
              ┌───────┴───────┐
              ▼               ▼
         ┌─────────┐    ┌──────────┐
         │ VPS_1   │    │ BASELINE │
         │DeepSeek │    │ Month 1  │
         │(cost opt)│   │ no DS    │
         └─────────┘    └──────────┘
```

## Infrastructure

| VPS | Purpose | Models |
|-----|---------|--------|
| VPS_1 | Local inference | DeepSeek-Coder-32B |
| VPS_2 | API gateway | Claude (Opus/Sonnet/Haiku) + Gemini (Pro/Flash) |

## Model Roles

### Tier 1: Architecture (Complex Decisions)

| Model | Role | Responsibility |
|-------|------|----------------|
| Claude Opus | PhD Senior Engineer | System design, architecture, critical decisions |
| Gemini Pro | RAG Memory (1M ctx) | Long-context retrieval, summarize info for Opus |

**Use case**: New feature design, security architecture, major refactors

### Tier 2: Execution (Implementation)

| Model | Role | Responsibility |
|-------|------|----------------|
| Claude Sonnet | Lead Developer | Execute plans, write code, code review |
| Gemini Pro | Junior Developer | Assist Sonnet, gather context, research |

**Use case**: Feature implementation, bug fixes, code generation

### Tier 3: Tasks (Quick Work)

| Model | Role | Responsibility |
|-------|------|----------------|
| Claude Haiku | Fast Intern | Quick answers, simple code |
| Gemini Flash | Fast Intern | Quick answers, simple lookups |

**Consensus pattern**: Haiku + Flash interact 3x to reach final answer

**Use case**: Small questions, formatting, simple tasks

### Cost Optimizer: DeepSeek

| Model | Role | Responsibility |
|-------|------|----------------|
| DeepSeek-Coder-32B | Cost Reduction | Replace Tier 3 for routine tasks after baseline |

**Strategy**: Introduce after Month 1 baseline to measure ROI

## Rollout Strategy

### Month 1: Baseline (No DeepSeek)

- Track costs per task type
- Log which models handle what workloads
- Identify "easy" patterns suitable for local model
- Establish quality benchmarks

### Month 2+: DeepSeek Integration

- Deploy DeepSeek on GPU VPS
- Replace Haiku on routine code tasks
- Replace Flash on simple RAG queries
- Keep Claude for judgment-heavy decisions
- Measure savings vs quality delta

## Cost Estimates

### API Costs (Claude + Gemini)

| Tier | Models | Monthly Cost |
|------|--------|--------------|
| Tier 1 (Arch) | Opus + Gemini Pro | $80-150 |
| Tier 2 (Exec) | Sonnet + Gemini Pro | $60-100 |
| Tier 3 (Tasks) | Haiku + Flash | $30-50 |
| **Total** | | **$170-300** |

### DeepSeek VPS Options

| Provider | GPU | VRAM | $/hour | $/month (24/7) |
|----------|-----|------|--------|----------------|
| Vast.ai | RTX 3090 | 24GB | $0.20-0.35 | $150-250 |
| Vast.ai | RTX 4090 | 24GB | $0.35-0.50 | $250-360 |
| RunPod | RTX 3090 | 24GB | $0.30 | $220 |
| RunPod | A40 | 48GB | $0.50 | $360 |

### On-Demand Usage (Recommended)

| Usage Pattern | Hours/day | Vast.ai 3090 | Monthly |
|---------------|-----------|--------------|---------|
| Light | 2h | $0.25 × 60h | $15 |
| Medium | 6h | $0.25 × 180h | $45 |
| Heavy | 12h | $0.25 × 360h | $90 |
| Always on | 24h | $0.25 × 720h | $180 |

### Projected Savings

| Phase | Claude + Gemini | DeepSeek VPS | Total |
|-------|-----------------|--------------|-------|
| Month 1 (baseline) | $200 | $0 | $200 |
| Month 2+ (light DS) | $150 | $15-45 | $165-195 |
| Month 2+ (heavy DS) | $100 | $90 | $190 |

## Hardware Requirements (DeepSeek 32B)

### GPU VPS Specs (Recommended)

- **GPU**: RTX 3090/4090 (24GB VRAM)
- **RAM**: 32-64GB
- **Storage**: 50GB SSD (model weights)
- **Quantization**: Q4_K_M (~20GB)

### Performance

| Mode | Speed |
|------|-------|
| Full GPU (24GB VRAM) | 15-22 tok/s |
| Hybrid (GPU + RAM) | 12-18 tok/s |
| CPU only | 1-3 tok/s |

## Implementation Stack

```python
# LangGraph orchestrator example
from langgraph.graph import StateGraph

workflow = StateGraph(TaskState)

# Router decides tier
workflow.add_node("router", classify_task)
workflow.add_node("tier1_arch", opus_gemini_pro)
workflow.add_node("tier2_exec", sonnet_gemini_pro)
workflow.add_node("tier3_fast", haiku_flash_vote)
workflow.add_node("deepseek", deepseek_local)

# Conditional routing
workflow.add_conditional_edges("router", route_by_complexity)
```

## Task Routing Logic

```python
def route_by_complexity(state: TaskState) -> str:
    task = state["task"]

    # Tier 1: Architecture
    if task.requires_design or task.is_critical:
        return "tier1_arch"

    # Tier 2: Execution
    if task.requires_implementation:
        return "tier2_exec"

    # DeepSeek (after baseline)
    if task.is_routine and deepseek_available:
        return "deepseek"

    # Tier 3: Quick tasks
    return "tier3_fast"
```

## Success Metrics

- [ ] Month 1: Establish cost baseline without DeepSeek
- [ ] Month 1: Log task types and model assignments
- [ ] Month 2: Deploy DeepSeek on Vast.ai
- [ ] Month 2: Achieve 20-30% cost reduction on Tier 3 tasks
- [ ] Month 3: Fine-tune routing logic based on quality metrics
- [ ] Month 3: Target total cost under $180/month

## Notes

- **Best VPS strategy**: Vast.ai spot instance (RTX 3090) @ $0.25/hr
- **Spin up on-demand**, auto-shutdown after idle
- **Preload model on persistent disk** to reduce cold start
- **Break-even vs buying hardware**: ~16-20 months

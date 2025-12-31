# AI Infrastructure Master Plan

**Project:** Diego's AI/ML System
**Parent:** `MASTERPLAN_CLOUD.md` → A0) Service Catalog → User AIs Models
**CTO:** Claude (Opus)
**Date:** 2025-12-11
**Status:** PLANNING (Premium Project - Will merge when ready)

---

# Executive Summary

This is a **sub-document** of MASTERPLAN_CLOUD.md, defining the AI-specific infrastructure.
**Two independent GPU VMs:** Multi-Model (inference) + MyAI (training) - both pay-per-use.

> [!abstract] A) PRODUCTS & INFRA - WHAT we're building
> - **[[#A0) Products]]** - User-facing AI applications
>   - [[#A00) Multi-Model Orchestration (VM1: Inference)]]	- openwebui, ollama
>   - [[#A01) MyAI Platform (VM2: Training)]]	- dashboard, training, mlflow
> - **[[#A1) Back-Services]]** - Admin & infrastructure
>   - [[#A10) AI Portal]]	- AI services dashboard
>   - [[#A11) Operation Dashboards]]	- GPU monitoring, cost alerts
>   - [[#A12) Infra Services]]	- Backend services
>     - [[#A120) Inference Services]]	- ollama-app, models (DeepSeek, Llama, Mistral)
>     - [[#A121) RAG & Knowledge]]	- chromadb, embeddings
>     - [[#A122) Training Services]]	- pytorch, mlflow-tracking
>     - [[#A123) MCP System]]	- → MASTERPLAN_CLOUD.md A122
>   - [[#A13) Infra Resources]]	- VMs, networks & allocation
>     - [[#A130) Resource Allocation]]
>       - [[#A1300) Resource Estimation]]
>       - [[#A1301) VM Capacity & Headroom]]
>       - [[#A1302) Cost Estimation]]
>       - [[#A1303) URL/Port Proxied]]
>     - [[#A131) Maps & Topology]]
>     - [[#A132) Costs]]

> [!example] B) ARCHITECTURE - HOW to build it
> - **[[#B0) Model Architecture]]**
>   - [[#B00) Model Selection & Routing]]
>   - [[#B01) RAG Architecture]]
> - **[[#B1) MCP Architecture]]** - → MASTERPLAN_CLOUD.md B04
> - **[[#B2) Training Pipeline]]**
>   - [[#B20) MyAI Training Flow]]
>   - [[#B21) Experiment Tracking (MLflow)]]
> - **[[#B3) Infrastructure Architecture]]**
>   - [[#B30) GPU Provisioning]]
>   - [[#B31) Data Flow]]

> [!tip] C) ROADMAP - WHEN to build it
> - **[[#C0) Phases - Implementation Milestones]]**
>   - [[#C00) Phase 1: Basic Inference (PRIORITY)]]
>   - [[#C01) Phase 2: RAG Integration]]
>   - [[#C02) Phase 3: Training Infrastructure]]
>   - [[#C03) Phase 4: Custom Models]]
>   - [[#C04) Phase 5: MCP System (Parallel Track)]]
> - **[[#C1) Dependencies - Service Graph]]**
> - **[[#C2) Backlog - Prioritized Tasks]]**
>   - [[#C20) High Priority (Now)]]
>   - [[#C21) Medium Priority (Next)]]
>   - [[#C22) Low Priority (Later)]]
>   - [[#C23) Tech Debt]]

> [!info] D) DEVOPS - HOW to operate it
> - **[[#D0) Dashboard - AI Services Access]]**
> - **[[#D1) Monitoring - Metrics & Alerts]]**
>   - [[#D10) GPU Monitoring]]
>   - [[#D11) Cost Alerts]]
>   - [[#D12) Health Checks]]
> - **[[#D2) Knowledge Center]]**
>   - [[#D20) AI Documentation]]
>   - [[#D21) Runbooks]]
>   - [[#D22) Quick Commands]]

> [!note] X) APPENDIX - Reference Material
> - **[[#X0) Code Practices]]** - TypeScript, Svelte 5, Vue 3, SCSS standards
> - **[[#X1) System OS Practices]]** - Poetry, Flatpak, Nix, dotfiles
> - **[[#X2) Tech Research]]** - Framework comparisons, model benchmarks
>   - [[#X20) LLM Models]]
>   - [[#X21) GPU Providers]]
>   - [[#X22) Vector DBs]]
>   - [[#X23) Embeddings]]
> - **[[#X3) Current State]]** - Today's running state
>   - [[#X30) Status]]
>   - [[#X31) Quick Ref]]

**Connection to MASTERPLAN_CLOUD:**
```
MASTERPLAN_CLOUD.md
└── A0) Service Catalog
    └── User AIs Models
        └── AI Chat (Terminals)
            ├── Mode 1: API Keys Only (OpenAI, Claude, etc.)
            └── Mode 2: Multi-Model Orchestration → THIS DOCUMENT
```

---

# A) HANDOFF - AI Infrastructure Definition




## A0) Products (Service, Stack and Component Definition)

### A00) Multi-Model Orchestration (VM1: Inference)

> **Independent VM:** `tensordock-inference` - Dedicated to chat/inference workloads.

```
Name                     | Component            | Stack               | Purpose
─────────────────────────┼──────────────────────┼─────────────────────┼────────────────────────────────
ai-chat                  | -                    | -                   | AI Chat System (VM1)
  ↳ openwebui            | Chat UI + RAG        | Open WebUI          | UI, model switching, built-in RAG
  ↳ ollama-app           | LLM Server           | Ollama              | Local model serving
                         |                      |                     |
models                   | Model Library        | -                   | Available Models (in Ollama)
  ↳ deepseek-coder-v2    | Code Model           | DeepSeek-v2 14B Q4  | Code generation
  ↳ llama-3.1-8b         | General Model        | Llama 3.1 8B Q4     | General chat
  ↳ mistral-7b           | Fast Model           | Mistral 7B Q4       | Fast inference
                         |                      |                     |
external-apis            | External Models      | -                   | Pay-per-token APIs (optional)
  ↳ openai               | External API         | OpenAI API          | GPT-4 (via Open WebUI)
  ↳ anthropic            | External API         | Claude API          | Claude 3 (via Open WebUI)
```

**Architecture (VM1 - Inference):**
```mermaid
flowchart TD
    subgraph VM1["VM1: TENSORDOCK-INFERENCE (On-Demand)<br/>RTX 4090 24GB | $0.35/hr"]
        subgraph OpenWebUI["Open WebUI :3000"]
            OW1["Chat interface"]
            OW2["Model selector"]
            OW3["Built-in RAG"]
            OW4["Chat history & users"]
        end
        subgraph Ollama["Ollama :11434"]
            M1["DeepSeek-Coder-v2 14B"]
            M2["Llama 3.1 8B"]
            M3["Mistral 7B"]
        end
        OpenWebUI --> Ollama
    end
```

**Why Open WebUI:**
- **No custom code** - Handles RAG, embeddings, document storage
- **Upload docs directly** - PDFs, code, notes via UI
- **Pay-per-use** - Only pay when chatting ($0.35/hr)

---

### A01) MyAI Platform - Train Your Own Models (VM2: Training)

> **Independent VM:** `tensordock-training` - Dedicated to training/fine-tuning workloads.

```
Name                     | Component            | Stack               | Purpose
─────────────────────────┼──────────────────────┼─────────────────────┼────────────────────────────────
myai                     | -                    | -                   | Train & Deploy Your Own AI (VM2)
  ↳ myai-dashboard       | Dashboard            | SvelteKit 5 + SCSS  | AI management UI
  ↳ myai-api             | Backend              | FastAPI             | Orchestration backend
                         |                      |                     |
data                     | Data Layer           | -                   | Your Data Pipeline
  ↳ data-ingest          | Ingestion            | Python3             | Data collection pipelines
  ↳ data-store           | Storage              | pgvector + S3       | Vector DB + document store
  ↳ data-prep            | Preprocessing        | LangChain           | Cleaning, chunking, embedding
  ↳ data-version         | Versioning           | DVC                 | Dataset versioning
                         |                      |                     |
train                    | Model Layer          | -                   | Your Training Pipeline
  ↳ train-base           | Base Models          | PyTorch / HF        | HuggingFace models
  ↳ train-finetune       | Fine-tuning          | LoRA / QLoRA        | Fine-tuning pipelines
  ↳ train-scratch        | From Scratch         | PyTorch             | Train from scratch (expensive)
  ↳ train-track          | Tracking             | MLflow              | Experiment tracking
                         |                      |                     |
deploy                   | Deployment Layer     | -                   | Your Serving Pipeline
  ↳ deploy-model         | Model Serving        | Ollama / vLLM       | Model inference server
  ↳ deploy-api           | API Gateway          | FastAPI             | API for your model
```

**Architecture (VM2 - Training):**
```mermaid
flowchart TD
    subgraph VM2["VM2: TENSORDOCK-TRAINING (On-Demand)<br/>RTX 4090 24GB | $0.35/hr"]
        subgraph Dashboard["MyAI Dashboard :8080"]
            D1["Dataset management"]
            D2["Training job launcher"]
            D3["Model deployment UI"]
        end
        subgraph Training["Training Stack"]
            T1["PyTorch + HuggingFace"]
            T2["LoRA/QLoRA fine-tuning"]
            T3["MLflow :5001"]
        end
        subgraph Serving["Model Serving"]
            S1["Ollama / vLLM"]
            S2["FastAPI :8000"]
        end
        Dashboard --> Training --> Serving
    end
```

**Access Modes:**
- **Private:** Your use only (via Authelia from CLOUD)
- **Shared:** Invite-only access (API keys)
- **Public:** Open API endpoint (rate-limited)

**Independence from VM1:**
- Can train while VM1 is running inference
- Separate storage for datasets and trained models
- Deploy trained models to VM1 (Ollama) or serve directly on VM2

---





## A1) Back-Services

> **Two independent VMs:** VM1 for inference (A00), VM2 for training (A01).

### A10) AI Portal

> AI services dashboard - access point for all AI infrastructure.

Managed via → `MASTERPLAN_CLOUD.md` A10) Cloud Portal Front

### A11) Operation Dashboards

> GPU monitoring, cost alerts, health checks.

Managed via → `MASTERPLAN_CLOUD.md` A11) Operation Dashboards (A110-A113)

### A12) Infra Services

> Backend services powering the AI products.

#### A120) Inference Services

```
Name                     | Component            | Stack               | Purpose
─────────────────────────┼──────────────────────┼─────────────────────┼────────────────────────────────
ollama                   | LLM Server           | Ollama              | Local model serving & management
                         |                      |                     |
models (in Ollama)       | Model Library        | -                   | Downloaded models
  ↳ deepseek-coder-v2    | Code Model           | 14B Q4 (~10 GB)     | Code generation
  ↳ llama-3.1-8b         | General Model        | 8B Q4 (~6 GB)       | General chat
  ↳ mistral-7b           | Fast Model           | 7B Q4 (~5 GB)       | Fast inference
```

#### A121) RAG & Knowledge

```
Name                     | Component            | Stack               | Purpose
─────────────────────────┼──────────────────────┼─────────────────────┼────────────────────────────────
; NO SEPARATE SERVICES - Open WebUI handles all of this on VM1:
openwebui-rag            | Built-in RAG         | Open WebUI          | Document upload, chunking, search
openwebui-embeddings     | Built-in Embeddings  | sentence-transform  | Text → vector (local, free)
openwebui-vectordb       | Built-in Vector DB   | ChromaDB            | Vector storage (SQLite backend)
```

> **Why Open WebUI:** No custom brain-api, brain-db, pgvector, LangChain, collectors needed.

#### A122) Training Services

```
Name                     | Component            | Stack               | Purpose
─────────────────────────┼──────────────────────┼─────────────────────┼────────────────────────────────
training                 | -                    | -                   | Model Fine-tuning (VM2)
  ↳ training-jobs        | Training Runner      | PyTorch + HF        | Fine-tuning jobs (LoRA/QLoRA)
  ↳ mlflow               | Experiment Tracking  | MLflow (self-host)  | Track experiments, models
  ↳ data-store           | Data Storage         | pgvector + S3       | Training datasets, vectors
```

> **Independence:** VM2 runs separately from VM1, can train while VM1 is serving inference.

---

#### A123) MCP System

> **MOVED TO:** `MASTERPLAN_CLOUD.md` → A12) DATA & SAFETY → MCP
> **Architecture:** `MASTERPLAN_CLOUD.md` → B4) MCP Architecture
>
> MCPs are AI-agnostic infrastructure that serves ALL AI clients (Claude Code, Claude Desktop, Ollama, future AIs).
> They belong in MASTERPLAN_CLOUD as core infrastructure, not in this AI-specific document.

**What MCPs Solve:**

```
Problem                              | MCP Solution                    | Impact
─────────────────────────────────────┼─────────────────────────────────┼─────────────────────────────────
46K tokens of masterplans forgotten  | masterplan-rag (semantic search)| Context preserved across sessions
18 projects hard to navigate         | file-navigator                  | Find any file in <5s
Cloud commands need SSH              | cloud-cli                       | VM status from Claude directly
Secrets exposure risk                | secrets-manager                 | Audit-logged paths only
Build requires leaving Claude        | build-orchestrator              | Build without context switch
```

**MCP Tools Summary:**

| MCP | Tools Provided | Example Query |
|-----|----------------|---------------|
| masterplan-rag | `semantic_search`, `get_section`, `list_sections` | "What's the auth architecture?" |
| file-navigator | `find_file`, `list_project`, `tree_structure` | "Find all SCSS files in linktree" |
| git-integration | `get_commit_history`, `search_commits`, `get_blame` | "Who changed Authelia config?" |
| secrets-manager | `get_ssh_key_path`, `confirm_credential_exists` | "Path to oci-p-flex_1 SSH key" |
| cloud-cli | `get_vm_status`, `gcloud_exec`, `oci_exec` | "Is oci-p-flex_1 running?" |
| docker-manager | `list_services`, `get_docker_logs`, `restart_service` | "Show photoprism logs" |
| build-orchestrator | `build_project`, `build_all`, `list_projects` | "Build linktree for production" |

---







### A13) Infra Resources

> **Philosophy:** Performance-focused, not GUI-pretty.


#### A130) Resource Allocation

##### A1300) Resource Estimation

```
Service                  | RAM (active) | Storage | GPU (active) | VM
─────────────────────────┼──────────────┼─────────┼──────────────┼─────────────────────
; VM1: TENSORDOCK-INFERENCE - Multi-Model Chat (A00)
openwebui                | 1 GB         | 10 GB   | -            | tensordock-inference
ollama-app               | 4 GB         | 5 GB    | 20 GB        | tensordock-inference
deepseek-coder-v2        | -            | 10 GB   | (in 20 GB)   | tensordock-inference
llama-3.1-8b             | -            | 6 GB    | (in 20 GB)   | tensordock-inference
mistral-7b               | -            | 5 GB    | (in 20 GB)   | tensordock-inference
─────────────────────────┼──────────────┼─────────┼──────────────┼─────────────────────
SUBTOTAL VM1             | 5 GB         | 36 GB   | 20 GB        |
                         |              |         |              |
; VM2: TENSORDOCK-TRAINING - MyAI Platform (A01)
myai-dashboard           | 0.5 GB       | 2 GB    | -            | tensordock-training
myai-api                 | 1 GB         | 1 GB    | -            | tensordock-training
training-jobs            | 8 GB         | 20 GB   | 24 GB        | tensordock-training
mlflow-tracking          | 1 GB         | 5 GB    | -            | tensordock-training
data-store (pgvector)    | 2 GB         | 30 GB   | -            | tensordock-training
─────────────────────────┼──────────────┼─────────┼──────────────┼─────────────────────
SUBTOTAL VM2             | 12.5 GB      | 58 GB   | 24 GB        |
                         |              |         |              |
─────────────────────────┼──────────────┼─────────┼──────────────┼─────────────────────
TOTAL (parallel)         | 17.5 GB      | 94 GB   | 44 GB        | (if both running)
```

> **Resource columns show capacity needed when active** (not cumulative over time).
> - **RAM/GPU (active):** Memory required while service is running
> - **Storage:** Disk space (persistent)
> - **TOTAL (parallel):** Capacity needed if both VMs running simultaneously (e.g., dedicated hardware)
> - For **cost calculations** (hrs × $0.35), see **A1302) Cost Estimation**

##### A1301) VM Capacity & Headroom

```
Provider   | VM                   | CPU        | RAM Cap | RAM Alloc | RAM Head | HD Cap | HD Alloc | HD Head | GPU Cap | GPU Alloc | GPU Head
───────────┼──────────────────────┼────────────┼─────────┼───────────┼──────────┼────────┼──────────┼─────────┼─────────┼───────────┼──────────
TensorDock | tensordock-inference | 4 vCPU x86 | 16 GB   | 5 GB      | 69%      | 70 GB  | 36 GB    | 49%     | 24 GB   | 20 GB     | 17%
TensorDock | tensordock-training  | 4 vCPU x86 | 16 GB   | 12.5 GB   | 22%      | 100 GB | 58 GB    | 42%     | 24 GB   | 24 GB     | 0%
```

**Headroom Analysis (VM1 - Inference):**
```
| VM                   | Resource | Capacity | Allocated | Free   | Headroom | Status |
|----------------------|----------|----------|-----------|--------|----------|--------|
| tensordock-inference | RAM      | 16 GB    | 5 GB      | 11 GB  | 69%      | OK     |
| tensordock-inference | GPU VRAM | 24 GB    | 20 GB     | 4 GB   | 17%      | OK     |
| tensordock-inference | Storage  | 70 GB    | 36 GB     | 34 GB  | 49%      | OK     |

**Headroom Analysis (VM2 - Training):**

| VM                   | Resource | Capacity | Allocated | Free   | Headroom | Status |
|----------------------|----------|----------|-----------|--------|----------|--------|
| tensordock-training  | RAM      | 16 GB    | 12.5 GB   | 3.5 GB | 22%      | TIGHT  |
| tensordock-training  | GPU VRAM | 24 GB    | 24 GB     | 0 GB   | 0%       | FULL   |
| tensordock-training  | Storage  | 100 GB   | 58 GB     | 42 GB  | 42%      | OK     |

**Services per VM:**

| VM                   | Product | Services Running                                          |
|----------------------|---------|-----------------------------------------------------------|
| tensordock-inference | A00     | openwebui, ollama (+ loaded model)                        |
| tensordock-training  | A01     | myai-dashboard, myai-api, training-jobs, mlflow, pgvector |
```


##### A1302) Cost Estimation

```
Resource                  | Type          | Unit Cost     | Usage Est      | Monthly Low | Monthly High
──────────────────────────┼───────────────┼───────────────┼────────────────┼─────────────┼─────────────
; VM1: TENSORDOCK-INFERENCE (A00 Multi-Model)
tensordock-inference      | Pay-per-use   | $0.35/hr      | 35-120 hrs/mo  | $12         | $42
tensordock-inference-ssd  | Included      | $0/mo         | 70 GB          | $0          | $0
                          |               |               |                |             |
; VM2: TENSORDOCK-TRAINING (A01 MyAI)
tensordock-training       | Pay-per-use   | $0.35/hr      | 15-60 hrs/mo   | $5          | $21
tensordock-training-ssd   | Included      | $0/mo         | 100 GB         | $0          | $0
                          |               |               |                |             |
; EXTERNAL APIS (optional)
openai-gpt4               | Pay-per-use   | $30/1M tok    | ~100k tok/mo   | $0          | $3
anthropic-claude          | Pay-per-use   | $15/1M tok    | ~100k tok/mo   | $0          | $2
──────────────────────────┼───────────────┼───────────────┼────────────────┼─────────────┼─────────────
                          |               |               | TOTAL          | $17/mo      | $68/mo
```

**Cost Tiers (Combined):**

| Tier        | VM1 (Inf) | VM2 (Train) | APIs   | Total      | Use Case                        |
|-------------|-----------|-------------|--------|------------|---------------------------------|
| **Minimal** | 35h ($12) | 0h ($0)     | $0     | **$12/mo** | Chat only, no training          |
| **Light**   | 60h ($21) | 15h ($5)    | $0     | **$26/mo** | Regular use + occasional train  |
| **Medium**  | 90h ($32) | 30h ($10)   | $5     | **$47/mo** | Daily dev + weekly training     |
| **Heavy**   | 120h ($42)| 60h ($21)   | $5     | **$68/mo** | Full-time dev + active training |
| **Parallel**| 150h ($52)| 100h ($35)  | $10    | **$97/mo** | Both VMs running simultaneously |

**Cost by Product:**

| Product     | VM                   | Low     | High    | Notes                          |
|-------------|----------------------|---------|---------|--------------------------------|
| A00 Chat    | tensordock-inference | $12/mo  | $42/mo  | Open WebUI + Ollama            |
| A01 MyAI    | tensordock-training  | $5/mo   | $35/mo  | Training + MLflow              |
| External    | -                    | $0/mo   | $5/mo   | Optional OpenAI/Claude APIs    |

##### A1303) URL/Port Proxied

**URL Pattern:** `service.diegonmarcos.com` = Login/Landing → redirects to `/app` after auth success

```
Service              | URL (Public)                    | VM                   | Container      | Port  | Auth
─────────────────────┼─────────────────────────────────┼──────────────────────┼────────────────┼───────┼──────────
; VM1: TENSORDOCK-INFERENCE (A00 Multi-Model)
openwebui            | chat.diegonmarcos.com           | tensordock-inference | openwebui      | 3000  | authelia
ollama-api           | (internal only)                 | tensordock-inference | ollama-app     | 11434 | internal
                     |                                 |                      |                |       |
; VM2: TENSORDOCK-TRAINING (A01 MyAI)
myai-dashboard       | myai.diegonmarcos.com           | tensordock-training  | myai-dashboard | 8080  | authelia
myai-api             | myai.diegonmarcos.com/api       | tensordock-training  | myai-api       | 8000  | authelia
mlflow-ui            | mlflow.diegonmarcos.com         | tensordock-training  | mlflow-tracking| 5001  | authelia
```

**Proxy Chains:**
```
; VM1 (Inference)
User → Cloudflare → NPM (gcp-f-micro_1) → Auth (Authelia) → tensordock-inference

; VM2 (Training)
User → Cloudflare → NPM (gcp-f-micro_1) → Auth (Authelia) → tensordock-training
```

**URLs by Product:**

| Product | URL                           | Purpose                  |
|---------|-------------------------------|--------------------------|
| A00     | chat.diegonmarcos.com         | Open WebUI chat          |
| A01     | myai.diegonmarcos.com         | MyAI dashboard           |
| A01     | mlflow.diegonmarcos.com       | MLflow experiment UI     |

---

#### A131) Maps & Topology

```mermaid
flowchart TB
    subgraph AI["AI INFRASTRUCTURE (Two Independent VMs)"]
        subgraph VM1["VM1: TENSORDOCK-INFERENCE<br/>RTX 4090 24GB | $0.35/hr<br/>(A00 Multi-Model Chat)"]
            subgraph OW["Open WebUI :3000"]
                OW1["Chat interface"]
                OW2["Model selector"]
                OW3["Built-in RAG"]
                OW4["Local embeddings"]
            end
            subgraph OL["Ollama :11434"]
                M1["DeepSeek-Coder-v2 14B"]
                M2["Llama 3.1 8B"]
                M3["Mistral 7B"]
            end
            OW --> OL
        end

        subgraph VM2["VM2: TENSORDOCK-TRAINING<br/>RTX 4090 24GB | $0.35/hr<br/>(A01 MyAI Platform)"]
            subgraph MYAI["MyAI Dashboard :8080"]
                MY1["Dataset management"]
                MY2["Training job launcher"]
                MY3["Model deployment"]
            end
            subgraph TRAIN["Training Stack"]
                TR1["PyTorch + HuggingFace"]
                TR2["LoRA/QLoRA fine-tuning"]
                TR3["MLflow :5001"]
            end
            subgraph DATA["Data Store"]
                DA1["pgvector (datasets)"]
                DA2["S3/MinIO (models)"]
            end
            MYAI --> TRAIN --> DATA
        end

        EXPORT["Model Export<br/>(optional)"]
        VM1 <-.-> EXPORT <-.-> VM2

        subgraph CLOUD["MASTERPLAN_CLOUD (Proxy + Auth)"]
            CF["Cloudflare"] --> NPM["NPM (gcp-f-micro_1)"] --> AUTH["Authelia"]
            URL1["chat.diegonmarcos.com → VM1"]
            URL2["myai.diegonmarcos.com → VM2"]
            URL3["mlflow.diegonmarcos.com → VM2"]
        end

        EXPORT --> CLOUD
    end
```

**Independence:**
- VM1 and VM2 run completely independently
- Can chat (VM1) while training (VM2) simultaneously
- Model export: trained models on VM2 can be deployed to VM1's Ollama

---

#### A132) Costs

> See **A1302) Cost Estimation** for detailed breakdown.

##### Cost Summary by Tier (Two VMs)

| Tier        | VM1 (Inf) | VM2 (Train) | APIs   | Total      | Use Case                        |
|-------------|-----------|-------------|--------|------------|---------------------------------|
| **Minimal** | 35h ($12) | 0h ($0)     | $0     | **$12/mo** | Chat only, no training          |
| **Light**   | 60h ($21) | 15h ($5)    | $0     | **$26/mo** | Regular use + occasional train  |
| **Medium**  | 90h ($32) | 30h ($10)   | $5     | **$47/mo** | Daily dev + weekly training     |
| **Heavy**   | 120h ($42)| 60h ($21)   | $5     | **$68/mo** | Full-time dev + active training |
| **Parallel**| 150h ($52)| 100h ($35)  | $10    | **$97/mo** | Both VMs running simultaneously |

#### All Costs are Variable (Pay-per-Use)

| Type         | Resource                | Cost        | Notes                          |
|--------------|-------------------------|-------------|--------------------------------|
| **Variable** | VM1 (tensordock-infer)  | $0.35/hr    | Only when chatting             |
| **Variable** | VM2 (tensordock-train)  | $0.35/hr    | Only when training             |
| **Variable** | OpenAI/Claude APIs      | Pay-per-use | Optional external models       |
| **Fixed**    | -                       | $0          | No 24/7 infrastructure needed  |

#### Cost by Product

| Product     | VM                   | Low     | High    | Notes                          |
|-------------|----------------------|---------|---------|--------------------------------|
| A00 Chat    | tensordock-inference | $12/mo  | $52/mo  | Open WebUI + Ollama            |
| A01 MyAI    | tensordock-training  | $0/mo   | $35/mo  | Training + MLflow (optional)   |

---








## X0) Code Practices

> **Source:** `/front-Github_io/1.ops/30_Code_Practise.md`

### X00) Tech Stack & Environment

- **Framework:** SvelteKit (Svelte 5 Runes Mode) / Vue 3 (Composition API)
- **Language:** TypeScript (Strict Mode)
- **Styling:** SCSS (Sass) with "Golden Mixins"
- **Analytics:** Matomo (Self-Hosted) via custom component
- **Rendering:** Hybrid (SSR + SPA Client-Side Navigation)

### X01) Svelte 5 & TypeScript Rules

**CRITICAL:** Do NOT use Svelte 4 syntax.

```
Props     → let { propName }: { propName: Type } = $props();   // NEVER use export let
State     → let count = $state(0);                              // NEVER use let var = val
Computed  → let doubled = $derived(count * 2);                  // NEVER use $: var = val
Effects   → $effect(() => { ... });                             // NEVER use onMount for reactive
Events    → onclick, oninput                                    // NEVER use on:click
```

**Typing:**
- Always import `PageData` and `PageServerLoad` from `./$types`
- Use `HTMLInputElement`, `HTMLButtonElement`, etc., for DOM refs

### X02) Vue 3 Rules

**Always use Composition API with `<script setup lang="ts">`**

```typescript
// Props - use generic type syntax
defineProps<{ id: number; name: string }>()

// Refs - explicit types for nullable
const user = ref<User | null>(null)

// Emits - typed
defineEmits<{ (e: 'update', id: number): void }>()
```

### X03) HTML & Accessibility

**Goal:** Semantic, accessible, and clean HTML.

- **No Div Soup:**
  - ❌ `div class="nav"` → ✅ `<nav>`
  - ❌ `div class="card"` → ✅ `<article class="card">`
  - ❌ `div class="footer"` → ✅ `<footer>`
- **Buttons vs Links:**
  - Use `<a href="...">` ONLY for navigation (changing URLs)
  - Use `<button type="button">` for actions (toggles, modals, API calls)
- **Forms:** Every `<input>` must have a linked `<label>` (via `for` attribute or wrapping)
- **Images:** All `<img>` tags MUST have an `alt` attribute

### X04) SCSS & Styling Rules (Golden Mixins)

**Goal:** Consistent, mobile-first responsive design.

**Global Logic:**
- Use **Flexbox** or **Grid** for all layouts
- **FORBIDDEN:** `float`, `clear`, or `position: absolute` (unless for UI overlays)
- Use `rem` for spacing/fonts, `%` for widths

**The Golden Mixins:**
```scss
// Breakpoints (Mobile-first)
$breakpoints: ('sm': 480px, 'md': 768px, 'lg': 1024px, 'xl': 1280px);
@mixin mq($size) {
  @media (min-width: map-get($breakpoints, $size)) { @content; }
}

// Flexbox
@mixin flex-center { display: flex; justify-content: center; align-items: center; }
@mixin flex-row($justify: flex-start, $align: stretch, $gap: 0) {
  display: flex; flex-direction: row; justify-content: $justify;
  align-items: $align; gap: $gap; flex-wrap: wrap;
}
@mixin flex-col($justify: flex-start, $align: stretch, $gap: 0) {
  display: flex; flex-direction: column; justify-content: $justify;
  align-items: $align; gap: $gap;
}

// CSS Grid
@mixin grid-auto-fit($min-size: 250px, $gap: 1rem) {
  display: grid; grid-template-columns: repeat(auto-fit, minmax($min-size, 1fr)); gap: $gap;
}
```

### X05) TypeScript Rules (Vanilla)

**Strict Null Checks for DOM:**
```typescript
// ❌ Bad - Object is possibly null
document.querySelector('.btn').addEventListener(...)

// ✅ Good - Check null, cast type
const btn = document.querySelector('.btn') as HTMLButtonElement;
if (btn) { btn.addEventListener('click', handler); }
```

**Rules:**
- **Strict Mode:** No `any`, handle `null`/`undefined`
- **Explicit Casting:** Cast to specific type (`HTMLInputElement` not `HTMLElement`)
- **ES Modules:** Use `import`/`export`, no global variables

### X06) Analytics (Matomo SPA Tracking)

**Problem:** In SPA, page doesn't reload - analytics won't track navigation.

**Solution:** Hook into router's navigation event.

```svelte
<script lang="ts">
  import { onMount } from 'svelte';
  import { page } from '$app/stores';
  import { afterNavigate } from '$app/navigation';
  import { browser } from '$app/environment';

  function track(action: any[]) {
    if (browser && window._paq) { window._paq.push(action); }
  }

  // Initial load
  onMount(() => {
    window._paq = window._paq || [];
    track(['trackPageView']);
  });

  // SPA navigation
  afterNavigate((navigation) => {
    if (navigation.type === 'enter') return;
    track(['setCustomUrl', $page.url.href]);
    track(['setDocumentTitle', document.title]);
    track(['trackPageView']);
  });
</script>
```

---

## X1) System OS Practices

> System-level package management, app installation, and environment standards.

### X10) Package Management

**MANDATORY:** Use the right tool for each package type.

```
Package Type        | Tool      | Why                                    | Example
────────────────────┼───────────┼────────────────────────────────────────┼─────────────────────────
Python Packages     | Poetry    | Dependency isolation, lock files       | poetry add requests
Python CLI Tools    | pipx      | Isolated environments for CLI apps     | pipx install black
Node.js Packages    | npm/pnpm  | Per-project node_modules               | npm install
Node.js Version     | nvm       | Multiple Node versions                 | nvm use 20
GUI Applications    | Flatpak   | Sandboxed, distro-agnostic             | flatpak install flathub org.gimp.GIMP
CLI Tools           | Nix       | Reproducible, declarative              | nix-env -iA nixpkgs.ripgrep
System Packages     | pacman    | Arch Linux system packages             | pacman -S base-devel
```

### X11) Python Environment

**Poetry is MANDATORY for all Python projects.**

```bash
# Project setup
poetry new myproject          # New project
poetry init                   # Existing project
poetry add requests           # Add dependency
poetry add --dev pytest       # Add dev dependency
poetry install                # Install from lock file
poetry shell                  # Activate venv
poetry run python script.py   # Run in venv

# Global CLI tools (NOT Poetry)
pipx install black            # Code formatter
pipx install ruff             # Linter
pipx install pre-commit       # Git hooks
```

### X12) Node.js Environment

**nvm is MANDATORY for Node.js version management.**

```bash
# Version management
nvm install 20                # Install Node 20
nvm use 20                    # Use Node 20
nvm alias default 20          # Set default

# Per-project version (.nvmrc)
echo "20" > .nvmrc
nvm use                       # Reads .nvmrc
```

### X13) Application Installation

**Flatpak for GUI apps, Nix for CLI tools.**

```bash
# GUI Apps → Flatpak (sandboxed, auto-updates)
flatpak install flathub com.obsidian.Obsidian
flatpak install flathub org.mozilla.firefox

# CLI Tools → Nix (reproducible, declarative)
nix-env -iA nixpkgs.ripgrep
nix-env -iA nixpkgs.fd
nix-env -iA nixpkgs.bat
```

### X14) Docker Practices

```bash
# Development
docker compose up -d          # Start services
docker compose logs -f        # Follow logs
docker compose down           # Stop services

# Never run as root inside containers
```

---

## X2) Tech Research

> Framework comparisons and benchmarks supporting stack choices.

### X20) LLM Models

```
Name                | Component   | Stack        | Purpose                        | Quality
────────────────────┼─────────────┼──────────────┼────────────────────────────────┼────────────
DeepSeek-Coder-v2   | Code LLM    | 14B Q4 ~10GB | Code generation                | ★★★★★
Llama 3.1           | General LLM | 8B Q4 ~6GB   | General chat                   | ★★★★☆
Mistral             | Fast LLM    | 7B Q4 ~5GB   | Fast inference                 | ★★★★☆
CodeLlama           | Code LLM    | 13B Q4 ~9GB  | Code (older)                   | ★★★☆☆
Qwen 2.5            | General LLM | 7B Q4 ~5GB   | Multilingual                   | ★★★★☆
```

### X21) GPU Providers

```
Name                | Component   | Stack        | Purpose                        | Cost/hr
────────────────────┼─────────────┼──────────────┼────────────────────────────────┼──────────
TensorDock ★        | GPU Cloud   | RTX 4090 24GB| Good availability (EU)         | $0.35
Vast.ai             | GPU Cloud   | RTX 4090 24GB| Variable availability          | $0.30-40
RunPod              | GPU Cloud   | RTX 4090 24GB| Good availability              | $0.44
Lambda Labs         | GPU Cloud   | A10G 24GB    | Limited availability           | $0.60
```

> **Our choice:** TensorDock (★) - Best price, good EU availability, RTX 4090 24GB.

### X22) Vector DBs

```
Name                | Component   | Stack        | Purpose                        | Cost
────────────────────┼─────────────┼──────────────┼────────────────────────────────┼──────────
ChromaDB ★          | Vector DB   | SQLite       | Embedded, Open WebUI built-in  | FREE
pgvector            | Vector DB   | PostgreSQL   | Self-hosted, full SQL          | FREE
Pinecone            | Vector DB   | Managed      | Serverless, easy setup         | $0.08/1M
Weaviate            | Vector DB   | Self-host    | GraphQL, multimodal            | FREE
Qdrant              | Vector DB   | Self-host    | High performance, Rust         | FREE
```

> **Our choice:** ChromaDB (★) - Built into Open WebUI, no setup needed.

### X23) Embeddings

```
Name                | Component   | Stack        | Purpose                        | Cost
────────────────────┼─────────────┼──────────────┼────────────────────────────────┼──────────
sentence-transform ★| Embeddings  | Local        | Open WebUI built-in, no cost   | FREE
OpenAI              | Embeddings  | text-embed-3 | Best quality, easy API         | $0.02/1M
Cohere              | Embeddings  | embed-v3     | Multilingual, good quality     | $0.10/1M
```

> **Our choice:** sentence-transformers (★) - Built into Open WebUI, runs locally on CPU, no API costs.

---







## X3) Current State

### X30) Status

```
Name                 | Component            | Stack                    | Status
─────────────────────┼──────────────────────┼──────────────────────────┼────────────────────────────────
; VM1: TENSORDOCK-INFERENCE (A00 Multi-Model)
tensordock-inference | GPU VM               | RTX 4090 24GB            | (pending) On-demand, not active
openwebui            | Chat UI + RAG        | VM1 :3000                | tbd
ollama-app           | LLM Server           | VM1 :11434               | tbd
deepseek-coder-v2    | Code Model           | Ollama (14B Q4)          | tbd
llama-3.1-8b         | General Model        | Ollama (8B Q4)           | tbd
mistral-7b           | Fast Model           | Ollama (7B Q4)           | tbd
                     |                      |                          |
; VM2: TENSORDOCK-TRAINING (A01 MyAI)
tensordock-training  | GPU VM               | RTX 4090 24GB            | (pending) On-demand, not active
myai-dashboard       | Dashboard            | VM2 :8080                | tbd
myai-api             | Backend              | VM2 :8000                | tbd
training-jobs        | Training Runner      | VM2 (PyTorch)            | tbd
mlflow-tracking      | Experiment Tracking  | VM2 :5001                | tbd
data-store           | Data Storage         | VM2 (pgvector)           | tbd
```

**Current Phase:** Planning complete, infrastructure not yet deployed.

> **Two Independent VMs:** Can run simultaneously (chat while training).
> - VM1: Open WebUI + Ollama (inference)
> - VM2: MyAI + Training stack (training)

### X31) Quick Ref

#### VM Access

```bash
# VM1: TensorDock Inference (on-demand)
ssh root@<tensordock-inference-ip>

# VM2: TensorDock Training (on-demand)
ssh root@<tensordock-training-ip>
```

#### Service URLs

| Service        | VM   | Port  | Status    | URL                         |
|----------------|------|-------|-----------|-----------------------------|
| openwebui      | VM1  | 3000  | On-demand | chat.diegonmarcos.com       |
| ollama         | VM1  | 11434 | On-demand | (internal)                  |
| myai-dashboard | VM2  | 8080  | On-demand | myai.diegonmarcos.com       |
| myai-api       | VM2  | 8000  | On-demand | myai.diegonmarcos.com/api   |
| mlflow         | VM2  | 5001  | On-demand | mlflow.diegonmarcos.com     |

#### Docker Compose - VM1 (Inference)

```yaml
# docker-compose.yml (tensordock-inference)
services:
  openwebui:
    image: ghcr.io/open-webui/open-webui:main
    ports:
      - "3000:8080"
    volumes:
      - ./data:/app/backend/data
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
    depends_on:
      - ollama

  ollama:
    image: ollama/ollama:latest
    ports:
      - "11434:11434"
    volumes:
      - ./ollama:/root/.ollama
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
```

#### Docker Compose - VM2 (Training)

```yaml
# docker-compose.yml (tensordock-training)
services:
  myai-dashboard:
    build: ./myai-dashboard
    ports:
      - "8080:8080"
    depends_on:
      - myai-api

  myai-api:
    build: ./myai-api
    ports:
      - "8000:8000"
    volumes:
      - ./data:/app/data
    environment:
      - DATABASE_URL=postgresql://postgres:postgres@pgvector:5432/myai

  mlflow:
    image: ghcr.io/mlflow/mlflow:latest
    ports:
      - "5001:5000"
    volumes:
      - ./mlflow:/mlflow
    command: mlflow server --host 0.0.0.0 --backend-store-uri sqlite:///mlflow/mlflow.db

  pgvector:
    image: pgvector/pgvector:pg16
    environment:
      POSTGRES_DB: myai
      POSTGRES_PASSWORD: postgres
    volumes:
      - ./pgdata:/var/lib/postgresql/data
```

#### Pull Models - VM1 (First Time)

```bash
# After docker compose up on VM1
docker exec -it ollama ollama pull deepseek-coder-v2:14b-instruct-q4_K_M
docker exec -it ollama ollama pull llama3.1:8b-instruct-q4_K_M
docker exec -it ollama ollama pull mistral:7b-instruct-q4_K_M
```

---

---

---

---

# B) Architecture - Technical Deep Dives

## B0) Model Architecture

### B00) Model Selection & Routing

```mermaid
flowchart TD
    Q["User Query"] --> OW["Open WebUI"] --> R["Model Router"]
    R --> DS["DeepSeek Coder<br/>(Code)"]
    R --> LL["Llama 3.1 8B<br/>(General)"]
    R --> MI["Mistral 7B<br/>(Fast)"]
```

**Routing Rules:**
| Query Type | Model | Why |
|------------|-------|-----|
| Code generation | DeepSeek Coder v2 | Best code quality |
| General chat | Llama 3.1 8B | Good balance |
| Quick answers | Mistral 7B | Fastest response |

### B01) RAG Architecture

```mermaid
flowchart LR
    subgraph Indexing
        D["Documents"] --> C["Chunking"] --> E["Embeddings<br/>sentence-transformers"] --> V["Vector Store"]
    end
    subgraph Retrieval
        Q["Query"] --> QE["Embed"] --> SS["Similarity Search"] --> TK["Top-K Chunks"] --> LLM["LLM"]
    end
    V --> SS
```

**RAG Config (Open WebUI built-in):**
- Embedding model: sentence-transformers (local)
- Chunk size: 1000 tokens
- Chunk overlap: 200 tokens
- Top-K retrieval: 5 chunks

---

## B1) MCP Architecture

> **MOVED TO:** `MASTERPLAN_CLOUD.md` → B4) MCP Architecture
>
> MCPs are AI-agnostic infrastructure. Full documentation including:
> - B41) System Overview
> - B42) RAG Pipeline
> - B43) Security Model
> - B44) Permission Model
> - B45) Directory Structure
> - B46) Tool Specifications (12 MCPs)
> - B47) Implementation Patterns
> - B48) Dependencies & Testing

---

## B2) Training Pipeline

### B20) MyAI Training Flow

```mermaid
flowchart TD
    subgraph S1["1. DATA COLLECTION"]
        L["Local"] --> C["Collectors"] --> PG["pgvector"]
    end
    subgraph S2["2. PREPROCESSING"]
        R["Raw Data"] --> CL["Clean"] --> TOK["Tokenize"] --> DS["Dataset"]
    end
    subgraph S3["3. TRAINING"]
        DS2["Dataset"] --> PT["PyTorch"] --> FT["Fine-tune"] --> CK["Checkpoints"]
        PT -.-> MLF["MLflow"]
    end
    subgraph S4["4. EVALUATION"]
        CK2["Checkpoints"] --> EV["Eval Suite"] --> MET["Metrics"] --> DASH["Dashboard"]
    end
    subgraph S5["5. DEPLOYMENT"]
        BM["Best Model"] --> EX["Export"] --> OL["Ollama/GGUF"] --> SRV["Serve"]
    end
    S1 --> S2 --> S3 --> S4 --> S5
```

### B21) Experiment Tracking (MLflow)

| Metric | Description |
|--------|-------------|
| Loss | Training/validation loss curves |
| Perplexity | Model quality measure |
| BLEU/ROUGE | Text generation quality |
| Latency | Inference speed |
| Memory | GPU memory usage |

---

## B3) Infrastructure Architecture

### B30) GPU Provisioning

```mermaid
flowchart TD
    REQ["1. Request (chat/training)"] --> CHK{"2. VM running?"}
    CHK -->|Running| FWD["Forward request"]
    CHK -->|Stopped| PROV["Provision via TensorDock API"]
    PROV --> WAIT["3. Wait for VM ready"]
    WAIT --> FWD2["4. Forward request"]
    FWD --> IDLE["5. Auto-shutdown<br/>after 30 min idle"]
    FWD2 --> IDLE
```

### B31) Data Flow

```mermaid
flowchart LR
    subgraph Local["Local Machine"]
        DOC["Documents"]
        CODE["Code repos"]
        NOTES["Notes"]
    end
    COL["Collectors"]
    subgraph VMs["TensorDock VMs"]
        PG["pgvector (VM2)"]
        EMB["Embeddings + Metadata"]
        VM1["VM1 (Inference)<br/>RAG queries"]
        VM2["VM2 (Training)<br/>Training data"]
    end
    DOC --> COL
    CODE --> COL
    NOTES --> COL
    COL --> PG --> EMB
    EMB --> VM1
    EMB --> VM2
```

---

# C) Roadmap - Planning & Prioritization

## C0) Phases - Implementation Milestones

### C00) Phase 1: Basic Inference (PRIORITY)
**Status:** Planned
**Dependencies:** TensorDock account

| Step | Task | Status |
|------|------|--------|
| 1.1 | Create TensorDock account | Planned |
| 1.2 | Deploy VM1 with Docker | Planned |
| 1.3 | Setup Open WebUI + Ollama | Planned |
| 1.4 | Pull initial models | Planned |
| 1.5 | Test chat interface | Planned |

### C01) Phase 2: RAG Integration
**Status:** Planned
**Dependencies:** Phase 1

| Step | Task | Status |
|------|------|--------|
| 2.1 | Configure document upload in Open WebUI | Planned |
| 2.2 | Test RAG with local documents | Planned |
| 2.3 | Tune chunk size and retrieval | Planned |

### C02) Phase 3: Training Infrastructure
**Status:** Future
**Dependencies:** Phase 1

| Step | Task | Status |
|------|------|--------|
| 3.1 | Deploy VM2 with training stack | Future |
| 3.2 | Setup MLflow tracking | Future |
| 3.3 | Create data collection pipeline | Future |
| 3.4 | First fine-tuning experiment | Future |

### C03) Phase 4: Custom Models
**Status:** Future
**Dependencies:** Phase 3

| Step | Task | Status |
|------|------|--------|
| 4.1 | Collect personal data corpus | Future |
| 4.2 | Fine-tune on personal data | Future |
| 4.3 | Deploy custom model to VM1 | Future |

### C04) Phase 5: MCP System (Parallel Track)
**Status:** Planned
**Dependencies:** None (runs locally, independent of GPU VMs)

| Step | Task | Status |
|------|------|--------|
| 5.1 | Setup ChromaDB + index masterplans | Planned |
| 5.2 | Build masterplan-rag MCP | Planned |
| 5.3 | Build file-navigator MCP | Planned |
| 5.4 | Build git-integration MCP | Planned |
| 5.5 | Build secrets-manager MCP | Planned |
| 5.6 | Build cloud-cli MCP | Future |
| 5.7 | Build docker-manager MCP | Future |
| 5.8 | Build build-orchestrator MCP | Future |
| 5.9 | Build remaining MCPs (P3) | Future |

> **Note:** MCPs run locally on your machine, not on GPU VMs. Can be developed in parallel with other phases.

---

## C1) Dependencies - Service Graph

```mermaid
flowchart TB
    subgraph L0["LAYER 0: CLOUD INFRASTRUCTURE"]
        NPM["NPM (proxy)"] --> AUTH["Authelia (auth)"] --> DNS["DNS (Cloudflare)"]
    end

    subgraph L1["LAYER 1: AI INFERENCE (VM1)"]
        subgraph VM1["TensorDock VM1"]
            OW["Open WebUI"] --> OLL["Ollama"] --> MOD["Models"]
        end
    end

    subgraph L2["LAYER 2: AI TRAINING (VM2)"]
        subgraph VM2["TensorDock VM2"]
            MYAI["MyAI"] --> MLF["MLflow"] --> PGV["pgvector"]
        end
    end

    subgraph L3["LAYER 3: AI AGENT TOOLS (Local)"]
        subgraph LOCAL["Local Machine (~/.claude/)"]
            MCP1["MCP RAG<br/>(ChromaDB)"]
            MCP2["MCP Files<br/>(pathlib)"]
            MCP3["MCP Git<br/>(GitPython)"]
            MCP4["MCP Cloud<br/>(gcloud)"]
            MCP5["MCP Docker<br/>(SDK)"]
            MCP6["MCP Build<br/>(shell)"]
        end
    end

    L0 --> L1
    L0 --> L2
```

---

## C2) Backlog - Prioritized Tasks

### C20) High Priority (Now)
**GPU Infrastructure:**
- [ ] Setup TensorDock account and billing
- [ ] Create VM1 deployment script
- [ ] Test Open WebUI + Ollama locally first
- [ ] Document model pull commands

**MCP System (Parallel):**
- [ ] Setup ChromaDB + sentence-transformers locally
- [ ] Build masterplan-rag MCP (semantic search)
- [ ] Build file-navigator MCP (codebase search)
- [ ] Build git-integration MCP (history queries)
- [ ] Build secrets-manager MCP (safe credential paths)

### C21) Medium Priority (Next)
**GPU Infrastructure:**
- [ ] Configure RAG with personal documents
- [ ] Setup auto-shutdown script for idle VMs
- [ ] Create VM2 deployment script
- [ ] Setup MLflow tracking

**MCP System:**
- [ ] Build cloud-cli MCP (gcloud/oci wrapper)
- [ ] Build docker-manager MCP (service control)
- [ ] Build build-orchestrator MCP (18 projects)

### C22) Low Priority (Later)
- [ ] Build data collection pipelines
- [ ] First fine-tuning experiment
- [ ] Custom model deployment
- [ ] Multi-model routing optimization
- [ ] Build remaining MCPs (project-config, github-integration, monitoring)

### C23) Tech Debt
- [ ] Automate VM provisioning via API
- [ ] Create backup scripts for model weights
- [ ] Document training procedures
- [ ] Setup cost monitoring alerts
- [ ] MCP audit log rotation

---

# D) DevOps - Operations & Observability

## D0) Dashboard - AI Services Access

```mermaid
flowchart LR
    subgraph DASH["AI SERVICES DASHBOARD"]
        direction TB
        STATUS["VM1: OFF | VM2: OFF | [Start VM1]"]
        subgraph INF["INFERENCE (VM1)"]
            OW["Open WebUI<br/>status: off<br/>[Launch]"]
            OLL["Ollama<br/>Models: 3<br/>[Manage]"]
        end
        subgraph TRAIN["TRAINING (VM2)"]
            MYAI["MyAI<br/>status: off<br/>[Launch]"]
            MLF["MLflow<br/>Experiments: 0<br/>[View]"]
        end
    end
```

---

## D1) Monitoring - Metrics & Alerts

### D10) GPU Monitoring

| Metric | Warning | Critical | Action |
|--------|---------|----------|--------|
| GPU Temp | 75°C | 85°C | Throttle/shutdown |
| GPU Memory | 80% | 95% | Alert |
| GPU Utilization | - | - | Info only |
| VM Cost/day | $5 | $10 | Alert + auto-shutdown |

### D11) Cost Alerts

```
┌─────────────────────────────────────────────────────────────────┐
│  COST MONITORING                                                 │
├─────────────────────────────────────────────────────────────────┤
│  Daily budget: $5.00                                            │
│  Monthly budget: $50.00                                         │
│                                                                 │
│  Alerts:                                                        │
│  - 50% daily budget → Email warning                             │
│  - 80% daily budget → Email alert                               │
│  - 100% daily budget → Auto-shutdown VMs                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### D12) Health Checks

| Service | Endpoint | Method | Expected |
|---------|----------|--------|----------|
| Open WebUI | :3000/health | GET | 200 |
| Ollama | :11434/api/tags | GET | 200 |
| MyAI API | :8000/health | GET | 200 |
| MLflow | :5001/health | GET | 200 |

---

## D2) Knowledge Center

### D20) AI Documentation

| Document | Purpose | Location |
|----------|---------|----------|
| MASTERPLAN_AI.md | This document | 0.spec/ |
| Model Cards | Model capabilities & limits | docs/models/ |
| Training Guides | How to fine-tune | docs/training/ |
| RAG Setup | Document ingestion | docs/rag/ |

### D21) Runbooks

| Runbook | Purpose |
|---------|---------|
| vm-start.sh | Start GPU VM on-demand |
| vm-stop.sh | Stop VM and save state |
| model-pull.sh | Pull new models to Ollama |
| backup-models.sh | Backup model weights |
| cost-check.sh | Check current spending |

### D22) Quick Commands

```bash
# Start VM1 (Inference)
./scripts/vm-start.sh inference

# Start VM2 (Training)
./scripts/vm-start.sh training

# Check VM costs
./scripts/cost-check.sh

# Pull a new model
./scripts/model-pull.sh llama3:8b
```

---

# END OF MASTERPLAN_AI.md

> **Cross-references:**
> - MASTERPLAN_CLOUD.md - Cloud infrastructure, networking, services, and MCP Architecture (B4)
> - CLAUDE.md - Agent configuration and repository guidelines
> - A13) MCP section references MASTERPLAN_CLOUD.md B4 for MCP implementation details

---

*Generated by Claude (Opus) - CTO*
*Sub-document of: MASTERPLAN_CLOUD.md*
*Last Updated: 2025-12-12*

# Carcará

On-premise, privacy-first LLM platform for HPC clusters.

---

## Project Philosophy

These five principles orient every development decision. When in doubt, refer back here.

1. **Privacy above all.** No one — not even system administrators — should be able to read user conversations. Privacy is not a feature; it is the architectural foundation. Every component choice, configuration default, and operational procedure must preserve this guarantee.

2. **Open-source only.** Every component in the stack must be open-source, battle-tested, and community-backed. No vendor lock-in. If a proprietary tool is "better," we still choose the open-source alternative — because long-term maintainability, auditability, and independence matter more than short-term convenience.

3. **Model-agnostic.** The platform serves models; it is not tied to any one model. Swapping the underlying LLM — whether for performance, licensing, or state-of-the-art reasons — must be a configuration change, not a code change. Today's best model is tomorrow's legacy.

4. **Lean operations.** A team of 2-5 developers with IT support must be able to deploy, operate, monitor, and evolve the entire platform. If something requires a dedicated team to maintain, it's the wrong tool. Simplicity is a feature. Fewer moving parts means fewer things that break.

5. **Incremental value.** Every development phase delivers something usable. No multi-month buildouts before the first user can send a message. The platform grows in capability while remaining functional at every stage.

---

## Stack Definition

### Chosen Stack

| Component | Tool | Version/Image |
|-----------|------|---------------|
| Inference engine | **vLLM** | Latest stable |
| Chat UI | **Open WebUI** | `ghcr.io/open-webui/open-webui:main` |
| API gateway / router | **LiteLLM Proxy** | `ghcr.io/berriai/litellm-database:main-stable` |
| Reverse proxy / TLS | **Nginx** | `nginx:alpine` |
| Database | **PostgreSQL 16** | `postgres:16-alpine` |
| Cache / rate-limit state | **Redis 7** | `redis:7-alpine` |
| Metrics collection | **Prometheus** | `prom/prometheus` |
| Dashboards / alerting | **Grafana** | `grafana/grafana` |
| Log aggregation | **Loki** | `grafana/loki` |
| Log shipping | **Promtail** | `grafana/promtail` |
| GPU metrics | **NVIDIA DCGM Exporter** | NVIDIA container |
| System metrics | **Node Exporter** | `prom/node-exporter` |
| Multi-node coordination | **Ray** | Bundled with vLLM |
| Container orchestration | **Docker Compose** (or Podman Compose) | — |
| Job scheduling | **Slurm** (existing) | — |
| Authentication | **LDAP** (existing) | — |

### Why These Tools

**vLLM** (over TGI, TensorRT-LLM, SGLang):
- TGI entered maintenance mode (Dec 2025) — HuggingFace recommends vLLM or SGLang for new projects.
- TensorRT-LLM achieves higher peak throughput but requires weeks of engineering per model and a compilation step on every model change. Incompatible with model-agnostic philosophy.
- SGLang excels at shared-prefix workloads but has fewer production deployments and less Slurm documentation. Strong future candidate.
- vLLM: best time-to-first-token, native OpenAI-compatible API, mature Slurm+Ray integration, active community, Prometheus metrics built in, model swap = config change.

**Open WebUI** (over LibreChat, LobeChat):
- LobeChat has no LDAP support — disqualified.
- LibreChat has stronger enterprise features but heavier deployment (multi-service). Viable fallback.
- Open WebUI: native LDAP, single-container deploy, `ENABLE_ADMIN_CHAT_ACCESS=false` flag directly addresses privacy, most active development, OpenAI-compatible backend.

**LiteLLM Proxy** (over Kong, custom FastAPI):
- Kong is enterprise-grade but heavyweight — steep learning curve, overkill for this scale.
- Custom FastAPI means writing and maintaining solved problems (rate limiting, load balancing, usage tracking).
- LiteLLM: per-user rate limiting (TPM/RPM) out of the box, load balancing with health checks, usage tracking, `store_prompts=false` for privacy, lightweight Python service.

**Prometheus + Grafana + Loki** (over ELK, commercial APM):
- ELK (Elasticsearch + Logstash + Kibana) is resource-hungry and complex — a full-time job for a small team.
- Commercial solutions (Datadog, Splunk) violate on-premise and privacy requirements.
- This stack: vLLM exports Prometheus metrics natively (zero integration work), Loki is dramatically lighter than Elasticsearch, Grafana unifies metrics and logs, smallest resource footprint.

**Docker Compose** (over Kubernetes):
- With 2 GPU nodes and 1 management node, Kubernetes adds enormous complexity (etcd, control plane, GPU operator, PVCs) for zero benefit. If the cluster grows to 10+ nodes, K8s becomes worth reconsidering.

---

## Architecture

### Deployment Topology

```
Management Node (non-GPU)              GPU Node 1 (4x H100)        GPU Node 2 (4x H100)
================================       ======================       ======================
| Nginx           :443 (TLS)  |       | vLLM           :8000|       | vLLM           :8000|
| Open WebUI      :8080       |       | Node Exporter  :9100|       | Node Exporter  :9100|
| LiteLLM Proxy   :4000       |       | DCGM Exporter  :9400|       | DCGM Exporter  :9400|
| PostgreSQL      :5432       |       | Promtail       →Loki|       | Promtail       →Loki|
| Redis           :6379       |       ======================       ======================
| Prometheus      :9090       |                ↑                            ↑
| Grafana         :3000       |                |   (Slurm jobs)            |
| Loki            :3100       |                |                            |
================================       ========================================
         ↑                                         ↑
         |  HTTPS (:443)                           |
         |                                         |
    VPN boundary                              Internal network
         |
   [Users / API clients]
         |
   [LDAP Server :389] (existing)
```

### Request Flow

```
Web chat:   User → Nginx (:443) → Open WebUI (:8080) → LiteLLM (:4000) → vLLM (:8000)
API call:   Client → Nginx (:443) → LiteLLM (:4000) → vLLM (:8000)
```

Nginx routes by path:
- `/` → Open WebUI (chat interface)
- `/api/v1/` → LiteLLM Proxy (API gateway)
- `/grafana/` → Grafana (admin only)

### Two Deployment Modes

**Replicated mode** (models up to ~70B at FP8 / ~320GB VRAM):
- Independent vLLM instance on each GPU node
- LiteLLM load-balances across instances (least-busy strategy)
- ~4-5x better throughput than distributed mode
- Better fault isolation (one node failing doesn't affect the other)
- This is the default and preferred mode

**Distributed mode** (models >70B, e.g. 405B):
- Ray cluster: head on node 1, worker on node 2
- vLLM with `--tensor-parallel-size 4 --pipeline-parallel-size 2`
- Single model spans all 8 GPUs across both nodes
- Required only for very large models
- Higher latency due to cross-node communication

### Model Sizing Reference (H100 GPUs)

#### Coding-Focused Models (Recommended)

| Model | Type | Params | FP8 VRAM | GPUs per instance | HumanEval | SWE-bench | Best for |
|-------|------|--------|----------|-------------------|-----------|-----------|----------|
| **Qwen2.5-Coder-32B** | Dense | 32B | ~32GB | **1** (TP=1) | 92.7% | — | Fast coding, high throughput |
| **Llama 3.3 70B** | Dense | 70B | ~70GB | **2** (TP=2) | 89.0% | — | General + coding balance |
| **MiniMax-M2.5** | MoE | 230B (10B active) | ~115GB | **2** (TP=2) | — | **80.2%** | Best real-world coding |
| **Qwen3-Coder** | MoE | 480B (35B active) | ~240GB | **4** (TP=4) | — | 69.6% | Purpose-built coder |
| **DeepSeek-V3** | MoE | 671B (37B active) | ~335GB | **8** (TP=4 PP=2) | ~90% | ~50%+ | Multi-language coding |
| **GLM-5** | MoE | 744B (32B active) | ~372GB | **8** (TP=4 PP=2) | — | 77.8% | Competitive programming |
| **Llama 3.1 405B** | Dense | 405B | ~405GB | **8** (TP=4 PP=2) | 89.0% | — | Strongest dense reasoning |

#### General Models

| Model | Type | Params | FP8 VRAM | GPUs per instance | Notes |
|-------|------|--------|----------|-------------------|-------|
| Llama 3.1 8B | Dense | 8B | ~16GB | 1 | Dev/testing, lightweight tasks |
| Mistral 7B | Dense | 7B | ~16GB | 1 | Dev/testing |
| Qwen 2.5 72B | Dense | 72B | ~85GB | 2 (TP=2) | Strong general-purpose |
| Mistral Large 2 | Dense | 123B | ~140GB | 2-4 | General-purpose |

#### Quantization Impact on Coding (H100-specific)

| Precision | Throughput vs FP16 | Coding quality impact | Recommendation |
|-----------|-------------------|----------------------|----------------|
| **FP8** | **2x faster** (native H100 tensor cores) | **None** (identical HumanEval) | Default for all deployments |
| INT8 | 1.5x faster | Minimal | Acceptable fallback |
| INT4 | 2.7x faster | **-8 points HumanEval** (significant) | Avoid for coding |

**FP8 is always the right choice on H100s** — it's not a compromise, it's how the hardware is designed to run.

---

## Resource Architecture & Access Map

### Physical / Logical Machine Map

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          ORGANIZATIONAL VPN                                 │
│                                                                             │
│  ┌──────────────┐        ┌──────────────────────────────────────────────┐   │
│  │  LDAP Server │        │          HPC CLUSTER (Slurm-managed)        │   │
│  │  (existing)  │        │                                              │   │
│  │  :389/:636   │        │  ┌────────────────┐  ┌────────────────┐     │   │
│  └──────┬───────┘        │  │  GPU Node 1    │  │  GPU Node 2    │     │   │
│         │                │  │  4x H100       │  │  4x H100       │     │   │
│         │                │  │  320 GB VRAM   │  │  320 GB VRAM   │     │   │
│         │                │  │                │  │                │     │   │
│         │                │  │  vLLM  :8000   │  │  vLLM  :8000   │     │   │
│         │                │  │  DCGM  :9400   │  │  DCGM  :9400   │     │   │
│         │                │  │  NodeEx :9100   │  │  NodeEx :9100   │     │   │
│         │                │  │  Promtail      │  │  Promtail      │     │   │
│         │                │  └───────┬────────┘  └───────┬────────┘     │   │
│         │                │          │    HPC internal    │              │   │
│         │                │          │     network        │              │   │
│         │                └──────────┼───────────────────┼──────────────┘   │
│         │                           │                   │                   │
│         │                    ┌──────┴───────────────────┴──────┐            │
│         │                    │       Management Node           │            │
│         │                    │       (VM or bare metal)        │            │
│         ├────────────────────┤                                 │            │
│         │                    │  Nginx         :443  (public)   │            │
│         │  LDAP auth         │  Open WebUI    :8080 (internal) │            │
│         │                    │  LiteLLM       :4000 (internal) │            │
│         │                    │  PostgreSQL    :5432 (internal) │            │
│         │                    │  Redis         :6379 (internal) │            │
│         │                    │  Prometheus    :9090 (internal) │            │
│         │                    │  Grafana       :3000 (internal) │            │
│         │                    │  Loki          :3100 (internal) │            │
│         │                    └──────────────┬──────────────────┘            │
│         │                                   │                               │
│  ┌──────┴───────────────────────────────────┴──────────┐                   │
│  │                   VPN Users                          │                   │
│  │                                                      │                   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────────────┐   │                   │
│  │  │ Browser  │  │ Terminal │  │ IDE (VS Code,    │   │                   │
│  │  │ (Chat)   │  │ (curl,   │  │ JetBrains, etc.) │   │                   │
│  │  │          │  │ Python)  │  │                  │   │                   │
│  │  └──────────┘  └──────────┘  └──────────────────┘   │                   │
│  └──────────────────────────────────────────────────────┘                   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────┐                   │
│  │               Shared Filesystem (NFS/Lustre)        │                   │
│  │               /models/ — LLM weights                │                   │
│  │               Mounted on all GPU nodes              │                   │
│  └─────────────────────────────────────────────────────┘                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```
┌──────────────────────────────────────────────────────────────────┐
│                   DEVELOPER WORKSTATION (Local)                   │
│                                                                  │
│  docker-compose (dev stack)                                      │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌──────────────┐  │
│  │ Open WebUI │ │ LiteLLM    │ │ PostgreSQL │ │ Redis        │  │
│  │ :8080      │ │ :4000      │ │ :5432      │ │ :6379        │  │
│  └─────┬──────┘ └─────┬──────┘ └────────────┘ └──────────────┘  │
│        │              │                                          │
│  ┌─────┴──────┐ ┌─────┴──────┐ ┌────────────┐ ┌──────────────┐  │
│  │ Nginx      │ │ Ollama     │ │ OpenLDAP   │ │ Prometheus   │  │
│  │ :443       │ │ :11434     │ │ :389       │ │ Grafana      │  │
│  │ (self-sign)│ │ (tiny LLM) │ │ (test      │ │ Loki         │  │
│  │            │ │            │ │  users)    │ │              │  │
│  └────────────┘ └────────────┘ └────────────┘ └──────────────┘  │
│                                                                  │
│  Mocks/substitutions:                                            │
│   - Ollama + Phi-3-mini replaces vLLM + H100s                   │
│   - OpenLDAP container replaces real LDAP                        │
│   - Self-signed certs replace org CA certs                       │
│   - localhost replaces carcara.internal                           │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### Access Tiers

Development is organized into three access tiers. The goal is to **go as far as possible in Tier 1 and Tier 2 before involving Tier 3.**

#### Tier 1: Developer Workstation (no external access needed)

Everything runs locally via Docker. This is where the majority of development and integration work happens.

**What you can do:**
- Full service stack: Open WebUI + LiteLLM + PostgreSQL + Redis + Nginx
- LDAP auth flows via local OpenLDAP container (`osixia/openldap` with pre-seeded test users)
- LLM backend via Ollama with a small CPU model (Phi-3-mini ~3.8B, or TinyLlama ~1.1B for low-RAM machines)
- All configuration files, scripts, Makefile
- Nginx TLS with self-signed certificates
- Full observability stack (Prometheus, Grafana, Loki) — test dashboards, alerts, log pipelines
- Privacy hardening: pgcrypto, RLS, pgaudit — all testable on local PostgreSQL
- Custom code development (carcara-proxy)
- Integration tests, API tests, LDAP auth tests
- Rate limiting and usage tracking
- Grafana dashboard development

**What you mock/substitute:**
| Production component | Local substitute |
|---------------------|-----------------|
| vLLM on H100s | Ollama + Phi-3-mini (CPU, OpenAI-compat) |
| Real LDAP server | `osixia/openldap` Docker container with test users |
| Org CA TLS certs | Self-signed certificates |
| DNS (carcara.internal) | `localhost` or `/etc/hosts` entry |
| GPU metrics (DCGM) | Skipped (or mock Prometheus targets) |
| Slurm | Not needed — Ollama runs directly |
| Management node | Your laptop IS the management node |

**Docker Compose (dev) provides:**
- `open-webui`, `litellm`, `postgres`, `redis`, `nginx`, `openldap`
- `ollama` with a small model
- `prometheus`, `grafana`, `loki`

#### Tier 2: HPC Cluster (you have this access)

Direct access to GPU nodes via Slurm. No IT/network admin involvement needed.

**What you can do:**
- Install vLLM in a conda/venv on GPU nodes
- Write and test Slurm sbatch scripts
- Run vLLM with real models on real H100 GPUs
- Benchmark throughput, latency, TTFT
- Test Ray cluster for multi-node distributed inference
- Test model swapping (`scripts/swap-model.sh`)
- Install and test DCGM Exporter, Node Exporter on GPU nodes
- Download model weights to shared filesystem
- Test Promtail log shipping (if you can reach a Loki endpoint)
- Validate model configs (`configs/models/*.yaml`)

**What you CANNOT do from HPC alone:**
- Run management node services (they need a persistent server, not a Slurm job)
- Connect to the real LDAP server (may need network routing)
- Expose vLLM to users outside the HPC network

**Practical workflow:**
1. SSH into HPC login node
2. `sbatch slurm/vllm-single-node.sbatch` — starts vLLM on a GPU node
3. `curl http://gpu-node1:8000/v1/models` — verify from login node
4. Run benchmarks, iterate on model configs
5. All Slurm scripts and model configs are developed here

#### Tier 3: IT / Network Admin Involvement (request when ready)

These are things you cannot do yourself. Prepare specific, well-defined requests.

| What you need | Who to ask | When (phase) | What to tell them |
|--------------|-----------|-------------|------------------|
| **Management node** (VM or bare metal) | IT / Sysadmin | Before Phase 1 (prod) | "We need a Linux VM with Docker, ~16GB RAM, ~500GB disk, reachable from both VPN users and GPU nodes. Ports: 443 inbound from VPN, 8000 outbound to GPU nodes." |
| **DNS entry** (`carcara.internal`) | Network admin | Phase 1 (prod) | "A records pointing carcara.internal to the management node IP." |
| **TLS certificate** from org CA | IT / Security | Phase 1 (prod) | "TLS cert for carcara.internal signed by our org CA. We'll handle renewal via scripts." |
| **LDAP service account** | LDAP / Directory admin | Phase 4 (prod) | "Read-only bind account for user authentication lookups. We need: bind DN, password, search base, user filter. We do NOT modify LDAP data." |
| **Firewall rules** | Network admin | Phase 1 (prod) | "Management node → GPU nodes: TCP 8000, 9100, 9400. VPN users → Management node: TCP 443. GPU nodes → Management node: TCP 3100 (Loki)." |
| **Shared filesystem access** | HPC / Storage admin | Phase 2 | "GPU nodes need read access to model weights on NFS/Lustre. Path: `/models/` or similar." |
| **Network routing** (management ↔ HPC) | Network admin | Phase 3 (prod) | "Management node needs TCP access to GPU node ports 8000, 9100, 9400. GPU nodes need TCP access to management node port 3100." |

### Local-First Development Strategy

The key insight: **Phases 1, 3, 4, 7, 8, 9, 10 are almost entirely Tier 1 work.** You can build the full management-node stack, LDAP integration, observability, privacy hardening, API access, and operational tooling on your laptop before touching the HPC or asking IT for anything.

**Phase 2 (vLLM on Slurm)** and **Phases 5-6 (multi-node)** require Tier 2 (HPC access) but no IT involvement.

**Going to production** (deploying the management-node stack on a real server and connecting to real LDAP/GPU nodes) is when Tier 3 kicks in — and by then, you'll have a fully working system and know exactly what to ask for.

```
Development timeline and access needs:

Phase   Description                    Tier 1    Tier 2    Tier 3
        (local)                       (laptop)   (HPC)    (IT/admin)
─────   ─────────────────────────────  ────────  ────────  ──────────
  1     Foundation (docker-compose)      ***                  *
  2     vLLM on Slurm                              ***
  3     LiteLLM Proxy (API gateway)      ***
  4     Open WebUI + LDAP                ***                  *
  5     Second GPU node                            ***
  6     Multi-node inference                       ***
  7     Observability stack              ***
  8     Privacy hardening                ***
  9     API access for devs              ***
 10     Operational tooling              ***
 11     Testing and validation           **        **
 12     Production hardening             *                   ***

*** = primary work happens here
 ** = significant work
  * = minor touchpoint (prep or handoff)

Tier 3 is concentrated at the END (production deployment).
Everything before that is either local or HPC — both under your control.
```

### Capacity Planning (4 nodes = 16x H100 = 1,280GB VRAM)

Assumptions: peak:active ratio 3:1 (100 peak ≈ 33 active), coding prompt ~1,500 tokens, response ~250 tokens, think time ~15-20s between requests, FP8 quantization throughout. "Good experience" = 15-30 tok/sec per user.

#### Deployment Scenarios (quality-first ordering)

**Scenario A: MiniMax-M2.5 — best coding quality**
- 2 GPUs per replica (TP=2) → 8 replicas on 4 nodes
- ~3,200-4,800 tok/sec total
- 100 peak users: ~97-145 tok/sec per user (excellent)
- **2 nodes is enough for 100 users; 4 nodes serves 200-400+**

**Scenario B: Qwen2.5-Coder-32B — most efficient**
- 1 GPU per replica (TP=1) → 16 replicas on 4 nodes
- ~6,400-9,600 tok/sec total
- 100 peak users: ~194-290 tok/sec per user (overkill)
- **1 node is enough for 100 users; 4 nodes serves 500-1,000+**

**Scenario C: Qwen3-Coder — purpose-built coder**
- 4 GPUs per replica (TP=4, 1 full node) → 4 replicas on 4 nodes
- ~1,200-2,000 tok/sec total
- 100 peak users: ~36-60 tok/sec per user (good)
- **4 nodes right-sized for 100 users**

**Scenario D: Llama 3.3 70B — proven workhorse**
- 2 GPUs per replica (TP=2) → 8 replicas on 4 nodes
- ~2,400-4,000 tok/sec total
- 100 peak users: ~73-121 tok/sec per user (excellent)
- **2 nodes is enough for 100 users; 4 nodes serves 200-400**

**Scenario E: Mixed fleet (recommended starting point)**
- Nodes 1-2: 8x Qwen2.5-Coder-32B replicas (fast day-to-day coding)
- Nodes 3-4: 1x Qwen3-Coder or DeepSeek-V3 (heavy reasoning on demand)
- Total: fast coding for everyone + heavy model available when needed
- Reconfigure by editing `configs/deployments/active.yaml`

#### Scaling by User Count

| Peak users | Nodes needed | Recommended setup |
|-----------|-------------|------------------|
| Up to 100 | **2 nodes** | 8x Qwen2.5-Coder-32B replicas |
| Up to 200 | **4 nodes** | 16x Qwen2.5-Coder-32B, or mixed fleet |
| Up to 500 | **6 nodes** | 12x Qwen2.5-Coder-32B + 1x large model |
| Up to 1,000 | **8-10 nodes** | Mix of 32B replicas + large model instances |

---

## Privacy Architecture

Privacy is enforced through five defense layers. No single layer is sufficient alone; the combination provides the guarantee.

### Layer 1: Network Isolation
- All services behind organizational VPN. No public internet exposure.
- TLS 1.3 for all inter-service communication.
- PostgreSQL requires TLS connections (`sslmode=require`).
- GPU nodes accept connections only from the management node.

### Layer 2: Application Controls
- Open WebUI: `ENABLE_ADMIN_CHAT_ACCESS=false` — admins cannot view other users' conversations through the UI.
- Open WebUI: `ENABLE_ADMIN_EXPORT=false` — admins cannot bulk-export conversation data.
- Open WebUI: `DEFAULT_USER_ROLE=pending` — new users require explicit approval after LDAP login.
- LiteLLM: `store_prompts=false` — prompt/response content is never logged by the proxy.
- vLLM: `--disable-log-requests` — prompts do not appear in inference engine logs.

### Layer 3: Database Encryption
- PostgreSQL `pgcrypto` extension for column-level encryption of conversation content.
- Row-Level Security (RLS) on conversation tables — each user can only access their own rows, even via direct SQL.
- Separate database roles: `app_runtime` (RLS enforced, used by services) and `app_admin` (migrations only, credentials in vault).

### Layer 4: Audit Without Content
- `pgaudit` extension logs which user accessed which tables, when — without logging query data or conversation content.
- Prometheus metrics are numerical (tokens/sec, latency, queue depth) — no conversation content.
- Loki logs capture operational events (model loading, errors, GPU utilization) — never prompts or responses.

### Layer 5: Operational Controls
- Database backups encrypted with GPG/age, key held by organizational leadership.
- Separation of duties: GPU infrastructure admin ≠ database admin ≠ application admin.
- No single person holds all credentials needed to access conversation content.

### Layer 6 (Optional): Conversation Retention Policy
- Auto-delete conversations older than N days (configurable per organization or per user)
- Limits the blast radius if encryption is ever compromised — data that no longer exists cannot be leaked
- Open WebUI supports conversation retention settings
- Some users may actively prefer ephemeral conversations (no history kept)
- Can be combined with a user-facing toggle: "keep my history" vs "auto-delete after session/7d/30d/90d"
- Even without auto-delete, providing a "delete all my conversations" self-service button is a privacy baseline

This is not a substitute for encryption — it's a complementary measure. Encrypted data that also gets deleted is the strongest position.

### Future Enhancement: Carcará Privacy Proxy
An optional thin FastAPI service (`services/carcara-proxy/`) that provides per-user AES-256-GCM encryption of conversation content before it reaches the database. This makes database-level snooping impossible even with full DB access. Planned for Phase 8 if the defense-in-depth approach proves insufficient.

### Privacy Threat Model — How Private Is This Setup?

This section is an honest assessment of what this architecture protects against and what it does not.

**What is fully protected:**

| Threat | Protection | Confidence |
|--------|-----------|------------|
| External attacker (internet) | VPN-only, no public exposure | Very high |
| Network eavesdropping within VPN | TLS 1.3 on all connections | Very high |
| Curious admin browsing chats via UI | `ENABLE_ADMIN_CHAT_ACCESS=false` | High |
| Admin bulk-exporting conversations | `ENABLE_ADMIN_EXPORT=false` | High |
| Conversation content in logs | `--disable-log-requests`, `store_prompts=false` | High |
| Conversation content in metrics | Prometheus exports only numerical metrics | Very high |
| One user reading another user's DB rows | Row-Level Security (RLS) | High |
| Database backup stolen | GPG/age encrypted backups | High |
| Data at rest on disk | pgcrypto column encryption or TDE | High |

**What requires effort to breach (strong deterrent, not impossible):**

| Threat | Situation | Mitigation |
|--------|----------|------------|
| DBA with direct SQL access | A database admin connects to PostgreSQL and queries conversation tables | pgcrypto column encryption makes the data unreadable ciphertext. They see encrypted blobs, not plaintext. However, the encryption key must be available to the application at runtime — a DBA with access to the app's environment variables or config could theoretically extract it. Mitigation: store the key in a separate secrets manager, restrict access to the app service account only, audit all access. |
| Sysadmin with root on management node | Root access means they can inspect running processes, read memory, extract env vars | This is the hardest threat to fully mitigate. A root user can theoretically dump process memory and find decryption keys. Mitigations: separation of duties (the person with root on the management node is not the same person who manages the GPU nodes), audit logging of SSH access, consider Trusted Execution Environments (TEE) for future hardening. |
| Sysadmin with root on GPU nodes | Root on the GPU node where vLLM runs. vLLM sees plaintext prompts and responses in memory during inference. | This is inherent to how LLMs work — the model must see plaintext to generate responses. No encryption scheme can prevent this without Fully Homomorphic Encryption (not production-ready). Mitigation: vLLM does not persist prompts (`--disable-log-requests`), data exists only in GPU memory during inference and is overwritten by the next request. The window of exposure is seconds. |
| Compromised Open WebUI application | If the Open WebUI container is compromised, the attacker has the DB credentials and encryption key | Standard container security: minimal base images, no shell access, read-only filesystem, network segmentation. The Carcará Privacy Proxy (future enhancement) could add a second encryption layer that Open WebUI never sees. |

**What is NOT protected (honest limitations):**

| Threat | Why | What would fix it |
|--------|-----|------------------|
| A determined root admin who wants to read conversations | Root = god. They can read process memory, extract keys, intercept network traffic on the host. | Hardware-level Trusted Execution Environments (TEE), e.g. AMD SEV or Intel TDX. The model and data run inside an encrypted enclave that even root cannot inspect. This is emerging technology — production-ready but complex to set up. Could be a future enhancement. |
| The LLM itself "leaking" information | The model has seen the prompt. If it's a fine-tuned model, training data could theoretically be extracted. | Use only well-known base models (not fine-tuned on sensitive data). This is a general LLM risk, not specific to our architecture. |
| User's own device being compromised | If the user's laptop has malware, conversations are visible in the browser/terminal | Out of scope — this is endpoint security, not platform security. |
| Legal/compliance compelled disclosure | A court order could require access to conversations | Retention policies (auto-delete after N days) limit what's available. Legal question, not technical. |

**In plain language — how private is this?**

This setup is **significantly more private than any cloud LLM service** (ChatGPT, Claude, Gemini, etc.) and **more private than most enterprise self-hosted deployments**. Specifically:

- No data leaves your network. Ever.
- No third party sees any conversation. Ever.
- A casual or curious admin cannot read conversations through any normal interface.
- A database admin sees encrypted blobs, not plaintext.
- Logs and metrics contain zero conversation content.
- The only realistic attack vector is a **determined sysadmin with root access who actively tries to extract encryption keys from running processes** — and even that requires significant technical skill, leaves audit trails, and can be mitigated by separation of duties.

For most organizations operating within a trust boundary (your own employees, your own network, your own hardware), this level of privacy is strong. The remaining gap (root access to running processes) is the same gap that exists in every self-hosted system that isn't using hardware-level enclaves — including commercial enterprise solutions.

---

## Mono-Repo Structure

```
carcara/
├── .claude/
│   └── CLAUDE.md                       # This file — living architectural document
├── .gitignore
├── LICENSE
├── README.md
├── Makefile                            # Top-level operational targets
│
├── configs/                            # All configuration, centralized
│   ├── base/                           # Service configurations (committed)
│   │   ├── litellm-config.yaml         # LiteLLM proxy: models, routing, rate limits
│   │   ├── prometheus.yaml             # Prometheus scrape targets
│   │   ├── loki-config.yaml            # Loki storage and retention
│   │   ├── promtail-config.yaml        # Promtail log shipping rules
│   │   ├── nginx/
│   │   │   └── nginx.conf              # Reverse proxy routing and TLS
│   │   └── grafana/
│   │       ├── datasources.yaml        # Prometheus + Loki datasources
│   │       └── dashboards/
│   │           ├── vllm.json           # vLLM performance dashboard
│   │           ├── litellm.json        # Usage and rate-limit dashboard
│   │           └── system.json         # System and GPU health dashboard
│   ├── envs/                           # Environment variable templates
│   │   ├── production.env.example      # All variables documented, no real secrets
│   │   └── development.env.example
│   ├── models/                         # Per-model vLLM configurations
│   │   ├── qwen2.5-coder-32b.yaml     # 1 GPU per instance
│   │   ├── llama-3.3-70b.yaml         # 2-4 GPUs per instance
│   │   ├── qwen3-coder.yaml           # 4 GPUs per instance (MoE)
│   │   ├── deepseek-v3.yaml           # 8 GPUs, 2 nodes (MoE)
│   │   ├── llama-3.1-405b.yaml        # 8+ GPUs, multi-node
│   │   └── README.md                  # How to add a new model
│   └── deployments/                    # Deployment plans (cluster layouts)
│       ├── active.yaml                 # Currently active plan (symlink or copy)
│       ├── all-32b.yaml               # 16x Qwen2.5-Coder-32B (max throughput)
│       ├── mixed-fleet.yaml           # 8x fast coder + 1x heavy model
│       ├── all-70b.yaml               # 4x Llama 70B (balanced)
│       └── distributed-405b.yaml      # 1x Llama 405B across all nodes
│
├── slurm/                              # Slurm job templates
│   ├── vllm-single-gpu.sbatch.tmpl    # Template: 1-4 GPUs on one node
│   ├── vllm-multi-node.sbatch.tmpl    # Template: model spanning multiple nodes
│   ├── ray-cluster.sh                 # Ray head/worker bootstrap
│   └── README.md                      # Slurm job management guide
│
├── containers/                         # Container definitions
│   └── docker-compose.yaml            # Management node services stack
│
├── scripts/                            # Operational scripts
│   ├── deploy-fleet.sh                # Deploy from active deployment plan
│   ├── gen-litellm-config.sh          # Generate LiteLLM config from deployment plan
│   ├── swap-model.sh                  # Quick switch the active deployment plan
│   ├── add-node.sh                    # Add a new GPU node to deployment plans
│   ├── health-check.sh                # Verify all services are running
│   ├── backup-db.sh                   # Encrypted PostgreSQL backup
│   ├── restore-db.sh                  # Restore from backup
│   ├── rotate-tls-certs.sh           # TLS certificate rotation
│   └── user-management.sh            # LDAP user provisioning helpers
│
├── services/                           # Custom service code
│   └── carcara-proxy/                 # Optional: privacy encryption proxy
│       ├── pyproject.toml
│       ├── src/carcara_proxy/
│       │   ├── __init__.py
│       │   ├── main.py                # FastAPI app
│       │   ├── auth.py                # LDAP authentication
│       │   ├── encryption.py          # Per-user conversation encryption
│       │   ├── middleware.py          # Audit logging, request sanitization
│       │   └── config.py             # Pydantic settings
│       └── tests/
│
├── tests/                              # Integration and smoke tests
│   ├── test_e2e_chat.py
│   ├── test_api_access.py
│   ├── test_ldap_auth.py
│   ├── test_model_swap.py
│   └── conftest.py
│
└── docs/                               # Documentation
    ├── architecture.md                 # Architecture decisions and diagrams
    ├── deployment-guide.md             # Step-by-step deployment runbook
    ├── operations-runbook.md           # Day-to-day ops procedures
    ├── model-catalog.md                # Supported models and configs
    ├── api-guide.md                    # API usage guide for end users
    ├── privacy-policy.md              # Privacy architecture documentation
    └── development.md                 # Dev setup and contributing guide
```

### Structure Principles
- **`configs/`** is the single source of truth for all service configuration. Real secrets never committed — only `.env.example` templates.
- **`configs/models/`** defines WHAT can run (model parameters, GPU requirements). Adding a model = adding a YAML file.
- **`configs/deployments/`** defines WHERE things run (which models on which nodes). Reconfiguring the cluster = editing a YAML file.
- **`configs/base/litellm-config.yaml`** is **auto-generated** from the active deployment plan. Never edit manually.
- **`slurm/`** contains templates, not concrete jobs. Jobs are generated by `scripts/deploy-fleet.sh` from the deployment plan.
- **`containers/`** holds all container definitions for the management node.
- **`scripts/`** makes operations executable. Every routine task has a script.
- **`services/`** is reserved for custom code — kept minimal by design.

---

## Development Phases

### Phase 1: Foundation and Infrastructure
**Access**: Tier 1 (local) | **IT prep**: request management node VM for later

**Goal**: Management node stack ready, running locally.

- Initialize mono-repo directory structure
- Create `containers/docker-compose.dev.yaml` with local dev stack
- Set up PostgreSQL with TLS (self-signed), create databases for Open WebUI and LiteLLM
- Set up Redis
- Add Ollama service with Phi-3-mini as mock LLM backend
- Add `osixia/openldap` container with pre-seeded test users
- Configure Nginx with self-signed TLS and reverse proxy stubs
- Write `configs/envs/development.env.example` and `production.env.example`
- Start preparing Tier 3 request list (management node VM specs, DNS, TLS cert)

**Deliverable**: `docker-compose -f docker-compose.dev.yaml up` brings up the full local dev stack.

**IT request to send NOW** (so it's ready when you need it later):
> "We need a Linux VM for a new internal service: ~16GB RAM, ~500GB disk, Docker installed, reachable from VPN users and HPC GPU nodes. Also need a DNS entry (carcara.internal) and a TLS cert from org CA."

### Phase 2: vLLM on Slurm — Single Node
**Access**: Tier 2 (HPC) | Can run in parallel with Phase 1

**Goal**: One vLLM instance serving a model on one GPU node.

- Install vLLM and dependencies on GPU node (conda/venv)
- Create Slurm sbatch templates (`slurm/vllm-single-gpu.sbatch.tmpl`, `slurm/vllm-multi-node.sbatch.tmpl`)
- Create model configs: `configs/models/qwen2.5-coder-32b.yaml`, `configs/models/llama-3.3-70b.yaml`
- Create first deployment plan: `configs/deployments/single-node-test.yaml`
- Write `scripts/deploy-fleet.sh` that reads deployment plan → generates sbatch → submits
- Write `scripts/gen-litellm-config.sh` that generates LiteLLM config from deployment plan
- Download model weights to shared filesystem (may need to confirm path with HPC admin)
- Test: single 32B instance on 1 GPU, then 4 instances on 4 GPUs of one node

**Deliverable**: `curl http://gpu-node1:8000/v1/chat/completions` returns a response. Deployment plan system works.

### Phase 3: LiteLLM Proxy — API Gateway
**Access**: Tier 1 (local, backed by Ollama) | Test against HPC vLLM when available

**Goal**: Unified API gateway with rate limiting.

- Deploy LiteLLM Proxy container (locally, pointed at Ollama first)
- Configure `configs/base/litellm-config.yaml` with model backends
- Set up PostgreSQL database for LiteLLM
- Configure Redis for rate-limit state
- Create test API keys with rate limits (RPM, TPM)
- Test rate limiting, load balancing, usage tracking — all locally
- Later: swap `api_base` from Ollama to real vLLM endpoints for production

**Deliverable**: API calls through LiteLLM reach the backend with rate limiting enforced.

### Phase 4: Open WebUI + LDAP Authentication
**Access**: Tier 1 (local, using OpenLDAP mock) | **IT prep**: request LDAP service account

**Goal**: Web chat interface with LDAP authentication.

- Deploy Open WebUI container (locally, pointed at local OpenLDAP + Ollama via LiteLLM)
- Configure LDAP authentication against `osixia/openldap` container with test users
- Point Open WebUI at LiteLLM (`OPENAI_API_BASE_URL=http://litellm:4000/v1`)
- Set privacy flags: `ENABLE_ADMIN_CHAT_ACCESS=false`, `ENABLE_ADMIN_EXPORT=false`
- Configure Nginx routing: `/` → Open WebUI, `/api/v1/` → LiteLLM
- Test full flow: LDAP login → chat → response — all locally

**Deliverable**: User logs in via LDAP, chats with the model through the web UI (locally).

**IT request to send NOW**:
> "We need a read-only LDAP service account for user authentication lookups. We need: bind DN, password, search base DN, and user object filter. We will not modify any LDAP data."

### Phase 5: Multi-Node Fleet Deployment
**Access**: Tier 2 (HPC)

**Goal**: Deploy across multiple nodes with different configurations.

- Expand deployment to 2+ nodes using deployment plans
- Create deployment plan templates: `all-32b.yaml`, `mixed-fleet.yaml`, `all-70b.yaml`
- Test fleet reconfiguration: `make deploy PLAN=all-32b`, then `make deploy PLAN=mixed-fleet`
- Verify LiteLLM auto-config generation picks up all replicas and endpoints
- Verify load balancing (least-busy strategy) across all replicas
- Stress test with concurrent requests across multiple replicas
- Write `scripts/health-check.sh` (checks all instances in active plan)

**Deliverable**: Multiple deployment plans tested, fleet reconfiguration works end-to-end.

### Phase 6: Multi-Node Inference for Large Models
**Access**: Tier 2 (HPC)

**Goal**: Support models spanning multiple nodes via Ray.

- Write `slurm/ray-cluster.sh` (Ray head/worker bootstrap)
- Create model configs for large models: `deepseek-v3.yaml`, `llama-3.1-405b.yaml`
- Create deployment plan: `distributed-405b.yaml`
- Test: `make deploy PLAN=distributed-405b` starts Ray cluster + vLLM with pipeline parallelism
- Verify multi-node model responds correctly
- Benchmark: compare throughput of 1x distributed 405B vs 4x replicated 70B

**Deliverable**: Large models run across multiple nodes. Mixed fleet vs distributed trade-off is benchmarked.

### Phase 7: Observability Stack
**Access**: Tier 1 (local) | Tier 2 for GPU-specific metrics

**Goal**: Full monitoring, alerting, and log aggregation.

- Deploy Prometheus, Grafana, Loki, Promtail via `docker-compose.yaml`
- Configure Prometheus scrape targets: vLLM metrics, LiteLLM, Node Exporter, DCGM Exporter
- Create Grafana dashboards:
  - vLLM: requests/sec, tokens/sec, TTFT, queue depth, KV cache utilization
  - LiteLLM: per-user usage, rate-limit hits, error rates
  - System: CPU, memory, disk, GPU utilization, GPU temperature
- Configure alerting: vLLM down, GPU memory >95%, GPU temp >80C, error rate >5%
- Verify no conversation content appears in metrics or logs

**Deliverable**: Grafana dashboards with real-time cluster health and alerting.

### Phase 8: Privacy Hardening
**Access**: Tier 1 (local — all testable on local PostgreSQL)

**Goal**: Full database-level privacy controls.

- Enable pgcrypto column-level encryption on conversation tables
- Implement Row-Level Security (RLS) on Open WebUI's conversation tables
- Create separate PostgreSQL roles (`app_runtime` with RLS, `app_admin` for migrations)
- Install and configure `pgaudit` for access auditing
- Write `scripts/backup-db.sh` with GPG-encrypted backups
- Verify: connect as runtime role, confirm cannot read other users' conversations
- Document privacy architecture in `docs/privacy-policy.md`

**Deliverable**: Defense-in-depth privacy: network + application + database + audit.

### Phase 9: API Access for Developers
**Access**: Tier 1 (local)

**Goal**: Developers use the platform from terminals, scripts, and IDEs.

- Document API access pattern in `docs/api-guide.md`
- Set up API key provisioning workflow (LiteLLM `/key/generate` or Open WebUI self-service)
- Configure per-user rate limits
- Write usage examples: Python (`openai` SDK), `curl`, IDE integration guides
- Test end-to-end: `openai.ChatCompletion.create()` with `base_url="https://carcara.internal/api/v1"`

**Deliverable**: API docs, working examples, rate-limited keys for developers.

### Phase 10: Operational Tooling and Automation
**Access**: Tier 1 (local)

**Goal**: Lean operations for the small team.

- Write `Makefile` with targets: `up`, `down`, `deploy-model`, `status`, `backup`, `logs`, `add-node`
- Write `scripts/add-node.sh` — provisions new GPU nodes (Prometheus targets, LiteLLM config, Promtail)
- Implement Slurm job monitoring (cron/systemd timer to auto-restart crashed vLLM jobs)
- Write `scripts/rotate-tls-certs.sh`
- Write `scripts/user-management.sh` (approve pending users, check usage, reset rate limits)

**Deliverable**: Day-two operations are scripted. Running the platform feels lightweight.

### Phase 11: Testing and Validation
**Access**: Tier 1 (local) + Tier 2 (HPC) for load tests

**Goal**: Confidence that everything works end-to-end.

- Write integration tests: e2e chat, API access, LDAP auth, model swap
- Load testing with `locust` or `vegeta` at expected concurrency
- Privacy audit: encrypted DB contents, admin access blocked, clean logs
- Failover testing: kill one vLLM instance, verify traffic routes to the other

**Deliverable**: Test suite and load-test results proving reliability.

### Phase 12: Production Deployment and Hardening
**Access**: Tier 3 (IT/admin) — this is where external teams are needed

**Goal**: Deploy to production infrastructure, connect real services.

- **IT delivers**: management node VM, DNS, TLS cert, LDAP service account, firewall rules
- Deploy docker-compose stack on management node (same configs, swap env from dev to prod)
- Swap LDAP config from OpenLDAP to real LDAP server
- Swap LiteLLM backend from Ollama to real vLLM endpoints on GPU nodes
- Harden Nginx (security headers, cipher selection, HSTS)
- Harden PostgreSQL (connection limits, timeouts)
- Harden Redis (requirepass, disable dangerous commands)
- Write complete `docs/operations-runbook.md`
- Write `docs/model-catalog.md` with tested models and optimal configs
- Final secret audit — no credentials in repo
- Tag v1.0.0

**Deliverable**: Production-ready platform, fully connected, fully documented.

**IT handoff document** (prepared during dev phases):
> - Management node VM specs: Linux, Docker, 16GB RAM, 500GB disk
> - DNS: `carcara.internal` → management node IP
> - TLS: cert for `carcara.internal` from org CA
> - Firewall: management node ↔ GPU nodes (TCP 8000, 9100, 9400, 3100), VPN → management node (TCP 443)
> - LDAP: read-only service account (bind DN, password, search base, user filter)
> - Network routing: management node must reach GPU nodes and vice versa

---

## Scaling Strategy

### Adding GPU Nodes

1. Install vLLM environment on the new node (same conda/venv as existing)
2. Run `scripts/add-node.sh gpu-node5` which:
   - Adds the node to `configs/base/prometheus.yaml` scrape targets
   - Deploys Promtail config to the new node
   - Outputs the node definition to add to deployment plans
3. Edit the active deployment plan to include the new node:
   ```yaml
   # configs/deployments/active.yaml
   nodes:
     # ... existing nodes ...
     gpu-node5: { host: "10.0.2.5", gpus: 4 }    # ← add this

   deployments:
     - model: qwen2.5-coder-32b
       nodes: [gpu-node1, gpu-node2, gpu-node5]   # ← add node here
   ```
4. Run `make deploy` — generates Slurm jobs, updates LiteLLM config, reloads

Throughput scales linearly for replicated models. Each node adds capacity based on `gpus_per_instance`:
- 32B model (1 GPU per instance): +4 replicas per node
- 70B model (2 GPUs per instance): +2 replicas per node
- Large MoE (4 GPUs per instance): +1 replica per node

### Reconfiguring the Fleet

Changing the cluster layout is a config change, not a code change:

```bash
# Switch from all-32B to mixed fleet
make deploy PLAN=mixed-fleet

# Or edit the active plan directly and redeploy
vim configs/deployments/active.yaml
make deploy
```

This cancels all running Slurm jobs, submits new ones per the updated plan, regenerates the LiteLLM config, and reloads. Downtime is limited to model loading time (~30s for 32B, ~2-5min for large models).

### Scaling Management Node Services

If the management node becomes a bottleneck (unlikely for <10 GPU nodes):
- Open WebUI: multiple instances behind Nginx with shared PostgreSQL + Redis
- LiteLLM: multiple proxy instances with shared Redis for rate-limit state
- PostgreSQL: pgBouncer for connection pooling, read replicas if needed

### Storage

- Model weights: shared filesystem (NFS/Lustre, typical for HPC). New nodes mount the same path.
- PostgreSQL: standard scaling — larger disk, read replicas if needed.

---

## API Design

### External Access

All API access goes through Nginx → LiteLLM Proxy. The API is fully **OpenAI-compatible** — any tool supporting the OpenAI API works out of the box.

**Base URL**: `https://carcara.internal/api/v1`
**Authentication**: Bearer token (LiteLLM virtual key)

### Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/chat/completions` | POST | Chat completion (streaming and non-streaming) |
| `/api/v1/models` | GET | List available models |
| `/api/v1/completions` | POST | Text completion |
| `/api/v1/embeddings` | POST | Embeddings (if model supports) |

### Rate Limiting

Enforced by LiteLLM per API key:
- **RPM**: Requests per minute
- **TPM**: Tokens per minute
- Returns HTTP 429 with `Retry-After` header when exceeded
- Limits reset automatically over time

### Usage Examples

**Python** (standard `openai` SDK):
```python
from openai import OpenAI

client = OpenAI(
    base_url="https://carcara.internal/api/v1",
    api_key="sk-user-key-here",
)

response = client.chat.completions.create(
    model="llama-3.1-70b",
    messages=[{"role": "user", "content": "Hello"}],
    stream=True,
)
for chunk in response:
    print(chunk.choices[0].delta.content or "", end="")
```

**curl**:
```bash
curl https://carcara.internal/api/v1/chat/completions \
  -H "Authorization: Bearer sk-user-key-here" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama-3.1-70b","messages":[{"role":"user","content":"Hello"}]}'
```

---

## Slurm Integration

vLLM runs as long-running Slurm jobs (not containers) on GPU nodes to avoid GPU-passthrough overhead.

### Job Lifecycle
- `scripts/health-check.sh` runs every 60s (cron/systemd timer) and resubmits crashed jobs
- `scripts/deploy-fleet.sh` reads the active deployment plan and submits/updates Slurm jobs accordingly
- `scripts/swap-model.sh` cancels current jobs (`scancel`), deploys a new configuration
- vLLM handles SIGTERM gracefully (finishes in-flight requests before exiting)

### Two-Layer Configuration

Configuration is split into **what** (model config) and **where** (deployment plan).

#### Layer 1: Model Configs (`configs/models/*.yaml`)

Each model gets a YAML defining its vLLM parameters. These are reusable across any deployment plan.

```yaml
# configs/models/qwen2.5-coder-32b.yaml
model_id: "Qwen/Qwen2.5-Coder-32B-Instruct"
gpus_per_instance: 1               # tensor_parallel_size (GPUs per vLLM process)
nodes_per_instance: 1              # pipeline_parallel_size (nodes spanned)
max_model_len: 32768
gpu_memory_utilization: 0.90
quantization: "fp8"
extra_args: "--enable-prefix-caching --disable-log-requests"
```

```yaml
# configs/models/qwen3-coder.yaml
model_id: "Qwen/Qwen3-Coder"
gpus_per_instance: 4               # uses all 4 GPUs on a node
nodes_per_instance: 1
max_model_len: 32768
gpu_memory_utilization: 0.92
quantization: "fp8"
extra_args: "--enable-prefix-caching --disable-log-requests"
```

```yaml
# configs/models/deepseek-v3.yaml
model_id: "deepseek-ai/DeepSeek-V3"
gpus_per_instance: 4
nodes_per_instance: 2              # spans 2 nodes via Ray (PP=2)
max_model_len: 16384
gpu_memory_utilization: 0.92
quantization: "fp8"
extra_args: "--enable-prefix-caching --disable-log-requests --distributed-executor-backend ray"
```

#### Layer 2: Deployment Plan (`configs/deployments/*.yaml`)

Describes the entire cluster layout — which models run on which nodes, how many replicas. This is the file you edit to reconfigure the cluster.

```yaml
# configs/deployments/active.yaml
# The active deployment plan. Edit and run `make deploy` to apply.
# Symlink or copy from one of the templates below.

nodes:
  gpu-node1: { host: "10.0.2.1", gpus: 4 }
  gpu-node2: { host: "10.0.2.2", gpus: 4 }
  gpu-node3: { host: "10.0.2.3", gpus: 4 }
  gpu-node4: { host: "10.0.2.4", gpus: 4 }

deployments:
  - model: qwen2.5-coder-32b        # references configs/models/qwen2.5-coder-32b.yaml
    nodes: [gpu-node1, gpu-node2]    # deploy on these nodes
    # gpus_per_instance=1, so 4 instances per node × 2 nodes = 8 replicas
    # Each gets a unique port: 8000, 8001, 8002, 8003 per node

  - model: qwen3-coder
    nodes: [gpu-node3, gpu-node4]    # these nodes run the big model
    # gpus_per_instance=4, so 1 instance per node = 2 replicas
```

#### Deployment Plan Templates

Pre-made plans for common configurations:

```yaml
# configs/deployments/all-32b.yaml — Maximum throughput (500+ users)
# 16 replicas of Qwen2.5-Coder-32B across all 4 nodes
deployments:
  - model: qwen2.5-coder-32b
    nodes: [gpu-node1, gpu-node2, gpu-node3, gpu-node4]

# configs/deployments/mixed-fleet.yaml — Fast coding + heavy reasoning
# 8 fast replicas on nodes 1-2, 1 large model on nodes 3-4
deployments:
  - model: qwen2.5-coder-32b
    nodes: [gpu-node1, gpu-node2]
  - model: qwen3-coder
    nodes: [gpu-node3, gpu-node4]

# configs/deployments/all-70b.yaml — Balanced quality/throughput
# 4 replicas of Llama 3.3 70B, one per node (TP=4)
deployments:
  - model: llama-3.3-70b
    nodes: [gpu-node1, gpu-node2, gpu-node3, gpu-node4]

# configs/deployments/distributed-405b.yaml — Maximum model quality
# 1 instance of Llama 405B spanning all 4 nodes
deployments:
  - model: llama-3.1-405b
    nodes: [gpu-node1, gpu-node2, gpu-node3, gpu-node4]
```

#### How `make deploy` works

```
make deploy                              # applies configs/deployments/active.yaml
make deploy PLAN=mixed-fleet             # applies configs/deployments/mixed-fleet.yaml
```

The deploy script (`scripts/deploy-fleet.sh`):
1. Reads the deployment plan YAML
2. For each deployment entry, reads the model config YAML
3. Calculates replicas: `(node_gpus ÷ gpus_per_instance) × number_of_nodes`
4. For multi-node models (`nodes_per_instance > 1`): groups nodes and starts Ray clusters
5. For single-GPU models: assigns `CUDA_VISIBLE_DEVICES` and unique ports (8000, 8001, ...)
6. Generates Slurm sbatch scripts from templates and submits them
7. **Auto-generates** `configs/base/litellm-config.yaml` with all endpoints and ports
8. Reloads LiteLLM to pick up the new config

#### Slurm Job Templates

Two templates handle all cases:

```bash
# slurm/vllm-single-gpu.sbatch.tmpl — for models using ≤4 GPUs on one node
#SBATCH --job-name=carcara-{{model_name}}-{{instance_id}}
#SBATCH --partition=gpu
#SBATCH --nodes=1
#SBATCH --nodelist={{node}}
#SBATCH --gres=gpu:{{gpus_per_instance}}
#SBATCH --cpus-per-task={{cpus}}
#SBATCH --mem={{memory}}
#SBATCH --time=UNLIMITED
#SBATCH --requeue

export CUDA_VISIBLE_DEVICES={{gpu_ids}}

vllm serve {{model_id}} \
    --host 0.0.0.0 --port {{port}} \
    --tensor-parallel-size {{gpus_per_instance}} \
    --gpu-memory-utilization {{gpu_memory_utilization}} \
    --max-model-len {{max_model_len}} \
    --api-key ${VLLM_API_KEY} \
    {{extra_args}}
```

```bash
# slurm/vllm-multi-node.sbatch.tmpl — for models spanning multiple nodes
#SBATCH --job-name=carcara-{{model_name}}
#SBATCH --partition=gpu
#SBATCH --nodes={{nodes_per_instance}}
#SBATCH --nodelist={{node_list}}
#SBATCH --gres=gpu:4
#SBATCH --cpus-per-task=32
#SBATCH --mem=256G
#SBATCH --time=UNLIMITED
#SBATCH --requeue

# Start Ray cluster, then vLLM with pipeline parallelism
source slurm/ray-cluster.sh {{nodes_per_instance}}

vllm serve {{model_id}} \
    --host 0.0.0.0 --port 8000 \
    --tensor-parallel-size {{gpus_per_instance}} \
    --pipeline-parallel-size {{nodes_per_instance}} \
    --distributed-executor-backend ray \
    --gpu-memory-utilization {{gpu_memory_utilization}} \
    --max-model-len {{max_model_len}} \
    --api-key ${VLLM_API_KEY} \
    {{extra_args}}
```

#### Auto-Generated LiteLLM Config

`scripts/deploy-fleet.sh` generates the LiteLLM config from the deployment plan. Example output for `mixed-fleet.yaml`:

```yaml
# configs/base/litellm-config.yaml (AUTO-GENERATED — do not edit manually)
# Generated from: configs/deployments/mixed-fleet.yaml
# Re-generate with: make deploy PLAN=mixed-fleet

model_list:
  # Qwen2.5-Coder-32B replicas (nodes 1-2, 8 instances)
  - model_name: qwen2.5-coder-32b
    litellm_params:
      model: openai/Qwen/Qwen2.5-Coder-32B-Instruct
      api_base: http://10.0.2.1:8000/v1
      api_key: os.environ/VLLM_API_KEY
  - model_name: qwen2.5-coder-32b
    litellm_params:
      model: openai/Qwen/Qwen2.5-Coder-32B-Instruct
      api_base: http://10.0.2.1:8001/v1
      api_key: os.environ/VLLM_API_KEY
  # ... (6 more replicas)

  # Qwen3-Coder replicas (nodes 3-4, 2 instances)
  - model_name: qwen3-coder
    litellm_params:
      model: openai/Qwen/Qwen3-Coder
      api_base: http://10.0.2.3:8000/v1
      api_key: os.environ/VLLM_API_KEY
  - model_name: qwen3-coder
    litellm_params:
      model: openai/Qwen/Qwen3-Coder
      api_base: http://10.0.2.4:8000/v1
      api_key: os.environ/VLLM_API_KEY

router_settings:
  routing_strategy: "least-busy"
  redis_host: redis
  redis_port: 6379

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
  store_prompts: false
```

Users select the model by name in their request (`model: "qwen2.5-coder-32b"` or `model: "qwen3-coder"`). LiteLLM load-balances across all replicas of that model.

---

## Network Topology

```
VPN Gateway
  |
  +-- Management Node (10.0.1.10)
  |     Nginx :443, PostgreSQL :5432, Redis :6379
  |     Open WebUI :8080, LiteLLM :4000
  |     Prometheus :9090, Grafana :3000, Loki :3100
  |
  +-- GPU Node 1 (10.0.2.1)
  |     vLLM :8000, Node Exporter :9100, DCGM Exporter :9400
  |
  +-- GPU Node 2 (10.0.2.2)
  |     vLLM :8000, Node Exporter :9100, DCGM Exporter :9400
  |
  +-- LDAP Server (10.0.1.5, existing)
```

### Firewall Rules
- Management node: accepts :443 from VPN. Internal ports only from localhost and known IPs.
- GPU nodes: accept :8000 only from management node. Accept :9100, :9400 only from Prometheus.

---

## Configuration Management

### Principles
- **No secrets in the repository.** Sensitive values in `.env` files (gitignored) or secret manager.
- **`.env.example` templates** document every required variable.
- **Base configs** in `configs/base/` are committed and version-controlled.
- **Environment overrides** via environment variables (12-factor style).
- **Two-layer model config**: `configs/models/` defines what (model params), `configs/deployments/` defines where (cluster layout).
- **LiteLLM config is auto-generated** from the deployment plan. The deployment plan is the source of truth.

### Changing the Cluster Layout

```bash
# Edit the deployment plan
vim configs/deployments/active.yaml

# Or switch to a pre-made plan
make deploy PLAN=mixed-fleet

# This will:
# 1. Cancel all running vLLM Slurm jobs
# 2. Generate new sbatch scripts from templates + deployment plan
# 3. Submit new Slurm jobs
# 4. Regenerate configs/base/litellm-config.yaml
# 5. Reload LiteLLM proxy
```

### Adding a New Model

1. Create `configs/models/new-model.yaml` with model params
2. Add the model to a deployment plan
3. Run `make deploy`

---

## Conventions

- All services communicate via OpenAI-compatible API protocol
- Configuration over code: behavior changes through YAML/env, not source edits
- Scripts are idempotent where possible
- Commit messages follow conventional commits (`feat:`, `fix:`, `ops:`, `docs:`)
- Python code follows the project's linting/formatting configuration
- No conversation content in any log, metric, or audit trail

---
name: carcara-ops
description: Core operational knowledge for Carcará on-premise LLM platform — architecture, conventions, bootstrapping, and Docker-first execution strategy
---

# Carcará Operations Skill

You are operating within the `carcara` repository — an on-premise, privacy-first LLM platform for HPC clusters running vLLM on NVIDIA H100 GPUs.

## Core Philosophy (Non-Negotiable)

1. **Privacy above all.** No conversation content in logs, metrics, or audit trails. Ever.
2. **Open-source only.** No proprietary dependencies.
3. **Model-agnostic.** Swapping a model = editing a YAML, never code.
4. **Lean operations.** A team of 2–5 people runs everything.
5. **Incremental value.** Every phase delivers something usable.

## Absolute Minimum: Docker

- Docker is the **only hard requirement** on the executor's machine.
- ALWAYS run `bash scripts/initialize.sh` as the first step. If Docker is missing, the script fails gracefully with installation instructions — never attempt aggressive OS package installations.
- If the machine lacks `python3`, `curl`, `jq`, or `make`, use Docker containers as drop-in replacements:
  ```bash
  # curl via Docker
  docker run --rm curlimages/curl:latest http://host.docker.internal:4000
  # python via Docker
  docker run --rm -v $(pwd):/app -w /app python:3.12-slim python scripts/myscript.py
  # jq via Docker
  echo '{}' | docker run --rm -i ghcr.io/jqlang/jq:latest '.'
  ```

## Tier System — Know Your Boundary

| Tier | Environment | What You Can Do | What You Cannot Do |
|------|------------|-----------------|-------------------|
| **Tier 1** | Local workstation (Docker) | Full stack: Open WebUI + LiteLLM + PostgreSQL + Redis + Nginx + Ollama + LDAP mock + Prometheus/Grafana/Loki | Real GPU inference, real LDAP |
| **Tier 2** | HPC cluster (Slurm) | vLLM on real GPUs, Slurm jobs, Ray clusters, model benchmarks, DCGM/Node Exporter | Management node services, user-facing endpoints |
| **Tier 3** | IT/Admin involvement | Management node VM, DNS, TLS certs, LDAP service account, firewall rules | N/A — this is the production boundary |

**Rule: ALWAYS develop in Tier 1 first.** Only move to Tier 2 when explicitly instructed. Never request Tier 3 resources without a prepared handoff document.

## Repository Layout

```
carcara/
├── configs/
│   ├── base/              # Service configs (committed). litellm-config.yaml is AUTO-GENERATED
│   ├── envs/              # .env templates (.env.example committed, .env gitignored)
│   ├── models/            # Per-model vLLM parameters (YAML). Adding a model = adding a file
│   └── deployments/       # Cluster layout plans. Editing = reconfiguring the cluster
├── slurm/                 # Sbatch templates (not concrete jobs)
├── containers/            # Docker Compose files for management node
├── scripts/               # Operational scripts (initialize, deploy, backup, health-check)
├── services/              # Custom code (carcara-proxy for optional encryption)
├── skills/                # Agent skills (you are reading one)
├── agents/workflows/      # Agent workflow definitions
├── tests/                 # Integration and smoke tests
└── docs/                  # Architecture, deployment, operations documentation
```

### Critical Files

| File | Purpose | Rule |
|------|---------|------|
| `configs/base/litellm-config.yaml` | LiteLLM routing config | **AUTO-GENERATED** by `scripts/deploy-fleet.sh`. Never edit manually. |
| `configs/deployments/active.yaml` | Current cluster layout | Source of truth. Edit this, then `make deploy`. |
| `configs/models/*.yaml` | Model parameters (TP, VRAM, quantization) | One file per model. Reusable across deployment plans. |
| `configs/envs/*.env.example` | Environment variable documentation | All variables documented. No real secrets committed. |

## Two-Layer Configuration Model

**Layer 1 — Model Configs** (`configs/models/*.yaml`): Define WHAT can run.
```yaml
model_id: "Qwen/Qwen2.5-Coder-32B-Instruct"
gpus_per_instance: 1
quantization: "fp8"
extra_args: "--enable-prefix-caching --disable-log-requests"
```

**Layer 2 — Deployment Plans** (`configs/deployments/*.yaml`): Define WHERE things run.
```yaml
nodes:
  gpu-node1: { host: "10.0.2.1", gpus: 4 }
deployments:
  - model: qwen2.5-coder-32b
    nodes: [gpu-node1]
```

## Operational Scripts Reference

| Script | Phase | Purpose |
|--------|-------|---------|
| `scripts/initialize.sh` | All | Verify Docker, scaffold dirs, create .env |
| `scripts/deploy-fleet.sh` | 2/5/6 | Read deployment plan → generate sbatch → submit Slurm jobs → regenerate LiteLLM config |
| `scripts/gen-litellm-config.sh` | 3 | Generate LiteLLM config from deployment plan |
| `scripts/swap-model.sh` | 5 | Cancel current jobs, deploy new config |
| `scripts/health-check.sh` | 10 | Verify all services, resubmit crashed Slurm jobs |
| `scripts/backup-db.sh` | 8 | GPG-encrypted PostgreSQL backup |
| `scripts/add-node.sh` | 5 | Add GPU node to Prometheus targets + deployment plans |
| `scripts/user-management.sh` | 9 | Approve pending users, check usage, reset rate limits |

## Conventions

- All services communicate via OpenAI-compatible API protocol
- Configuration over code: behavior changes through YAML/env, never source edits
- Scripts are idempotent where possible
- Commit messages: `feat:`, `fix:`, `ops:`, `docs:`
- **No conversation content in any log, metric, or audit trail**

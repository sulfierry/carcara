---
name: carcara-hpc-slurm
description: HPC cluster management — Slurm job orchestration, vLLM deployment on GPU nodes, Ray distributed inference, and fleet scaling for Carcará
---

# Carcará HPC & Slurm Integration Skill

This skill governs all operations on Tier 2 (HPC cluster). You manage GPU resources, Slurm jobs, Ray clusters, and model deployments across NVIDIA H100 nodes.

## Architecture Context

```
GPU Node (4x H100, 320GB VRAM each)
├── vLLM process(es) — one per model replica
├── Node Exporter :9100 — system metrics
├── DCGM Exporter :9400 — GPU metrics
└── Promtail — log shipping to Loki on management node
```

- vLLM runs as **long-running Slurm jobs** (not containers) to avoid GPU-passthrough overhead.
- Each GPU node has 4x H100 GPUs = 320GB VRAM total.
- Models are stored on shared filesystem (NFS/Lustre) mounted at `/models/`.

## Slurm Job Lifecycle

1. `scripts/deploy-fleet.sh` reads `configs/deployments/active.yaml`
2. For each deployment entry, reads the model config from `configs/models/*.yaml`
3. Calculates replicas: `(node_gpus ÷ gpus_per_instance) × number_of_nodes`
4. For multi-node models (`nodes_per_instance > 1`): starts Ray cluster first
5. For single-node models: assigns `CUDA_VISIBLE_DEVICES` and unique ports (8000, 8001, ...)
6. Generates sbatch scripts from `slurm/*.sbatch.tmpl` templates
7. Submits to Slurm via `sbatch`
8. Auto-generates `configs/base/litellm-config.yaml`
9. Reloads LiteLLM to pick up new endpoints

## Sbatch Template System

Two templates handle all cases:

**Single-node** (`slurm/vllm-single-gpu.sbatch.tmpl`):
```bash
#SBATCH --job-name=carcara-{{model_name}}-{{instance_id}}
#SBATCH --partition=gpu
#SBATCH --nodes=1
#SBATCH --nodelist={{node}}
#SBATCH --gres=gpu:{{gpus_per_instance}}
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

**Multi-node** (`slurm/vllm-multi-node.sbatch.tmpl`):
```bash
#SBATCH --job-name=carcara-{{model_name}}
#SBATCH --nodes={{nodes_per_instance}}
#SBATCH --nodelist={{node_list}}
#SBATCH --gres=gpu:4
#SBATCH --time=UNLIMITED
#SBATCH --requeue

source slurm/ray-cluster.sh {{nodes_per_instance}}
vllm serve {{model_id}} \
    --host 0.0.0.0 --port 8000 \
    --tensor-parallel-size {{gpus_per_instance}} \
    --pipeline-parallel-size {{nodes_per_instance}} \
    --distributed-executor-backend ray \
    {{extra_args}}
```

## Model Sizing Reference (H100 GPUs, FP8)

| Model | Params | Active | VRAM | GPUs/instance | Mode |
|-------|--------|--------|------|---------------|------|
| Qwen2.5-Coder-32B | 32B | 32B | ~32GB | 1 (TP=1) | Replicated |
| Llama 3.3 70B | 70B | 70B | ~70GB | 2 (TP=2) | Replicated |
| MiniMax-M2.5 | 230B | 10B active | ~115GB | 2 (TP=2) | Replicated |
| Qwen3-Coder | 480B | 35B active | ~240GB | 4 (TP=4) | Replicated |
| DeepSeek-V3 | 671B | 37B active | ~335GB | 8 (TP=4 PP=2) | Distributed |
| Llama 3.1 405B | 405B | 405B | ~405GB | 8 (TP=4 PP=2) | Distributed |

**FP8 is always the default on H100s** — native tensor core support, 2x throughput vs FP16, zero quality loss. Never use INT4 for coding models (–8 HumanEval points).

## Deployment Plans

Pre-made plans in `configs/deployments/`:

| Plan | Description | Capacity |
|------|-------------|----------|
| `all-32b.yaml` | 16× Qwen2.5-Coder-32B | 500+ peak users |
| `mixed-fleet.yaml` | 8× fast coder + 1× heavy model | 200 peak users |
| `all-70b.yaml` | 4× Llama 3.3 70B | 200 peak users |
| `distributed-405b.yaml` | 1× Llama 405B (all nodes) | Max quality, ~50 users |

### Fleet Reconfiguration

```bash
make deploy PLAN=mixed-fleet    # switch plans
# This: cancels running jobs → submits new → regenerates LiteLLM → reloads
# Downtime: model loading time only (~30s for 32B, ~5min for 405B)
```

## Scaling Rules

- Throughput scales **linearly** for replicated models
- Each node adds: 4 replicas (32B), 2 replicas (70B), or 1 replica (MoE 480B)
- **Start with replicated mode** — only use distributed for models > 320GB VRAM
- `scripts/health-check.sh` runs every 60s and auto-resubmits crashed jobs

## Safety Rules

- **Never** submit Slurm jobs without reading the deployment plan YAML first
- **Never** start Ray clusters without confirming node availability via `sinfo`
- **Always** use `--disable-log-requests` on vLLM to prevent prompt leakage
- **Always** validate model config exists in `configs/models/` before deploying
- **Never** modify `configs/base/litellm-config.yaml` — it is auto-generated

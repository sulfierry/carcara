---
name: carcara-model-profiler
description: Model performance profiling and capacity planning — VRAM calculations, throughput estimation, quantization impact analysis, and deployment plan optimization for H100 GPU clusters
---

# Carcará Model Profiler Skill

This skill enables agents to analyze, estimate, and optimize LLM deployment configurations based on hardware constraints, model architecture, and user concurrency requirements.

## Hardware Baseline: NVIDIA H100

| Property | Value |
|----------|-------|
| VRAM per GPU | 80GB HBM3 |
| GPUs per node | 4 |
| VRAM per node | 320GB |
| FP8 tensor core throughput | ~2x vs FP16 |
| Inter-node interconnect | NVLink or InfiniBand |

## VRAM Estimation Formula

```
VRAM_required ≈ (params_billions × bytes_per_param) + KV_cache_overhead

For FP8:  bytes_per_param = 1
For FP16: bytes_per_param = 2
For INT4: bytes_per_param = 0.5

KV_cache_overhead ≈ 10-20% of model VRAM
```

**Example: Qwen2.5-Coder-32B at FP8**
```
VRAM = 32B × 1 byte = 32GB + ~5GB KV cache ≈ 37GB → fits on 1× H100 (80GB)
```

**Example: Llama 3.1 405B at FP8**
```
VRAM = 405B × 1 byte = 405GB + ~50GB KV cache ≈ 455GB → needs 8× H100 (640GB available)
```

## Quantization Impact Matrix

| Precision | Throughput vs FP16 | HumanEval Impact | Recommendation |
|-----------|-------------------|------------------|----------------|
| **FP8** | **2x faster** | **None** (identical scores) | **Default for all H100 deployments** |
| INT8 | 1.5x faster | Minimal | Acceptable fallback |
| INT4 | 2.7x faster | **-8 points** (significant) | **Avoid for coding tasks** |

**Rule: FP8 is always the correct choice on H100s.** It is not a compromise — it is how the hardware was designed.

## Throughput Estimation

Assumptions: peak:active ratio 3:1, coding prompt ~1500 tokens, response ~250 tokens, think time 15-20s.

```
tokens_per_sec_per_replica ≈ 400-600 tok/s  (32B model, FP8, single H100)
tokens_per_sec_per_replica ≈ 300-500 tok/s  (70B model, FP8, TP=2)
tokens_per_sec_per_replica ≈ 200-300 tok/s  (480B MoE, FP8, TP=4)

active_users_at_peak = peak_users / 3
tokens_per_user = total_throughput / active_users_at_peak
```

"Good experience" target: **15-30 tok/sec per concurrent user**.

## Capacity Planning Table

| Peak Users | Nodes Needed | Recommended Setup |
|-----------|-------------|-------------------|
| Up to 100 | 2 nodes | 8× Qwen2.5-Coder-32B replicas |
| Up to 200 | 4 nodes | 16× Qwen2.5-Coder-32B, or mixed fleet |
| Up to 500 | 6 nodes | 12× Qwen2.5-Coder-32B + 1× large model |
| Up to 1000 | 8-10 nodes | Mix of 32B replicas + large model instances |

## Deployment Scenario Analysis

When asked to recommend a deployment plan, evaluate using this framework:

1. **Identify user count and usage pattern** (coding-heavy? general chat? API-only?)
2. **Calculate VRAM budget**: `total_nodes × 4 × 80GB`
3. **Select model(s)** from `configs/models/*.yaml` based on quality requirements
4. **Calculate replicas**: `(node_gpus ÷ gpus_per_instance) × nodes`
5. **Estimate throughput**: `replicas × tok/s_per_replica`
6. **Verify**: `throughput / (peak_users / 3) ≥ 15 tok/s` ← good experience
7. **Recommend plan** or create a new `configs/deployments/*.yaml`

## Grafana/Prometheus Metrics to Monitor

| Metric | Source | What It Tells You |
|--------|--------|-------------------|
| `vllm:num_requests_running` | vLLM | Active concurrent requests |
| `vllm:num_requests_waiting` | vLLM | Queue depth (>0 means saturation) |
| `vllm:gpu_cache_usage_perc` | vLLM | KV cache utilization |
| `vllm:avg_generation_throughput_toks_per_s` | vLLM | Tokens/sec throughput |
| `vllm:avg_prompt_throughput_toks_per_s` | vLLM | Prompt processing speed |
| `DCGM_FI_DEV_GPU_UTIL` | DCGM | GPU compute utilization % |
| `DCGM_FI_DEV_FB_USED` | DCGM | GPU memory used (bytes) |
| `DCGM_FI_DEV_GPU_TEMP` | DCGM | GPU temperature (°C) |

### Alert Thresholds

| Condition | Action |
|-----------|--------|
| `num_requests_waiting > 10` sustained | Add replicas or scale nodes |
| `gpu_cache_usage_perc > 0.95` | Reduce `max_model_len` or add GPUs |
| `GPU_TEMP > 80°C` | Check cooling, reduce load |
| `generation_throughput < 100 tok/s` per replica | Investigate bottleneck |

## Model Comparison Commands

```bash
# List available models on a running vLLM instance
curl http://gpu-node1:8000/v1/models

# Benchmark TTFT and throughput (via Docker if curl missing)
docker run --rm curlimages/curl:latest -w "TTFT: %{time_starttransfer}s\nTotal: %{time_total}s\n" \
  -X POST http://gpu-node1:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-coder-32b","messages":[{"role":"user","content":"Write a Python hello world"}],"max_tokens":100}'
```

## Safety Rules

- **Never** recommend INT4 quantization for coding-focused deployments
- **Never** set `gpu_memory_utilization` above 0.95 (leave headroom for KV cache spikes)
- **Always** include `--disable-log-requests` in vLLM args (privacy requirement)
- **Always** use FP8 as the default quantization on H100 hardware

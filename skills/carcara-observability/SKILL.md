---
name: carcara-observability
description: Monitoring, logging, and alerting for Carcará — Prometheus, Grafana, Loki, Promtail, DCGM Exporter, and Node Exporter configuration and dashboard management
---

# Carcará Observability Skill

This skill governs the full observability stack: metrics collection, log aggregation, dashboards, and alerting — while strictly maintaining the privacy guarantee that **no conversation content ever appears in any metric, log, or alert**.

## Stack Components

| Component | Port | Purpose |
|-----------|------|---------|
| **Prometheus** | :9090 | Metrics collection and storage |
| **Grafana** | :3000 | Dashboards and alerting |
| **Loki** | :3100 | Log aggregation |
| **Promtail** | — | Log shipping agent (runs on GPU nodes) |
| **DCGM Exporter** | :9400 | NVIDIA GPU metrics |
| **Node Exporter** | :9100 | System metrics (CPU, RAM, disk, network) |

## Prometheus Scrape Targets

Defined in `configs/base/prometheus.yaml`:

```yaml
scrape_configs:
  - job_name: 'vllm'
    static_configs:
      - targets: ['gpu-node1:8000', 'gpu-node2:8000']  # auto-updated by deploy-fleet.sh

  - job_name: 'litellm'
    static_configs:
      - targets: ['litellm:4000']

  - job_name: 'node-exporter'
    static_configs:
      - targets: ['gpu-node1:9100', 'gpu-node2:9100']

  - job_name: 'dcgm-exporter'
    static_configs:
      - targets: ['gpu-node1:9400', 'gpu-node2:9400']
```

**Rule:** When adding new GPU nodes via `scripts/add-node.sh`, Prometheus targets are auto-updated.

## Grafana Dashboards

Three core dashboards in `configs/base/grafana/dashboards/`:

### 1. vLLM Performance (`vllm.json`)
- Requests/sec (running + waiting)
- Tokens/sec (prompt + generation throughput)
- Time-to-First-Token (TTFT) histogram
- KV cache utilization %
- Queue depth over time

### 2. LiteLLM Usage (`litellm.json`)
- Per-user request count and token usage
- Rate-limit hits per user/key
- Error rates by model
- Latency percentiles (p50, p95, p99)

### 3. System Health (`system.json`)
- GPU utilization % per GPU (DCGM)
- GPU memory used/total per GPU (DCGM)
- GPU temperature per GPU (DCGM)
- CPU, RAM, disk utilization (Node Exporter)
- Network I/O (Node Exporter)

## Alerting Rules

| Alert | Condition | Severity | Action |
|-------|-----------|----------|--------|
| vLLM Down | `up{job="vllm"} == 0` for 2min | Critical | Check Slurm job, resubmit |
| GPU Memory Critical | `DCGM_FI_DEV_FB_USED / DCGM_FI_DEV_FB_TOTAL > 0.95` | Warning | Reduce `max_model_len` or add GPUs |
| GPU Temperature High | `DCGM_FI_DEV_GPU_TEMP > 80` | Warning | Check cooling infrastructure |
| Error Rate High | `rate(litellm_errors[5m]) > 0.05` | Warning | Check model health, review logs |
| Queue Saturation | `vllm:num_requests_waiting > 10` for 5min | Warning | Add replicas or scale nodes |

## Loki Log Pipeline

Promtail ships logs from GPU nodes to Loki on the management node:

```yaml
# configs/base/promtail-config.yaml
clients:
  - url: http://management-node:3100/loki/api/v1/push

scrape_configs:
  - job_name: vllm
    static_configs:
      - targets: [localhost]
        labels:
          job: vllm
          __path__: /var/log/vllm/*.log

  - job_name: system
    static_configs:
      - targets: [localhost]
        labels:
          job: system
          __path__: /var/log/syslog
```

## Privacy Constraints for Observability

**These are absolute and non-negotiable:**

1. Prometheus metrics are **numerical only** — tokens/sec, latency, queue depth. Zero text content.
2. vLLM runs with `--disable-log-requests` — prompts never appear in logs.
3. LiteLLM runs with `store_prompts: false` — no request/response bodies stored.
4. Loki captures operational events (model loading, errors, GPU utilization) — **never prompts or responses**.
5. Grafana dashboards display **only numerical data and operational status**.

**Verification:**
```bash
# Audit Loki for any leaked content
docker exec loki logcli query '{job="vllm"}' --limit 500 | grep -ciE "prompt|user.*(said|asked|wrote)"
# Expected: 0
```

## Adding a New GPU Node to Observability

```bash
scripts/add-node.sh gpu-node5
# This automatically:
# 1. Adds gpu-node5:9100 to Prometheus node-exporter targets
# 2. Adds gpu-node5:9400 to Prometheus DCGM targets
# 3. Deploys Promtail config to gpu-node5
# 4. Outputs node definition for deployment plans
```

## Dashboard Development Workflow

1. Develop dashboards locally using Tier 1 Docker stack (Grafana + mock Prometheus data)
2. Export dashboard JSON from Grafana UI
3. Save to `configs/base/grafana/dashboards/*.json`
4. Commit to repository — dashboards are provisioned automatically on startup

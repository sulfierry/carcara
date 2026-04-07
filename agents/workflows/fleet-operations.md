---
description: Fleet operations — reconfigure cluster deployments, swap models, add GPU nodes, and manage capacity across the Carcará HPC infrastructure
---

# Workflow: Fleet Operations

Day-to-day operational tasks for managing the GPU fleet. Used after initial deployment (Phase 2+).

**Prerequisites:**
- Phase 2 completed (at least one vLLM instance running via Slurm)
- SSH access to HPC login node
- Management node services running (LiteLLM, Prometheus)

---

## Operation A: Switch Deployment Plan

Change the entire cluster from one configuration to another (e.g., `all-32b` → `mixed-fleet`).

1. **Review available plans**
   ```bash
   ls -la configs/deployments/
   ```

2. **Preview the target plan**
   ```bash
   cat configs/deployments/mixed-fleet.yaml
   ```

// turbo
3. **Deploy new plan**
   This cancels running Slurm jobs, submits new ones, and regenerates LiteLLM config.
   ```bash
   make deploy PLAN=mixed-fleet
   ```

4. **Verify**
   ```bash
   ssh hpc-login "squeue --name='carcara-*' --format='%j %N %T' --noheader"
   ```

---

## Operation B: Add a New GPU Node

Expand the cluster with an additional GPU node.

1. **Verify new node**
   ```bash
   ssh hpc-login "sinfo --nodes=gpu-node5 --format='%N %G %t' --noheader"
   ```

// turbo
2. **Register the node**
   Adds Prometheus targets, Promtail config, and outputs deployment plan snippet.
   ```bash
   bash scripts/add-node.sh gpu-node5
   ```

3. **Update deployment plan**
   Add the new node to the active deployment:
   ```yaml
   # configs/deployments/active.yaml
   nodes:
     gpu-node5: { host: "10.0.2.5", gpus: 4 }    # ← add
   deployments:
     - model: qwen2.5-coder-32b
       nodes: [gpu-node1, gpu-node2, gpu-node5]    # ← add to list
   ```

// turbo
4. **Redeploy**
   ```bash
   make deploy
   ```

---

## Operation C: Quick Model Swap

Switch which model(s) are running without changing the full deployment plan.

// turbo
1. **Execute swap**
   ```bash
   bash scripts/swap-model.sh qwen3-coder
   ```
   This cancels current jobs, deploys the new model using the existing node allocation.

2. **Verify model availability**
   ```bash
   ssh hpc-login "curl -s http://gpu-node1:8000/v1/models | python3 -m json.tool"
   ```

---

## Operation D: Health Check & Auto-Recovery

Verify all services and auto-restart crashed Slurm jobs.

// turbo
1. **Run health check**
   ```bash
   bash scripts/health-check.sh
   ```
   This:
   - Queries `squeue` for expected Carcará jobs
   - Curls each vLLM endpoint
   - Resubmits any crashed/missing jobs
   - Reports status

---

## Operation E: Database Backup

Create an encrypted backup of PostgreSQL data.

1. **Run backup**
   ```bash
   bash scripts/backup-db.sh
   ```
   Creates a GPG-encrypted dump in `data/backups/`.

2. **Verify backup**
   ```bash
   ls -la data/backups/*.sql.gpg
   file data/backups/$(ls -t data/backups/ | head -1)
   ```
   *Expected: GPG encrypted data.*

---

## Operation F: TLS Certificate Rotation

Rotate TLS certificates before expiry.

1. **Rotate**
   ```bash
   bash scripts/rotate-tls-certs.sh
   ```

2. **Reload Nginx**
   ```bash
   docker exec nginx nginx -s reload
   ```

3. **Verify**
   ```bash
   curl -vI https://carcara.internal 2>&1 | grep "expire date"
   ```

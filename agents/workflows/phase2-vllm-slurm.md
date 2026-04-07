---
description: Phase 2 — Deploy vLLM on HPC Slurm nodes, validate inference endpoints, and benchmark model performance on real H100 GPUs
---

# Workflow: Phase 2 — vLLM on Slurm

Deploys vLLM instances on GPU nodes via Slurm. This is Tier 2 work — requires HPC cluster access.

**Prerequisites:**
- SSH access to HPC login node
- vLLM environment installed on GPU nodes (conda/venv)
- Model weights available on shared filesystem (`/models/`)
- Model config YAML exists in `configs/models/`
- Deployment plan YAML exists in `configs/deployments/`

1. **Verify HPC Access**
   Confirm connectivity to the HPC login node and GPU node availability.
   ```bash
   ssh hpc-login "sinfo --partition=gpu --format='%N %G %t' --noheader"
   ```
   *Expected: GPU nodes listed with state `idle` or `mix`.*

2. **Verify Model Weights**
   Confirm the model is available on the shared filesystem.
   ```bash
   ssh hpc-login "ls -la /models/Qwen/Qwen2.5-Coder-32B-Instruct/"
   ```

3. **Validate Model Config**
   Review the model configuration before deployment.
   ```bash
   cat configs/models/qwen2.5-coder-32b.yaml
   ```
   Verify: `model_id`, `gpus_per_instance`, `quantization: "fp8"`, `extra_args` includes `--disable-log-requests`.

4. **Select Deployment Plan**
   Choose and review the deployment plan.
   ```bash
   cat configs/deployments/active.yaml
   ```
   Verify: node hostnames match `sinfo` output, GPU counts are correct.

// turbo
5. **Deploy Fleet**
   Execute the deployment script. This generates sbatch scripts, submits Slurm jobs, and regenerates LiteLLM config.
   ```bash
   make deploy PLAN=active
   ```
   Or manually:
   ```bash
   bash scripts/deploy-fleet.sh configs/deployments/active.yaml
   ```

6. **Verify Running Slurm Jobs**
   Confirm vLLM instances are running.
   ```bash
   ssh hpc-login "squeue --name='carcara-*' --format='%j %N %T %M' --noheader"
   ```
   *Expected: One job per replica, state RUNNING.*

7. **Test Inference Endpoint**
   Hit a vLLM instance directly to confirm it's serving.
   ```bash
   ssh hpc-login "curl -s http://gpu-node1:8000/v1/models"
   ```
   *Expected: JSON listing the loaded model.*

8. **Benchmark Performance**
   Measure TTFT and throughput on real hardware.
   ```bash
   ssh hpc-login 'curl -w "TTFT: %{time_starttransfer}s Total: %{time_total}s\n" \
     -X POST http://gpu-node1:8000/v1/chat/completions \
     -H "Content-Type: application/json" \
     -d '"'"'{"model":"qwen2.5-coder-32b","messages":[{"role":"user","content":"Write a Python Fibonacci function"}],"max_tokens":200}'"'"''
   ```

9. **Verify Auto-Generated LiteLLM Config**
   Ensure `deploy-fleet.sh` correctly generated the LiteLLM routing config.
   ```bash
   cat configs/base/litellm-config.yaml
   ```
   Verify: all replica endpoints are listed, `store_prompts: false` is present.

10. **Teardown (if reverting)**
    Cancel all Carcará Slurm jobs:
    ```bash
    ssh hpc-login "scancel --name='carcara-*'"
    ```

---
description: Phase 1 — Bootstrap local development stack with Docker Compose, Ollama mock, OpenLDAP, and observability. Validates environment and all service endpoints.
---

# Workflow: Phase 1 — Foundation & Infrastructure

Deploys the full Tier 1 local development stack. This is where 80% of development happens before touching any GPU node.

**Prerequisites:** Docker installed (verified by `initialize.sh`).

// turbo
1. **Initialize Environment**
   Bootstrap directories, verify Docker, create `.env` files.
   ```bash
   bash scripts/initialize.sh
   ```

2. **Review Environment Configuration**
   Verify that `configs/envs/development.env` contains all required variables.
   Key variables to check:
   - `POSTGRES_PASSWORD` — database password
   - `LITELLM_MASTER_KEY` — API gateway master key
   - `VLLM_API_KEY` — backend model API key
   - `LDAP_BIND_DN` — LDAP service account DN
   - `WEBUI_SECRET_KEY` — Open WebUI session secret

// turbo
3. **Start Local Stack**
   Bring up all services: Nginx, Open WebUI, LiteLLM, PostgreSQL, Redis, Ollama, OpenLDAP, Prometheus, Grafana, Loki.
   ```bash
   docker compose -f containers/docker-compose.dev.yaml up -d
   ```

4. **Wait for Services**
   Services need time to initialize (especially PostgreSQL migrations and model downloads).
   ```bash
   echo "Waiting for services to become healthy..."
   sleep 30
   docker compose -f containers/docker-compose.dev.yaml ps
   ```

5. **Verify Core Services**
   Test that each critical endpoint responds:
   ```bash
   # Open WebUI (chat interface)
   curl -s -o /dev/null -w "Open WebUI: %{http_code}\n" http://localhost:8080
   
   # LiteLLM Proxy (API gateway)
   curl -s -o /dev/null -w "LiteLLM:   %{http_code}\n" http://localhost:4000/health
   
   # Ollama (mock LLM backend)
   curl -s -o /dev/null -w "Ollama:    %{http_code}\n" http://localhost:11434/api/tags

   # Grafana (dashboards)
   curl -s -o /dev/null -w "Grafana:   %{http_code}\n" http://localhost:3000/api/health
   ```
   *Expected: all return 200.*
   
   If `curl` is not installed locally:
   ```bash
   docker run --rm --network host curlimages/curl:latest -s -o /dev/null -w "%{http_code}" http://localhost:8080
   ```

6. **Verify Privacy Flags**
   Confirm that privacy settings are enforced from the start:
   ```bash
   docker exec open-webui env | grep -E "ENABLE_ADMIN_CHAT_ACCESS|ENABLE_ADMIN_EXPORT|DEFAULT_USER_ROLE"
   # Expected: false, false, pending
   ```

7. **Test End-to-End Chat Flow**
   Send a test message through the full pipeline: LiteLLM → Ollama.
   ```bash
   curl -s http://localhost:4000/v1/chat/completions \
     -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
     -H "Content-Type: application/json" \
     -d '{"model":"phi-3-mini","messages":[{"role":"user","content":"Say hello"}],"max_tokens":50}'
   ```
   *Expected: JSON response with model completion.*

8. **Teardown (when done developing)**
   Stops containers but preserves database volumes:
   ```bash
   docker compose -f containers/docker-compose.dev.yaml down
   ```
   To also remove volumes (full reset):
   ```bash
   docker compose -f containers/docker-compose.dev.yaml down -v
   ```

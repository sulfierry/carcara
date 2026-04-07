---
description: Phase 8 — Full privacy audit including database encryption verification, RLS penetration testing, log content scanning, and application control enforcement
---

# Workflow: Phase 8 — Privacy Audit

Executes a comprehensive Red Team privacy audit against the running Carcará platform. Can run against Tier 1 (local Docker) or production.

**Prerequisites:**
- Local stack running (`docker compose up`) OR production access
- PostgreSQL accessible with both `app_runtime` and `app_admin` roles configured
- At least 2 test users with existing conversations

1. **Verify Application Privacy Flags**
   Confirm Open WebUI restricts admin access to conversations.
   ```bash
   docker exec open-webui env | grep ENABLE_ADMIN_CHAT_ACCESS
   # Expected: ENABLE_ADMIN_CHAT_ACCESS=false
   
   docker exec open-webui env | grep ENABLE_ADMIN_EXPORT
   # Expected: ENABLE_ADMIN_EXPORT=false
   
   docker exec open-webui env | grep DEFAULT_USER_ROLE
   # Expected: DEFAULT_USER_ROLE=pending
   ```

2. **Verify LiteLLM Prompt Storage Disabled**
   ```bash
   grep "store_prompts" configs/base/litellm-config.yaml
   # Expected: store_prompts: false
   ```

3. **Verify vLLM Log Sanitization**
   Check that running vLLM instances have `--disable-log-requests` enabled.
   ```bash
   # For local (Ollama mock — check env vars)
   docker exec ollama env | grep -i log
   
   # For production (Slurm jobs)
   ssh hpc-login "scontrol show job --name='carcara-*' | grep Command"
   # Then inspect the sbatch script for --disable-log-requests
   ```

4. **Test pgcrypto Column Encryption**
   Connect to PostgreSQL and verify conversation content is encrypted.
   ```bash
   docker exec -i postgres psql -U postgres -d openwebui -c \
     "SELECT substring(encode(conversation_content::bytea, 'hex'), 1, 80) FROM conversations LIMIT 3;"
   ```
   *Expected: hex-encoded encrypted blobs, NOT readable text.*

5. **Penetration Test: Cross-User RLS**
   Attempt to read another user's conversations using the restricted runtime role.
   ```bash
   docker exec -i postgres psql -U app_runtime -d openwebui -c \
     "SET app.current_user_id = 'user-alice';
      SELECT count(*) FROM conversations WHERE user_id = 'user-bob';"
   ```
   *Expected: 0 rows returned. RLS blocks cross-user access.*

6. **Verify pgaudit Logging (Without Content)**
   Confirm audit logs capture access events but NOT query data.
   ```bash
   docker exec -i postgres psql -U postgres -c "SHOW shared_preload_libraries;"
   # Expected: includes "pgaudit"
   
   docker exec -i postgres psql -U postgres -c \
     "SELECT query FROM pg_stat_activity WHERE application_name LIKE '%audit%' LIMIT 5;"
   ```

7. **Scan Logs for Leaked Content**
   Search all log sources for any accidentally leaked prompt/response content.
   ```bash
   # Scan vLLM logs
   docker logs ollama 2>&1 | grep -ciE "(user.*said|prompt|message.*content)" || echo "CLEAN: 0 matches"
   
   # Scan LiteLLM logs
   docker logs litellm 2>&1 | grep -ciE "(prompt|completion|user.*message)" || echo "CLEAN: 0 matches"
   
   # Scan Loki (if running)
   docker exec loki logcli query '{job=~".+"}' --limit 1000 2>/dev/null | \
     grep -ciE "(prompt|user.*said|message.*content)" || echo "CLEAN: 0 matches"
   ```
   *Expected: 0 matches on all sources.*

8. **Scan Prometheus for Textual Data**
   Verify Prometheus stores only numerical metrics.
   ```bash
   curl -s http://localhost:9090/api/v1/label/__name__/values | \
     python3 -c "import sys,json; names=json.load(sys.stdin)['data']; [print(n) for n in names if 'prompt' in n.lower() or 'message' in n.lower() or 'content' in n.lower()]"
   ```
   *Expected: no metric names containing "prompt", "message", or "content".*

9. **Verify Backup Encryption**
   If backups exist, confirm they are GPG/age encrypted.
   ```bash
   file data/backups/*.sql.gpg 2>/dev/null || echo "No backups found (OK for local dev)"
   ```

10. **Generate Audit Report**
    Summarize results. All checks must pass for privacy compliance.
    ```
    Privacy Audit Results:
    ├── Application Controls ......... [PASS/FAIL]
    ├── LiteLLM store_prompts ........ [PASS/FAIL]
    ├── vLLM disable-log-requests .... [PASS/FAIL]
    ├── pgcrypto Encryption .......... [PASS/FAIL]
    ├── RLS Cross-User Block ......... [PASS/FAIL]
    ├── pgaudit Configuration ........ [PASS/FAIL]
    ├── Log Content Scan ............. [PASS/FAIL]
    ├── Prometheus Content Scan ...... [PASS/FAIL]
    └── Backup Encryption ............ [PASS/FAIL]
    ```

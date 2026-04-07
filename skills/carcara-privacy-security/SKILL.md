---
name: carcara-privacy-security
description: Privacy engineering and security auditing for Carcará — 6-layer defense enforcement, pgcrypto/RLS verification, Red Team penetration testing, and threat model validation
---

# Carcará Privacy & Security Skill

Privacy is not a feature of Carcará — it is the **architectural foundation**. This skill enables agents to enforce, verify, and stress-test all 6 layers of the privacy defense stack.

## The 6 Defense Layers

### Layer 1: Network Isolation
- **All services behind organizational VPN.** No public internet exposure.
- TLS 1.3 on all inter-service communication.
- PostgreSQL requires TLS connections (`sslmode=require`).
- GPU nodes accept connections **only** from the management node.

**Verification commands:**
```bash
# Confirm TLS on Nginx
docker run --rm curlimages/curl:latest -vI https://carcara.internal 2>&1 | grep "TLSv1.3"
# Confirm PostgreSQL TLS
docker exec postgres psql -U app_runtime -c "SHOW ssl;"  # must return "on"
```

### Layer 2: Application Controls
| Setting | Value | Purpose |
|---------|-------|---------|
| `ENABLE_ADMIN_CHAT_ACCESS` | `false` | Admins cannot view user conversations via UI |
| `ENABLE_ADMIN_EXPORT` | `false` | Admins cannot bulk-export conversation data |
| `DEFAULT_USER_ROLE` | `pending` | New users require explicit approval |
| `store_prompts` (LiteLLM) | `false` | Proxy never logs prompt/response content |
| `--disable-log-requests` (vLLM) | enabled | Inference engine never logs prompts |

**Verification:**
```bash
# Confirm Open WebUI privacy flags
docker exec open-webui env | grep -E "ENABLE_ADMIN|DEFAULT_USER"
# Confirm LiteLLM does not store prompts
grep "store_prompts" configs/base/litellm-config.yaml  # must be: false
```

### Layer 3: Database Encryption
- **pgcrypto** extension for column-level encryption of conversation content.
- **Row-Level Security (RLS)** — each user can only access their own rows, even via direct SQL.
- Separate database roles: `app_runtime` (RLS enforced) and `app_admin` (migrations only).

**Verification — RLS penetration test:**
```sql
-- Connect as app_runtime user
SET ROLE app_runtime;
-- Attempt to read another user's conversations
SELECT * FROM conversations WHERE user_id != current_setting('app.current_user_id');
-- Expected: 0 rows returned (RLS blocks cross-user access)
```

**Verification — pgcrypto encryption test:**
```sql
-- Raw query on encrypted column
SELECT conversation_content FROM conversations LIMIT 1;
-- Expected: encrypted blob (\\x...), NOT plaintext
```

### Layer 4: Audit Without Content
- **pgaudit** logs WHO accessed WHAT tables, WHEN — without logging query data.
- Prometheus exports **only numerical metrics** (tokens/sec, latency, queue depth).
- Loki logs capture operational events — **never prompts or responses**.

**Verification:**
```bash
# Check pgaudit is enabled
docker exec postgres psql -U postgres -c "SHOW shared_preload_libraries;" | grep pgaudit
# Check Loki logs contain no prompt content
docker exec loki logcli query '{job="vllm"}' --limit 100 | grep -i "prompt\|user.*said\|message"
# Expected: 0 matches
```

### Layer 5: Operational Controls
- Database backups encrypted with **GPG/age**.
- Separation of duties: GPU admin ≠ DB admin ≠ app admin.
- No single person holds all credentials.

### Layer 6: Conversation Retention Policy
- Auto-delete conversations older than N days (configurable).
- User-facing toggle: "keep history" vs "auto-delete after session/7d/30d/90d".
- Complement, not substitute, for encryption at rest.

## Red Team Audit Checklist

When performing a privacy audit, execute this checklist **in order**:

- [ ] Confirm `ENABLE_ADMIN_CHAT_ACCESS=false` in Open WebUI environment
- [ ] Confirm `ENABLE_ADMIN_EXPORT=false` in Open WebUI environment
- [ ] Confirm `store_prompts: false` in LiteLLM config
- [ ] Confirm `--disable-log-requests` in all vLLM Slurm job scripts
- [ ] Attempt cross-user conversation read via SQL (must fail)
- [ ] Verify conversation content is encrypted in database (pgcrypto blobs)
- [ ] Verify pgaudit logs do NOT contain query data
- [ ] Verify Loki/Promtail logs contain ZERO prompt/response content
- [ ] Verify Prometheus metrics contain ZERO textual data
- [ ] Verify database backup is GPG-encrypted

## Threat Model Summary

| Threat | Protection | Confidence |
|--------|-----------|------------|
| External attacker | VPN + TLS 1.3 | Very high |
| Curious admin via UI | `ENABLE_ADMIN_CHAT_ACCESS=false` | High |
| DBA with direct SQL | pgcrypto + RLS | High (key in separate secret store) |
| Root on management node | Separation of duties + audit logs | Medium (inherent limit) |
| Root on GPU node | `--disable-log-requests`, data in GPU mem only during inference | Medium |
| Compromised Open WebUI | Container security + optional carcara-proxy | Medium |

## Absolute Rules for Agents

1. **NEVER** set `store_prompts` to `true`
2. **NEVER** enable `ENABLE_ADMIN_CHAT_ACCESS`
3. **NEVER** remove `--disable-log-requests` from vLLM args
4. **NEVER** log request/response bodies in any middleware or proxy
5. **NEVER** store encryption keys in the same location as encrypted data
6. **ALWAYS** use separate database roles (`app_runtime` vs `app_admin`)

# Crontab Canonical — OpenClaw VPS

> **Source of truth** versionado em git pra estado correto do crontab user `root` na VPS Hostinger.
> Última atualização: **2026-05-05** (post-incident silent loss 2026-05-04 13:29).
> Aplica via: `bash /root/.openclaw/scripts/crontab-rebuild.sh` (espelho local em `infra/scripts/crontab-rebuild.sh`).

---

## Workflow de mudança

1. **Editar este arquivo PRIMEIRO** (PR no repo `openclaw-vps`)
2. Atualizar canonical embedded em `infra/scripts/crontab-rebuild.sh` (mesma seção)
3. Sync local → VPS: `scp infra/scripts/crontab-rebuild.sh root@VPS:/root/.openclaw/scripts/`
4. Aplicar com dry-run primeiro: `ssh root@VPS 'bash /root/.openclaw/scripts/crontab-rebuild.sh --dry-run'`
5. Aplicar real: `ssh root@VPS 'bash /root/.openclaw/scripts/crontab-rebuild.sh'`
6. Verificar: `ssh root@VPS 'crontab -l | grep -cE "^[0-9*]"'` deve dar **26**

---

## Canonical (26 entries OpenClaw)

```cron
# ── Health & monitoring ─────────────────────────────────────────────
*/5 * * * * /root/.openclaw/scripts/canary-telegram-conflict.sh
*/10 * * * * /root/.openclaw/scripts/health-probe.sh >> /var/log/nox-health.log 2>&1
*/15 * * * * /root/.openclaw/scripts/canary-bundle-15min.sh
*/15 * * * * /usr/bin/python3 /root/.openclaw/workspace/tools/bvv-extract.py >> /var/log/bvv-extract.log 2>&1
2,32 * * * * /root/.openclaw/scripts/check-discord-heartbeat-validation.sh
7,37 * * * * /root/.openclaw/scripts/config-drift-monitor.sh >> /var/log/config-drift.log 2>&1
12,42 * * * * /root/.openclaw/scripts/heartbeat-sync.sh
17,47 * * * * /root/.openclaw/scripts/semantic-canary.sh >> /var/log/nox-canary.log 2>&1
22,52 * * * * /usr/local/bin/beir-kill-if-overload.sh >> /var/log/nox-mem/beir-killswitch.log 2>&1
15 * * * * /root/.openclaw/scripts/check-gm-messages.sh 2>&1 | logger -t nox-canary-cron

# ── Token refresh & version monitor ─────────────────────────────────
0 */4 * * * /root/.openclaw/scripts/token-refresh-max.sh >> /var/log/token-refresh.log 2>&1
5 9 * * * /root/.openclaw/scripts/openclaw-version-monitor.sh >> /var/log/openclaw-version-monitor.log 2>&1
0 12 * * * /root/.openclaw/upgrade-watcher/check.sh
0 9 * * 1 /usr/local/bin/forge-cc-token-check

# ── Backups (escalonados de madrugada) ──────────────────────────────
0 2 * * * /root/.openclaw/scripts/backup-all.sh >> /var/log/nox-backup.log 2>&1
5 2 * * * /root/bin/ckpt save "daily-passive" >/var/log/ckpt-daily.log 2>&1
30 2 * * * /usr/bin/python3 /root/.openclaw/scripts/export-obsidian-vault.py >> /var/log/nox-obsidian-export.log 2>&1
30 3 * * * /root/.openclaw/scripts/prune-pre-op-snapshots.sh
0 4 * * * /root/.openclaw/workspace/tools/delivery-queue-cleanup.sh >> /var/log/delivery-cleanup.log 2>&1

# ── Memory sync (pre-morning) ───────────────────────────────────────
0 5 * * * /usr/local/bin/agents-context-watchdog.sh >> /var/log/agents-context-watchdog.log 2>&1
30 5 * * * set -a && source /root/.openclaw/.env 2>/dev/null && set +a && bash /root/.openclaw/workspace/tools/cross-agent-sync.sh >> /root/.openclaw/workspace/tools/nox-mem/nox-mem.log 2>&1
0 6 * * * bash /root/.openclaw/workspace/tools/sync-verify.sh >> /root/.openclaw/workspace/tools/nox-mem/nox-mem.log 2>&1

# ── Daily reports ───────────────────────────────────────────────────
30 6 * * * /root/.openclaw/scripts/morning-report.sh >> /var/log/nox-morning.log 2>&1
0 9 * * * /root/.openclaw/scripts/marathon-followup-check.sh >> /var/log/marathon-followup.log 2>&1
0 12 * * * /root/.openclaw/scripts/seh-report-daily.sh >> /var/log/nox-seh-cron.log 2>&1

# ── Nightly maintenance (orchestra reindex/consolidate/kg/vectorize) ─
0 23 * * * /root/.openclaw/scripts/nightly-maintenance.sh >> /var/log/nox-maintenance.log 2>&1
```

---

## Distribuição de carga (load profile)

### Por minuto (worst case `:00` da hora cada 30min)
| Minute | Scripts simultâneos | Source |
|---|---|---|
| `:00` | 6 | canary-telegram (*/5), canary-bundle (*/15), bvv-extract (*/15), health-probe (*/10), cron.hourly system, check-gm-messages base |
| `:02, :32` | 1 | check-discord-heartbeat |
| `:05, :10, :15, :20, :25, :35, :40, :45, :50, :55` | 1-2 | depende do step |
| `:07, :37` | 1 | config-drift-monitor |
| `:12, :42` | 1 | heartbeat-sync |
| `:15` | +1 | check-gm-messages (hourly :15) |
| `:17, :47` | 1 | semantic-canary |
| `:22, :52` | 1 | beir-kill-if-overload |
| `:30` | 5 | canary-telegram + canary-bundle + bvv-extract + health-probe + check-gm-messages slot |

### Por hora (frequência ofensiva)
| Schedule | Total runs/dia | Notes |
|---|---|---|
| `*/5` | 288 | canary-telegram-conflict (1 entry) |
| `*/10` | 144 | health-probe |
| `*/15` | 96 × 2 | canary-bundle + bvv-extract |
| `*/30` (staggered) | 48 × 5 | check-discord-heartbeat, config-drift, heartbeat-sync, semantic-canary, beir-kill |
| `:15 hourly` | 24 | check-gm-messages |
| `0 */4` | 6 | token-refresh-max |
| Daily fixed times | 11 entries | backups, reports, sync, version monitor, etc |
| Weekly (Monday) | 1 | forge-cc-token-check |
| Daily (23:00) | 1 | nightly-maintenance |

**Total runs/dia:** ≈ 870 cron invocations.

---

## Categorização por criticidade

### 🔴 P0 (sem essas, sistema degrada em horas/dias)
- `nightly-maintenance.sh` (23:00) — reindex/consolidate/kg/vectorize/session-distill
- `backup-all.sh` (02:00) — wal/agent-dbs/openclaw/git
- `health-probe.sh` (*/10) — gateway+nox-mem+disk+SQLite+circuit breaker
- `token-refresh-max.sh` (0 */4) — Anthropic Max OAuth refresh
- `config-drift-monitor.sh` (7,37) — detect schema/config drift
- `agents-context-watchdog.sh` (05:00) — agent context integrity
- `cross-agent-sync.sh` (05:30) — cross-agent memory sync
- `sync-verify.sh` (06:00) — sync invariant check
- `beir-kill-if-overload.sh` (22,52) — backpressure killswitch nox-mem-api

### ⚠️ Canários/reports (sem essas, não detecta problemas mas não quebra)
17 entries restantes — canary-telegram, canary-bundle, semantic-canary, check-gm-messages, check-discord-heartbeat, heartbeat-sync, marathon-followup, morning-report, seh-report-daily, openclaw-version-monitor, upgrade-watcher, ckpt save, export-obsidian-vault, prune-pre-op-snapshots, delivery-queue-cleanup, bvv-extract, forge-cc-token-check.

---

## System crons (NÃO neste crontab)

Gerenciados separadamente em `/etc/crontab` ou `/etc/cron.d/`:
- anacron — `/etc/cron.daily`, `/etc/cron.weekly`, `/etc/cron.monthly`
- sysstat — `/etc/cron.d/sysstat` (debian-sa1)
- e2fsprogs — `/etc/cron.d/e2scrub_all`
- run-parts hourly — `/etc/crontab` (cron.hourly)

---

## Anti-padrões (NÃO fazer)

❌ **Não rodar `crontab -e` direto** — modificações via UI interativa não ficam versionadas. Sempre via PR + `crontab-rebuild.sh`.

❌ **Não usar `crontab -r`** — comando irreversível. Em emergência, usar `crontab-rebuild.sh` que faz backup automático.

❌ **Não setar todos os `*/30` no minuto `:00`** — staggering reduz pico simultâneo de 10→6 scripts (-40%). Documentado na lesson `2026-05-05-crontab-silent-loss-and-restore.md`.

❌ **Não confiar em syslog mining como single source-of-truth** — janela limitada (≤7 dias geralmente), inferência de schedule pode errar pra crons semanais (ex.: forge-cc-token-check). Sempre cross-check com este runbook + pre-hermes backup.

❌ **Não adicionar entries diretas via scripts de upgrade** — orchestrators devem só verificar (não modificar) o crontab. Mudanças deliberadas vão por este runbook.

---

## Histórico de mudanças

| Data | Mudança | Trigger |
|---|---|---|
| 2026-04-08 | Schema "simplificado" 7 entries (pre-hermes) | Refactor |
| 2026-04-13 | Snapshot manual em `workspace/backups/pre-hermes-20260413-1527/crontab.txt` | Backup pre-hermes upgrade |
| 2026-04-29 | `nightly-maintenance.sh` integrou 20+ entries individuais (reindex/consolidate/session-wrap-up por agent) num único orchestrator às 23:00 | Refactor — reduzir crontab clutter |
| 2026-05-04 13:29 | **INCIDENT — crontab silenciosamente reescrito pra 1 entry** | Cause unknown (possível side-effect upgrade 5.3-1) |
| 2026-05-05 16:30 | Restore via syslog mining; 3 fixes: forge Monday-only, */30 staggered, rebuild-script updated | Restore + harden |

---

## Mitigações ativas / TODO

### ✅ Implementadas
- `crontab-rebuild.sh` source-of-truth no script + mirror em `infra/scripts/`
- Backup automático antes de aplicar
- Verify count pós-aplicação (esperado=26)
- Staggering `*/30` reduz pico simultâneo
- Lesson + INCIDENTS + este runbook em git

### 📋 TODO (G6/G7 do backlog HANDOFF)
- **G6.1** Crontab backup horário: `0 * * * * crontab -l > /var/backups/crontab/crontab-$(date +\%Y\%m\%d-\%H).txt 2>/dev/null`
- **G6.2** Watchdog em `config-drift-monitor.sh`: alertar se `crontab -l | grep -cE "^[0-9*]" < 20` via logger + Telegram (quando F16 estiver pronto)
- **G7** Pre/post check no `upgrade-zero-downtime.sh`: backup crontab em Phase 0, verify count não regrediu em Phase 6

---

## Comandos de emergência

### Detectar perda silenciosa
```bash
# Count atual
ssh root@VPS 'crontab -l 2>/dev/null | grep -cE "^[0-9*]"'
# Se < 20: investigar antes de restore
```

### Backup pré-mudança
```bash
ssh root@VPS 'crontab -l > /tmp/crontab-pre-$(date +%Y%m%d-%H%M%S).txt 2>/dev/null'
```

### Restore canonical
```bash
# Sync rebuild script local → VPS (se mirror desatualizado)
scp infra/scripts/crontab-rebuild.sh root@VPS:/root/.openclaw/scripts/

# Dry-run (sempre primeiro)
ssh root@VPS 'bash /root/.openclaw/scripts/crontab-rebuild.sh --dry-run'

# Apply real
ssh root@VPS 'bash /root/.openclaw/scripts/crontab-rebuild.sh'

# Verify
ssh root@VPS 'crontab -l | grep -cE "^[0-9*]"'   # esperado 26
ssh root@VPS 'journalctl _COMM=cron --since "60 sec ago" --no-pager | grep RELOAD'
```

### Forensics (identificar quem reescreveu)
```bash
# Auditar histórico do crontab (se audit log estiver ativo)
ssh root@VPS 'aureport -f --start "2026-05-04 12:00:00" --end "2026-05-04 14:00:00" 2>/dev/null | grep -i cron'

# bash history do user root (raramente útil mas vale tentar)
ssh root@VPS 'grep -E "crontab|crontab-rebuild" ~/.bash_history | head -10'

# Header timestamp do crontab atual (sempre disponível)
ssh root@VPS 'sudo cat /var/spool/cron/crontabs/root | head -3'
# Mostra: # (- installed on <date>)
```

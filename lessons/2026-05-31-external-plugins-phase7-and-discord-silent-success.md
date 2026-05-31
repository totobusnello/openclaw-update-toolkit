---
chunk_type: lesson
source: internal
date: 2026-05-31
severity: medium
downtime_minutes: 0
tags: [openclaw, upgrade, external-plugins, npm, discord, whatsapp, plugin-version-drift, log-behavior-change, sessions-sticky, phase-7]
related_lessons: [2026-05-30-openclaw-5.27-upgrade-and-vec0-cli-recovery, 2026-05-24-upgrade-5.22-harness-restart-latency-and-plugin-config-env, 2026-05-03-openclaw-v5.2-upgrade-pitfalls]
---

# 2026-05-31 — Plugins externos @openclaw/* não atualizados pelo upgrade core + Discord plugin v5.27 silent-success + sessions sticky pós-fallback

## TL;DR

Toto reportou `⚠️ WhatsApp e Discord offline — verificar` no dia seguinte ao upgrade 5.22→5.27. Investigação revelou **4 problemas distintos em camadas**, sendo apenas 2 deles realmente "offline":

1. **Keepalive/warmup scripts esquecidos** na migração de modelo de ontem (16 cron jobs OK, mas 2 scripts shell ficaram em `claude-haiku-4-5` retired) → erro a cada 10min.
2. **Plugins externos `@openclaw/*` outdated** (Discord, WhatsApp, Slack, Codex, ACPX em v5.22 vs gateway v5.27) — `npm install -g openclaw` NÃO atualiza esse path. Phase 7 do playbook não existia.
3. **Discord plugin v5.27 mudou log behavior** — não emite mais `gateway READY` event explicitamente, fica silent-success após `awaiting gateway readiness`. Heurística antiga `grep "gateway READY"` dava falso negativo. Discord estava **funcional o tempo todo** (Toto confirmou interagindo com Forge).
4. **Sessions sticky** em modelos retired/fallback (regra 5 CLAUDE.md) — exposed por um empty response transiente do Sonnet às 09:27 que caiu pro `gpt-5.5` e grudou.

WhatsApp + Discord restaurados. Phase 7 adicionada ao playbook. Discord plugin log behavior change documentada.

---

## Severidade & impacto

- **Downtime gateway:** 0 (restart semanal aos domingos 04h funcionou normal)
- **Downtime WhatsApp:** watchdog timeouts mais frequentes (plugin v5.22 vs gateway v5.27), recovery automático funcional
- **Downtime Discord:** **0 real** (era falso positivo na minha análise — plugin v5.27 não loga READY)
- **Erros visíveis:** ~144/dia (a cada 10min) do keepalive cron tentando modelo retired
- **Custo:** ~$0 (errors não acumulam billing, fallback chain funcional)

---

## Sintomas observados

### Alerta inicial
- Discord notification de `⚠️ Sistema — WhatsApp e Discord offline — verificar`
- Toto atribuiu ao upgrade 5.27 de ontem

### Investigação revelou
1. **Gateway restartou às 04:00:03 BRT** — cron semanal aos domingos `0 4 * * 0 /bin/systemctl restart openclaw-gateway` (NÃO estava documentado no CLAUDE.md antes desta lesson)
2. **Errors a cada 10min:**
   ```
   [ws] ⇄ res ✗ agent errorCode=UNAVAILABLE
   errorMessage=Error: Model override "anthropic/claude-haiku-4-5" is not allowed for agent "main"
   ```
3. **WhatsApp watchdog timeouts esporádicos** com `Listening for WhatsApp inbound messages` após recovery
4. **Discord aparentemente stuck** em `[discord] [default] client initialized as <REDACTED-CHANNEL-ID>; awaiting gateway readiness` (último log Discord útil)
5. **`openclaw health`** mostrou `Discord: configured` (não `connected`/`ready`)
6. **Empty response do Sonnet** uma vez às 09:27:02:
   ```
   [model-fallback/decision] decision=candidate_failed requested=anthropic/claude-sonnet-4-6
   reason=empty_response detail=CLI backend returned an empty response.
   ```

---

## Root cause analysis

### Bug 1: Scripts shell esquecidos na migração de modelo de ontem

Ontem (30/mai) migrei 16 cron jobs de `anthropic/claude-haiku-4-5` retired pra `anthropic/claude-haiku-4-5-20251001`. Mas **esqueci dos scripts shell**:
- `/root/.openclaw/scripts/keepalive-harness.sh` linha 22
- `/root/.openclaw/scripts/warmup-harness.sh` linha 15

Ambos usavam `--model anthropic/claude-haiku-4-5` hardcoded. Keepalive cron `*/10 * * * *` gerava erro a cada 10 min.

### Bug 2: Plugins externos `@openclaw/*` ficam em versão antiga após upgrade do core

**Arquitetura (regra #2.2 do CLAUDE.md):**
- **Bundled plugins** (slack/telegram pré-externalization v5.2): `/usr/lib/node_modules/openclaw/dist/extensions/` — atualizados pelo `npm install -g openclaw`
- **External plugins** (`@openclaw/*` v5.2+): `/root/.openclaw/npm/node_modules/@openclaw/` — **NÃO atualizados** pelo upgrade do core; precisam `cd /root/.openclaw/npm && npm install @openclaw/<X>@<v>` separado

**Estado pré-fix:**
```
"dependencies": {
  "@openclaw/acpx":     "2026.5.22",  ⚠️ 5 versões atrás (gateway 5.27)
  "@openclaw/discord":  "2026.5.22",  ⚠️
  "@openclaw/slack":    "2026.5.22",  ⚠️
  "@openclaw/whatsapp": "2026.5.22",  ⚠️
  "@openclaw/codex":    "2026.5.22"   ⚠️
}
```

**Sintomas de incompatibilidade plugin v5.22 vs gateway v5.27:**
- WhatsApp: watchdog timeouts mais frequentes (Baileys SDK é resiliente, recupera automaticamente)
- Discord: travava aparentemente em `awaiting gateway readiness` (depois descoberto que era silent-success no v5.27, não problema do v5.22)

### Bug 3: Discord plugin v5.27 mudou log behavior (silent-success)

**Plugin v5.22 logava:**
```
[discord] client initialized as <id>; awaiting gateway readiness
[discord] gateway READY received (guilds: 1, channels: 7)  ← LOG removido no v5.27
[discord] presence ready
```

**Plugin v5.27 loga apenas:**
```
[discord] client initialized as <id>; awaiting gateway readiness
                                                            ↓ (silent — sem log READY explícito)
```

**Falso positivo gerado:** minha heurística `journalctl | grep "gateway READY"` retornou só uma entry antiga de 25/mai (provavelmente um timeout real naquele dia que NÃO se repetiu). Conclui erroneamente que Discord estava broken desde 25/mai. Toto desmentiu em 30 segundos: "Discord ta funcionando! falei agora com o forge por la".

**Validação correta no plugin v5.27+:**
- `openclaw health` mostra Discord como `configured` (não há mais valor `ready`)
- Interação real (Toto envia mensagem, agent responde)
- Logs de webhook ativos (`[plugins] [webhooks] registered route github-ci on /hooks/github for session forge`)

### Bug 4: Sessions sticky em modelos retired ou fallback

**Regra 5 CLAUDE.md (já documentada):** gateway persiste em `agents/main/sessions/sessions.json` o model do último turn bem-sucedido por session-key. Se uma session caiu uma vez em fallback (gemini/codex), gruda lá até reset manual.

**Estado encontrado:**
- 4 sessions cron em `claude-haiku-4-5` (sem version, retired) — resíduo pré-fix de ontem (cron job tem `payload.model` correto mas session stuck)
- 1 session Discord em `gpt-5.5` — pegou o fallback do empty response de 09:27

---

## Fixes aplicados

### Fix 1 — Scripts shell (sed)
```bash
sed -i 's|anthropic/claude-haiku-4-5\b|anthropic/claude-haiku-4-5-20251001|g' \
  /root/.openclaw/scripts/keepalive-harness.sh \
  /root/.openclaw/scripts/warmup-harness.sh
```
Backups `.bak-pre-haiku-version-20260531-091851`. Smoke test keepalive: exit 0 ✓.

### Fix 2 — Plugins externos batch upgrade (per regra #2.2)
```bash
# Backups
TS=$(date +%Y%m%d-%H%M%S)
cp /root/.openclaw/npm/package.json /root/.openclaw/npm/package.json.bak-pre-plugin-upgrade-$TS
cp /root/.openclaw/npm/package-lock.json /root/.openclaw/npm/package-lock.json.bak-pre-plugin-upgrade-$TS
tar czf /root/openclaw-plugins-pre-5.27-upgrade-$TS.tar.gz /root/.openclaw/npm/node_modules/@openclaw/

# Update batch via npm direto (NUNCA `openclaw plugins install` — bug destrutivo #2.2)
cd /root/.openclaw/npm
npm install @openclaw/acpx@2026.5.27 \
            @openclaw/discord@2026.5.27 \
            @openclaw/slack@2026.5.27 \
            @openclaw/whatsapp@2026.5.27 \
            @openclaw/codex@2026.5.27

# Restart gateway pra carregar novos plugins
systemctl restart openclaw-gateway.service
```
Resultado: 98 packages added, 14 removed, 64 changed, 26s. Backup tarball 376MB. WhatsApp restaurou imediatamente.

### Fix 3 — Sessions cleanup (jq)
```bash
TS=$(date +%Y%m%d-%H%M%S)
cp /root/.openclaw/agents/main/sessions/sessions.json /root/.openclaw/agents/main/sessions/sessions.json.bak-pre-cleanup-$TS

jq 'to_entries
    | map(
        if (.value.model | tostring | test("^claude-haiku-4-5$"))
            then .value.model = "anthropic/claude-haiku-4-5-20251001"
        elif (.value.model | tostring | test("^gpt-5"))
            then del(.value.model)
        else . end
      )
    | from_entries' \
  /root/.openclaw/agents/main/sessions/sessions.json > /tmp/sessions.new.json

jq empty /tmp/sessions.new.json && mv /tmp/sessions.new.json /root/.openclaw/agents/main/sessions/sessions.json
chmod 600 /root/.openclaw/agents/main/sessions/sessions.json
```
Resultado: 4 sessions cron atualizadas, 1 session Discord resetada (re-resolve no próximo turn pro default sonnet).

---

## Prevenção / pattern reusável — Phase 7 mandatória no upgrade do core

**Checklist pós `npm install -g openclaw@<v>`:**

```bash
# 1. Validar versão atual dos externos vs gateway
GW=$(openclaw --version | grep -oE '2026\.[0-9]+\.[0-9]+')
echo "Gateway: $GW"
for p in acpx discord slack whatsapp codex; do
  v=$(jq -r .version /root/.openclaw/npm/node_modules/@openclaw/$p/package.json 2>/dev/null)
  [ "$v" != "$GW" ] && echo "⚠️ @openclaw/$p outdated: $v (want $GW)" || echo "✓ @openclaw/$p $v"
done

# 2. Se outdated: backup + batch update (NUNCA via `openclaw plugins install`)
TS=$(date +%Y%m%d-%H%M%S)
cp /root/.openclaw/npm/package.json /root/.openclaw/npm/package.json.bak-pre-plugin-upgrade-$TS
tar czf /root/openclaw-plugins-pre-$GW-upgrade-$TS.tar.gz /root/.openclaw/npm/node_modules/@openclaw/
cd /root/.openclaw/npm
npm install @openclaw/acpx@$GW @openclaw/discord@$GW @openclaw/slack@$GW @openclaw/whatsapp@$GW @openclaw/codex@$GW

# 3. Restart gateway pra carregar novos
systemctl restart openclaw-gateway.service
sleep 30

# 4. Smoke test
openclaw health  # Discord/WhatsApp deve mostrar 'configured' ou 'linked'
journalctl -u openclaw-gateway.service --since "1 minute ago" | grep -iE "discord|whatsapp|error"

# 5. Validar scripts shell custom (keepalive, warmup, outros) NÃO ficaram com modelo retired
grep -rln 'claude-haiku-4-5[^-]\|claude-opus-4-5[^-]\|claude-sonnet-4-5[^-]' /root/.openclaw/scripts/ 2>/dev/null
# Se algo apareceu: sed -i com o ID versionado

# 6. Verificar sessions sticky em models retired (regra 5)
jq -r '.[].model' /root/.openclaw/agents/main/sessions/sessions.json 2>/dev/null | sort | uniq -c | sort -rn
# Se há sessions em models retired ou em fallback grudado: cleanup via jq
```

**Sintomas de Phase 7 esquecida:**
- WhatsApp watchdog timeouts mais frequentes que normal
- Discord plugin loop de reconnect (em versões < 5.27 que logam READY)
- Plugin breaking changes silenciosos (events que mudaram name/payload entre versões do core)

---

## Heurística de validação Discord — NÃO usar com plugin v5.27+

❌ **Antiga (false negative no v5.27):**
```bash
journalctl | grep "gateway READY"
journalctl | grep "discord.*ready"
```

✅ **Nova:**
```bash
# Plugin v5.27 não loga READY explícito; validar de outras formas:
openclaw health | grep Discord          # mostra "configured" quando plugin carregado
journalctl --since "10 minutes ago" | grep -iE "session forge|webhooks.*forge"  # webhooks ativos = bot OK
# Definitivo: interação real (Toto envia mensagem, agent responde)
```

---

## Backups dessa sessão

```
/root/.openclaw/scripts/keepalive-harness.sh.bak-pre-haiku-version-20260531-091851
/root/.openclaw/scripts/warmup-harness.sh.bak-pre-haiku-version-20260531-091851
/root/.openclaw/npm/package.json.bak-pre-plugin-upgrade-20260531-091851
/root/.openclaw/npm/package-lock.json.bak-pre-plugin-upgrade-20260531-091851
/root/openclaw-plugins-pre-5.27-upgrade-20260531-091851.tar.gz  (376M)
/root/.openclaw/agents/main/sessions/sessions.json.bak-pre-cleanup-20260531-092924
```

---

## Estado final (09:35 BRT)

| Métrica | Valor |
|---|---|
| OpenClaw core | 5.27 (27ae826) |
| Plugins externos | **TODOS em 2026.5.27** (acpx, discord, slack, whatsapp, codex) ✅ |
| Gateway | active, uptime ~15min |
| **WhatsApp** | ✅ Listening |
| **Discord** | ✅ funcional (silent-success no plugin v5.27 — Toto confirmou interagindo com Forge) |
| **Slack** | ✅ configured |
| Keepalive cron | ✅ smoke test exit 0 |
| Errors haiku 10min | ✅ ZERO |
| Sessions sticky em retired | ✅ ZERO (cleanup aplicado) |
| Doctor warnings | 0 |

---

## Pendências (não-bloqueantes)

- **Monitorar empty response do Sonnet** — 1 ocorrência isolada às 09:27, sem padrão. Se recorrer, investigar Claude CLI subprocess health.
- **Task #16** Avaliar desligar `keepalive-harness.sh` cron + `openclaw-warmup.service` após 7d sem MissingAgentHarnessError (~2026-06-06).
- **Próximo check automático:** `check-reindex-postnight.sh` em **1/jun 06:03 BRT**. Esperada 🟢 GREEN.

---

## Cross-references

- **Lessons relacionadas:**
  - `2026-05-30-openclaw-5.27-upgrade-and-vec0-cli-recovery.md` — sessão de upgrade que esqueceu Phase 7
  - `2026-05-24-upgrade-5.22-harness-restart-latency-and-plugin-config-env.md` — upgrade anterior com pattern similar
  - `2026-05-03-openclaw-v5.2-upgrade-pitfalls.md` — plugin externalization (origem do path `/root/.openclaw/npm/`)

- **Memórias persistentes:**
  - `external-plugins-need-explicit-update-on-openclaw-upgrade.md` (criada hoje) — checklist Phase 7 + alerta sobre log change Discord
  - `openclaw-haiku-not-in-default-allowlist.md` — pattern allowlist (referência cruzada com migração de modelo)

- **Incident log:** `infra/docs/INCIDENTS.md` (entry 2026-05-31 com 4 achados)
- **Handoff:** `infra/docs/HANDOFF.md` (seção "Onde paramos" 2026-05-31)
- **CLAUDE.md infra:** Phase 7 mandatória adicionada à regra #1

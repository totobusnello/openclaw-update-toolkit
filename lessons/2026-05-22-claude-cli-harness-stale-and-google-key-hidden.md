# Lesson 2026-05-22 — Claude CLI harness "not registered" pós-upgrade + chave Google escondida em 3 lugares

## Sintoma

Manhã do dia seguinte ao upgrade 5.20: agents pararam de responder.

- **WhatsApp:** Nox virou silêncio (sem resposta a DMs)
- **Discord:** todos os channels passaram a mostrar **`⚠️ Requested agent harness "claude-cli" is not registered`** acima dos prompts
- **Sessions log:** WhatsApp DM `+5511***********` ficou stuck em `processing age=139s queueDepth=1 reason=queued_behind_active_work` por ~5 min sem resposta

Nenhum erro fatal no journal, gateway ativo, `openclaw status` retornava channels `OK`. Sintoma puramente comportamental.

## Diagnóstico

### Phase 1 — Onde está o erro real

`/tmp/openclaw/openclaw-2026-05-22.log` (path novo do 5.20, antes era `/root/.openclaw/logs/`) revelou erro tipado:

```
{"subsystem":"diagnostic","logLevelName":"ERROR",
 "message":"lane task error: lane=main durationMs=13
  error=\"MissingAgentHarnessError: Requested agent harness \"claude-cli\" is not registered.\""}
```

Erro disparava em **TODA** lane (main + cada Discord session). Cada turn:
1. Gateway recebe msg → roteia pro harness `claude-cli` (declarado em `agents.defaults.models.anthropic/*.agentRuntime.id`)
2. Registry retorna `MissingAgentHarnessError`
3. Fallback chain ativada → cai pra `openai-codex/gpt-5.5`
4. WhatsApp Nox respondia (via Codex) mas com modelo errado; Discord rendering condicional mostrava o warning de harness antes do reply

### Phase 2 — Por que harness sumiu do registry (race condition de boot)

Em 5.20, `@openclaw/anthropic-provider` (stock plugin que registra o harness `claude-cli`) tem `activation.onStartup: false` no manifest — **lazy plugin**. O processo do gateway estava rodando desde **2026-05-21 22:30 BRT** (logo após o restart pós-upgrade do dia anterior).

**Smoking gun no log às 11:58 BRT (auto-detected):**
```
gateway tool: restart requested (delayMs=default,
 reason=Forge Discord session had stale modelProvider=claude-cli state;
 restart needed to clear in-memory lane/session state.)
```

Gateway pediu **in-process restart** às 12:04 BRT. Mas in-process restart só limpa session state — **não recarrega plugins**.

**Diagnóstico real (confirmado empiricamente após o full restart):**

O erro **NÃO é invalidação permanente do registry**. É uma **race condition transiente** que dispara nos primeiros segundos após qualquer reload de webhook do Discord:

1. Item na fila inbound do Discord (do Forge ou outro channel) chega
2. Lane handler tenta resolver harness `claude-cli`
3. Plugin `@openclaw/anthropic-provider` ainda **não ativou** (lazy, `activation.onStartup: false`)
4. Registry retorna `MissingAgentHarnessError`
5. Sistema tenta novamente (até 3x conforme retry policy)
6. Plugin ativa entre tentativas, registry popula, **próximas requests funcionam normal**
7. Janela de exposição total: ~90 segundos (medido empiricamente: cluster de erros entre 13:50:50 → 13:52:26 e auto-recovery)

**Diff de plugin loading no source code** (`api-builder-DsIoFkN8.js` + `loader-C2-kzSfV.js`): `registerAgentHarness$1` exige plugin record com `id` populado + active. Plugin lazy só "ativa" sob demand — e durante boot/webhook-reload o request pode chegar antes da ativação.

**Por que pareceu pior do que era:**
- A fila do Forge Discord ficou com 1 mensagem stuck do upgrade da noite anterior
- WhatsApp não foi afetado em momento algum (cli-backend funcionou normal)
- Aparição na UI do Discord (warning visível) magnificou impacto percebido
- Após qualquer restart, janela de 90s mostra os erros antes de estabilizar — **comportamento esperado, não regressão**

### Phase 3 — Fix do harness era simples; achei OUTRO problema oculto

`systemctl restart openclaw-gateway` (não `openclaw update`, não in-process). Old PID `2019170` → New PID `2129013`, ready em 2s.

**Importante:** os primeiros ~90s pós-restart ainda mostram `MissingAgentHarnessError` em logs (race do plugin lazy descrita acima). Sistema auto-recupera. Validation correta = monitorar 2-3 min e confirmar `count==0` na janela atual, não na janela total do dia.

Logs imediatos após estabilização:
- Forge Discord session JÁ usando `claude-cli/claude-opus-4-7` runtime `Claude CLI` ✓
- Nox Discord session `claude-cli/claude-sonnet-4-6` runtime `Claude CLI` ✓

**Mas** logs continuaram emitindo erro DIFERENTE (graph-memory):
```
[graph-memory] embedding probe failed: Error: [graph-memory] Embedding API 400:
{"error":{"code":400,"message":"API key expired. Please renew the API key."}}
```

Confirmado também via `openclaw memory search`:
```
[memory] sync failed (search-bootstrap):
 Error: gemini embeddings failed (400): API key expired.
```

### Phase 4 — As 3 fontes da chave Google

Toto passou chave nova válida (`<NEW_KEY_REDACTED>`). Probe direto:
```bash
curl -s -o /dev/null -w "%{http_code}" \
  "https://generativelanguage.googleapis.com/v1beta/openai/embeddings" \
  -H "Authorization: Bearer $NEW_KEY" \
  -d '{"model":"gemini-embedding-001","input":"test","dimensions":3072}'
# → 200 (embeddings reais retornados)
```

Chave nova já estava em `.env`. Mas gateway continuava recebendo "expired".

Investigação revelou **3 lugares distintos onde a chave existe**, com substituição `${VAR}` quebrada em parte deles:

| Path | Conteúdo | Substituição funciona? |
|---|---|---|
| `/root/.openclaw/.env` (`GEMINI_API_KEY=<key>`) | Chave bruta | N/A — fonte primária |
| `openclaw.json: models.providers.gemini.apiKey` | `${GEMINI_API_KEY}` literal | ❌ Não substituiu (cache stale?) |
| `openclaw.json: plugins.entries.graph-memory.config.embedding.apiKey` | `${GEMINI_API_KEY}` literal | ❌ Não substituiu |
| `openclaw.json: plugins.entries.graph-memory.config.llm.apiKey` | `${GEMINI_API_KEY}` literal | ❌ Não substituiu |
| **`/root/.openclaw/agents/main/agent/auth-profiles.json: profiles."google:default".key`** | **chave hardcoded LITERAL antiga (expirada)** | ✅ Lido mas valor literal antigo |

O **terceiro lugar** foi a real bomba. `auth-profiles.json` é onde o sistema de `resolveApiKeyForProvider({ provider: "google" })` lê — usado pelo `MemoryIndexManager.loadProviderResult` → `resolveGeminiEmbeddingClient`. E a chave ali estava **`<OLD_EXPIRED_KEY_REDACTED>`** (expirada há semanas) gravada hard-coded.

**Outros 6 sub-agents (atlas/nox/boris/cipher/forge/lex):** todos têm `auth-profiles.json` próprio mas **sem `google:default`** — herdam do main quando precisam.

**Observação inconsistente:** alguns profiles no MESMO arquivo `auth-profiles.json` usam `${VAR}` e funcionam:
```json
"anthropic:default": { "type": "token", "token": "${ANTHROPIC_MAX_API_KEY}" },     // ✅ substitui
"anthropic-max:default": { "type": "api_key", "key": "${ANTHROPIC_MAX_API_KEY}" }, // ✅ substitui
"google:default": { "type": "api_key", "key": "<OLD_EXPIRED_GOOGLE_KEY_REDACTED>" } // ❌ literal antiga
```

Provavelmente o `google:default` foi configurado manualmente em algum momento antigo via `openclaw config set` ou similar que persistiu literal, enquanto os anthropic vieram via fluxo que usa `${VAR}`. Inconsistência do schema 5.20.

## Fix aplicado

### 1. Restart full do system service (sem `openclaw update`)

```bash
ssh root@<REDACTED-TAILSCALE-IP> 'systemctl restart openclaw-gateway'
# ~2s pra health endpoint responder
```

Old PID → New PID, plugin registry repovoado, `MissingAgentHarnessError` sumiu permanentemente.

### 2. ~~Aplicar chave literal nos paths de plugin config~~ — DESCONSIDERAR

Aplicado durante debug por hipótese errada de substituição quebrada. **REVERTIDO** após confirmar que o problema real era outro. Manter os 3 paths como `${GEMINI_API_KEY}` (regra #9):
```bash
openclaw config set models.providers.gemini.apiKey '${GEMINI_API_KEY}'
openclaw config set plugins.entries.graph-memory.config.embedding.apiKey '${GEMINI_API_KEY}'
openclaw config set plugins.entries.graph-memory.config.llm.apiKey '${GEMINI_API_KEY}'
```
(Use aspas simples no shell pra evitar expansão local de `${VAR}`.)

### 3. Atualizar `google:default` em `auth-profiles.json` (jq direto, não há CLI exposto)

```bash
F=/root/.openclaw/agents/main/agent/auth-profiles.json
cp "$F" "${F}.bak-pre-google-key-$(date +%Y%m%d-%H%M%S)"
jq --arg key "$NEW_KEY" '.profiles."google:default".key = $key' "$F" > /tmp/auth-new.json
mv /tmp/auth-new.json "$F"
chmod 600 "$F"
```

Validação que a chave gravou (sha256 first-16 chars sem expor o valor):
```bash
jq -r '.profiles."google:default".key' "$F" | tr -d '\n' | sha256sum | cut -c1-16
# Comparar com hash esperado
```

### 4. Reset session WhatsApp stuck (persisted state grudou no fallback Codex)

```bash
SFILE=/root/.openclaw/agents/main/sessions/sessions.json
cp "$SFILE" "${SFILE}.bak-pre-reset-$(date +%Y%m%d-%H%M%S)"
jq 'del(."agent:main:whatsapp:direct:+5511***********")' "$SFILE" > /tmp/sessions-new.json
mv /tmp/sessions-new.json "$SFILE"
chmod 600 "$SFILE"
# 34 → 33 entries; próxima msg cria nova session com runtime correto
```

### 5. Fix Discord `groupAllowFrom` (doctor warning legado da sessão anterior)

`channels.discord.groupAllowFrom` em top-level rejeitado pelo schema 5.20:
```
Error: Config validation failed: channels.discord: invalid config: must NOT have additional properties
```

Path que FUNCIONA é `channels.discord.allowFrom`:
```bash
openclaw config set channels.discord.allowFrom '["*"]'
```

Doctor warning sumiu (parece que em 5.20 o `allowFrom` cobre tanto DM quanto a verificação do group policy gate).

### 6. Restart final + validação

```bash
systemctl restart openclaw-gateway
openclaw doctor 2>&1 | grep -iE "error|warn|expired"
# Errors: 0
openclaw memory search "test"
# No error; empty result (não tem dado indexado, mas sem failure)
```

## Resultado

```
Doctor: Errors: 0
Health: event loop ok max=33ms p99=22ms util=0.072
Discord: configured (warning groupAllowFrom resolvido)
Slack: configured
WhatsApp: linked (auth age 1m)
Sessions Claude CLI:
  agent:forge:discord:channel:**: claude-cli/claude-opus-4-7
  agent:main:whatsapp:direct:**: claude-cli/claude-sonnet-4-6
Errors last 60s: 0
```

Cost: $0 (de volta a OAuth Max headless via subprocess Claude CLI, sem API billing).

## Lições

### 1. Lazy plugin `@openclaw/anthropic-provider` causa race transiente — esperar 90s antes de declarar regressão

O `activation.onStartup: false` no manifest do `@openclaw/anthropic-provider` cria janela de exposição de ~90s em **TODO** restart do gateway (full ou hot-reload de webhook):
- Items na fila inbound que chegam nesses 90s veem `MissingAgentHarnessError`
- Sistema tenta 3x e depois cai pra fallback chain (ou drop, dependendo da policy)
- **Auto-recupera assim que o plugin ativa por demand**

**Nova regra operacional:**
- ✅ Sintoma comportamental por <2 min → esperar e re-validar; NÃO restartar (vai recriar a janela)
- ⚠️ Sintoma comportamental por >5 min → investigar, possível `systemctl restart` se outras evidências sugerirem registry corrompido
- ❌ NÃO concluir regressão olhando contagem total de erros do dia — filtrar pela janela atual (`ts >= NOW - 60s`)

**Issue upstream pra abrir:** sugerir `activation.onStartup: true` pro `@openclaw/anthropic-provider` dado que TODO modelo Anthropic depende dele. Eliminaria a janela de race.

### 2. Restart é mandatory pra recarregar plugin registry — `openclaw update` é insuficiente

Continua válido (já documentado em `[[2026-05-21-openclaw-5.20-upgrade-regressions]]`): `openclaw update` instala binário mas não restarta system service. `systemctl restart openclaw-gateway` é obrigatório pós-upgrade pra repovoar registry de plugins.

In-process restart (`gateway tool: restart requested`) só limpa session state — **não recarrega plugins**. Quando o gateway pede in-process restart por conta própria, isso é INSUFICIENTE pra resolver "harness not registered". Precisa systemctl full restart.

### 2. Chaves de API em OpenClaw moram em 3 lugares — rotação precisa atualizar TODOS

Pré-rotação, checar:
```bash
# 1. .env
grep "^GEMINI_API_KEY=" /root/.openclaw/.env

# 2. openclaw.json (3 paths possíveis)
for p in "models.providers.gemini.apiKey" \
         "plugins.entries.graph-memory.config.embedding.apiKey" \
         "plugins.entries.graph-memory.config.llm.apiKey"; do
  echo "$p = $(jq -r ".$p" /root/.openclaw/openclaw.json | head -c 12)..."
done

# 3. auth-profiles.json (per-agent; mas só main tem google:default normalmente)
find /root/.openclaw -name "auth-profiles.json" \
  -not -path "*node_modules*" -not -path "*checkpoint*" -not -path "*backup*" \
  -exec sh -c 'echo "$1: $(jq -r '"'"'.profiles."google:default".key'"'"' "$1" 2>/dev/null | head -c 12)..."' _ {} \;
```

Se hashes (sha256 first-16) divergem entre eles, rotação ficou parcial.

### 3. Substituição `${VAR}` no openclaw.json FUNCIONA — minha hipótese de "broken substitution" era equivocada

Hipótese inicial errada: imaginei que `${GEMINI_API_KEY}` em `plugins.entries.*.config.apiKey` não substituía. Empiricamente após o fix real, **substitui sim** — sistema funciona com:
```json
"plugins.entries.graph-memory.config.embedding.apiKey": "${GEMINI_API_KEY}"
```

O que pareceu "substituição quebrada" era na verdade o `auth-profiles.json google:default.key` ter chave EXPIRADA hardcoded — esse arquivo NÃO usa substituição (campo recebe valor literal direto via `setup-token` ou edição manual). Code path `resolveApiKeyForProvider({provider: "google"})` lê dali, não do openclaw.json.

**Regra #9 do CLAUDE.md mantém validade total.** Secrets em `${VAR}` no openclaw.json é o caminho correto. Workaround literal que apliquei durante debug foi **revertido** após confirmar que o problema era outro.

**Cuidado pra debugging:** quando um secret aparece como "expired" no log, mapear TODOS os possíveis lugares antes de declarar "substituição quebrada". Em 5.20 existem ao menos 3 paths possíveis (env, openclaw.json, auth-profiles.json).

### 4. Doctor warning sobre `groupAllowFrom` é confuso e contradiz o schema

Doctor sugere literalmente:
> Add sender IDs to `channels.discord.groupAllowFrom` or `channels.discord.allowFrom`, or set `groupPolicy` to "open".

Mas `channels.discord.groupAllowFrom` (path sugerido) é **rejeitado pelo validator**:
```
must NOT have additional properties
```

Caminho que funciona: `channels.discord.allowFrom = ["*"]`. Vale abrir issue upstream pra ajustar a doctor message ou aceitar o path sugerido.

## Próximos passos sugeridos

1. **Issue upstream openclaw/openclaw:** documentar que registry de harness pode ficar inconsistente sob transições lazy do `@openclaw/anthropic-provider`. Sugestão: `activation.onStartup: true` pra esse plugin específico, dado que TODO modelo Anthropic depende dele.
2. **Issue upstream:** ajustar doctor message do groupAllowFrom pra refletir o schema real do 5.20.
3. **Issue upstream:** documentar (ou corrigir) inconsistência de substituição `${VAR}` entre `auth.profiles.*.token` (funciona) e `plugins.entries.*.config.apiKey` (não funciona).
4. **Pre-flight check antes de qualquer rotação de chave** — script `infra/scripts/check-key-consistency.sh` (TODO) que valida sha256 das 3 fontes. Adicionar como hook do cron `06:00 sync-verify`.
5. **Atualizar regra #9 do `infra/CLAUDE.md`** pra refletir que em 5.20 valor literal é OK em `plugins.entries.*.config.apiKey` quando `${VAR}` falha (até upstream resolver).

## Backups criados nesta sessão

- `/root/.openclaw/openclaw.json.bak-pre-harness-fix-20260522-125849`
- `/root/.openclaw/.env.bak-pre-harness-fix-20260522-125849`
- `/root/.openclaw/openclaw.json.bak-pre-key-literal-20260522-131853`
- `/root/.openclaw/agents/main/sessions/sessions.json.bak-pre-reset-20260522-132055`
- `/root/.openclaw/openclaw.json.bak-pre-pendings-20260522-133036`
- `/root/.openclaw/agents/main/agent/auth-profiles.json.bak-pre-google-key-20260522-134010`

## Memórias correlatas (em `~/.claude/projects/.../memory/`)

- `[[openclaw-upgrade-restart-mandatory]]` — sempre `systemctl restart` após upgrade
- `[[env-var-substitution-broken-in-plugin-config]]` — chaves literais como workaround
- `[[auth-profiles-hidden-key-store]]` — as 3 fontes da chave de API
- `[[openclaw-update-skips-system-service-restart]]` — CLI só vê user service
- `[[plugins-allow-gate-2026-05-21]]` — gate novo do 5.20

## Lessons correlatas

- `2026-05-21-openclaw-5.20-upgrade-regressions.md` — incident anterior do mesmo upgrade
- `2026-04-20-openclaw-gateway-fratricide-issue-62028.md` — issue clássica de in-process restart

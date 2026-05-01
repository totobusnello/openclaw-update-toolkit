# OpenClaw v2026.4.x Recovery Guide

> Guide diagnostic-driven pra estabilizar instalação OpenClaw rodando entre v2026.4.24 e v2026.4.29.
> Compilado a partir de incidents reais e fixes validados em produção (sessão de troubleshooting 2026-05-01).
> Cobre: custos inesperados, fratricide pós-upgrade, Telegram 409 conflict, leak de DM, label cosmético enganoso.

---

## 🤖 META-PROMPT — cole isso pro seu Claude no início

```
Você é um operador de recuperação OpenClaw. O guide abaixo descreve como
diagnosticar e estabilizar a instalação do meu amigo. Regras estritas:

1. Conecte na VPS via SSH (vou te dar credenciais separadamente)
2. Comece SEMPRE pela Phase 0 (diagnóstico read-only) — nunca mude
   nada antes de me reportar o estado completo
3. Para cada Recipe que eu autorizar, faça BACKUP antes de qualquer
   write. Sem exceção.
4. NUNCA imprima no chat: tokens, credenciais, números de telefone,
   API keys, OAuth tokens (formato sk-*, sk-ant-oat01-*, xoxp-*, etc)
5. Espere autorização explícita antes de cada Recipe. Não tome
   decisão sozinho. "Continua" não é blanket approval — é confirmação
   pra próximo item específico.
6. Se algum comando falhar, PARE e reporte. Não tente "corrigir
   sozinho" via chains de fixes não autorizados.
7. Pós cada Recipe: rodar a seção VALIDATION e me mostrar resultado.
8. Se algo quebrar: usar a seção REVERT do mesmo Recipe.

Ordem recomendada: Phase 0 → me reportar → eu autorizo Recipes
priorizados → Phase 5 (validação final).

Comece agora pela Phase 0.
```

---

## Phase 0 — Diagnostic (read-only, ~3min)

Rode esse bash one-liner via SSH na VPS. Reporta tudo formatado em markdown.

```bash
ssh root@<vps-ip> << 'EOF'
echo "## OpenClaw Diagnostic Report — $(date -Iseconds)"
echo
echo "### A. Versão e processo"
openclaw --version 2>/dev/null || echo "openclaw CLI ausente"
ps -ef | grep openclaw | grep -v grep | awk '{print $2, $3, $9, $10}'
systemctl is-active openclaw-gateway 2>/dev/null
systemctl status openclaw-gateway --no-pager 2>/dev/null | grep -E "Active|Memory|Tasks|Main PID" | head -5
echo
echo "### B. Restart counter (saúde)"
systemctl show openclaw-gateway -p NRestarts -p Restart 2>/dev/null
echo "Recent fratricide indicators:"
journalctl -u openclaw-gateway --since "2 hours ago" --no-pager 2>/dev/null | grep -cE "Gateway already running|SIGTERM|cleanStale" || echo 0
echo
echo "### C. Monkey-patch fratricide #62028"
PATCH_FILE=$(ls /usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js 2>/dev/null | xargs -I{} sh -c 'wc -l < "{}" | grep -v ^[0-9]$ ; echo {}' | awk 'NR%2==0 && prev>100 {print $0} {prev=$1}' | head -1)
[ -n "$PATCH_FILE" ] || PATCH_FILE=$(ls /usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js 2>/dev/null | head -1)
if [ -f "$PATCH_FILE" ]; then
  if grep -q "MONKEY-PATCH.*62028\|return \[\];$" "$PATCH_FILE" | head -3; then
    grep -A2 "function cleanStaleGatewayProcessesSync" "$PATCH_FILE" | head -5
  else
    echo "PATCH MISSING — fratricide risk!"
  fi
else
  echo "patch file not found"
fi
echo
echo "### D. Custo zero — claude-cli ativo?"
journalctl -u openclaw-gateway --since "1 hour ago" --no-pager 2>/dev/null | grep -E "provider=claude-cli|provider=anthropic[^-]" | tail -3
echo "Anthropic API calls (PAID path):"
journalctl -u openclaw-gateway --since "1 hour ago" --no-pager 2>/dev/null | grep -cE "api\.anthropic\.com|x-api-key" || echo 0
echo
echo "### E. Agents runtime config"
jq -r '.agents.list[]? | "\(.id): runtime=\(.agentRuntime.id // "DEFAULT")"' /root/.openclaw/openclaw.json 2>/dev/null
echo "defaults:"
jq '.agents.defaults | {agentRuntime: .agentRuntime.id, model: .model.primary, fallbacks: .model.fallbacks}' /root/.openclaw/openclaw.json 2>/dev/null
echo
echo "### F. Telegram conflict count (last hour + last 24h)"
echo "1h: $(journalctl -u openclaw-gateway --since '1 hour ago' --no-pager 2>/dev/null | grep -cE 'telegram.*conflict|409.*Conflict')"
echo "24h: $(journalctl -u openclaw-gateway --since '24 hours ago' --no-pager 2>/dev/null | grep -cE 'telegram.*conflict|409.*Conflict')"
echo
echo "### G. Claude CLI plugins enabled (root user)"
jq '.enabledPlugins // {}' /root/.claude/settings.json 2>/dev/null
echo "Has channels preset:"
jq 'has("channels")' /root/.claude/settings.json 2>/dev/null
echo
echo "### H. Credentials state"
ls -la /root/.claude/.credentials.json 2>/dev/null
lsattr /root/.claude/.credentials.json 2>/dev/null
echo
echo "### I. Session config"
jq '{session: .session, reload: .gateway.reload, mdns: .discovery.mdns.mode, commands: .commands.restart}' /root/.openclaw/openclaw.json 2>/dev/null
echo
echo "### J. Anthropic provider baseUrl (deve ser api.anthropic.com)"
jq '.models.providers.anthropic.baseUrl' /root/.openclaw/openclaw.json 2>/dev/null
echo
echo "### K. RelayPlane (deve estar inactive)"
systemctl is-active relayplane-proxy 2>/dev/null || echo "inactive (good)"
echo
echo "### L. Auth profiles (mode of each)"
jq '.auth.profiles // {} | to_entries | map({k: .key, mode: .value.mode})' /root/.openclaw/openclaw.json 2>/dev/null
echo
echo "### M. Plugin-runtime-deps disk usage"
du -sh /root/.openclaw/plugin-runtime-deps/openclaw-* 2>/dev/null | head -10
echo
echo "### N. Stability bundles last 24h (gateway crash forensics)"
ls -1t /root/.openclaw/logs/stability/*.json 2>/dev/null | head -5
EOF
```

### Como interpretar o output

| Seção | OK | Alerta | Ação |
|-------|-----|---------|------|
| **A** | versão = 2026.4.29, gateway active | versão < 4.27 ou múltiplos PIDs `openclaw` | Recipe A (upgrade) |
| **B** | NRestarts=0, fratricide=0 | NRestarts ≥ 5 ou fratricide > 0 | Recipe D (monkey-patch) |
| **C** | mostra `MONKEY-PATCH.*62028` + `return [];` | "PATCH MISSING" | Recipe D |
| **D** | `provider=claude-cli` presente, `api.anthropic.com calls = 0` | calls > 0 | Recipe B (kill switch) |
| **E** | todos agentes com `runtime=claude-cli` | `runtime=DEFAULT` ou `pi` | Recipe B |
| **F** | 0 conflicts | conflicts > 0 | Recipe G (telegram plugin) |
| **G** | `telegram@*: false` | `: true` | Recipe G |
| **H** | `credentials.json` existe + tem `i` (immutable) | falta ou sem `i` | Recipe E |
| **I** | `dmScope=per-channel-peer`, `reload.mode=hot`, `mdns=off` | `dmScope=main` ou ausente | Recipe H |
| **J** | `https://api.anthropic.com` | `:4100` (RelayPlane) | Recipe F |
| **K** | inactive | active | Recipe F |
| **L** | profiles existem com modes esperados | `anthropic-max` em fallback chain | Recipe B |
| **M** | só dirs ativos + 1 stale máx | 4+ dirs antigos | Recipe K (cleanup) |
| **N** | 0 nas últimas 24h | múltiplos | investigar bundles |

---

## Fix Recipes

### Recipe A — Upgrade controlado v.24/.25/.26 → v.29

**SYMPTOM:** versão antiga, instabilidade pós-upgrade anterior.

**CAUSA RAIZ:** `npm install -g openclaw@<v>` reinstala `node_modules/dist/`, **invalidando monkey-patch fratricide** (Issue #62028) e podendo reescrever `models.providers.anthropic.baseUrl` pra RelayPlane (`http://127.0.0.1:4100`).

**FIX:**
```bash
# 1. Backup
cp /root/.openclaw/openclaw.json /root/.openclaw/openclaw.json.bak-pre-upgrade-$(date +%Y%m%d)
cp /root/.openclaw/.env /root/.openclaw/.env.bak-pre-upgrade-$(date +%Y%m%d)

# 2. Stop gateway (drop-in pra evitar auto-restart)
mkdir -p /etc/systemd/system/openclaw-gateway.service.d
echo -e "[Service]\nRestart=no" > /etc/systemd/system/openclaw-gateway.service.d/no-restart.conf
systemctl daemon-reload
systemctl stop openclaw-gateway
pkill -9 openclaw 2>/dev/null
sleep 2

# 3. Upgrade
npm install -g openclaw@2026.4.29

# 4. Reaplicar monkey-patch (ver Recipe D)
# 5. Validar baseUrl (Recipe F)
# 6. Remove drop-in
rm /etc/systemd/system/openclaw-gateway.service.d/no-restart.conf
systemctl daemon-reload
systemctl start openclaw-gateway
```

**VALIDATION:** `openclaw --version` mostra 2026.4.29; gateway active sem crash loop em 30s.

**REVERT:** `npm install -g openclaw@<previous-version>` + restaurar `.bak`s.

---

### Recipe B — Kill switch anti-cobrança Anthropic

**SYMPTOM:** custos inesperados na Anthropic API; logs mostram `provider=anthropic` em vez de `provider=claude-cli`.

**CAUSA RAIZ:** agentes configurados com `agentRuntime: { id: "pi" }` (default) usam profile `anthropic:default` (mode=token, API key paga). Solução: forçar todos pra `claude-cli` que usa OAuth Max local (zero custo).

**FIX:**
```bash
# Backup
cp /root/.openclaw/openclaw.json /root/.openclaw/openclaw.json.bak-pre-runtime-fix-$(date +%Y%m%d-%H%M%S)

# Setar agentRuntime=claude-cli em todos os agentes
openclaw config set agents.defaults.agentRuntime.id claude-cli

# Pra cada agente individual, repetir:
# Listar primeiro:
jq -r '.agents.list[].id' /root/.openclaw/openclaw.json
# Depois pra cada:
# openclaw config set agents.list.<INDEX>.agentRuntime.id claude-cli

# Restart pra aplicar
systemctl restart openclaw-gateway
```

**VALIDATION:**
```bash
journalctl -u openclaw-gateway --since "30 seconds ago" | grep "provider=claude-cli"
journalctl -u openclaw-gateway --since "30 seconds ago" | grep -c "api.anthropic.com"
# Esperado: provider=claude-cli aparecendo + zero requests api.anthropic.com
```

**REVERT:** `mv` o backup .bak de volta + `systemctl restart openclaw-gateway`.

**ATENÇÃO:** Se `ANTHROPIC_API_KEY` estiver no `.env`, **NÃO comente a linha** — o plugin runtime do provider `anthropic-max` exige a var no startup mesmo sem uso. Comentar quebra startup com `SecretRefResolutionError`. Kill switch real é a config dos agentes, não env var.

---

### Recipe C — Fallback chain limpa

**SYMPTOM:** mesmo com claude-cli, custos aparecem; fallback grudado em modelo pago.

**CAUSA RAIZ:** `agents.defaults.model.fallbacks` apontando pra Anthropic (`anthropic/*`) ou outro provider pago como primeiro fallback. Quando claude-cli falha uma vez, sessão "gruda" no fallback.

**FIX:**
```bash
# Validar chain atual
jq '.agents.defaults.model' /root/.openclaw/openclaw.json

# Setar chain canônica
openclaw config set 'agents.defaults.model.fallbacks' '["openai-codex/gpt-5.5","gemini/gemini-2.5-pro"]'

# Reset sessions stickiness (CADA agente)
for agent in $(jq -r '.agents.list[].id' /root/.openclaw/openclaw.json); do
  SESS=/root/.openclaw/agents/$agent/sessions/sessions.json
  if [ -f "$SESS" ]; then
    cp "$SESS" "$SESS.bak-$(date +%Y%m%d-%H%M%S)"
    jq 'with_entries(select(.value.model | tostring | startswith("claude-")))' "$SESS" > "$SESS.tmp" && mv "$SESS.tmp" "$SESS"
  fi
done

systemctl restart openclaw-gateway
```

**VALIDATION:** `jq '.agents.defaults.model.fallbacks' /root/.openclaw/openclaw.json` mostra `[openai-codex/gpt-5.5, gemini/gemini-2.5-pro]`.

**REVERT:** restaurar `.bak`s de `sessions.json` e `openclaw.json`.

---

### Recipe D — Reaplicar monkey-patch fratricide #62028

**SYMPTOM:** crash loop pós-upgrade (15+ restarts/5min, SIGTERM em ~20s, "Gateway already running locally" nos logs).

**CAUSA RAIZ:** Issue #62028 (gateway fratricide). Função `cleanStaleGatewayProcessesSync` em `/usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js` mata o próprio gateway. Patch faz a função retornar `[]` direto. **O hash do nome do arquivo muda a cada versão** — usar glob.

**FIX:**
```bash
# Encontrar arquivo impl (não wrapper de 2 linhas)
PATCHFILES=$(ls /usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js)
TARGET=""
for F in $PATCHFILES; do
  LINES=$(wc -l < "$F")
  if [ "$LINES" -gt 100 ]; then TARGET="$F"; break; fi
done
echo "patching: $TARGET"

# chattr -i se já estava imutável
chattr -i "$TARGET" 2>/dev/null || true

# Backup
cp "$TARGET" "$TARGET.bak-$(date +%Y%m%d-%H%M%S)"

# Patch via Python (regex)
python3 - "$TARGET" << 'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f: c = f.read()
if 'MONKEY-PATCH' in c and 'Issue #62028' in c:
    print('SKIP: already patched'); sys.exit(0)
new = re.sub(
    r'(function cleanStaleGatewayProcessesSync\([^)]*\)\s*\{\s*try\s*\{)',
    r'\1\n\t\t// MONKEY-PATCH: Issue #62028 fratricide fix (reapplied on upgrade)\n\t\treturn [];',
    c, count=1
)
if new == c:
    print('ERROR: pattern not matched'); sys.exit(1)
with open(path, 'w', encoding='utf-8') as f: f.write(new)
print('OK patched')
PYEOF

# Validar
grep -A3 "function cleanStaleGatewayProcessesSync" "$TARGET" | head -5

# Wrapper imutável (se ainda não)
if [ -f /usr/local/bin/openclaw-gateway-wrapper ]; then
  chattr +i /usr/local/bin/openclaw-gateway-wrapper
fi

systemctl restart openclaw-gateway
```

**VALIDATION:** `systemctl show openclaw-gateway -p NRestarts` retorna 0 após 60s; logs sem "Gateway already running".

**REVERT:** `chattr -i $TARGET; cp $TARGET.bak-* $TARGET; systemctl restart openclaw-gateway`.

**INVARIANTE:** **toda vez** que rodar `npm install/update -g openclaw` ou `openclaw models auth login/setup-token`, **reaplicar imediatamente** antes de restart. Senão crash loop.

---

### Recipe E — Credentials.json Claude CLI imutável

**SYMPTOM:** após algumas horas, agents falham com "Not logged in" / HTTP 401.

**CAUSA RAIZ:** Claude CLI quando spawned como subprocess sem TTY em condição de erro faz "self-fix" zerando `~/.claude/.credentials.json`. Próximo turn falha autenticação.

**FIX:**
```bash
# Re-popular credentials se zero/missing
if [ ! -s /root/.claude/.credentials.json ]; then
  if [ -f /root/.claude/.credentials.json.bak ]; then
    cp /root/.claude/.credentials.json.bak /root/.claude/.credentials.json
  else
    # Refazer login OAuth interativamente
    claude setup-token
  fi
fi

# Tornar imutável
chattr +i /root/.claude/.credentials.json
lsattr /root/.claude/.credentials.json
```

**VALIDATION:** `lsattr` mostra `i` flag. `claude auth status` retorna `loggedIn: true`.

**REVERT:** `chattr -i /root/.claude/.credentials.json` antes de qualquer edit legítimo (rotação anual de token).

**ATENÇÃO crítica — 2 tokens distintos:** `setup-token` imprime um **long-lived OAuth token** (uso em env vars) e ao mesmo tempo persiste um **session credential** em `.credentials.json`. **Devem ser o mesmo valor.** Se divergirem, `claude auth status` retorna `loggedIn:true` mas chamadas reais retornam HTTP 401. Validação:

```bash
jq -r '.claudeAiOauth.accessToken[0:15]' /root/.claude/.credentials.json
# vs primeiros 15 chars do que setup-token imprimiu na tela
```

---

### Recipe F — RelayPlane desativado + baseUrl correto

**SYMPTOM:** `relayplane-proxy` ativo na porta 4100, ou `models.providers.anthropic.baseUrl == http://127.0.0.1:4100`.

**CAUSA RAIZ:** RelayPlane foi feature anterior, redundante com provider direto Anthropic. `npm install -g openclaw@<v>` pode reescrever baseUrl pro :4100 ativando RelayPlane silenciosamente.

**FIX:**
```bash
systemctl stop relayplane-proxy 2>/dev/null
systemctl disable relayplane-proxy 2>/dev/null
openclaw config set models.providers.anthropic.baseUrl https://api.anthropic.com
systemctl restart openclaw-gateway
```

**VALIDATION:**
```bash
jq '.models.providers.anthropic.baseUrl' /root/.openclaw/openclaw.json
# deve retornar "https://api.anthropic.com"
systemctl is-active relayplane-proxy  # deve retornar inactive
```

---

### Recipe G — Plugin Telegram MCP do Claude CLI duplicate poller (CAUSA REAL DE 80% DOS CRASHES PÓS-UPGRADE)

**SYMPTOM:** `[telegram] getUpdates conflict (409: Conflict: terminated by other getUpdates request)` recorrente. Workers `openclaw-channels` em 96% CPU. Slash commands lentos. WhatsApp/Telegram instáveis.

**CAUSA RAIZ:** plugin `telegram@claude-plugins-official` instalado em `~/.claude/plugins/cache/` e habilitado em `~/.claude/settings.json`. Cada subprocess Claude CLI disparado pelo gateway (porque `agentRuntime: claude-cli`) carrega esse plugin MCP, que faz **seu próprio polling** no Bot Telegram com o mesmo `TELEGRAM_BOT_TOKEN` herdado do env. Resultado: **N+1 pollers competindo**, Telegram API mata todos exceto um (409), retry-loop nos workers de canal.

Confirmação visual: `getWebhookInfo` do bot retorna `pending_update_count=0` e `last_error_date=null` — paradoxal, porque o duplicate poller é **efêmero** (vive só durante a session do subprocess).

**FIX:**
```bash
TS=$(date +%Y%m%d-%H%M%S)
cp /root/.claude/settings.json /root/.claude/settings.json.bak-pre-telegram-disable-$TS
jq '.enabledPlugins["telegram@claude-plugins-official"] = false' \
   /root/.claude/settings.json > /tmp/settings.new
mv /tmp/settings.new /root/.claude/settings.json
chmod 644 /root/.claude/settings.json

# Defesa em profundidade: remover MCP perms stale
jq '.permissions.allow = (.permissions.allow | map(select(. | test("mcp__plugin_telegram") | not)))' \
   /root/.claude/settings.json > /tmp/settings.new && mv /tmp/settings.new /root/.claude/settings.json

# Defesa em profundidade: remover preset legacy se existir
jq 'del(.channels)' /root/.claude/settings.json > /tmp/settings.new && mv /tmp/settings.new /root/.claude/settings.json

systemctl restart openclaw-gateway
```

**VALIDATION:** após 90s, `journalctl -u openclaw-gateway --since "90 seconds ago" | grep -cE "telegram.*conflict|409"` retorna 0.

**REVERT:** `cp /root/.claude/settings.json.bak-* /root/.claude/settings.json && systemctl restart openclaw-gateway`.

**Não afeta:**
- Plugin Telegram **nativo do gateway** (Grammy SDK) continua funcionando — é stack independente
- Claude Code do Mac/desktop local — fix é só no `~/.claude/settings.json` do user **root da VPS**

**Canary opcional (recomendado):**
```bash
cat > /root/.openclaw/scripts/canary-telegram-conflict.sh << 'SCRIPT'
#!/bin/bash
COUNT=$(journalctl -u openclaw-gateway --since "10 minutes ago" --no-pager 2>/dev/null \
  | grep -cE "telegram.*conflict|getUpdates conflict|409.*Conflict" || true)
logger -t canary-telegram-conflict "telegram-409-count=$COUNT"
if [ "$COUNT" -gt 2 ] && [ -f /root/.openclaw/.env ]; then
  WEBHOOK=$(grep "^DISCORD_WEBHOOK=" /root/.openclaw/.env | cut -d= -f2-)
  [ -n "$WEBHOOK" ] && curl -sS -X POST -H "Content-Type: application/json" \
    -d "{\"content\": \"🚨 Telegram 409 conflict: $COUNT em 10min\"}" "$WEBHOOK" > /dev/null
fi
SCRIPT
chmod +x /root/.openclaw/scripts/canary-telegram-conflict.sh
( crontab -l 2>/dev/null | grep -v canary-telegram-conflict; echo "*/5 * * * * /root/.openclaw/scripts/canary-telegram-conflict.sh" ) | crontab -
```

---

### Recipe H — Session DM scope per-channel-peer + hot-reload

**SYMPTOM:** mensagens de pessoas diferentes em DM (WhatsApp, Telegram, Slack, Discord) compartilhando contexto / sessão entre si.

**CAUSA RAIZ:** default `session.dmScope = "main"` faz todos DMs herdar mesma sessão. Pra isolamento por peer dentro do canal, usar `per-channel-peer`.

**FIX:**
```bash
openclaw config set session.dmScope per-channel-peer
openclaw config set gateway.reload.mode hot
systemctl restart openclaw-gateway
```

**VALIDATION:** `jq '.session, .gateway.reload' /root/.openclaw/openclaw.json` mostra `dmScope: per-channel-peer` e `reload: { mode: hot, debounceMs: 5000 }`.

**ATENÇÃO:** valores válidos de `gateway.reload.mode` são `[off, restart, hot, hybrid]` — `"watch"` é inválido (CLI rejeita silenciosamente, gateway fica em `off`). Validado empiricamente que `hot` é compatível com monkey-patch fratricide #62028.

---

### Recipe I — Delivery-queue cleanup (Unknown Channel spam)

**SYMPTOM:** logs com 15+ "Unknown Channel" + "recovery time budget exceeded" a cada restart.

**CAUSA RAIZ:** canais Discord/Telegram removidos do servidor deixam mensagens em `/root/.openclaw/delivery-queue/*.json`. Gateway tenta reentregar a cada restart.

**FIX:**
```bash
# Cleanup script (idempotente)
bash /root/.openclaw/workspace/tools/delivery-queue-cleanup.sh
# OU manual:
find /root/.openclaw/delivery-queue -name '*.json' -mtime +7 -delete
```

**VALIDATION:** `ls /root/.openclaw/delivery-queue/*.json 2>/dev/null | wc -l` baixa significativamente.

---

### Recipe J — Patch label OAuth Max (cosmético)

**SYMPTOM:** session_status mostra `🔑 token (anthropic:claude-cli)` confundindo user com cobrança ativa, mesmo rodando OAuth Max zero-cost.

**CAUSA RAIZ:** Plugin `session-status.runtime.js` renderiza `🔑 ${selectedAuthLabelValue}` literal. Label vem de `auth.profiles[anthropic:claude-cli].mode = "token"` que é nome do método de auth, **não custo**.

**FIX (script idempotente):**
```python
#!/usr/bin/env python3
import re, sys, glob
KEY = "\U0001F511"
SHIELD = "\U0001F6E1️"
SEP = " · "

def patch(path):
    with open(path, "r", encoding="utf-8") as f: c = f.read()
    if "OAuth (Max)" in c:
        print(f"SKIP: {path}"); return True
    o = c
    for var in ("selectedAuthLabelValue", "activeAuthLabelValue"):
        pat = rf"`{re.escape(SEP)}{re.escape(KEY)} \$\{{{var}\}}`"
        rep = (f'`{SEP}${{(typeof {var} === "string" && '
               f'{var}.includes("claude-cli")) ? '
               f'"{SHIELD} OAuth (Max)" : '
               f'"{KEY} " + {var}}}`')
        c = re.sub(pat, rep, c)
    if c == o: return False
    with open(path, "w", encoding="utf-8") as f: f.write(c)
    return True

for path in glob.glob("/root/.openclaw/plugin-runtime-deps/openclaw-*/dist/status-message-*.js"):
    import os
    os.system(f"chattr -i {path} 2>/dev/null")
    if patch(path):
        os.system(f"chattr +i {path}")
        print(f"OK: {path}")
```

Salvar como `/root/reapply-session-status-emoji-patch.py`, `chmod +x`, rodar. Restart gateway.

**INVARIANTE:** mesmo trigger de invalidação da Recipe D — reaplicar após `npm install -g openclaw` ou `openclaw models auth login`.

**VALIDATION:** `grep -c "OAuth (Max)" /root/.openclaw/plugin-runtime-deps/openclaw-*/dist/status-message-*.js` retorna 2 por arquivo.

---

### Recipe K — Cleanup plugin-runtime-deps stale

**SYMPTOM:** disco em `/root` com múltiplos `openclaw-2026.4.X-*` consumindo dezenas de GB.

**CAUSA RAIZ:** `npm install -g openclaw@<v>` deixa versões antigas em `/root/.openclaw/plugin-runtime-deps/`. Não limpa automaticamente.

**FIX (cauteloso):**
```bash
# 1. Identificar dir ATIVO (atime mais recente)
for D in /root/.openclaw/plugin-runtime-deps/openclaw-*; do
  echo "$(stat -c '%x' $D) $D"
done | sort -r | head -3

# 2. Verificar inotify por 30s (quem está usando)
timeout 30 inotifywait -m -r /root/.openclaw/plugin-runtime-deps -e access,open 2>&1 | head -20

# 3. Pra dirs OBVIAMENTE stale (versão != atual + atime > 24h):
mkdir -p /root/.openclaw/_trash
mv /root/.openclaw/plugin-runtime-deps/openclaw-OLD-VERSION /root/.openclaw/_trash/

# 4. Aguardar 5min, validar gateway healthy
sleep 300
journalctl -u openclaw-gateway --since "5 minutes ago" | grep -iE "ENOENT|Cannot find module" | head -5

# 5. Se OK, hard delete
chattr -i /root/.openclaw/_trash/<dir>/dist/*.js 2>/dev/null
rm -rf /root/.openclaw/_trash/openclaw-OLD-VERSION
```

**ATENÇÃO:** se Recipe J (label OAuth patch) foi aplicada com `chattr +i`, precisa `chattr -i` antes do `rm -rf`. Senão `Operation not permitted`.

---

### Recipe L — Sessions.json grudado em fallback model

**SYMPTOM:** mesmo após Recipe B+C, agente continua usando gemini/codex em vez de claude.

**CAUSA RAIZ:** gateway persiste em `agents/<id>/sessions/sessions.json` o model do último turn bem-sucedido. Se claude-cli falhou uma vez antes, sessão "gruda".

**FIX:**
```bash
for agent in $(jq -r '.agents.list[].id' /root/.openclaw/openclaw.json); do
  SESS=/root/.openclaw/agents/$agent/sessions/sessions.json
  if [ -f "$SESS" ]; then
    cp "$SESS" "$SESS.bak-$(date +%Y%m%d-%H%M%S)"
    jq 'with_entries(select(.value.model | tostring | startswith("claude-")))' "$SESS" > "$SESS.tmp" && mv "$SESS.tmp" "$SESS"
    echo "reset: $agent"
  fi
done
systemctl restart openclaw-gateway
```

**VALIDATION:** próximos turns nos canais devem voltar pra claude-sonnet-4-6.

---

## Phase 5 — Validação final pós-fix (5 invariants)

```bash
ssh root@<vps-ip> << 'EOF'
PASS=0; FAIL=0
check() { if eval "$2"; then echo "✅ $1"; PASS=$((PASS+1)); else echo "❌ $1"; FAIL=$((FAIL+1)); fi; }

check "model.primary é anthropic/<model>" '[ "$(jq -r .agents.defaults.model.primary /root/.openclaw/openclaw.json)" != null ] && jq -r .agents.defaults.model.primary /root/.openclaw/openclaw.json | grep -q "^anthropic/"'
check "anthropic.baseUrl == api.anthropic.com" 'jq -r .models.providers.anthropic.baseUrl /root/.openclaw/openclaw.json | grep -q "^https://api.anthropic.com$"'
check "RelayPlane inactive+disabled" '! systemctl is-active --quiet relayplane-proxy 2>/dev/null'
check "fallback chain sem anthropic-max" '! jq -r ".agents.defaults.model.fallbacks // [] | join(\",\")" /root/.openclaw/openclaw.json | grep -q anthropic-max'
check "gateway active + NRestarts=0" 'systemctl is-active --quiet openclaw-gateway && [ "$(systemctl show -p NRestarts --value openclaw-gateway)" = "0" ]'
check "monkey-patch fratricide aplicado" 'grep -q "MONKEY-PATCH.*62028\|return \[\];" /usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js'
check "telegram plugin desabilitado" '[ "$(jq -r ".enabledPlugins[\"telegram@claude-plugins-official\"]" /root/.claude/settings.json)" = "false" ]'
check "credentials.json imutável" 'lsattr /root/.claude/.credentials.json 2>/dev/null | grep -q "^----i"'
check "session.dmScope per-channel-peer" '[ "$(jq -r .session.dmScope /root/.openclaw/openclaw.json)" = "per-channel-peer" ]'
check "zero anthropic API calls última hora" '[ "$(journalctl -u openclaw-gateway --since "1 hour ago" --no-pager 2>/dev/null | grep -c "api.anthropic.com")" = "0" ]'

echo
echo "Total: $PASS passou, $FAIL falhou"
EOF
```

Resultado esperado: 10 ✅, 0 ❌.

---

## Decision Tree resumido (cole pro Claude se quiser priorização rápida)

```
Phase 0 mostrou:
├── monkey-patch missing → Recipe D (URGENTE — gateway pode crashar a qualquer restart)
├── NRestarts > 0 → Recipe D (mesmo)
├── api.anthropic.com calls > 0 → Recipe B + Recipe C (custo ATIVO)
├── telegram conflict > 0 → Recipe G (instabilidade)
├── credentials.json sem chattr +i → Recipe E
├── relayplane:4100 ativo → Recipe F
├── dmScope=main → Recipe H
├── plugin-runtime-deps > 5 dirs → Recipe K (housekeeping)
└── label "🔑 token" no display → Recipe J (cosmético)
```

Ordem de severidade: **D > B > G > E > F > C > H > L > K > J**.

---

## Aprendizados não-óbvios que custaram horas pra descobrir

1. **Plugin MCP do Claude CLI ≠ plugin nativo do OpenClaw gateway.** Eles são stacks separados. Disable do MCP plugin não afeta canal nativo.
2. **`getWebhookInfo` mostra estado limpo entre conflicts** porque duplicate poller é efêmero (subprocess CLI). Não confiar em snapshots da API Telegram.
3. **`gateway.reload.mode = "watch"` é INVÁLIDO** — gateway aceita silenciosamente, volta pra `off`. Valores válidos: `[off, restart, hot, hybrid]`. Confirme via `openclaw config set gateway.reload.mode hot` (CLI valida).
4. **Editar `openclaw.json` com `jq` + `mv` NÃO aplica em runtime** — gateway tem in-memory canonical state que sobrescreve no startup. Usar `openclaw config set` (CLI oficial) que escreve no canonical state. **Restart depois pra aplicar.**
5. **Setar `commands.restart=false` na regra antiga é desnecessário** — monkey-patch protege independente desse valor. `mode=hot` também é seguro.
6. **2 tokens distintos no Claude CLI Max** (env-var vs credentials.json) podem divergir silenciosamente; `claude auth status` retorna `loggedIn:true` mas chamadas reais retornam 401. Sempre validar com prefix match.
7. **`.credentials.json` trunca ciclicamente sem TTY** — `chattr +i` é mandatório, não opcional.
8. **`agents.list[]` é array, não objeto.** Per-agent override fica em `agents.list[<INDEX>].model.primary`, não `agents.<id>.model`.
9. **`gpt-5.5` no runtime catalog ≠ config registry.** `openclaw config get models.providers.openai-codex.models` mostra só gpt-5.4, mas `openclaw models list | grep gpt-5.5` confirma "configured" via Codex catalog dinâmico.
10. **Sessions stickiness** — fallback model gruda em `sessions.json`; reset com `jq with_entries(select(...startswith("claude-")))`.

---

## Backup checklist (antes de QUALQUER fix)

```bash
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p /root/.openclaw/backups/recovery-$TS
cp /root/.openclaw/openclaw.json /root/.openclaw/backups/recovery-$TS/
cp /root/.openclaw/.env /root/.openclaw/backups/recovery-$TS/
cp /root/.claude/settings.json /root/.openclaw/backups/recovery-$TS/ 2>/dev/null
cp /root/.claude/.credentials.json /root/.openclaw/backups/recovery-$TS/ 2>/dev/null
ls /usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js | xargs -I{} cp {} /root/.openclaw/backups/recovery-$TS/
echo "backups em: /root/.openclaw/backups/recovery-$TS/"
```

---

## Suporte / atualização do guide

Esse guide foi compilado a partir de uma sessão real de troubleshooting OpenClaw v2026.4.29 em 2026-05-01. Versões e patches podem mudar. Se OpenClaw shipar v2026.4.30+ que corrija fratricide nativamente, Recipes D e J ficam obsoletas.

**Antes de aplicar Recipes:** confirme versão atual com `openclaw --version` e ajuste comandos se necessário.

**Última atualização:** 2026-05-01

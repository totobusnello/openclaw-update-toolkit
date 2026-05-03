# Lesson — Claude CLI plugin MCP gera duplicate poller no Bot Telegram

**Data:** 2026-05-01
**Detectado em:** sessão de troubleshooting com Toto, ~14:00-15:25 BRT
**Severidade:** alta (instabilidade recorrente, slash commands quebrados, zumbis 96% CPU)
**Status:** resolvido. Causa raiz tratada. Cross-reference com incident similar de 2026-03-31.

---

## TL;DR

`/root/.claude/settings.json` no user root da VPS tinha `enabledPlugins.telegram@claude-plugins-official: true`. Cada subprocess `claude` disparado pelo gateway (`agentRuntime: claude-cli`) herdava `~/.claude/` e o env, carregava o plugin MCP Telegram, iniciava **seu próprio polling** no `getUpdates` do mesmo bot — **competindo com o gateway nativo** que também faz polling via Grammy SDK.

Resultado: 409 conflict na Telegram API, retry-loop nos workers `openclaw-channels`, 96% CPU, travamento de slash commands.

---

## Como detectar (sintomas observáveis)

1. **Journal:** `journalctl -u openclaw-gateway | grep "telegram.*conflict\|409.*getUpdates"` retornando entries clusterizadas em janelas de minutos.
2. **CPU/process:** `ps -ef | grep openclaw-channels` mostrando processos travados em alto CPU.
3. **getWebhookInfo paradoxal:** `curl https://api.telegram.org/bot<TOKEN>/getWebhookInfo` mostra `pending_update_count=0` e `last_error_date=null` — porque o duplicate poller é **efêmero** (vive só durante o subprocess Claude CLI da session ativa) e o estado do bot na Telegram API "estabiliza" entre conflitos.
4. **Slash commands no Discord falhando** sem erro óbvio (porque worker travou).

---

## Como diagnosticar (de leve a profundo)

### Nível 1 — config check
```bash
ssh root@<REDACTED-TAILSCALE-IP> 'jq ".enabledPlugins" /root/.claude/settings.json'
```
Se aparecer `"telegram@claude-plugins-official": true`, está vulnerável.

### Nível 2 — confirmação por correlação temporal
```bash
journalctl -u openclaw-gateway --since "7 days ago" | grep -E "claude live session|telegram.*conflict|409"
```
Conflits surgem **minutos depois** de cada `claude live session start` (porque o subprocess claude inicializa o plugin durante boot da session).

### Nível 3 — bash_history
```bash
grep -iE "telegram|tmux.*bot" /root/.bash_history
```
Se mostrar `claude --channels 'plugin:telegram@...'` ou `tmux new -s telegram-bot`, é evidência forte que Toto (ou agente) ativou o plugin manualmente em algum momento.

### Nível 4 — TCP sockets ativos
```bash
ss -tnp | grep "149.154.166\|95.161"
```
Se aparecer **mais de uma** ESTAB pra IPs da Telegram API (range 149.154.x.x ou 95.161.x.x), tem polling duplicado em curso.

---

## Como corrigir

```bash
ssh root@<REDACTED-TAILSCALE-IP> << 'EOF'
TS=$(date +%Y%m%d-%H%M%S)
cp /root/.claude/settings.json /root/.claude/settings.json.bak-pre-telegram-disable-$TS
jq '.enabledPlugins["telegram@claude-plugins-official"] = false' \
   /root/.claude/settings.json > /tmp/settings.new
mv /tmp/settings.new /root/.claude/settings.json
chmod 644 /root/.claude/settings.json
systemctl restart openclaw-gateway
EOF
```

Validação pós-fix (esperar 90s):
```bash
journalctl -u openclaw-gateway --since "90 seconds ago" | grep -iE "telegram.*(conflict|409)"
# resultado esperado: vazio
```

---

## Como prevenir

### 1. Audit de plugins MCP no Claude CLI
Sempre que instalar plugin novo via `claude plugin install <name>`, verificar:
- Plugin abre conexão de longo prazo? (polling, websocket, listener)
- Plugin lê `TELEGRAM_BOT_TOKEN`, `SLACK_TOKEN`, `DISCORD_TOKEN`, `WHATSAPP_*`?
- Plugin é singleton (só um poller pode existir por token)?

Se sim em qualquer um, **NÃO habilitar** em `enabledPlugins` no `~/.claude/settings.json` da VPS — o gateway OpenClaw já cobre esses canais nativamente.

### 2. Canary específico (a criar)
Sugestão: cron `*/5 * * * *` rodando:
```bash
journalctl -u openclaw-gateway --since "10 minutes ago" \
  | grep -c "telegram.*conflict\|getUpdates conflict\|409.*Conflict" \
  > /tmp/telegram-conflict-count
```
Alertar Discord se contagem > 2 em 10min.

### 3. Documentar no CLAUDE.md (regra futura)
Adicionar na seção "Regras críticas" do `infra/CLAUDE.md`:
> **Plugins MCP no `~/.claude/settings.json` do root da VPS:** auditar antes de habilitar. Plugins que abrem polling em canais (telegram, slack, discord, whatsapp) **NÃO podem** ser habilitados — o gateway OpenClaw já faz polling nativo. Habilitar gera 409 conflicts e retry-loop nos workers de canal.

---

## Cross-references

- **Incident 2026-03-31** (em `INCIDENTS.md`): mesmo sintoma `getUpdates conflict 409`, fonte diferente — `claude-telegram.service` + `claude-tg-watchdog.sh` (services systemd que faziam polling independente). Foram desabilitados na época. **Esta é a terceira vez** que esse sintoma surge na plataforma — vale tratar como pattern conhecido.
- **Incident 2026-05-01** (este): plugin MCP do Claude CLI fazendo polling herdado.

---

## Referências de código

- Plugin: `/root/.claude/plugins/cache/claude-plugins-official/telegram/0.0.6/server.ts`
- Marketplace install path: `/root/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/`
- Settings flag: `/root/.claude/settings.json` → `enabledPlugins["telegram@claude-plugins-official"]`
- Gateway native poller (Grammy): `/root/.openclaw/plugin-runtime-deps/openclaw-2026.4.29-*/dist/extensions/telegram/`

## Backups gerados nesta sessão

```
/root/.claude/settings.json.bak-pre-telegram-disable-20260501-151928
/root/.claude/settings.json.bak-pre-perm-cleanup-20260501-*
/root/.claude/settings.json.bak-pre-channels-cleanup-20260501-*
/root/.openclaw/.env.bak-pre-killswitch-20260501-150721
/root/.openclaw/openclaw.json.bak-pre-killswitch-20260501-150721
/root/.openclaw/openclaw.json.bak-pre-dmscope-20260501-*
/root/.openclaw/plugin-runtime-deps/openclaw-2026.4.29-*/dist/status-message-Bwz2ekKl.js.bak-pre-emoji-patch-20260501-155028
/root/.openclaw/archive/clobbered-2026-04/  (14 fósseis arquivados)
/root/.openclaw/archive/env-backups/  (4 .env.bak antigos pré-Apr 21)
```

## Acompanhou no mesmo encerramento

- **Audit de plugins MCP em ~/.claude/settings.json:** confirmado nenhum outro plugin com listener concorrente além do telegram (já desabilitado). `claude-code-setup` é helper safe.
- **`session.dmScope: "per-channel-peer"`:** aplicado via `openclaw config set` (default era `"main"` — leak de contexto entre peers em DMs WhatsApp/Telegram/Discord/Slack).
- **`gateway.reload.mode: "hot"`:** valor `"watch"` que tentei era inválido (CLI rejeita); valores válidos são `[off, restart, hot, hybrid]`. Depois do fix correto, gateway detecta config inválido + auto-restaura last-known-good.
- **Patch label `🔑 token` → `🛡️ OAuth (Max)`:** aplicado em `status-message-Bwz2ekKl.js` + `chattr +i`. Reapply script: `infra/scripts/reapply-session-status-emoji-patch.py`. Adicionada como **regra 2.1** no `infra/CLAUDE.md` — invariante adicional pós-upgrade ao lado do monkey-patch fratricide #62028.
- **Canary `*/5min`** instalado (`canary-telegram-conflict.sh`): conta 409 conflicts em janela de 10min, alerta Discord se >2.

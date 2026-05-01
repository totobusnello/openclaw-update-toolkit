# Lesson 2026-05-01 — Plugin MCP do Claude CLI gera duplicate poller no Bot Telegram

**Data:** 2026-05-01
**Severidade:** alta (instabilidade recorrente, slash commands quebrados, workers em 96% CPU)
**Status:** resolvido. Causa raiz tratada. Implementada Recipe G + canary de detecção.

---

## TL;DR

`/root/.claude/settings.json` no user root da VPS tinha `enabledPlugins["telegram@claude-plugins-official"]: true`. Cada subprocess `claude` disparado pelo gateway (com `agentRuntime: claude-cli`) herdava `~/.claude/` e o env, carregava o plugin MCP Telegram, iniciava **seu próprio polling** no `getUpdates` do mesmo bot — competindo com o gateway nativo que também faz polling via Grammy SDK.

Resultado: 409 conflict na Telegram API, retry-loop nos workers `openclaw-channels`, 96% CPU, travamento de slash commands.

---

## Como detectar

1. **Journal:** `journalctl -u openclaw-gateway | grep "telegram.*conflict\|409.*getUpdates"` retornando entries clusterizadas em janelas de minutos.
2. **CPU/process:** `ps -ef | grep openclaw-channels` mostrando processos travados em alto CPU.
3. **getWebhookInfo paradoxal:** `curl https://api.telegram.org/bot<TOKEN>/getWebhookInfo` mostra `pending_update_count=0` e `last_error_date=null` — porque o duplicate poller é **efêmero** (vive só durante o subprocess Claude CLI da session ativa).
4. **Slash commands no Discord falhando** sem erro óbvio (porque worker travou).

## Como diagnosticar (de leve a profundo)

### Nível 1 — config check
```bash
ssh root@<vps>
jq ".enabledPlugins" /root/.claude/settings.json
```
Se aparecer `"telegram@claude-plugins-official": true`, está vulnerável.

### Nível 2 — confirmação por correlação temporal
```bash
journalctl -u openclaw-gateway --since "7 days ago" | grep -E "claude live session|telegram.*conflict|409"
```
Conflits surgem **minutos depois** de cada `claude live session start` (porque o subprocess inicializa o plugin durante boot da session).

### Nível 3 — TCP sockets ativos
```bash
ss -tnp | grep "149.154.166\|95.161"
```
Se aparecer **mais de uma** ESTAB pra IPs da Telegram API (range 149.154.x.x ou 95.161.x.x), tem polling duplicado em curso.

## Como corrigir

Recipe G no toolkit. Comando direto:
```bash
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/disable-telegram-mcp.sh | sudo bash
```

## Como prevenir

### Audit de plugins MCP no Claude CLI
Sempre que instalar plugin novo via `claude plugin install <name>`, verificar:
- Plugin abre conexão de longo prazo? (polling, websocket, listener)
- Plugin lê `TELEGRAM_BOT_TOKEN`, `SLACK_TOKEN`, `DISCORD_TOKEN`, etc?
- Plugin é singleton (só um poller pode existir por token)?

Se sim em qualquer um, **NÃO habilitar** em `enabledPlugins` no `~/.claude/settings.json` da VPS — o gateway OpenClaw já cobre esses canais nativamente.

### Canary específico
Recipe G inclui (opt-in) canary `*/5min` que monitora 409 conflicts e alerta Discord se >2 em 10min.

---

## Cross-references

- **Incident histórico (Mar/2026):** mesmo sintoma `getUpdates conflict 409`, fonte diferente — `claude-telegram.service` + `claude-tg-watchdog.sh` (services systemd que faziam polling independente). Foram desabilitados na época.
- **Esta é (pelo menos) a 3ª vez** que esse sintoma surge na plataforma — vale tratar como pattern conhecido.

---

## Aprendizados gerais

1. **Plugin MCP do Claude CLI ≠ plugin nativo do OpenClaw gateway.** São stacks separados. Disable do MCP plugin não afeta canal nativo.
2. **`getWebhookInfo` mostra estado limpo entre conflicts** porque duplicate poller é efêmero (subprocess CLI). Não confiar em snapshots da API Telegram.
3. **Forge-style "fix sintoma sem ver causa":** primeiros fixes (matar processos zumbis CPU 96%) só removiam efeito; causa estava no plugin habilitado. Sempre buscar quem CRIA o sintoma, não só quem mostra.

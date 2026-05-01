# Recipe G — Disable plugin Telegram MCP do Claude CLI

**SEVERIDADE:** 🔴 ALTA — workers em retry-loop CPU 96%, instabilidade ativa

**SYMPTOM:**
- `[telegram] getUpdates conflict (409: Conflict: terminated by other getUpdates request)` recorrente
- Workers `openclaw-channels` em 96% CPU
- Slash commands lentos
- WhatsApp/Telegram instáveis
- `getWebhookInfo` paradoxalmente mostra estado limpo (sem erros recentes)

**CAUSA RAIZ:**
Plugin `telegram@claude-plugins-official` instalado em `~/.claude/plugins/cache/` e **habilitado** em `~/.claude/settings.json` do user root. Cada subprocess Claude CLI disparado pelo gateway (porque `agentRuntime: claude-cli`) carrega esse plugin MCP, que faz **seu próprio polling** no Bot Telegram com o mesmo `TELEGRAM_BOT_TOKEN` herdado do env.

**Resultado:** N+1 pollers competindo pelo mesmo token → Telegram API mata todos exceto um (409 Conflict) → retry-loop nos workers de canal → 96% CPU → travamento de slash commands.

Por que o `getWebhookInfo` mostra "OK"? Porque o duplicate poller é **efêmero** (vive só durante a session do subprocess CLI). Entre conflicts a Telegram API estabiliza.

**FIX:**
```bash
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/disable-telegram-mcp.sh | sudo bash
```

**VALIDATION:**
```bash
# Após 90s, validar zero conflicts:
sleep 90 && journalctl -u openclaw-gateway --since "90 seconds ago" --no-pager | grep -cE "telegram.*conflict|409.*Conflict"
# Esperado: 0
```

**REVERT:**
```bash
ls -1t /root/.claude/settings.json.bak-pre-telegram-disable-* | head -1 | xargs -I{} cp {} /root/.claude/settings.json
systemctl restart openclaw-gateway
```

**Não afeta:**
- Plugin Telegram **nativo do gateway** (Grammy SDK) continua funcionando — é stack independente
- Claude Code do Mac/desktop local — fix é só no `~/.claude/settings.json` do user **root da VPS**

**Bonus — canary opcional:** o script de fix oferece instalar canary `*/5min` que detecta retorno do mesmo padrão e alerta Discord se >2 conflicts em 10min.

Ver detalhes completos em [`docs/recovery-guide.md`](../docs/recovery-guide.md#recipe-g--plugin-telegram-mcp-do-claude-cli-duplicate-poller-causa-real-de-80-dos-crashes-pós-upgrade).

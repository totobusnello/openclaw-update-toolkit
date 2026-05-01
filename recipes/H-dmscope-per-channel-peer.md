# Recipe H — Session DM scope per-channel-peer

**SEVERIDADE:** 🟡 MÉDIA

**SYMPTOM:**
- Mensagens de pessoas diferentes em DM (WhatsApp, Telegram, Slack, Discord) compartilhando contexto entre si
- Agente "lembra" de coisa que outra pessoa falou em DM separada

**CAUSA RAIZ:**
Default `session.dmScope = "main"` faz todos DMs herdar mesma sessão (vazamento de contexto). Pra isolamento por peer dentro do canal, usar `per-channel-peer`. Outros valores: `per-peer` (mais isolado), `per-account-channel-peer` (multi-account).

**FIX:**
```bash
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/dmscope-fix.sh | sudo bash
```

**VALIDATION:**
```bash
jq '.session, .gateway.reload' /root/.openclaw/openclaw.json
# Esperado: { "dmScope": "per-channel-peer" } e reload.mode = "hot"
```

**REVERT:**
```bash
openclaw config set session.dmScope main
systemctl restart openclaw-gateway
```

**Bonus:** o script de fix também seta `gateway.reload.mode=hot` (descobrimos que o valor `"watch"` documentado em fontes antigas é INVÁLIDO — gateway aceita silenciosamente e volta pra `off`). Valores válidos: `[off, restart, hot, hybrid]`. `hot` é compatível com monkey-patch fratricide.

Ver detalhes em [`docs/recovery-guide.md`](../docs/recovery-guide.md#recipe-h--session-dm-scope-per-channel-peer--hot-reload).

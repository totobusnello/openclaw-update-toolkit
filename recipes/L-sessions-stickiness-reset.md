# Recipe L — Reset sessions.json grudado em fallback model

**SEVERIDADE:** 🟡 MÉDIA

**SYMPTOM:**
- Mesmo após Recipe B+C, agente continua usando gemini/codex em vez de claude
- Canais específicos "grudaram" em fallback

**CAUSA RAIZ:**
Gateway persiste em `agents/<id>/sessions/sessions.json` o model do último turn bem-sucedido por canal/session. Se claude-cli falhou uma vez antes, sessão fica grudada nesse fallback.

**FIX:**
```bash
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/reset-sessions.sh | sudo bash
```

Filtra apenas sessions cujo model começa com `claude-` (mantém válidas, descarta grudadas em fallback).

**VALIDATION:**
Próximos turns nos canais devem voltar pra `claude-sonnet-4-6`. Verificar:
```bash
journalctl -u openclaw-gateway --since "1 minute ago" | grep -E "model=(claude|gemini|gpt)"
```

**REVERT:**
```bash
for agent in $(jq -r '.agents.list[].id' /root/.openclaw/openclaw.json); do
  ls -1t /root/.openclaw/agents/$agent/sessions/sessions.json.bak-* 2>/dev/null | head -1 | xargs -I{} cp {} /root/.openclaw/agents/$agent/sessions/sessions.json
done
systemctl restart openclaw-gateway
```

Ver detalhes em [`docs/recovery-guide.md`](../docs/recovery-guide.md#recipe-l--sessionsjson-grudado-em-fallback-model).

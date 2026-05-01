# Recipe B — Kill switch anti-cobrança Anthropic

**SEVERIDADE:** 🔴 ALTA — custo ATIVO agora, sangramento financeiro

**SYMPTOM:**
- Custos inesperados na Anthropic API
- Diagnostic mostra `provider=anthropic` em vez de `provider=claude-cli`
- `journalctl | grep "api.anthropic.com"` retorna count > 0

**CAUSA RAIZ:**
Agentes configurados com `agentRuntime: { id: "pi" }` (default) usam profile `anthropic:default` (mode=token, API key paga). Solução: forçar todos pra `claude-cli` que usa OAuth Max via subprocess local (zero custo, mesmo modelo Claude Sonnet 4.6).

**FIX:**
```bash
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/kill-switch-cost.sh | sudo bash
```

**VALIDATION:**
```bash
journalctl -u openclaw-gateway --since "30 seconds ago" | grep "provider=claude-cli"
# Esperado: aparecer linha confirmando provider=claude-cli
journalctl -u openclaw-gateway --since "30 seconds ago" | grep -c "api.anthropic.com"
# Esperado: 0 (zero requests)
```

**REVERT:**
```bash
# Restaurar backup do openclaw.json
ls -1t /root/.openclaw/openclaw.json.bak-pre-runtime-fix-* | head -1 | xargs -I{} cp {} /root/.openclaw/openclaw.json
systemctl restart openclaw-gateway
```

**ATENÇÃO:** Se `ANTHROPIC_API_KEY` ou `ANTHROPIC_MAX_API_KEY` estiverem no `.env`, **NÃO comente as linhas** — o plugin runtime do provider `anthropic-max` exige a var no startup mesmo sem uso. Comentar quebra startup com `SecretRefResolutionError`. **Kill switch real é a config dos agentes, não env var.**

Ver detalhes completos em [`docs/recovery-guide.md`](../docs/recovery-guide.md#recipe-b--kill-switch-anti-cobrança-anthropic).

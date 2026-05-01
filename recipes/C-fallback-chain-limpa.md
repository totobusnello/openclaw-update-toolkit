# Recipe C — Fallback chain sem providers pagos

**SEVERIDADE:** 🟡 MÉDIA

**SYMPTOM:**
- Mesmo com claude-cli ativo, custos aparecem ocasionalmente
- Fallback grudado em modelo pago em alguns canais

**CAUSA RAIZ:**
`agents.defaults.model.fallbacks` apontando pra Anthropic (`anthropic/*`) ou outro provider pago como primeiro fallback. Quando claude-cli falha uma vez, sessão "gruda" no fallback (sticky session — ver Recipe L pra reset).

**Chain canônica recomendada:**
```yaml
primary: anthropic/claude-sonnet-4-6      # Max OAuth, $0
fallbacks:
  - openai-codex/gpt-5.5                  # OAuth Codex, $0
  - gemini/gemini-2.5-pro                 # API key barata, último recurso
```

**FIX:**
```bash
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/clean-fallback-chain.sh | sudo bash
```

**VALIDATION:**
```bash
jq '.agents.defaults.model.fallbacks' /root/.openclaw/openclaw.json
# Esperado: ["openai-codex/gpt-5.5", "gemini/gemini-2.5-pro"]
```

**REVERT:**
```bash
ls -1t /root/.openclaw/openclaw.json.bak-pre-fallback-fix-* | head -1 | xargs -I{} cp {} /root/.openclaw/openclaw.json
systemctl restart openclaw-gateway
```

Ver detalhes em [`docs/recovery-guide.md`](../docs/recovery-guide.md#recipe-c--fallback-chain-limpa).

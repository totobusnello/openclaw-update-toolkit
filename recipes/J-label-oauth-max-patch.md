# Recipe J — Patch label OAuth Max (cosmético)

**SEVERIDADE:** 🟢 BAIXA / COSMÉTICA

**SYMPTOM:**
- `session_status` mostra `🔑 token (anthropic:claude-cli)` confundindo usuário com cobrança ativa
- Mesmo rodando OAuth Max zero-cost, label parece API paga

**CAUSA RAIZ:**
Plugin `session-status.runtime.js` renderiza `🔑 ${selectedAuthLabelValue}` literal. Label vem de `auth.profiles[anthropic:claude-cli].mode = "token"` que é nome do método de auth, **não custo**.

**FIX:**
```bash
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/reapply-emoji-patch.py | sudo python3
```

Patch local idempotente. Aplica em todos `status-message-*.js` matched + `chattr +i` pra resistir upgrades.

**VALIDATION:**
```bash
grep -c "OAuth (Max)" /root/.openclaw/plugin-runtime-deps/openclaw-*/dist/status-message-*.js
# Esperado: 2 por arquivo
```

**REVERT:**
```bash
for F in /root/.openclaw/plugin-runtime-deps/openclaw-*/dist/status-message-*.js; do
  chattr -i "$F" 2>/dev/null
  ls -1t "$F.bak-pre-emoji-patch-"* 2>/dev/null | head -1 | xargs -I{} cp {} "$F"
done
systemctl restart openclaw-gateway
```

**INVARIANTE pós-upgrade:** mesmo trigger da Recipe D — reaplicar após `npm install -g openclaw` ou `openclaw models auth login`. O script é idempotente, só executa se label original estiver presente.

Ver detalhes em [`docs/recovery-guide.md`](../docs/recovery-guide.md#recipe-j--patch-label-oauth-max-cosmético).

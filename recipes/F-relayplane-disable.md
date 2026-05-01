# Recipe F — RelayPlane desativado + baseUrl correto

**SEVERIDADE:** 🟡 MÉDIA

**SYMPTOM:**
- `relayplane-proxy` ativo na porta 4100
- `models.providers.anthropic.baseUrl == http://127.0.0.1:4100`

**CAUSA RAIZ:**
RelayPlane foi feature anterior, redundante com provider direto Anthropic. `npm install -g openclaw@<v>` pode reescrever `baseUrl` pro `:4100` ativando RelayPlane silenciosamente.

**FIX:**
```bash
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/relayplane-disable.sh | sudo bash
```

**VALIDATION:**
```bash
jq '.models.providers.anthropic.baseUrl' /root/.openclaw/openclaw.json
# Esperado: "https://api.anthropic.com"
systemctl is-active relayplane-proxy
# Esperado: inactive (ou unit ausente)
```

**REVERT:** desnecessário (RelayPlane é redundante, não tem benefício real).

Ver detalhes em [`docs/recovery-guide.md`](../docs/recovery-guide.md#recipe-f--relayplane-desativado--baseurl-correto).

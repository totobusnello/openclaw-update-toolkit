# Recipe E — chattr +i em `.credentials.json` do Claude CLI

**SEVERIDADE:** 🔴 ALTA — auth quebra em horas sem isso

**SYMPTOM:**
- Após algumas horas, agents falham com "Not logged in" / HTTP 401
- Diagnostic seção H mostra `chattr +i AUSENTE` ou arquivo zero/missing

**CAUSA RAIZ:**
Claude CLI quando spawned como subprocess sem TTY em condição de erro faz "self-fix" zerando `~/.claude/.credentials.json`. Próximo turn falha autenticação — gateway perde acesso ao OAuth Max e cai em fallback (modelo pago) ou simplesmente erro.

**Mitigação obrigatória:** `chattr +i` no arquivo após popular. Pra atualizar legitimamente no futuro (rotação anual de token): `chattr -i` → edit → `chattr +i`.

**FIX:**
```bash
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/chattr-credentials.sh | sudo bash
```

Se o arquivo está zerado/missing, o script tenta restaurar de `.credentials.json.bak`. Se também não existir, o script para e pede `claude setup-token` interativo.

**VALIDATION:**
```bash
lsattr /root/.claude/.credentials.json
# Esperado: ----i---------e-------
claude auth status
# Esperado: loggedIn: true
```

**ATENÇÃO crítica — 2 tokens distintos:**

`claude setup-token` imprime na tela um **long-lived OAuth token** (uso em env vars/API externa) e ao mesmo tempo persiste um **session credential** em `.credentials.json` pro uso local do subprocess. **Devem ser o mesmo valor.** Se divergirem (por restore antigo, edit manual inconsistente), `claude auth status` retorna `loggedIn:true` (usando env var) mas chamadas reais retornam HTTP 401.

Validação rigorosa:
```bash
jq -r '.claudeAiOauth.accessToken[0:15]' /root/.claude/.credentials.json
# Deve bater com os primeiros 15 chars do que setup-token imprimiu na tela
```

**REVERT:**
```bash
chattr -i /root/.claude/.credentials.json
# (se quiser apagar: rm /root/.claude/.credentials.json — perde auth atual!)
```

Ver detalhes em [`docs/recovery-guide.md`](../docs/recovery-guide.md#recipe-e--credentialsjson-claude-cli-imutável).

# Recipe K — Cleanup plugin-runtime-deps stale

**SEVERIDADE:** 🟢 BAIXA / HOUSEKEEPING

**SYMPTOM:**
- `/root` com múltiplos `openclaw-2026.4.X-*` consumindo dezenas de GB
- Diagnostic mostra > 3 dirs em `plugin-runtime-deps/`

**CAUSA RAIZ:**
`npm install -g openclaw@<v>` deixa versões antigas em `/root/.openclaw/plugin-runtime-deps/`. Não limpa automaticamente.

**FIX (cauteloso, com observação inotify primeiro):**
```bash
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/cleanup-plugin-runtime-deps.sh | sudo bash
```

O script:
1. Identifica dir ATIVO (atime mais recente)
2. Roda inotify watch 30s nos dirs antigos pra confirmar inertes
3. Move dirs candidatos pra `/root/.openclaw/_trash/` (reversível)
4. Aguarda 5min validando gateway healthy
5. Hard delete só após confirmação

**VALIDATION:**
```bash
ls /root/.openclaw/plugin-runtime-deps/
# Esperado: 1-2 dirs (versão atual + 1 anterior pra fallback rápido)
df -h /root | tail -1
# Espaço recuperado
```

**REVERT:**
Antes do hard delete, dir ainda está em `/root/.openclaw/_trash/` — pode ser movido de volta. Após hard delete, único revert é reinstalar (`npm install -g openclaw@<v>`).

**ATENÇÃO:** Se Recipe J (label OAuth patch) foi aplicada com `chattr +i`, o script automaticamente faz `chattr -i` antes do `rm -rf` em arquivos do _trash.

Ver detalhes em [`docs/recovery-guide.md`](../docs/recovery-guide.md#recipe-k--cleanup-plugin-runtime-deps-stale).

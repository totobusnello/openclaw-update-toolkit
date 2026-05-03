# Recipe M — Web search provider validation strict (v2026.5.2+)

**SEVERIDADE:** 🔴 ALTA (se versão >= v2026.5.0 e houver config antiga) | 🟢 N/A (nova install ou migrado já)

**SYMPTOM:**
- Gateway fails to boot com mensagem: `Gateway failed to start: Error: Invalid config at <config-path>. tools.web.search.provider: web_search provider is not available: <NAME>`
- Sugestão no erro: `install or enable plugin "<NAME>", then run openclaw doctor --fix`
- Boot travado em Phase 1, zero gateway uptime

**CAUSA RAIZ:**
Na v2026.5.0, o gateway introduziu **validação estrita** do campo `tools.web.search.provider` contra o conjunto de plugins ATIVOS em startup. Configs antigas apontam pra plugins desabilitados/não-instalados (chamamos de "config-zumbi") — tolerado na v2026.4.x, bloqueante na v5.0+.

Caso comum: `tools.web.search.provider = "brave"` mas `openclaw plugins list --json | jq '.plugins[] | select(.id=="brave")'` mostra `enabled:false, status:disabled` desde versões anteriores. Ou plugin foi **externalizado** na v5.2 (movido pra npm scoped `@openclaw/brave`) e nunca foi reinstalado.

**FIX:**
```bash
# 1. Backup precaucional
cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.bak-pre-websearch-fix-$(date +%Y%m%d-%H%M%S)

# 2. Trocar provider pra um bundled (zero-config, presente em v5.0+)
openclaw config set tools.web.search.provider duckduckgo

# 3. Validar config
openclaw config validate
# Esperado: Config valid
```

**VALIDATION:**
```bash
# Confirmar provider gravado
openclaw config get tools.web.search.provider
# Esperado: duckduckgo

# Confirmar plugin disponível
openclaw plugins list --json | jq '.plugins[] | select(.id=="duckduckgo")'
# Esperado: enabled:true, status:loaded (ou similar)

# Boot test
openclaw doctor --fix
# Esperado: retorna sem erros
```

**REVERT:**
```bash
# Se precisa voltar pro provider antigo
cp ~/.openclaw/openclaw.json.bak-pre-websearch-fix-* ~/.openclaw/openclaw.json
openclaw config validate
# Se retorna erro sobre provider ausente, refazer FIX acima
```

**ALTERNATIVAS — Providers bundled recomendados (v5.0+):**
- `duckduckgo` — **recomendado**, zero-config, search genérico
- `searxng` — requer instance `SEARXNG_URL` no env ou config; mais privacidade
- `exa` — requer `EXA_API_KEY`
- `firecrawl` — requer `FIRECRAWL_API_KEY`
- `tavily` — requer `TAVILY_API_KEY`
- `kimi-coding` — requer key Kimi
- `web-readability` — leitura pura, sem search
- `webhooks` — integração custom

Se quer **manter o provider externalizado antigo** (ex: `brave`):
1. Verificar se existe como `@openclaw/brave` no npm: `npm search @openclaw/brave --json | jq '.[]'`
2. Se não existe publicamente, aguardar publicação via ClawHub ou contatar maintainers
3. Temporariamente usar `duckduckgo` pra unblock boot, migrar depois

**APPLIES TO:** v2026.5.0+ (validação estrita introduzida em release notes #53092 — "*validate configured web-search providers... against the active plugin set at config load*")

Lição completa em [`lessons/2026-05-03-openclaw-v5.2-upgrade-pitfalls.md`](../lessons/2026-05-03-openclaw-v5.2-upgrade-pitfalls.md) — seção Pitfall 1: Web search provider validation strict.

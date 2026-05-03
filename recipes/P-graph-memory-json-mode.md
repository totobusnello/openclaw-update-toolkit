# Recipe P — Graph-memory JSON mode fix (markdown wrapping)

**SEVERIDADE:** 🟡 MÉDIA (graph-memory perde ~5-10% dos extracts em silêncio; recall continua funcionando) | 🟢 BAIXA se você não usa graph-memory plugin

**SYMPTOM:**
- Logs do gateway mostram recorrentemente: `[plugins] [graph-memory] turn extract failed: Error: [...] extraction parse failed: SyntaxError: Unexpected non-whitespace character after JSON at position N`
- Raw response começa com ` ```json` (markdown code block wrapper)
- `graph-memory` extracts caem, mas recalls continuam (lê graph existente sem problema)
- Graph cresce mais lentamente do que esperado, aumento de nodes/edges por turno é intermitente

**CAUSA RAIZ:**
O plugin `graph-memory` envia prompts ao LLM esperando JSON puro (`{"nodes":[...],"edges":[...]}`), mas não força explicitamente `response_format` na request OpenAI-compatible. LLMs modernos (Gemini 2.5-flash-lite, OpenAI, Claude, Mistral, etc) frequentemente wrappar respostas em markdown code blocks (` ```json...``` `) por padrão, mesmo com system prompts dizendo "JSON only, no extra text".

O plugin chama `JSON.parse()` direto no raw response, e o helper `extractJson()` não strip markdown delimiters. O caractere ` ``` ` na primeira posição não-whitespace quebra o parser, causando erro de parse. Turns com extract bloqueado falham silenciosamente — nenhuma alerta, apenas "extraction skipped". O result: ~5-10% dos turns perdem extratos novos de nodes/edges. Recall não é afetado (apenas lê graph existente).

A solução é forçar JSON mode na request adicionando `response_format: { type: "json_object" }` no body do fetch contra `${baseURL}/chat/completions`, seguindo spec OpenAI. Isso garante que o provider retorne **JSON puro**, sem markdown.

**FIX:**
```bash
# 1. Localizar arquivo LLM do plugin
LLM_FILE=$(find /root/.openclaw -name "llm.ts" -path "*/graph-memory/src/engine/*" 2>/dev/null | head -1)
if [ -z "$LLM_FILE" ]; then
  echo "ERROR: graph-memory plugin not found. Install via: openclaw plugins install graph-memory"
  exit 1
fi

# 2. Backup pré-patch
TS=$(date +%Y%m%d-%H%M%S)
cp "$LLM_FILE" "${LLM_FILE}.bak-pre-json-mode-${TS}"
echo "Backup: ${LLM_FILE}.bak-pre-json-mode-${TS}"

# 3. Patch idempotente via Python (detecta se já patched)
python3 - "$LLM_FILE" <<'PYSCRIPT'
import re, sys
path = sys.argv[1]
src = open(path).read()

# Detecta se já patched
if 'response_format' in src and '// MONKEY-PATCH' in src:
    print("[graph-memory] already patched with response_format")
    sys.exit(0)

# Pattern: busca fechamento de body do fetch (temperature: 0.1 seguido de })
# e insere response_format antes do fechamento
old_pattern = r'(temperature:\s*0\.1,\s*)(\})'
new_replacement = r'\1// MONKEY-PATCH: force JSON mode to prevent markdown ```json``` wrapping\n          response_format: { type: "json_object" },\n        \2'

patched, n = re.subn(old_pattern, new_replacement, src)
if n == 0:
    print("ERROR: could not find 'temperature: 0.1' pattern in llm.ts")
    print("File structure may have changed. Manual patch required.")
    sys.exit(2)
if n > 1:
    print(f"WARNING: found {n} occurrences of temperature: 0.1 (expected 1)")
    print("Patching first occurrence only")
    patched = src  # revert multi-match
    patched = re.sub(old_pattern, new_replacement, src, count=1)
    n = 1

open(path, 'w').write(patched)
print(f"[graph-memory] patched: response_format injected ({n} occurrence)")
PYSCRIPT

# 4. Reiniciar gateway pra carregar plugin patcheado
systemctl restart openclaw-gateway
echo "[graph-memory] gateway restarting..."
sleep 3
```

**VALIDATION:**
```bash
# 1. Confirmar marker presente
LLM_FILE=$(find /root/.openclaw -name "llm.ts" -path "*/graph-memory/src/engine/*" 2>/dev/null | head -1)
if grep -q "MONKEY-PATCH.*JSON mode" "$LLM_FILE" 2>/dev/null; then
  echo "✓ Patch marker found"
else
  echo "✗ Patch marker NOT found"
  exit 1
fi

# 2. Confirmar response_format na chamada
if grep -q "response_format.*json_object" "$LLM_FILE" 2>/dev/null; then
  echo "✓ response_format injected"
else
  echo "✗ response_format NOT found"
  exit 1
fi

# 3. Confirmar gateway online e rodando
sleep 2
if systemctl is-active openclaw-gateway > /dev/null; then
  echo "✓ Gateway active"
else
  echo "✗ Gateway NOT active"
  systemctl status openclaw-gateway
  exit 1
fi

# 4. Monitorar erros graph-memory (aguardar ~5 min de traffic)
echo "Waiting 5 minutes to collect metrics..."
sleep 300

PARSE_ERRORS=$(journalctl -u openclaw-gateway --since "5 min ago" --no-pager 2>/dev/null | grep -c "extraction parse failed" || echo "0")
EXTRACTS=$(journalctl -u openclaw-gateway --since "5 min ago" --no-pager 2>/dev/null | grep -c "graph-memory.*extracted" || echo "0")

echo "Parse errors (last 5 min): $PARSE_ERRORS (expected: 0)"
echo "Successful extracts (last 5 min): $EXTRACTS (expected: > 0)"

if [ "$PARSE_ERRORS" -eq 0 ] && [ "$EXTRACTS" -gt 0 ]; then
  echo "✓ Fix validated"
  exit 0
else
  echo "⚠ Check graph-memory logs:"
  journalctl -u openclaw-gateway --since "10 min ago" --no-pager | grep -i "graph-memory" | tail -5
fi
```

**REVERT:**
```bash
# Localizar backup mais recente
LLM_FILE=$(find /root/.openclaw -name "llm.ts" -path "*/graph-memory/src/engine/*" 2>/dev/null | head -1)
LATEST_BAK=$(ls -t ${LLM_FILE}.bak-pre-json-mode-* 2>/dev/null | head -1)

if [ -n "$LATEST_BAK" ]; then
  cp "$LATEST_BAK" "$LLM_FILE"
  echo "Reverted to: $LATEST_BAK"
  systemctl restart openclaw-gateway
else
  echo "No backup found. Reverting via git (if graph-memory is git-cloned):"
  GRM_DIR=$(dirname $(dirname $(dirname "$LLM_FILE")))
  if [ -d "$GRM_DIR/.git" ]; then
    cd "$GRM_DIR"
    git checkout src/engine/llm.ts
    echo "Reverted via git"
  else
    echo "ERROR: no backup and not a git repo. Manual restore needed."
    exit 1
  fi
fi
```

**APPLIES TO:** todas versões do graph-memory plugin (testado em 1.5.x+) com provider OpenAI-compatible (`models.providers.<X>.api: "openai-compatible"` ou `baseURL` apontando pra endpoint `/chat/completions` que aceita spec OpenAI).

**Compatibility — Providers que suportam `response_format`:**
- **Gemini 1.5+** via baseURL `https://generativelanguage.googleapis.com/v1beta/openai/`
- **OpenAI** gpt-3.5-turbo-1106+ e todos gpt-4+
- **Claude** (Anthropic) se acessado via proxy OpenAI-compatible
- **Mistral** (todos modelos)
- **OpenRouter** (passa pra provider underlying)
- **Ollama** versões recentes (suporte adicionado em 0.1.x+)
- **LM Studio** via OpenAI-compatible endpoint
- **Vllm** e similares (suportam spec)

Se seu provider **NÃO suporta** `response_format`, o gateway retornará erro 400 no boot. Nesse caso, alternativa é patchear `extractJson()` em `extract.ts` pra strip markdown delimiters (` ```json ... ``` `) antes do `JSON.parse()`. Contacte maintainers ou abra issue.

**INVARIANTE pós-upgrade:** se você atualizar o plugin via `npm install graph-memory@<v>` ou `git pull` no repo do plugin, o arquivo `llm.ts` será sobrescrito (patch perdido). Reaplicar via comando FIX acima — o script Python é idempotente, detecta `response_format` já presente e pula patching.

> ⚠️ **MÉDIO impacto:** graph-memory perde ~5-10% dos extracts durante turns afetados. Recall não sofre (lê graph existente sem problema). Ao aplicar patch, extracts voltam ao normal — próximos turns gerão nodes/edges esperados. Nenhuma perda de dados existentes.


# Runbook — Recovery de "Cost Explosion" (custos inesperados na Anthropic)

> **Cenário:** dashboard da Anthropic mostra cobrança alta inesperada. Você acreditava estar usando Max OAuth (zero-cost) mas alguma coisa está consumindo API paga.
> **Severidade:** 🔴 ALTA — sangramento financeiro ativo.
> **Tempo estimado:** 10-15min.

---

## Diagnóstico rápido (2min)

Confirme que é cost explosion vs falso alarme:

```bash
# 1. Ver provider em uso real
journalctl -u openclaw-gateway --since "2 hours ago" --no-pager | grep -E "provider=" | tail -10

# 2. Contar requests pra api.anthropic.com (path PAGO)
journalctl -u openclaw-gateway --since "24 hours ago" --no-pager | grep -cE "api\.anthropic\.com|x-api-key"
```

Resultados possíveis:
- Logs mostram `provider=claude-cli` + 0 requests pra `api.anthropic.com` → **falso alarme** (label cosmético do session-status pode ter confundido — Recipe J)
- Logs mostram `provider=anthropic` (sem o `-cli`) OU > 0 requests → **cost explosion confirmado**

Se confirmado, prosseguir.

---

## Passo 1 — Parar sangramento imediatamente

A causa mais comum: agentes configurados com `agentRuntime: { id: "pi" }` (default) usam profile `anthropic:default` (mode=token, API key paga).

```bash
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/kill-switch-cost.sh | sudo bash
```

Esse script força todos os agentes pra `agentRuntime.id=claude-cli` (subprocess local OAuth Max, zero custo).

**Validação imediata:**
```bash
sleep 30
NEW_CALLS=$(journalctl -u openclaw-gateway --since "30 seconds ago" --no-pager | grep -cE "api\.anthropic\.com|x-api-key")
echo "Calls a api.anthropic.com nos últimos 30s: $NEW_CALLS"
# Esperado: 0
```

## Passo 2 — Limpar fallback chain (Recipe C)

Mesmo com `claude-cli` ativo, se chain tem `anthropic-max` ou `anthropic` como fallback, ainda pode cair em path pago quando claude-cli falha uma vez.

```bash
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/clean-fallback-chain.sh | sudo bash
```

Chain canônica resultante:
```
primary: anthropic/claude-sonnet-4-6      # Max OAuth, $0
fallbacks:
  - openai-codex/gpt-5.5                  # OAuth Codex, $0
  - gemini/gemini-2.5-pro                 # API key barata
```

## Passo 3 — Reset sessions stickiness (Recipe L)

Sessões podem ter "grudado" em fallback durante o período de cost explosion. Resetar pra forçar volta pro claude-cli.

```bash
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/reset-sessions.sh | sudo bash
```

## Passo 4 — Validar credentials Claude CLI (Recipe E)

Se `.credentials.json` está corrompido/zerado, Claude CLI falha → cai no fallback pago. Aplicar imutabilidade:

```bash
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/chattr-credentials.sh | sudo bash
```

Se script falhar com "credentials.json não existe", autenticar:
```bash
claude setup-token  # interativo — segue prompt
chattr +i /root/.claude/.credentials.json
```

## Passo 5 — Validação 1h depois

Aguarde 60min de operação normal e valide:

```bash
# Calls a api.anthropic.com na última hora — deve ser 0
journalctl -u openclaw-gateway --since "1 hour ago" --no-pager | grep -cE "api\.anthropic\.com|x-api-key"

# Provider em uso
journalctl -u openclaw-gateway --since "1 hour ago" --no-pager | grep -E "provider=" | sort | uniq -c
# Esperado: só `provider=claude-cli` (e ocasionalmente `provider=openai-codex` ou `gemini`)
```

## Passo 6 — Validação 24h (próximo dia)

Manhã seguinte:

```bash
journalctl -u openclaw-gateway --since "24 hours ago" --no-pager | grep -cE "api\.anthropic\.com|x-api-key"
# Esperado: 0 (ou bem próximo de 0)
```

E confirmar no dashboard da Anthropic — não deve haver nova cobrança.

---

## Investigar gasto que JÁ aconteceu

Pra estimar quanto gastou no período de cost explosion:

```bash
# Quando começou o problema?
journalctl -u openclaw-gateway --since "7 days ago" --no-pager | grep -E "provider=anthropic[^-]" | head -5
# Pegue o timestamp do PRIMEIRO match — esse é o início aproximado

# Volume de chamadas durante o período
journalctl -u openclaw-gateway --since "<TIMESTAMP_INICIO>" --no-pager | grep -cE "provider=anthropic[^-]|api\.anthropic\.com"
```

Multiplique pelo custo médio da sua tier de modelo Anthropic. Se número alto:
- Considere abrir ticket de suporte Anthropic explicando que houve mau-funcionamento da configuração
- Eles podem dar credit em alguns casos (sem garantia)

---

## Causas raiz mais comuns

1. **`agentRuntime.id` default em agentes recém-criados** — Recipe B resolve.
2. **`npm install -g openclaw@<v>` resetou config** — checar `git log` do `openclaw.json` ou diff com backup.
3. **`.credentials.json` foi zerado** sem `chattr +i` — Recipe E.
4. **Session stickiness em canal específico** — Recipe L.
5. **Fallback chain mal configurada** apontando pra `anthropic-max` — Recipe C.
6. **RelayPlane reativado** após upgrade — Recipe F.

---

## Prevenção contínua

Adicionar canary que monitora cost path e alerta no Discord:

```bash
cat > /root/.openclaw/scripts/canary-anthropic-api-calls.sh << 'CANARY'
#!/bin/bash
set -e
COUNT=$(journalctl -u openclaw-gateway --since "1 hour ago" --no-pager 2>/dev/null \
  | grep -cE "api\.anthropic\.com|x-api-key" || true)
logger -t canary-anthropic-api "anthropic-api-calls-1h=$COUNT"

if [ "$COUNT" -gt 0 ] && [ -f /root/.openclaw/.env ]; then
  WEBHOOK=$(grep "^DISCORD_WEBHOOK=" /root/.openclaw/.env | cut -d= -f2-)
  if [ -n "$WEBHOOK" ]; then
    curl -sS -X POST -H "Content-Type: application/json" \
      -d "{\"content\": \"🚨 COST CANARY: $COUNT calls a api.anthropic.com na última hora em $(hostname). Investigar.\"}" \
      "$WEBHOOK" > /dev/null 2>&1 || true
  fi
fi
CANARY
chmod +x /root/.openclaw/scripts/canary-anthropic-api-calls.sh
( crontab -l 2>/dev/null | grep -v canary-anthropic-api-calls; echo "0 * * * * /root/.openclaw/scripts/canary-anthropic-api-calls.sh" ) | crontab -
echo "✅ Canary instalado: roda hourly, alerta Discord se >0 calls"
```

---

## Última atualização

2026-05-01.

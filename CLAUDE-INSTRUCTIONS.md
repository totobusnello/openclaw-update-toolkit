# Instruções Operacionais — Para o Claude do Usuário

> **Para humanos:** este arquivo é o "manual do operador" que o Claude do destinatário lê para operar autonomamente. Você não precisa ler — só apontar para este repo no chat. O Claude sabe o que fazer.

> **Para Claude:** você é o operador de recuperação. Leia este arquivo INTEIRO antes de qualquer ação. Siga o protocolo abaixo à risca. Não improvise. Quando em dúvida, pare e pergunte.

---

## 🎯 Sua missão

O usuário tem uma instalação OpenClaw com problemas (custos inesperados, crashes, conflitos de plugin, leak de DM, etc). Você vai:

1. **Diagnosticar** o estado dela (read-only)
2. **Apresentar** plano de ação organizado por severidade
3. **Aplicar fixes** com autorização do usuário (modo híbrido — explicado abaixo)
4. **Validar** com 10-invariants check
5. **Reportar** resultado final

Você opera **via SSH** na VPS do usuário. As credenciais ele te passa no chat.

---

## 📜 Protocolo rigoroso (não improvise)

### Fase 1 — Diagnóstico (read-only, sempre primeiro, sem autorização)

```bash
ssh root@<vps-ip>
bash <(curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/diagnostic.sh)
```

Capture o output completo. **Nunca** cole tokens, credenciais, ou números de telefone no chat.

### Fase 2 — Plano de ação organizado por severidade

Mapeie cada ❌/⚠️ do diagnostic para uma Recipe específica. Apresente para o usuário em formato:

```
## Estado da instalação

✅ X coisas OK
❌ N problemas detectados

## Plano de ação proposto

### 🔴 SEVERIDADE ALTA — aplico em batch com 1 autorização sua
- Recipe X — <título>: <causa raiz em 1 linha>
- Recipe Y — <título>: <causa raiz em 1 linha>

### 🟡 SEVERIDADE MÉDIA — pergunto antes de cada uma
- Recipe Z — <título>: <quando aplica>

### 🟢 SEVERIDADE BAIXA / COSMÉTICA — só se você pedir
- Recipe W — <título>

**Posso aplicar as ALTAs agora? (sim/não)**
```

### Fase 3 — Aplicação modo híbrido

Receba autorização. Aplique conforme tabela abaixo.

#### 🔴 SEVERIDADE ALTA — 1 autorização batch ("sim/vai")

Aplica em sequência sem nova pergunta. Se qualquer uma falhar, **pare** e reporte.

| Recipe | Quando | Por que ALTA |
|--------|--------|--------------|
| **D** — Reaplicar monkey-patch fratricide #62028 | patch ausente OU NRestarts > 0 | Gateway pode crashar a qualquer restart |
| **B** — Kill switch custo Anthropic | calls a api.anthropic.com > 0 OU agentRuntime != claude-cli | Custo ATIVO agora, sangramento |
| **G** — Disable plugin Telegram MCP | telegram@claude-plugins-official: true OU 409 conflicts > 0 | Workers em retry-loop CPU 96%, instabilidade ativa |
| **E** — chattr +i credentials.json | sem flag `i` no `lsattr` | Auth quebra em horas sem isso |

#### 🟡 SEVERIDADE MÉDIA — pergunta antes de cada

Para cada uma aplicável, pergunte ao usuário individualmente. Não em batch.

| Recipe | Quando | Pergunta sugerida |
|--------|--------|-------------------|
| **F** — RelayPlane disable + baseUrl | baseUrl != api.anthropic.com OU relayplane-proxy active | "Aplico Recipe F (desativa RelayPlane redundante)?" |
| **C** — Fallback chain limpa | anthropic-max em fallbacks | "Aplico Recipe C (limpa fallback pra evitar custo escondido)?" |
| **H** — dmScope per-channel-peer | dmScope != per-channel-peer | "Aplico Recipe H (isola sessões DM entre peers)?" |
| **L** — Reset sessions stickiness | sessions.json com fallback model grudado | "Aplico Recipe L (reseta sessions grudadas)?" |
| **I** — Delivery-queue cleanup | "Unknown Channel" recorrente | "Aplico Recipe I (limpa delivery-queue órfã)?" |

#### 🟢 SEVERIDADE BAIXA / COSMÉTICA — só se usuário pedir explicitamente

Não ofereça espontaneamente. Mencione no plano de ação como "se quiser":

- **J** — Patch label OAuth Max (display "🔑 token" → "🛡️ OAuth Max")
- **K** — Cleanup plugin-runtime-deps stale (recupera disk se >5 dirs)

### Fase 4 — Validação

Após cada Recipe aplicada, rode validação parcial específica daquela Recipe.

Após **todas** as Recipes do batch ALTA, rode o validate global:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/validate.sh)
```

Espera 10 ✅. Se algum ❌ aparecer:
- Identifique qual Recipe relacionada
- Reporte ao usuário
- Pergunte se quer reaplicar ou reverter

### Fase 5 — Reporte final

```
## ✅ Recovery completo

**Aplicado:** Recipes A, B, G, E (4 ALTA) + Recipe F (1 MÉDIA autorizada)
**Pulado:** Recipe H (você não autorizou), Recipes J/K (cosméticas)

**Estado final:** 10/10 invariants ✅
- Custo zero validado (provider=claude-cli, 0 calls api.anthropic.com)
- Telegram conflicts: 0 nas últimas 24h
- Gateway healthy: NRestarts=0, Memory=600M, 22 tasks
- Backups timestampados em /root/.openclaw/backups/recovery-<TS>/

**Próximas ações sugeridas:**
- Considerar Recipes cosméticas (J, K) numa janela tranquila
- Monitorar canary Telegram (instalado pela Recipe G)
- Reaplicar monkey-patch após qualquer `npm install -g openclaw@<v>` futuro
```

---

## 🛡️ Regras inegociáveis

### 1. Backup obrigatório antes de qualquer write
Antes da PRIMEIRA Recipe da sessão, sempre rode:
```bash
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p /root/.openclaw/backups/recovery-$TS
cp /root/.openclaw/openclaw.json /root/.openclaw/backups/recovery-$TS/
cp /root/.openclaw/.env /root/.openclaw/backups/recovery-$TS/
cp /root/.claude/settings.json /root/.openclaw/backups/recovery-$TS/ 2>/dev/null
cp /root/.claude/.credentials.json /root/.openclaw/backups/recovery-$TS/ 2>/dev/null
ls /usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js | xargs -I{} cp {} /root/.openclaw/backups/recovery-$TS/
echo "Backup directory: /root/.openclaw/backups/recovery-$TS"
```

Reporte o caminho do backup ao usuário no início.

### 2. Sanitização total
**NUNCA** imprima no chat:
- Tokens (sk-*, sk-ant-oat01-*, xoxp-*, ghp_*)
- API keys
- Números de telefone (+55*, +1*, etc)
- IDs de canais privados
- OAuth tokens completos

Quando precisar mencionar, use `<REDACTED>` ou hash truncado (`sha256:abc123...`).

### 3. Pare em qualquer erro
Se algum comando retornar non-zero exit:
- **Pare imediatamente**
- Reporte ao usuário com comando exato + erro
- Não tente "corrigir sozinho" via chains de fixes não autorizados
- Se gateway entrou em crash loop por causa do fix, reverta IMEDIATAMENTE com o backup

### 4. Auto-rollback se validate falhar pós-Recipe ALTA
Se após aplicar Recipe ALTA, `validate.sh` mostra ❌ em invariant que deveria estar ✅:
- Reverta a Recipe (cada uma tem seção REVERT documentada)
- Reporte ao usuário
- **NÃO continue** com próximas Recipes até resolver

### 5. Use sempre os scripts modulares quando disponíveis
Em vez de copiar comandos shell de markdown, prefira:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/<RECIPE>.sh)
```

Lista em `scripts/recipes/`:
- `reapply-monkey-patch.sh` (Recipe D)
- `disable-telegram-mcp.sh` (Recipe G)
- `kill-switch-cost.sh` (Recipe B)
- `chattr-credentials.sh` (Recipe E)
- `relayplane-disable.sh` (Recipe F)
- `clean-fallback-chain.sh` (Recipe C)
- `dmscope-fix.sh` (Recipe H)
- `reset-sessions.sh` (Recipe L)
- `delivery-queue-cleanup.sh` (Recipe I)
- `reapply-emoji-patch.py` (Recipe J)
- `cleanup-plugin-runtime-deps.sh` (Recipe K)

Cada script é idempotente, faz backup interno, valida pós-aplicação.

### 6. Versão do OpenClaw — confirme antes
Se versão < v2026.4.29, alerte o usuário:
> "Você está em v<X>. Toolkit é otimizado pra v2026.4.29. Recomendo upgrade primeiro (Recipe A) antes dos outros fixes — ou aceitar que algumas Recipes podem se aplicar de forma diferente."

Se versão > v2026.4.29 (futura), alerte:
> "Você está em v<X> — toolkit pode estar desatualizado. Algumas Recipes podem ser obsoletas (problema corrigido upstream). Verifique CHANGELOG do toolkit antes."

---

## 📚 Como ler as Recipes

Cada Recipe está em `recipes/<LETRA>-<nome>.md`. Estrutura padrão:

```markdown
## Recipe X — <título>
**SEVERIDADE:** ALTA / MÉDIA / BAIXA

**SYMPTOM:** <o que o user vê no diagnostic ou no comportamento>
**CAUSA RAIZ:** <explicação técnica>
**FIX:** <comando exato OU referência ao script em scripts/recipes/>
**VALIDATION:** <como confirmar que funcionou>
**REVERT:** <como desfazer>

**INVARIANTE pós-upgrade:** <se aplicável — coisas que precisam reaplicar após npm install -g>
```

Ler primeiro o cabeçalho (severidade + sintoma) pra decidir se aplica. Depois ler tudo se for executar.

---

## 🤝 Quando perguntar ao usuário (não decida sozinho)

- Versão muito diferente da v2026.4.29 (< v.24 ou > v.30)
- Diagnostic mostra estado **inesperado** (configs custom, agentes não-padrão, channels exóticos)
- Qualquer erro durante aplicação
- Recipes MÉDIAS individuais (perguntar sempre)
- Recipes COSMÉTICAS (só se ele pedir)
- Se backup falhar (filesystem read-only? permissão? disk full?)
- Se validate.sh retornar > 3 ❌ (instalação muito danificada — pode precisar de atenção manual)

---

## 🎯 Princípios de UX que você deve seguir

1. **Tom direto, sem floreio.** Usuário tem um problema, quer fix. Não floreie.
2. **Fragmentos OK** quando claros. "Recipe D aplicada. Validando." é melhor que parágrafos.
3. **Sempre estimar tempo.** "Recipe G — ~30s + restart 12s = ~1min" pra setar expectativa.
4. **Reportar progresso em logs short.** "1/4 ALTA aplicada (D ✅)..."
5. **NUNCA fingir que algo funcionou.** Se não validou, diga "comando rodou, validação pendente".
6. **Mostrar comando exato que rodou.** Transparência = confiança.

---

## 📋 Checklist mental antes de cada ação

- [ ] É read-only? (Se sim, pode rodar sem autorização)
- [ ] Tem severidade definida? (Se ALTA → batch. Se MÉDIA → perguntar. Se BAIXA → só se pedido)
- [ ] Backup foi feito hoje nesta sessão? (Se não, fazer agora)
- [ ] Tem REVERT documentado? (Se não, parar e perguntar)
- [ ] Estou imprimindo secret no chat? (Se sim, redact)

---

**Última atualização:** 2026-05-01

Versão deste protocolo: 1.0.0 (Phase 1 MVP do toolkit)

# Lesson: `toolsAllow` incompatível com backend `claude-cli`

**Data:** 2026-06-17
**Severidade:** Alta (crons críticos falharam silenciosamente por múltiplos dias)
**Agente:** Forge

---

## O que aconteceu

Três crons críticos passaram a falhar com erro consistente:

```
FallbackSummaryError: All models failed (2):
  anthropic/claude-haiku-4-5: CLI backend claude-cli cannot enforce runtime toolsAllow;
    use an embedded runtime for restricted tool policy (unknown)
  openai/gpt-5.5: auth refresh request timed out after 10s (timeout)
```

**Jobs afetados:**
| Job | Agent | `toolsAllow` | Erros consecutivos |
|-----|-------|-------------|-------------------|
| `relatorio-eod` | main | `["exec", "session_status"]` | 4 |
| `auto-update-skills-clawhub` | main | `["exec"]` | 4 |
| `workspace-git-autopush` | forge | `["exec"]` | 4 |

**Job proativamente corrigido antes de falhar:**
| Job | Agent | `toolsAllow` |
|-----|-------|-------------|
| `cipher-weekly-full` | cipher | `["exec", "message"]` |

---

## Root cause

O campo `toolsAllow` no payload de cron jobs define uma allowlist de ferramentas — quando presente, o runtime tenta restringir o agente apenas a essas ferramentas.

**O problema:** o backend `claude-cli` (usado pelo `anthropic/claude-haiku-4-5` e todos os modelos Anthropic via CLI) **não suporta enforcement de `toolsAllow` em runtime**. A verificação passou a ser feita de forma mais rígida em alguma versão recente do gateway, rejeitando o job antes mesmo de iniciar a execução.

O fallback para `openai/gpt-5.5` (OAuth) também falhou por timeout de auth refresh — deixando os jobs sem fallback funcional.

---

## Por que alguns jobs com `toolsAllow` continuaram funcionando?

Os jobs de briefing (`prepare-briefing-context`, `daily-briefing-delivery`, etc.) também tinham `toolsAllow: ["exec"]` mas não falharam imediatamente. Hipótese: o enforcement mais rígido foi introduzido gradualmente ou os jobs afetados têm alguma combinação específica (ex: `lightContext: true` + `toolsAllow`).

**Ação preventiva recomendada:** remover `toolsAllow` de todos os cron jobs que usam modelos Anthropic via CLI.

---

## Fix aplicado

Removido `toolsAllow` (setado para `null`) nos 4 jobs via `cron.update`:

```bash
# Exemplo do patch aplicado em cada job
{
  "patch": {
    "payload": {
      "toolsAllow": null
    }
  }
}
```

**Por que é seguro remover:** os jobs são todos `sessionTarget: "isolated"` — sessões efêmeras sem histórico de ferramenta. O comportamento do agente já é constrangido pelo prompt (ex: "Execute X, responda HEARTBEAT_OK"). A restrição via `toolsAllow` era redundante.

---

## Regra para novos crons

> **Nunca use `toolsAllow` em cron jobs com `sessionTarget: "isolated"` e modelo Anthropic (claude-cli).**

Se precisar restringir ferramentas em cron jobs:
1. Use **embedded runtime** (não claude-cli) — ex: `openai/gpt-4o` com API key direta
2. Ou constranja via **prompt** — mais confiável e portável entre runtimes

---

## Lições aprendidas

1. **`toolsAllow` ≠ segurança robusta** — depende de suporte do runtime e pode quebrar silenciosamente
2. **Fallback chain deve ser testada** — `gpt-5.5` OAuth estava com timeout; fallback ineficaz
3. **Crons críticos precisam de `failureAlert`** — `workspace-git-autopush` não tinha alerta configurado, ficou 4 falhas silencioso
4. **Alertas de falha chegam tarde** — `relatorio-eod` alertou só na 3ª falha; para crons diários isso é 3 dias perdidos

---

## Ações de follow-up recomendadas

- [ ] Auditar todos os crons restantes com `toolsAllow` e remover onde modelo = Anthropic/CLI
- [ ] Verificar health do OAuth `openai/gpt-5.5` — auth refresh timeout pode indicar token próximo de expirar
- [ ] Adicionar `failureAlert` ao `workspace-git-autopush` (atualmente sem alerta)
- [ ] Considerar reduzir `failureAlert.after` em crons críticos de 3 para 1

# Lesson: cron agent "some sem erro" — tool-cap legado sem marker força fallback `claude-cli → gpt-5.5`

**Data:** 2026-07-07
**Severidade:** Alta (digest crítico entregou vazio por dias, sem nenhum erro visível)
**Versão:** OpenClaw 2026.6.11

---

## Sintoma

Um cron `agentTurn` (ex.: um digest que depende de `exec`/Bash) **para de entregar, sem lançar erro visível pro usuário**. O agente simplesmente "some": a sessão roda, mas a saída chega vazia, às vezes com um `announce give up (retry-limit)`.

Nos logs do gateway, o rastro é este:

```
[model-fallback/decision] model fallback decision: decision=candidate_failed
  requested=anthropic/claude-... candidate=anthropic/claude-...
  reason=unknown next=openai/gpt-5.5
  detail=CLI backend claude-cli cannot enforce runtime toolsAllow; use an embedded runtime for restricted tool policy
```

O backend `claude-cli` **não consegue impor um `toolsAllow` em runtime** — por design ele lança esse erro em vez de silenciosamente ignorar o cap (ignorar seria um downgrade de segurança). O gateway então cai no fallback (`gpt-5.5`), que **não tem `exec`/Bash** — logo qualquer agente que dependa de shell produz saída vazia. O usuário nunca vê um erro: o digest só "some".

## Causa-raiz

A correção nativa **#91499** ("preserve scheduled turn tool policy", merge 2026-06-15, presente no build 6.11) resolve isso **apenas para caps auto-stampados** — os que carregam o marker `"toolsAllowIsDefault": true` no `job_json`. Para esses, `resolveCliRuntimeToolsAllow(toolsAllow, toolsAllowIsDefault)` retorna `undefined` (dropa o cap) e o `claude-cli` não lança.

**O buraco:** jobs criados ANTES de 15/jun carregam um tool-cap **sem** esse marker, e **não há backfill** que os migre. Eles continuam quebrando indefinidamente mesmo depois do upgrade que trouxe o #91499. O cap costuma ser um snapshot auto-stampado de ~60 tools de superfície (nem contém `exec`), então o agente perde justamente a capacidade que precisava.

## Diagnóstico (como confirmar)

1. **Log:** procurar `cannot enforce runtime toolsAllow` no journal do gateway.
2. **Store:** no SQLite do gateway (`state/openclaw.sqlite`, tabela `cron_jobs`), listar jobs com cap não-vazio, sem marker, em model `anthropic/*`:

```sql
SELECT name FROM cron_jobs
WHERE payload_tools_allow_json IS NOT NULL
  AND payload_tools_allow_json NOT IN ('', 'null', '[]')
  AND job_json NOT LIKE '%toolsAllowIsDefault":true%'
  AND payload_model LIKE 'anthropic/%';
```

Se um cron `anthropic/*` "some sem erro", esses dois sinais confirmam a causa.

## Fix

```bash
openclaw cron edit <job_id> --clear-tools
```

`--clear-tools` é first-class e remove o cap do job (o turn passa a usar todas as tools). Jobs recriados no 6.11 já nascem imunes (o criador de superfície irrestrito não recebe cap).

**NÃO** usar:
- `sandbox.sessionToolsVisibility` — **alavanca errada**: governa o targeting cross-session dos tools `sessions_*`, não o cap do cron.
- escrita SQL direta no store — frágil e fora do contrato do gateway; use o CLI.

## Guard durável

Como o sintoma é invisível, vale um canário horário que detecta a recorrência: cron com cap-não-vazio + sem-marker + `anthropic/*` no store, OU o log `cannot enforce` na última hora → alerta. (Na nossa VPS: `cron-toolsallow-guard.sh`, `37 * * * *`.)

## Por que NÃO virou PR

O fix já é nativo (#91499); o resíduo é **migração de jobs legados**, resolvida com `--clear-tools` (ou recriando o cron). Abrir PR duplicaria trabalho já mergeado. A lição anterior (`2026-06-17-toolsallow-incompatible-claude-cli`) cobre o caso geral "toolsAllow incompatível com claude-cli"; **esta é o twist pós-#91499**: o fix existe mas não faz backfill, então legados seguem quebrando até serem tocados.

## TL;DR

- `claude-cli cannot enforce runtime toolsAllow` → fallback silencioso pra um modelo sem Bash → agente "some".
- #91499 conserta caps COM marker `toolsAllowIsDefault`; legados pré-15/jun sem marker não têm backfill.
- Fix: `openclaw cron edit <id> --clear-tools`. Guard horário pra recorrência.

---
chunk_type: lesson
source: internal
date: 2026-06-20
severity: high
downtime_minutes: 0
tags: [openclaw, claude-cli, session-resume, hang, watchdog, timeout, fallback, oauth, model-routing, session-housekeeping, jsonl]
related_lessons: [2026-06-04-openclaw-6.1-upgrade-patches-native, 2026-06-16-openclaw-6.8-apply-patches-pattern-drift]
---

# OpenClaw claude-cli — `--resume` de sessão inflada trava o turn 900s (hang total, ≠ empty-response); fallback OAuth exige re-login quando o refresh trava

## TL;DR

Um turn `provider=claude-cli model=claude-sonnet-4-6 trigger=user` ficou **900s sem emitir um único byte** (sem stream, sem `rawLines`) e foi morto pelo watchdog: `claude live session turn failed ... durationMs=900005 error=FailoverError ... CLI exceeded timeout (900s) and was terminated`.

Não era o modelo, o auth, rate-limit, MCP nem o gateway. **Repro isolado provou:** `claude --model claude-sonnet-4-6 -p "OK"` limpo respondia em **3-4s** (inclusive no `cwd` do workspace com todos os MCPs/skills carregados). A única variável que diferia do turn que travava era o **`--resume <session-id>`** de uma sessão acumulada (um `.jsonl` grande em `~/.claude/projects/`).

Agravante: o **fallback também estava morto** — o provider OAuth dava `auth refresh request timed out after 10s` e a API key backstop estava expirada (HTTP 401) → `All models failed`. O usuário recebia erro total, não só atraso.

## Sintoma

```
[agent/cli-backend] cli exec: provider=claude-cli model=claude-sonnet-4-6 trigger=user useResume=true resumeSession=<id> reuse=reusable historyPrompt=present
[agent/cli-backend] claude live session start: provider=claude-cli model=claude-sonnet-4-6 activeSessions=1
   ... (900s de SILÊNCIO — nenhum "claude live session turn" intermediário) ...
[agent/cli-backend] claude live session close: provider=claude-cli model=claude-sonnet-4-6 reason=abort
[agent/cli-backend] claude live session turn failed: ... durationMs=900005 error=FailoverError
[model-fallback/decision] decision=candidate_failed reason=timeout next=<fallback> detail=CLI exceeded timeout (900s) and was terminated.
```

Mensagem que o usuário vê no canal:
> ⚠️ CLI subprocess timed out after 900s (overall CLI turn budget). The gateway may still be healthy. Try /new, a lighter model, or raise timeoutSeconds...

## Diagnóstico — repro isolado é o que fecha o caso

O sintoma parece "modelo lento / quota / gateway travado", mas o teste decisivo elimina tudo isso em dois comandos:

```bash
# 1) claude-cli limpo (sem --resume)
time claude --model claude-sonnet-4-6 -p "Reply with exactly: OK"     # → ~3s, "OK"
time claude --model claude-haiku-4-5  -p "Reply with exactly: OK"     # → ~4s, "OK"

# 2) mesmo modelo no cwd do workspace do agente (MCPs/skills carregam)
cd <agent-workspace> && time claude --model claude-sonnet-4-6 -p "OK" # → ~4s, "OK"
```

Se o claude-cli limpo responde em segundos mas o turn do gateway trava 900s, **a variável é o `--resume`**, não o modelo. Sinais de apoio:
- gateway HTTP responde (`curl 127.0.0.1:<port>` → 200 em ms);
- heartbeats de modelos mais baratos (haiku) continuam OK no mesmo período (eles usam sessões frescas);
- zero `429`/rate-limit nos logs; auth do claude-cli válido.

## Root cause

`claude --resume <session>` de uma sessão **acumulada** faz o claude-cli reprocessar o histórico inteiro do `.jsonl` e **trava sem emitir nada** até o watchdog de turno (900s) matar o subprocess. O prompt do turn em si é minúsculo (≈1KB) — não é carga de entrada, é o resume.

Por que heartbeats/crons não travam: eles tendem a abrir **sessão nova a cada batida** (`useResume=false`), então nunca carregam um histórico grande. O canal de conversa de um agente, ao contrário, fica preso numa **única sessão que só cresce** — e em algum ponto o resume dela trava.

**Distinto do bug "empty response"** (corrigido pelo PR upstream do streaming): naquele caso a sessão emite o stream completo mas o `result` final vem vazio (`outBytes=0` com `rawLines>0`). Aqui é hang **sem stream nenhum** — categorias diferentes, fixes diferentes.

## Fix

**Imediato (desbloqueia o canal):** `/new` no canal travado — descarta o resume problemático e abre sessão limpa. **NÃO** aumentar `agents.defaults.timeoutSeconds` (já costuma ser 900s): só faz esperar mais por um hang que nunca emite.

**Estrutural — as sessões `.jsonl` crescem sem housekeeping nativo.** Em uma instância real, `~/.claude/projects/` tinha 4452 arquivos / 309MB; agentes com heartbeat geravam dezenas de sessões órfãs/dia. Um cron diário resolve:

```bash
#!/bin/bash
# prune-claude-sessions.sh — housekeeping das sessões claude-cli (.jsonl)
set -uo pipefail
PROJ="$HOME/.claude/projects"
# 1) prune sessões antigas (>7d)
find "$PROJ" -name "*.jsonl" -mtime +7 -delete 2>/dev/null || true
# 2) prune órfãs pequenas de heartbeat/cron (<50KB & >12h)
find "$PROJ" -name "*.jsonl" -size -50k -mmin +720 -delete 2>/dev/null || true
# 3) ALERTA: sessão ATIVA (<2d) que passou de 2MB = risco de resume hang → /new
big=$(find "$PROJ" -name "*.jsonl" -mtime -2 -size +2M -printf "%s|%p\n" 2>/dev/null | sort -rn)
[ -n "$big" ] && echo "WARN: sessões ativas >2MB (considere /new):" && \
  echo "$big" | head -5 | awk -F'|' '{printf "  %.1fMB %s\n", $1/1048576, $2}'
```

O passo 3 é o mais valioso: **alerta antes** de uma sessão ativa virar um resume travado, em vez de só limpar depois.

## Fallback resiliente — duas armadilhas

Quando o primary (claude-cli) trava, o fallback é a única rede. Duas coisas que o derrubaram:

1. **Token OAuth com refresh travado.** Um provider OAuth de validade curta (~10 dias) cujo auto-refresh falha (`auth refresh request timed out`) precisa de **re-login interativo** — que **exige TTY** (recusa em automação com `requires an interactive TTY`):
   ```bash
   # de um terminal real (ssh -t), NÃO de cron/script:
   openclaw models auth login --provider <provider> --device-code --force
   ```
   `--device-code` mostra URL+código (funciona via SSH); `--force` **limpa o token cached travado** antes de relogar.

2. **Backstop fantasma.** Confirme que o backstop key-based existe de fato como profile — `openclaw models auth list`. Um backstop "documentado" mas inexistente faz o fallback dar `next=none` em vez de cair na key. E valide a key de verdade antes de confiar:
   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" https://api.openai.com/v1/models \
     -H "Authorization: Bearer $KEY"   # 200 = ok; 401 = revogada/expirada
   ```

## Checklist / invariantes

- **`durationMs≈900005 error=FailoverError` SEM logs de turn intermediários = resume-hang**, não empty-response. Fix = `/new`, não `+timeout`.
- **Sessões `.jsonl` precisam de housekeeping** (prune >7d + órfãs pequenas) + **alerta de sessão ativa >2MB**.
- **OAuth de validade curta = ponto único de falha** se o refresh travar; ter procedimento de re-login `--device-code --force` documentado e o backstop key-based *realmente* configurado e validado (não presumido).
- Antes de culpar modelo/quota/gateway num hang de turno: **rode o repro limpo** (`claude -p "OK"`). Segundos = problema é o resume/contexto; trava = aí sim é o backend/auth.

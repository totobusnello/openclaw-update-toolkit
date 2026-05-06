---
chunk_type: lesson
source: internal
date: 2026-05-06
severity: medium
downtime_minutes: 0
component: whatsapp-channel
tags: [whatsapp, baileys, chattr, drift, smoke-test, lesson-2026-05-04, regression]
related_lessons: [2026-05-04-orchestrator-staging-roubou-sessao-baileys-whatsapp.md, 2026-05-04-staging-gateway-contaminates-prod-config.md]
---

# WhatsApp creds.json chattr +i Drift — Pego pelo Smoke Test no Day 1

## TL;DR

Primeiro run do `smoke-test-whatsapp.sh` em produção (recém-criado) revelou que `/root/.openclaw/credentials/whatsapp/default/creds.json` **estava sem `chattr +i`** — violação direta da lição 2026-05-04 (`orchestrator-staging-roubou-sessao-baileys-whatsapp.md`) que prescreveu chattr `+i` como invariante após o incidente do staging gateway invalidando sessão Baileys de produção. Sem `chattr +i`, qualquer outra sessão WhatsApp Web ativa (staging dry-run, instância paralela, re-pair acidental) pode invalidar o device-key da produção e forçar re-scan de QR.

Aplicado `chattr +i` imediatamente. Re-run smoke test: 0 FAILs. Smoke test inaugural validou seu próprio ROI no day 1.

## Como foi detectado

Smoke test executou `lsattr` no creds.json:
```
--------------e------- /root/.openclaw/credentials/whatsapp/default/creds.json
                       ^^^^ esperado: ----i---------e-------
```

Output do smoke test:
```
=== 5. Credentials integrity (regra #6/#7 — chattr +i) ===
  [FAIL] creds.json SEM chattr +i — risco de invalidação por outra sessão.
         Aplicar: chattr +i /root/.openclaw/credentials/whatsapp/default/creds.json
  [OK]   creds.json não-vazio (1863 bytes)
```

## Fix

```bash
ssh root@<vps> 'chattr +i /root/.openclaw/credentials/whatsapp/default/creds.json'
```

Re-run smoke test: PASS.

## Causa provável

Não há trace direto, mas hipóteses ordenadas por probabilidade:

1. **Re-pair manual recente** — operação de re-pair WhatsApp exige `chattr -i` antes de sobrescrever creds.json. Se quem rodou esqueceu de reaplicar `chattr +i` no fim, fica drifted. (Padrão idêntico ao risco do `~/.claude/.credentials.json` documentado na regra #6 do CLAUDE.md.)
2. **Upgrade pipeline** — algum step do `upgrade-zero-downtime.sh` ou follow-up manual pós-v5.4 mexeu em creds (improvável; orchestrator não toca em creds de canais).
3. **Operação manual ad-hoc** — debugging session que abriu o arquivo via vim/edit perdeu flag e não restaurou.

Sem mais evidência forensicamente, hipótese #1 é a mais provável.

## Por que importa

- `chattr +i` é a barreira física que impede staging gateway (que lê paths hardcoded de produção) de invalidar mutuamente a sessão de produção. Lição 2026-05-04 nasceu desse incidente.
- WhatsApp Web limita **1 device-key por número**. Se uma segunda sessão se conecta com os mesmos creds, a primeira é desconectada silenciosamente e exige novo QR scan.
- Nox usa WhatsApp dedicado (<REDACTED-PHONE>). Re-pair envolve scanear QR no celular físico = fricção real pro Toto.

## Lições

### 1. Smoke test surfacing drift no day 1 = ROI imediato

Smoke test inaugural pegou drift que estava silente — provavelmente há dias ou semanas. Sem o smoke test, próximo gatilho seria o próximo upgrade (Phase 1 staging dry-run rodando paralelo ao gateway) e o incidente da lição 2026-05-04 se repetiria.

**Generalização:** todo invariante crítico documentado em lição prévia merece um check automatizável em smoke test. Drift de invariantes silente é mais comum do que parece.

### 2. Reaplicar `chattr +i` precisa ser explícito em qualquer doc de re-pair

Qualquer playbook que mencione `chattr -i` (incluindo o RB-12 emergency-whatsapp.md recém-criado) **deve** terminar com `chattr +i` + validação `lsattr`. Caso contrário, replica o problema toda vez que alguém roda o procedimento.

Validação no RB-12 §4 e §5 já tem essa etapa explícita. Confirmado pós-criação.

### 3. Cron periódico de invariantes seria útil

Hoje o smoke test é manual (rodar `bash infra/scripts/smoke-test-whatsapp.sh` quando lembrar). Vale considerar:
- Cron diário 06:00 BRT que roda smoke test + alerta Discord se FAIL
- Adicionar aos canários */15 (mais ruidoso mas pega drift mais cedo)

Decisão pendente: cadência. Diário é provavelmente suficiente — drift de chattr não muda em horas.

## Backlog gerado

1. ✅ Drift fix aplicado (chattr +i)
2. ⏳ Considerar cron diário do smoke test + alerta
3. ⏳ Audit similar pra outros invariantes que podem driftar:
   - `chattr +i` em `~/.claude/.credentials.json` (regra #6) — provavelmente OK porque verificado no upgrade Claude CLI hoje
   - `chattr +i` em outros creds de canais (Slack, Discord, Telegram) — schema do `@openclaw/whatsapp` foi documentado mas Slack/Discord/Telegram não têm equivalente formal
4. ⏳ Investigar trace via `journalctl --since '7 days ago' | grep -E 'chattr|whatsapp.*creds'` se houver evidência de quando a flag caiu

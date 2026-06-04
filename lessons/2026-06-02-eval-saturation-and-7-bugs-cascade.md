---
chunk_type: lesson
source: internal
date: 2026-06-02
severity: medium
downtime_minutes: 0
tags: [openclaw, eval, recovery, cpu-steal, nox-mem-freeze, cron-d, sigusr1, haiku-alias, ollama-cleanup, heartbeat-sync, cron-timeout]
related_lessons: [2026-05-30-openclaw-5.27-upgrade-and-vec0-cli-recovery, 2026-05-31-external-plugins-phase7-and-discord-silent-success, 2026-05-24-upgrade-5.22-harness-restart-latency-and-plugin-config-env]
---

# 2026-06-02 — Eval saturou VPS, recovery + cascata de 7 bugs estruturais paralelos

## TL;DR

Sessão de 4h45 disparada por agents Discord/WhatsApp travados. Causa imediata: eval do memoria-nox consumindo 395% CPU + **62.7% steal time** do hypervisor Hostinger (noisy neighbor). Toto autorizou parar gateway até eval terminar; recovery descobriu 7 bugs distintos que estavam dormentes:

1. **nox-mem-api event-loop freeze silent** — service `active`, porta LISTEN, HTTP travado por 11h sem detecção
2. **Hostinger noisy neighbor 62.7% steal** — upgrade de vCPU não resolve, é host físico sobrecarregado
3. **`/etc/cron.d/config-backup` sem USER field** — cron daemon ignorou silenciosamente por 2 meses (zero backups)
4. **Haiku alias retired `claude-haiku-4-5`** em heartbeats → doctor migrava pra sonnet (caro)
5. **Alias dated `claude-haiku-4-5-20251001` não estava em `models.providers.anthropic.models`** → doctor não reconhecia
6. **Gateway DOWN false positive via SIGUSR1** — graceful restart via `gateway-tool` triggera systemd FAILURE → Discord alert
7. **Cipher `context-watchdog` cron timeout 120s** insuficiente pro cold start do claude-cli (cipher dormante 100% do tempo)

Bônus: Ollama removido 100% (binary, service, group, data dirs, entry openclaw.json), heartbeat-sync excluiu atlas+lex (agents passivos), fwupd-refresh.timer silenciado, lessons publicáveis.

VPS saiu com **0 doctor warnings**, 0 failed units, 67.051 chunks/0 orphans, todos canais conectados.

---

## Severidade & impacto

- **Downtime gateway:** ~14min (intencional, decisão do Toto pra liberar CPU pro eval)
- **Downtime nox-mem-api functional:** ~11h silencioso (active mas HTTP travado), descoberto durante recovery
- **Backups perdidos:** 2 meses de config-backup horário (zero arquivos gerados)
- **Custo:** ~$0 (haiku alias retired era cosmético, doctor não foi rodado com `--fix` no período)
- **Sinal externo:** semantic-canary detectou unreachable:18802 e mandou Discord a cada 30min desde 02:47 BRT

---

## Sintomas observados

### Sinal #1 — Agents Discord/WhatsApp param de responder (~17h BRT)

Toto reportou direto. Diagnóstico: gateway disputando CPU com eval (395% load), event loop atrasado. Não era crash, era starvation.

### Sinal #2 — Discord alert "memoria-nox healthcheck: VPS nox-mem unreachable" no Mac

Script `~/Claude/Projetos/memoria-nox/scripts/vps-healthcheck.sh` rodando `*/15min` no cron local do Mac. Disparou notification osascript com som Submarine. Era falso positivo *naquele momento* (script tinha fallback SSH tunnel via IP público), mas evidenciou que algo estava travado.

### Sinal #3 — Canary `semantic-canary.sh` alertando `unreachable:18802` há 11h

```
[2026-06-02 02:47:17] FAIL(2): unreachable:18802 (prev=unreachable:18802 age=1799s) — alertando Discord
[2026-06-02 03:17:18] FAIL(1): unreachable:18802 — aguardando confirmação (debounce 5400s)
[2026-06-02 03:47:17] FAIL(2): unreachable:18802 ...
... (a cada 30min)
```

Mas Discord webhook estava silenciado durante a janela do eval, então alertas não chegaram. Quando Toto liberou webhook, o backlog não foi reenviado.

---

## Sequência de eventos

| Hora BRT | Evento | Quem agiu |
|---|---|---|
| ~14h | Eval capstone iniciado, atinge 395% CPU | autônomo |
| ~02:47 | nox-mem-api event-loop trava (último `[vault-facts]` log) | --- |
| ~16h | Agents param de responder Discord/WhatsApp | Toto reporta |
| 17h15 | Stop gateway+warmup+watch, preservei nox-mem-api (eval usa) | Claude |
| 17h15 | 14 crons silenciados, Discord webhook comentado | Claude |
| ~17:53 | Toto religa gateway via SSH | Toto |
| 18h17 | Detect nox-mem-api freeze → restart | Claude |
| 18h23 | Migrar haiku alias dated nos 7 heartbeat slots | Claude |
| 18h30 | Ollama 100% removido (binary, service, group, data, config) | Claude |
| 19h22 | Fix config-backup cron.d (USER field) | Claude |
| 20h09 | **NOVO incident:** Forge invoca `gateway-tool restart` → SIGUSR1 → systemd FAILURE → health-probe alerta | autônomo |
| 20h10 | Health-probe restart automático em 4s | autônomo |
| 20h45 | Smart-silence patch em health-probe.sh (SIGUSR1 detection) | Claude |
| 20h55 | Análise pós-recovery descobre 3 bugs adicionais (haiku list, cipher timeout, atlas/lex passivos) | Claude |
| 21h00 | Add haiku dated em models.providers.anthropic.models → doctor zero output | Claude |
| 21h43 | Cipher cron timeout 120s→300s via CLI oficial | Claude |
| 21h44 | heartbeat-sync skip passive agents (PASSIVE_AGENTS="atlas lex") | Claude |
| 21h45 | fwupd-refresh.timer disabled (failed unit recorrente) | Claude |

---

## Bug A — nox-mem-api event-loop freeze silent

**Sintoma:**
- `systemctl is-active` → `active` (mascarado)
- Porta 18802 LISTEN (TCP handshake completa)
- `curl /api/health` → empty body, timeout >5s
- Último log `[vault-facts]` 11h atrás, depois silêncio
- Process vivo, PID estável, CPU baixo (~0%)

**Root cause hipótese:** event loop do Node.js travou em algum await/promise pendente, mas o socket TCP continua aceitando conexões via kernel — só não há ninguém pra processá-las.

**Fix imediato:** `systemctl restart nox-mem-api`. Resolve em <30s.

**Pendente (Tier 3+4):** healthcheck mais ativo no service unit:
```ini
[Service]
WatchdogSec=120
```
Requer código do nox-mem-api pingar `sd_notify("WATCHDOG=1")` em cada HTTP processing real. Sem isso, systemd só sabe que o process não morreu.

---

## Bug B — Hostinger noisy neighbor 62.7% steal

**Sintoma:** durante a sobrecarga, `vmstat 1 3` mostrou:
```
 r  b   swpd   free   buff   cache  ...  us sy id wa st gu
 0  0      0 20942924 447016 9604772  ...  2  0 33  1 64  0
```

`st 64%` = hypervisor está dando 64% do CPU pra outro tenant no mesmo host físico. Significa que do CPU contratado (após upgrade pra 8 vCPU), apenas ~35% estava efetivamente disponível.

**Não é problema seu** — é o KVM time-slicing entre VMs do host físico. Mitigação:

1. Esperar (steal flutua conforme vizinho)
2. Ticket Hostinger pedindo migração de host: "noisy neighbor on host XYZ, request VM migration"
3. Não escale vCPU pensando que vai resolver

**Detecção preventiva:** adicionar em `health-probe.sh`:
```bash
STEAL=$(vmstat 1 2 | tail -1 | awk '{print $17}')
[ "$STEAL" -gt 20 ] && warn_discord "CPU steal $STEAL% — noisy neighbor possivel"
```

---

## Bug C — `/etc/cron.d/config-backup` sem USER field

**Sintoma:** zero backups em `/root/.openclaw/backups/config-*.json` desde 31/mai 14:52 (~2 dias), apesar do file existir desde 01/abr. Bug paralelo já reportado em INCIDENTS.md 31/mai mas o "fix" aplicado (`systemctl restart cron`) foi placebo.

**Root cause:** files em `/etc/cron.d/` requerem **7 campos** (`min hour dom mon dow USER command`), o file tinha apenas 6. Cron daemon ignora silenciosamente — **sem warning, sem log, sem nada em `systemctl status cron`**.

```cron
# ANTES (6 fields, silenciado):
0 * * * * cp /root/.openclaw/openclaw.json ...

# DEPOIS (7 fields):
0 * * * * root cp /root/.openclaw/openclaw.json ...
```

**Lição genérica:** sempre validar `/etc/cron.d/*` com execução real após criar, NÃO confiar em syntax check. Auditar com:
```bash
for f in /etc/cron.d/*; do
  awk '!/^#/ && NF>0 && NF<7 {print FILENAME":"NR": "$0}' "$f"
done
```

---

## Bug D — Haiku alias retired `claude-haiku-4-5` em heartbeats

Em 6 agents (atlas, boris, cipher, forge, lex, nox) + `agents.defaults.heartbeat.model`, o model era `anthropic/claude-haiku-4-5` (alias retired). `openclaw doctor` queria migrar tudo pra `anthropic/claude-sonnet-4-6` (~10x mais caro).

**Fix:** trocar pra alias dated `anthropic/claude-haiku-4-5-20251001` em 7 lugares.

**Bug auxiliar durante o fix:** `jq "(.agents.list[]?.heartbeat.model) |= (...)"` **CRIA** sub-objeto `heartbeat: {model: null}` em agents que não tinham heartbeat (jq path assignment cria parents). Quebrou schema validation. Fix: `del(.heartbeat)` onde `model == null` (restaurou ausência original).

---

## Bug D2 — Alias dated não estava em `models.providers.anthropic.models`

Mesmo após Bug D corrigido, doctor continuava querendo migrar `claude-haiku-4-5-20251001` pra sonnet. Motivo: o dated alias não estava na lista canonical de models disponíveis em `models.providers.anthropic.models`, só o alias curto `claude-haiku-4-5`.

**Fix:**
```bash
jq '(.models.providers.anthropic.models) |= . + [{
  "id": "claude-haiku-4-5-20251001",
  "name": "Claude Haiku 4.5 (2025-10-01)",
  "contextWindow": 200000,
  "maxTokens": 8192
}]' /root/.openclaw/openclaw.json > /tmp/oc.json && mv /tmp/oc.json /root/.openclaw/openclaw.json
```

**Lição:** quando usar alias dated, garantir que esteja na lista de provider models. Doctor é strict: exige ID na lista canonical, não aceita "alias resolvable".

---

## Bug E — Gateway DOWN false positive via SIGUSR1

**Sequência (21s):**

1. Agent Forge chamou `gateway-tool restart` (reason: "context-watchdog: gathering agent session metrics")
2. Gateway recebeu SIGUSR1, shutdown limpo em 3.4s
3. systemd interpretou exit=1 como FAILURE
4. health-probe (cron `*/10min`) viu port DOWN → Discord alert + restart automático
5. Gateway voltou em 4s

**Histórico:** 10 restarts via `gateway-tool` em 7 dias (1.4/dia). Vai acontecer de novo sempre que algum agent invocar a tool legítima.

**Fix:** smart-silence em `health-probe.sh`:
```bash
if journalctl -u openclaw-gateway --since "90 seconds ago" | grep -q "SIGUSR1 received"; then
    log "INFO: Gateway DOWN coincide com SIGUSR1 — graceful restart em curso, aguardando 20s"
    sleep 20
    if ss -tlnp | grep -q ":18789"; then
        log "OK: Gateway port 18789 (recuperou apos SIGUSR1, sem alerta)"
        GW_UP=1
    fi
fi
```

**Trade-offs considerados:**
- B: `SuccessExitStatus=1` no service unit → rejeitado (mascararia crashes legítimos)
- C: educar Forge a não chamar a tool → rejeitado (não escala pra outros agents)

---

## Bug F — Cipher `context-watchdog` cron timeout 120s

Cron hourly `4e59b867-d715-4dfe-8b7c-cf278f6f78e4` (cipher: context-watchdog) timeout em **TODAS** as 6 execuções de hoje (durations 121-127s).

**Diagnóstico:** o script `context-check.sh` executa em **8 segundos** e retorna "OK" 99% das vezes. O timeout vinha do agent claude-cli demorar >120s pra processar a task trivial: cold start + bootstrap skills + TOOLS.md 14KB + LLM call.

**Fix:** `openclaw cron edit 4e59b867-... --timeout-seconds 300` (CLI oficial). Sintoma colateral resolvido: heartbeat-sync para de alertar cipher como dormente, porque HEARTBEAT.md volta a atualizar quando o cron completa.

**Padrão genérico** (criou memory file `cron-timeouts-cold-start-pattern.md`):
- Crons de agent (`sessionTarget: "isolated"`) **precisam ≥ 300s mínimo**
- Cold start sozinho consome 30-60s
- Tasks legacy com timeout 120s vão silentemente falhar até serem atualizadas

---

## Bug G — heartbeat-sync alerta atlas + lex (falso positivo)

Atlas e lex têm **0 crons registrados** (são agents passivos, só interagidos manualmente). heartbeat-sync vê `HEARTBEAT.md` >48h e alerta diariamente. Noise contínuo.

**Fix:** adicionar var no header de `heartbeat-sync.sh`:
```bash
PASSIVE_AGENTS="atlas lex"
...
for AGENT in nox atlas boris cipher forge lex; do
  ...
  if [[ " $PASSIVE_AGENTS " == *" $AGENT "* ]]; then
    log "SKIP: $AGENT (passive — sem cron registrado)"
    continue
  fi
```

**Quando atlas ou lex ganhar cron real:** remover do `PASSIVE_AGENTS`. Validável via `openclaw cron list | grep -E "agent.*atlas|agent.*lex"`.

---

## Cleanup secundário

### Ollama removido 100%

Toto: "nao uso pode limpar tudo a respeito do Ollama". Removido:
- Binary `/usr/local/bin/ollama`
- Unit `/etc/systemd/system/ollama.service` (backup em `backups/`)
- User `ollama` (uid=999) + group `ollama` (gid=989, após `gpasswd -d root ollama`)
- Data dirs (não existiam — Ollama nunca foi usado pra valer)
- `plugins.entries.ollama: {enabled: false}` em `openclaw.json`

`services.ollama: false` em `/api/health` agora é estado permanente esperado.

### fwupd-refresh.timer disabled

`fwupd-refresh.service` aparecia como failed unit recorrente. Irrelevante em VPS (firmware do hypervisor não atualiza). Silenciado com `systemctl stop + disable`. **0 failed units agora.**

### Throttle files antigos limpos

3 files em `/var/lib/nox-canary/notify-throttle/` >2d antigos (heartbeat-lex* + notify-discord-smoke) removidos.

---

## Lessons / regras genéricas

1. **`systemctl is-active` é insuficiente como healthcheck** — port-bound services podem estar `active` com event loop travado. Healthcheck real precisa HTTP request + verificar resposta.

2. **CPU steal > 20% = não é seu problema** — checar `vmstat` antes de assumir overload local. Hostinger pode ter noisy neighbor. Upgrade vCPU não resolve.

3. **`/etc/cron.d/` requer 7 campos** — bug silencioso, `systemctl restart cron` não detecta. Sempre validar com execução real e aguardar 1 ciclo.

4. **`jq path |= update` cria sub-objetos null** — usar `select` ou `if has(...) then ... else . end` explicitamente.

5. **Aliases retired vs dated em Anthropic models** — sempre usar dated suffix em config persistido AND garantir que o dated esteja em `models.providers.anthropic.models`. Doctor exige ID na lista canonical.

6. **Crons de agent precisam timeout ≥ 300s** — cold start do claude-cli sozinho consome 30-60s. 120s legacy é insuficiente pra tasks que envolvam LLM.

7. **`gateway-tool restart` é legítima ferramenta** — agents podem invocar pra refresh de state. Mas systemd interpreta SIGUSR1 como FAILURE → health-probe alerta. Smart-silence é a solução; mascarar exit=1 sistêmico não.

8. **Agents passivos (0 crons) não devem ser monitorados pelo heartbeat-sync** — alerta diário falso enche Discord. PASSIVE_AGENTS list resolve.

9. **Notification fatigue corrosivo** — quando Toto silenciou tudo durante o eval, ficamos cegos pra 11h de `unreachable:18802` real. Diferenciar "silenciar temporariamente" vs "esquecer de ligar de novo".

10. **Forge agent precisa de hard limits** (já documentado anteriormente) — mas se estende: TODOS os agents que invocam tools sistêmicas (`gateway-tool`, `cron edit`, etc) precisam de guidelines explícitas em `<agent>/TOOLS.md` sobre quando É ok vs quando NÃO É.

---

## Backups dessa sessão

```
/root/.openclaw/backups/silence-20260602-074039/                  (.env + crontab pre-silence)
/root/.openclaw/backups/crontab-pre-restore-20260602-181623.txt
/root/.openclaw/backups/openclaw.json.pre-haiku-rename-20260602-182318
/root/.openclaw/backups/openclaw.json.pre-null-fix-20260602-182526
/root/.openclaw/backups/openclaw.json.pre-ollama-cleanup-20260602-183050
/root/.openclaw/backups/openclaw.json.pre-haiku-dated-list-20260602-210036
/root/.openclaw/backups/ollama.service.bak-20260602-1829XX
/root/.openclaw/backups/etc-cron-d-config-backup.bak-20260602-192236
/root/.openclaw/backups/health-probe.sh.bak-pre-sigusr1-smart-20260602-204346
/root/.openclaw/backups/heartbeat-sync.sh.bak-pre-passive-skip-20260602-214431
```

---

## Estado final

| Métrica | Valor |
|---|---|
| Load 1min | 0.22 |
| RAM disponível | 29 GB / 32 GB (Toto upgraded 15→32GB durante a sessão) |
| CPU steal | 0% |
| Disk | 29% (111G / 387G) |
| Failed units | **0** |
| Doctor warnings | **0** |
| Channels (Discord/WhatsApp/Slack) | ✅ todos conectados |
| nox-mem | 67.051 chunks, 0 orphans, 100% vector coverage |
| Token Claude OAuth | válido até 2027-04-22 (323 dias) |
| Plugins externos | 5/5 em sync com gateway 5.27 |
| Config-backup hourly | ✅ rodando (validado 20:00 + 21:00) |

---

## Pendências

- **#16** — desligar `keepalive-harness` + `openclaw-warmup` se 5.27 estabilizar limpo (defer ~6/jun)
- **Tier 3+4 evolução:**
  1. Healthcheck mais ativo nox-mem-api (`WatchdogSec=` ou external `/api/health` polling)
  2. Dashboard único de canários
  3. Migrar cron → systemd timers (OnFailure handlers, journalctl nativo)
  4. Prometheus + Grafana
  5. auditd file watch em `openclaw.json`
- **`memoria-nox` repo** (fora escopo openclaw-vps):
  - gitleaks 21 falsos positivos (privacy patterns lib) → `.gitleaks.toml` allowlist
  - npm audit ignorando `--audit-level=high` em algum `staged-*`

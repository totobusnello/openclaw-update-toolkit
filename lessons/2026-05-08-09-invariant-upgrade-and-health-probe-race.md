# Lesson — Invariant alerter upgrade + health-probe race + memory leak triage

> Date: 2026-05-08 11:00 BRT → 2026-05-09 19:40 BRT (~30h, sessão única)
> Owner: Toto + Claude session
> Trigger: alert "⚠️ nox-mem schema invariant failed: 1 ops_audit zombie running >60min — last: ocr-batch-cloud pid=709224"

## OUTCOME

✅ **3 fixes deployados** + 1 investigação consolidada:

1. **Invariant alerter** (`check-schema-invariants.sh`) — split em zombie_real vs pending_reap, threshold 60→90min. Falsos positivos de 1-2min eliminados. Threshold env-overridable (`NOX_ZOMBIE_THRESHOLD_MIN`, `NOX_ZOMBIE_REAP_GRACE_MIN`).

2. **Crontab tuning** — `bvv-extract.py` movido de `*/15` (pico simultâneo no :00) pra `3,18,33,48`. `token-refresh-max.sh` dead line removida. Crontab espelhada em `infra/cron/crontab.txt` (cobertura do gap "perda 2026-05-04 13:29 incident").

3. **Health-probe race** (`/api/health` heavy → restart espúrio) — novo endpoint `/api/health/lite` zero-DB, 0.6-1.2 ms latency (vs 425-572 ms do `/api/health`). Health-probe aponta pra `/lite` + timeout 3→5s.

4. **Memory leak nox-mem-api** — investigação completa, 2 patches falharam. Causa raiz isolada: `onnxruntime-node` arena leak não exposto via API JS de @xenova/transformers v2.17.2. Mitigação atual: `NOX_RERANKER_MODE=off`. Reabertura em sessão paralela com bge-reranker-v2-m3 (D01-v2).

⚠️ Pendente: cron preventivo `27 1,4,7,10,13,16,19,22 * * *` com health-probe novo + reranker off provavelmente desnecessário; remoção pendente decisão Toto.

## Hipótese inicial vs realidade

| Item | Hipótese | Realidade |
|---|---|---|
| Alert "zombie running >60min" | Processo travado de verdade | **Falso positivo race**: pid 709224 morreu por kill manual; ops_audit row demorou 1m38s pra `crashed` enquanto alerter já tinha disparado |
| Bump 3 + cron preventivo 3h "resolvia" mem leak | Workaround suficiente | **Restarts mais frequentes que 3h**: health-probe restartando a API toda vez que `/api/health` passava de 3s (lock contention com canary-bundle). Cron preventivo nunca chegava a rodar — mascarava sintoma |
| Tensor.dispose() resolve leak | API @xenova/transformers tem `.dispose()` em tensors | **Falso**: em v2.17.2 só `Pipeline` e `Model` têm `.dispose()`. `Tensor` e `BatchEncoding` não. Try/catch comeu no-op |
| Model.dispose() periódico mitiga | Liberar InferenceSession libera arenas | **Falso**: `Model.dispose()` chama `handler.dispose()` em cada `InferenceSession`, mas as arenas globais do onnxruntime-node permanecem alocadas. Sem GC público pra elas |

**Lição central:** quando 2/3 patches em userland falham com mesmo padrão, o problema está abaixo da camada que você consegue patchar. Próxima tentativa = trocar de camada (sidecar Python, modelo diferente, lib diferente), não mais um patch.

## Incidente 10 (P3) — Falso positivo do invariant alerter

**Sintoma:** Discord alert disparou às 11:00:01 BRT informando 1 zombie ops_audit row >60min. Mas pid 709224 já não existia no `ps`.

**Investigação (em ordem de descoberta):**

1. `crontab -l | grep invariant` retornou vazio — pareceu fantasma.
2. Mais grep amplo achou caller real: `*/15 * * * * /root/.openclaw/scripts/canary-bundle-15min.sh` que invoca 3 canaries em sequência (gateway-drift + monkey-patch + schema-invariants). Bundle existe pra reduzir starts/day de 288 → 96 e unificar logging via `logger -t nox-canary-bundle`.
3. Greps em /etc/cron.d, anacron, systemd timers todos vazios. Indireção do bundle me cegou — keyword "invariant" não está no nome do script chamado pelo cron.
4. Row 45 da `ops_audit` confirmou: pid 709224, status=`crashed`, started_at=12:50:35 UTC, finished_at=14:02:13 UTC, error="killed mid-batch by user choice B (skip architectural + VERRE>25MB)". Crash handler tomou 1m38s pra atualizar status — alerter rodou nesse intervalo.

**Root cause:** race entre alert window (60min, cron */15) e reap window (post-kill cleanup ~1-2min).

**Fix deployado** (`check-schema-invariants.sh`):

```bash
# Split em zombie_real vs pending_reap
ZOMBIE_ROWS=$(q "SELECT id || '|' || COALESCE(pid,0) || '|' || age_sec || '|' || op_name FROM ops_audit WHERE status='running' AND started_at < datetime('now', '-${ZOMBIE_THRESHOLD_MIN} minutes') ...")
while IFS='|' read -r z_id z_pid z_age_sec z_op_name; do
    pid_alive=0
    [ "${z_pid:-0}" -gt 0 ] && kill -0 "$z_pid" 2>/dev/null && pid_alive=1
    if [ "$pid_alive" -eq 1 ]; then
        # zombie_real(alive) — Discord alert
    elif [ "$z_age_sec" -gt $((THRESHOLD_SEC + GRACE_SEC)) ]; then
        # zombie_real(dead+postgrace) — reaper failed → Discord alert
    else
        # pending_reap — log only, sem alert
    fi
done <<< "$ZOMBIE_ROWS"
```

Threshold default 60→90min (batches OCR legítimos passam de 1h). Grace window 5min cobre kill manual + crash handler.

**Validação em prod:** alert real disparou 2026-05-08 13:25 BRT pra pid 718998 alive >90min ("stuck >90min" — texto novo), classificação correta. Confirma que pending_reap suprime falsos positivos sem perder zombies reais.

Backups VPS:
- `/root/.openclaw/scripts/check-schema-invariants.sh.bak-pre-pending-reap-20260508`
- Cron entry inalterada (já passava env vars do .env via `set -a; . .env; set +a`).

Commits: `ace1cd0` (fix lógica) + `677735c` (header + chain mirror).

## Incidente 11 (P2) — Health-probe race causando restarts espúrios

**Sintoma:** observado durante teste do plan B (disable reranker) — API restartou 4× em 1.5h sem motivo aparente. Log `/var/log/nox-health.log` mostrou `WARN: nox-mem API not responding on 18802, restarting` em :00 e :30 alternadamente.

**Investigação:**

```bash
# /api/health full latency (manual, sem load)
$ curl -w "%{time_total}\n" http://127.0.0.1:18802/api/health
0.572013s
0.485808s
0.425940s

# health-probe.sh:56 — timeout 3s
if curl -sf --max-time 3 "http://127.0.0.1:${NOX_API_PORT:-18802}/api/health"
```

**Root cause:** `/api/health` faz ~8 queries SQLite (`COUNT(*) FROM chunks`, `GROUP BY chunk_type`, `consolidated_files`, `vec_chunk_map INNER JOIN chunks`, `getKgStats` = entities + relations, `getOpAuditStats`). Em momentos de lock contention com `canary-bundle-15min.sh` (também */15min lendo `chunks` para schema-invariants), passava de 3s. Health-probe assume morto → restart.

Coincidência exata: WARN nos cron times :00, :30, :00, :30 (múltiplos de 15 onde canary-bundle roda). Em :10, :20, :40, :50 (entre canary runs) sempre OK.

**Fix deployado** (`api-server.ts` + `health-probe.sh`):

```typescript
// api-server.ts — novo case ANTES de /api/health
case "/api/health/lite": {
  json(res, { ok: true, ts: new Date().toISOString(), pid: process.pid });
  return;
}
```

```bash
# health-probe.sh — apontar pro lite + timeout 3→5s
if curl -sf --max-time 5 "http://127.0.0.1:${NOX_API_PORT:-18802}/api/health/lite"
```

**Benchmark pós-deploy:**

| | /api/health | /api/health/lite |
|---|---|---|
| t1 | 572 ms | 1.2 ms |
| t2 | 486 ms | 0.7 ms |
| t3 | 426 ms | 0.6 ms |

**~500x mais rápido** + zero queries DB → impossível ter race. /api/health full continua disponível pra dashboards/morning-report.

Backups VPS:
- `/root/.openclaw/workspace/tools/nox-mem/src/api-server.ts.bak-pre-lite-20260509`
- `/root/.openclaw/scripts/health-probe.sh.bak-pre-lite-20260509`

Commit: `c4a616b`.

## Incidente 12 (P2 → escalado) — Memory leak nox-mem-api: investigação consolidada

**Sintoma observado em sessão anterior (2026-05-08 manhã):** bump 2 (MemoryHigh=2400M) saturou em 14h, leak confirmado (+700MB / 90min). Bump 3 (3000M/3500M) + cron preventivo restart `27 1,4,7,10,13,16,19,22 * * *` foi a mitigação inicial.

**Plan B (disable reranker) — confirmou hipótese:**

| Cenário | Uptime | Memory peak |
|---|---|---|
| Com reranker shadow (hoje cedo) | 30-90min | 2.3-2.9 GB |
| Sem reranker (12:04→12:20) | 16min | **101 MB** |
| Sem reranker (12:20→12:30) | 10min | **50.7 MB** |

Redução de **~95%**. Reranker = vilão sem dúvida.

**Plan C-v1 (dispose tensors) — falhou:**

```typescript
function disposeTensors(obj: any): void {
  if (typeof obj.dispose === "function") obj.dispose();
  for (const k in obj) {
    if (obj[k] && typeof obj[k].dispose === "function") obj[k].dispose();
  }
}
// no fn singleton:
} finally {
  disposeTensors(encoded);
  disposeTensors(out);
}
```

Resultado: RSS 2.6 GB em 18min — mesmo nível do leak original. **Causa do fail:** em `@xenova/transformers v2.17.2`, `Tensor` e `BatchEncoding` não têm método `.dispose()`. Só `Pipeline.dispose()` e `Model.dispose()` existem (confirmado em `node_modules/@xenova/transformers/src/{pipelines.js:178, models.js:709}`). Try/catch comeu silenciosamente.

**Plan C-v2 (Model.dispose() periódico) — falhou:**

```typescript
async function maybeReloadModel(): Promise<void> {
  if (callCount < everyN) return;
  const oldModel = cachedModel;
  cachedFn = null; cachedModel = null; callCount = 0;
  if (oldModel?.dispose) await oldModel.dispose();
}
// no fn:
callCount++;
void maybeReloadModel();
```

Resultado: RSS plateau de 1.33 GB de t+5 a t+15min, depois disparou pra 2.63 GB em t+20min. **Causa do fail:** `Model.dispose()` itera sessions e chama `handler.dispose()` (libera InferenceSession), mas as arenas globais do `onnxruntime-node` permanecem alocadas. ONNX Runtime native code não expõe API JS pra GC dessas arenas.

**Conclusão:** leak está abaixo da camada userland. Próximas opções viáveis (em ordem de probabilidade de funcionar):

| # | Abordagem | Esforço | Probabilidade |
|---|---|---|---|
| 1 | Manter `RERANKER_MODE=off` (perde lift D01) | 0 | 100% (status quo) |
| 5 | Sidecar Python (`fastapi` + `onnxruntime`) | 1 dia | alta (Python ONNX libera arenas via `del` + GC) |
| 4 | Migrar `@huggingface/transformers` v3 (sucessor) | 4-8h | média (pode ter mesmo bug) |
| 6 | Modelo lite (TF-IDF rerank ou sem ONNX) | 2-4h | alta (sem ONNX = sem leak) |

**Estado de produção pós-investigação:**
- `.env`: `NOX_RERANKER_MODE=off` (sem leak)
- Source `reranker.ts`: revertido pra clean state via commit paralelo `2c5bae0` (em `nox-workspace.git`, repo separado deste — confirmar fetch após push)
- bump 3 (`MemoryHigh=3000M, MemoryMax=3500M`) intacto — não custa, é defesa em profundidade
- cron preventivo (`27 1,4,7,10,13,16,19,22`) intacto — pode ser removido com health-probe novo + reranker off (nunca dispara MemoryMax sem reranker)

**D01-v2 em andamento (sessão paralela):** Toto está testando `onnx-community/bge-reranker-v2-m3-ONNX` (multilingual, 568M params, suporte explícito PT-BR). Eval 3-run × 60 queries em tmux `d01v2-eval`. Wake-up 2026-05-09 19:56 BRT.

⚠️ **Risco técnico apontado pra D01-v2:** v2-m3 é ~2x maior (568M vs 280M base). Mesmo backend onnxruntime-node = mesmo padrão de arena leak, **proporcional ao tamanho do modelo**. Se ACTIVATE com lift +0.03, leak provável ~3-4 GB / 1h em prod. Critério de mem trend deveria entrar na decision matrix além do nDCG.

## Crontab tuning paralelo

Durante investigação, 2 oportunidades observadas e aplicadas:

1. **Pico simultâneo no :00**: `*/15 * * * * canary-bundle-15min.sh` + `*/15 * * * * bvv-extract.py` rodavam ambos no segundo zero do :00 (junto com `system-health-watchdog` e `config-backup`). Movido `bvv-extract` pra `3,18,33,48 * * * *` (offset +3min).

2. **`token-refresh-max.sh` linha morta**: já estava DISABLED em comentário (`#0 */4 * * *`); removida, comentário explicativo preservado.

3. **Crontab espelhada em `infra/cron/crontab.txt`** — cobre o gap de "crontab perda 2026-05-04 13:29 incident" referenciado no header da própria crontab.

Commit: `6ac271e`.

## Backlog gerado

- [ ] **F13**: avaliar remoção do cron preventivo `27 1,4,7,10,13,16,19,22 * * *` agora que health-probe não restarta espúrio + reranker está off. Sem leak ativo + sem race do health-probe = restart preventivo perde justificativa.
- [ ] **F14**: D01-v2 com bge-reranker-v2-m3 — capturar mem trend no eval, não só nDCG. Se ACTIVATE, considerar bumpar MemoryHigh OU restart preventivo a cada 1-2h (mais agressivo que 3h, modelo 2x maior).
- [ ] **F15**: investigar lift `/api/health` queries — `vec_chunk_map INNER JOIN chunks` + `getKgStats` + `getOpAuditStats` somam ~400ms cold. Se outros clients usam `/api/health` (não só health-probe), vale split em endpoints específicos (`/api/stats/chunks`, `/api/stats/kg`).
- [ ] **F16**: bug latente reportado em D01-v1 retro: tokenizer também aloca em ONNX em alguns modelos — confirmar se `tokenizer(...)` em @xenova vaza igual model. Pra D01-v2 com 568M, tokenizer pode ser parte do problema.

## Lições

1. **Indireção em cron mascara debug**: `*/15 * * * * canary-bundle-15min.sh` invoca 3 canaries internamente. `crontab -l | grep invariant` retorna vazio. Sempre que um cron job parece "fantasma", grep pelo nome do script invocado e suba a árvore (canary → bundle → cron entry).

2. **Race entre alert window e reap window é sintoma de threshold mal calibrado**: alerter checava em 60min, reaper só agia em 6h. Janela de 5h59min vivendo com possíveis falsos positivos. Solução: pid_alive check + grace window curto (5min) → silencia false positive sem perder zombies reais.

3. **Endpoint /health com queries pesadas é tiro no pé**: liveness check deve ser zero-DB. Stats separados em endpoint dedicado. Race com outros readers do mesmo DB = restart espúrio garantido sob carga.

4. **`.dispose()` defensivo com try/catch silencioso esconde no-op**: se você não confirma via grep que o método existe na lib em uso, qualquer fallback (`if typeof === 'function'`) silencia falha de design. Em libs com ONNX/native code, sempre verificar explicitamente antes de assumir API.

5. **2 patches userland falhando mesmo padrão = subir uma camada**: insistir em uma terceira tentativa de userland é waste. Próximo move = sidecar process (Python/outro), modelo diferente, ou abandonar feature. Toto cortou rápido após C-v2 — boa decisão executiva.

6. **Modelo 2x maior = leak proporcionalmente pior**: óbvio em retrospecto. Antes de migrar pra modelo maior na mesma stack que vaza, verificar se a stack (onnxruntime-node) é o problema. Se for, modelo maior só acelera o saturation.

## Files tocados

**Source-of-truth no VPS:**
- `/root/.openclaw/scripts/check-schema-invariants.sh` (mudança 1 + 2)
- `/root/.openclaw/scripts/health-probe.sh` (mudança 3)
- `/root/.openclaw/workspace/tools/nox-mem/src/api-server.ts` (mudança 3 — endpoint novo)
- `/root/.openclaw/workspace/tools/nox-mem/src/lib/reranker.ts` (mudanças C-v1 + C-v2 → revertido em commit paralelo `2c5bae0`)
- `/var/spool/cron/crontabs/root` (tuning bvv + token-refresh remove)

**Espelhos local em `openclaw-vps`:**
- `infra/scripts/check-schema-invariants.sh` (commit `ace1cd0` + `677735c`)
- `infra/scripts/canary-bundle-15min.sh` (`677735c` — chain completa)
- `infra/scripts/gateway-drift-check.sh` (`677735c`)
- `infra/scripts/health-probe.sh` (`c4a616b`)
- `infra/src/nox-mem/api-server.ts` (`c4a616b` — snapshot)
- `infra/cron/crontab.txt` (`6ac271e`)

**Backups VPS pré-mudanças** (todos preservados):
- `check-schema-invariants.sh.bak-pre-pending-reap-20260508`
- `.env.bak-pre-reranker-off-20260508-1158` (e variantes timestamped)
- `api-server.ts.bak-pre-lite-20260509`
- `health-probe.sh.bak-pre-lite-20260509`

## Commits desta sessão (`openclaw-vps` repo)

```
c4a616b fix(health): /api/health/lite endpoint elimina restart espúrio do health-probe
6ac271e chore(cron): bvv-extract offset + remove token-refresh dead line + mirror crontab
677735c chore(invariant): cosmetic header + espelhar canary chain completa
ace1cd0 fix(invariant): pending_reap state + threshold 60→90min
```

Todos em `main`, 12 commits ahead of `origin/main` no momento desta lesson.

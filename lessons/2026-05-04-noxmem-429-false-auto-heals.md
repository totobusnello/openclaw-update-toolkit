# 2026-05-04 — Falsos auto-heals do nox-mem eram 429 sem retry no single-embed

## TL;DR

Canary semantic disparava "auto-healed" 5×/dia em horários alinhados com cron `*/30`. Hipótese inicial: processo dropping sem supervisor. Realidade: `nox-mem-api` ficou up o dia inteiro (NRestarts=0). 429 transitório do Gemini batia em `geminiEmbedQuery` que não tinha retry — só `embedBatchAPI` tinha. Fix: adicionar `fetchWithRetry` (1s/2s/4s backoff) nos single-embed paths + reduzir cron canary 48→4/dia + cleanup logrotate.

## Contexto

`semantic-canary.sh` (cron `*/30`) chama `/api/search` com query PT-BR fixa, espera ≥1 resultado com `match_type=semantic`. Falha → invoca `nox-mem vectorize` (rebuild full) → recovery message no Discord.

Toto via "5 auto-heals" = 5 mensagens Discord = 5 falsos crashes do processo.

## Detecção do problema real

Sequência de batch reads que matou cada hipótese:

| Hipótese | Como descartada |
|---|---|
| Sem supervisor | `nox-mem-api.service` enabled/running, `Restart=on-failure`, `RestartSec=10` |
| Crashing | `NRestarts=0`, journal sem `Stopped/Started` no intervalo |
| OOM | `journalctl -k --since=48h | grep -i oom` vazio, dmesg limpo |
| Rate limit do Gemini paid | Live test: 1 embed = HTTP 200 752ms, burst 30/30 = 200 |
| Quota free tier | Billing ativo confirmado via project response do API |

Achado real: journal mostrou `Gemini embed query failed: 429 Resource exhausted` exatamente nos slots, **mesmo PID** o dia inteiro.

## Causa raiz

`src/embed.ts` tinha 2 paths:

- `embedBatchAPI` (vectorize/ingest) → retry+backoff `2^n * 1000ms` em 429/5xx, 4 tentativas ✓
- `geminiEmbed` / `geminiEmbedQuery` (single-embed via `embedText`, usado por `/api/search`) → **fetch direto sem retry** ✗

Convergência transitória de 8 crons em slots `:00`/`:30` + chamadas internas (vectorize/ingest/crystallize) estourava RPM/TPM por segundo. Batch path absorvia, single-embed vazava direto pra WARN do canary.

## Fix

### Patch `src/embed.ts` (memoria-nox)

Helper `fetchWithRetry(url, init, label, maxAttempts=4)`:

```typescript
async function fetchWithRetry(url, init, label, maxAttempts = 4) {
  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    const resp = await fetch(url, init);
    if (resp.ok) return resp;
    if (resp.status !== 429 && resp.status < 500) return resp;  // hard 4xx → no retry

    // Forensic logging
    const fhdrs = {};
    resp.headers.forEach((v, k) => {
      const kl = k.toLowerCase();
      if (kl.includes("retry") || kl.includes("quota") || kl.includes("rate")) fhdrs[k] = v;
    });
    const body = (await resp.text()).slice(0, 500);

    if (attempt === maxAttempts - 1) {
      console.error(`[EMBED:${label}] ${resp.status} after ${maxAttempts} attempts. headers=${JSON.stringify(fhdrs)} body=${body}`);
      return new Response(body, { status: resp.status, headers: resp.headers });
    }

    const backoff = 1000 * Math.pow(2, attempt);
    console.error(`[EMBED:${label}] ${resp.status} attempt=${attempt+1}/${maxAttempts} ... retry in ${backoff}ms`);
    await new Promise(r => setTimeout(r, backoff));
  }
}
```

`geminiEmbed` e `geminiEmbedQuery` refatorados pra delegar pro helper com label `embedDoc`/`embedQuery`. Rebuild `npm run build`. Restart serviço.

### Cron

```diff
-*/30 * * * * /root/.openclaw/scripts/semantic-canary.sh >> /var/log/nox-canary.log 2>&1
+0 */6 * * * /root/.openclaw/scripts/semantic-canary.sh >> /var/log/nox-canary.log 2>&1
```

### logrotate

`/etc/logrotate.d/openclaw` tinha `*.log` glob conflitando com path explícito em `/etc/logrotate.d/nox`. Removida glob; `logrotate -f` rodou clean; `systemctl reset-failed logrotate.service`.

### systemd drop-in

`/etc/systemd/system/nox-mem-api.service.d/limits.conf`:

```ini
[Service]
MemoryHigh=1500M
MemoryMax=2G
TimeoutStopSec=20
StartLimitInterval=60s
StartLimitBurst=5
```

## Lições generalizáveis

1. **Symmetry de retry policy entre call paths.** Se batch tem retry e single não tem, single será o canário do bug — mas com um sintoma desnorteador ("processo crashando").
2. **Diagnóstico read-only antes de fix.** "Sem supervisor" foi 100% errado. 5 minutos de read-only economizaram horas em pm2/supervisord.
3. **Canary não pode ser cacheado.** Cache anula propósito (detectar regressão real). Reduzir frequência sim, cachear não.
4. **Self-heal precisa ser proporcional ao gatilho.** Single 429 transitório não justifica vectorize full. Retry-backoff cobre 99% dos casos antes do canary nem perceber.
5. **Forensic logging em retry exhaustion.** Quando o backoff esgotar, logar headers + body é a diferença entre "Gemini deu 429" e saber se é tier issue, model cap, project mismatch ou outro.
6. **Convergência de crons sobrepostos é uma forma de carga oculta.** 8 jobs em slots `:00`/`:30` parecem inofensivos individualmente; juntos saturam RPM por segundo.

## Validação

- `bash semantic-canary.sh` → RC=0, `OK: total=10 semantic=8 fts=2 orphans=0`
- `grep -c fetchWithRetry dist/embed.js` = 3
- `systemctl show nox-mem-api | grep Memory` confirma high=1.5G max=2G
- `systemctl --failed` sem `logrotate`

## Invariante novo

Pós qualquer rebuild de nox-mem: `grep -c "fetchWithRetry" /root/.openclaw/workspace/tools/nox-mem/dist/embed.js` deve retornar ≥ 3. Se cair pra 0 = patch perdido em rebuild de versão antiga.

## Arquivos tocados

| Path | Tipo | Backup |
|---|---|---|
| `/root/.openclaw/workspace/tools/nox-mem/src/embed.ts` | edit (+86 -34) | `/tmp/embed.ts.bak-pre-retry-20260504-081443` |
| `/root/.openclaw/workspace/tools/nox-mem/dist/embed.js` | rebuild via `tsc` | — |
| crontab linha canary | edit | `/tmp/crontab.bak-20260504-08*` |
| `/etc/logrotate.d/openclaw` | edit (-1 linha) | `/tmp/logrotate-openclaw.bak-20260504-08*` |
| `/etc/systemd/system/nox-mem-api.service.d/limits.conf` | NEW | — |

## Refs

- Incident detalhe: `infra/docs/INCIDENTS.md` entrada 2026-05-04
- Memoria-nox source patch: `src/embed.ts` (memoria-nox repo, mas live na VPS em `/root/.openclaw/workspace/tools/nox-mem/`)

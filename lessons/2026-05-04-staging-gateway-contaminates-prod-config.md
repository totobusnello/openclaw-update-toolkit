# 2026-05-04 — Staging gateway do `upgrade-zero-downtime.sh` contamina production config

## TL;DR

Phase 1 do `upgrade-zero-downtime.sh` sobe um staging gateway com `OPENCLAW_WORKSPACE=/tmp/openclaw-staging-workspace` esperando isolamento. Durante dry-run de 5.2 → 5.3 descobriu-se que o staging gateway **escreve em `/root/.openclaw/openclaw.json`** (path hardcoded), não no workspace isolado. Contaminações observadas no dry-run: `lastTouchedVersion=2026.5.3` e plugin `duckduckgo` auto-onboardado em `plugins.entries` + `plugins.allow`. Production binary continuou 5.2, mas config layout foi tocado. Fix: `chattr +i` no openclaw.json antes do staging + SHA snapshot + trap EXIT pra unlock+restore. Cobertura: dry-run e real-run, idempotente, salva produção mesmo em erro do orchestrator.

## Contexto

`upgrade-zero-downtime.sh` Phase 1 (`[1d]`):

```bash
systemd-run --unit=openclaw-staging \
  --property=Environment=IS_SANDBOX=1 \
  --property=Environment=OPENCLAW_WORKSPACE="$STAGING_WORKSPACE" \
  --property=EnvironmentFile=/root/.openclaw/.env \
  -- node "$STAGING_MODULES/node_modules/openclaw/dist/index.js" \
       gateway run --bind loopback --port "$STAGING_PORT"
```

Intenção: staging lê e grava em `/tmp/openclaw-staging-workspace/`. Realidade: staging gateway tem path canonical `/root/.openclaw/openclaw.json` codado em algum lugar do dist, e auto-rewrite de metadata (`lastTouchedVersion`, `lastTouchedAt`) + auto-onboarding de plugins (ex.: `duckduckgo`) escrevem no production config independente de `OPENCLAW_WORKSPACE`.

## Sintomas observados

Após dry-run inicial (sem proteção):

```diff
3,4c3,4
< "lastTouchedVersion": "2026.5.2",
< "lastTouchedAt": "2026-05-03T21:06:47.373Z"
> "lastTouchedVersion": "2026.5.3",
> "lastTouchedAt": "2026-05-04T11:35:34.570Z"
1049a1050,1052
> "duckduckgo": { "enabled": true }
1071c1074,1075
< "whatsapp"
> "whatsapp",
> "duckduckgo"
```

E ao consultar via CLI 5.2 production:

```
Config was last written by a newer OpenClaw (2026.5.3); current version is 2026.5.2.
```

Production binary intocado, mas config diz que foi escrito por versão futura. Em outras versões, contaminação poderia mexer em items críticos (auth profiles, providers, fallback chain).

## Causa raiz

`OPENCLAW_WORKSPACE` env var **não isola** o config canonical do gateway. Há paths hardcoded ou defaults que apontam pra `/root/.openclaw/openclaw.json` mesmo quando workspace está em outro lugar. Especificamente:

1. `plugin auto-enable` persistence
2. `lastTouchedVersion` metadata rewrite no startup
3. Possivelmente outros writes de state durante runtime

## Fix aplicado em `upgrade-zero-downtime.sh`

### 1. SHA snapshot + chattr lock antes do staging

```bash
# Phase 0z — depois de [0j], antes de Phase 1
echo "[0z] Pre-staging config snapshot + lock..."
CONFIG_SHA_PRE=$(sha256sum /root/.openclaw/openclaw.json | awk '{print $1}')
cp /root/.openclaw/openclaw.json "$BACKUP_DIR/openclaw.json.pre-staging"
chattr +i /root/.openclaw/openclaw.json
echo "    chattr +i applied — production config locked during staging"
```

### 2. Função idempotente unlock+restore

```bash
CONFIG_UNLOCK_DONE=0
unlock_and_restore_config() {
  [[ "$CONFIG_UNLOCK_DONE" == "1" ]] && return 0
  systemctl stop openclaw-staging 2>/dev/null || true
  if lsattr /root/.openclaw/openclaw.json 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
    chattr -i /root/.openclaw/openclaw.json 2>/dev/null || true
  fi
  local sha_post
  sha_post=$(sha256sum /root/.openclaw/openclaw.json | awk '{print $1}')
  if [[ "$CONFIG_SHA_PRE" != "$sha_post" ]]; then
    echo "    WARN: config SHA drifted ($CONFIG_SHA_PRE → $sha_post) — restoring"
    cp "$BACKUP_DIR/openclaw.json.pre-staging" /root/.openclaw/openclaw.json
  fi
  CONFIG_UNLOCK_DONE=1
}
trap 'unlock_and_restore_config' EXIT
```

### 3. Manual unlock após Phase 2

Antes do gate dry-run e antes da Phase 3 atomic swap, unlock manual:

```bash
unlock_and_restore_config   # idempotente; trap continua como safety net
```

## Por que essa abordagem

| Solução | Porque NÃO foi escolhida |
|---|---|
| Trocar env var pra outro nome | Não há doc clara de qual var isola tudo; risco de regressão entre versões |
| Bind mount /root/.openclaw em namespace | Complexidade alta; systemd-run não suporta facilmente |
| Apagar e recriar config após dry-run | Race conditions; perda em caso de erro entre apagar e restaurar |
| **chattr +i + SHA snapshot + trap** ✅ | Defesa em profundidade (lock impede write; SHA detecta vazamento; trap garante unlock mesmo em erro) |

## Validação empírica

Re-dry-run com patch ativo:

```
[0z] Pre-staging config snapshot + lock...
    sha256 pre-staging: 537fd8d13468b94c47a86c2d1ab8685e37e01b0df32a78f223892dd345f2a51a
    chattr +i applied — production config locked during staging
...
━━━ PHASE 2: SMOKE TESTS ━━━
    PASS  health endpoint
    PASS  version match
    PASS  plugin load (no real errors; EPERM-on-config is expected during isolation)
    PASS  monkey-patch marker in staging dist
    PASS  IS_SANDBOX=1 in staging env
    PASS  production gateway still running
[2] ALL SMOKE TESTS PASSED — staging GREEN

━━━ CLEANUP: unlock + verify production config ━━━
    chattr -i removed from production config
    production config SHA intact — no restore needed
```

Staging gateway tentou escrever — falhou silenciosamente com `EPERM` (esperado). Production SHA inalterada. Cleanup automático no exit.

## Side effect controlado: smoke test 2d

O auto-enable persistence error aparece em journal:

```
[gateway] failed to persist plugin auto-enable changes:
  Error: EPERM: operation not permitted, copyfile '...openclaw.json.tmp' -> '/root/.openclaw/openclaw.json'
```

Smoke test "plugin load" original pegava esse erro como FAIL. Filtro adicionado:

```bash
grep -v "failed to persist plugin auto-enable" | grep -v "EPERM.*openclaw.json"
```

## Lições generalizáveis

1. **`OPENCLAW_WORKSPACE` env var não garante isolamento total.** Provavelmente outras vars (`HOME`, `XDG_CONFIG_HOME`, ou paths hardcoded) precisam de override coordenado pra real isolation. Investigar em release futura.
2. **Staging em production OS sempre tem risco de cross-pollination via paths canonical.** Defesa em profundidade obrigatória antes de assumir isolamento.
3. **`chattr +i` é uma ferramenta poderosa pra freeze de config durante operações sensíveis.** Combina bem com trap EXIT pra cleanup garantido.
4. **SHA snapshot é a verificação final**: mesmo com `chattr +i`, validar que o file não mudou via SHA é defesa contra bugs nossos (alguém esquece de aplicar lock, nova versão ignora attribute, etc).
5. **Trap EXIT idempotente é o canivete suíço de safety nets em scripts.** Evita estado inconsistente em qualquer caminho de saída.
6. **Dry-run de upgrade real precisa ser TÃO seguro quanto produção continuar funcionando.** Se dry-run pode contaminar, ele falha o teste de "dry".

## Arquivos tocados

- `infra/scripts/upgrade-zero-downtime.sh` (+50 linhas Phase 0z + função + trap + manual call + smoke filter)
- `/root/upgrade-zero-downtime.sh` na VPS (sync)

## Refs

- Lesson companion: `2026-05-03-openclaw-v5.2-upgrade-pitfalls.md` (3 pitfalls da 5.2 que motivaram patches do orchestrator)
- Incident: `infra/docs/INCIDENTS.md` entrada 2026-05-04
- TODO: investigar com upstream qual env var ou config flag isola REALMENTE o gateway de production paths

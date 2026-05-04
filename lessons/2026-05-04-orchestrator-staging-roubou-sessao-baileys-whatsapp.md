# 2026-05-04 — Orchestrator dry-run roubou sessão Baileys do WhatsApp (relink obrigatório)

## TL;DR

Phase 1 do `upgrade-zero-downtime.sh` subiu staging gateway que carregou plugin `whatsapp` lendo creds de **produção** (`/root/.openclaw/credentials/whatsapp/default/creds.json`). WhatsApp Web só permite **1 device-key por vez** — staging+prod usando mesmos creds → Baileys invalidou sessão de produção → Toto teve que **reescanear QR code pelo celular do Nox** (com fricção real). Causa raiz: `OPENCLAW_WORKSPACE` env var configurada NÃO isola `resolveOAuthDir()` — que olha pra `OPENCLAW_STATE_DIR` (não setado). Fix em 3 camadas: (a) `chattr +i` em todos creds files de canais, (b) `OPENCLAW_STATE_DIR` override no staging spawn, (c) snapshot tarball + auto-restore se SHA divergir.

## Severidade

**Alta.** Causou perda real de sessão WhatsApp em produção. Mensagens recebidas durante a janela de relink ficaram em `/root/.openclaw/delivery-queue/` com erro "No active WhatsApp Web listener". Toto teve que:

1. Buscar celular do Nox (<REDACTED-PHONE>)
2. Abrir WhatsApp → Aparelhos conectados → Conectar aparelho
3. Escanear QR (gerado via comando interativo SSH)
4. Esperar Baileys re-baixar app-state-sync (~200 keys)

Tempo total de downtime do canal WhatsApp: **~2 horas** (08:34 → 10:17 BRT).

## Contexto

`upgrade-zero-downtime.sh` Phase 1 sobe um staging gateway side-by-side em `:18790` pra rodar smoke tests sem tocar produção em `:18789`. Workspace separado em `/tmp/openclaw-staging-workspace`.

Setup do staging spawn (versão antiga, com bug):

```bash
systemd-run --unit=openclaw-staging \
  --property=Environment=IS_SANDBOX=1 \
  --property=Environment=OPENCLAW_WORKSPACE="$STAGING_WORKSPACE" \
  --property=EnvironmentFile=/root/.openclaw/.env \
  ...
```

**Intenção**: staging isolado, lê seu próprio config e seus próprios state files de `/tmp/openclaw-staging-workspace`.

**Realidade**: `OPENCLAW_WORKSPACE` é uma var ANTIGA/sem efeito real. O plugin-sdk usa `OPENCLAW_STATE_DIR` (vide `paths-C1_Y0cDn.js` → `resolveStateDir()`):

```javascript
function resolveStateDir(env = process.env, homedir = envHomedir(env)) {
    const override = env.OPENCLAW_STATE_DIR?.trim();
    if (override) return resolveUserPath(override, env, effectiveHomedir);
    // fallback to ~/.openclaw
    return newStateDir(effectiveHomedir);
}
```

E `resolveOAuthDir()` retorna `path.join(stateDir, "credentials")`. Sem `OPENCLAW_STATE_DIR`, staging gateway resolveu `/root/.openclaw/credentials/` — **mesmo path da produção**.

## O que aconteceu — timeline minuto a minuto

| Hora BRT | Evento |
|---|---|
| **2026-05-03 18:39:55** | gateway prod (PID 222124, v5.2) iniciou |
| 2026-05-04 07:34:04 | última mensagem WhatsApp inbound — sessão saudável |
| 07:36-07:39 | mensagens outbound — sessão saudável |
| 07:39-08:34 | silêncio (idle, mas conectada) |
| **08:34:14** | dry-run #1 disparado (`bash upgrade-zero-downtime.sh 2026.5.3 --dry-run`) |
| 08:34:27 | Phase 0a: snapshot openclaw.json |
| 08:35:16 | Phase 1d: staging gateway sobe em :18790 |
| **08:35:20** | ⚠️ staging carregou plugin `whatsapp` de `/root/.openclaw/npm/node_modules/@openclaw/whatsapp/dist/index.js` |
| 08:35:21 | ⚠️ plugin tentou ler creds de `/root/.openclaw/credentials/whatsapp/default/creds.json` (mesmo path da prod) |
| 08:35:25 | 🔴 Baileys: 2 device-keys ativos pro mesmo número → sessão invalidada |
| 08:46:13 | dry-run #2 disparado — repete o conflito |
| **08:09 BRT** (visto durante diagnóstico após o fato) | `WhatsApp default: not linked, stopped, disconnected` |
| 09:36:12 | dir `/root/.openclaw/credentials/whatsapp/default/` recriado vazio (5.3 plugin init) |
| 10:17:00 | Toto escaneou QR — sessão restaurada |
| **10:17-10:19** | Baileys re-baixou ~200 keys (pre-key-1 a pre-key-200, app-state-sync, lid-mapping, device-list) |

## Causa raiz

**Variável de ambiente errada usada pra isolar staging state.**

`OPENCLAW_WORKSPACE` parecia o nome óbvio mas:
- **Não é lida pelo plugin-sdk** (`paths-C1_Y0cDn.js` só checa `OPENCLAW_STATE_DIR` e `OPENCLAW_CONFIG_PATH`)
- Talvez seja só um hint pra plugins customizados ou legacy
- Documentação da plataforma não deixa explícito

`resolveOAuthDir()` em qualquer plugin (whatsapp, discord, telegram) → `<state_dir>/credentials/<channel>/<account>/` — e sem `OPENCLAW_STATE_DIR`, o `state_dir` defaulta pra `~/.openclaw` que é `/root/.openclaw` (mesmo que prod).

WhatsApp/Baileys especificamente sofre porque:
1. Mantém persistent device identity em `creds.json`
2. WhatsApp Web servidor rejeita 2ª conexão com mesma identity (duplicate detection)
3. Quando rejeita, **invalida creds.json também** — não dá pra "recuperar" depois, precisa re-link

Discord/Telegram não sofrem do mesmo modo:
- Discord usa bot token (sem identity persistente atrelada a device)
- Telegram polling é stateless por API key

## Por que não detectei antes

1. **`chattr +i openclaw.json`** que adicionei em iteração anterior não cobria `credentials/`. Pensei que isolation do config era suficiente.
2. **`OPENCLAW_WORKSPACE`** name suggestiu isolation. Não validei empiricamente se era a var certa.
3. **Smoke tests do orchestrator não testam channel state preservation pós-staging.** Phase 2 só verifica que staging gateway sobe; não verifica que prod channels continuam saudáveis.
4. **WhatsApp não mostra erro no journal imediato.** Baileys recebe disconnect, tenta reconectar, falha silenciosamente. Não houve linha "AUTH_FAILED" óbvia no log.

## Fix aplicado — defesa em 3 camadas

### 1. `chattr +i` em todos creds files (Phase 0z)

```bash
CREDS_LOCKED_FILES=(
  /root/.openclaw/openclaw.json
  /root/.openclaw/credentials/whatsapp/default/creds.json
  /root/.openclaw/credentials/whatsapp/default/creds.json.bak
  /root/.openclaw/credentials/discord-pairing.json
  /root/.openclaw/credentials/discord-default-allowFrom.json
  /root/.openclaw/credentials/telegram-pairing.json
  /root/.openclaw/credentials/telegram-default-allowFrom.json
)
for f in "${CREDS_LOCKED_FILES[@]}"; do
  chattr +i "$f" 2>/dev/null
done
```

Se staging tentar overwrite/delete, falha com `EPERM`. Defesa final no filesystem layer.

### 2. `OPENCLAW_STATE_DIR` override no staging spawn (Phase 1d)

```bash
mkdir -p "$STAGING_WORKSPACE/credentials"
mkdir -p "$STAGING_WORKSPACE/agents/staging-test/agent"

systemd-run --unit=openclaw-staging \
  --property=Environment=IS_SANDBOX=1 \
  --property=Environment=OPENCLAW_WORKSPACE="$STAGING_WORKSPACE" \
  --property=Environment=OPENCLAW_STATE_DIR="$STAGING_WORKSPACE" \
  --property=Environment=OPENCLAW_CONFIG_PATH="$STAGING_WORKSPACE/openclaw.json" \
  --property=EnvironmentFile=/root/.openclaw/.env \
  ...
```

`OPENCLAW_STATE_DIR=$STAGING_WORKSPACE` → `resolveOAuthDir()` retorna `$STAGING_WORKSPACE/credentials` (vazio) → channels veem "no creds" → não tentam auto-connect → zero conflito.

### 3. Snapshot tarball + auto-restore (Phase 0z + trap EXIT)

```bash
# Phase 0z — snapshot de TODA a árvore credentials/ pré-staging
tar -czf "$BACKUP_DIR/channel-creds-snapshot.tar.gz" -C /root/.openclaw credentials

# unlock_and_restore_config() — chamado via trap EXIT
if [[ ! -f /root/.openclaw/credentials/whatsapp/default/creds.json ]]; then
  tar -xzf "$BACKUP_DIR/channel-creds-snapshot.tar.gz" -C /root/.openclaw
fi
```

Se SOMEHOW os 2 layers acima falharem e creds.json sumir, restore automático do snapshot. Belt + suspenders + parachute.

## Lições generalizáveis

### 1. Env var name nem sempre faz o que parece

`OPENCLAW_WORKSPACE` PARECE isolation. Não é. Sempre **validar empiricamente** que isolation funciona — não confiar no nome da var.

**Como testar**: rodar staging com env vars setadas, fazer staging gateway tocar em um arquivo (qualquer um), verificar que o arquivo apareceu **só** no path esperado, não no path de produção.

### 2. Plugins state-aware (Baileys, OAuth) precisam isolation extra

Channels com persistent device identity (WhatsApp/Baileys, eventualmente Signal, iMessage) NÃO podem rodar 2 instâncias com mesmos creds. Ao contrário de bot-token-only channels (Discord, Telegram).

**Antes de subir staging com plugins:**
- Verificar quais plugins do bundle são "stateful" (têm persistent identity)
- Garantir que esses plugins NÃO veem creds de produção, OU desabilitar eles na config staging

### 3. Smoke tests do orchestrator devem incluir "produção continua saudável"

Phase 2 smoke testa staging UP. Adicionar:

```bash
# Phase 2x — verify production channels still healthy
smoke "production whatsapp still linked" \
  "openclaw channels status --json | jq -e '.[] | select(.id==\"whatsapp\") | .linked == true'"
smoke "production discord still connected" \
  "openclaw channels status --json | jq -e '.[] | select(.id==\"discord\") | .connected == true'"
```

Se staging causar regressão em prod, smoke falha → auto-rollback antes do swap real.

### 4. `chattr +i` é a última linha — não a única

Locks no FS é defense-in-depth, não solução primária. Mas é leve, idempotente, e cobre o "esqueci de setar a env var" — o tipo de bug que essa lesson documenta.

### 5. Snapshots tarball antes de operações arriscadas — sempre

`/root/.openclaw/credentials/` é tiny (alguns MB). Custo de tar.gz é desprezível. Benefício de poder restaurar no trap EXIT se algo der ruim é enorme.

### 6. Documentar pitfalls UPSTREAM

`OPENCLAW_WORKSPACE` vs `OPENCLAW_STATE_DIR` confusion deve ir pra docs do plugin-sdk. Reportar issue/PR upstream pra OpenClaw.

## Validação do fix

Re-rodar dry-run pós-patch:

```bash
bash /root/upgrade-zero-downtime.sh 2026.5.3 --dry-run
```

Esperado:
- ✅ Staging gateway sobe sem tocar `/root/.openclaw/credentials/`
- ✅ Production channels continuam connected (Discord, Telegram, Slack, WhatsApp)
- ✅ Cleanup post-Phase-2 confirma "whatsapp creds.json intact"
- ✅ chattr -i removido de TODOS os 7 files no exit

## Arquivos tocados

| Path | Tipo | Diff |
|---|---|---|
| `infra/scripts/upgrade-zero-downtime.sh` | edit | +60 linhas (Phase 0z: 7-file lock + tarball snapshot; Phase 1d: 2 novos env vars + mkdir staging dirs) |
| `/root/upgrade-zero-downtime.sh` na VPS | sync | espelho do acima |
| Lesson nova | NEW | este arquivo |

## Refs

- Lesson 2026-05-04 anterior (config contamination): `2026-05-04-staging-gateway-contaminates-prod-config.md`
- Lesson 2026-04-10: `2026-04-10-whatsapp-creds-corrompidas-restauracao-automatica-de.md` — documenta path canonical `/root/.openclaw/credentials/whatsapp/default/creds.json`
- INCIDENTS.md entrada 2026-05-04 (será atualizada com este postmortem)
- Source path resolution: `/usr/lib/node_modules/openclaw/dist/paths-C1_Y0cDn.js`

## Mea culpa

Apliquei o orchestrator com confiança baseada em premissas erradas (env var name = isolation). Toto teve fricção real — relink WhatsApp no celular, restore manual de creds Slack/Gemini que pareciam corrompidos mas eram outros issues. **Cobertura defensiva insuficiente.**

Próxima iteração: smoke tests de "produção saudável" no orchestrator + reportar OPENCLAW_WORKSPACE upstream.

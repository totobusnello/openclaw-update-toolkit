# RB-12: Emergency Procedures — Canal WhatsApp

> **Versão:** 1.0 (2026-05-06) — quick-ref playbook
> **Severity:** P1-P2 (canal degradado vs gateway down)
> **Aplica a:** `@openclaw/whatsapp` v2026.5.3+ rodando em `openclaw-gateway` compartilhado
> **Smoke test:** `bash infra/scripts/smoke-test-whatsapp.sh` — sempre rodar pós-intervenção

> ⚠️ **NUNCA** mexer em creds.json sem `chattr -i` primeiro. Sempre `chattr +i` de volta no final. Lição 2026-05-04 (`orchestrator-staging-roubou-sessao-baileys-whatsapp.md`).

---

## Index de cenários

1. [Gateway down — WhatsApp não responde](#1-gateway-down)
2. [Mensagens não chegam mas gateway está up](#2-mensagens-nao-chegam)
3. [WhatsApp 503/Stream Errored em retry loop](#3-503-retry-loop)
4. [Session expired — precisa re-pair (QR)](#4-session-expired-qr)
5. [Session corrupted — Baileys trava em handshake](#5-session-corrupted)
6. [allowFrom drift — alguém perdeu acesso](#6-allowfrom-drift)
7. [Delivery queue stuck — Unknown Channel persistente](#7-delivery-queue-stuck)
8. [Staging contaminou produção — sessão invalidada](#8-staging-contaminacao)
9. [Recovery confirm — sempre depois de qualquer intervenção](#9-recovery-confirm)

---

## 1. Gateway down

**Sintoma:** `systemctl is-active openclaw-gateway` = `inactive`/`failed`. Nenhum canal funciona (não só WhatsApp).

```bash
ssh root@<REDACTED-TAILSCALE-IP>
systemctl status openclaw-gateway --no-pager | head -20
journalctl -u openclaw-gateway --since '5 minutes ago' --no-pager | tail -30

# Se for crash recente: restart simples
systemctl restart openclaw-gateway
sleep 8
systemctl is-active openclaw-gateway

# Se NRestarts crescer rapidamente (fratricide loop):
# → Ver RB-11 §13 pitfalls (monkey-patch perdido)
```

---

## 2. Mensagens não chegam

**Sintoma:** Gateway up, outros canais funcionam, WhatsApp sem turn nas últimas Xh.

```bash
# Plugin loaded?
ssh root@<REDACTED-TAILSCALE-IP> 'openclaw plugins list --json | jq ".plugins[] | select(.id==\"whatsapp\")"'

# Logs específicos do plugin nas últimas 6h
ssh root@<REDACTED-TAILSCALE-IP> 'journalctl -u openclaw-gateway --since "6 hours ago" --no-pager | grep "\[whatsapp\]" | tail -30'

# Conexão estabelecida desde último restart?
ssh root@<REDACTED-TAILSCALE-IP> 'journalctl -u openclaw-gateway --since "today" --no-pager | grep -iE "\[whatsapp\].*(connected|opened|ready)" | tail -5'
```

Se zero conexões: cair pra cenário [#4 Session expired](#4-session-expired-qr).

---

## 3. 503 retry loop

**Sintoma:** Logs com `[whatsapp] Web connection closed (status 503). Retry X/12 in Ys`. Auto-recupera mas é ruidoso.

```bash
# Contar retries últimas 24h
ssh root@<REDACTED-TAILSCALE-IP> 'journalctl -u openclaw-gateway --since "24 hours ago" --no-pager | grep -c "\[whatsapp\].*status 503"'

# Se > 50: WhatsApp Web está flaky pro nosso device. Opções:
#   a) Aguardar — 503 é transient, geralmente volta sozinho
#   b) Se persistir > 4h: restart gateway para reconectar limpo
#      ssh root@<REDACTED-TAILSCALE-IP> 'systemctl restart openclaw-gateway'
#   c) Se persistir após restart: cenário [#5 Session corrupted]
```

---

## 4. Session expired (QR)

**Sintoma:** Logs mostram `[whatsapp] QR generated` ou `[whatsapp] Need to scan QR`. Conexão nunca completa.

```bash
# CRITICAL: nunca rodar pairing através de agent. Sempre SSH manual.
ssh root@<REDACTED-TAILSCALE-IP>

# 1. Confirmar que precisa de QR (não é falso alarme)
journalctl -u openclaw-gateway --since '10 min ago' --no-pager | grep -iE "qr|pairing|need to scan" | tail -5

# 2. Se confirmado, parar gateway pra evitar conflito
systemctl stop openclaw-gateway

# 3. Rodar plugin standalone pra ver QR ASCII
# (NOTA: via @openclaw/whatsapp não temos QR direto sem CLI flag.
#  Caminho oficial: openclaw channels add whatsapp --auth-dir <path>)
openclaw channels reauth whatsapp --auth-dir /root/.openclaw/credentials/whatsapp/default 2>&1 | tee /tmp/qr.log
# QR aparece no terminal — escanear com celular DEDICADO (Nox: <REDACTED-PHONE>)

# 4. Após "ready" no log, restart gateway
systemctl start openclaw-gateway
sleep 10
systemctl is-active openclaw-gateway

# 5. Reaplicar chattr +i (foi removido pelo re-auth)
chattr +i /root/.openclaw/credentials/whatsapp/default/creds.json
lsattr /root/.openclaw/credentials/whatsapp/default/creds.json | grep -q "^----i" && echo "chattr OK"
```

---

## 5. Session corrupted

**Sintoma:** Pós-crash gateway sobe mas WhatsApp loop em `connecting → disconnected` sem QR. Baileys handshake falha.

```bash
ssh root@<REDACTED-TAILSCALE-IP>

# 1. Backup dos creds atuais (pode ter dados parciais úteis)
TS=$(date +%Y%m%d-%H%M%S)
cp -r /root/.openclaw/credentials/whatsapp/default /root/.openclaw/credentials/whatsapp/default.corrupt-$TS

# 2. Stop gateway
systemctl stop openclaw-gateway

# 3. Remover creds corrompidos (force re-pair)
chattr -i /root/.openclaw/credentials/whatsapp/default/creds.json 2>/dev/null
rm -f /root/.openclaw/credentials/whatsapp/default/creds.json
# OU mais agressivo: rm -rf /root/.openclaw/credentials/whatsapp/default/* (só se backup feito acima)

# 4. Re-pair (cenário #4)
openclaw channels reauth whatsapp --auth-dir /root/.openclaw/credentials/whatsapp/default
# Escanear QR com celular dedicado

# 5. chattr +i + restart
chattr +i /root/.openclaw/credentials/whatsapp/default/creds.json
systemctl start openclaw-gateway
sleep 10

# 6. Validar
bash infra/scripts/smoke-test-whatsapp.sh
```

---

## 6. allowFrom drift

**Sintoma:** Alguém manda mensagem e bot não responde. Outros números na allowlist funcionam normal.

```bash
ssh root@<REDACTED-TAILSCALE-IP>

# 1. Ver allowlist atual
jq '.channels.whatsapp.allowFrom' /root/.openclaw/openclaw.json

# 2. Adicionar numero (formato: +55XXXXXXXXXXX)
openclaw config set channels.whatsapp.allowFrom '["<REDACTED-PHONE>","<REDACTED-PHONE>","<REDACTED-PHONE>","+55XXXXXXXXXXX"]'

# 3. Validar config + restart
openclaw config validate
systemctl restart openclaw-gateway
```

> **Nunca** editar `openclaw.json` direto via `jq`/`vim` — gateway tem in-memory state que sobrescreve no startup. Sempre `openclaw config set`.

---

## 7. Delivery queue stuck

**Sintoma:** Logs mostram `[delivery-recovery] Unknown Channel` ou `recovery time budget exceeded` repetindo a cada restart. Mensagens órfãs travadas.

```bash
ssh root@<REDACTED-TAILSCALE-IP>

# 1. Ver scope
ls /root/.openclaw/delivery-queue/*.json 2>/dev/null | wc -l
grep -l whatsapp /root/.openclaw/delivery-queue/*.json 2>/dev/null

# 2. Limpar via script existente (regra #8)
bash /root/.openclaw/workspace/tools/delivery-queue-cleanup.sh

# 3. Se script não funcionar — limpeza manual de items >7 dias com Unknown Channel
find /root/.openclaw/delivery-queue -name "*.json" -mtime +7 \
  -exec grep -l "Unknown Channel" {} \; \
  -exec mv {} {}.deleted-$(date +%Y%m%d) \;
```

---

## 8. Staging contaminação

**Sintoma:** Após rodar `infra/scripts/upgrade-zero-downtime.sh` (Phase 1 dry-run), Nox para de receber WhatsApp + log mostra Baileys disconnect. Lição completa: `infra/lessons/2026-05-04-orchestrator-staging-roubou-sessao-baileys-whatsapp.md`.

```bash
ssh root@<REDACTED-TAILSCALE-IP>

# Causa: staging gateway leu creds de produção, WhatsApp Web invalidou device-key
# Fix: re-pair (cenário #4) + auditar staging script pra garantir OPENCLAW_STATE_DIR override

# Imediato:
# 1. Re-pair WhatsApp (cenário #4)
# 2. Confirmar fix no staging script:
grep -nE "OPENCLAW_STATE_DIR|chattr.*creds" infra/scripts/upgrade-zero-downtime.sh
# Esperado: OPENCLAW_STATE_DIR=$STAGING_WORKSPACE setado antes do staging gateway spawn

# Validar invariante: creds.json sempre +i exceto durante re-pair manual
lsattr /root/.openclaw/credentials/whatsapp/default/creds.json
```

---

## 9. Recovery confirm

**Sempre rodar depois de qualquer cenário acima:**

```bash
# Smoke test completo (6 checks)
bash infra/scripts/smoke-test-whatsapp.sh

# Esperado:
#   - 6× [OK]
#   - Exit 0
#   - 0 FAILs

# Smoke manual:
# Mandar mensagem WhatsApp do celular do Toto pro número do Nox.
# Esperado: resposta em 15-25s coerente.
```

---

## Referências

- Plugin source: `/root/.openclaw/npm/node_modules/@openclaw/whatsapp/`
- Schema: `cat /root/.openclaw/npm/node_modules/@openclaw/whatsapp/openclaw.plugin.json | jq '.channelConfigs.whatsapp.schema.properties'`
- Lições relacionadas:
  - `2026-05-04-orchestrator-staging-roubou-sessao-baileys-whatsapp.md` — origem do `chattr +i` em creds + `OPENCLAW_STATE_DIR` no staging
  - `2026-05-03-openclaw-v5.2-upgrade-pitfalls.md` — plugin externalization (instalar via `npm install` direto, não `openclaw plugins install`)
- CLAUDE.md regras críticas: #1 (Max OAuth), #6 (chattr +i credentials), #8 (delivery-queue cleanup)

---

*Runbook criado 2026-05-06 inspirado em `docbiker/whatsapp-agent-setup/references/emergency-procedures.md` (v1.1.0), adaptado pra nossa stack Baileys + gateway compartilhado + multi-agent.*

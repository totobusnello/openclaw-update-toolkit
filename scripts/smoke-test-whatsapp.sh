#!/usr/bin/env bash
# smoke-test-whatsapp.sh — End-to-end validation do canal WhatsApp na VPS
#
# Uso:
#   bash infra/scripts/smoke-test-whatsapp.sh                   # rodar contra VPS prod via SSH
#   bash infra/scripts/smoke-test-whatsapp.sh --local           # rodar diretamente (dentro da VPS)
#
# 6 checks. Exit non-zero em qualquer FAIL. WARN não falha mas sinaliza atenção.
#
# Inspirado em docbiker/whatsapp-agent-setup smoke-test.sh, adaptado pra:
# - Gateway compartilhado (não 1 systemd por agente)
# - Baileys SDK (não Puppeteer/wwebjs)
# - @openclaw/whatsapp v2026.5.3 schema
# - Nossos patterns: chattr +i creds, allowlist dmPolicy, delivery-queue cleanup

set -u

LOCAL=false
[[ "${1:-}" == "--local" ]] && LOCAL=true

SSH_HOST="${SSH_HOST:-root@<REDACTED-TAILSCALE-IP>}"
WHATSAPP_CREDS_DIR="${WHATSAPP_CREDS_DIR:-/root/.openclaw/credentials/whatsapp/default}"
DELIVERY_QUEUE_DIR="${DELIVERY_QUEUE_DIR:-/root/.openclaw/delivery-queue}"
FAIL=0
WARN=0

pass() { echo "  [OK]   $1"; }
warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }
fail() { echo "  [FAIL] $1" >&2; FAIL=$((FAIL + 1)); }

# Helper — executa comando local ou via SSH dependendo do modo
remote() {
  if $LOCAL; then
    bash -c "$1"
  else
    ssh -o ConnectTimeout=10 "$SSH_HOST" "$1"
  fi
}

echo "=== smoke-test-whatsapp $(date '+%Y-%m-%d %H:%M:%S') ==="
echo "Mode: $($LOCAL && echo local || echo "remote ($SSH_HOST)")"
echo

echo "=== 1. Gateway service active ==="
GW_STATUS=$(remote 'systemctl is-active openclaw-gateway' 2>&1 | tr -d '[:space:]')
if [[ "$GW_STATUS" == "active" ]]; then
  pass "openclaw-gateway active"
  remote 'systemctl status openclaw-gateway --no-pager 2>&1 | grep -E "Active:|Memory:" | sed "s/^/    /"'
else
  fail "openclaw-gateway not active (status=$GW_STATUS)"
fi

echo
echo "=== 2. WhatsApp plugin loaded ==="
WPP_LOADED=$(remote 'openclaw plugins list --json 2>/dev/null | jq -r ".plugins[] | select(.id==\"whatsapp\") | \"\(.id) \(.status // \"?\") \(.origin // \"?\")\""' 2>&1)
if [[ -n "$WPP_LOADED" ]]; then
  pass "plugin whatsapp loaded: $WPP_LOADED"
else
  fail "plugin whatsapp não aparece em openclaw plugins list"
fi

echo
echo "=== 3. WhatsApp connection ready (logs últimos 6h) ==="
LOGS_6H=$(remote 'journalctl -u openclaw-gateway --since "6 hours ago" --no-pager 2>/dev/null | grep "\[whatsapp\]"' 2>&1)
READY_COUNT=$(echo "$LOGS_6H" | grep -ciE 'connected|ready|opened' || true)
ERROR_COUNT=$(echo "$LOGS_6H" | grep -ciE 'error|fail|disconnected|Stream Errored' || true)
RETRY_COUNT=$(echo "$LOGS_6H" | grep -ciE 'retry|status 503|status 401' || true)

if [[ "$READY_COUNT" -gt 0 ]]; then
  pass "$READY_COUNT linhas de connected/ready em 6h"
else
  warn "zero linhas de connected/ready em 6h — pode estar OK se gateway não foi restartado"
fi

if [[ "$ERROR_COUNT" -eq 0 ]]; then
  pass "zero erros [whatsapp] em 6h"
elif [[ "$ERROR_COUNT" -le 5 ]]; then
  warn "$ERROR_COUNT erros [whatsapp] em 6h — investigar se for recorrente"
  echo "$LOGS_6H" | grep -iE 'error|fail|disconnected' | tail -3 | sed 's/^/    /'
else
  fail "$ERROR_COUNT erros [whatsapp] em 6h — alta taxa de erro"
  echo "$LOGS_6H" | grep -iE 'error|fail|disconnected' | tail -5 | sed 's/^/    /'
fi

[[ "$RETRY_COUNT" -gt 0 ]] && warn "$RETRY_COUNT retries (503/401) em 6h — pode ser WhatsApp Web flaky"

echo
echo "=== 4. Channel security config (regra: dmPolicy=allowlist, allowFrom não vazio) ==="
WPP_CONFIG=$(remote 'jq ".channels.whatsapp" /root/.openclaw/openclaw.json' 2>&1)

DM_POLICY=$(echo "$WPP_CONFIG" | jq -r '.dmPolicy // "missing"')
GROUP_POLICY=$(echo "$WPP_CONFIG" | jq -r '.groupPolicy // "missing"')
ALLOW_FROM_COUNT=$(echo "$WPP_CONFIG" | jq -r '.allowFrom | length // 0')
SELF_CHAT=$(echo "$WPP_CONFIG" | jq -r '.selfChatMode // false')

case "$DM_POLICY" in
  allowlist|pairing) pass "dmPolicy=$DM_POLICY (seguro)";;
  open) fail "dmPolicy=open — qualquer contato pode iniciar DM. Confirmar se intencional.";;
  disabled) warn "dmPolicy=disabled — DMs desabilitados (intencional?)";;
  missing) fail "dmPolicy não setado — schema requer dmPolicy";;
  *) warn "dmPolicy=$DM_POLICY — valor não reconhecido";;
esac

case "$GROUP_POLICY" in
  allowlist|disabled) pass "groupPolicy=$GROUP_POLICY (seguro)";;
  open) warn "groupPolicy=open — bot responde em qualquer grupo. Confirmar se intencional.";;
  missing) fail "groupPolicy não setado";;
  *) warn "groupPolicy=$GROUP_POLICY";;
esac

if [[ "$DM_POLICY" == "allowlist" ]]; then
  if [[ "$ALLOW_FROM_COUNT" -gt 0 ]]; then
    pass "allowFrom: $ALLOW_FROM_COUNT contato(s) na allowlist"
  else
    fail "dmPolicy=allowlist mas allowFrom vazio — ninguém consegue mandar DM"
  fi
fi

[[ "$SELF_CHAT" == "true" ]] && pass "selfChatMode=true (permite uso do próprio número)"

echo
echo "=== 5. Credentials integrity (regra #6/#7 — chattr +i) ==="
CREDS_PATH="$WHATSAPP_CREDS_DIR/creds.json"
CREDS_LSATTR=$(remote "lsattr $CREDS_PATH 2>/dev/null" 2>&1)

if echo "$CREDS_LSATTR" | grep -qE '^----i'; then
  pass "creds.json com chattr +i (proteção contra Baileys self-fix + staging contamination — lição 2026-05-04)"
else
  fail "creds.json SEM chattr +i — risco de invalidação por outra sessão. Aplicar: chattr +i $CREDS_PATH"
fi

CREDS_SIZE=$(remote "wc -c < $CREDS_PATH 2>/dev/null" 2>&1 | tr -d '[:space:]')
if [[ "$CREDS_SIZE" =~ ^[0-9]+$ ]] && [[ "$CREDS_SIZE" -gt 100 ]]; then
  pass "creds.json não-vazio ($CREDS_SIZE bytes)"
else
  fail "creds.json ausente ou suspeito (size=$CREDS_SIZE)"
fi

echo
echo "=== 6. Delivery queue sem WhatsApp stuck (regra #8) ==="
WPP_STUCK=$(remote "find $DELIVERY_QUEUE_DIR -maxdepth 2 -name '*.json' -newer /tmp -mmin +5 2>/dev/null | xargs grep -l 'whatsapp' 2>/dev/null | wc -l" 2>&1 | tr -d '[:space:]')
QUEUE_TOTAL=$(remote "ls $DELIVERY_QUEUE_DIR/*.json 2>/dev/null | wc -l" 2>&1 | tr -d '[:space:]')

if [[ "$QUEUE_TOTAL" =~ ^[0-9]+$ ]]; then
  if [[ "$QUEUE_TOTAL" -eq 0 ]]; then
    pass "delivery-queue vazia"
  elif [[ "$WPP_STUCK" =~ ^[0-9]+$ ]] && [[ "$WPP_STUCK" -eq 0 ]]; then
    pass "delivery-queue tem $QUEUE_TOTAL items mas nenhum WhatsApp stuck >5min"
  else
    warn "delivery-queue tem $WPP_STUCK item(s) WhatsApp >5min — considerar /root/.openclaw/workspace/tools/delivery-queue-cleanup.sh"
  fi
else
  warn "não foi possível ler delivery-queue dir"
fi

echo
echo "=== Resumo ==="
echo "  FAILs: $FAIL"
echo "  WARNs: $WARN"
echo

if [[ "$FAIL" -gt 0 ]]; then
  echo "❌ SMOKE TEST FAILED — corrigir FAILs antes de declarar canal WhatsApp saudável"
  echo "   Ver runbook: infra/runbooks/emergency-whatsapp.md"
  exit 1
elif [[ "$WARN" -gt 0 ]]; then
  echo "⚠️  SMOKE TEST PASSED com WARNs — revisar avisos acima"
  exit 0
else
  echo "✅ SMOKE TEST PASSED — canal WhatsApp saudável"
  exit 0
fi

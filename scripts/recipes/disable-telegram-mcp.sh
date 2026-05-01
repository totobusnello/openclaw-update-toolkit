#!/usr/bin/env bash
# Recipe G — Disable plugin Telegram MCP do Claude CLI (duplicate poller)
# https://github.com/totobusnello/openclaw-update-toolkit
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ERRO: rode como root"; exit 1
fi

TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/root/.openclaw/backups/recipe-G-$TS"
mkdir -p "$BACKUP_DIR"
SETTINGS=/root/.claude/settings.json

echo "## Recipe G — Disable plugin Telegram MCP duplicate poller"
echo

if [[ ! -f "$SETTINGS" ]]; then
  echo "✅ SKIP: $SETTINGS não existe — Claude CLI não está instalado pra root, sem risco de duplicate poller MCP."
  exit 0
fi

# Backup
cp "$SETTINGS" "$BACKUP_DIR/settings.json.bak"
echo "Backup: $BACKUP_DIR/settings.json.bak"

CURRENT=$(jq -r '.enabledPlugins["telegram@claude-plugins-official"] // false' "$SETTINGS" 2>/dev/null)
if [[ "$CURRENT" == "false" ]]; then
  echo "✅ telegram MCP plugin já está disabled. Validando defesa em profundidade..."
else
  echo "telegram MCP plugin atualmente: $CURRENT → setando false"
  jq '.enabledPlugins["telegram@claude-plugins-official"] = false' "$SETTINGS" > /tmp/settings.new
  mv /tmp/settings.new "$SETTINGS"
  chmod 644 "$SETTINGS"
fi

# Defesa em profundidade: remover MCP perms stale
PERMS_BEFORE=$(jq '.permissions.allow // [] | map(select(. | test("mcp__plugin_telegram"))) | length' "$SETTINGS" 2>/dev/null || echo 0)
if [[ "$PERMS_BEFORE" -gt 0 ]]; then
  echo "Removendo $PERMS_BEFORE perms MCP stale..."
  jq '.permissions.allow = (.permissions.allow | map(select(. | test("mcp__plugin_telegram") | not)))' "$SETTINGS" > /tmp/settings.new
  mv /tmp/settings.new "$SETTINGS"
fi

# Defesa em profundidade: remover preset legacy
if jq -e 'has("channels")' "$SETTINGS" >/dev/null 2>&1; then
  echo "Removendo preset legacy 'channels'..."
  jq 'del(.channels)' "$SETTINGS" > /tmp/settings.new
  mv /tmp/settings.new "$SETTINGS"
fi

chmod 644 "$SETTINGS"

echo
echo "Restart pra clear in-flight subprocesses..."
systemctl restart openclaw-gateway
sleep 12

if ! systemctl is-active --quiet openclaw-gateway; then
  echo "❌ Gateway falhou. Revertendo..."
  cp "$BACKUP_DIR/settings.json.bak" "$SETTINGS"
  systemctl reset-failed openclaw-gateway 2>/dev/null
  systemctl restart openclaw-gateway
  exit 3
fi

echo "✅ Gateway active"
echo
echo "Aguardando 90s pra validar zero conflicts..."
sleep 90
CONFLICTS=$(journalctl -u openclaw-gateway --since "90 seconds ago" --no-pager 2>/dev/null | grep -cE "telegram.*conflict|409.*Conflict" || echo 0)
if [[ "$CONFLICTS" -eq 0 ]]; then
  echo "✅ Zero conflicts em 90s — fix funcionando"
else
  echo "⚠️ Ainda $CONFLICTS conflict(s) — pode haver outro poller ativo (script externo, outro VPS, container)"
  echo "   Investigar: ps -ef | grep -iE 'telegram|getUpdates'"
fi

echo
echo "✅ Recipe G aplicada. Backup: $BACKUP_DIR/"
echo
read -p "Instalar canary Telegram 409 (recomendado)? (y/N) " -n 1 -r INSTALL_CANARY < /dev/tty || true
echo
if [[ "$INSTALL_CANARY" =~ ^[Yy]$ ]]; then
  cat > /root/.openclaw/scripts/canary-telegram-conflict.sh << 'CANARY'
#!/bin/bash
set -e
COUNT=$(journalctl -u openclaw-gateway --since "10 minutes ago" --no-pager 2>/dev/null \
  | grep -cE "telegram.*conflict|getUpdates conflict|409.*Conflict" || true)
logger -t canary-telegram-conflict "telegram-409-count=$COUNT"
LAST_ALERT_FILE=/var/lib/nox-canary/telegram-conflict-last-alert
mkdir -p /var/lib/nox-canary
if [ "$COUNT" -gt 2 ] && [ -f /root/.openclaw/.env ]; then
  NOW=$(date +%s); LAST=$(cat "$LAST_ALERT_FILE" 2>/dev/null || echo 0)
  if [ $((NOW - LAST)) -gt 3600 ]; then
    WEBHOOK=$(grep "^DISCORD_WEBHOOK=" /root/.openclaw/.env | cut -d= -f2-)
    if [ -n "$WEBHOOK" ]; then
      curl -sS -X POST -H "Content-Type: application/json" \
        -d "{\"content\": \"🚨 Telegram 409 conflict canary: $COUNT em 10min em $(hostname)\"}" \
        "$WEBHOOK" > /dev/null 2>&1 || true
      echo "$NOW" > "$LAST_ALERT_FILE"
    fi
  fi
fi
CANARY
  mkdir -p /root/.openclaw/scripts
  chmod +x /root/.openclaw/scripts/canary-telegram-conflict.sh
  ( crontab -l 2>/dev/null | grep -v canary-telegram-conflict; echo "*/5 * * * * /root/.openclaw/scripts/canary-telegram-conflict.sh" ) | crontab -
  echo "✅ Canary instalado: cron */5min, alerta Discord se >2 conflicts em 10min, throttle 1h"
fi

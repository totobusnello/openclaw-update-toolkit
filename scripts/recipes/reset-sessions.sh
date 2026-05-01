#!/usr/bin/env bash
# Recipe L — Reset sessions.json grudados em fallback
set -euo pipefail
if [[ $EUID -ne 0 ]]; then echo "ERRO: rode como root"; exit 1; fi
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/root/.openclaw/backups/recipe-L-$TS"
mkdir -p "$BACKUP_DIR"

echo "## Recipe L — Reset sessions stickiness"

CONFIG=/root/.openclaw/openclaw.json
RESET_COUNT=0
for AGENT in $(jq -r '.agents.list[].id' "$CONFIG" 2>/dev/null); do
  SESS=/root/.openclaw/agents/$AGENT/sessions/sessions.json
  if [[ -f "$SESS" ]]; then
    cp "$SESS" "$BACKUP_DIR/sessions-$AGENT.bak"
    BEFORE=$(jq 'length' "$SESS" 2>/dev/null || echo 0)
    jq 'with_entries(select(.value.model // "" | tostring | startswith("claude-")))' "$SESS" > /tmp/sessions.tmp
    mv /tmp/sessions.tmp "$SESS"
    AFTER=$(jq 'length' "$SESS" 2>/dev/null || echo 0)
    REMOVED=$((BEFORE - AFTER))
    if [[ "$REMOVED" -gt 0 ]]; then
      echo "  $AGENT: removed $REMOVED stuck session(s) ($BEFORE → $AFTER)"
      RESET_COUNT=$((RESET_COUNT + REMOVED))
    fi
  fi
done

echo
if [[ "$RESET_COUNT" -gt 0 ]]; then
  echo "Total: $RESET_COUNT sessions resetadas"
  echo "Backup: $BACKUP_DIR/"
  systemctl restart openclaw-gateway
  sleep 8
  if systemctl is-active --quiet openclaw-gateway; then
    echo "✅ Recipe L aplicada"
  else
    echo "❌ Gateway falhou"
    exit 2
  fi
else
  echo "✅ SKIP: nenhuma session grudada em fallback (todas já em claude-*)"
fi

#!/usr/bin/env bash
# Recipe H — Session DM scope per-channel-peer + reload mode hot
set -euo pipefail
if [[ $EUID -ne 0 ]]; then echo "ERRO: rode como root"; exit 1; fi
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/root/.openclaw/backups/recipe-H-$TS"
mkdir -p "$BACKUP_DIR"
CONFIG=/root/.openclaw/openclaw.json

echo "## Recipe H — dmScope per-channel-peer + reload hot"
cp "$CONFIG" "$BACKUP_DIR/openclaw.json.bak"
echo "Backup: $BACKUP_DIR/"

CURRENT_SCOPE=$(jq -r '.session.dmScope // "main"' "$CONFIG")
CURRENT_RELOAD=$(jq -r '.gateway.reload.mode // "off"' "$CONFIG")
echo "Atual: dmScope=$CURRENT_SCOPE, reload.mode=$CURRENT_RELOAD"

if [[ "$CURRENT_SCOPE" != "per-channel-peer" ]]; then
  openclaw config set session.dmScope per-channel-peer
fi
if [[ "$CURRENT_RELOAD" != "hot" ]]; then
  openclaw config set gateway.reload.mode hot
fi

systemctl restart openclaw-gateway
sleep 10
if ! systemctl is-active --quiet openclaw-gateway; then
  echo "❌ Gateway falhou. Revertendo..."
  cp "$BACKUP_DIR/openclaw.json.bak" "$CONFIG"
  systemctl restart openclaw-gateway
  exit 2
fi

echo "✅ Recipe H aplicada"
echo "Estado:"
jq '.session, .gateway.reload' "$CONFIG"

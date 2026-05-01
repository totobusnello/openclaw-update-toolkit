#!/usr/bin/env bash
# Recipe C — Fallback chain limpa (sem anthropic-max ou outros pagos)
set -euo pipefail
if [[ $EUID -ne 0 ]]; then echo "ERRO: rode como root"; exit 1; fi
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/root/.openclaw/backups/recipe-C-$TS"
mkdir -p "$BACKUP_DIR"
CONFIG=/root/.openclaw/openclaw.json

echo "## Recipe C — Fallback chain limpa"
cp "$CONFIG" "$BACKUP_DIR/openclaw.json.bak"
echo "Backup: $BACKUP_DIR/"

CURRENT=$(jq -r '.agents.defaults.model.fallbacks // [] | join(",")' "$CONFIG")
echo "Fallbacks atuais: $CURRENT"

# Setar chain canônica
openclaw config set 'agents.defaults.model.fallbacks' '["openai-codex/gpt-5.5","gemini/gemini-2.5-pro"]'

NEW=$(jq -r '.agents.defaults.model.fallbacks | join(",")' "$CONFIG")
echo "Fallbacks novos: $NEW"

systemctl restart openclaw-gateway
sleep 8
if ! systemctl is-active --quiet openclaw-gateway; then
  echo "❌ Gateway falhou. Revertendo..."
  cp "$BACKUP_DIR/openclaw.json.bak" "$CONFIG"
  systemctl restart openclaw-gateway
  exit 2
fi
echo "✅ Recipe C aplicada"

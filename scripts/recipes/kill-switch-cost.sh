#!/usr/bin/env bash
# Recipe B — Kill switch anti-cobrança Anthropic (forçar agentRuntime=claude-cli)
# https://github.com/totobusnello/openclaw-update-toolkit
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ERRO: rode como root"; exit 1
fi

TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/root/.openclaw/backups/recipe-B-$TS"
mkdir -p "$BACKUP_DIR"
CONFIG=/root/.openclaw/openclaw.json

echo "## Recipe B — Kill switch custo Anthropic"
echo

if [[ ! -f "$CONFIG" ]]; then
  echo "ERRO: $CONFIG não existe"
  exit 2
fi

# Backup
cp "$CONFIG" "$BACKUP_DIR/openclaw.json.bak"
echo "Backup: $BACKUP_DIR/openclaw.json.bak"

# Setar defaults.agentRuntime.id = claude-cli
echo "Setting agents.defaults.agentRuntime.id = claude-cli..."
openclaw config set agents.defaults.agentRuntime.id claude-cli 2>&1 | head -3

# Iterar agents.list e setar cada um
echo "Iterando agents individuais..."
COUNT=$(jq '.agents.list | length' "$CONFIG")
for ((i=0; i<COUNT; i++)); do
  AGENT_ID=$(jq -r ".agents.list[$i].id" "$CONFIG")
  CURRENT=$(jq -r ".agents.list[$i].agentRuntime.id // \"DEFAULT\"" "$CONFIG")
  if [[ "$CURRENT" != "claude-cli" ]]; then
    echo "  - $AGENT_ID: $CURRENT → claude-cli"
    openclaw config set "agents.list.$i.agentRuntime.id" claude-cli 2>&1 | grep -v "^Config\|Updated\|Restart" | head -3
  else
    echo "  - $AGENT_ID: já claude-cli ✅"
  fi
done

echo
echo "Restart pra aplicar..."
systemctl restart openclaw-gateway
sleep 12

if ! systemctl is-active --quiet openclaw-gateway; then
  echo "❌ Gateway falhou. Revertendo..."
  cp "$BACKUP_DIR/openclaw.json.bak" "$CONFIG"
  systemctl reset-failed openclaw-gateway 2>/dev/null
  systemctl restart openclaw-gateway
  exit 3
fi

echo "✅ Gateway active"
echo
echo "Validando: provider=claude-cli em logs..."
sleep 3
if journalctl -u openclaw-gateway --since "30 seconds ago" --no-pager 2>/dev/null | grep -q "provider=claude-cli"; then
  echo "✅ provider=claude-cli detectado nos logs"
else
  echo "⚠️ provider=claude-cli ainda não apareceu (pode levar até alguns minutos para próximo turn)"
fi

ANTHROPIC_CALLS=$(journalctl -u openclaw-gateway --since "1 hour ago" --no-pager 2>/dev/null | grep -cE "api\.anthropic\.com|x-api-key" || echo 0)
if [[ "$ANTHROPIC_CALLS" -eq 0 ]]; then
  echo "✅ Zero calls a api.anthropic.com na última hora"
else
  echo "⚠️ Ainda tem $ANTHROPIC_CALLS call(s) a api.anthropic.com — pode ser histórico anterior ao fix"
fi

echo
echo "✅ Recipe B aplicada. Backup: $BACKUP_DIR/"
echo "ATENÇÃO: NÃO comentar ANTHROPIC_API_KEY no .env — provider runtime exige no startup."

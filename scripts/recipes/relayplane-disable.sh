#!/usr/bin/env bash
# Recipe F — RelayPlane disable + baseUrl correto
set -euo pipefail
if [[ $EUID -ne 0 ]]; then echo "ERRO: rode como root"; exit 1; fi
echo "## Recipe F — RelayPlane disable + baseUrl"

if systemctl list-unit-files relayplane-proxy.service &>/dev/null; then
  systemctl stop relayplane-proxy 2>/dev/null || true
  systemctl disable relayplane-proxy 2>/dev/null || true
  echo "✅ relayplane-proxy stopped + disabled"
else
  echo "✅ relayplane-proxy unit não existe (já estava inativo)"
fi

CURRENT_URL=$(jq -r '.models.providers.anthropic.baseUrl // "missing"' /root/.openclaw/openclaw.json)
if [[ "$CURRENT_URL" == "https://api.anthropic.com" ]]; then
  echo "✅ baseUrl já correto: $CURRENT_URL"
else
  echo "baseUrl: $CURRENT_URL → setando https://api.anthropic.com"
  openclaw config set models.providers.anthropic.baseUrl https://api.anthropic.com
  systemctl restart openclaw-gateway
  sleep 8
fi

if systemctl is-active --quiet openclaw-gateway; then
  echo "✅ Gateway active"
else
  echo "❌ Gateway falhou — investigar logs"
  exit 2
fi
echo "✅ Recipe F aplicada"

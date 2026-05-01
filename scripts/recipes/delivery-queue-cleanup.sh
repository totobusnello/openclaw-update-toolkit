#!/usr/bin/env bash
# Recipe I — Delivery-queue cleanup (Unknown Channel órfãs)
set -euo pipefail
if [[ $EUID -ne 0 ]]; then echo "ERRO: rode como root"; exit 1; fi

echo "## Recipe I — Delivery-queue cleanup"

QUEUE=/root/.openclaw/delivery-queue
SCRIPT=/root/.openclaw/workspace/tools/delivery-queue-cleanup.sh

if [[ -x "$SCRIPT" ]]; then
  echo "Usando script oficial do OpenClaw: $SCRIPT"
  bash "$SCRIPT"
elif [[ -d "$QUEUE" ]]; then
  BEFORE=$(ls "$QUEUE"/*.json 2>/dev/null | wc -l)
  find "$QUEUE" -name '*.json' -mtime +7 -delete 2>/dev/null || true
  AFTER=$(ls "$QUEUE"/*.json 2>/dev/null | wc -l)
  echo "Removed: $((BEFORE - AFTER)) arquivos > 7 dias"
else
  echo "✅ SKIP: delivery-queue não existe"
fi

echo "✅ Recipe I aplicada"

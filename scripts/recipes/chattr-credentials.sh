#!/usr/bin/env bash
# Recipe E — chattr +i em ~/.claude/.credentials.json
# https://github.com/totobusnello/openclaw-update-toolkit
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ERRO: rode como root"; exit 1
fi

CRED=/root/.claude/.credentials.json

echo "## Recipe E — chattr +i credentials.json"
echo

if [[ ! -f "$CRED" ]]; then
  if [[ -f "$CRED.bak" ]]; then
    echo "credentials.json missing — restaurando de .bak..."
    cp "$CRED.bak" "$CRED"
    chmod 600 "$CRED"
  else
    echo "❌ credentials.json não existe e sem backup .bak"
    echo "   Rode 'claude setup-token' interativamente pra autenticar OAuth Max"
    echo "   Depois reexecute esta recipe."
    exit 2
  fi
fi

# Já imutável?
ATTRS=$(lsattr "$CRED" 2>/dev/null | awk '{print $1}')
if [[ "$ATTRS" == *"i"* ]]; then
  echo "✅ SKIP: $CRED já tem chattr +i"
  exit 0
fi

# Validar não vazio + JSON válido
if [[ ! -s "$CRED" ]]; then
  echo "❌ $CRED está vazio ou zero bytes"
  echo "   Rode 'claude setup-token' interativamente"
  exit 3
fi

if ! jq empty "$CRED" 2>/dev/null; then
  echo "❌ $CRED não é JSON válido"
  exit 4
fi

chattr +i "$CRED"
echo "✅ chattr +i aplicado"
lsattr "$CRED"

echo
echo "Validando: claude auth status..."
if claude auth status 2>&1 | grep -q "loggedIn.*true\|logged in"; then
  echo "✅ auth status OK"
else
  echo "⚠️ auth status retornou status inesperado — pode haver mismatch entre env var e credentials.json"
  echo "   Validar manualmente: jq -r '.claudeAiOauth.accessToken[0:15]' $CRED"
fi

echo
echo "✅ Recipe E aplicada"
echo "Pra rotacionar token no futuro: chattr -i $CRED && claude setup-token && chattr +i $CRED"

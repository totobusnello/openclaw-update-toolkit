#!/usr/bin/env bash
# Recipe D — Reaplicar monkey-patch fratricide #62028
# https://github.com/totobusnello/openclaw-update-toolkit
# Idempotente: só patcha se ainda não estiver patched. Faz chattr +i automático.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ERRO: rode como root"
  exit 1
fi

TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/root/.openclaw/backups/recipe-D-$TS"
mkdir -p "$BACKUP_DIR"

echo "## Recipe D — Reaplicar monkey-patch fratricide #62028"
echo

# Encontrar arquivo impl (não wrapper de 2 linhas)
TARGET=""
for F in /usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js; do
  if [[ -f "$F" ]] && [[ $(wc -l < "$F" 2>/dev/null) -gt 100 ]]; then
    TARGET="$F"
    break
  fi
done

if [[ -z "$TARGET" ]]; then
  echo "ERRO: arquivo impl não encontrado em /usr/lib/node_modules/openclaw/dist/"
  echo "Verificar: ls /usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js"
  exit 2
fi

echo "Target file: $TARGET"

# Já patched?
if grep -qE "MONKEY-PATCH.*62028" "$TARGET"; then
  echo "✅ SKIP: já patched. Função cleanStaleGatewayProcessesSync já tem return [] direto."
  echo "Validating wrapper imutability:"
  if [[ -f /usr/local/bin/openclaw-gateway-wrapper ]]; then
    lsattr /usr/local/bin/openclaw-gateway-wrapper 2>/dev/null | head -1
  fi
  exit 0
fi

# Backup + remover chattr se imutável
chattr -i "$TARGET" 2>/dev/null || true
cp "$TARGET" "$BACKUP_DIR/$(basename "$TARGET").bak"
echo "Backup: $BACKUP_DIR/$(basename "$TARGET").bak"

# Patch via Python (regex idempotente)
python3 - "$TARGET" << 'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    c = f.read()
new = re.sub(
    r'(function cleanStaleGatewayProcessesSync\([^)]*\)\s*\{\s*try\s*\{)',
    r'\1\n\t\t// MONKEY-PATCH: Issue #62028 fratricide fix (reapplied via openclaw-update-toolkit)\n\t\treturn [];',
    c, count=1
)
if new == c:
    print('ERROR: pattern not matched — função cleanStaleGatewayProcessesSync pode ter mudado de assinatura nessa versão')
    sys.exit(1)
with open(path, 'w', encoding='utf-8') as f:
    f.write(new)
print('OK: patch applied')
PYEOF

# Validar patch aplicado
if ! grep -qE "MONKEY-PATCH.*62028" "$TARGET"; then
  echo "ERRO: patch não foi aplicado mesmo após Python script"
  echo "Restaurando backup..."
  cp "$BACKUP_DIR/$(basename "$TARGET").bak" "$TARGET"
  exit 3
fi

echo "Patched function (3 first lines):"
grep -A3 "function cleanStaleGatewayProcessesSync" "$TARGET" | head -5

# Wrapper imutável (se existir)
if [[ -f /usr/local/bin/openclaw-gateway-wrapper ]]; then
  if ! lsattr /usr/local/bin/openclaw-gateway-wrapper 2>/dev/null | grep -q "^----i"; then
    chattr +i /usr/local/bin/openclaw-gateway-wrapper
    echo "✅ chattr +i aplicado em /usr/local/bin/openclaw-gateway-wrapper"
  else
    echo "✅ wrapper já imutável"
  fi
fi

echo
echo "Restartando gateway..."
systemctl restart openclaw-gateway
sleep 12

if systemctl is-active --quiet openclaw-gateway; then
  NRESTARTS=$(systemctl show -p NRestarts --value openclaw-gateway)
  echo "✅ Gateway active. NRestarts=$NRESTARTS (esperado: 0)"
else
  echo "❌ Gateway não está active após restart. Reverter:"
  echo "   chattr -i $TARGET && cp $BACKUP_DIR/$(basename "$TARGET").bak $TARGET && systemctl restart openclaw-gateway"
  exit 4
fi

echo
echo "✅ Recipe D aplicada. Backup: $BACKUP_DIR/"
echo "INVARIANTE: reaplicar após qualquer 'npm install -g openclaw' ou 'openclaw models auth login'"

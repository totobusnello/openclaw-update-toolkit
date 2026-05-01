#!/usr/bin/env bash
# Recipe K — Cleanup plugin-runtime-deps stale (housekeeping disk)
set -euo pipefail
if [[ $EUID -ne 0 ]]; then echo "ERRO: rode como root"; exit 1; fi

echo "## Recipe K — Cleanup plugin-runtime-deps stale"

DEPS_DIR=/root/.openclaw/plugin-runtime-deps
TRASH=/root/.openclaw/_trash-recipe-k

if [[ ! -d "$DEPS_DIR" ]]; then
  echo "✅ SKIP: $DEPS_DIR não existe"
  exit 0
fi

# Listar dirs por atime (mais recente = ATIVO)
echo "Dirs em plugin-runtime-deps (ordenados por atime, mais recente = ATIVO):"
TMPFILE=$(mktemp)
for D in "$DEPS_DIR"/openclaw-*; do
  [[ -d "$D" ]] || continue
  echo "$(stat -c '%X' "$D") $D" >> "$TMPFILE"
done
sort -rn "$TMPFILE" | head -10

ACTIVE_DIR=$(sort -rn "$TMPFILE" | head -1 | awk '{print $2}')
echo
echo "ACTIVE: $ACTIVE_DIR"

# Identificar candidatos: dirs com atime > 24h E não ACTIVE
CANDIDATES=()
NOW=$(date +%s)
while IFS= read -r LINE; do
  ATIME=$(echo "$LINE" | awk '{print $1}')
  D=$(echo "$LINE" | awk '{print $2}')
  if [[ "$D" == "$ACTIVE_DIR" ]]; then continue; fi
  AGE=$((NOW - ATIME))
  if [[ "$AGE" -gt 86400 ]]; then
    CANDIDATES+=("$D")
  fi
done < "$TMPFILE"
rm "$TMPFILE"

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  echo "✅ SKIP: nenhum dir candidato (todos com atime recente — possivelmente em uso)"
  exit 0
fi

echo
echo "Candidatos pra delete (atime > 24h):"
for D in "${CANDIDATES[@]}"; do
  echo "  - $D ($(du -sh "$D" 2>/dev/null | awk '{print $1}'))"
done

echo
echo "Confirmação: digitar 'yes' pra prosseguir (Ctrl-C pra cancelar):"
read -r CONFIRM < /dev/tty
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Cancelado."
  exit 0
fi

# Mover pra trash (reversível)
mkdir -p "$TRASH"
for D in "${CANDIDATES[@]}"; do
  mv "$D" "$TRASH/"
  echo "  moved: $(basename "$D") → $TRASH"
done

# Aguardar e validar gateway
echo "Aguardando 30s pra validar gateway healthy pós-move..."
sleep 30
if ! systemctl is-active --quiet openclaw-gateway; then
  echo "❌ Gateway caiu! Revertendo..."
  for D in "$TRASH"/openclaw-*; do
    mv "$D" "$DEPS_DIR/"
  done
  systemctl restart openclaw-gateway
  exit 3
fi

# Hard delete
echo "Hard delete..."
for D in "$TRASH"/openclaw-*; do
  # Remover chattr +i de patches anteriores se houver
  find "$D" -name '*.js' -exec chattr -i {} \; 2>/dev/null || true
  rm -rf "$D"
done
rmdir "$TRASH" 2>/dev/null || true

echo
echo "Disk após cleanup:"
df -h /root | tail -1
du -sh "$DEPS_DIR"

echo "✅ Recipe K aplicada"

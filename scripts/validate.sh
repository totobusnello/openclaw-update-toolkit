#!/usr/bin/env bash
# OpenClaw Update Toolkit — Phase 5 Validation
# Read-only. Roda 10 invariants check pra confirmar instalação saudável pós-fix.
# https://github.com/totobusnello/openclaw-update-toolkit
#
# USAGE:
#   bash scripts/validate.sh
#
# OUTPUT:
#   10 checks (✅/❌) + summary final.
#   Exit code = número de checks falhados (0 = tudo OK).

if [[ $EUID -ne 0 ]]; then
  echo "ERRO: este script precisa rodar como root"
  exit 1
fi

CONFIG=/root/.openclaw/openclaw.json
CLAUDE_SETTINGS=/root/.claude/settings.json
PASS=0
FAIL=0
declare -a FAILED_CHECKS=()

check() {
  local name="$1"
  local cmd="$2"
  local recipe="$3"
  if eval "$cmd" >/dev/null 2>&1; then
    echo "✅ $name"
    PASS=$((PASS+1))
  else
    echo "❌ $name → ver $recipe"
    FAIL=$((FAIL+1))
    FAILED_CHECKS+=("$name → $recipe")
  fi
}

echo "# OpenClaw Update Toolkit — 14-invariant Validation (v5.2-aware)"
echo "**Gerado em:** $(date -Iseconds)"
echo

if [[ ! -f "$CONFIG" ]]; then
  echo "ERRO: $CONFIG não existe"
  exit 99
fi

# 1. model.primary é anthropic/<model>
check "model.primary é anthropic/<model>" \
  '[ -n "$(jq -r .agents.defaults.model.primary "$CONFIG" 2>/dev/null)" ] && jq -r .agents.defaults.model.primary "$CONFIG" | grep -q "^anthropic/"' \
  "Recipe A/B"

# 2. baseUrl correto
check "anthropic.baseUrl == https://api.anthropic.com" \
  'jq -r .models.providers.anthropic.baseUrl "$CONFIG" 2>/dev/null | grep -q "^https://api.anthropic.com$"' \
  "Recipe F"

# 3. RelayPlane inactive
check "RelayPlane inactive (ou ausente)" \
  '! systemctl is-active --quiet relayplane-proxy 2>/dev/null' \
  "Recipe F"

# 4. fallback chain sem anthropic-max
check "fallback chain sem anthropic-max" \
  '! jq -r ".agents.defaults.model.fallbacks // [] | join(\",\")" "$CONFIG" 2>/dev/null | grep -q anthropic-max' \
  "Recipe C"

# 5. gateway active + NRestarts=0
check "gateway active + NRestarts=0" \
  'systemctl is-active --quiet openclaw-gateway && [ "$(systemctl show -p NRestarts --value openclaw-gateway 2>/dev/null)" = "0" ]' \
  "Recipe D (fratricide)"

# 6. monkey-patch fratricide aplicado
check "monkey-patch fratricide aplicado" \
  'grep -qE "MONKEY-PATCH.*62028|return \[\];" /usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js 2>/dev/null' \
  "Recipe D"

# 7. telegram plugin desabilitado
check "telegram MCP plugin desabilitado" \
  '[ ! -f "$CLAUDE_SETTINGS" ] || [ "$(jq -r ".enabledPlugins[\"telegram@claude-plugins-official\"] // false" "$CLAUDE_SETTINGS" 2>/dev/null)" != "true" ]' \
  "Recipe G"

# 8. credentials.json imutável (se existir)
check "credentials.json imutável (chattr +i)" \
  '[ ! -f /root/.claude/.credentials.json ] || lsattr /root/.claude/.credentials.json 2>/dev/null | grep -q "^----i"' \
  "Recipe E"

# 9. session.dmScope per-channel-peer (ou explicitamente outro non-main)
check "session.dmScope != main" \
  '[ "$(jq -r .session.dmScope "$CONFIG" 2>/dev/null)" != "main" ] && [ "$(jq -r .session.dmScope "$CONFIG" 2>/dev/null)" != "null" ]' \
  "Recipe H"

# 10. zero anthropic API calls última hora
check "zero anthropic API calls última hora" \
  '[ "$(journalctl -u openclaw-gateway --since "1 hour ago" --no-pager 2>/dev/null | grep -cE "api\.anthropic\.com|x-api-key")" = "0" ]' \
  "Recipe B"

# ============================================================================
# Invariants 11-14 — v5.2-aware checks (skip se versão < 5.2)
# ============================================================================
INSTALLED_VERSION=$(openclaw --version 2>/dev/null | awk '{print $2}' | head -1)
INSTALLED_MAJOR=$(echo "$INSTALLED_VERSION" | awk -F. '{print $2}')
INSTALLED_MINOR=$(echo "$INSTALLED_VERSION" | awk -F. '{print $3}')
IS_V5_2_PLUS=false
if [[ -n "$INSTALLED_MAJOR" ]] && { [[ "$INSTALLED_MAJOR" -gt 4 ]] || { [[ "$INSTALLED_MAJOR" -eq 5 ]] && [[ "$INSTALLED_MINOR" -ge 2 ]]; }; }; then
  IS_V5_2_PLUS=true
fi

# 11. web_search provider aponta pra plugin enabled+loaded (ou unset)
check "tools.web.search.provider plugin instalado+enabled (ou unset)" \
  'WS=$(jq -r ".tools.web.search.provider // \"none\"" "$CONFIG" 2>/dev/null);
   [ "$WS" = "none" ] || \
   openclaw plugins list --json 2>/dev/null | jq -e --arg p "$WS" ".plugins[] | select(.id==\$p and .enabled==true and .status==\"loaded\")" >/dev/null' \
  "Recipe M"

# 12. sem chattr +i bloqueando node_modules global (warn pré-upgrade)
check "sem chattr +i em /usr/lib/node_modules/openclaw (warn pré-upgrade)" \
  '[ "$(find /usr/lib/node_modules/openclaw -type f -exec lsattr {} \; 2>/dev/null | grep -c "^----i" || echo 0)" = "0" ] || \
   { echo "    INFO: imutáveis presentes — Recipe N obrigatória ANTES do próximo npm install -g openclaw@<v>" >&2; true; }' \
  "Recipe N (preventiva)"

# 13. plugins externalizados (configurados) estão presentes em /root/.openclaw/npm/node_modules/@openclaw/
if [[ "$IS_V5_2_PLUS" == "true" ]]; then
  check "plugins externalizados configurados estão fisicamente presentes" \
    'EXT_DIR=/root/.openclaw/npm/node_modules/@openclaw;
     for cfg_plugin in $(jq -r ".plugins.entries // {} | keys[]?" "$CONFIG" 2>/dev/null); do
       case "$cfg_plugin" in
         whatsapp|discord|voice-call|memory-lancedb|matrix|mattermost|brave|acpx|diffs|google-chat|line|microsoft-teams)
           if [ ! -d "$EXT_DIR/$cfg_plugin" ] && [ ! -d "/usr/lib/node_modules/openclaw/dist/extensions/$cfg_plugin" ]; then
             exit 1
           fi ;;
       esac
     done;
     exit 0' \
    "Recipe O"
else
  echo "ℹ️ skip check 13 (plugin externalization) — versão atual < 5.2"
fi

# 14. meta.lastTouchedVersion atualizado (doctor repair rodou pra 5.2+)
if [[ "$IS_V5_2_PLUS" == "true" ]]; then
  check "meta.lastTouchedVersion == installed (doctor repair rodou)" \
    'LTV=$(jq -r ".meta.lastTouchedVersion // \"unset\"" "$CONFIG" 2>/dev/null);
     [ "$LTV" = "$(openclaw --version 2>/dev/null | awk "{print \$2}")" ]' \
    "Reiniciar gateway pra disparar doctor (passa naturalmente após primeiro request)"
else
  echo "ℹ️ skip check 14 (lastTouchedVersion) — versão atual < 5.2"
fi

echo
echo "---"
echo
echo "**Total: $PASS passou, $FAIL falhou**"
echo

if [[ "$FAIL" -gt 0 ]]; then
  echo "**Recipes pendentes:**"
  for c in "${FAILED_CHECKS[@]}"; do
    echo "- $c"
  done
  echo
  echo "Ver \`docs/recovery-guide.md\` pra cada Recipe."
else
  echo "🎉 Instalação **saudável e blindada**. Nenhuma ação necessária."
fi

exit $FAIL

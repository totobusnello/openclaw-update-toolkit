#!/usr/bin/env bash
# OpenClaw Update Toolkit — Phase 0 Diagnostic
# Read-only. Coleta estado completo da instalação OpenClaw em ~3min.
# https://github.com/totobusnello/openclaw-update-toolkit
#
# USAGE:
#   bash scripts/diagnostic.sh
#   curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/diagnostic.sh | bash
#
# OUTPUT:
#   Markdown table com 14 seções de estado. Saída pra stdout — pipe pra arquivo se quiser.
#   Cada seção mapeada pra fix recipe específica em docs/recovery-guide.md.

set +e  # diagnostic é read-only — não abortar em comandos que falham (graceful)

if [[ $EUID -ne 0 ]]; then
  echo "ERRO: este script precisa rodar como root (gateway state está em /root/)"
  echo "Tente: sudo bash $0"
  exit 1
fi

if [[ ! -d /root/.openclaw ]]; then
  echo "ERRO: /root/.openclaw não existe — OpenClaw provavelmente não está instalado"
  exit 1
fi

CONFIG=/root/.openclaw/openclaw.json
CLAUDE_SETTINGS=/root/.claude/settings.json

echo "# OpenClaw Diagnostic Report"
echo "**Gerado em:** $(date -Iseconds)"
echo "**Hostname:** $(hostname)"
echo

echo "## A. Versão e processo"
openclaw --version 2>/dev/null || echo "openclaw CLI ausente"
echo
echo "Processos openclaw ativos:"
ps -ef | grep -i openclaw | grep -v grep | awk '{print $2, $3, $9, $10}' || echo "(nenhum)"
echo
echo "Service state:"
systemctl is-active openclaw-gateway 2>/dev/null || echo "(service ausente)"
systemctl status openclaw-gateway --no-pager 2>/dev/null | grep -E "Active|Memory|Tasks|Main PID" | head -5
echo

echo "## B. Restart counter (saúde)"
systemctl show openclaw-gateway -p NRestarts -p Restart 2>/dev/null
FRATRICIDE_COUNT=$(journalctl -u openclaw-gateway --since "2 hours ago" --no-pager 2>/dev/null | grep -cE "Gateway already running|SIGTERM|cleanStaleGateway" || echo 0)
echo "Fratricide indicators (2h): $FRATRICIDE_COUNT"
echo

echo "## C. Monkey-patch fratricide #62028"
PATCH_FILE=""
for F in /usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js; do
  if [[ -f "$F" ]] && [[ $(wc -l < "$F" 2>/dev/null) -gt 100 ]]; then
    PATCH_FILE="$F"
    break
  fi
done
if [[ -n "$PATCH_FILE" ]]; then
  if grep -qE "MONKEY-PATCH.*62028|return \[\];" "$PATCH_FILE"; then
    echo "✅ Patch presente em: $PATCH_FILE"
    grep -A2 "function cleanStaleGatewayProcessesSync" "$PATCH_FILE" | head -5
  else
    echo "❌ PATCH MISSING — risco de fratricide loop em qualquer restart!"
  fi
else
  echo "⚠️ patch file não encontrado em /usr/lib/node_modules/openclaw/dist/"
fi
echo

echo "## D. Custo zero — claude-cli ativo?"
PROVIDER_USAGE=$(journalctl -u openclaw-gateway --since "1 hour ago" --no-pager 2>/dev/null | grep -E "provider=claude-cli|provider=anthropic[^-]" | tail -3)
if [[ -n "$PROVIDER_USAGE" ]]; then
  echo "$PROVIDER_USAGE"
else
  echo "(sem activity nos últimos 60min)"
fi
ANTHROPIC_CALLS=$(journalctl -u openclaw-gateway --since "1 hour ago" --no-pager 2>/dev/null | grep -cE "api\.anthropic\.com|x-api-key" || echo 0)
if [[ "$ANTHROPIC_CALLS" -eq 0 ]]; then
  echo "✅ Anthropic API calls (PAID path): 0"
else
  echo "❌ Anthropic API calls (PAID path): $ANTHROPIC_CALLS — Recipe B + C necessárias"
fi
echo

echo "## E. Agents runtime config"
if [[ -f "$CONFIG" ]]; then
  jq -r '.agents.list[]? | "\(.id): runtime=\(.agentRuntime.id // "DEFAULT") model=\(.model.primary // "default")"' "$CONFIG" 2>/dev/null || echo "(config malformado ou estrutura diferente)"
  echo "defaults:"
  jq '.agents.defaults | {agentRuntime: .agentRuntime.id, model: .model.primary, fallbacks: .model.fallbacks}' "$CONFIG" 2>/dev/null
fi
echo

echo "## F. Telegram conflict (last hour / 24h)"
CONFLICT_1H=$(journalctl -u openclaw-gateway --since "1 hour ago" --no-pager 2>/dev/null | grep -cE "telegram.*conflict|409.*Conflict" || echo 0)
CONFLICT_24H=$(journalctl -u openclaw-gateway --since "24 hours ago" --no-pager 2>/dev/null | grep -cE "telegram.*conflict|409.*Conflict" || echo 0)
echo "1h: $CONFLICT_1H | 24h: $CONFLICT_24H"
if [[ "$CONFLICT_1H" -gt 0 ]] || [[ "$CONFLICT_24H" -gt 5 ]]; then
  echo "⚠️ Recipe G — duplicate poller suspeito"
fi
echo

echo "## G. Claude CLI plugins habilitados (root user)"
if [[ -f "$CLAUDE_SETTINGS" ]]; then
  jq '.enabledPlugins // {}' "$CLAUDE_SETTINGS" 2>/dev/null
  echo "Has channels preset (legacy):"
  jq 'has("channels")' "$CLAUDE_SETTINGS" 2>/dev/null
  TELEGRAM_ENABLED=$(jq -r '.enabledPlugins["telegram@claude-plugins-official"] // false' "$CLAUDE_SETTINGS" 2>/dev/null)
  if [[ "$TELEGRAM_ENABLED" == "true" ]]; then
    echo "❌ telegram MCP plugin HABILITADO — Recipe G urgente"
  fi
else
  echo "(claude settings ausente em $CLAUDE_SETTINGS)"
fi
echo

echo "## H. Credentials state (Claude CLI OAuth Max)"
if [[ -f /root/.claude/.credentials.json ]]; then
  ls -la /root/.claude/.credentials.json
  ATTRS=$(lsattr /root/.claude/.credentials.json 2>/dev/null | awk '{print $1}')
  echo "attrs: $ATTRS"
  if [[ "$ATTRS" == *"i"* ]]; then
    echo "✅ chattr +i aplicado"
  else
    echo "⚠️ chattr +i AUSENTE — Recipe E (credentials.json trunca ciclicamente sem TTY)"
  fi
else
  echo "❌ credentials.json AUSENTE — claude setup-token necessário (Recipe E)"
fi
echo

echo "## I. Session config + reload mode"
if [[ -f "$CONFIG" ]]; then
  jq '{session: .session, reload: .gateway.reload, mdns: .discovery.mdns.mode, commands_restart: .commands.restart}' "$CONFIG" 2>/dev/null
fi
echo

echo "## J. Anthropic provider baseUrl"
BASEURL=$(jq -r '.models.providers.anthropic.baseUrl // "missing"' "$CONFIG" 2>/dev/null)
echo "baseUrl: $BASEURL"
if [[ "$BASEURL" == *"4100"* ]] || [[ "$BASEURL" == *"127.0.0.1"* ]]; then
  echo "❌ baseUrl aponta pra RelayPlane local — Recipe F"
elif [[ "$BASEURL" == "https://api.anthropic.com" ]]; then
  echo "✅ baseUrl correto"
else
  echo "⚠️ baseUrl inesperado — investigar"
fi
echo

echo "## K. RelayPlane proxy (deve estar inactive)"
RELAY_STATE=$(systemctl is-active relayplane-proxy 2>/dev/null || echo "inactive (ou ausente)")
echo "$RELAY_STATE"
if [[ "$RELAY_STATE" == "active" ]]; then
  echo "❌ RelayPlane ativo — Recipe F"
fi
echo

echo "## L. Auth profiles (modes)"
if [[ -f "$CONFIG" ]]; then
  jq '.auth.profiles // {} | to_entries | map({k: .key, mode: .value.mode})' "$CONFIG" 2>/dev/null
fi
echo

echo "## M. Plugin-runtime-deps disk usage"
du -sh /root/.openclaw/plugin-runtime-deps/openclaw-* 2>/dev/null | head -10 || echo "(dir vazio ou ausente)"
DIR_COUNT=$(ls -d /root/.openclaw/plugin-runtime-deps/openclaw-* 2>/dev/null | wc -l)
echo "Total dirs: $DIR_COUNT"
if [[ "$DIR_COUNT" -gt 3 ]]; then
  echo "⚠️ Mais de 3 dirs — Recipe K (cleanup stale)"
fi
echo

echo "## N. Stability bundles last 24h (gateway crash forensics)"
RECENT_BUNDLES=$(find /root/.openclaw/logs/stability/ -name '*.json' -mtime -1 2>/dev/null | wc -l)
echo "Bundles 24h: $RECENT_BUNDLES"
if [[ "$RECENT_BUNDLES" -gt 0 ]]; then
  ls -1t /root/.openclaw/logs/stability/*.json 2>/dev/null | head -3
fi
echo

# ============================================================================
# Detecção de versão pra ativar checks v5.2-specific (O, P, Q, R, S)
# ============================================================================
INSTALLED_VERSION=$(openclaw --version 2>/dev/null | awk '{print $2}' | head -1)
INSTALLED_MAJOR=$(echo "$INSTALLED_VERSION" | awk -F. '{print $2}')
INSTALLED_MINOR=$(echo "$INSTALLED_VERSION" | awk -F. '{print $3}')
IS_V5_2_PLUS=false
if [[ -n "$INSTALLED_MAJOR" ]] && { [[ "$INSTALLED_MAJOR" -gt 4 ]] || { [[ "$INSTALLED_MAJOR" -eq 5 ]] && [[ "$INSTALLED_MINOR" -ge 2 ]]; }; }; then
  IS_V5_2_PLUS=true
fi

echo "## O. Web search provider validation (v5.2+ strict — Recipe M)"
WS_PROVIDER=$(jq -r '.tools.web.search.provider // "none"' "$CONFIG" 2>/dev/null)
echo "tools.web.search.provider: $WS_PROVIDER"
if [[ "$WS_PROVIDER" != "none" ]]; then
  # Plugin precisa estar enabled+loaded pro provider funcionar na 5.2
  PROVIDER_PLUGIN_STATE=$(openclaw plugins list --json 2>/dev/null | jq -r --arg p "$WS_PROVIDER" '.plugins[]? | select(.id == $p) | "enabled=\(.enabled // false) status=\(.status // "missing")"' | head -1)
  if [[ -z "$PROVIDER_PLUGIN_STATE" ]]; then
    if [[ "$IS_V5_2_PLUS" == "true" ]]; then
      echo "❌ provider '$WS_PROVIDER' aponta pra plugin AUSENTE — gateway vai recusar boot na 5.2+ — Recipe M urgente"
    else
      echo "⚠️ provider '$WS_PROVIDER' aponta pra plugin ausente (tolerado em <5.2, blocker em 5.2+) — Recipe M preventiva"
    fi
  elif [[ "$PROVIDER_PLUGIN_STATE" == "enabled=false"* ]]; then
    if [[ "$IS_V5_2_PLUS" == "true" ]]; then
      echo "❌ plugin '$WS_PROVIDER' DISABLED — Recipe M (trocar pra 'duckduckgo' ou enable plugin)"
    else
      echo "⚠️ plugin '$WS_PROVIDER' disabled (tolerado pre-5.2, blocker em 5.2+) — Recipe M preventiva antes de upgrade"
    fi
  else
    echo "✅ plugin '$WS_PROVIDER' loaded ($PROVIDER_PLUGIN_STATE)"
  fi
else
  echo "✅ web_search provider não configurado (sem risco)"
fi
echo

echo "## P. chattr +i no node_modules global (Recipe N — pré-upgrade)"
IMMUTABLE_COUNT=$(find /usr/lib/node_modules/openclaw -type f -exec lsattr {} \; 2>/dev/null | grep -c "^----i" || echo 0)
echo "Arquivos imutáveis em /usr/lib/node_modules/openclaw: $IMMUTABLE_COUNT"
if [[ "$IMMUTABLE_COUNT" -gt 0 ]]; then
  echo "⚠️ Recipe N OBRIGATÓRIA antes de qualquer 'npm install -g openclaw@<v>' — chattr +i bloqueia npm rm e quebra binário no meio"
  find /usr/lib/node_modules/openclaw -type f -exec lsattr {} \; 2>/dev/null | grep "^----i" | awk '{print "  ", $NF}' | head -5
else
  echo "✅ sem imutáveis bloqueando — npm install -g pode rodar livre"
fi
echo

echo "## Q. Plugin externalization @openclaw/* (v5.2+ — Recipe O)"
EXT_DIR=/root/.openclaw/npm/node_modules/@openclaw
if [[ -d "$EXT_DIR" ]]; then
  EXT_PLUGINS=$(ls "$EXT_DIR" 2>/dev/null | tr '\n' ' ')
  echo "Externalized plugins instalados: ${EXT_PLUGINS:-(nenhum)}"
  # Verificar se algum config aponta pra plugin ausente fisicamente
  for cfg_plugin in $(jq -r '.plugins.entries // {} | keys[]?' "$CONFIG" 2>/dev/null); do
    if [[ "$cfg_plugin" =~ ^(whatsapp|discord|voice-call|memory-lancedb|matrix|mattermost|brave|acpx|diffs|google-chat|line|microsoft-teams)$ ]]; then
      if [[ ! -d "$EXT_DIR/$cfg_plugin" ]] && [[ ! -d "/usr/lib/node_modules/openclaw/dist/extensions/$cfg_plugin" ]]; then
        if [[ "$IS_V5_2_PLUS" == "true" ]]; then
          echo "❌ '$cfg_plugin' configurado mas AUSENTE — Recipe O (npm install @openclaw/$cfg_plugin)"
        else
          echo "ℹ️ '$cfg_plugin' bundled — sem ação necessária na versão atual"
        fi
      fi
    fi
  done
else
  if [[ "$IS_V5_2_PLUS" == "true" ]]; then
    echo "ℹ️ /root/.openclaw/npm/ ausente — sem plugins externalized instalados (OK se não usa channels externalized)"
  else
    echo "ℹ️ /root/.openclaw/npm/ ausente — esperado em pré-5.2"
  fi
fi
echo

echo "## R. meta.lastTouchedVersion (doctor repair trigger awareness)"
LTV=$(jq -r '.meta.lastTouchedVersion // "unset"' "$CONFIG" 2>/dev/null)
echo "lastTouchedVersion: $LTV"
echo "installed: $INSTALLED_VERSION"
if [[ "$LTV" == "$INSTALLED_VERSION" ]]; then
  echo "✅ doctor repair já executou pra versão atual"
elif [[ "$LTV" == "unset" ]]; then
  echo "⚠️ lastTouchedVersion ausente — doctor pode disparar 'one-time install repair' no próximo restart (revisar config diff antes/depois)"
else
  echo "ℹ️ lastTouchedVersion ($LTV) ≠ installed ($INSTALLED_VERSION) — doctor 'install repair' vai disparar no próximo restart se versão >= 5.2"
fi
echo

echo "## S. Schema 5.2 — agentRuntime.id status"
RT_ID=$(openclaw config get agentRuntime.id 2>/dev/null | tail -1)
if echo "$RT_ID" | grep -qiE "not found|undefined"; then
  if [[ "$IS_V5_2_PLUS" == "true" ]]; then
    echo "✅ agentRuntime.id ausente — esperado em 5.2+ (schema mudou; conceito virou plugin-based)"
  else
    echo "⚠️ agentRuntime.id ausente em pré-5.2 — config antiga ou customizada"
  fi
else
  if [[ "$IS_V5_2_PLUS" == "true" ]]; then
    echo "ℹ️ agentRuntime.id ainda configurado em 5.2+ ($RT_ID) — pode ser ignorado pelo gateway, sem impacto"
  else
    echo "✅ agentRuntime.id: $RT_ID"
  fi
fi
echo

echo "---"
echo
echo "## Summary — quais recipes aplicar?"
echo
echo "Veja \`docs/recovery-guide.md\` ou \`runbooks/upgrade-any-version.md\` (pra upgrades)."
echo "Priorize por severidade: **D > B > G > E > F > C > H > L > K > J**"
if [[ "$IS_V5_2_PLUS" == "true" ]] || [[ -n "$INSTALLED_VERSION" ]]; then
  echo "Recipes v5.2-specific: **N (sempre pré-upgrade) > M (web_search) > O (plugin externalization)**"
fi
echo
echo "_Diagnostic completo. Próximo passo: revisar output + autorizar recipes específicas via Claude Code._"

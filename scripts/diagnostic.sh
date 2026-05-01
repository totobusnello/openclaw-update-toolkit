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
ps -ef | grep -i openclaw | grep -vE 'grep|nox-mem-watch' | awk '{print $2, $3, $9, $10}' || echo "(nenhum)"
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

echo "---"
echo
echo "## Summary — quais recipes aplicar?"
echo
echo "Veja \`docs/recovery-guide.md\` para detalhes de cada recipe."
echo "Priorize por severidade: **D > B > G > E > F > C > H > L > K > J**"
echo
echo "_Diagnostic completo. Próximo passo: revisar output + autorizar recipes específicas via Claude Code._"

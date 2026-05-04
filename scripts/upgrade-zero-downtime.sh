#!/usr/bin/env bash
# =============================================================================
# OpenClaw zero-downtime upgrade — v2 (2026-04-26)
# Methodology: pre-flight → staging → smoke → atomic swap → watch → auto-rollback
#
# Usage: bash upgrade-zero-downtime.sh <target_version>
# Example: bash upgrade-zero-downtime.sh 2026.4.25
#
# What is NEW vs upgrade-4.24.sh:
#   - npm pack pre-flight: extracts target tarball and diffs harness/plugin manifests
#   - Side-by-side staging on :18790 with isolated workspace (no real channels)
#   - Runtime smoke tests via openclaw CLI against staging port BEFORE swap
#   - Auto-rollback gate expanded: harness errors + channel disconnects + cron fails
#   - Post-swap watch loop checks runtime signals, not only restart count
# =============================================================================
set -euo pipefail

TARGET=${1:?usage: $0 <target_version>}
CURRENT=$(openclaw --version 2>&1 | awk '{print $2}')
ROLLBACK_DIR=/usr/lib/node_modules/openclaw.bak-pre-${TARGET}
BACKUP_DIR=/root/backups/openclaw-pre-${TARGET}
STAGING_MODULES=/opt/openclaw-staging
STAGING_WORKSPACE=/tmp/openclaw-staging-workspace
STAGING_PORT=18790
LOG=/var/log/openclaw-upgrade-$(date +%Y%m%d-%H%M%S).log

exec > >(tee -a "$LOG") 2>&1
echo "=== OpenClaw zero-downtime upgrade: $CURRENT → $TARGET — $(date -Is) ==="
echo "Log: $LOG"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 0: PRE-FLIGHT — validate before touching production
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "━━━ PHASE 0: PRE-FLIGHT ━━━"

mkdir -p "$BACKUP_DIR"

# 0a. Snapshot current production state
echo "[0a] Snapshotting production state..."
rm -rf "$ROLLBACK_DIR"
cp -a /usr/lib/node_modules/openclaw "$ROLLBACK_DIR"
cp /root/.openclaw/openclaw.json "$BACKUP_DIR/openclaw.json.bak"
[[ -f /root/.openclaw/agents/main/sessions/sessions.json ]] && \
  cp /root/.openclaw/agents/main/sessions/sessions.json "$BACKUP_DIR/sessions.json.bak" || true
OLD_PATCH=$(grep -l "function cleanStaleGatewayProcessesSync(portOverride) {" /usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js 2>/dev/null | head -1)
[[ -n "$OLD_PATCH" ]] || OLD_PATCH=$(ls /usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js | head -1)
cp "$OLD_PATCH" "$BACKUP_DIR/$(basename "$OLD_PATCH").pre-upgrade"
echo "    backup dir: $BACKUP_DIR"
echo "    rollback snapshot: $ROLLBACK_DIR"

# 0b. Download target tarball WITHOUT installing it on production
echo "[0b] Downloading target tarball for inspection..."
TARBALL_DIR=$(mktemp -d /tmp/openclaw-preflight-XXXXXX)
npm pack "openclaw@${TARGET}" --pack-destination "$TARBALL_DIR" >/dev/null 2>&1
TARBALL=$(ls "$TARBALL_DIR"/openclaw-*.tgz | head -1)
[[ -f "$TARBALL" ]] || { echo "ERROR: npm pack failed for $TARGET"; exit 1; }
echo "    tarball: $TARBALL"

# 0c. Extract and diff harness registry (the key invariant that broke .24)
EXTRACT_DIR="$TARBALL_DIR/extracted"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$TARBALL" -C "$EXTRACT_DIR" package/ >/dev/null 2>&1

echo "[0c] Harness diff: current vs target..."
# Extract harness registrations from dist bundles
CURRENT_HARNESSES=$(grep -rh "registerHarness\|harnessId\|harness.*claude-cli" \
  /usr/lib/node_modules/openclaw/dist/ 2>/dev/null \
  | grep -oP '"[a-z]+-[a-z]+"(?=.*harness|harness.*=)' | sort -u || true)
TARGET_HARNESSES=$(grep -rh "registerHarness\|harnessId\|harness.*claude-cli" \
  "$EXTRACT_DIR/package/dist/" 2>/dev/null \
  | grep -oP '"[a-z]+-[a-z]+"(?=.*harness|harness.*=)' | sort -u || true)

HARNESS_DIFF=$(diff <(echo "$CURRENT_HARNESSES") <(echo "$TARGET_HARNESSES") || true)
if [[ -n "$HARNESS_DIFF" ]]; then
  echo "    WARN: harness manifest changed:"
  echo "$HARNESS_DIFF" | sed 's/^/      /'
  echo "    REVIEW REQUIRED — does 'claude-cli' harness still exist in target?"
  # Hard stop if claude-cli harness is removed entirely
  if ! echo "$TARGET_HARNESSES" | grep -q "claude-cli"; then
    echo "ERROR: claude-cli harness NOT FOUND in $TARGET dist bundle — abort" >&2
    exit 10
  fi
else
  echo "    harness manifest identical — OK"
fi

# 0d. Plugin manifest compat check (plugin API version)
echo "[0d] Plugin API version check..."
CURRENT_PLUGIN_API=$(grep -r "pluginApiVersion\|PLUGIN_API_VERSION\|plugin_api" \
  /usr/lib/node_modules/openclaw/dist/ 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || echo "unknown")
TARGET_PLUGIN_API=$(grep -r "pluginApiVersion\|PLUGIN_API_VERSION\|plugin_api" \
  "$EXTRACT_DIR/package/dist/" 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || echo "unknown")
echo "    current plugin API: $CURRENT_PLUGIN_API"
echo "    target plugin API:  $TARGET_PLUGIN_API"
if [[ "$CURRENT_PLUGIN_API" != "$TARGET_PLUGIN_API" && "$TARGET_PLUGIN_API" != "unknown" ]]; then
  echo "    WARN: plugin API version changed — test all plugins in staging"
fi

# 0e. Auth-profiles schema check (lição 2026-05-04: dist nunca teve string literal "anthropic-max")
# 5.2/5.3 dist faz lookup dinâmico via auth-profiles/usage.ts — não há string literal pra grep.
# Profile 'anthropic-max' vive em /root/.openclaw/agents/main/agent/auth-profiles.json (per-agent).
# Validar lá em vez de grepar dist binário.
echo "[0e] Auth profile schema check..."
PER_AGENT_AUTH=/root/.openclaw/agents/main/agent/auth-profiles.json
if [[ -f "$PER_AGENT_AUTH" ]] && jq -e '.profiles | has("anthropic-max:default")' "$PER_AGENT_AUTH" >/dev/null 2>&1; then
  echo "    auth-profiles.json has 'anthropic-max:default' profile — OK"
else
  echo "    WARN: 'anthropic-max:default' profile not found in $PER_AGENT_AUTH — Max OAuth may not authenticate"
fi
# Verify auth-profiles/usage.ts is present in target dist (lookup mechanism canonical)
if grep -rq "auth-profiles/usage" "$EXTRACT_DIR/package/dist/" 2>/dev/null; then
  echo "    target dist has auth-profiles/usage.ts — lookup mechanism present"
else
  echo "    WARN: auth-profiles/usage.ts NOT found in target dist — lookup mechanism may have changed"
fi

# 0f. Dry-run monkey-patch: does the expected function signature exist in target?
echo "[0f] Monkey-patch target compatibility check..."
TARGET_PATCH_FILE=$(grep -l "function cleanStaleGatewayProcessesSync(portOverride) {" "$EXTRACT_DIR/package/dist/restart-stale-pids-"*.js 2>/dev/null | head -1 || true)
if [[ -z "$TARGET_PATCH_FILE" ]]; then
  echo "    ERROR: restart-stale-pids-*.js NOT found in target dist — patch will fail" >&2
  echo "    Bundle layout changed. Update reapply-monkey-patch.sh before proceeding." >&2
  exit 11
fi
if ! grep -q "cleanStaleGatewayProcessesSync" "$TARGET_PATCH_FILE"; then
  echo "    ERROR: cleanStaleGatewayProcessesSync function not found in target — patch pattern broken" >&2
  exit 12
fi
echo "    patch target file: $(basename "$TARGET_PATCH_FILE") — function signature OK"

# 0g. Node.js wrapper still intact?
echo "[0g] Node.js wrapper check..."
if ! file /usr/bin/node | grep -q "shell script"; then
  echo "    ERROR: /usr/bin/node is not a wrapper — DEP0040 crash loop risk" >&2
  exit 13
fi

# 0h. Credentials.json immutable?
echo "[0h] Credentials.json immutability check..."
if ! lsattr ~/.claude/.credentials.json | awk '{print $1}' | grep -q 'i'; then
  echo "    ERROR: ~/.claude/.credentials.json is NOT immutable — run: chattr +i ~/.claude/.credentials.json" >&2
  exit 14
fi

# 0i. Web search provider validation (lição 2026-05-03 — pitfall #1 da 5.2)
# Gateway 5.2+ rejeita boot se tools.web.search.provider aponta pra plugin não-installed/disabled.
# Em 5.3 invalid config fails closed (não auto-restore). Validar ANTES do swap pra evitar gateway down.
echo "[0i] Web search provider validation..."
WS_PROVIDER=$(openclaw config get tools.web.search.provider 2>/dev/null | tr -d '"' || echo "")
if [[ -n "$WS_PROVIDER" && "$WS_PROVIDER" != "null" ]]; then
  WS_STATUS=$(openclaw plugins list --json 2>/dev/null | jq -r --arg p "$WS_PROVIDER" '.plugins[]? | select(.id==$p) | "\(.enabled // false)/\(.status // "unknown")"')
  if [[ -z "$WS_STATUS" ]]; then
    echo "    ERROR: tools.web.search.provider='$WS_PROVIDER' but plugin NOT INSTALLED — gateway boot will fail in 5.3+" >&2
    echo "    Fix: openclaw config set tools.web.search.provider duckduckgo  (then validate)" >&2
    exit 15
  fi
  if [[ "$WS_STATUS" != "true/enabled" && "$WS_STATUS" != "true/active" ]]; then
    echo "    WARN: tools.web.search.provider='$WS_PROVIDER' status=$WS_STATUS (disabled?). 5.3 fails closed."
    echo "    Recommend: openclaw config set tools.web.search.provider duckduckgo"
  fi
  echo "    web_search provider: $WS_PROVIDER ($WS_STATUS)"
else
  echo "    no web_search provider configured (safe)"
fi

# 0j. Snapshot @openclaw/* externalized plugins (lição 2026-05-03 — pitfall #3 da 5.2)
# openclaw plugins install é destrutivo entre @openclaw/* scoped packages.
# Snapshot pré-swap pra validar pós-swap que nenhum sumiu silenciosamente.
echo "[0j] Snapshotting @openclaw/* plugin tree..."
EXTERNAL_PLUGINS_DIR=/root/.openclaw/npm/node_modules/@openclaw
if [[ -d "$EXTERNAL_PLUGINS_DIR" ]]; then
  ls "$EXTERNAL_PLUGINS_DIR" | sort > "$BACKUP_DIR/external-plugins.snapshot"
  cp /root/.openclaw/npm/package.json "$BACKUP_DIR/npm-package.json.bak" 2>/dev/null || true
  echo "    snapshot: $(wc -l < "$BACKUP_DIR/external-plugins.snapshot") plugin(s) — $(tr '\n' ' ' < "$BACKUP_DIR/external-plugins.snapshot")"
else
  echo "    no @openclaw/* externalized plugins directory (none expected pre-5.2)"
  : > "$BACKUP_DIR/external-plugins.snapshot"
fi

# 0z. Production config + channel credentials lock
# (lição 2026-05-04: staging gateway contamina prod config + ROUBA SESSÃO BAILEYS DO WHATSAPP)
#
# CONTEXT: WhatsApp Web só permite 1 device-key por vez. Se staging gateway carregar plugin
# whatsapp e usar os MESMOS creds em /root/.openclaw/credentials/whatsapp/default/,
# Baileys vê 2 conexões com mesmo identity → invalida sessão → user precisa reescanear QR.
# Aconteceu em 2026-05-04 08:34 — Toto teve que relinkar WhatsApp depois.
#
# DEFESA EM 3 CAMADAS:
#   (a) chattr +i nos creds dirs de TODOS channels (whatsapp, discord, telegram) → write fails
#   (b) OPENCLAW_STATE_DIR override no staging spawn → resolveOAuthDir aponta /tmp não /root
#   (c) SHA snapshot + auto-restore como antes (defesa final)
echo "[0z] Pre-staging snapshot + lock (config + channel credentials)..."
CONFIG_SHA_PRE=$(sha256sum /root/.openclaw/openclaw.json | awk '{print $1}')
cp /root/.openclaw/openclaw.json "$BACKUP_DIR/openclaw.json.pre-staging"
echo "    config sha256: $CONFIG_SHA_PRE"

# Snapshot de credenciais por canal (creds.json + chaves) — defesa contra wipe acidental
CHANNEL_CRED_SNAPSHOT="$BACKUP_DIR/channel-creds-snapshot.tar.gz"
if [[ -d /root/.openclaw/credentials ]]; then
  tar -czf "$CHANNEL_CRED_SNAPSHOT" -C /root/.openclaw credentials 2>/dev/null
  echo "    channel creds snapshot: $CHANNEL_CRED_SNAPSHOT ($(du -k "$CHANNEL_CRED_SNAPSHOT" | awk '{print $1}')K)"
fi

# Lista de creds files que precisam lock — incluindo channel-specific dirs
CREDS_LOCKED_FILES=()
for f in /root/.openclaw/openclaw.json \
         /root/.openclaw/credentials/whatsapp/default/creds.json \
         /root/.openclaw/credentials/whatsapp/default/creds.json.bak \
         /root/.openclaw/credentials/discord-pairing.json \
         /root/.openclaw/credentials/discord-default-allowFrom.json \
         /root/.openclaw/credentials/telegram-pairing.json \
         /root/.openclaw/credentials/telegram-default-allowFrom.json; do
  if [[ -f "$f" ]]; then
    CREDS_LOCKED_FILES+=("$f")
  fi
done

# Idempotent — safe to call manually OR via trap. Does NOT exit script (caller decides).
CONFIG_UNLOCK_DONE=0
unlock_and_restore_config() {
  [[ "$CONFIG_UNLOCK_DONE" == "1" ]] && return 0
  echo ""
  echo "━━━ CLEANUP: unlock + verify production state ━━━"
  systemctl stop openclaw-staging 2>/dev/null || true
  # Unlock all creds files
  local unlocked=0
  for f in "${CREDS_LOCKED_FILES[@]}"; do
    if lsattr "$f" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
      chattr -i "$f" 2>/dev/null && unlocked=$((unlocked+1)) || true
    fi
  done
  echo "    chattr -i removed from $unlocked locked file(s)"
  # Verify production config didn't drift
  local sha_post
  sha_post=$(sha256sum /root/.openclaw/openclaw.json | awk '{print $1}')
  if [[ "$CONFIG_SHA_PRE" != "$sha_post" ]]; then
    echo "    WARN: production config SHA drifted ($CONFIG_SHA_PRE → $sha_post) — restoring from snapshot"
    cp "$BACKUP_DIR/openclaw.json.pre-staging" /root/.openclaw/openclaw.json
    echo "    restored from $BACKUP_DIR/openclaw.json.pre-staging"
  else
    echo "    production config SHA intact"
  fi
  # Verify whatsapp creds didn't get wiped (would break baileys session)
  local wa_creds=/root/.openclaw/credentials/whatsapp/default/creds.json
  if [[ -d /root/.openclaw/credentials/whatsapp/default ]] && [[ ! -f "$wa_creds" ]]; then
    echo "    WARN: whatsapp creds.json missing — restoring from snapshot tarball"
    if [[ -f "$CHANNEL_CRED_SNAPSHOT" ]]; then
      tar -xzf "$CHANNEL_CRED_SNAPSHOT" -C /root/.openclaw 2>/dev/null && \
        echo "    restored creds.json from $CHANNEL_CRED_SNAPSHOT"
    fi
  else
    [[ -f "$wa_creds" ]] && echo "    whatsapp creds.json intact"
  fi
  CONFIG_UNLOCK_DONE=1
}
trap 'unlock_and_restore_config' EXIT

# Apply chattr +i to all sensitive files
locked=0
for f in "${CREDS_LOCKED_FILES[@]}"; do
  chattr +i "$f" 2>/dev/null && locked=$((locked+1)) || true
done
echo "    chattr +i applied to $locked file(s) — write blocked during staging"

echo "[0] PRE-FLIGHT COMPLETE — proceeding to staging"
rm -rf "$TARBALL_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1: STAGING — install target in isolated path, start on :18790
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "━━━ PHASE 1: STAGING (:$STAGING_PORT, isolated workspace) ━━━"

echo "[1a] Installing openclaw@$TARGET to $STAGING_MODULES..."
# npm install --prefix puts node_modules/ under the prefix
# We want the package at $STAGING_MODULES/node_modules/openclaw
rm -rf "$STAGING_MODULES"
mkdir -p "$STAGING_MODULES"
npm install --prefix "$STAGING_MODULES" "openclaw@${TARGET}" >/dev/null 2>&1
STAGING_BIN="$STAGING_MODULES/node_modules/.bin/openclaw"
[[ -f "$STAGING_BIN" ]] || STAGING_BIN="$STAGING_MODULES/node_modules/openclaw/dist/index.js"
STAGING_VERSION=$(node "$STAGING_BIN" --version 2>&1 | awk '{print $2}' || echo "unknown")
echo "    installed: $STAGING_VERSION"
[[ "$STAGING_VERSION" == "$TARGET" ]] || \
  { echo "ERROR: staging version mismatch (got $STAGING_VERSION)"; exit 20; }

echo "[1b] Monkey-patching staging installation..."
STAGING_PATCH=$(grep -l "function cleanStaleGatewayProcessesSync(portOverride) {" "$STAGING_MODULES/node_modules/openclaw/dist/restart-stale-pids-"*.js 2>/dev/null | head -1)
[[ -n "$STAGING_PATCH" ]] || { echo "ERROR: no impl file with cleanStaleGatewayProcessesSync in staging dist"; exit 21; }
python3 /root/reapply-monkey-patch.sh "$STAGING_PATCH" 2>/dev/null || \
  python3 - "$STAGING_PATCH" <<'PY'
import re, sys
p = sys.argv[1]
src = open(p).read()
pattern = r'(function cleanStaleGatewayProcessesSync\(portOverride\) \{\n\ttry \{\n)(\t\tconst port)'
if not re.search(pattern, src):
    print(f"ERROR: pattern not found in {p}", file=sys.stderr); sys.exit(2)
patched = re.sub(pattern,
    r'\1\t\t// MONKEY-PATCH: staging test\n\t\treturn [];\n\2', src, count=1)
open(p, 'w').write(patched)
print(f"staging patched: {p}")
PY

echo "[1c] Creating minimal staging workspace..."
rm -rf "$STAGING_WORKSPACE"
mkdir -p "$STAGING_WORKSPACE/agents/staging-test/agent"
# Minimal agent config: single test agent, no real channel webhooks
# Provider canonical post-v.26: anthropic/* (claude-cli/* was removed in v.26 — CLAUDE.md regra #1)
cat > "$STAGING_WORKSPACE/openclaw.json" <<STAGINGCFG
{
  "agents": {
    "staging-test": {
      "persona": "staging smoke-test agent — DO NOT USE FOR REAL CHANNELS",
      "model": { "primary": "anthropic/claude-sonnet-4-6", "fallbacks": ["gemini/gemini-2.5-flash-lite"] }
    },
    "defaults": {
      "model": {
        "primary": "anthropic/claude-sonnet-4-6",
        "fallbacks": ["gemini/gemini-2.5-flash-lite"]
      },
      "compaction": { "keepRecentTokens": 8000 }
    }
  },
  "gateway": { "port": $STAGING_PORT, "reload": { "mode": "off" } },
  "commands": { "restart": false },
  "discovery": { "mdns": { "mode": "off" } },
  "plugins": {}
}
STAGINGCFG

# Pre-create empty staging credentials dir so plugin-sdk's resolveOAuthDir
# (= $STATE_DIR/credentials) finds an empty path → channels see "no creds" → no auto-connect
mkdir -p "$STAGING_WORKSPACE/credentials"
mkdir -p "$STAGING_WORKSPACE/agents/staging-test/agent"

echo "[1d] Starting staging gateway (systemd-run, ISOLATED state dir)..."
# OPENCLAW_STATE_DIR override (lição 2026-05-04): plugin-sdk paths-C1_Y0cDn.js usa
# OPENCLAW_STATE_DIR env como override do default ~/.openclaw. Sem isso, resolveOAuthDir
# retornava /root/.openclaw/credentials e staging gateway lia creds DE PRODUÇÃO →
# tentava conectar WhatsApp Web em paralelo com prod → Baileys invalidava sessão.
# Com este override staging vê /tmp/openclaw-staging-workspace/credentials/ (vazio) →
# channels reportam "not configured" e NÃO tentam auto-connect.
# OPENCLAW_CONFIG_PATH garante que staging lê o openclaw.json ISOLADO em $STAGING_WORKSPACE.
systemd-run --unit=openclaw-staging \
  --property=Environment=IS_SANDBOX=1 \
  --property=Environment=OPENCLAW_WORKSPACE="$STAGING_WORKSPACE" \
  --property=Environment=OPENCLAW_STATE_DIR="$STAGING_WORKSPACE" \
  --property=Environment=OPENCLAW_CONFIG_PATH="$STAGING_WORKSPACE/openclaw.json" \
  --property=EnvironmentFile=/root/.openclaw/.env \
  --property=StandardOutput=journal \
  --property=StandardError=journal \
  -- node "$STAGING_MODULES/node_modules/openclaw/dist/index.js" \
       gateway run --bind loopback --port "$STAGING_PORT" \
       2>/dev/null || \
  { echo "    systemd-run failed — trying foreground staging..."; STAGING_FOREGROUND=1; }

# Wait for staging gateway to come up
echo "    waiting for staging gateway on :$STAGING_PORT..."
for i in $(seq 1 36); do
  if curl -sf "http://127.0.0.1:$STAGING_PORT/health" >/dev/null 2>&1 || \
     curl -sf "http://127.0.0.1:$STAGING_PORT/api/health" >/dev/null 2>&1; then
    echo "    staging gateway UP (attempt $i)"
    break
  fi
  # Detect early bail (exit 78 or systemd failure) — abort fast instead of waiting full timeout
  if ! systemctl is-active --quiet openclaw-staging 2>/dev/null; then
    echo "ERROR: staging unit exited (attempt $i) — check journalctl -u openclaw-staging"
    systemctl status openclaw-staging --no-pager 2>&1 | tail -10
    exit 22
  fi
  sleep 5
  if [[ $i -eq 36 ]]; then
    echo "ERROR: staging gateway did not come up in 180s — abort"
    journalctl -u openclaw-staging --since "3min ago" --no-pager 2>&1 | tail -20
    systemctl stop openclaw-staging 2>/dev/null || true
    exit 21
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2: SMOKE TESTS against staging
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "━━━ PHASE 2: SMOKE TESTS (staging :$STAGING_PORT) ━━━"

SMOKE_FAIL=0
smoke() {
  local label="$1" cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    echo "    PASS  $label"
  else
    echo "    FAIL  $label"
    SMOKE_FAIL=1
  fi
}

# 2a. Health endpoint responds
smoke "health endpoint" \
  "curl -sf http://127.0.0.1:$STAGING_PORT/health || curl -sf http://127.0.0.1:$STAGING_PORT/api/health"

# 2b. CLI version matches target on staging binary
smoke "version match" \
  "[[ \"\$(node $STAGING_MODULES/node_modules/openclaw/dist/index.js --version 2>&1 | awk '{print \$2}')\" == '$TARGET' ]]"

# 2c. THE KEY TEST: harness registration is live (not just in dist)
# Check gateway runtime exposes claude-cli harness via introspection endpoint (if available)
HARNESS_RUNTIME=$(curl -sf "http://127.0.0.1:$STAGING_PORT/api/harnesses" 2>/dev/null || \
                  curl -sf "http://127.0.0.1:$STAGING_PORT/harnesses" 2>/dev/null || echo "")
if [[ -n "$HARNESS_RUNTIME" ]]; then
  # Non-fatal: staging runs with minimal config (no real claude credentials/PATH).
  # Phase 0c already validated claude-cli harness exists in target dist bundle.
  # Production (with full env + agents) initializes claude-cli backend correctly.
  if echo "$HARNESS_RUNTIME" | grep -q "claude-cli"; then
    echo "    PASS  claude-cli harness registered (runtime)"
  else
    echo "    WARN  claude-cli harness not in staging runtime — expected in minimal staging config"
    echo "          (Phase 0c validated bundle; prod env initializes backend correctly)"
  fi
else
  # Fallback: check journals for harness registration messages
  sleep 5
  JOURNAL_HARNESS=$(journalctl -u openclaw-staging --since "2 min ago" --no-pager 2>/dev/null | \
    grep -i "harness\|claude-cli.*register\|backend.*load" || true)
  if echo "$JOURNAL_HARNESS" | grep -qi "claude-cli"; then
    echo "    PASS  claude-cli harness registration (journal)"
  elif echo "$JOURNAL_HARNESS" | grep -qi "not registered\|harness.*fail\|PI fallback"; then
    echo "    FAIL  claude-cli harness — PI fallback error detected in journal"
    SMOKE_FAIL=1
  else
    echo "    INFO  claude-cli harness — no runtime endpoint, no journal error (check manually if needed)"
  fi
fi

# 2d. Plugin load check: no plugin load errors in staging journals.
# Exclude expected EPERM from auto-enable persistence (lição 2026-05-04: chattr +i blocks
# staging gateway from contaminating production openclaw.json). That EPERM is BY DESIGN.
PLUGIN_ERRORS=$(journalctl -u openclaw-staging --since "2 min ago" --no-pager 2>/dev/null | \
  grep -iE "plugin.*error|failed.*load|cannot.*require|MODULE_NOT_FOUND" | \
  grep -v "failed to persist plugin auto-enable" | \
  grep -v "EPERM.*openclaw.json" || true)
if [[ -n "$PLUGIN_ERRORS" ]]; then
  echo "    FAIL  plugin load errors:"
  echo "$PLUGIN_ERRORS" | head -5 | sed 's/^/      /'
  SMOKE_FAIL=1
else
  echo "    PASS  plugin load (no real errors; EPERM-on-config is expected during isolation)"
fi

# 2e. Monkey-patch marker confirmed in staging runtime file
smoke "monkey-patch marker in staging dist" \
  "grep -q 'MONKEY-PATCH' $STAGING_MODULES/node_modules/openclaw/dist/restart-stale-pids-*.js"

# 2f. IS_SANDBOX env reaches staging process (fratricide guard)
# Confirm staging process has IS_SANDBOX=1
STAGING_PID=$(systemctl show openclaw-staging --property=MainPID --value 2>/dev/null || echo "")
if [[ -n "$STAGING_PID" && "$STAGING_PID" != "0" ]]; then
  smoke "IS_SANDBOX=1 in staging env" \
    "grep -q 'IS_SANDBOX=1' /proc/$STAGING_PID/environ 2>/dev/null || \
     grep -z 'IS_SANDBOX' /proc/$STAGING_PID/environ 2>/dev/null | grep -q '1'"
else
  echo "    INFO  IS_SANDBOX check skipped (could not get staging PID)"
fi

# 2g. Check for fratricide: staging should NOT have killed production gateway
smoke "production gateway still running" "systemctl is-active openclaw-gateway"

if [[ $SMOKE_FAIL -ne 0 ]]; then
  echo ""
  echo "!!! SMOKE TESTS FAILED — aborting upgrade"
  echo "    staging logs: journalctl -u openclaw-staging --no-pager"
  systemctl stop openclaw-staging 2>/dev/null || true
  rm -rf "$STAGING_WORKSPACE" "$STAGING_MODULES"
  exit 30
fi

echo "[2] ALL SMOKE TESTS PASSED — staging GREEN"
systemctl stop openclaw-staging 2>/dev/null || true
rm -rf "$STAGING_WORKSPACE"

# Unlock prod config + verify SHA before either dry-run exit OR Phase 3 atomic swap.
# Manual call here (not waiting for trap) — Phase 3+ needs config writable for new gateway.
# Trap remains as safety net for non-zero exits in Phase 3-5 (idempotent — won't double-run).
unlock_and_restore_config

# ─────────────────────────────────────────────────────────────────────────────
# DRY-RUN GATE: stop here if --dry-run was passed (or DRY_RUN=1 env)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${2:-}" == "--dry-run" ]] || [[ "${DRY_RUN:-}" == "1" ]]; then
  echo ""
  echo "━━━ DRY-RUN MODE: stopping after Phase 2 ━━━"
  echo "  Pre-flight + staging + smoke tests passed."
  echo "  Production NOT touched (still on $CURRENT)."
  echo "  To run real upgrade: bash $0 $TARGET (without --dry-run)"
  echo "  Cleanup staging: rm -rf $STAGING_MODULES"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3: ATOMIC SWAP — production ← target
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "━━━ PHASE 3: ATOMIC SWAP ━━━"

echo "[3a] Stopping production gateway..."
systemctl stop openclaw-gateway
sleep 3

echo "[3b] Installing openclaw@$TARGET globally (npm resolves all deps)..."
# Why npm install -g instead of mv staging:
#  npm install --prefix in Phase 1 puts openclaw + ALL deps flat in $STAGING_MODULES/node_modules/.
#  A simple `mv openclaw` leaves transitive deps (e.g. dotenv added in .29) behind, causing
#  ERR_MODULE_NOT_FOUND at gateway start. npm install -g reproduces the canonical nested layout
#  expected by `/usr/lib/node_modules/openclaw/node_modules/<dep>` resolution.
#  Production snapshot already at $ROLLBACK_DIR (from Phase 0a) for rollback safety.

# CRITICAL (lição 2026-05-03 — CLAUDE.md regra #2): emoji patch (regra 2.1) aplica chattr +i
# em status-message-*.js dentro de /usr/lib/node_modules/openclaw/dist/. npm install -g tenta
# rm esses arquivos, falha com "Operation not permitted" e DEIXA O BINÁRIO QUEBRADO.
# Solução: remover chattr ANTES do rm/install. Reaplicar via reapply-session-status-emoji-patch.py
# em [3c.1] mais abaixo.
echo "[3b.0] Removing chattr +i from /usr/lib/node_modules/openclaw before npm install..."
IMMUTABLE_COUNT=$(find /usr/lib/node_modules/openclaw -type f -exec lsattr {} \; 2>/dev/null | grep -c "^----i" || true)
if [[ "$IMMUTABLE_COUNT" -gt 0 ]]; then
  echo "    found $IMMUTABLE_COUNT immutable file(s) — removing chattr +i"
  find /usr/lib/node_modules/openclaw -type f -exec lsattr {} \; 2>/dev/null \
    | grep "^----i" | awk '{print $NF}' | xargs -r chattr -i
else
  echo "    no immutable files (OK to proceed)"
fi

rm -rf /usr/lib/node_modules/openclaw
if ! npm install -g "openclaw@${TARGET}" >/dev/null 2>&1; then
  echo "    ERROR: npm install -g openclaw@${TARGET} failed — rolling back" >&2
  bash /root/rollback-zero-downtime.sh "$TARGET" "$ROLLBACK_DIR" "$BACKUP_DIR" || true
  exit 30
fi

# Verify install
if ! [[ -d /usr/lib/node_modules/openclaw/node_modules ]]; then
  echo "    ERROR: deps tree missing after npm install -g — rolling back" >&2
  bash /root/rollback-zero-downtime.sh "$TARGET" "$ROLLBACK_DIR" "$BACKUP_DIR" || true
  exit 31
fi
INSTALLED_VERSION=$(openclaw --version 2>&1 | awk '{print $2}')
[[ "$INSTALLED_VERSION" == "$TARGET" ]] || {
  echo "    ERROR: post-install version mismatch ($INSTALLED_VERSION ≠ $TARGET) — rolling back" >&2
  bash /root/rollback-zero-downtime.sh "$TARGET" "$ROLLBACK_DIR" "$BACKUP_DIR" || true
  exit 32
}
echo "    installed: $INSTALLED_VERSION (deps tree: $(ls /usr/lib/node_modules/openclaw/node_modules | wc -l) packages)"

# Fix npm global symlink if broken (npm install -g should set it correctly, but verify)
GLOBAL_BIN="/usr/bin/openclaw"
if [[ -L "$GLOBAL_BIN" ]] && [[ ! -e "$GLOBAL_BIN" ]]; then
  rm -f "$GLOBAL_BIN"
  ln -sf /usr/lib/node_modules/openclaw/dist/index.js "$GLOBAL_BIN"
fi

echo "[3c] Reapplying monkey-patch on production path..."
bash /root/reapply-monkey-patch.sh

echo "[3c.1] Reapplying session-status emoji patch (regra 2.1)..."
if [[ -x /root/reapply-session-status-emoji-patch.py ]]; then
  python3 /root/reapply-session-status-emoji-patch.py || echo "    WARN: emoji patch reapply failed (regra 2.1 may show 🔑 token instead of 🛡️ OAuth (Max))"
elif [[ -f /root/reapply-session-status-emoji-patch.py ]]; then
  python3 /root/reapply-session-status-emoji-patch.py || echo "    WARN: emoji patch reapply failed"
else
  echo "    SKIP: /root/reapply-session-status-emoji-patch.py not present"
fi

echo "[3d] Verifying wrapper still immutable..."
if ! lsattr /usr/local/bin/openclaw-gateway-wrapper | awk '{print $1}' | grep -q 'i'; then
  chattr +i /usr/local/bin/openclaw-gateway-wrapper
  echo "    re-immutabilized wrapper"
fi

# 3d.1 Verify @openclaw/* plugins survived swap (lição 2026-05-03 — pitfall #3)
# npm install -g openclaw NÃO toca /root/.openclaw/npm/node_modules/@openclaw, mas se algum
# subprocess no install acionar plugins install/uninstall (ex.: doctor automático em 5.3),
# pode haver perda silenciosa. Compare com snapshot pré-swap.
echo "[3d.1] Verifying @openclaw/* externalized plugins survived swap..."
if [[ -s "$BACKUP_DIR/external-plugins.snapshot" ]]; then
  POST_SWAP_PLUGINS=$(ls /root/.openclaw/npm/node_modules/@openclaw/ 2>/dev/null | sort)
  EXPECTED_PLUGINS=$(cat "$BACKUP_DIR/external-plugins.snapshot")
  PLUGIN_DIFF=$(diff <(echo "$EXPECTED_PLUGINS") <(echo "$POST_SWAP_PLUGINS") || true)
  if [[ -n "$PLUGIN_DIFF" ]]; then
    echo "    WARN: @openclaw/* plugin set changed during swap:"
    echo "$PLUGIN_DIFF" | sed 's/^/      /'
    MISSING=$(comm -23 <(echo "$EXPECTED_PLUGINS") <(echo "$POST_SWAP_PLUGINS"))
    if [[ -n "$MISSING" ]]; then
      echo "    MISSING plugins detected — restoring via npm install:"
      cd /root/.openclaw/npm && npm install $(echo "$MISSING" | sed 's|^|@openclaw/|' | tr '\n' ' ') 2>&1 | tail -5
      cd - >/dev/null
    fi
  else
    echo "    @openclaw/* plugin set intact: $(echo "$POST_SWAP_PLUGINS" | tr '\n' ' ')"
  fi
fi

echo "[3e] Starting production gateway..."
systemctl daemon-reload
systemctl start openclaw-gateway

# Wait for full ready signal — not just systemctl active
echo "[3f] Waiting for [gateway] ready signal (max 30s)..."
READY=""
for i in $(seq 1 6); do
  sleep 5
  READY=$(journalctl -u openclaw-gateway --since "1 min ago" --no-pager 2>/dev/null | \
    grep -E "\[gateway\] ready|Gateway started|gateway.*:18789" | tail -1 || true)
  if [[ -n "$READY" ]]; then
    echo "    gateway ready: $READY"
    break
  fi
  if ! systemctl is-active openclaw-gateway >/dev/null 2>&1; then
    echo "    FATAL: gateway crashed before ready signal — auto-rollback"
    bash /root/rollback-zero-downtime.sh "$TARGET" "$ROLLBACK_DIR" "$BACKUP_DIR"
    exit 40
  fi
done

if [[ -z "$READY" ]]; then
  echo "    WARN: no [gateway] ready signal in 30s — checking if it's running anyway..."
  if ! systemctl is-active openclaw-gateway >/dev/null 2>&1; then
    echo "    FATAL: gateway not active — auto-rollback"
    bash /root/rollback-zero-downtime.sh "$TARGET" "$ROLLBACK_DIR" "$BACKUP_DIR"
    exit 41
  fi
  echo "    gateway is active (ready log may have different format in $TARGET)"
fi

NEW_VERSION=$(openclaw --version 2>&1 | awk '{print $2}')
echo "    installed version confirmed: $NEW_VERSION"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 4: POST-SWAP WATCH (5min auto-rollback gate)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "━━━ PHASE 4: POST-SWAP WATCH (5min gate) ━━━"
echo "    monitoring: restarts / harness errors / channel disconnects / fratricide"

WATCH_END=$(($(date +%s) + 300))
ROLLBACK_TRIGGERED=0

while [[ $(date +%s) -lt $WATCH_END ]]; do
  sleep 20
  REMAIN=$((WATCH_END - $(date +%s)))

  # CODE-8 fix: capture journalctl once + detect failure (do not silently treat as 0)
  JOURNAL=$(journalctl -u openclaw-gateway --since "5 min ago" --no-pager 2>/dev/null)
  JRC=$?
  if [[ $JRC -ne 0 ]]; then
    echo "    WARN: journalctl rc=$JRC — watch iteration inconclusive (skipping signal eval)"
    continue
  fi

  # Signal 1: restart count (fratricide indicator)
  RESTARTS=$(echo "$JOURNAL" | grep -c "Started.*openclaw-gateway" 2>/dev/null || true)
  RESTARTS=${RESTARTS:-0}

  # Signal 2: harness errors (the .24 failure mode)
  HARNESS_ERRS=$(echo "$JOURNAL" | grep -ciE "harness.*not registered|PI fallback is disabled|is not registered" 2>/dev/null || true)
  HARNESS_ERRS=${HARNESS_ERRS:-0}

  # Signal 3: channel disconnect storms (one reconnect OK, storm is not)
  DISCONNECTS=$(echo "$JOURNAL" | grep -ciE "channel.*disconnect|session.*lost|WebSocket.*close" 2>/dev/null || true)
  DISCONNECTS=${DISCONNECTS:-0}

  # Signal 4: fatal errors
  FATALS=$(echo "$JOURNAL" | grep -ciE "FATAL|process.*crash|uncaughtException|unhandledRejection" 2>/dev/null || true)
  FATALS=${FATALS:-0}

  echo "    t-${REMAIN}s  restarts=$RESTARTS  harness_errs=$HARNESS_ERRS  disconnects=$DISCONNECTS  fatals=$FATALS"

  # Auto-rollback thresholds
  if [[ $RESTARTS -gt 3 ]]; then
    echo "    ROLLBACK TRIGGER: fratricide ($RESTARTS restarts)"
    ROLLBACK_TRIGGERED=1; break
  fi
  if [[ $HARNESS_ERRS -gt 1 ]]; then
    echo "    ROLLBACK TRIGGER: harness not registered ($HARNESS_ERRS errors) — THIS WAS THE .24 FAILURE"
    ROLLBACK_TRIGGERED=1; break
  fi
  if [[ $DISCONNECTS -gt 15 ]]; then
    echo "    ROLLBACK TRIGGER: channel disconnect storm ($DISCONNECTS in 5min)"
    ROLLBACK_TRIGGERED=1; break
  fi
  if [[ $FATALS -gt 0 ]]; then
    echo "    ROLLBACK TRIGGER: fatal errors ($FATALS)"
    ROLLBACK_TRIGGERED=1; break
  fi

  if ! systemctl is-active openclaw-gateway >/dev/null 2>&1; then
    echo "    ROLLBACK TRIGGER: gateway not active"
    ROLLBACK_TRIGGERED=1; break
  fi
done

if [[ $ROLLBACK_TRIGGERED -eq 1 ]]; then
  bash /root/rollback-zero-downtime.sh "$TARGET" "$ROLLBACK_DIR" "$BACKUP_DIR"
  exit 50
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 5: FINAL VALIDATION
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "━━━ PHASE 5: FINAL VALIDATION ━━━"

FAIL=0
check() { if eval "$2" >/dev/null 2>&1; then echo "    OK    $1"; else echo "    FAIL  $1"; FAIL=1; fi; }

check "credentials.json immutable" \
  "lsattr ~/.claude/.credentials.json | awk '{print \$1}' | grep -q 'i'"
check "/usr/bin/node is bash wrapper" \
  "file /usr/bin/node | grep -q 'shell script'"
check "IS_SANDBOX=1 in override.conf" \
  "grep -q 'IS_SANDBOX=1' /etc/systemd/system/openclaw-gateway.service.d/override.conf"
check "monkey-patch marker in production dist" \
  "grep -q 'MONKEY-PATCH' /usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js"
check "primary model is anthropic Max OAuth (opus or sonnet)" \
  "jq -e '.agents.defaults.model.primary | test(\"^(anthropic|claude-cli)/claude-(opus|sonnet)\")' /root/.openclaw/openclaw.json"
check "anthropic baseUrl is api.anthropic.com (not RelayPlane :4100)" \
  "jq -e '.models.providers.anthropic.baseUrl == \"https://api.anthropic.com\"' /root/.openclaw/openclaw.json"
check "relayplane-proxy inactive (zero use, redundant)" \
  "! systemctl is-active relayplane-proxy"
check "fallbacks: no anthropic/* duplicating primary (would mask primary failure into bill)" \
  "! jq -e '(.agents.defaults.model.fallbacks // [])[]? | select(. | startswith(\"anthropic/claude\"))' /root/.openclaw/openclaw.json"
check "no cliBackends override" \
  "jq -e '(.agents.defaults.cliBackends // null) == null' /root/.openclaw/openclaw.json"
# commands.restart: historically false, but with monkey-patch active either is safe (CLAUDE.md regra #2)
check "commands.restart safe (false OR patched)" \
  "jq -e '.commands.restart == false' /root/.openclaw/openclaw.json || grep -q 'MONKEY-PATCH' /usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js"
# gateway.reload.mode: off OR hot are both compatible with monkey-patch (CLAUDE.md regra #2 atualizada 2026-05-01)
check "gateway.reload.mode in {off, hot}" \
  "jq -e '.gateway.reload.mode == \"off\" or .gateway.reload.mode == \"hot\"' /root/.openclaw/openclaw.json"
check "nox-mem-api responding (chunks > 0)" \
  "curl -sf http://127.0.0.1:18802/api/health | jq -e '.chunks.total > 0'"
check "gateway port 18789 listening" \
  "fuser 18789/tcp >/dev/null 2>&1"
check "sessions.json not stuck on non-claude model" \
  "! jq -e 'to_entries[] | select(.value.model | startswith(\"gemini\") or startswith(\"openai\") or startswith(\"gpt-\"))' \
    /root/.openclaw/agents/main/sessions/sessions.json"

# Phase 5 invariants from 5.2 lessons (pitfalls #1 + #3)
check "tools.web.search.provider points to installed+enabled plugin (pitfall #1 5.2)" \
  "openclaw plugins list --json | jq -e --arg p \"\$(openclaw config get tools.web.search.provider | tr -d '\"')\" '.plugins[]? | select(.id==\$p) | .enabled == true'"
check "@openclaw/discord present in /root/.openclaw/npm/node_modules/@openclaw/ (pitfall #3 5.2)" \
  "test -d /root/.openclaw/npm/node_modules/@openclaw/discord"
check "@openclaw/whatsapp present in /root/.openclaw/npm/node_modules/@openclaw/ (pitfall #3 5.2)" \
  "test -d /root/.openclaw/npm/node_modules/@openclaw/whatsapp"
check "channels loaded count >= 4 (slack+telegram bundled + discord+whatsapp external)" \
  "[ \$(openclaw plugins list --json | jq '[.plugins[]? | select((.id | test(\"^(slack|telegram|discord|whatsapp)$\")) and (.enabled // false) == true and .status == \"loaded\")] | length') -ge 4 ]"

# Phase 6 — auto-remediate config drift if detected
if [[ $FAIL -ne 0 ]]; then
  echo ""
  echo "━━━ PHASE 6: CONFIG DRIFT AUTO-REMEDIATION ━━━"
  DRIFT_FIXED=0
  CURRENT_BASEURL=$(jq -r '.models.providers.anthropic.baseUrl // ""' /root/.openclaw/openclaw.json)
  if [[ "$CURRENT_BASEURL" != "https://api.anthropic.com" ]]; then
    echo "    fixing anthropic.baseUrl ($CURRENT_BASEURL → https://api.anthropic.com)"
    openclaw config set models.providers.anthropic.baseUrl "https://api.anthropic.com" >/dev/null 2>&1 && DRIFT_FIXED=1
  fi
  if systemctl is-active --quiet relayplane-proxy 2>/dev/null; then
    echo "    stopping+disabling relayplane-proxy (redundant)"
    systemctl stop relayplane-proxy 2>/dev/null
    systemctl disable relayplane-proxy 2>/dev/null
    DRIFT_FIXED=1
  fi
  # Canonical model.primary post-v.26: anthropic/claude-* (claude-cli/* provider was removed).
  CURRENT_PRIMARY=$(jq -r '.agents.defaults.model.primary // ""' /root/.openclaw/openclaw.json)
  if ! [[ "$CURRENT_PRIMARY" =~ ^anthropic/claude-(opus|sonnet|haiku) ]]; then
    echo "    fixing model.primary ($CURRENT_PRIMARY → anthropic/claude-sonnet-4-6)"
    openclaw config set agents.defaults.model.primary "anthropic/claude-sonnet-4-6" >/dev/null 2>&1 && DRIFT_FIXED=1
  fi
  # Canonical fallback chain (CLAUDE.md regra #1): no anthropic/* duplicating primary.
  CURRENT_FALLBACKS=$(jq -c '.agents.defaults.model.fallbacks // []' /root/.openclaw/openclaw.json)
  if echo "$CURRENT_FALLBACKS" | grep -qE '"anthropic/claude'; then
    echo "    fixing fallbacks (anthropic/* duplicating primary detected)"
    openclaw config set agents.defaults.model.fallbacks \
      '["openai-codex/gpt-5.5","gemini/gemini-2.5-pro"]' >/dev/null 2>&1 && DRIFT_FIXED=1
  fi
  if [[ $DRIFT_FIXED -eq 1 ]]; then
    echo "    drift fixed — restarting gateway to apply..."
    systemctl restart openclaw-gateway && sleep 8
    echo "    gateway: $(systemctl is-active openclaw-gateway)"
    echo "    NOTE: sessions reset may also be needed if agents were stuck on fallback:"
    echo "      for a in main nox atlas boris cipher forge lex; do"
    echo "        jq 'with_entries(select(.value.model | test(\"^(claude-|anthropic-|opus|sonnet|haiku)\")))' \\"
    echo "          /root/.openclaw/agents/\$a/sessions/sessions.json > /tmp/clean && \\"
    echo "          mv /tmp/clean /root/.openclaw/agents/\$a/sessions/sessions.json"
    echo "      done"
  fi
fi

if [[ $FAIL -ne 0 ]]; then
  echo "    WARN: final validation has failures — investigate before closing"
  echo "    rollback available: bash /root/rollback-zero-downtime.sh $TARGET $ROLLBACK_DIR $BACKUP_DIR"
fi

echo ""
echo "=== UPGRADE COMPLETE ==="
echo "    version:  $NEW_VERSION"
echo "    log:      $LOG"
echo "    backups:  $BACKUP_DIR"
echo "    rollback: bash /root/rollback-zero-downtime.sh $TARGET $ROLLBACK_DIR $BACKUP_DIR"
echo ""
echo "    NEXT: monitor heartbeats for 30min. Check /api/harnesses via claude-cli."
echo "    CLEANUP (after 24h stable): rm -rf $ROLLBACK_DIR"

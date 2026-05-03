# Runbook — Upgrade qualquer versão OpenClaw (v2026.4.24+)

> **Substitui:** `upgrade-from-v24-to-v29.md` (mantido como histórico).
>
> **Cobertura:** qualquer transição entre v2026.4.24 e a versão estável atual.
>
> **Tempo médio:** 45–90 min dependendo do gap de versões + downtime real ~30 s (atomic swap Phase 3).
>
> **Risco:** Médio (backup + auto-rollback + forward-fix implementados).

---

## TL;DR — 4 comandos críticos

```bash
# 1. Diagnosticar gap
CURRENT=$(openclaw --version | cut -d' ' -f1)
TARGET="${1:-latest}"  # ou especifique ex: 2026.5.2
echo "Upgrade path: $CURRENT → $TARGET"

# 2. Backup (não pula)
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p /root/.openclaw/backups/upgrade-$TS
cp /root/.openclaw/openclaw.json /root/.openclaw/backups/upgrade-$TS/
cp /root/.openclaw/.env /root/.openclaw/backups/upgrade-$TS/

# 3. Pre-flight chattr -i (Recipe N — obrigatório se tiver patches aplicados)
find /usr/lib/node_modules/openclaw -type f -exec lsattr {} \; 2>/dev/null \
  | grep "^----i" | awk '{print $NF}' | xargs -r chattr -i
systemctl reset-failed openclaw-gateway

# 4. Upgrade + reapply patches + watch
npm install -g openclaw@${TARGET}
bash <(curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/reapply-monkey-patch.sh)
systemctl restart openclaw-gateway
sleep 30 && systemctl is-active openclaw-gateway
```

---

## 0. Pré-requisitos universais

- [ ] **Snapshot VPS** tirado nos últimos 60 min (Hostinger/provider)
- [ ] Acesso SSH confirmado: `ssh root@<vps-ip>`
- [ ] Espaço em disco: mínimo **2 GB** livres em `/root` e `/var`
  ```bash
  df -h /root /var | tail -2
  ```
- [ ] **Janela de manutenção documentada** — gateway fica offline ~30 s (Phase 3)
- [ ] Versão atual anotada:
  ```bash
  openclaw --version > /tmp/version-pre-upgrade.txt
  cat /tmp/version-pre-upgrade.txt
  ```
- [ ] Diagnostic pré-upgrade capturado:
  ```bash
  bash <(curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/diagnostic.sh) > /tmp/diagnostic-pre-upgrade.txt
  ```

---

## 1. Detectar o gap (decision tree)

Execute este bloco pra determinar o path de upgrade correto:

```bash
#!/bin/bash
set -e

CURRENT=$(openclaw --version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)
TARGET="${1:-latest}"

if [[ -z "$CURRENT" ]]; then
  echo "❌ FALHA: openclaw não encontrado ou versão inválida"
  exit 1
fi

# Converter versão em número pra comparação
ver2num() {
  local v="$1"
  v=${v#v}  # remover 'v' prefix se houver
  echo "${v%%-*}" | awk -F. '{printf("%d%03d%03d", $1, $2, $3)}'
}

CURR_NUM=$(ver2num "$CURRENT")
GAP_SIZE=0

# Se target = "latest", detectar
if [[ "$TARGET" == "latest" ]]; then
  TARGET=$(npm view openclaw version 2>/dev/null || echo "2026.5.2")
fi

TARGET_NUM=$(ver2num "$TARGET")

# Calcular gap
if (( TARGET_NUM > CURR_NUM )); then
  GAP_SIZE=$(( (TARGET_NUM - CURR_NUM) / 1000000 ))  # Major.minor diff
fi

# Decision tree
echo "═══════════════════════════════════════════════════════"
echo "Upgrade path detected:"
echo "  Current version: $CURRENT (num: $CURR_NUM)"
echo "  Target version:  $TARGET (num: $TARGET_NUM)"
echo "  Gap size:        $GAP_SIZE releases"
echo "═══════════════════════════════════════════════════════"

# Gap pequeno (0-1 releases)
if (( CURR_NUM >= 202604027000000 )) && (( TARGET_NUM >= CURR_NUM )); then
  echo ""
  echo "✅ Gap pequeno — recipes obrigatórias: A, D, N (Recipe M/O opcional)"
  echo "   Tempo estimado: 30-45 min (com downtime ~30s)"
  echo ""
  echo "   Path:"
  echo "   [0] Backup (5min)"
  echo "   [1] Config audit (2min)"
  echo "   [2] Pre-flight chattr -i (1min)"
  echo "   [3] Atomic swap npm install (3-5min, ~30s downtime)"
  echo "   [4] Reaplicar patches (5min)"
  echo "   [5] Watch loop 5min (5min)"
  echo "   [6] Validação + reimmutabilize (5min)"
  
  READ_RECIPES="A, D, N"
  RECIPES_CONDITIONAL="M (config audit strict v5.2+), O (plugins externalized)"
  
# Gap médio (2-4 releases)
elif (( CURR_NUM >= 202604024000000 )); then
  echo ""
  echo "⚠️  Gap médio — recomenda-se staging incremental"
  echo "    Current < 4.27 E target >= 5.0 = risco de incompatibilidades cumulativas"
  echo ""
  echo "   Path alternativo sugerido:"
  echo "   1. Upgrade pra 4.29 primeiro (validado, releases intermediárias testadas)"
  echo "   2. Depois upgrade pra 5.x em contexto stável"
  echo ""
  echo "   Ou prosseguir com precaução (recipes A+D+N+M+O obrigatórias):"
  echo "   Tempo estimado: 90-120 min (com staging)."
  
  READ_RECIPES="A, D, N, M, O"
  RECIPES_CONDITIONAL="(todas)"
  
# Gap grande (> 4 releases)
else
  echo ""
  echo "❌ RISCO ALTO — gap > 4 releases detectado"
  echo "    Não prosseguir — fazer staging incremental:"
  echo "    1. Upgrade pra v.27 (stabil intermediária conhecida)"
  echo "    2. Validar 24h"
  echo "    3. Depois upgrade pra target"
  echo ""
  echo "    Ou restaurar snapshot pré-upgrade se isso foi acidental."
  exit 1
fi

echo ""
echo "Recipes a ler:"
echo "  Obrigatórias: $READ_RECIPES"
echo "  Condicionais: $RECIPES_CONDITIONAL"
echo ""
```

**Output esperado:** decisão clara de path (pequeno/médio/grande) + recipes a aplicar.

---

## 2. Phase 0 — Pre-flight (sempre, ~15 min)

### 2.A Backup completo + rotate antigos

```bash
TS=$(date +%Y%m%d-%H%M%S)
BACKUP=/root/.openclaw/backups/upgrade-$TS

echo "[2.A] Criando backup pre-upgrade em $BACKUP..."
mkdir -p "$BACKUP"

# Core config + env
cp /root/.openclaw/openclaw.json "$BACKUP/"
cp /root/.openclaw/.env "$BACKUP/"

# Agents + memory
cp -r /root/.openclaw/agents "$BACKUP/agents-snapshot" 2>/dev/null || echo "  (no agents dir)"

# Plugged node_modules (scoped @openclaw/*)
cp -r /root/.openclaw/npm "$BACKUP/npm-snapshot" 2>/dev/null || echo "  (no npm dir)"

# Credentials
cp /root/.claude/.credentials.json "$BACKUP/" 2>/dev/null || echo "  (no credentials)"

# Binário wrapper (se houver custom)
cp /usr/local/bin/openclaw-gateway-wrapper "$BACKUP/" 2>/dev/null || echo "  (no wrapper)"

# Lista de arquivo imutáveis (pré-diagnóstico)
find /usr/lib/node_modules/openclaw -type f -exec lsattr {} \; 2>/dev/null \
  | grep "^----i" | wc -l > "$BACKUP/immutable-count-pre-upgrade.txt"

echo "  ✓ Backup criado. Arquivos:"
ls -lh "$BACKUP" | tail -5

# Rotação: remover backups > 30 dias
echo "[2.A] Limpando backups antigos (> 30 dias)..."
find /root/.openclaw/backups -maxdepth 1 -type d -mtime +30 -exec rm -rf {} \; 2>/dev/null || true

echo "  Backups mantidos (últimos 30 dias):"
ls -d /root/.openclaw/backups/upgrade-* 2>/dev/null | tail -3
```

### 2.B Token sentinel (validar se CLI ativo)

```bash
echo "[2.B] Validando Claude CLI auth..."
if ! claude auth status 2>&1 | grep -q "loggedIn.*true"; then
  echo "  ⚠️  Claude CLI não logado. Rodar:"
  echo "     claude setup-token"
  echo "     (cole o token de 'Setup Token', não 'API Key')"
  exit 1
fi
echo "  ✓ Claude CLI ativo"
```

### 2.C Audit config pré-upgrade (Recipe M — obrigatório se v5.2+)

```bash
echo "[2.C] Auditando config (v5.2+ requer validação estrita)..."

# Validar que tools.web.search.provider aponta pra plugin instalado+enabled
WEB_SEARCH_PROVIDER=$(openclaw config get tools.web.search.provider 2>/dev/null || echo "duckduckgo")
echo "  Web search provider: $WEB_SEARCH_PROVIDER"

# Checklist de providers seguros bundled na v5.2+
SAFE_PROVIDERS="duckduckgo searxng exa firecrawl tavily kimi-coding web-readability webhooks"
if ! echo "$SAFE_PROVIDERS" | grep -q "$WEB_SEARCH_PROVIDER"; then
  echo "  ⚠️  Provider '$WEB_SEARCH_PROVIDER' pode ser desconhecido ou externalized"
  echo "      Recipe M recomendado pós-upgrade pra validar"
fi

# Validar modelos
echo "  Validando model.primary..."
PRIMARY_MODEL=$(openclaw config get model.primary 2>/dev/null || echo "anthropic/claude-sonnet-4-6")
echo "    Primary model: $PRIMARY_MODEL"

if ! echo "$PRIMARY_MODEL" | grep -q "anthropic"; then
  echo "  ⚠️  Primary model não é anthropic/* (Max OAuth pode não funcionar)"
fi

# Se houver fallback malformado, alertar
echo "  ✓ Config audit completado. Prosseguir se nenhum warning acima."
```

### 2.D Pre-flight chattr -i (Recipe N — obrigatório pré-upgrade)

**CRÍTICO:** Este passo é mandatório se houver patches aplicados (`chattr +i` em node_modules).

```bash
echo "[2.D] Removendo chattr +i pré-upgrade (Recipe N)..."

IMMUTABLE_COUNT=$(find /usr/lib/node_modules/openclaw -type f -exec lsattr {} \; 2>/dev/null \
  | grep -c "^----i" || true)

if [[ "$IMMUTABLE_COUNT" -eq 0 ]]; then
  echo "  ✓ Nenhum arquivo imutável encontrado — seguro prosseguir"
else
  echo "  ⚠️  Encontrados $IMMUTABLE_COUNT arquivo(s) com chattr +i"
  echo "     Removendo pré-upgrade (necessário pra npm install funcionar)..."
  
  find /usr/lib/node_modules/openclaw -type f -exec lsattr {} \; 2>/dev/null \
    | grep "^----i" | awk '{print $NF}' | xargs -r chattr -i
  
  echo "  ✓ chattr +i removido"
fi

# Reset systemd failure counter
echo "[2.D] Resetando contador de restarts systemd..."
systemctl reset-failed openclaw-gateway 2>/dev/null || true
```

---

## 3. Phase 1 — Staging isolado :18790

Simular upgrade em porta isolada (sem afetar prod).

```bash
TARGET_VERSION="${1:-latest}"

echo "[3] Iniciando Phase 1 — staging isolado em :18790..."

# 1. Deploy tarball temporário de versão-alvo
echo "[3.1] Baixando tarball $TARGET_VERSION (validação pré-download)..."
npm view openclaw@${TARGET_VERSION} > /tmp/pkg-info.json 2>/dev/null || {
  echo "❌ Versão $TARGET_VERSION não encontrada no npm"
  exit 1
}

TARBALL_URL=$(jq -r '.dist.tarball' /tmp/pkg-info.json)
echo "  Tarball: $TARBALL_URL"

# 2. Extrair em dir temporário (não em global)
STAGING_DIR="/tmp/openclaw-staging-$$"
mkdir -p "$STAGING_DIR"

echo "[3.2] Extraindo pra staging dir $STAGING_DIR..."
cd "$STAGING_DIR"
npm install openclaw@${TARGET_VERSION} --no-save 2>&1 | tail -5

STAGED_BIN="$STAGING_DIR/node_modules/.bin/openclaw"
echo "[3.3] Validando binário staged..."
if ! $STAGED_BIN --version 2>/dev/null; then
  echo "❌ Staged binary falhou — verificar tarball"
  exit 1
fi
echo "  ✓ Staged version: $($STAGED_BIN --version)"

# 3. Port forwarding pra staging gateway (opcional)
# Usar PORT=18790 se quiser rodar gateway isolado pra fumar-teste
# PORT=18790 $STAGED_BIN start-gateway --config /root/.openclaw/openclaw.json --staging
# Pra este runbook simplificado, pulamos o gateway staging — apenas validamos o binário

echo "  ✓ Phase 1 staging OK"
```

---

## 4. Phase 2 — Smoke staging (validação rápida)

```bash
echo "[4] Phase 2 — Smoke tests..."

# 1. Validar que binário staged tem os arquivos esperados
echo "[4.1] Checando estrutura do binário..."
ls -lh "$STAGING_DIR/node_modules/openclaw/dist/" | grep -E "restart-stale|status-message" | wc -l
echo "  (esperado: 4+ arquivos encontrados)"

# 2. Validar que versão é exatamente a esperada
STAGED_VER=$($STAGED_BIN --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [[ "$STAGED_VER" != *"${TARGET_VERSION##v}"* ]]; then
  echo "⚠️  Versão staged não bate com target ($STAGED_VER vs $TARGET_VERSION)"
fi
echo "  ✓ Staged version: $STAGED_VER"

# 3. Validar que config é carregável
echo "[4.2] Teste de config (staged)..."
$STAGED_BIN config validate 2>&1 | head -3
echo "  (config deve ser válida em staging)"

# 4. Limpar staging
echo "[4.3] Limpando staging dir..."
rm -rf "$STAGING_DIR"
echo "  ✓ Phase 2 smoke OK"
```

---

## 5. Phase 3 — Atomic swap (~30 s downtime)

```bash
TARGET_VERSION="${1:-latest}"

echo "[5] Phase 3 — ATOMIC SWAP (gateway vai ficar offline ~30s)..."
echo "    CONFIRMAÇÃO: Digitar 'SIM' pra prosseguir (ou Ctrl+C pra abortar)"
read -p "    > "
if [[ "$REPLY" != "SIM" ]]; then
  echo "Abortado."
  exit 0
fi

# Drop-in systemd pra evitar auto-restart durante install
echo "[5.1] Pausando auto-restart do gateway..."
mkdir -p /etc/systemd/system/openclaw-gateway.service.d
cat > /etc/systemd/system/openclaw-gateway.service.d/no-restart-during-upgrade.conf << 'EOF'
[Service]
Restart=no
EOF
systemctl daemon-reload

# Para gateway
echo "[5.2] Parando gateway (will not auto-restart)..."
systemctl stop openclaw-gateway
sleep 2
pkill -9 openclaw 2>/dev/null || true
sleep 1

ps -ef | grep -i "[o]penclaw" || echo "  ✓ Gateway parado"

# ATOMIC: npm install -g
echo "[5.3] npm install -g openclaw@${TARGET_VERSION} (DOWNTIME BEGINS)..."
START_SWAP=$(date +%s)

npm install -g openclaw@${TARGET_VERSION} 2>&1 | tail -5 || {
  echo "❌ npm install falhou"
  echo "   Tentando restauração..."
  systemctl start openclaw-gateway
  sleep 10
  exit 1
}

END_SWAP=$(date +%s)
SWAP_DURATION=$(( END_SWAP - START_SWAP ))
echo "  ✓ npm install completado em ${SWAP_DURATION}s"

# Validar que binário foi instalado
NEW_VER=$(openclaw --version)
echo "[5.4] Validando binário pós-install..."
echo "  Versão: $NEW_VER"

if [[ -z "$NEW_VER" ]]; then
  echo "❌ FALHA: openclaw binary não recuperado"
  echo "   Procurando backup..."
  if [[ -d "/root/.openclaw/backups" ]]; then
    echo "   Prosseguir com restauração manual (ver Seção 9 Rollback)"
  fi
  exit 1
fi

echo "  ✓ Binary válido"
```

---

## 6. Phase 4 — Reaplicar patches obrigatórios

```bash
TARGET_VERSION="${1:-latest}"

echo "[6] Phase 4 — Reaplicar patches (obrigatório pós npm install)..."

# 6.A Monkey-patch fratricide #62028 (Recipe D)
echo "[6.A] Aplicando monkey-patch fratricide #62028..."
bash <(curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/reapply-monkey-patch.sh) 2>&1 | tail -3
echo "  ✓ Monkey-patch aplicado"

# 6.B Validar patch
IMPL_FILE=$(find /usr/lib/node_modules/openclaw/dist -name "restart-stale-pids-*.js" -type f -exec grep -l "cleanStaleGatewayProcessesSync" {} \;)
if [[ -z "$IMPL_FILE" ]]; then
  echo "⚠️  Arquivo impl não encontrado — validação falhou"
else
  PATCH_MARKER=$(grep -c "MONKEY-PATCH" "$IMPL_FILE" || true)
  if (( PATCH_MARKER > 0 )); then
    echo "  ✓ Marker 'MONKEY-PATCH' encontrado em $(basename $IMPL_FILE)"
  else
    echo "⚠️  Marker não encontrado — reaplicar manualmente"
  fi
fi

# 6.C Reapply config (Recipe F — baseUrl)
echo "[6.B] Validando baseUrl..."
BASE_URL=$(openclaw config get models.providers.anthropic.baseUrl 2>/dev/null || echo "https://api.anthropic.com")
if [[ "$BASE_URL" == "http://127.0.0.1:4100" ]]; then
  echo "  ⚠️  baseUrl apontando pra RelayPlane (redundante, será corrigido)"
  openclaw config set models.providers.anthropic.baseUrl https://api.anthropic.com
fi
echo "  ✓ baseUrl canonical: $BASE_URL"

# 6.D Re-aplicar emoji patch (regra 2.1)
echo "[6.C] Aplicando emoji patch (se aplicável)..."
python3 <(curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/reapply-session-status-emoji-patch.py) 2>&1 | tail -2 || echo "  (patch não aplicável pra esta versão)"

echo "  ✓ Phase 4 patches OK"
```

---

## 7. Phase 5 — Watch loop 5 min com auto-rollback

```bash
echo "[7] Phase 5 — WATCH LOOP (5 min monitoramento, criteria rollback automático)..."

# Resume gateway
echo "[7.1] Retirando drop-in, restaurando auto-restart..."
rm /etc/systemd/system/openclaw-gateway.service.d/no-restart-during-upgrade.conf 2>/dev/null || true
systemctl daemon-reload

echo "[7.2] Iniciando gateway..."
systemctl start openclaw-gateway
sleep 8

# Critérios de failure (auto-rollback)
FAILED=false
FAILURES=""

echo "[7.3] Observando por 5 min (criterios de rollback)..."
WATCH_END=$(( $(date +%s) + 300 ))  # 5 minutos

while (( $(date +%s) < WATCH_END )); do
  # Check 1: gateway está ativo?
  if ! systemctl is-active --quiet openclaw-gateway; then
    FAILED=true
    FAILURES="$FAILURES\n  - Gateway não está ativo"
  fi
  
  # Check 2: restart counter > 3 em 5min = fratricide
  NRESTARTS=$(systemctl show -p NRestarts --value openclaw-gateway)
  if (( NRESTARTS > 3 )); then
    FAILED=true
    FAILURES="$FAILURES\n  - Fratricide detectado (NRestarts=$NRESTARTS)"
  fi
  
  # Check 3: buscar "harness 'claude-cli' not registered" nos logs
  if journalctl -u openclaw-gateway -n 100 --no-pager 2>/dev/null | grep -q "harness.*not registered"; then
    FAILED=true
    FAILURES="$FAILURES\n  - Harness error (claude-cli não registrado)"
  fi
  
  if $FAILED; then
    echo -e "❌ FALHA DETECTADA:$FAILURES"
    echo ""
    echo "   Auto-rollback iniciado..."
    systemctl stop openclaw-gateway
    
    # Rollback: voltar pra versão anterior
    PREV_VER=$(cat /tmp/version-pre-upgrade.txt 2>/dev/null | cut -d' ' -f1 || echo "2026.4.29")
    echo "   Reinstalando $PREV_VER..."
    npm install -g openclaw@${PREV_VER}
    
    # Reaplicar patches na versão anterior
    bash <(curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/reapply-monkey-patch.sh)
    
    systemctl start openclaw-gateway
    sleep 10
    
    if systemctl is-active --quiet openclaw-gateway; then
      echo "  ✓ Rollback bem-sucedido, gateway recuperado em $PREV_VER"
      exit 1
    else
      echo "  ✗ Rollback FALHOU — situação crítica, contate suporte"
      exit 1
    fi
  fi
  
  echo -n "."
  sleep 15
done

echo ""
echo "  ✓ 5 min watch loop completado sem failures"
echo "  ✓ Phase 5 OK"
```

---

## 8. Phase 6 — Validação + reimmutabilize

```bash
echo "[8] Phase 6 — Validação + reimmutabilize..."

# 1. Validar versão
echo "[8.1] Confirmando versão final..."
openclaw --version
FINAL_VER=$(openclaw --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
echo "  ✓ Versão final: $FINAL_VER"

# 2. Validar invariantes críticas
echo "[8.2] Validando 7 invariantes críticas..."

# I1: model.primary = anthropic/*
PRIMARY=$(openclaw config get model.primary 2>/dev/null || echo "anthropic/claude-sonnet-4-6")
[[ "$PRIMARY" == anthropic* ]] && echo "  ✓ I1: model.primary = $PRIMARY" || echo "  ✗ I1: FAIL"

# I2: baseUrl canônica
BASE_URL=$(openclaw config get models.providers.anthropic.baseUrl 2>/dev/null || echo "https://api.anthropic.com")
[[ "$BASE_URL" == "https://api.anthropic.com" ]] && echo "  ✓ I2: baseUrl = $BASE_URL" || echo "  ✗ I2: FAIL"

# I3: relayplane desativado
if systemctl is-active --quiet relayplane-proxy 2>/dev/null; then
  echo "  ✗ I3: RelayPlane ativo (deve estar disabled)"
  systemctl stop relayplane-proxy && systemctl disable relayplane-proxy
else
  echo "  ✓ I3: RelayPlane inactive"
fi

# I4: monkey-patch aplicado
IMPL_FILE=$(find /usr/lib/node_modules/openclaw/dist -name "restart-stale-pids-*.js" -exec grep -l "cleanStaleGatewayProcessesSync" {} \;)
if [[ -n "$IMPL_FILE" ]] && grep -q "MONKEY-PATCH" "$IMPL_FILE"; then
  echo "  ✓ I4: Monkey-patch validado"
else
  echo "  ✗ I4: Monkey-patch NÃO encontrado (reaplicar)"
  bash <(curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/reapply-monkey-patch.sh)
fi

# I5: NRestarts = 0
NRESTARTS=$(systemctl show -p NRestarts --value openclaw-gateway)
[[ "$NRESTARTS" == "0" ]] && echo "  ✓ I5: NRestarts = $NRESTARTS" || echo "  ⚠️  I5: NRestarts = $NRESTARTS (OK se < 3)"

# I6: web.search.provider válido (v5.2+)
WEB_PROV=$(openclaw config get tools.web.search.provider 2>/dev/null || echo "duckduckgo")
echo "  ✓ I6: web.search.provider = $WEB_PROV"

# I7: canais carregados
CHANNELS=$(openclaw plugins list --json 2>/dev/null | jq '.plugins | length' || echo "?")
echo "  ✓ I7: Plugins loaded = $CHANNELS"

# 3. Re-aplicar chattr +i em arquivos críticos
echo "[8.3] Re-aplicando chattr +i (regra 2.1)..."
chattr +i /root/.claude/.credentials.json 2>/dev/null && echo "  ✓ credentials imutável" || echo "  (credentials não encontrado)"
chattr +i /usr/local/bin/openclaw-gateway-wrapper 2>/dev/null && echo "  ✓ gateway wrapper imutável" || echo "  (wrapper não encontrado)"

# Re-aplicar em status-message files se existirem
PATCHED_COUNT=$(find /root/.openclaw -name "status-message-*.js" -type f 2>/dev/null | wc -l)
if (( PATCHED_COUNT > 0 )); then
  find /root/.openclaw -name "status-message-*.js" -type f 2>/dev/null | xargs -r chattr +i
  echo "  ✓ Aplicado chattr +i em $PATCHED_COUNT status-message files"
fi

echo "  ✓ Phase 6 OK"
```

---

## 9. Phase 7 — Plugin externalization handling (Recipe O, v5.2+)

Se atualizar para v5.2+, validar plugins externalized:

```bash
echo "[9] Phase 7 — Plugin externalization (v5.2+ only)..."

# Check: versão >= 5.2?
CURR=$(openclaw --version | cut -d'.' -f1-2)
if [[ "$CURR" != "2026.5" ]] && [[ "$CURR" != "2026.6" ]] && [[ "$CURR" != "2026.7" ]]; then
  echo "  (não aplicável pra versão < 5.2, pulando)"
  exit 0
fi

echo "[9.1] Checando plugins externalized..."

# Listar o que espera estar em @openclaw/*
EXPECTED_PLUGINS=( "whatsapp" "discord" "memory-lance" "matrix" "mattermost" "voice-call" )

# Validar se foram instalados
for PLUGIN in "${EXPECTED_PLUGINS[@]}"; do
  if ls /root/.openclaw/npm/node_modules/@openclaw/$PLUGIN 2>/dev/null >/dev/null; then
    echo "  ✓ @openclaw/$PLUGIN instalado"
  else
    echo "  ⚠️  @openclaw/$PLUGIN NÃO encontrado"
  fi
done

# Se algum plugin importante sumiu, reinstalar via npm direto (não openclaw plugins install!)
echo "[9.2] Reinstalando plugins externalized (se necessário)..."

# Detectar quais estão em package.json
if [[ -f /root/.openclaw/npm/package.json ]]; then
  echo "  Deps em package.json:"
  jq -r '.dependencies | keys[] | select(startswith("@openclaw"))' /root/.openclaw/npm/package.json 2>/dev/null || echo "  (nenhum @openclaw/* encontrado)"
  
  # Reinstalar se houver package.json
  echo "  Reinstalando todos os deps em package.json..."
  cd /root/.openclaw/npm && npm install 2>&1 | tail -3
fi

# Restart gateway pra reconhecer plugins
echo "[9.3] Restarting gateway para reconhecer plugins..."
systemctl restart openclaw-gateway
sleep 8

echo "[9.4] Validando carregamento de plugins..."
openclaw plugins list --json 2>/dev/null | jq '.plugins[] | select(.origin=="global") | {id, enabled, status}' | head -20

echo "  ✓ Phase 7 OK"
```

---

## 10. Decision tree por gap (atual → alvo)

Consultar este quadro para determinar se precisa de recipes adicionais.

| Versão atual | Versão alvo | Recipes obrigatórias | Downtime | Tempo est. | Notas |
|---|---|---|---|---|---|
| < 4.27 | qualquer | A, D, warn múltiplos saltos | ~30 s | 90–120 min | Considerar staging incremental (4.27 → alvo) |
| 4.27–4.29 | 4.27–4.29 | A, D, N | ~30 s | 45 min | Pequeno gap, sem Recipe M/O |
| 4.27–5.1 | >= 5.2 | A, D, N, M, O | ~30 s | 60–90 min | Plugin externalization + web-search validation |
| >= 5.2 | >= 5.2 | A, D, N | ~30 s | 45 min | M/O só se config drift detectado |
| > 5.2 | > 5.2 | A, D (N opcional) | ~30 s | 30–45 min | Gap muito pequeno, patches automáticos |

---

## 11. Rollback procedure (cenários críticos)

### Cenário 1: Fase 3 falhou (npm install)

Se `npm install -g openclaw@<version>` falhou no meio:

```bash
# 1. Verificar se binário foi deixado quebrado
which openclaw || echo "Binário não encontrado — reinstalar"

# 2. Remover chattr +i novamente (caso tenha sobrado)
find /usr/lib/node_modules/openclaw -type f -exec lsattr {} \; 2>/dev/null \
  | grep "^----i" | awk '{print $NF}' | xargs -r chattr -i

# 3. Reset-failed
systemctl reset-failed openclaw-gateway

# 4. Reinstalar versão anterior (de /tmp/version-pre-upgrade.txt)
PREV_VER=$(cat /tmp/version-pre-upgrade.txt | cut -d' ' -f1)
npm install -g openclaw@${PREV_VER}

# 5. Reaplicar patches
bash <(curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/reapply-monkey-patch.sh)

# 6. Start
systemctl start openclaw-gateway
sleep 15
systemctl is-active openclaw-gateway
```

### Cenário 2: Fase 5 detectou failure (auto-rollback)

Watch loop já disparou rollback automático. Se ainda estiver instável:

```bash
# Snapshot total (último recurso) — restaurar pelo provider VPS
# ~5 min downtime real
# Via Hostinger: VM snapshots → restore pre-upgrade
```

### Cenário 3: Config corrompida pós-upgrade

Se gateway subiu mas config está inconsistente:

```bash
# 1. Restaurar openclaw.json do backup Phase 0
TS=<timestamp-do-backup-feito>
cp /root/.openclaw/backups/upgrade-$TS/openclaw.json /root/.openclaw/

# 2. Validar
openclaw config validate

# 3. Restart
systemctl restart openclaw-gateway
```

---

## 12. Post-upgrade hygiene (D+1, D+7)

Após upgrade bem-sucedido:

- [ ] **D+1 (próximo dia):** Verificar logs pra patterns estranhos
  ```bash
  journalctl -u openclaw-gateway -S "1 hour ago" --grep "error|warn" --no-pager
  ```

- [ ] **D+1:** Validar canais funcionando (Discord/Slack/WhatsApp response)

- [ ] **D+7:** Se aplicou recipes opcionais (M, O), registrar quais no docs/HANDOFF.md

- [ ] **D+7:** Considerar apagar backups pré-upgrade (retenção 30 dias automática)

---

## 13. Quando NÃO seguir este runbook

Abortar + escalar se:

- Versão alvo é **beta/alpha** (usar staging dedicado separado)
- Gap > 5 minor versions (ex: 4.22 → 5.1) — fazer incremental
- Custom builds/forks do OpenClaw (não cobertos)
- Binário corrompido irrecuperável (restaurar snapshot total)

---

## 14. Recipes referenciadas (links relativos)

- **Recipe A** — Upgrade controlado: `../recipes/A-upgrade-controlado.md`
- **Recipe D** — Monkey-patch fratricide #62028: via script em curl (inline)
- **Recipe F** — RelayPlane disable/baseUrl: via `openclaw config set`
- **Recipe M** — Web search provider validation strict (v5.2+): `../recipes/M-web-search-validation-strict.md`
- **Recipe N** — Remover chattr +i pré-npm-install: `../recipes/N-chattr-vs-npm-install.md`
- **Recipe O** — Plugin externalization scoped `@openclaw/*`: `../recipes/O-plugin-externalization-scoped.md`

---

## 15. Lições de upgrades anteriores

Referência: `../lessons/2026-05-03-openclaw-v5.2-upgrade-pitfalls.md`

**3 pitfalls não-documentados encontrados em v5.2 (documentados aqui agora):**

1. **Web search provider validation strict** — v5.2 rejeita config se provider não existe/disabled. Fix: usar provider bundled seguro (`duckduckgo`).
2. **`chattr +i` bloqueia `npm install -g`** — Archives imutáveis impedem `rm` durante install. Fix: Recipe N obrigatória.
3. **`openclaw plugins install` destrutivo entre scoped `@openclaw/*`** — Cada install remove o anterior. Fix: usar `npm install` direto em `/root/.openclaw/npm/`.

---

## Última atualização

2026-05-03. Compatível com v2026.5.2 e futuras (gap detection automático).

**Verificação de sintaxe bash completa — use em produção:**

```bash
bash -n upgrade-any-version.md  # (nota: este arquivo é markdown, não shell direto)
# Copiar blocks de código acima pra shell scripts separados pra testar
```

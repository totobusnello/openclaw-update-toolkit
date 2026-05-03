# Recipe N — Remover `chattr +i` antes de `npm install -g openclaw@<v>`

**SEVERIDADE:** 🔴 ALTA (se você aplicou chattr +i em arquivos do node_modules global E vai fazer upgrade de versão do binário OpenClaw) | 🟢 N/A (se nunca aplicou patches imutáveis, ou é primeira instalação)

**SYMPTOM:**
- Durante `npm install -g openclaw@<versão>`: erro `rm: cannot remove '/usr/lib/node_modules/openclaw/dist/status-message-*.js': Operation not permitted`
- `npm install -g` aborta no meio do processo
- `which openclaw` retorna vazio (binário está quebrado/incompleto)
- `systemctl is-active openclaw-gateway` mostra `failed` ou `activating` em crash loop
- Restart counter do systemd alta (`NRestarts > 5`)

**CAUSA RAIZ:**
Recipes D (monkey-patch fratricide #62028) e J (label OAuth Max emoji patch) aplicam `chattr +i` em arquivos críticos do node_modules `/usr/lib/node_modules/openclaw/dist/status-message-*.js` pra proteger contra invalidação acidental durante runtime.

Ao rodar `npm install -g openclaw@<nova-versão>`, o npm precisa remover os arquivos antigos **antes de extrair os novos**. O flag `chattr +i` (imutável) bloqueia operações de `rm` no filesystem ext4. Resultado: operação parcial — node_modules tree destruído incompletamente, binário openclaw resta só em forma de stub sem deps — **gateway totalmente inoperável**.

**Lição histórica:** incidente 2026-05-03 17:50 UTC durante upgrade v2026.4.29 → v2026.5.2. Erro capturado em journalctl:
```
npm ERR! code EACCES
npm ERR! syscall unlink
npm ERR! path /usr/lib/node_modules/openclaw/dist/status-message-Bwz2ekKl.js
rm: cannot remove '/usr/lib/node_modules/openclaw/dist/status-message-Bwz2ekKl.js': Operation not permitted
```

> ⚠️ **CRÍTICO:** Este procedimento é **OBRIGATÓRIO** como etapa pré-upgrade de qualquer versão nova do binário OpenClaw quando você tem patches imutáveis aplicados.

**FIX:**

```bash
# 1. Listar todos arquivos imutáveis no node_modules global (validação)
echo "[1] Checando por arquivos imutáveis em node_modules global..."
IMMUTABLE_COUNT=$(find /usr/lib/node_modules/openclaw -type f -exec lsattr {} \; 2>/dev/null | grep -c "^----i" || true)
if [[ "$IMMUTABLE_COUNT" -eq 0 ]]; then
  echo "    ✓ Nenhum arquivo imutável encontrado — seguro prosseguir com npm install"
  exit 0
fi
echo "    Found $IMMUTABLE_COUNT immutable file(s) — proceedendo com remocao de chattr +i"

# 2. Remover chattr +i de TODOS os arquivos no diretório de instalação do openclaw
echo "[2] Removendo chattr +i de arquivos do openclaw..."
find /usr/lib/node_modules/openclaw -type f -exec lsattr {} \; 2>/dev/null \
  | grep "^----i" | awk '{print $NF}' | xargs -r chattr -i
echo "    ✓ chattr +i removido"

# 3. Reset do failure counter do systemd (se houver restarts anteriores)
echo "[3] Resetando contador de restarts do systemd..."
systemctl reset-failed openclaw-gateway 2>/dev/null || true

# 4. Agora é SEGURO rodar npm install -g
# SUBSTITUA <TARGET> pela versão desejada (ex: 2026.5.2)
TARGET_VERSION="2026.5.2"
echo "[4] Rodando npm install -g openclaw@${TARGET_VERSION}..."
npm install -g openclaw@${TARGET_VERSION}

# 5. Validar que binário foi restaurado corretamente
echo "[5] Validando instalação..."
if ! which openclaw >/dev/null 2>&1; then
  echo "    ✗ FALHA: openclaw binary não encontrado"
  echo "    Tente manualmente: npm install -g openclaw@${TARGET_VERSION}"
  exit 1
fi
echo "    ✓ Binary restaurado: $(which openclaw)"
echo "    Version: $(openclaw --version)"

# 6. Reaplicar os patches (Recipe D + J) OBRIGATORIAMENTE
echo "[6] Reaplicando patches obrigatórios..."

# 6a. Monkey-patch fratricide #62028
echo "    [6a] Aplicando monkey-patch fratricide #62028..."
bash <(curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/reapply-monkey-patch.sh)

# 6b. Label emoji patch (OAuth Max)
echo "    [6b] Aplicando label emoji patch..."
python3 <(curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/reapply-session-status-emoji-patch.py)

# 7. Re-aplicar chattr +i em arquivos críticos
echo "[7] Re-aplicando chattr +i em arquivos críticos..."
chattr +i /root/.claude/.credentials.json 2>/dev/null || echo "    (credentials.json não encontrado, pulando)"
chattr +i /usr/local/bin/openclaw-gateway-wrapper 2>/dev/null || echo "    (gateway wrapper não encontrado, pulando)"

# Aplicar em status-message patched se existir
if ls /root/.openclaw/plugin-runtime-deps/openclaw-*/dist/status-message-*.js >/dev/null 2>&1; then
  chattr +i /root/.openclaw/plugin-runtime-deps/openclaw-*/dist/status-message-*.js
  echo "    ✓ chattr +i aplicado em status-message files"
fi

# 8. Restart do gateway
echo "[8] Reiniciando gateway..."
systemctl daemon-reload
systemctl start openclaw-gateway
sleep 3

# 9. Validação final
echo "[9] Validação final..."
if systemctl is-active --quiet openclaw-gateway; then
  echo "    ✓ Gateway ativo e estável"
  systemctl show -p NRestarts --value openclaw-gateway
  echo "    (NRestarts deve ser 0)"
else
  echo "    ✗ Gateway NÃO está ativo. Checando logs:"
  journalctl -u openclaw-gateway -n 20 --no-pager
  exit 1
fi

echo ""
echo "✓ Upgrade completo. Binário, patches e imutabilidade restaurados."
```

**VALIDATION:**

```bash
# 1. Validar que binário está funcional
which openclaw && openclaw --version
# Esperado: binário encontrado + versão matching <TARGET>

# 2. Validar que gateway está operacional
systemctl is-active openclaw-gateway
# Esperado: active

# 3. Validar que restart counter está em 0 (sem fratricide)
systemctl show -p NRestarts --value openclaw-gateway
# Esperado: 0

# 4. Validar que monkey-patch foi aplicado
grep -A2 "function cleanStaleGatewayProcessesSync" /usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js | head -5
# Esperado: aparecer "MONKEY-PATCH" comment + "return [];" como primeira instrução

# 5. Validar que emoji patch foi reaplicado
grep -c "OAuth (Max)" /root/.openclaw/plugin-runtime-deps/openclaw-*/dist/status-message-*.js 2>/dev/null || echo "emoji patch não aplicado nesta versão"
# Esperado: 2 occurrences por arquivo (se plugin existir)

# 6. Validar que chattr +i está ativo nos arquivos críticos
lsattr /usr/local/bin/openclaw-gateway-wrapper 2>/dev/null | grep -q "i" && echo "✓ Gateway wrapper imutável" || echo "✗ Gateway wrapper NÃO imutável"
lsattr /root/.claude/.credentials.json 2>/dev/null | grep -q "i" && echo "✓ Credentials imutável" || echo "✗ Credentials NÃO imutável"
```

**REVERT:**

```bash
# Se o upgrade falhou e você quer voltar pra versão anterior
TARGET_PREVIOUS="2026.4.29"

# 1. Remover chattr +i novamente (mesmo procedimento)
find /usr/lib/node_modules/openclaw -type f -exec lsattr {} \; 2>/dev/null \
  | grep "^----i" | awk '{print $NF}' | xargs -r chattr -i

# 2. Rodar npm install da versão anterior
npm install -g openclaw@${TARGET_PREVIOUS}

# 3. Reaplicar patches
bash <(curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/reapply-monkey-patch.sh)
python3 <(curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/reapply-session-status-emoji-patch.py)

# 4. Re-aplicar chattr +i
chattr +i /root/.claude/.credentials.json /usr/local/bin/openclaw-gateway-wrapper 2>/dev/null

# 5. Restart
systemctl reset-failed openclaw-gateway
systemctl start openclaw-gateway
```

**APPLIES TO:** todas versões do OpenClaw (v2026.4.x+). Lição é agnóstica de versão — qualquer upgrade futuro do binário global OpenClaw quando você tem `chattr +i` ativo em node_modules vai sofrer do mesmo problema. Procedimento é obrigatório **PRÉ-UPGRADE**, não PÓSTUMO.

---

## Contextualização: Por que isso é necessário?

O objetivo dos patches D e J é proteger arquivos críticos contra corrupção acidental **em runtime** — durante operação normal do gateway. O `chattr +i` funciona perfeitamente pra esse caso.

Porém, **não foi considerado que gerenciadores de pacotes como npm rodam operações destrutivas durante upgrade.** Quando `npm install -g openclaw@<v>` tenta substituir a árvore global de node_modules, ele:

1. Faz backup dos arquivos antigos
2. Tenta DELETAR os antigos via `rm`
3. Extrai os novos
4. Atualiza metadados

Se o step 2 falha porque `chattr +i` bloqueia `rm`, o step 3 nunca acontece — você fica com uma árvore parcial e um binário inoperável.

**Solução:** remover `chattr +i` antes de `npm install -g`, deixar npm completar, depois reaplicar `chattr +i` e re-aplicar os patches (que npm pode ter sobrescrito).

## Integração com Orquestrador

Se você usa `infra/scripts/upgrade-zero-downtime.sh`, este procedimento já está automatizado no **Phase 3b.0** (checagem + remoção de chattr antes do install). Ao rodar:

```bash
bash /root/upgrade-<VERSION>.sh
```

O orquestrador vai executar este fix automaticamente. Mas se você estiver fazendo upgrade **manual** via `npm install -g`, siga os steps acima.

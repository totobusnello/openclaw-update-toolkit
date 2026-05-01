# Recipe D — Reaplicar monkey-patch fratricide #62028

**SEVERIDADE:** 🔴 ALTA — gateway pode crashar em qualquer restart

**SYMPTOM:**
- Gateway crash loop (15+ restarts em 5min)
- Logs: "Gateway already running locally"
- SIGTERM em ~20s, NRestarts subindo rápido
- Diagnostic mostra "PATCH MISSING" na seção C

**CAUSA RAIZ:**
Issue #62028 do OpenClaw — função `cleanStaleGatewayProcessesSync` em `/usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js` mata o próprio gateway quando detecta processos "stale" (que na verdade são o próprio gateway tentando restart). Patch local força a função a retornar `[]` direto.

**O hash do nome do arquivo muda a cada versão** (ex: v4.22=`BUk5aJLm`, v4.29=`DNoLLjzi`) — usar glob `restart-stale-pids-*.js`. Desde v.27, bundle ships 2 arquivos: wrapper de re-export (~2 linhas) + impl (~510 linhas). Patch vai no impl, não no wrapper.

**INVARIANTE crítica:** **toda vez** que rodar `npm install/update -g openclaw` ou `openclaw models auth login/setup-token`, o `node_modules/dist/` é reescrito e o patch perde. **Reaplicar imediatamente** antes de qualquer restart.

**FIX:**
```bash
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/reapply-monkey-patch.sh | sudo bash
```

Ou clone + execute local: `bash scripts/recipes/reapply-monkey-patch.sh`.

**VALIDATION:**
```bash
grep -A2 "function cleanStaleGatewayProcessesSync" /usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js | head -5
# Esperado: aparecer "MONKEY-PATCH" comment e "return [];" como primeira instrução do try
systemctl show -p NRestarts --value openclaw-gateway
# Esperado: 0 (após 60s de uptime)
```

**REVERT:**
```bash
TARGET=$(ls /usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js | xargs -I{} sh -c 'wc -l < "{}" 2>/dev/null && echo "{}"' | awk 'NR%2==0 && prev>100 {print $0} {prev=$1}' | head -1)
chattr -i "$TARGET" 2>/dev/null
# Restaurar de backup mais recente
ls -1t "$TARGET.bak-"* | head -1 | xargs -I{} cp {} "$TARGET"
systemctl restart openclaw-gateway
```

**Wrapper imutável:** `/usr/local/bin/openclaw-gateway-wrapper` deve ter `chattr +i` aplicado (unset `OPENCLAW_SERVICE_MARKER/KIND`). O script de fix faz isso automaticamente se existir.

Ver detalhes completos em [`docs/recovery-guide.md`](../docs/recovery-guide.md#recipe-d--reaplicar-monkey-patch-fratricide-62028).

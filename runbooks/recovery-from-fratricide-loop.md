# Runbook — Recovery de Fratricide Loop (Issue #62028)

> **Cenário:** gateway está em crash loop. Logs mostram "Gateway already running locally", SIGTERM em ~20s, NRestarts subindo rápido.
> **Severidade:** 🔴 CRÍTICA — sistema em downtime.
> **Tempo estimado:** 5-10min.

---

## Diagnóstico rápido

Confirme que é fratricide (e não outro problema):

```bash
systemctl show -p NRestarts --value openclaw-gateway
# > 5 em < 5min = fratricide forte indício

journalctl -u openclaw-gateway --since "10 minutes ago" --no-pager | grep -cE "Gateway already running|SIGTERM|cleanStaleGateway"
# > 0 = fratricide confirmado
```

Se ambos > 0, prosseguir. Se NRestarts=0 e zero matches, é outro problema (consultar `docs/recovery-guide.md`).

---

## Passo 1 — Parar o ciclo de auto-restart (URGENTE)

Sem isso, o systemd continua spawnando processos novos enquanto você tenta diagnosticar.

```bash
# Drop-in temporário desativando Restart
mkdir -p /etc/systemd/system/openclaw-gateway.service.d
cat > /etc/systemd/system/openclaw-gateway.service.d/no-restart-emergency.conf << 'EOF'
[Service]
Restart=no
EOF
systemctl daemon-reload
systemctl stop openclaw-gateway
sleep 3
pkill -9 openclaw 2>/dev/null || true
sleep 2
ps -ef | grep -i openclaw | grep -v grep || echo "✅ Gateway parado e zero processos órfãos"
```

## Passo 2 — Identificar causa do patch ter sido perdido

Lista mais provável de quem invalidou o patch (hoje ou recentemente):

```bash
# Ver últimos comandos do shell (root)
grep -E "npm.*install|openclaw.*models.*auth|openclaw.*upgrade" /root/.bash_history | tail -10

# Ver quando o arquivo dist/ foi tocado por último
stat /usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js | grep -E "Modify|Change"
```

Causas comuns:
- `npm install/update -g openclaw` (reescreve dist/)
- `openclaw models auth login/setup-token/paste-token/add` (reinstala node_modules)
- Update automático de packages (raro mas possível)

## Passo 3 — Reaplicar monkey-patch (Recipe D)

```bash
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/reapply-monkey-patch.sh | sudo bash
```

**Validação obrigatória antes de prosseguir:**

```bash
grep -A2 "function cleanStaleGatewayProcessesSync" /usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js | head -8
```

Esperado:
```
function cleanStaleGatewayProcessesSync(portOverride) {
	try {
		// MONKEY-PATCH: Issue #62028 fratricide fix (reapplied via openclaw-update-toolkit)
		return [];
```

Se NÃO aparecer o `return [];` direto após `try {`, o patch falhou — script reportará. Investigar antes de prosseguir.

## Passo 4 — Validar wrapper imutável

```bash
ls -la /usr/local/bin/openclaw-gateway-wrapper
lsattr /usr/local/bin/openclaw-gateway-wrapper
# Esperado: ----i---------e-------
```

Se sem `i` flag:
```bash
chattr +i /usr/local/bin/openclaw-gateway-wrapper
```

## Passo 5 — Remover drop-in emergencial + restart limpo

```bash
rm /etc/systemd/system/openclaw-gateway.service.d/no-restart-emergency.conf
systemctl daemon-reload
systemctl reset-failed openclaw-gateway
systemctl start openclaw-gateway
```

## Passo 6 — Validar 60s sem fratricide

```bash
sleep 60
NRESTARTS=$(systemctl show -p NRestarts --value openclaw-gateway)
ACTIVE=$(systemctl is-active openclaw-gateway)
echo "NRestarts: $NRESTARTS (esperado: 0)"
echo "Active: $ACTIVE (esperado: active)"

if [[ "$NRESTARTS" == "0" ]] && [[ "$ACTIVE" == "active" ]]; then
  echo "✅ FRATRICIDE LOOP RESOLVIDO"
else
  echo "❌ AINDA EM PROBLEMA — investigar logs"
  journalctl -u openclaw-gateway --since "60 seconds ago" --no-pager | tail -20
fi
```

## Passo 7 — Diagnóstico completo pós-recovery

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/validate.sh)
# Esperado: 10/10 ✅
```

Se algum ❌ aparecer, aplicar Recipes correspondentes.

---

## Se NÃO funcionou

### Hipótese A: arquivo dist/ tem assinatura diferente nesta versão

```bash
# Inspecionar manualmente
PATCH_FILE=$(ls /usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js | xargs -I{} sh -c 'wc -l < "{}" | grep -v ^[0-9]$ ; echo {}' | awk 'NR%2==0 && prev>100' | head -1)
grep -nE "function cleanStaleGateway" "$PATCH_FILE"
```

Se a função tem outra assinatura (renomeada upstream?), o patch padrão não funciona. Reportar issue no toolkit com versão + signature.

### Hipótese B: tem 2 arquivos impl (raro pós-v.27)

```bash
ls -la /usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js
# Procurar o impl (>100 linhas), não o wrapper (~2 linhas)
```

### Hipótese C: gateway não é fratricide, é outra coisa

```bash
journalctl -u openclaw-gateway --since "5 minutes ago" --no-pager | grep -iE "FATAL|panic|TypeError|Cannot find|ENOENT" | head -5
```

Se aparecer `Cannot find module` ou `TypeError`, é problema diferente — ver `docs/recovery-guide.md` ou abrir issue no toolkit.

---

## Última atualização

2026-05-01.

# Runbook — Upgrade OpenClaw v2026.4.24 → v2026.4.29

> **Cenário:** você está rodando v.24, v.25, v.26, ou v.28 e quer chegar em v.29 sem quebrar.
> **Tempo estimado:** 15-30min (com janela de manutenção).
> **Risco:** médio. Backup + revert plan documentados.

---

## Pré-requisitos

- [ ] **Snapshot da VPS** no provider (Hostinger/DigitalOcean/AWS) tirado nos últimos 60min
- [ ] Acesso SSH como root
- [ ] Janela de manutenção — gateway vai ficar ~10min indisponível (canais não respondem)
- [ ] Diagnostic atual capturado:
  ```bash
  bash <(curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/diagnostic.sh) > diagnostic-pre-upgrade.txt
  ```

## Passo 1 — Backup completo (5min)

```bash
TS=$(date +%Y%m%d-%H%M%S)
BACKUP=/root/.openclaw/backups/upgrade-to-v29-$TS
mkdir -p "$BACKUP"
cp /root/.openclaw/openclaw.json "$BACKUP/"
cp /root/.openclaw/.env "$BACKUP/"
cp -r /root/.claude "$BACKUP/" 2>/dev/null
cp /usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js "$BACKUP/" 2>/dev/null
cp /usr/local/bin/openclaw-gateway-wrapper "$BACKUP/" 2>/dev/null
ls -la "$BACKUP/"
echo "Backup directory: $BACKUP"
```

**Anote o caminho do `$BACKUP`** — será necessário pro revert se algo der errado.

## Passo 2 — Pausar gateway (evitar fratricide loop durante npm install)

```bash
# Drop-in temporário pra impedir auto-restart
mkdir -p /etc/systemd/system/openclaw-gateway.service.d
cat > /etc/systemd/system/openclaw-gateway.service.d/no-restart-during-upgrade.conf << 'EOF'
[Service]
Restart=no
EOF
systemctl daemon-reload
systemctl stop openclaw-gateway
sleep 3
pkill -9 openclaw 2>/dev/null || true
sleep 2
ps -ef | grep -i openclaw | grep -v grep || echo "✅ Gateway parado, sem processos órfãos"
```

## Passo 3 — Upgrade via npm (3-5min)

```bash
npm install -g openclaw@2026.4.29 2>&1 | tail -10
openclaw --version
# Esperado: 2026.4.29.X
```

⚠️ **Após este passo:** monkey-patch fratricide #62028 foi **invalidado** (npm reescreveu node_modules/dist/). NÃO restartar antes do Passo 4.

## Passo 4 — Reaplicar monkey-patch fratricide (Recipe D)

```bash
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/reapply-monkey-patch.sh | sudo bash
```

Validação obrigatória antes de prosseguir:
```bash
grep -c "MONKEY-PATCH.*62028" /usr/lib/node_modules/openclaw/dist/restart-stale-pids-*.js
# Esperado: 1 (apenas no arquivo impl, não no wrapper)
```

## Passo 5 — Validar baseUrl + RelayPlane (Recipe F)

```bash
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/relayplane-disable.sh | sudo bash
```

`npm install` pode ter reescrito `baseUrl` pro `:4100` — esse script corrige.

## Passo 6 — Resume gateway

```bash
rm /etc/systemd/system/openclaw-gateway.service.d/no-restart-during-upgrade.conf
systemctl daemon-reload
systemctl start openclaw-gateway
sleep 12
systemctl is-active openclaw-gateway
# Esperado: active
```

Se NÃO ficar active:
```bash
journalctl -u openclaw-gateway --since "1 minute ago" --no-pager | tail -30
```

Erros mais comuns:
- `SecretRefResolutionError: Environment variable "X" missing` → vars faltando no .env (não relacionado ao upgrade — preexistia)
- `Cannot find module` → reinstalar: `npm install -g openclaw@2026.4.29`
- `Gateway already running` → fratricide loop, monkey-patch falhou no Passo 4 — reaplicar

## Passo 7 — Aplicar fixes opcionais novos da v.29

```bash
# Diagnóstico pós-upgrade
bash <(curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/diagnostic.sh) > diagnostic-post-upgrade.txt

# Comparar com diagnostic-pre-upgrade.txt pra ver se algo mudou
diff diagnostic-pre-upgrade.txt diagnostic-post-upgrade.txt
```

Aplicar Recipes baseado no diagnostic-post-upgrade:
- Recipe G (Telegram MCP) — se `enabledPlugins.telegram@claude-plugins-official: true`
- Recipe H (dmScope) — se `session.dmScope` não setado
- Recipe E (chattr credentials) — se sem `i` flag
- Recipe B (kill switch) — se algum agente sem `agentRuntime.id=claude-cli`

## Passo 8 — Validação final

```bash
sleep 30
bash <(curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/validate.sh)
# Esperado: 10/10 ✅
```

---

## Revert plan (se algo der errado)

### Cenário 1: Gateway não sobe após Passo 6

```bash
TS=<timestamp do backup feito no Passo 1>
BACKUP=/root/.openclaw/backups/upgrade-to-v29-$TS

# Voltar pra versão anterior
npm install -g openclaw@<previous-version>  # ex: 2026.4.26
cp $BACKUP/openclaw.json /root/.openclaw/
cp $BACKUP/.env /root/.openclaw/
chattr -i /usr/local/bin/openclaw-gateway-wrapper 2>/dev/null
cp $BACKUP/openclaw-gateway-wrapper /usr/local/bin/
chattr +i /usr/local/bin/openclaw-gateway-wrapper

# Reaplicar monkey-patch na versão antiga
bash <(curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/reapply-monkey-patch.sh)

systemctl reset-failed openclaw-gateway
systemctl restart openclaw-gateway
sleep 15
systemctl is-active openclaw-gateway
```

### Cenário 2: Snapshot total (último recurso)

Pelo provider da VPS — restaurar snapshot pré-upgrade. ~5min downtime.

---

## Após upgrade bem-sucedido

- [ ] Apagar drop-in temporário se ainda existir: `ls /etc/systemd/system/openclaw-gateway.service.d/`
- [ ] Validar canais funcionando (Discord/WhatsApp/Telegram/Slack response a teste)
- [ ] Monitorar `journalctl -u openclaw-gateway --since "1 hour ago"` por warnings
- [ ] Se aplicou Recipes opcionais, registrar quais
- [ ] Considerar instalar canary Telegram (opcional, oferecido por Recipe G)

---

## Versões cobertas por este runbook

| Versão atual → v.29 | Notas específicas |
|---------------------|-------------------|
| v2026.4.24 → v.29 | Salto grande — todas as Recipes B-L podem ser necessárias |
| v2026.4.25 → v.29 | Salto médio — Recipe G (telegram MCP) introduzida durante este intervalo |
| v2026.4.26 → v.29 | Salto pequeno — esperar maioria das Recipes desnecessárias |
| v2026.4.27 → v.29 | Apenas npm install + Recipe D obrigatória |
| v2026.4.28 → v.29 | Mesmo |

---

## Última atualização

2026-05-01. Compatível com v2026.4.29 ([CHANGELOG.md](../CHANGELOG.md)).

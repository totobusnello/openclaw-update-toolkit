# Recipe A — Upgrade controlado para v2026.4.29

**SEVERIDADE:** 🔴 ALTA (se versão atual < v2026.4.29) | 🟢 N/A (se já está em v.29)

**SYMPTOM:**
- Versão antiga (< v2026.4.29) com instabilidade
- Tentativas de upgrade anteriores quebraram

**CAUSA RAIZ:**
`npm install -g openclaw@<v>` reinstala `node_modules/dist/`, **invalidando** o monkey-patch fratricide #62028 e podendo reescrever `models.providers.anthropic.baseUrl` pra RelayPlane (`http://127.0.0.1:4100`).

**FIX:**
```bash
# 1. Backup completo
TS=$(date +%Y%m%d-%H%M%S)
cp /root/.openclaw/openclaw.json /root/.openclaw/openclaw.json.bak-pre-upgrade-$TS
cp /root/.openclaw/.env /root/.openclaw/.env.bak-pre-upgrade-$TS

# 2. Pause auto-restart
mkdir -p /etc/systemd/system/openclaw-gateway.service.d
echo -e "[Service]\nRestart=no" > /etc/systemd/system/openclaw-gateway.service.d/no-restart.conf
systemctl daemon-reload
systemctl stop openclaw-gateway
pkill -9 openclaw 2>/dev/null
sleep 2

# 3. Upgrade
npm install -g openclaw@2026.4.29

# 4. Reaplicar monkey-patch (Recipe D)
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/reapply-monkey-patch.sh | sudo bash

# 5. Validar baseUrl (Recipe F)
openclaw config set models.providers.anthropic.baseUrl https://api.anthropic.com

# 6. Resume
rm /etc/systemd/system/openclaw-gateway.service.d/no-restart.conf
systemctl daemon-reload
systemctl start openclaw-gateway
```

**VALIDATION:**
```bash
openclaw --version
# Esperado: 2026.4.29.X
sleep 30 && systemctl is-active openclaw-gateway
# Esperado: active
systemctl show -p NRestarts --value openclaw-gateway
# Esperado: 0
```

**REVERT:**
```bash
npm install -g openclaw@<previous-version>
cp /root/.openclaw/openclaw.json.bak-pre-upgrade-* /root/.openclaw/openclaw.json
systemctl restart openclaw-gateway
```

Ver runbook detalhado em [`runbooks/upgrade-from-v24-to-v29.md`](../runbooks/upgrade-from-v24-to-v29.md) (em breve, Fase 2).

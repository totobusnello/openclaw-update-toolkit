# Lesson 2026-05-17 — Protocol mismatch loop causado por LaunchAgent macOS com binário/env stale

## Sintoma
Após upgrade do gateway pra OpenClaw 2026.5.12 (VPS), o gateway log mostrou loop sustained de `[ws] protocol mismatch ... client=MacBook node v2026.3.12` (~26-80/min) via SSH tunnel local do MacBook do Toto. Memory peak chegou a 2.94 GB e estava em queda lenta.

Tentar `npm install -g openclaw@2026.5.12` no MacBook NÃO resolveu — versão reportada continuou `v2026.3.12`.

## Diagnóstico

Duas descobertas que andam juntas:

### 1. Há duas instalações paralelas de OpenClaw no Mac
- `/opt/homebrew/lib/node_modules/openclaw/` (versão `2026.4.29` antes do fix, dono `lab:admin`)
- `/usr/local/lib/node_modules/openclaw/` (versão `2026.3.12`, dono `root:wheel`, instalada `Mar 13 11:27`)

O `npm install -g` atualiza só o `prefix` do npm config ativo (no caso, homebrew). O `/usr/local/...` é install antigo que ficou fora do radar.

### 2. O LaunchAgent `ai.openclaw.node` aponta pro path legacy
`~/Library/LaunchAgents/ai.openclaw.node.plist`:
```xml
<key>ProgramArguments</key>
<array>
    <string>/opt/homebrew/opt/node/bin/node</string>
    <string>/usr/local/lib/node_modules/openclaw/dist/index.js</string>  ← LEGACY
    <string>node</string>
    <string>run</string>
    <string>--host</string>
    <string>127.0.0.1</string>
    <string>--port</string>
    <string>18789</string>
</array>
<key>EnvironmentVariables</key>
<dict>
    <key>OPENCLAW_SERVICE_VERSION</key>
    <string>2026.3.12</string>  ← HARDCODED no plist
    ...
</dict>
```

O `OPENCLAW_SERVICE_VERSION` é env var enviada no handshake WS — independente da versão do binário em disco. O plist foi gerado pelo App OpenClaw Mac em 2026-04-30 22:55 quando 2026.3.12 estava em uso. App Sparkle updater está parado desde **2026-03-09** (`SULastCheckTime`), então o plist nunca foi regenerado.

### 3. SSH tunnel mantido por `ai.openclaw.tunnel`
LaunchAgent paralelo executa `ssh -N -L 18789:127.0.0.1:18789 root@VPS` continuamente — daí os logs do gateway mostram `remote=127.0.0.1` (loopback da VPS, lado server do tunnel).

## Fix aplicado

```bash
# 1. npm cache root-owned files (bug npm histórico)
npm install -g openclaw@2026.5.12 --cache /tmp/npm-cache-fix

# 2. Atualizar meta.lastTouchedVersion no config local
python3 -c "import json; p='/Users/lab/.openclaw/openclaw.json';
  d=json.load(open(p)); d['meta']['lastTouchedVersion']='2026.5.12';
  d['meta']['lastTouchedAt']='<now>'; json.dump(d,open(p,'w'),indent=2)"

# 3. Editar plist do LaunchAgent
cd ~/Library/LaunchAgents
plutil -replace ProgramArguments.1 -string \
  "/opt/homebrew/lib/node_modules/openclaw/dist/index.js" ai.openclaw.node.plist
plutil -remove ProgramArguments.2 ai.openclaw.node.plist  # tira legacy path
plutil -replace EnvironmentVariables.OPENCLAW_SERVICE_VERSION -string \
  "2026.5.12" ai.openclaw.node.plist
plutil -replace Comment -string "OpenClaw Node Host (v2026.5.12)" ai.openclaw.node.plist
plutil -lint ai.openclaw.node.plist

# 4. Reload LaunchAgent
launchctl bootout gui/$(id -u)/ai.openclaw.node
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.node.plist
```

## Validação
- Antes: 266 mismatches/10min, openclaw-node CPU 99-101%, gateway log `client=MacBook node v2026.3.12`
- Depois: **0 mismatches/5min**, openclaw-node CPU 0%, log silent

## Causa estrutural (não fixada nesta sessão)
1. **Sparkle updater do App OpenClaw Mac parado** desde 9 de março. Idealmente seria abrir o App e fazer "Check for Updates" — ele regeneraria plist+env+paths e migraria pro caminho moderno.
2. **`gateway.reload.mode = hot`** permite hot-reload de mudanças de config no gateway, mas o handshake protocol version do client é checado uma vez no connect — não tem hot-reload pra clients velhos.

## Backup criado
`~/Library/LaunchAgents/ai.openclaw.node.plist.bak-pre-5.12-fix-20260517`

## Próximos passos sugeridos
1. Avisar Toto pra abrir o App OpenClaw Mac e checar updates manualmente — eventualmente Sparkle regenera tudo
2. Mover `/usr/local/lib/node_modules/openclaw/` pra `.bak-legacy-20260517` (requer sudo) — remove confusão
3. Considerar issue upstream: LaunchAgent deveria refletir versão dinamicamente, não hardcoded

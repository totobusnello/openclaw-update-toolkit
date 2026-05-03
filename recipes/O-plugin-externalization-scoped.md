# Recipe O — Instalar plugins externalized via npm scoped `@openclaw/*` SEM perder os outros

**SEVERIDADE:** 🔴 ALTA (se canais críticos sumiram pós-upgrade) / 🟡 MÉDIA (preventiva pra qualquer upgrade pra v5.2+)

**SYMPTOM:**
- Após upgrade pra v5.2 ou tentar reinstalar plugins via `openclaw plugins install`, canais que estavam funcionando (WhatsApp, Discord, Voice Call, Memory LanceDB, etc) somem de `openclaw plugins list --json`
- Tentar reinstalar um plugin via `openclaw plugins install @openclaw/<X>` instala X mas remove Y que estava instalado antes
- `ls /root/.openclaw/npm/node_modules/@openclaw/` mostra apenas o plugin mais recentemente instalado, não todos os esperados

**CAUSA RAIZ:**

Na v5.2 do OpenClaw, um **grande número de plugins core saíram do bundled tree** (embutido no binário npm global) e foram movidos pra **packages npm scoped** `@openclaw/*` (WhatsApp, Discord, Voice Call, Memory LanceDB, Matrix, Mattermost, Brave, ACPX, Diffs, Google Chat, LINE, Microsoft Teams). Essa mudança é boa pra manutenção, MAS introduz um **bug crítico no comando `openclaw plugins install`**.

Quando você roda `openclaw plugins install @openclaw/X`, o comando **NÃO é aditivo** — ele sobrescreve a lista de dependencies em `/root/.openclaw/npm/package.json` removendo qualquer plugin `@openclaw/*` anterior. Instalação sequencial de plugins resulta em **perda de todos exceto o último**:

```bash
openclaw plugins install @openclaw/whatsapp  # ✅ whatsapp aparece em plugins list
openclaw plugins install @openclaw/discord   # ✅ discord aparece — ❌ MAS whatsapp foi DELETADO
ls /root/.openclaw/npm/node_modules/@openclaw/  # Resultado: só discord
```

Adicionalmente, pacotes **SEM scope** no npm (nomes simples como `whatsapp`, `discord`) são **outros projetos completamente**:
- `whatsapp` no npm é alpha 0.0.5 sem manifest correto
- `discord` é biblioteca de jogo pra Discord.js
- Vão falhar com erro `package.json missing openclaw.extensions` (não são extensões OpenClaw)

**FIX:**

```bash
# 1. Listar plugins externalized atualmente esperados (validar se todos foram removidos)
ls /root/.openclaw/npm/node_modules/@openclaw/ 2>/dev/null
# Esperado: whatsapp, discord, memory-lance, matrix, etc (dependendo da sua stack)

# 2. Snapshot do package.json deps ANTES (pra referência)
cat /root/.openclaw/npm/package.json | jq '.dependencies | select(. != null)'

# 3. USAR NPM DIRETO — instalar TODOS os plugins externalized JUNTOS (chave!)
cd /root/.openclaw/npm
npm install @openclaw/whatsapp @openclaw/discord
# Adicionar quaisquer outros plugins que precisar: @openclaw/memory-lance, @openclaw/matrix, etc

# 4. Validar filesystem — confirmar que TODOS ficaram instalados
ls /root/.openclaw/npm/node_modules/@openclaw/
# Esperado: whatsapp/, discord/, memory-lance/, ... (conforme instalou acima)

# 5. Se algum plugin aparecer disabled em openclaw plugins list, enable explícito
openclaw plugins enable whatsapp
openclaw plugins enable discord
# Repetir pra cada um que mostrar disabled

# 6. Restart gateway pra hot-load dos plugins
systemctl restart openclaw-gateway
sleep 8  # Aguardar gateway iniciar completamente

# 7. Validar carregamento via gateway logs
openclaw plugins list --json | jq '.plugins[] | select(.id | test("whatsapp|discord|memory")) | {id, enabled, status, origin}'
# Esperado: enabled:true, status:loaded, origin:global (pra cada plugin instalado)
```

> ⚠️ **NÃO USE `openclaw plugins install` pra packages `@openclaw/*`** — use `npm install` direto em `/root/.openclaw/npm/`. O comando `openclaw plugins install` é destrutivo entre plugins scoped.

**VALIDATION:**

```bash
# Validação 1: filesystem — todos os plugins esperados presentes
ls /root/.openclaw/npm/node_modules/@openclaw/
# Exemplo esperado (variável conforme sua stack):
#   discord/
#   whatsapp/
#   memory-lance/

# Validação 2: package.json — lista todas as dependencies
cat /root/.openclaw/npm/package.json | jq '.dependencies | keys[] | select(startswith("@openclaw"))'
# Esperado: @openclaw/discord, @openclaw/whatsapp, @openclaw/memory-lance, etc (todos que instalou)

# Validação 3: status do gateway — todos carregados
openclaw plugins list --json | jq '.plugins[] | select(.origin=="global") | {id, enabled, status}'
# Esperado: enabled:true, status:loaded para whatsapp, discord, etc

# Validação 4: logs do gateway confirmando startup
journalctl -u openclaw-gateway -n 50 | grep -E "\[(whatsapp|discord|memory)" 
# Esperado: linhas como "[whatsapp] [default] starting provider ..." ou "[discord] [guild] ready"

# Validação 5: confirmar que plugin está RECEBENDO mensagens
# (aplicável se o plugin tem canal ativo) — aguarde 30s após restart
# WhatsApp: verificar "Listening for personal WhatsApp inbound messages"
# Discord: verificar que bot responde em servidor
journalctl -u openclaw-gateway | grep -i "listening\|ready\|inbound"
```

**REVERT:**

Se precisar remover um plugin instalado via npm scoped:

```bash
# Remover um plugin específico
cd /root/.openclaw/npm
npm uninstall @openclaw/<id>  # exemplo: npm uninstall @openclaw/discord

# Validar remoção
ls /root/.openclaw/npm/node_modules/@openclaw/  # <id> não deve aparecer

# Restart gateway
systemctl restart openclaw-gateway

# Confirmar que plugin não aparece mais em openclaw plugins list
openclaw plugins list --json | jq '.plugins[] | select(.id=="<id>")'
# Esperado: (nenhuma saída — plugin removido)
```

**APPLIES TO:** v2026.5.0+ (plugin externalization começou nas betas 5.0/5.1, finalizado na 5.2)

---

## Contexto técnico — por que isso acontece

OpenClaw v5.2 dividiu plugins em **duas categorias**:

### 1. **Plugins bundled** (embutidos no binário npm global)
Instalados automaticamente via `npm install -g openclaw@<v>`. Atualmente:
- Slack (Bolt SDK)
- Telegram (Grammy SDK)
- memory-core
- Muitos provedores: anthropic, google, openai, openrouter, etc

Esses ficam em `/usr/lib/node_modules/openclaw/dist/extensions/` e **NÃO requerem install separado**.

### 2. **Plugins externalized** (scoped `@openclaw/*`)
Instalados separadamente. Necessário fazer `npm install @openclaw/<id>` pra cada um.

| Plugin | Scope correto | Escopo errado (⚠️ não use) |
|--------|---------------|--------------------------|
| WhatsApp | `@openclaw/whatsapp` | `whatsapp` (alpha 0.0.5 no npm — diferente) |
| Discord | `@openclaw/discord` | `discord` (biblioteca de jogo) |
| Voice Call | `@openclaw/voice-call` | `voice-call` |
| Memory LanceDB | `@openclaw/memory-lance` | `memory-lance` |
| Matrix | `@openclaw/matrix` | `matrix` |
| Mattermost | `@openclaw/mattermost` | `mattermost` |
| Brave (web search) | `@openclaw/brave` | `brave` |
| ACPX | `@openclaw/acpx` | `acpx` |
| Diffs | `@openclaw/diffs` | `diffs` |
| Google Chat | `@openclaw/google-chat` | `google-chat` |
| LINE | `@openclaw/line` | `line` |
| Microsoft Teams | `@openclaw/teams` | `teams` |

### Como validar qual é qual

Se não tiver certeza se um plugin está bundled ou externalized:

```bash
# Bundled — está em dist/extensions/ do binário global
ls /usr/lib/node_modules/openclaw/dist/extensions/ | grep -i <plugin-name>

# Externalized — está em node_modules scoped da instalação local
ls /root/.openclaw/npm/node_modules/@openclaw/ | grep -i <plugin-name>
```

---

## Dica — Package.json como anchor pra upgrades

O arquivo `/root/.openclaw/npm/package.json` é seu **anchor** que sobrevive a upgrades. Exemplo:

```json
{
  "name": "openclaw-local-extensions",
  "version": "1.0.0",
  "dependencies": {
    "@openclaw/whatsapp": "^2026.5.2",
    "@openclaw/discord": "^2026.5.2",
    "@openclaw/memory-lance": "^2026.5.2"
  }
}
```

Quando fizer upgrade do binário global (`npm install -g openclaw@<nova-versão>`):
1. O global node_modules é atualizado (bundled plugins)
2. Seu `/root/.openclaw/npm/` **fica intacto**
3. Pra reaplicar todos os scoped plugins após upgrade: `cd /root/.openclaw/npm && npm install` (npm vê package.json, repuxa todas as deps)

Isso economiza ter que relembrar qual plugins você tinha instalado.

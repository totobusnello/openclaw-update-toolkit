# OpenClaw Update Toolkit

> **Diagnostic-driven recovery toolkit** para estabilizar instalações OpenClaw rodando entre **v2026.4.24 e v2026.4.29**.
> Cole este repo no Claude Code, ele faz tudo pra você.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![OpenClaw](https://img.shields.io/badge/OpenClaw-v2026.4.29-blue)
![Status](https://img.shields.io/badge/status-active-success)

---

## 🚀 Como usar — em 1 mensagem

Cole isso no Claude Code do seu computador (Mac/PC). Substitua `<seu-vps-ip>` pelo IP da sua VPS:

```
Lê https://github.com/totobusnello/openclaw-update-toolkit/blob/main/CLAUDE-INSTRUCTIONS.md
e arruma minha instalação OpenClaw seguindo o protocolo.
SSH: root@<seu-vps-ip>
```

Pronto. O Claude vai:
1. Conectar via SSH na sua VPS
2. Rodar diagnóstico read-only (~3min)
3. Apresentar plano de ação organizado por severidade
4. Pedir autorização do que aplicar
5. Aplicar com backup automático + validar

---

## 🎯 Quantas autorizações você vai dar

Modo **híbrido por severidade** — sem floreio, sem 12 perguntas chatas:

| Bateria | Você responde | Quando | Tempo médio |
|---------|---------------|--------|--------------|
| **🔴 ALTA — 1 autorização batch** | "vai" / "sim" | Sempre que o diagnóstico achar problema crítico (custo ativo, fratricide, plugin duplicate poller, credentials sem chattr) | ~3min total pra todas |
| **🟡 MÉDIA — 1 pergunta por recipe** | "ok" / "pula" | Pra cada recipe MÉDIA aplicável (RelayPlane, fallback chain, dmScope, sessions, delivery-queue) | ~15s cada |
| **🟢 BAIXA — só se pedir** | Você fala "também as cosméticas" se quiser | Patches cosméticos (label OAuth, cleanup disk) | opcional |

**Pior caso (instalação muito danificada):** ~5 autorizações totais.
**Caso comum:** 2-3 autorizações totais.
**Caso ideal (instalação quase ok):** 1 autorização ou nenhuma.

---

## 📌 O que esse toolkit resolve

Quando você atualiza o OpenClaw entre versões `2026.4.24 → 2026.4.29`, **vários problemas silenciosos** podem aparecer — desde gateway crash loops até cobranças inesperadas na Anthropic API. Esses problemas raramente estão na documentação oficial e custam horas pra debugar do zero.

### Sintomas que você pode estar tendo

| Sintoma observável | O que está acontecendo | Recipe |
|--------------------|------------------------|--------|
| Gateway crash loop (15+ restarts/5min, "Gateway already running") | Monkey-patch fratricide #62028 perdido pós-upgrade | **D** 🔴 |
| Custos inesperados na Anthropic API | Agentes usando profile pago em vez de OAuth Max | **B** 🔴 |
| `[telegram] getUpdates conflict 409` recorrente | Plugin MCP do Claude CLI fazendo polling paralelo | **G** 🔴 |
| Workers `openclaw-channels` em 96% CPU | Mesmo problema acima — retry-loop em cascata | **G** 🔴 |
| Agents falham com "Not logged in" / 401 após algumas horas | `.credentials.json` truncando ciclicamente sem TTY | **E** 🔴 |
| RelayPlane reativo após upgrade | npm reescreveu `baseUrl` para `127.0.0.1:4100` | **F** 🟡 |
| Fallback grudado em modelo pago | Chain com `anthropic-max` ou similar | **C** 🟡 |
| DMs misturando contexto entre peers | `session.dmScope=main` (default leak) | **H** 🟡 |
| Sessions grudaram em fallback model | `sessions.json` persistiu turn antigo | **L** 🟡 |
| `delivery-queue` com 15+ "Unknown Channel" | Canais removidos deixaram mensagens órfãs | **I** 🟡 |
| Display mostra "🔑 token" confundindo com cobrança | Label cosmético do plugin session-status | **J** 🟢 |
| Disco enchendo com `plugin-runtime-deps/openclaw-2026.*` | npm não limpa versões antigas | **K** 🟢 |

Cada Recipe está documentada em `recipes/<LETRA>-*.md` com causa raiz + fix + validação + revert.

---

## 🛡️ Como funciona — você está protegido

### 1. Diagnostic-first
Antes de qualquer mudança, o Claude roda script read-only que coleta 14 seções de estado. Você vê tudo antes de decidir.

### 2. Backup automático
Antes da primeira mudança, ele cria backup completo em `/root/.openclaw/backups/recovery-<timestamp>/`:
- `openclaw.json`
- `.env`
- `claude/settings.json`
- `claude/.credentials.json`
- arquivos do monkey-patch fratricide

### 3. Sanitização total
Tokens, credenciais, números de telefone, channel IDs **nunca** aparecem no chat. Se precisa mencionar, redact (`<REDACTED>`).

### 4. Severidade explícita
Modo híbrido evita perguntar 12 vezes. ALTA = 1 autorização batch. MÉDIA = 1 pergunta por recipe. BAIXA = só se você pedir.

### 5. Auto-rollback
Se Recipe ALTA fizer validate retornar ❌, Claude reverte sozinho usando o backup. Você é avisado.

### 6. Validação 10-invariants no fim
Roda script `validate.sh` que checa 10 condições. Esperado: 10 ✅. Se algum ❌, Claude reporta + sugere ação.

### 7. Aprovação humana sempre que importa
Os scripts são read-only. Os fixes destrutivos (chattr, patches, deletes) **só rodam com aprovação explícita sua**.

---

## 🗺️ Estrutura do toolkit

```
openclaw-update-toolkit/
├── README.md                       # você está aqui
├── CLAUDE-INSTRUCTIONS.md          # mega-prompt operacional pro Claude (não precisa ler)
├── LICENSE                          # MIT
├── docs/
│   ├── recovery-guide.md            # Guide completo (12 fix recipes + decision tree + lessons)
│   ├── concepts.md                  # Por que esses problemas existem (em breve)
│   └── faq.md                       # Perguntas frequentes (em breve)
├── scripts/
│   ├── diagnostic.sh                # Phase 0 standalone (~3min, read-only)
│   ├── validate.sh                  # 10-invariant check (exit code = nº de fails)
│   └── recipes/                     # Helpers automatizados por Recipe
│       ├── reapply-monkey-patch.sh  # Recipe D
│       ├── disable-telegram-mcp.sh  # Recipe G
│       ├── kill-switch-cost.sh      # Recipe B
│       ├── chattr-credentials.sh    # Recipe E
│       ├── relayplane-disable.sh    # Recipe F
│       ├── clean-fallback-chain.sh  # Recipe C
│       ├── dmscope-fix.sh           # Recipe H
│       ├── reset-sessions.sh        # Recipe L
│       ├── delivery-queue-cleanup.sh # Recipe I
│       ├── reapply-emoji-patch.py   # Recipe J
│       └── cleanup-plugin-runtime-deps.sh # Recipe K
├── recipes/                        # 1 .md por Recipe (referência detalhada)
│   ├── A-upgrade-controlado.md
│   ├── B-kill-switch-anthropic.md
│   ├── C-fallback-chain-limpa.md
│   ├── D-monkey-patch-fratricide.md
│   ├── E-credentials-immutable.md
│   ├── F-relayplane-disable.md
│   ├── G-telegram-mcp-disable.md
│   ├── H-dmscope-per-channel-peer.md
│   ├── I-delivery-queue-cleanup.md
│   ├── J-label-oauth-max-patch.md
│   ├── K-plugin-runtime-deps-cleanup.md
│   └── L-sessions-stickiness-reset.md
├── runbooks/                       # Caminhos completos por cenário (em breve)
│   ├── upgrade-from-v24-to-v29.md
│   ├── recovery-from-fratricide-loop.md
│   └── recovery-from-cost-explosion.md
└── lessons/                        # Insights por incident (em breve)
    └── 2026-05-01-mcp-duplicate-poller.md
```

---

## ⚙️ Métodos alternativos de uso

### Método 1 — Claude Code (recomendado)

Já descrito acima. Mais fácil. Usuário quase não faz nada.

### Método 2 — Manual (se preferir controle total)

Direto via SSH na sua VPS:

```bash
# 1. Diagnóstico
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/diagnostic.sh | sudo bash

# 2. Ler output, decidir quais Recipes aplicar

# 3. Aplicar Recipes individuais (exemplo Recipe D — monkey-patch)
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/reapply-monkey-patch.sh | sudo bash

# 4. Validar
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/validate.sh | sudo bash
```

### Método 3 — Clone local (pra modificar)

```bash
git clone https://github.com/totobusnello/openclaw-update-toolkit.git
cd openclaw-update-toolkit
# editar conforme necessário
sudo bash scripts/diagnostic.sh
```

---

## 🧠 Aprendizados não-óbvios incluídos

Coisas que custaram horas/dias pra descobrir e estão documentadas no `docs/recovery-guide.md`:

1. **Plugin MCP do Claude CLI ≠ plugin nativo do OpenClaw gateway** — são stacks separados
2. **`getWebhookInfo` mostra estado limpo entre conflicts** — duplicate poller é efêmero (subprocess CLI)
3. **`gateway.reload.mode = "watch"` é INVÁLIDO** — gateway aceita silenciosamente, volta pra `off`. Valores válidos: `[off, restart, hot, hybrid]`
4. **Editar `openclaw.json` com `jq` + `mv` NÃO aplica em runtime** — gateway tem in-memory canonical state
5. **2 tokens distintos no Claude CLI Max** podem divergir silenciosamente; `claude auth status` mente
6. **`.credentials.json` trunca ciclicamente sem TTY** — `chattr +i` é mandatório
7. **`agents.list[]` é array, não objeto** — per-agent override usa índice, não id
8. **`gpt-5.5` no runtime catalog ≠ config registry** — assimetria silenciosa
9. **Sessions stickiness** — fallback grudado em `sessions.json` requer reset manual
10. **`commands.restart=false` da regra antiga é desnecessário** — monkey-patch protege independente

---

## 🔄 Manutenção e atualizações

Esse toolkit é **mantido ativamente** sincronizado com uma instalação OpenClaw real em produção. Cada vez que o time encontra um novo problema/fix, atualizamos aqui.

- **Versionamento:** `CHANGELOG.md` lista atualizações por data
- **Trigger de update:** após qualquer incident documentado em produção
- **Compatibilidade:** v2026.4.29 é o foco principal. Versões anteriores cobertas em runbooks específicos
- **Quando OpenClaw shipar v2026.4.30+:** algumas Recipes podem ficar obsoletas. Vamos atualizar.

---

## 🤝 Contribuir

### Reportar problema novo

Abra issue em [github.com/totobusnello/openclaw-update-toolkit/issues](https://github.com/totobusnello/openclaw-update-toolkit/issues) com:
- Versão OpenClaw (`openclaw --version`)
- Output do `scripts/diagnostic.sh`
- Sintoma observável (mensagem de erro, comportamento)
- Comando que disparou (se aplicável)

### Sugerir Recipe nova

PR welcome com formato em `recipes/<LETRA-OU-NOVO>-<nome>.md`:
```
## Recipe X — <título curto>
**SEVERIDADE:** ALTA / MÉDIA / BAIXA
**SYMPTOM:** <o que o user vê>
**CAUSA RAIZ:** <explicação técnica>
**FIX:** <comando exato>
**VALIDATION:** <como confirmar>
**REVERT:** <como desfazer>
```

E (idealmente) um script idempotente em `scripts/recipes/`.

---

## ⚠️ Disclaimer

Este toolkit roda como **root na sua VPS** e modifica configs críticas. Use com:
- ✅ Backup completo da VPS (snapshot do provider) antes da primeira execução
- ✅ Diagnóstico read-only primeiro (`scripts/diagnostic.sh`)
- ✅ Aprovação explícita pra cada Recipe (não automatize cegamente)
- ✅ Validação pós-fix (`scripts/validate.sh`)

Os recipes foram validados em produção mas **toda instalação é única**. Se algo der errado, use os REVERT documentados ou os backups timestampados.

Os autores não se responsabilizam por danos. Use por sua conta e risco.

---

## 📜 Licença

[MIT](LICENSE) — use, modifique, distribua livremente.

---

## 🙏 Reconhecimentos

Compilado em maio/2026 a partir de incidents reais documentados em produção. Inspirado por noites perdidas debugando OpenClaw e zero documentação upstream sobre os problemas mais comuns.

Se este toolkit te economizou horas, considere:
- ⭐ Star no repo
- 🐛 Reportar problemas novos
- 🤝 PR com Recipes que descobriu

**OpenClaw not affiliated.** Este é um projeto comunitário independente.

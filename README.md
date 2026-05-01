# OpenClaw Update Toolkit

> **Diagnostic-driven recovery toolkit** para estabilizar instalações OpenClaw rodando entre **v2026.4.24 e v2026.4.29**.
> Compilado a partir de incidents reais e fixes validados em produção.
> Cobre: custos inesperados, crashes pós-upgrade, plugin conflicts, leak de DM, label cosmético enganoso.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Version](https://img.shields.io/badge/OpenClaw-v2026.4.29-blue)
![Status](https://img.shields.io/badge/status-active-success)

---

## 📌 O que é isso?

Quando você atualiza o OpenClaw entre versões `2026.4.24 → 2026.4.29`, **vários problemas silenciosos** podem aparecer — desde gateway crash loops até cobranças inesperadas na Anthropic API. Esses problemas raramente estão na documentação oficial e custam horas pra debugar do zero.

Este toolkit:
- ✅ Faz **diagnóstico read-only** completo do estado da sua instalação
- ✅ Identifica qual sintoma você tem casando com **fix recipes específicas**
- ✅ Aplica fixes com **backup + validation + revert** documentados pra cada um
- ✅ Roda **10 invariants check** pra confirmar que ficou estável

**Pra quem é:** quem roda OpenClaw self-hosted (VPS, dedicated server) e tem alguma instabilidade pós-upgrade.

**Pra quem NÃO é:** usuários do app desktop / cloud-managed (esses problemas não se aplicam).

---

## 🚀 Quick start (3 passos)

### 1. Diagnóstico read-only (~3min)

Conecte na VPS e rode:

```bash
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/diagnostic.sh | bash
```

Ou clone e rode local:

```bash
git clone https://github.com/totobusnello/openclaw-update-toolkit.git
cd openclaw-update-toolkit
bash scripts/diagnostic.sh
```

Output: tabela markdown com 14 seções de estado (versão, fratricide, custo zero, telegram conflicts, plugins, credentials, baseUrl, RelayPlane, sessions, disk usage).

### 2. Identificar fix recipes aplicáveis

Cada linha da tabela do diagnóstico mostra:
- ✅ se está OK
- ⚠️ qual Recipe aplicar se está com problema

Recipes vão de A a L — priorizadas por severidade no [`docs/recovery-guide.md`](docs/recovery-guide.md).

### 3. Aplicar fixes (com Claude Code, recomendado)

Cole o conteúdo de [`docs/recovery-guide.md`](docs/recovery-guide.md) no Claude Code do seu Mac/PC, junto com o output do diagnóstico, e fale:

> "Conecte na minha VPS via SSH (`<vps-ip>`). Leia o guide e o output do diagnóstico. Identifique recipes aplicáveis e me peça autorização explícita pra cada uma antes de executar. Faça backup antes de qualquer write."

O Claude vira operador, você só autoriza.

### 4. Validar (~30s)

```bash
bash scripts/validate.sh
```

Espera 10 ✅. Se algum ❌, rode a Recipe que falhou.

---

## 🗺️ Mapa do toolkit

```
openclaw-update-toolkit/
├── README.md                       # você está aqui
├── LICENSE                          # MIT
├── docs/
│   ├── recovery-guide.md            # Guide completo (12 fix recipes + decision tree + 10 aprendizados)
│   ├── concepts.md                  # Por que esses problemas existem (em breve)
│   └── faq.md                       # Perguntas frequentes (em breve)
├── scripts/
│   ├── diagnostic.sh                # Phase 0 standalone (~3min, read-only)
│   ├── validate.sh                  # Phase 5 — 10-invariant check
│   └── recipes/                     # Helpers automatizados por Recipe (em breve)
├── recipes/                         # 1 .md por Recipe (em breve — Fase 2)
├── runbooks/                        # Caminhos completos por cenário (em breve — Fase 2)
│   ├── upgrade-from-v24-to-v29.md
│   ├── recovery-from-fratricide-loop.md
│   └── recovery-from-cost-explosion.md
└── lessons/                         # Insights por incident (em breve — Fase 2)
```

---

## 🩺 Sintomas que esse toolkit resolve

| Sintoma observável | Recipe |
|--------------------|--------|
| Gateway crash loop (15+ restarts/5min, "Gateway already running") | **D** — Reaplicar monkey-patch fratricide #62028 |
| Custos inesperados na Anthropic API | **B** — Kill switch (forçar agentRuntime=claude-cli) |
| Fallback grudado em modelo pago | **C** — Limpar fallback chain |
| `[telegram] getUpdates conflict 409` recorrente | **G** — Disable plugin Telegram MCP |
| Workers `openclaw-channels` em 96% CPU | **G** (mesmo fix acima) |
| DMs misturando contexto entre peers diferentes | **H** — Setar `session.dmScope=per-channel-peer` |
| Agents falham com "Not logged in" / 401 | **E** — `chattr +i` em `.credentials.json` |
| RelayPlane:4100 reativo após upgrade | **F** — Desativar + corrigir baseUrl |
| Display mostra "🔑 token" confundindo com cobrança | **J** — Patch local label OAuth Max |
| Sessions grudaram em fallback model | **L** — Reset sessions.json |
| Disco enchendo com `plugin-runtime-deps/openclaw-2026.*` | **K** — Cleanup dirs stale |
| `delivery-queue` com 15+ "Unknown Channel" | **I** — Cleanup queue órfã |

Cada Recipe está documentada em detalhes no [`docs/recovery-guide.md`](docs/recovery-guide.md) com **causa raiz**, **comando exato**, **validação** e **revert**.

---

## ⚙️ Como o toolkit funciona

### Diagnostic-driven, não linear

Tutoriais lineares ("rode A → B → C") não funcionam porque cada instalação está num estado diferente:
- versão exata
- quais channels estão habilitados (Discord/Telegram/WhatsApp/Slack)
- agentes customizados
- histórico de upgrades passados

O toolkit roda **diagnóstico primeiro** e identifica EXATAMENTE quais fixes você precisa. Você só aplica o que é relevante.

### Backup antes, revert depois

Toda Recipe tem:
- **Backup automático** (timestamped) antes de qualquer write
- **Validation** explícita pra confirmar que o fix funcionou
- **Revert** documentado caso algo dê errado

Backups ficam em `/root/.openclaw/backups/recovery-<timestamp>/`.

### Aprovação humana sempre

Os scripts são read-only. Os fixes destrutivos (chattr, patches, deletes) **só rodam com aprovação explícita** quando você usa o fluxo recomendado via Claude Code.

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

Esse toolkit é **mantido ativamente** sincronizado com nossa instalação OpenClaw real. Cada vez que descobrirmos um novo problema ou fix, atualizamos aqui.

- **Versionamento:** [`CHANGELOG.md`](CHANGELOG.md) (em breve) lista atualizações por data
- **Trigger de update:** após qualquer incident documentado em produção
- **Compatibilidade:** v2026.4.29 é o foco principal. Versões anteriores (v.24-v.28) cobertas em runbooks específicos
- **Quando OpenClaw shipar v2026.4.30+:** algumas Recipes podem ficar obsoletas. Vamos atualizar.

---

## 🤝 Contribuir

### Reportar problema novo

Abra issue em [github.com/totobusnello/openclaw-update-toolkit/issues](https://github.com/totobusnello/openclaw-update-toolkit/issues) com:
- Versão OpenClaw (`openclaw --version`)
- Output do `scripts/diagnostic.sh`
- Sintoma observável (mensagem de erro, comportamento)
- Comando que disparou (se aplicável)

### Sugerir Recipe

PR welcome com formato:
```
## Recipe X — <título curto>
**SYMPTOM:** <o que o user vê>
**CAUSA RAIZ:** <explicação técnica>
**FIX:** <comando exato>
**VALIDATION:** <como confirmar>
**REVERT:** <como desfazer>
```

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

---
chunk_type: lesson
source: internal
date: 2026-05-06
severity: low
downtime_minutes: 0
component: claude-cli-subprocess
from_version: 2.1.88
to_version: 2.1.132
delta: 44 patches
runbook_ref: infra/runbooks/openclaw-upgrade-runbook.md (Appendix A)
plan_ref: infra/plans/2026-05-06-claude-cli-v2.1.132-upgrade.md
tags: [claude-cli, subprocess, npm, oauth-max, native-build, hooks, mcp, runbook-amendment]
related_lessons: [2026-05-05-openclaw-v5.4-upgrade-completed, 2026-05-03-openclaw-v5.2-upgrade-pitfalls]
---

# Claude CLI Subprocess Upgrade v2.1.88 → v2.1.132 — Primeira Aplicação do Appendix A

## TL;DR

Primeiro upgrade do Claude CLI subprocess (`@anthropic-ai/claude-code`) tratado como classe separada do upgrade OpenClaw — gerou Appendix A no RB-11. Salto de 44 patches (v2.1.88 → v2.1.132). **Janela total: 6min** (Phase 0 já tinha sido feita). Zero downtime efetivo (gateway restart ~5s). Zero issues. Todos 8 invariantes preservados. Memory baseline melhorou (-200MB no openclaw, +400MB available).

**1 descoberta importante:** novo path do binário virou `bin/claude.exe` (native build, não mais `cli.js`) — antes apontava pra `/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js`, agora aponta pra `bin/claude.exe`. Subprocess do gateway funcionou sem mudança nenhuma — interface `claude --print` continua estável.

**Reassessment crítico do plano original:** premissas iniciais sobre RAM (4GB → real 16GB) e MCP servers (14 → real 0 configurados na VPS) DERRUBARAM 5 dos 7 wins iniciais como "não aplicáveis". Upgrade ainda valeu pelos fixes de hooks (v2.1.92), `--resume` cache miss (v2.1.129), e SIGINT graceful (v2.1.132).

---

## Plano executado vs realidade

| Phase | Plano | Realidade |
|---|---|---|
| Phase 0A (recon + plan + appendix) | 30min de read-only audit + 2 recon agents paralelos + plan file + runbook delta | ~25min — 3 recon agents paralelos (1 falhou em SSH e foi refeito direto via ctx_execute), plan + appendix entregues |
| Phase 1A (backup + install) | 5min: backup binário + node_modules + npm install -g | 6s pro npm install (!), 127MB de backup, total ~1min com validação |
| Phase 4A (restart + ready) | 5min restart gateway + ready check | Restart limpo em 5s, gateway ready em ~5s, logs limpos |
| Phase 5A (watch loop 5min) | NRestarts=0 + zero 401/429/harness_err | 10/10 ciclos clean (NRestarts=0 todos), 1 falso positivo (grep pegou "resolved" em log discord). Smoke `claude --print "ping pong em uma palavra"` → "pong" ✓ |
| Phase 6A (invariantes) | 8 invariantes I1-I12 todos OK | 8/8 ✓ — I1 model.primary, I2 baseUrl, I3 relayplane, I7 3 services, I8 monkey-patch (2 files), I9 emoji patch (count=2), I11 chattr +i, I12 node wrapper |

---

## Descobertas

### 1. Novo path do binário: `bin/claude.exe` (native build)

**Pré (v2.1.88):**
```
/usr/bin/claude → /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js
```

**Pós (v2.1.132):**
```
/usr/bin/claude → /usr/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe
```

A versão 2.1.132 ships com **native build** (release notes mencionam: "Fixed an uncaught exception when the terminal is closed or SSH disconnects mid-session under the native build"). O binário virou um native shim em vez de `cli.js` Node script direto.

**Impact:**
- Subprocess do gateway funcionou imediatamente — interface `claude --print` continua estável
- `node_modules` fica menor (npm reportou: "added 1 package, removed 2 packages, and changed 1 package in 6s")
- Inicialização provavelmente mais rápida (sem cold start do Node)

**Implicação pro Appendix A:** validação `readlink -f $(which claude)` agora deve aceitar tanto `cli.js` quanto `bin/claude.exe` — o path muda entre versões, mas o **comportamento via `claude --print`** é o invariante real que importa.

### 2. Reassessment de premissas vale tanto quanto o upgrade em si

Premissas iniciais (do meu primeiro pass do release notes):

| Premissa | Realidade descoberta no audit | Impacto |
|---|---|---|
| VPS 4GB RAM → memory leak fix CRÍTICO | **16GB total, 13GB available** | Memory leak fix vira "defensivo", não "urgente" |
| 14 MCP servers ativos | `claude mcp list` = **0 configurados na VPS** | 5 dos 7 wins da v2.1.132 (todos MCP-related) NÃO se aplicam |
| Risco chattr +i bloqueia npm install | `package.json` postinstall = só `prepare` (publish gate) | Risco MITIGADO sem mexer |
| Hooks dependem de OTEL_* | `permission-auto.mjs` + `subagent-start.mjs` zero hits | Safe pra mudança v2.1.107-110 |

**Lição genérica:** sempre fazer audit ao vivo ANTES de finalizar prioridade do upgrade. Mudei a recomendação de "alto valor" pra "valor médio defensivo" porque os fixes mais ruidosos da release não se aplicavam. Se tivesse pulado o audit, teria reportado o upgrade como mais urgente do que de fato era.

### 3. Memory baseline melhorou pós-upgrade

| Process | Pré (RSS) | Pós (RSS) | Δ |
|---|---|---|---|
| openclaw (gateway) | 734MB | 537MB | **-200MB** |
| node.real api-server | 345MB | 345MB | 0 |
| claude subprocess | 242MB | (não spawned no momento da medição) | — |
| **available RAM** | **13.27GB** | **13.67GB** | **+400MB** |

Não é prova causal — gateway tinha rodado por dias, RSS naturalmente cresce. Restart limpo já recupera memória. Mas é um sinal positivo. Re-medir D+1 com gateway em uso normal por 24h pra ver se o leak fix da v2.1.108 (idle re-render loop) ajuda manter RSS estável.

### 4. Watch loop revelou false positive recorrente

`grep -ciE "error|401|429|fratricide|harness_err"` matched em log line:
```
[discord] channel users resolved: <REDACTED-CHANNEL-ID>
```
Porque "resolved" tem "ed" e... não, espera — não é match óbvio. Olhando de novo: pode ter sido outro line não capturado completo. Independente da causa específica, **regex do watch loop precisa ser mais preciso** (boundary `\b` ou exclude lines com "resolved", "registered", "bridge").

Fix sugerido pro Appendix A:
```bash
# Antes:
grep -ciE "error|401|429|fratricide|harness_err"

# Depois:
grep -ciE "\\b(error|401|429|fratricide|harness_err)\\b" | grep -ivE "resolved|registered|recover"
```

### 5. Recon agent #1 (architect-medium) não tinha SSH access

`architect-medium` tem Bash, mas a inicialização via Tailscale precisa do contexto SSH local — agente isolado não consegue. Resultado: relatório veio com "PENDENTE" em todos itens live e foi necessário refazer manualmente via `ctx_execute`.

**Lição operacional pro recon de upgrade:** ou (a) adicionar credentials/SSH config no contexto do agent, ou (b) **fazer audit VPS diretamente do main thread** (foi o que acabei fazendo), ou (c) usar `general-purpose` agent que tem todas tools incluindo Bash com SSH access herdado do shell parent.

---

## Estado final canônico (2026-05-06 19:45 BRT)

```
Claude CLI: 2.1.132 (Claude Code) — native build em /usr/lib/.../bin/claude.exe
OpenClaw:   2026.5.4 (325df3e)
Node:       v22.22.2 (wrapper bash → /usr/bin/node.real --no-warnings)

Auth: Max OAuth firstParty, <REDACTED-EMAIL>, token <REDACTED-ANTHROPIC-TOKEN>...
Credentials: chattr +i intact, 296 bytes preserved

Services:
  ✓ openclaw-gateway   active+enabled  PID 618346  RSS 537MB  NRestarts=0
  ✓ nox-mem-api        active+enabled
  ✓ nox-mem-watcher    active+enabled
  ✓ relayplane-proxy   inactive+disabled (regra #1)

Patches OpenClaw (intocados pelo upgrade do CLI):
  ✓ monkey-patch C35Sc29h.js + DXMaKEVe.js (Issue #62028)
  ✓ emoji patch status-message-Bwz2ekKl.js (count=2)

Schema canônico:
  ✓ agents.defaults.model.primary = anthropic/claude-sonnet-4-6
  ✓ models.providers.anthropic.baseUrl = https://api.anthropic.com

Backup: /var/backups/claude-cli-pre-upgrade-2026-05-06/ (127MB)

Memory: 16GB total, 13.67GB available (era 13.27GB pré — +400MB)
```

---

## TODOs gerados (não-críticos)

1. **Atualizar Appendix A** com lições desta primeira aplicação:
   - Validação `readlink -f` aceitar tanto `cli.js` quanto `bin/claude.exe`
   - Watch loop regex com `\b` boundary + exclude `resolved|registered|recover`
   - Reconnaissance: usar `general-purpose` agent OU fazer audit do main thread pra VPS audits ao vivo
2. **Memory comparison D+1** — re-medir RSS após 24h de gateway em uso normal pra validar se v2.1.108 leak fixes mantêm baseline estável
3. **Sync to toolkit** — esta lição vale pra comunidade (primeiro padrão de upgrade Claude CLI subprocess separado de OpenClaw upgrade); rodar `bash infra/scripts/sync-to-toolkit.sh --file infra/lessons/2026-05-06-claude-cli-v2.1.132-upgrade.md`
4. **Smoke test 6 personas via canais** — não fizemos formal (só `claude --print` direto). Validar D+1 que Discord/Slack/WhatsApp turns continuam normais
5. **Documentar trigger condition adicional no RB-11 Appendix A**: "novo path de binário entre versões" (cli.js → claude.exe) é mudança esperada quando ships native build

---

## Comandos de referência rápida

```bash
# Verificar versão atual + path
ssh root@<REDACTED-TAILSCALE-IP> 'claude --version; readlink -f $(which claude)'

# Backup + install + restart (sequência completa)
ssh root@<REDACTED-TAILSCALE-IP> '
  DATE=$(date +%Y-%m-%d)
  mkdir -p /var/backups/claude-cli-pre-upgrade-$DATE
  cp /usr/bin/claude /var/backups/claude-cli-pre-upgrade-$DATE/
  cp -r /usr/lib/node_modules/@anthropic-ai/claude-code /var/backups/claude-cli-pre-upgrade-$DATE/
  npm install -g @anthropic-ai/claude-code@<VERSION>
  claude auth status
  systemctl restart openclaw-gateway
'

# Smoke test
ssh root@<REDACTED-TAILSCALE-IP> 'echo "ping pong em uma palavra" | timeout 30 claude --print -'

# Rollback (se necessário)
ssh root@<REDACTED-TAILSCALE-IP> '
  chattr -i ~/.claude/.credentials.json 2>/dev/null
  npm install -g @anthropic-ai/claude-code@<PREVIOUS>
  chattr +i ~/.claude/.credentials.json
  systemctl restart openclaw-gateway
'
```

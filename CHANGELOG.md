# Changelog

Todas as mudanças notáveis deste toolkit serão documentadas aqui.

Formato baseado em [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versionamento independente do OpenClaw — kit segue semver próprio.

## [Unreleased]

### Adicionado
- **Lesson** [`lessons/2026-05-06-whatsapp-creds-chattr-drift.md`](lessons/2026-05-06-whatsapp-creds-chattr-drift.md) — Primeiro run do smoke-test-whatsapp.sh em produção (recém-criado) revelou que /root/.openclaw/credentials/whatsapp/default/creds.json estava sem chattr +i — violação direta da lição 2026-05-04 (orches
- **Lesson** [`lessons/2026-05-03-graph-memory-json-mode.md`](lessons/2026-05-03-graph-memory-json-mode.md) — Plugin graph-memory usando Gemini 2.5-flash-lite falha ~5-10% das extrações com SyntaxError: Unexpected non-whitespace character after JSON at position 416. Root cause: Gemini frequentemente wrappa JSON em markdown  json...  blocks mesmo com temperature: 0.1 e "JSON only" system 
- **Lesson** [`lessons/2026-05-04-followup-5.3.1-validation-schema-channels.md`](lessons/2026-05-04-followup-5.3.1-validation-schema-channels.md) — Continuação da sessão 2026-05-04 cobrindo 4 tópicos não capturados nas 3 lessons anteriores:
- **Lesson** [`lessons/2026-05-04-noxmem-429-false-auto-heals.md`](lessons/2026-05-04-noxmem-429-false-auto-heals.md) — Canary semantic disparava "auto-healed" 5×/dia em horários alinhados com cron /30. Hipótese inicial: processo dropping sem supervisor. Realidade: nox-mem-api ficou up o dia inteiro (NRestarts=0). 429 transitório do Gemini batia em geminiEmbedQuery que não tinha retry — só embedBa
- **Lesson** [`lessons/2026-05-04-orchestrator-staging-roubou-sessao-baileys-whatsapp.md`](lessons/2026-05-04-orchestrator-staging-roubou-sessao-baileys-whatsapp.md) — Phase 1 do upgrade-zero-downtime.sh subiu staging gateway que carregou plugin whatsapp lendo creds de produção (/root/.openclaw/credentials/whatsapp/default/creds.json). WhatsApp Web só permite 1 device-key por vez — staging+prod usando mesmos creds → Baileys invalidou sessão de 
- **Lesson** [`lessons/2026-05-04-staging-gateway-contaminates-prod-config.md`](lessons/2026-05-04-staging-gateway-contaminates-prod-config.md) — Phase 1 do upgrade-zero-downtime.sh sobe um staging gateway com OPENCLAW_WORKSPACE=/tmp/openclaw-staging-workspace esperando isolamento. Durante dry-run de 5.2 → 5.3 descobriu-se que o staging gateway escreve em /root/.openclaw/openclaw.json (path hardcoded), não no workspace iso
- **Lesson** [`lessons/2026-05-05-codex-oauth-headless-callback-curl.md`](lessons/2026-05-05-codex-oauth-headless-callback-curl.md) — openclaw models auth login --provider openai-codex em VPS headless: comando spawna listener HTTP em 127.0.0.1:1455/auth/callback esperando o browser entregar o code do OAuth. Browser está no Mac do operador, não na VPS — então o redirect natural não chega no listener. Solução: co
- **Lesson** [`lessons/2026-05-05-crontab-silent-loss-and-restore.md`](lessons/2026-05-05-crontab-silent-loss-and-restore.md) — Durante a sessão de upgrade 2026.5.3-1 em 2026-05-04 13:29 BRT, algum step (orchestrator, follow-up, ou intervenção manual não-documentada) reescreveu o crontab do user root deixando apenas 1 entry (beir-kill-if-overload.sh). 26 cron jobs OpenClaw foram silenciosamente desativado
- **Lesson** [`lessons/2026-05-05-openclaw-v5.4-graph-memory-build-required.md`](lessons/2026-05-05-openclaw-v5.4-graph-memory-build-required.md) — Upgrade 2026.5.3-1 → 2026.5.4 parecia patch incremental sem cutover estrutural (96 extensions bundled idênticas, sem novo plugin externalization, sem mudança de schema). Phase 2 (atomic swap) completou em ~30s, watch loop 5min limpo, gateway healthy. MAS Phase 5 detectou harness_
- **Lesson** [`lessons/2026-05-05-openclaw-v5.4-upgrade-completed.md`](lessons/2026-05-05-openclaw-v5.4-upgrade-completed.md) — Upgrade 2026.5.3-1 → 2026.5.4 patch incremental (≈280 fixes, sem cutover estrutural). Janela total: ~2h (Phase 0 read-only + Phase 1 staging dry-run + Phase 2 atomic swap + 6 follow-ups). Zero downtime efetivo (gateway offline ~30s no atomic swap + ~6s × 3 nos restarts dos follow
- **Lesson** [`lessons/2026-05-05-post-v5.4-doctor-hygiene-bootstrap-trim.md`](lessons/2026-05-05-post-v5.4-doctor-hygiene-bootstrap-trim.md) — Sessão de hygiene 6h após o upgrade 5.4 estabilizar. openclaw doctor flagou 8 itens; resolvidos 7 (1 descartado por escolha). Aprendizados que valem replicar:
- **Lesson** [`lessons/2026-05-06-claude-cli-v2.1.132-upgrade.md`](lessons/2026-05-06-claude-cli-v2.1.132-upgrade.md) — Primeiro upgrade do Claude CLI subprocess (@anthropic-ai/claude-code) tratado como classe separada do upgrade OpenClaw — gerou Appendix A no RB-11. Salto de 44 patches (v2.1.88 → v2.1.132). Janela total: 6min (Phase 0 já tinha sido feita). Zero downtime efetivo (gateway restart ~


## [0.4.1] — 2026-05-03 (graph-memory JSON mode fix)

### Adicionado
- **Recipe P** (`recipes/P-graph-memory-json-mode.md`) — fix pra bug do plugin `graph-memory` que falha `JSON.parse` em ~5-10% dos turns quando o LLM (Gemini 2.5-flash-lite especialmente, mas também outros) wrappa resposta em ` ```json...``` ` markdown blocks. Solução: forçar `response_format: { type: "json_object" }` no body do fetch contra endpoint OpenAI-compatible. Patch idempotente (Python regex), aplicável a todas versões do graph-memory plugin (1.x+) com provider OpenAI-compatible (Gemini, OpenAI, Mistral, OpenRouter, Ollama, LM Studio, etc).

### Notas
- Bug **pré-existente** (não introduzido pela v5.2). Detectado durante smoke test pós-upgrade. RECALL não é afetado (lê graph existente); apenas EXTRACT degrada (~10% dos turns não viram nodes/edges). Severidade MÉDIA.

## [0.4.0] — 2026-05-03 (Phase 4 — v5.2 awareness)

### Adicionado
- **3 recipes novas** cobrindo pitfalls não-documentados da v2026.5.2:
  - `recipes/M-web-search-validation-strict.md` — `tools.web.search.provider` validação strict introduzida em v5.0+ (#53092). Config-zumbi com plugin disabled bloqueia boot. Fix: trocar pra `duckduckgo` (bundled, zero-config) ou outros providers válidos
  - `recipes/N-chattr-vs-npm-install.md` — protocolo obrigatório `chattr -i` pré-`npm install -g openclaw@<v>`. Sem isso, npm `rm` falha com "Operation not permitted" e binário openclaw fica QUEBRADO no meio do install. Aplica-se a TODAS as versões com Recipe D ou Recipe J ativas
  - `recipes/O-plugin-externalization-scoped.md` — instalar plugins externalized `@openclaw/*` (WhatsApp/Discord/Voice Call/Brave/etc.) via `npm install` direto. `openclaw plugins install` é DESTRUTIVO entre packages scoped (cada install remove o anterior)
- **Runbook genérico** `runbooks/upgrade-any-version.md` (substitui efetivamente `upgrade-from-v24-to-v29.md`):
  - Decision tree automático por gap de versões (current vs target)
  - Parametrizado pra qualquer transição entre v2026.4.24 e v2026.5.2+
  - Phases 0-7 zero-downtime + auto-rollback embutido
  - Tabela de recipes obrigatórias por gap
- **3 lessons sincronizadas** do upstream privado (sanitizadas):
  - `lessons/2026-04-20-openclaw-gateway-fratricide-issue-62028.md` — origem do monkey-patch fratricide (Recipe D)
  - `lessons/2026-05-01-claude-cli-plugin-telegram-duplicate-poller.md` — versão completa do MCP duplicate poller (Recipe G); substitui versão anterior mais curta
  - `lessons/2026-05-03-openclaw-v5.2-upgrade-pitfalls.md` — 3 pitfalls da v5.2 com recovery completo

### Modificado
- **`scripts/diagnostic.sh`** — 5 seções novas (O-S):
  - O. Web search provider validation (v5.2+ strict)
  - P. `chattr +i` no node_modules global (Recipe N awareness)
  - Q. Plugin externalization `@openclaw/*` (Recipe O coverage)
  - R. `meta.lastTouchedVersion` (doctor "install repair" trigger)
  - S. Schema 5.2 — `agentRuntime.id` removed status
- **`scripts/validate.sh`** — 4 invariants novos (11-14, version-aware, total agora 14):
  - 11. `tools.web.search.provider` plugin instalado+enabled
  - 12. Sem `chattr +i` bloqueando node_modules global (warn pré-upgrade)
  - 13. Plugins externalizados configurados estão fisicamente presentes (skip se < 5.2)
  - 14. `meta.lastTouchedVersion == installed` (skip se < 5.2)
- **README.md** — scope expandido pra v2026.4.24 → v2026.5.2+, badge atualizado, seção "Novidades v5.2" adicionada

### Removido
- `lessons/2026-05-01-mcp-duplicate-poller.md` — versão anterior mais curta substituída pela completa do upstream

### Sustentabilidade
- Sanitização aplicada em todas as 3 lessons sincronizadas: tokens (sk-ant-*, ghp_*, AIza*), telefones, WhatsApp group IDs, channel IDs Discord, emails, IPs Tailscale (100.*), IPs públicos (187.*)

## [0.3.0] — 2026-05-01 (Phase 3)

### Adicionado
- **GitHub Actions** (`.github/workflows/lint.yml`) — shellcheck nos scripts (warning level), ruff em Python, markdownlint advisory, link-check pra validar referências internas dos recipes
- **3 issue templates** (`.github/ISSUE_TEMPLATE/`):
  - `bug-report.md` — bug no toolkit
  - `new-symptom.md` — usuário descobriu novo problema OpenClaw
  - `recipe-suggestion.md` — usuário tem fix pronto pra contribuir
- **3 runbooks completos** em `runbooks/`:
  - `upgrade-from-v24-to-v29.md` — passo-a-passo controlado de upgrade entre versões intermediárias até v.29
  - `recovery-from-fratricide-loop.md` — recovery emergencial de crash loop por monkey-patch perdido
  - `recovery-from-cost-explosion.md` — recovery de cobrança inesperada Anthropic + canary preventivo

### Sustentabilidade
- Sync script no upstream privado (`openclaw-vps/infra/scripts/sync-to-toolkit.sh`) — sanitiza lessons + abre PR pro toolkit pra revisão manual

## [0.2.0] — 2026-05-01 (Phase 2)

### Adicionado
- **`CLAUDE-INSTRUCTIONS.md`** na raiz — mega-prompt operacional pra Claude do usuário operar autonomamente
- **README atualizado** com onboarding em 1 mensagem ("Cole isso no Claude Code")
- **Modo híbrido por severidade** — 1 autorização batch pra ALTA, 1 pergunta por MÉDIA, opt-in pra BAIXA
- **12 recipes individuais** em `recipes/<LETRA>-*.md` — referência detalhada por sintoma
- **11 scripts modulares idempotentes** em `scripts/recipes/`:
  - `reapply-monkey-patch.sh` (Recipe D)
  - `kill-switch-cost.sh` (Recipe B)
  - `disable-telegram-mcp.sh` (Recipe G)
  - `chattr-credentials.sh` (Recipe E)
  - `relayplane-disable.sh` (Recipe F)
  - `clean-fallback-chain.sh` (Recipe C)
  - `dmscope-fix.sh` (Recipe H)
  - `reset-sessions.sh` (Recipe L)
  - `delivery-queue-cleanup.sh` (Recipe I)
  - `reapply-emoji-patch.py` (Recipe J)
  - `cleanup-plugin-runtime-deps.sh` (Recipe K)
- Cada script: backup interno, idempotência, validação pós-aplicação, rollback documentado

## [0.1.0] — 2026-05-01 (Phase 1 MVP)

### Adicionado
- README inicial com quick-start e mapa de sintomas
- LICENSE MIT
- `.gitignore` sensible defaults
- `docs/recovery-guide.md` (636 linhas) — guide completo: meta-prompt, Phase 0 diagnostic, 12 fix recipes, Phase 5 validation, decision tree, 10 lessons
- `scripts/diagnostic.sh` — Phase 0 standalone (read-only, ~3min, 14 seções de estado)
- `scripts/validate.sh` — 10-invariant health check (exit code = nº de fails)

### Sanitização
- Zero secrets, tokens, números de telefone, IDs privados
- PT-BR usando "você" form

---

## Compatibilidade

| Versão do toolkit | Versões OpenClaw cobertas | Notas |
|-------------------|---------------------------|-------|
| 0.2.0 | v2026.4.24 — v2026.4.29 | Foco principal: v.29 |
| 0.1.0 | v2026.4.24 — v2026.4.29 | MVP inicial |

## Roadmap

### Phase 3 (em breve)
- Sync script no upstream (`infra/scripts/sync-to-toolkit.sh`)
- GitHub Actions: shellcheck nos scripts + markdownlint
- Issue templates (bug report, new symptom)
- `runbooks/` populados (upgrade-from-v24-to-v29.md, recovery-from-fratricide-loop.md, recovery-from-cost-explosion.md)
- `lessons/` migradas de incidents reais (sanitizadas)
- `docs/concepts.md` + `docs/faq.md`

### Futuro (quando OpenClaw shipar v2026.4.30+)
- Avaliar quais Recipes ficam obsoletas (problema corrigido upstream)
- Adicionar Recipes pra novos sintomas que aparecerem
- Bumpar major se mudanças quebrarem compatibilidade backward

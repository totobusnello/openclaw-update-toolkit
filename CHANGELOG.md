# Changelog

Todas as mudanças notáveis deste toolkit serão documentadas aqui.

Formato baseado em [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versionamento independente do OpenClaw — kit segue semver próprio.

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

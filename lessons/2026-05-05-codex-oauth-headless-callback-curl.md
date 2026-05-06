---
chunk_type: lesson
source: internal
date: 2026-05-05
severity: low
downtime_minutes: 0
tags: [openclaw, codex, oauth, headless, vps, models-auth, curl-trick]
related_lessons: [2026-05-05-openclaw-v5.4-upgrade-completed]
---

# Codex OAuth em VPS Headless — Entregar Callback via `curl localhost`

## TL;DR

`openclaw models auth login --provider openai-codex` em VPS headless: comando spawna listener HTTP em `127.0.0.1:1455/auth/callback` esperando o browser entregar o `code` do OAuth. Browser está no Mac do operador, não na VPS — então o redirect natural não chega no listener. Solução: copiar a URL de callback do browser do Mac e fazer `curl <url>` direto na VPS — o listener aceita e completa o token exchange.

## Contexto

OpenClaw Codex usa OAuth via ChatGPT Business (refresh tokens automáticos). Re-auth ocasional precisa fluxo interativo:

```bash
ssh root@<vps>
openclaw models auth login --provider openai-codex
```

Comando imprime URL `https://auth.openai.com/...?redirect_uri=http://localhost:1455/auth/callback&...` e abre listener local em `127.0.0.1:1455`.

**Problema:** o `localhost` no `redirect_uri` é resolvido pelo browser — que está no Mac, não na VPS. Browser tenta entregar callback em `Mac:1455`, não em `VPS:1455`. Listener da VPS nunca recebe. Comando trava no "manual redirect paste prompt" da v5.4 (release notes: "stop OAuth progress spinner before showing the manual redirect paste prompt").

## Solução — três caminhos

### Caminho 1 (cleanest, descoberto nesta sessão): curl direto na VPS

1. SSH na VPS, rodar `openclaw models auth login --provider openai-codex`
2. Copiar URL de auth do output, abrir no browser do Mac
3. Fazer login no ChatGPT
4. Browser tenta redirecionar pra `http://localhost:1455/auth/callback?code=ac_...&state=...&scope=...` — falha (porque é localhost do Mac)
5. **Copiar essa URL de callback completa da barra do browser**
6. Em outro shell SSH na VPS:
   ```bash
   curl -sS 'http://localhost:1455/auth/callback?code=ac_...&scope=...&state=...'
   ```
7. Listener responde HTML "Authentication successful", processo openclaw-models completa o token exchange, aborta o paste prompt automaticamente

**Verificação:**
```bash
openclaw models auth list --provider openai-codex
# Profiles:
# - openai-codex:default ([REDACTED-EMAIL]) [openai-codex/oauth; expires <2 weeks>]
```

### Caminho 2: SSH port forwarding (mais setup, sem curl manual)

```bash
ssh -L 1455:localhost:1455 root@<vps>
# Em outro terminal local na VPS via SSH:
openclaw models auth login --provider openai-codex
# Browser abre normalmente, callback chega via tunnel
```

Mais "natural" mas exige forwarding ativo durante todo o fluxo. Útil se for fazer múltiplos auths.

### Caminho 3: paste no prompt (oficial, mais lento)

Per v5.4 release: "manual redirect paste prompt". Comando aguarda paste manual da URL de callback no terminal SSH. Funciona, mas exige duas janelas + paste cuidadoso.

## Por que o curl funciona

`openclaw-models` spawna server HTTP genérico em `0.0.0.0:1455` (na verdade `127.0.0.1:1455` — verificável via `ss -tlnp | grep 1455`). Não há autenticação de origem — qualquer request em `/auth/callback` com `code` válido entrega ao OAuth handler. State/code validados pelo OpenAI, não pelo listener.

Curl bypass elegante porque:
- Não precisa expor porta 1455 publicamente
- Não precisa SSH tunnel (comando único)
- Funciona com qualquer combinação de `--method`, agentes ou config

## Comandos resumidos

```bash
# 1. Iniciar (terminal A)
ssh root@<vps>
openclaw models auth login --provider openai-codex

# 2. Browser no Mac → fazer login → copiar callback URL

# 3. Entregar (terminal B na VPS)
curl -sS 'http://localhost:1455/auth/callback?code=...&scope=...&state=...' >/dev/null

# 4. Verificar
openclaw models auth list --provider openai-codex --json
```

## Aplicável também a

- Qualquer provider OpenClaw que use OAuth com listener local em VPS headless
- Pattern geral pra OAuth flows que esperam callback HTTP no host onde o comando rodou
- Outros sistemas com a mesma arquitetura: `gh auth login`, `gcloud auth login`, etc — embora esses já tenham `--no-browser` flags próprias

## Caveats

- **Code é one-shot e expira em segundos** — copiar e curl rápido (< 1 min entre login e curl)
- **State validation** — o `state=` precisa ser exato, não inventar
- **Não compartilhar a URL** — o `code` é credencial até ser trocado por token (~10s)
- **HTTP only** (`http://localhost:1455`) — não tentar `https://`

## Referências

- v2026.5.4 release notes: "Providers/OpenAI Codex: stop the OAuth progress spinner before showing the manual redirect paste prompt"
- `openclaw models auth login --help`
- Listener confirmado via `ss -tlnp | grep 1455` durante o flow

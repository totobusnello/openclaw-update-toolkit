# Lesson: `reply session initialization conflicted` é (quase sempre) benigno — e como contribuir upstream sem errar

**Data:** 2026-07-09
**Severidade:** Baixa (o bug é benigno) — mas **alto valor de método** (evita PR duplicado + comentário errado em repo público)
**Versão:** OpenClaw 2026.6.11

---

## Parte 1 — O erro `reply session initialization conflicted`

Se o log do gateway está cheio de:

```
[diagnostic] message dispatch completed: ... source=replyResolver outcome=error
  error="Error: reply session initialization conflicted for agent:<a>:<channel>:<id>"
```

...na maioria dos casos **é benigno**. A inicialização da reply-session usa um commit otimista (compare-and-swap na revisão do session-store). Quando dois eventos disputam a init da mesma `sessionKey` — tipicamente um trigger (mensagem do usuário, heartbeat, cron) chegando **enquanto um turn anterior ainda roda** —, o perdedor do CAS lança esse erro e o inbound é descartado.

### Dois modos distintos sob a MESMA mensagem de erro

A confusão perigosa: **dois bugs diferentes produzem exatamente esse texto.** Distinga antes de agir:

| | **Wedge permanente** | **Transient drop** (o comum) |
|---|---|---|
| Padrão | a **mesma** messageId re-bate o conflito pra sempre | messageIds **distintos**, cada um perde 1× e é descartado |
| Sessão | **travada** — todo turn seguinte falha, só `/reset` cura | **saudável** — crons/digests seguem rodando na mesma key |
| Sobrevive a restart? | sim (é keyed na sessionKey persistida) | não se aplica (não trava) |
| Impacto | real (sessão inutilizável, tool-results voltam vazios) | benigno (perde só heartbeat/cron, não mensagens do usuário) |

**Como diagnosticar rápido:** os messageIds nas linhas de erro são iguais (wedge) ou distintos e crescentes (transient)? Os digests/crons daquele agente continuam entregando (transient) ou pararam de vez (wedge)?

### O que NÃO investigar (becos sem saída que parecem promissores)

- **"Um webhook está despejando eventos"** — cheque os hits reais do webhook; no nosso caso `/hooks/github` teve **0 hits/24h**.
- **"Algo está postando no canal"** — o canal Discord estava **vazio**; os IDs eram de turns internos (cron/heartbeat), não mensagens visíveis.
- **"Os crons do agente estão colidindo"** — se os crons têm horários espaçados, não há contenção de cron pra desfazer; a sobreposição vem de trigger interativo + heartbeat caindo dentro da janela de um turn longo. **Nem sempre há uma alavanca de config pra puxar.**

### Mitigação local

O fix determinístico é upstream (dar aos paths de inbound o mesmo retry/spool que alguns canais já têm, ou serializar a init por sessionKey). Enquanto isso, se um canário de "heartbeat do canal" ficar em false-FAIL por causa desse ruído benigno, **silencie o canário** (reversível) em vez de mascarar o log — o bug em si não exige ação.

## Parte 2 — Como contribuir upstream sem errar

Esse erro tem **dezenas de issues relacionadas** no repo. Antes de "descobrir um bug novo e abrir um PR", siga este checklist — ele evitou, nesta sessão, um PR duplicado e um comentário público errado.

### 1. Busque issues/PRs existentes ANTES de escrever qualquer coisa
A assinatura do erro já tinha ~65 issues, incluindo uma aberta **no mesmo dia, na mesma versão, por outro usuário**, com o label **`no-new-fix-pr`** (o próprio projeto pedindo pra não abrir PR de fix) e `needs-product-decision`. Abrir PR ali seria ruído.

### 2. Não deixe um fix fechar o bug errado
Havia um PR de "self-heal" (para o **wedge permanente**) sendo tratado pelo bot de triagem como o fix primário do **transient drop** — dois bugs distintos sob a mesma mensagem. Se você tem evidência de que são separados, **diga isso**, senão o transient é fechado por engano quando o self-heal landar.

### 3. Valide seu raciocínio com modelos adversariais — mas verifique todo claim de código no código
Rodamos o raciocínio por dois modelos independentes em modo "challenge". Foi ótimo pra tese — **mas um deles produziu um "achado de código" plausível e FALSO** (afirmou que um retry reusava um snapshot velho; ao ler o fonte, o snapshot era re-lido). Regra dura: **qualquer alegação com número de linha / mecanismo vai ao código real antes de ir a público.** Um `git clone` + `git show` de 30s te salva de ser corrigido pela equipe do projeto — e pegou também um número mal-atribuído que **eu mesmo** ia postar.

### 4. Quando o fix já está em movimento, contribua EVIDÊNCIA, não um PR concorrente
O que faltava na issue era uma repro de produção ao vivo (o revisor automatizado admitiu não ter rodado uma). Postamos exatamente isso — a distinção transient-vs-wedge + logs redigidos num bloco `<details>` colapsável (corpo curto engaja, prova a um clique). Isso destrava a decisão de produto sem duplicar código.

## TL;DR

- `reply session initialization conflicted` com **messageIds distintos + sessão viva** = transient drop **benigno**; com **mesma messageId + sessão travada** = wedge (real, precisa fix/`/reset`).
- Antes de abrir PR: **busque issues existentes** (procure o label `no-new-fix-pr`), **não deixe um fix fechar o bug errado**, **verifique claims de código no fonte**, e **contribua evidência de campo** quando o fix já está em andamento.

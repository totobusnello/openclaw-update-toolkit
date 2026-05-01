---
name: 🍳 Recipe nova
about: Tenho uma recipe pronta pra contribuir (já tem fix testado)
title: "[RECIPE] "
labels: recipe, enhancement
---

## Letra sugerida
<!-- ex: M, N, O... A-L já estão usados. Sugerir letra/nome -->

## Título curto
<!-- ex: "Limpar cache stale do graph-memory" -->

## SEVERIDADE
- [ ] 🔴 ALTA
- [ ] 🟡 MÉDIA
- [ ] 🟢 BAIXA / COSMÉTICA

## SYMPTOM
<!-- O que o usuário vê? Como detectar via diagnostic.sh? -->

## CAUSA RAIZ
<!-- Explicação técnica -->

## FIX (comando exato ou referência a script)

```bash
<comandos>
```

## VALIDATION
<!-- Como confirmar que funcionou -->

```bash
<comandos>
```

## REVERT
<!-- Como desfazer -->

```bash
<comandos>
```

## INVARIANTE pós-upgrade?
- [ ] Sim — precisa reaplicar após `npm install -g openclaw` (explicar abaixo)
- [ ] Não — fix persiste

## Validei em produção?
- [ ] Sim, está funcionando há X dias/semanas em meu setup
- [ ] Sim, mas foi caso isolado (1 vez)
- [ ] Não, é hipótese baseada em código upstream

## Posso enviar PR?
- [ ] Sim, vou enviar PR com `recipes/<LETRA>-<nome>.md` + `scripts/recipes/<nome>.sh`
- [ ] Quero contribuir mas preciso de ajuda com o formato
- [ ] Só reportando — alguém pode escrever

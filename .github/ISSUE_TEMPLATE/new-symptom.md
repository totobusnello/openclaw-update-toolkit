---
name: 🔍 Novo sintoma descoberto
about: Identifiquei um problema OpenClaw não coberto pelas Recipes A-L
title: "[SYMPTOM] "
labels: new-symptom, enhancement
---

## Sintoma observável
<!-- O que o usuário vê? Mensagem de erro, comportamento estranho, etc -->

## Versão OpenClaw afetada
<!-- ex: v2026.4.27 e v2026.4.29 (testei nas duas) -->

## Trigger conhecido
<!-- Quando aparece? Após upgrade? Cron específico? Mensagem de canal X? -->

## Causa raiz (se já investigou)
<!-- Sua análise técnica do POR QUÊ -->

## Como reproduzir
<!-- Passo-a-passo pra alguém replicar -->

```
1. ...
2. ...
3. ...
```

## Workaround atual
<!-- O que você fez pra contornar? Ainda funciona? -->

```bash
<comandos>
```

## Por que merece Recipe nova
<!-- Por que isso não cabe em Recipe existente? -->

## Severidade sugerida
- [ ] 🔴 ALTA — custo ativo, instabilidade, segurança
- [ ] 🟡 MÉDIA — impacto funcional mas não bloqueante
- [ ] 🟢 BAIXA — cosmético/housekeeping

## Output do diagnostic.sh nesse estado
<!-- Como o diagnostic.sh atual descreve o estado da instalação afetada? -->

```
<output relevante sanitizado>
```

## Tem fix automatizável?
- [ ] Sim, posso escrever script idempotente
- [ ] Sim, mas precisa intervenção manual em alguma parte
- [ ] Não, requer julgamento caso-a-caso

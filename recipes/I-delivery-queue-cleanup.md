# Recipe I — Delivery-queue cleanup (Unknown Channel spam)

**SEVERIDADE:** 🟡 MÉDIA

**SYMPTOM:**
- Logs com 15+ "Unknown Channel" + "recovery time budget exceeded" a cada restart
- Mensagens órfãs poluindo `delivery-queue/`

**CAUSA RAIZ:**
Canais Discord/Telegram removidos do servidor deixam mensagens em `/root/.openclaw/delivery-queue/*.json`. Gateway tenta reentregar a cada restart, gerando warnings em loop.

**FIX:**
```bash
curl -fsSL https://raw.githubusercontent.com/totobusnello/openclaw-update-toolkit/main/scripts/recipes/delivery-queue-cleanup.sh | sudo bash
```

**VALIDATION:**
```bash
ls /root/.openclaw/delivery-queue/*.json 2>/dev/null | wc -l
# Esperado: queda significativa (depende do estado anterior)
```

**REVERT:** desnecessário — entries deletadas são todas órfãs (canais não existem mais).

Ver detalhes em [`docs/recovery-guide.md`](../docs/recovery-guide.md#recipe-i--delivery-queue-cleanup-unknown-channel-spam).

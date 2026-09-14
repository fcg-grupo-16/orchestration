# ADR 0003 — Azure Functions em container com KEDA, e não o plano Consumption

- **Status:** aceito
- **Data:** 2026-09-13
- **Issues:** [#29](https://github.com/fcg-grupo-16/orchestration/issues/29),
  [notifications-function#5](https://github.com/fcg-grupo-16/notifications-function/issues/5)

## Contexto

O `notifications-api` ficava **24/7 no ar** aguardando eventos esporádicos — o oposto do que a Fase 3
pede ao exigir uma função serverless com otimização de recursos.

A restrição que decide esta ADR: a plataforma publica os eventos em **RabbitMQ** (MassTransit), e o
binding **`RabbitMQTrigger`** do Azure Functions **não é suportado nos planos Consumption e Flex
Consumption** — só em Elastic Premium e Dedicated, que são de **instância reservada** e, portanto,
**sem escala a zero real**.

Ou seja: "usar o plano serverless da Azure" e "manter o RabbitMQ como backbone" são mutuamente
exclusivos. Uma das duas coisas teria de mudar.

## Decisão

Manter a **Azure Function de verdade** (mesmo runtime isolated worker, mesmo binding, mesmo
`host.json`), empacotá-la em container e rodá-la no Kubernetes com **KEDA 2.20.2** fazendo o
scale-to-zero.

- `ScaledObject` com **dois triggers** (uma fila cada — o KEDA escala pelo maior),
  `minReplicaCount: 0`, `maxReplicaCount: 5`, `pollingInterval: 15s`, `cooldownPeriod: 60s`.
- Em repouso o Deployment fica em **zero réplica**; o KEDA cria o pod quando entra mensagem e o
  devolve a zero quando a fila esvazia.
- Medido no cluster: pod nasce **6s a 11s** depois do evento, `Executed 'Functions.UserCreatedFunction'
  (Succeeded)`, fila drenada, e volta a zero **63s a 75s** depois do disparo. Os números variam de
  propósito — são observação, não especificação.

## Consequências

- O scale-to-zero é **real**, e é o próprio requisito de otimização de recursos.
- A imagem exige **`--platform linux/amd64`**: a base `azure-functions/dotnet-isolated` publica só
  amd64 (conferido em todas as tags). Ela roda no nó arm64 via `binfmt`/`qemu-x86_64` do minikube, ao
  custo de partida mais lenta.
- O host de Functions reporta `azure.functions.webjobs.storage: Unhealthy` para sempre, com
  `AzureWebJobsStorage` vazio, e **não é falha** — nenhum trigger depende de Storage.
- O HPA criado pelo KEDA aparece com `minReplicas: 1`, e está **correto**: o HPA não escala a zero; a
  transição 0↔1 é do operador, por fora dele.
- A condição `Ready=True` do `ScaledObject` é **necessária e não suficiente**: um `queueName`
  inexistente também reporta `Ready=True` até o primeiro poll (~18s). Só o ciclo 0→1→0 do
  `scripts/keda-test.sh` prova o scaler.
- **A Function não está no `docker-compose.yml`** (scale-to-zero exige KEDA): no caminho do compose
  ninguém consome as duas filas, e as mensagens acumulam. O fluxo de notificação só é observável no
  cluster.
- O endpoint HTTP `NotificationHistoryFunction` ficou **inalcançável** na plataforma: expor exigiria
  Service + pod quente, o que anularia o scale-to-zero. Consciente, e registrado como trabalho
  separado.

## Alternativas descartadas

- **Plano Consumption / Flex Consumption da Azure** — não suporta `RabbitMQTrigger`. Seria preciso
  trocar o backbone de mensageria da plataforma inteira.
- **Elastic Premium / Dedicated** — suportam o trigger, mas são instância reservada: **sem escala a
  zero**, que é exatamente o requisito.
- **AWS Lambda + SQS** — exigiria migrar a mensageria e alterar dois outros serviços.
- **AWS Lambda + Amazon MQ** — exige conta AWS e não roda offline, inviabilizando a demonstração
  local.

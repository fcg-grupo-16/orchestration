# RabbitMQ da plataforma FCG — imagem custom

Imagem do broker com duas customizações sobre a oficial `rabbitmq:3.13.7-management`:

| Arquivo | O que faz |
|---|---|
| `Dockerfile` | instala o plugin `rabbitmq_delayed_message_exchange` (exigido pelo *delayed redelivery* do MassTransit) |
| `rabbitmq.conf` | teto absoluto de memória (flow control antes do OOM do container) |
| **`definitions.json`** | **topologia declarativa** das filas de notificação (Fase 3) |
| **`load-definitions.conf`** | aponta o broker para o `definitions.json` |

```bash
docker build -t fcg-rabbitmq:local docker/rabbitmq
```

---

## Topologia declarativa (Fase 3)

### Por que existe

Até a Fase 2, quem criava exchanges, filas e bindings de notificação era o próprio
`notifications-api`, via MassTransit, no startup.

Na Fase 3 esse serviço foi substituído pela
[`notifications-function`](https://github.com/fcg-grupo-16/notifications-function), cujo binding
`RabbitMQTrigger` da Azure Functions **apenas consome** de uma fila existente — ele não declara
fila, exchange nem binding. A documentação da Microsoft é explícita a respeito:

> *"Dead letter queues and exchanges can't be controlled or configured from the RabbitMQ trigger.
> To use dead letter queues, pre-configure the queue used by the trigger in RabbitMQ."*

Sem esta topologia versionada, o resultado não seria um erro visível: a fila simplesmente não
existiria, o `UserCreatedEvent` publicado pelo `users-api` cairia num exchange **sem nenhum
binding**, e a mensagem seria **descartada em silêncio**.

### Topologia

```
users-api ──publish──► Fcg.Contracts.Events:UserCreatedEvent ─┐
                              (fanout, durable)               │
                                                              ▼
                                          notifications-user-created  (exchange de endpoint)
                                                              │
                                                              ▼
                                          notifications-user-created  (fila)  ◄── notifications-function
                                                              │
                                       policy notifications-dlx │ (dead-letter-exchange)
                                                              ▼
                                                    notifications-dlx (exchange)
                                                              │
                                                              ▼
                                                    notifications-dlq (fila)
```

Idem para `Fcg.Contracts.Events:PaymentProcessedEvent` → `notifications-payment-processed`.

### Três decisões que parecem detalhe e não são

**1. O arquivo espelha EXATAMENTE o que o MassTransit declara.**
Foi capturado do broker com `rabbitmqadmin export`, não escrito de memória. Isso inclui o exchange
**intermediário** por endpoint (`type-exchange → endpoint-exchange → queue`), que à primeira vista
parece redundante — um binding direto do exchange de tipo para a fila funcionaria igual.

Não simplifique. As propriedades de um exchange/fila participam da checagem de equivalência do
`declare` do AMQP: enquanto o `notifications-api` ainda existir, qualquer divergência faz o broker
recusar o declare dele com `PRECONDITION_FAILED` e o serviço para de subir.

**2. Dead-letter por POLICY, não por `x-dead-letter-exchange` nos `arguments` da fila.**

Esta foi a decisão menos óbvia, e vale a explicação completa porque o desenho original da issue #28
estava errado.

Os `arguments` de uma fila **participam** da checagem de equivalência do `queue.declare`. O
MassTransit declara estas filas **sem argumento nenhum**. Se o `definitions.json` as declarasse com
`x-dead-letter-exchange`, o `notifications-api` passaria a morrer no startup durante toda a janela
de transição — entre esta mudança e a remoção do serviço (issue #29). Verificado na prática:

```
PRECONDITION_FAILED - inequivalent arg 'x-dead-letter-exchange' for queue
'notifications-user-created' in vhost '/': received none but current is the value
'notifications-dlx' of type 'longstr'
```

**Policies** são aplicadas pelo servidor **por fora** do declare: entregam o mesmo dead-lettering
sem participar da equivalência. Com a policy, `arguments` continua `[]` e o `notifications-api`
sobe normalmente:

```bash
$ docker compose exec rabbitmq rabbitmqctl list_queues name arguments policy
notifications-user-created        []   notifications-dlx
notifications-payment-processed   []   notifications-dlx
notifications-dlq                 []
```

O padrão da policy (`^notifications-(user-created|payment-processed)$`) é **ancorado** e
deliberadamente **não casa** com `notifications-dlq` — se casasse, a própria DLQ dead-letteraria
para si mesma, criando um loop.

**3. O usuário `guest` PRECISA estar declarado no `definitions.json`.**

Quando `load_definitions` está configurado, o broker registra no boot:

```
Will not seed default virtual host and user: have definitions to load...
```

…e **não cria mais o usuário `guest` padrão**. Com uma lista `users` vazia, o broker sobe com **zero
usuários** e todos os serviços da plataforma passam a falhar a autenticação. Pelo mesmo motivo o
vhost `/` e as `permissions` também precisam estar no arquivo.

O importador aceita `"password"` em texto plano (ele faz o hash), o que é bem mais legível que
versionar um `password_hash` salgado. A credencial é a mesma de demonstração que já está em claro no
`docker-compose.yml` — **nunca versione credencial real aqui**.

---

## Alterando a topologia

`load_definitions` roda **no boot** do broker e é idempotente. Depois de editar o `definitions.json`:

```bash
# compose
docker compose build rabbitmq && docker compose up -d --force-recreate rabbitmq

# kubernetes
docker build -t fcg-rabbitmq:local docker/rabbitmq
minikube image load fcg-rabbitmq:local
kubectl -n fcg rollout restart deploy/rabbitmq
```

> O RabbitMQ do k8s não tem volume persistente, então a topologia é recriada do zero a cada
> restart — o que aqui é bom: o broker é sempre igual ao que está no git.

### Como verificar

```bash
# A topologia nasce com o broker, SEM nenhum serviço .NET rodando?
docker compose down -v && docker compose up -d rabbitmq
docker compose exec rabbitmq rabbitmqctl list_queues name durable arguments policy
docker compose exec rabbitmq rabbitmqctl list_exchanges name type durable
docker compose exec rabbitmq rabbitmqctl list_bindings source_name destination_name destination_kind
docker compose exec rabbitmq rabbitmqctl list_users          # guest DEVE existir

# O publisher continua funcionando (sem PRECONDITION_FAILED)?
docker compose up -d mongodb users-api
docker compose logs users-api | grep -i precondition || echo "sem conflito de topologia"

# TESTE DECISIVO: a mensagem acumula na fila SEM consumidor?
# (é exatamente o cenário da Function escalada a zero pelo KEDA)
curl -s -X POST http://localhost:8081/api/v1/usuarios -H 'Content-Type: application/json' \
  -d '{"nome":"Topologia","email":"topologia@fcg.com","senha":"Teste@123456"}'
docker compose exec rabbitmq rabbitmqctl list_queues name messages consumers

# A DLQ recebe o que é rejeitado sem requeue?
docker compose exec rabbitmq rabbitmqadmin -u guest -p guest \
  get queue=notifications-user-created ackmode=reject_requeue_false
docker compose exec rabbitmq rabbitmqctl list_queues name messages | grep dlq
```

---

## O envelope que a Function recebe

O corpo da mensagem **não** é o evento cru: é o envelope do MassTransit
(`content_type: application/vnd.masstransit+json`). Capturado do broker:

```json
{
  "messageId": "01000000-b43e-86fd-bb6f-08df0e1c3f3e",
  "conversationId": "01000000-b43e-86fd-9d0f-08df0e1c3f3f",
  "sourceAddress": "rabbitmq://rabbitmq/<host>_FcgUsersApi_bus_<id>?temporary=true",
  "destinationAddress": "rabbitmq://rabbitmq/Fcg.Contracts.Events:UserCreatedEvent",
  "messageType": ["urn:message:Fcg.Contracts.Events:UserCreatedEvent"],
  "message": {
    "userId": "6aa0c8039056346385d903d0",
    "nome": "Topologia",
    "email": "topologia@fcg.com"
  },
  "sentTime": "2026-09-09T02:44:19.2848751Z",
  "headers": {},
  "host": { "processName": "Fcg.Users.Api", "massTransitVersion": "8.5.10.0", "...": "..." }
}
```

Dois pontos que importam para quem for implementar a Function
([`notifications-function#1`](https://github.com/fcg-grupo-16/notifications-function/issues/1)):

- **o corpo do evento vem em `camelCase`** (`userId`, `nome`, `email`), enquanto os records em C#
  são `PascalCase` — sem `PropertyNameCaseInsensitive = true` na desserialização, todas as
  propriedades vêm nulas e a função "funciona" enviando e-mail para destinatário vazio;
- **`headers` está vazio** — não há `Diagnostic-Id`/`traceparent` hoje. O MassTransit só propaga
  contexto de trace quando há uma `Activity` ativa, o que passa a existir depois da instrumentação
  OpenTelemetry (`users-api#19`). Relevante para
  [`notifications-function#6`](https://github.com/fcg-grupo-16/notifications-function/issues/6).

Para espiar o envelope sem consumir a mensagem:

```bash
docker compose exec rabbitmq rabbitmqadmin -u guest -p guest \
  get queue=notifications-user-created ackmode=reject_requeue_true
```

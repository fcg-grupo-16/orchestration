# FIAP Cloud Games (FCG) — Orquestração (Fase 3)

Repositório central de **orquestração** da plataforma FIAP Cloud Games, refatorada de um
monólito .NET para uma arquitetura de **microsserviços orientada a eventos**.

Aqui ficam o `docker-compose.yml` (sobe a plataforma completa localmente) e os manifestos
**Kubernetes** (`/k8s`) para o deploy em cluster. O código de cada microsserviço vive em
seu próprio repositório.

> **Grupo 16** — Org GitHub [`fcg-grupo-16`](https://github.com/fcg-grupo-16)

[![CI](https://github.com/fcg-grupo-16/orchestration/actions/workflows/ci.yml/badge.svg)](https://github.com/fcg-grupo-16/orchestration/actions/workflows/ci.yml)

## Arquitetura

```mermaid
flowchart TB
    Cliente(["Cliente"])

    subgraph KONG["namespace kong"]
      Gateway["Kong 3.9 — API Gateway<br/>api.fcg.local :80<br/>plugin jwt · rate-limiting por IP"]
    end

    Cliente --> Gateway

    subgraph FCG["namespace fcg"]
      Users["users-api · .NET 10<br/>/metrics · OTLP"]
      Catalog["catalog-api · .NET 10<br/>/metrics · OTLP"]
      Payments["payments-api · .NET 10<br/>/metrics · OTLP"]
      Func["notifications-function · .NET 8<br/>Azure Functions + KEDA<br/>escala 0..5"]

      Rabbit[("RabbitMQ 3.13.7<br/>+ delayed message exchange")]
      Mongo[("MongoDB 7 — rs0<br/>usersdb · catalogdb<br/>paymentsdb · notificationsdb")]
      Redis[("Redis 7.4<br/>cache + idempotência")]

      Prom["Prometheus 3.5"]
      Graf["Grafana 12.1"]
      Jaeger["Jaeger 1.62"]
    end

    Gateway -->|rotas públicas e protegidas| Users
    Gateway -->|rotas protegidas| Catalog

    Users --> Mongo
    Users --> Redis
    Catalog --> Mongo
    Catalog --> Redis
    Payments --> Mongo
    Func --> Mongo
    Func --> Redis

    Users -.->|UserCreatedEvent| Rabbit
    Catalog -.->|OrderPlacedEvent| Rabbit
    Rabbit -.->|OrderPlacedEvent| Payments
    Payments -.->|PaymentProcessedEvent| Rabbit
    Rabbit -.->|PaymentProcessedEvent| Catalog
    Rabbit -.->|trigger: 2 filas| Func

    Prom -->|scrape /metrics| Users
    Prom -->|scrape /metrics| Catalog
    Prom -->|scrape /metrics| Payments
    Graf --> Prom
    Graf --> Jaeger
    Users -.->|OTLP| Jaeger
    Catalog -.->|OTLP| Jaeger
    Payments -.->|OTLP| Jaeger
    Func -.->|OTLP| Jaeger
```

> **O diagrama é o estado real, não o desejado.** Os **quatro** serviços exportam traces por OTLP:
> a `notifications-function` passou a exportar também, e as duas cadeias — cadastro e compra —
> fecham num único trace cada. Ver a seção de observabilidade e o
> [ADR 0002](docs/adr/0002-observabilidade-opcao-a.md).
>
> A `notifications-function` **não** tem rota no gateway: é event-driven, acordada pelo KEDA quando
> entra mensagem na fila. O `payments-api` idem.

## Decisões de arquitetura (ADRs)

| ADR | Decisão |
|---|---|
| [0001](docs/adr/0001-api-gateway-kong.md) | Kong Ingress Controller como única porta de entrada |
| [0002](docs/adr/0002-observabilidade-opcao-a.md) | Observabilidade pela **Opção A** (Prometheus + Grafana), com Jaeger |
| [0003](docs/adr/0003-serverless-azure-functions-keda.md) | Azure Functions em container com KEDA, e não o plano Consumption |
| [0004](docs/adr/0004-nosql-avaliacoes.md) | Avaliações em MongoDB com o driver nativo |
| [0005](docs/adr/0005-cache-redis-invalidacao-por-geracao.md) | Cache em Redis com invalidação por geração de chave |
| [0006](docs/adr/0006-redis-dedicado-para-idempotencia.md) | Redis dedicado e durável para o store de idempotência |

## Microsserviços

| Serviço | Repositório | Responsabilidade | Eventos |
|---|---|---|---|
| **UsersAPI** | [`users-api`](https://github.com/fcg-grupo-16/users-api) | Cadastro, autenticação (JWT) e autorização | publica `UserCreatedEvent` |
| **CatalogAPI** | [`catalog-api`](https://github.com/fcg-grupo-16/catalog-api) | CRUD de jogos, biblioteca e início da compra | publica `OrderPlacedEvent`; consome `PaymentProcessedEvent` |
| **PaymentsAPI** | [`payments-api`](https://github.com/fcg-grupo-16/payments-api) | Processa (simula) o pagamento | consome `OrderPlacedEvent`; publica `PaymentProcessedEvent` |
| **NotificationsFunction** | [`notifications-function`](https://github.com/fcg-grupo-16/notifications-function) | "Envia" e-mails (log no console), **serverless com scale-to-zero** | consome `UserCreatedEvent` e `PaymentProcessedEvent` |
| ~~NotificationsAPI~~ | [`notifications-api`](https://github.com/fcg-grupo-16/notifications-api) | **DEPRECADO na Fase 3** — substituído pela Function acima (#29) | — |

**Stack:** .NET 10 nos três serviços ASP.NET · **.NET 8** na `notifications-function` (o worker
isolado do Azure Functions v4) · MongoDB 7 (database por serviço) · **Redis 7.4** (cache distribuído)
· RabbitMQ 3.13.7 + MassTransit · **Kong 3.9** (gateway) · **KEDA 2.20.2** (scale-to-zero) ·
**Prometheus 3.5 + Grafana 12.1 + Jaeger 1.62** (observabilidade) · Docker · Kubernetes.

> **RabbitMQ com plugin de mensagens atrasadas.** O broker roda uma imagem custom
> (`docker/rabbitmq/`: `rabbitmq:3.13.7-management` + `rabbitmq_delayed_message_exchange`),
> exigida pelo **delayed redelivery** (second-level retry) do MassTransit no
> [`catalog-api`](https://github.com/fcg-grupo-16/catalog-api) (issue `catalog-api#4`).
> O compose builda via `build:`; no k8s a imagem `fcg-rabbitmq:local` é construída e carregada
> no minikube pelo `scripts/deploy-minikube.sh`.

> **Topologia declarativa das filas de notificação (Fase 3).** A mesma imagem custom carrega
> [`docker/rabbitmq/definitions.json`](docker/rabbitmq/definitions.json) no boot (`load_definitions`),
> criando os exchanges, as filas `notifications-user-created` / `notifications-payment-processed`, a
> dead-letter queue `notifications-dlq` e o usuário `guest` — **sem depender de nenhum serviço .NET**.
> É pré-requisito da [`notifications-function`](https://github.com/fcg-grupo-16/notifications-function):
> o binding `RabbitMQTrigger` da Azure Functions só **consome** de uma fila existente, ele não declara
> nada. O raciocínio completo (por que o arquivo espelha exatamente o MassTransit, por que o
> dead-letter é por *policy* e não por argumento de fila, e por que o usuário `guest` precisa estar
> declarado) está em [`docker/rabbitmq/README.md`](docker/rabbitmq/README.md).
>
> ⚠️ Ao editar o `definitions.json`, **não** altere as propriedades dos exchanges
> (`fanout`/`durable`) nem acrescente `arguments` nas filas: elas participam da checagem de
> equivalência do `declare` do AMQP, e divergir quebra publishers e consumers com
> `PRECONDITION_FAILED`.

## Fluxos orientados a eventos

```mermaid
flowchart LR
    subgraph Cadastro
      U[users-api] -- UserCreatedEvent --> F1["notifications-function<br/>UserCreatedFunction<br/>(KEDA acorda do zero)"]
    end
    subgraph Compra
      C[catalog-api] -- OrderPlacedEvent --> P[payments-api]
      P -- PaymentProcessedEvent --> C2[catalog-api<br/>grava biblioteca se Approved]
      P -- PaymentProcessedEvent --> F2["notifications-function<br/>PaymentProcessedFunction<br/>(KEDA acorda do zero)"]
    end
```

**Fluxo de cadastro:** `users-api` cria o usuário e publica `UserCreatedEvent` → a
`notifications-function` é **acordada do zero pelo KEDA** e envia o e-mail de boas-vindas.

**Fluxo de compra:** `catalog-api` recebe a requisição de aquisição e publica `OrderPlacedEvent`
(UserId, GameId, Price) → `payments-api` processa e publica `PaymentProcessedEvent`
(Approved/Rejected) → `catalog-api` grava na biblioteca se aprovado, e a `notifications-function`
envia o e-mail de confirmação.

> ⚠️ **Os dois consumidores de notificação só existem no cluster.** A `notifications-function`
> depende do KEDA e **não está no `docker-compose.yml`**: no caminho do compose ninguém consome
> `notifications-user-created` nem `notifications-payment-processed`, e as mensagens **acumulam** nas
> filas — nada quebra, mas não há e-mail simulado para ver. Até a Fase 2 quem consumia era o
> `notifications-api`, hoje [deprecado](https://github.com/fcg-grupo-16/notifications-api).

## Estrutura de diretórios esperada

Clone os 5 repositórios como irmãos:

```
fiap/
├── orchestration/      (este repo)
├── users-api/
├── catalog-api/
├── payments-api/
└── notifications-function/
```

```bash
gh repo clone fcg-grupo-16/orchestration
gh repo clone fcg-grupo-16/users-api
gh repo clone fcg-grupo-16/catalog-api
gh repo clone fcg-grupo-16/payments-api
gh repo clone fcg-grupo-16/notifications-function
```

## Executar com Docker Compose

A partir deste repositório:

```bash
docker compose up --build
```

Sobe RabbitMQ, MongoDB, Redis, a stack de observabilidade e os **3 microsserviços** (a
`notifications-function` não está no compose — ver a ressalva no fim desta seção).

| Componente | Compose (host) | Kubernetes (port-forward) | Credencial |
|---|---|---|---|
| **Kong (gateway)** | — (só no cluster) | `kubectl -n kong port-forward svc/kong-kong-proxy 8000:80` | — |
| users-api | <http://localhost:8081> | `kubectl -n fcg port-forward svc/users-api 8081:80` | — |
| catalog-api | <http://localhost:8082> | `kubectl -n fcg port-forward svc/catalog-api 8082:80` | — |
| payments-api | <http://localhost:8083> (worker) | `kubectl -n fcg port-forward svc/payments-api 8083:80` | — |
| notifications-function | — (use `func start` no repo dela) | escala a zero — sem porta | — |
| **Grafana** | <http://localhost:3000> | `kubectl -n fcg port-forward svc/grafana 3000:3000` | admin / admin |
| **Prometheus** | <http://localhost:9090> | `kubectl -n fcg port-forward svc/prometheus 9090:9090` | — |
| **Jaeger** | <http://localhost:16686> | `kubectl -n fcg port-forward svc/jaeger 16686:16686` | — |
| RabbitMQ Management | <http://localhost:15672> | `kubectl -n fcg port-forward svc/rabbitmq 15672:15672` | guest / guest |
| MongoDB | `mongodb://localhost:27017/?replicaSet=rs0` | `kubectl -n fcg port-forward svc/mongodb 27017:27017` | — |
| Redis | `localhost:6379` | `kubectl -n fcg port-forward svc/redis 6379:6379` | — |

> As portas do host podem estar **remapeadas nesta máquina** pelo `docker-compose.override.yml`
> (gitignored). Confira com `docker compose ps`.

> ⚠️ **O compose NÃO tem o API Gateway, e o contrato observável difere do cluster.** No compose os
> serviços são acessados direto nas portas acima, sem gateway: `GET /api/v1/jogos` responde **200
> anônimo** e não há rate limit. No Kubernetes o mesmo endpoint exige **token** (401 sem ele) e tem
> limite por IP. É decisão deliberada (decisão 3 do épico #24 — manter um `kong.yml` paralelo
> duplicaria a configuração do gateway), mas significa que **um cliente escrito contra o compose
> pode quebrar no cluster**. Ao desenvolver contra o compose, trate o token como obrigatório.

> Swagger só é exposto em ambiente Development. Para ativá-lo no compose, troque
> `ASPNETCORE_ENVIRONMENT` para `Development` no serviço desejado.

> **MongoDB roda como replica set (`rs0`).** O container sobe com `mongod --replSet rs0` e o
> healthcheck do compose **auto-inicia** o replica set (`rs.initiate(...)`); por isso os serviços
> conectam com `MongoDbSettings__ConnectionString=mongodb://mongodb:27017/?replicaSet=rs0`. O replica
> set é **pré-requisito do outbox transacional da `users-api`** — transações multi-documento do
> MongoDB exigem replica set. Ao editar o `docker-compose.yml`, **não** remova o `--replSet rs0` nem
> o `?replicaSet=rs0` das connection strings, ou o cadastro de usuários passa a falhar.

### Testar os fluxos de ponta a ponta

```bash
./scripts/smoke-test.sh                 # 9 casos; requer docker (curl/jq rodam em container)
docker compose logs payments-api
```

O mesmo script serve os dois ambientes, e **não roda no mesmo lugar** nos dois — de propósito:

| Modo | Como roda | O que prova |
|---|---|---|
| `MODO=compose` (padrão) | as asserções rodam **dentro de um container** na rede do compose, usando os nomes de serviço (`http://users-api:8080`) | o **código**: cadastro, login, compra assíncrona, avaliações, cache, métricas |
| `MODO=gateway` | rodam **no host**, contra o port-forward do Kong | o **gateway**: 401 sem token na borda, roteamento e JWT, além de tudo acima |

> Rodar em container no modo compose evita depender das portas publicadas no host: elas são
> remapeadas por máquina no `docker-compose.override.yml` (gitignored), então bater em
> `localhost:8081` seria frágil — pela rede do compose, os nomes de serviço são estáveis. No modo
> gateway é o inverso: quem tem o port-forward aberto é o host.

O teste **grava dados reais** (conta, pedido, avaliação) e os remove no final. A limpeza é
verificada: `usuarios` e `avaliacoes` têm a mesma contagem antes e depois de uma execução.

Derrubar tudo:

```bash
docker compose down -v
```

## Deploy no Kubernetes (local)

Os manifestos estão em [`k8s/`](k8s/): `Namespace`, infra (`StatefulSet`+`Service` do
MongoDB, `Deployment`+`Service` do RabbitMQ) e, para cada microsserviço, `ConfigMap`
(config não sensível), `Secret` (connection strings, chave JWT, credenciais),
`Deployment` e `Service` (ClusterIP, porta 80 → 8080).

> **Persistência do MongoDB.** O Mongo roda como `StatefulSet` com `volumeClaimTemplates`,
> que provisiona um `PersistentVolumeClaim` (`mongo-data-mongodb-0`, `storageClassName: standard`
> — a StorageClass padrão do minikube). O volume **sobrevive** à recriação do Pod (rollout,
> `kubectl delete pod`, reagendamento), então `usersdb`/`catalogdb` não são perdidos. O Service
> `mongodb` (headless, porta 27017) mantém o mesmo DNS interno, então as APIs seguem conectando por
> `mongodb://mongodb:27017/?replicaSet=rs0` sem mudança de config. Confira o PVC com
> `kubectl -n fcg get pvc` (STATUS `Bound`).
>
> **Replica set `rs0` (paridade com o compose).** Assim como no `docker-compose.yml`, o Mongo no
> k8s roda como **single-node replica set** — o container sobe com `mongod --replSet rs0` e a
> `readinessProbe` inicia o RS de forma idempotente (mesmo `rs.initiate(...)` do healthcheck do
> compose), só marcando o Pod `Ready` após o RS estar de pé. As connection strings dos Secrets de
> `users-api` e `catalog-api` usam `?replicaSet=rs0`. Isso é **exigido pelo outbox transacional**
> (transações multi-documento do Mongo requerem replica set), então o fluxo de cadastro funciona no
> cluster igual ao compose. Confira com `kubectl -n fcg exec mongodb-0 -- mongosh --quiet --eval 'rs.status().ok'`.

### Forma rápida (script)

```bash
./scripts/deploy-minikube.sh      # sobe tudo: Kong, KEDA, infra, serviços e observabilidade
./scripts/verify-fase3.sh         # checklist da entrega — rode antes de gravar
```

Faz o build das imagens, carrega no minikube e aplica os manifestos, instalando também o Kong
(Helm, chart pinado) e o KEDA (URL pinada) antes do `apply`, porque os CRDs deles são pré-requisito
dos manifestos.

> **As imagens são marcadas pelo COMMIT do repositório de origem** (`users-api:5f78b28`), não por
> uma tag móvel `:local`. O motivo é concreto: com tag móvel, `minikube image load` vira **no-op
> silencioso** quando a tag já existe no nó e um container a referencia — o pod segue `Running`
> servindo o binário antigo e todo `kubectl get` diz que está tudo certo. Foi assim que três
> requisitos da Fase 3 ficaram invisíveis no cluster (issue #40). Com tag nova a cada commit não há
> colisão, e mudar de commit muda o `image:` do spec, disparando o rollout naturalmente.
>
> Os arquivos em `k8s/` continuam com `:local`: são YAML puro, validável offline pelo CI. A
> substituição acontece numa **cópia renderizada** na hora do deploy. Se você aplicar os manifestos
> à mão (`kubectl apply -R -f k8s/`), o cluster volta para `:local` — use o script.

### Forma manual

```bash
minikube start

# Build + carga das imagens no cluster
for s in users-api catalog-api payments-api; do
  docker build -t "$s:local" "../$s"
  minikube image load "$s:local"
done

# Deploy (recursivo por causa das subpastas/ordenação)
kubectl apply -R -f k8s/

# Verificar
kubectl -n fcg get pods
```

> ⚠️ **Este caminho manual tem uma armadilha, e é a razão de o script existir.** Se a tag
> `<servico>:local` **já existir** no nó com um container a referenciando, o `minikube image load`
> acima é um **no-op silencioso**: sai 0, não imprime nada, e o pod continua servindo o binário
> antigo. Nem `rollout restart` resolve — o spec não mudou, então não há o que rolar. Use
> `./scripts/deploy-minikube.sh`, que marca cada imagem pelo commit de origem e torna a colisão
> impossível. Para diagnosticar um cluster já nessa situação: `./scripts/verify-fase3.sh` compara o
> `imageID` do pod com o `Id` do host e acusa a divergência (issue #40).

Acessar os serviços:

```bash
kubectl -n fcg port-forward svc/users-api 8081:80
kubectl -n fcg port-forward svc/catalog-api 8082:80
kubectl -n fcg port-forward svc/rabbitmq 15672:15672   # Management UI
```

Comunicação interna no cluster usa os nomes de Service (ex.: `http://catalog-api:80`,
`rabbitmq:5672`, `mongodb:27017`).

### Acesso externo: API Gateway (Kong) — porta de entrada única

Todo o tráfego externo entra pelo **Kong Ingress Controller** em modo **DB-less**, com um host
único `api.fcg.local`. O gateway **valida o JWT na borda**: sem token válido a requisição recebe
401 e **não sai do namespace `kong`**. Os serviços continuam validando por conta própria — a borda
antecipa a rejeição, não substitui a autorização do serviço.

O Ingress NGINX anterior (dois hosts, sem validação de token) foi **removido**.

```
                        ┌──────────────────────────────────────────┐
   cliente ──────────►  │  Kong (namespace kong) — api.fcg.local   │
                        └──────┬───────────────────────────┬───────┘
                     PÚBLICAS │                           │ PROTEGIDAS (jwt + rate-limit)
                              ▼                           ▼
   /api/v1/auth/**       → users-api:80     GET/PUT/DELETE /api/v1/usuarios/** → users-api:80
   POST /api/v1/usuarios → users-api:80     /api/v1/jogos/**                   → catalog-api:80
                                            /api/v1/biblioteca/**              → catalog-api:80
                                            /api/v1/pedidos/**                 → catalog-api:80
                                            /api/v1/avaliacoes/**              → catalog-api:80
```

**Público sem token:** `login`, `refresh` e o **cadastro** (`POST /api/v1/usuarios`) — são como o
usuário *obtém* um token; exigir token aqui seria um deadlock. O cadastro tem rota própria
(`pathType: Exact` + `konghq.com/methods: POST`), então `GET /api/v1/usuarios` sem token dá 401.

⚠️ **O prefixo `/api/v1/auth/` NÃO é restrito por método**, ao contrário do cadastro: qualquer verbo e
qualquer subpath sob ele chegam ao `users-api` sem token (medido: `PUT /api/v1/auth/login` → 405 do
Kestrel, `GET /api/v1/auth/qualquercoisa` → 404 do Kestrel). A superfície ali é o `AuthController`
inteiro. É o desenho pretendido e não um bypass — rota pública tem de ser anônima —, mas a frase
"sem token a requisição não sai do namespace `kong`" vale **só para as 5 rotas protegidas**.

⚠️ **Cliente de browser cross-origin não funciona em rota nenhuma da plataforma.** Não há plugin
`cors` no gateway e o plugin `jwt` exige token também no preflight, então `OPTIONS` numa rota
protegida devolve 401 — e `OPTIONS /api/v1/usuarios` também, porque a rota de cadastro é POST-only e
o preflight acaba casando com o Ingress protegido. Antes o mesmo preflight chegava ao Kestrel e
voltava 405 sem header de CORS nenhum, ou seja, estava quebrado dos dois lados. Habilitar CORS de
forma correta é trabalho de uma issue própria.

**Fora do gateway de propósito:** `payments-api` e `notifications-function` são orientados a
eventos e não têm rota. `/health*` e `/metrics` também não — o Prometheus raspa os pods **dentro**
do cluster.

> ⚠️ **`GET /api/v1/jogos` é `[AllowAnonymous]` no `catalog-api`, mas a BORDA exige token.**
> Decisão consciente: evita rota ambígua por método no mesmo path (fonte clássica de bug de
> prioridade no Kong) e deixa a demonstração inequívoca — sem token 401, com token 200. Os
> `[AllowAnonymous]` continuam no código, então acesso interno (pod-a-pod, Prometheus, testes de
> integração) não muda.

#### Configuração versionada

| Arquivo | Papel |
| --- | --- |
| [`gateway/kong-values.yaml`](gateway/kong-values.yaml) | values do chart (DB-less, `ingressClass: kong`, proxy NodePort 30080, admin/manager/portal fechados) |
| [`k8s/gateway/40-kong-consumer.yaml`](k8s/gateway/40-kong-consumer.yaml) | `KongConsumer` + credencial JWT |
| [`k8s/gateway/41-kong-plugins.yaml`](k8s/gateway/41-kong-plugins.yaml) | plugins `jwt`, `rate-limiting` (120/min protegido e 20/min público — ver a limitação abaixo), `correlation-id` |
| [`k8s/gateway/42-kong-ingress.yaml`](k8s/gateway/42-kong-ingress.yaml) | as três rotas (pública, cadastro, protegida) |

> **Por que o `kong-values.yaml` não está em `k8s/gateway/`:** o `deploy-minikube.sh` roda
> `kubectl apply -R -f k8s/`, e um values de Helm não tem `apiVersion`/`kind` — o apply falharia
> **inteiro**. Artefato que não é manifesto vive fora de `k8s/`.

A instalação é por **Helm** (pré-requisito novo), com a versão do chart **pinada**; o
`deploy-minikube.sh` faz isso automaticamente, **antes** do `kubectl apply`, porque os CRDs
`KongPlugin`/`KongConsumer` são pré-requisito dos manifestos:

```bash
brew install helm                       # pré-requisito
./scripts/deploy-minikube.sh            # instala o Kong (chart 3.4.1) e aplica tudo
```

#### Acessar e testar

```bash
kubectl -n kong port-forward svc/kong-kong-proxy 8000:80
GW=http://localhost:8000; H='Host: api.fcg.local'
```

| Comando | Esperado |
| --- | --- |
| `curl -i -H "$H" $GW/api/v1/jogos` | **401** com `Server: kong/3.9.3` — é o **Kong**, não o serviço |
| `curl -i -H "$H" -H 'Authorization: Bearer lixo' $GW/api/v1/jogos` | **401** |
| `curl -H "$H" -H 'Content-Type: application/json' -d '{"email":"admin@fcg.com","senha":"Admin@123456"}' $GW/api/v1/auth/login` | **200** + token (campo `.token`) |
| `curl -i -H "$H" -H "Authorization: Bearer $TOKEN" $GW/api/v1/jogos` | **200** |
| `curl -i -H "$H" "$GW/api/v1/jogos?jwt=$TOKEN"` | **401** — token **não** é aceito pela querystring |
| `curl -i -H "$H" -H "Cookie: jwt=$TOKEN" $GW/api/v1/jogos` | **401** — nem por cookie |
| `curl -i -X OPTIONS -H "$H" $GW/api/v1/jogos` | **401** — o preflight também exige token (não há plugin `cors`) |
| `curl -i -H "$H" -H 'Content-Type: application/json' --data-binary @signup.json $GW/api/v1/usuarios` | **201** (cadastro público) |
| `curl -i -H "$H" $GW/api/v1/usuarios` | **401** (GET exige token) |
| `curl -i -H "$H" -H "Authorization: Bearer $TOKEN" $GW/health` | **404** — não exposto |
| 130 requisições em 1 min | aparece **429** após 120 — **não** prova isolamento (ver limitação) |
| `./scripts/gateway-test.sh` | a matriz inteira, incluindo o teste de **dois pods** do rate limit |
| `curl -si ... \| grep -i ratelimit` | `RateLimit-Limit: 120`, `RateLimit-Remaining`, `RateLimit-Reset` |

> **macOS + driver docker:** o `minikube ip` não é alcançável direto do host, por isso o
> `port-forward` acima é o caminho recomendado em vez de `/etc/hosts` + `minikube tunnel`.

> ⚠️ **A `IngressClass` default do cluster continua sendo a `nginx`**
> (`ingressclass.kubernetes.io/is-default-class: true`), com o controller do minikube instalado.
> Nada da plataforma passa por ele hoje — todos os nossos Ingress declaram
> `ingressClassName: kong` —, mas **um Ingress futuro que esqueça o `ingressClassName` entra pelo
> NGINX, sem validação de JWT**, furando a porta de entrada única. Ao adicionar rota nova, declare
> a classe explicitamente.

#### Correlation-id — o que ele faz e o que não faz

O plugin gera um `X-Correlation-Id` por requisição, propaga ao upstream e devolve ao cliente
(`echo_downstream`). O `CorrelationIdMiddleware` dos serviços lê o header e o coloca em
`HttpContext.TraceIdentifier`.

> ⚠️ **O id NÃO entra nos logs dos serviços.** Verificado no cluster: `kubectl logs deploy/users-api`
> tem zero ocorrências de correlation — o middleware não empurra o valor para o `LogContext` do
> Serilog. Para rastrear ponta a ponta hoje, use o **TraceId** (`@tr` no log estruturado, mesmo id
> no Jaeger). Enriquecer o log com o correlation-id é melhoria dos serviços, não do gateway.

#### Limitações conhecidas

- O Deployment do Kong vem do chart **sem `resources`** definidos por nós, ao contrário dos
  serviços do `fcg`, que têm requests/limits.
- Sem TLS no gateway (ambiente de demonstração).
- `rate-limiting` com `policy: local`: exato com 1 réplica do Kong; com N réplicas o limite
  efetivo seria N × 120. Contador global exigiria `policy: redis`.
- ⚠️ **O rate limit é, na prática, um bucket GLOBAL para todo cliente externo.** Não é o que o
  nome `limit_by: ip` sugere, e não foi corrigido — é limitação conhecida. Medido no cluster:
  via `kubectl port-forward` (o único caminho documentado) o access log do Kong registra
  `127.0.0.1` para **todas** as requisições; via NodePort 30080 o Service tem
  `externalTrafficPolicy: Cluster`, então o kube-proxy faz SNAT e todo cliente externo chega com o
  IP do nó. E o contador é compartilhado entre as 5 rotas protegidas (medido em sequência:
  `jogos`=116 → `biblioteca`=115 → `pedidos`=114 → `jogos`=113 → `avaliacoes`=112).
  **São 120/min para a plataforma inteira vista de fora**, e um cliente que esgote a cota faz os
  outros receberem 429. Passaria a isolar de verdade com um LoadBalancer real preservando o IP de
  origem (`externalTrafficPolicy: Local`) ou `trusted_ips`/`real_ip_header` configurados **no
  Kong** — nenhum dos dois existe aqui.
- Ainda assim `limit_by: ip` é preferível a `consumer`: com `consumer` o colapso é **garantido por
  construção**, porque todo JWT do `users-api` tem `iss: FiapCloudGames` e o plugin resolve o
  consumer por essa claim — todos casam com o único `KongConsumer`. Limite real por usuário exigiria
  um `KongConsumer` por usuário, o que não é declarável para usuários dinâmicos.
- ⚠️ **O `ForwardedHeaders__*` dos serviços não ajuda nisso.** Ele governa o `RemoteIpAddress` que
  `users-api`/`catalog-api` leem do `X-Forwarded-For` escrito pelo Kong — e esse valor é
  `127.0.0.1` para todos. Logo o rate limiter de login do próprio `users-api` também é global hoje.
- ⚠️ **Requisição não autenticada não consome cota nas rotas protegidas.** O plugin `jwt`
  (prioridade 1005) roda antes do `rate-limiting` (901) e encerra a requisição: medido, o 401 sai
  com **0** headers `RateLimit-*` e o 200 com 3. Um flood anônimo com token inválido nas rotas
  protegidas não é limitado na borda. Prioridade de plugin no Kong é fixa por tipo — não há inversão
  declarativa. O caminho anônimo é coberto pelo `fcg-rate-limit-publico` nas rotas públicas.
- A credencial JWT é um `Secret` com o valor **em claro** — de demonstração, como já ocorre no
  `docker-compose.yml`. Migrar para SealedSecret é follow-up.

Remover:

```bash
./scripts/undeploy-minikube.sh
```

> O script remove os manifestos, o gateway (release Helm, namespace `kong` e os CRDs
> `*.konghq.com`) **e o KEDA** (namespace `keda`, os três deployments, o webhook, o apiservice de
> external metrics e os CRDs `keda.sh`), nessa ordem — os CRDs têm de sair **depois** dos
> `KongPlugin`/`KongConsumer` e do `ScaledObject`, senão o delete falha com `no matches for kind`.
> Um `kubectl delete -R -f k8s/` avulso **não** desinstala nem o Kong nem o KEDA: deixaria os
> releases, os CRDs, os webhooks e a NodePort 30080 para trás.
>
> A remoção dos CRDs de ambos é **condicional e falha fechado**: se houver outro release do Kong, ou
> CRs de Kong/KEDA fora do namespace `fcg`, ou se a sonda não conseguir se pronunciar, os CRDs são
> **preservados** — apagá-los levaria em cascata os recursos de outros times.

> O `PersistentVolumeClaim` gerado pelo `volumeClaimTemplates` **não** é removido por
> `kubectl delete -R -f k8s/` — os dados ficam para trás de propósito. Para zerar de vez
> num ambiente de demo: `kubectl -n fcg delete pvc mongo-data-mongodb-0`.

## Serverless — `notifications-function` com scale-to-zero (KEDA)

O `notifications-api` ficava **24/7 no ar** aguardando eventos esporádicos. Na Fase 3 ele foi
**substituído** pela [`notifications-function`](https://github.com/fcg-grupo-16/notifications-function),
uma Azure Function que roda em container no cluster com **KEDA 2.20.2**: em repouso o Deployment
fica em **zero réplica** (custo computacional zero) e o KEDA o acorda quando entra mensagem na fila.

### Por que Functions + KEDA, e não o plano Consumption da Azure

A documentação do binding é explícita: o trigger de **RabbitMQ não é suportado** nos planos
Consumption/Flex Consumption — só em Elastic Premium e Dedicated, que são de **instância reservada** e
portanto **sem escala a zero real**. Rodar o mesmo host de Functions em container com o KEDA mantém a
Function de verdade (mesmo runtime, mesmo binding, mesmo `host.json`) e torna o scale-to-zero real.
É decisão de arquitetura, não atalho.

### Como demonstrar o ciclo 0 → 1 → 0

```bash
# 1) OCIOSO — o requisito de otimização de recursos
kubectl -n fcg get deploy notifications-function     # READY 0/0
kubectl -n fcg get pods -l app=notifications-function # No resources found

# 2) DISPARO — evento real pelo gateway (em outro terminal, observe com -w)
kubectl -n kong port-forward svc/kong-kong-proxy 8000:80 &
curl -s -X POST -H 'Host: api.fcg.local' -H 'Content-Type: application/json' \
  -d '{"nome":"Serverless","email":"demo@fcg.com","senha":"Teste@123456"}' \
  http://localhost:8000/api/v1/usuarios

# 3) A Function processou?
kubectl -n fcg logs -l app=notifications-function --tail=50

# 4) A fila zerou?
kubectl -n fcg exec deploy/rabbitmq -- rabbitmqctl list_queues name messages | grep notifications
```

Ou, de uma vez, a matriz de aceite (**12 asserções**):

```bash
./scripts/keda-test.sh
```

Ela existe pela mesma razão do `gateway-test.sh`: o `kubeconform` do CI **pula** os CRs do KEDA. E o
modo de falha engana de **duas** formas medidas, com resultados opostos:

| quebra | condição `Ready` medida | HPA? | pega pela asserção 1? |
|---|---|---|---|
| credencial → secret inexistente | **`False`** (`ScaledObjectCheckFailed`), estável em t+8s/25s/60s | não | **sim** |
| credencial boa + `queueName` inexistente | **`True`** em t+6s e t+12s, depois `False` (`TriggerError`) em t+18s | **sim** | só depois do 1º poll |

O engano é **temporal**, não de categoria: `Ready=True` aparece **antes do primeiro poll do trigger**,
então ler `Ready` cedo demais aprova um scaler que não alcança a fila. Credencial irresolvível — a
classe do primeiro defeito desta entrega — dá `Ready=False` e a asserção 1 **pega**. Nos dois casos o
Deployment fica em 0 réplica, indistinguível de scale-to-zero saudável, e a asserção decisiva é a de
**execução** (`Executed ... Succeeded`): a de `Ready` é necessária e não suficiente. O script limpa o
que cria nas três coleções que toca.

> **Correção registrada:** uma versão anterior desta tabela dizia o oposto — que a credencial quebrada
> deixava `Ready=True` sem erro no operador. Era falso, e a origem do erro foi eu transcrever a
> medição de uma revisão **sem reproduzi-la**. Os números acima são de medição própria, com
> `ScaledObject`s efêmeros em Deployments dedicados.

### O que foi medido

| | valor |
|---|---|
| Pod acordado após o evento | **6s** e **11s** em duas execuções (teto é o `pollingInterval: 15`, mais a partida emulada) |
| Processamento | `Executed 'Functions.UserCreatedFunction' (Succeeded, Duration=3080ms)` |
| Volta a zero réplica | **63s** e **71s** após o disparo (`cooldownPeriod: 60`) |
| Resíduo do teste no Mongo | zero nas **três** coleções que ele toca (`usersdb.usuarios`, `usersdb.refresh_tokens`, `notificationsdb.notifications`) |

Os tempos **variam** de execução para execução; não são especificação.

> **Correção registrada:** a primeira versão desta tabela afirmava "resíduo zero" medindo só
> `usersdb`. Era **falso**: a Function persiste **toda** notificação em `notificationsdb.notifications`,
> e nem o `keda-test.sh` nem o `gateway-test.sh` limpavam essa coleção — 14 documentos de teste
> haviam acumulado (12 do gateway, 2 do KEDA). Os dois scripts passaram a apagá-la.

### Ressalvas que valem conhecer

- **A imagem exige `--platform linux/amd64`.** A base `azure-functions/dotnet-isolated` publica só
  `linux/amd64` — conferido em `4-dotnet-isolated8.0`, `9.0`, `10.0`, `-appservice` e `-mariner`. Num
  host arm64 o build sem `--platform` falha com `no match for platform in manifest`. A imagem amd64
  **executa** no nó arm64 porque o minikube traz `binfmt` com handler `qemu-x86_64` (verificado: pod
  de teste imprimiu `x86_64`). O custo é partida mais lenta; os outros serviços são arm64 nativos.
  O `deploy-minikube.sh` já trata isso num laço `FUNCTIONS` separado.
- **O host do Functions reporta `Unhealthy` para sempre, e não é falha.** Com `AzureWebJobsStorage`
  vazio (nenhum trigger depende de Storage), `azure.functions.webjobs.storage` é a **única**
  sub-checagem não saudável — `web_host.lifecycle` e `script_host.lifecycle` ficam `Healthy` e a
  função executa normalmente.
- **O HPA criado pelo KEDA aparece com `minReplicas: 1`, e está correto.** O HPA do Kubernetes não
  escala a zero: a transição 0↔1 é do operador do KEDA, por fora dele.
- **A credencial do scaler usa FQDN** (`rabbitmq.fcg.svc.cluster.local`) porque o operador do KEDA
  roda no namespace `keda`, onde o nome curto não resolve. É a mesma credencial dos serviços, selada
  à parte só por causa do host.
- ⚠️ **O endpoint HTTP de histórico ficou inalcançável na plataforma.** A Function tem **três**
  funções — `UserCreatedFunction` e `PaymentProcessedFunction` (RabbitMQ) e `NotificationHistoryFunction`
  (**HTTP**) —, confirmado na imagem construída (`functions.metadata`). O `notifications-api` servia
  `GET /api/v1/notificacoes` atrás de um Service; o `k8s/24-notifications-function.yaml` **não declara
  `containerPort` nem Service**, e o scale-to-zero mantém 0 réplica. Consciente e não corrigido aqui:
  expor o endpoint exigiria Service + pod quente (o que anularia o scale-to-zero) ou um caminho de
  ativação por HTTP, além de tratar a `x-functions-key`. Fica como trabalho separado.
- **A `notifications-function` não está no `docker-compose.yml`**: scale-to-zero exige KEDA, que só
  existe no minikube. Para validar o código localmente, use `func start` no repo da Function.
- ⚠️ **Consequência disso no compose:** desde a remoção do `notifications-api`, **ninguém consome**
  `notifications-user-created` nem `notifications-payment-processed` no caminho do compose. As filas
  existem (o `definitions.json` está assado na imagem do broker), então as mensagens **acumulam** em
  vez de serem descartadas — nada quebra, mas **não há e-mail simulado para ver no compose**. O fluxo
  de notificação completo só é observável no cluster.

## Observabilidade — escolhemos a **Opção A** (Prometheus + Grafana)

O desafio da Fase 3 pede para escolher entre uma stack de código aberto (**Opção A**: Prometheus +
Grafana) ou uma plataforma de APM gerenciada (**Opção B**: Datadog ou New Relic), e **documentar a
escolha aqui**. Optamos pela **Opção A**, por três motivos:

1. **Custo zero e sem dependência de terceiros.** Nenhuma conta, nenhum trial que expira antes da
   entrega, nenhuma chave de API para gerenciar.
2. **É o que o próprio enunciado exige para a Opção A:** *"a implantação das ferramentas deve ser
   feita via manifestos Kubernetes"* — tudo está em [`k8s/40-`](k8s/40-observability-prometheus.yaml),
   [`41-`](k8s/41-observability-grafana.yaml), [`41b-`](k8s/41b-grafana-dashboard.yaml) e
   [`42-`](k8s/42-observability-jaeger.yaml), versionado e reproduzível.
3. **Funciona offline**, o que importa no dia da gravação do vídeo.

### Os três componentes

| Componente | Papel | Acesso |
|---|---|---|
| **Prometheus** | raspa `/metrics` dos pods e armazena as séries (retenção 6h) | `kubectl -n fcg port-forward svc/prometheus 9090:9090` |
| **Grafana** | dashboard de latência, throughput e erros | `kubectl -n fcg port-forward svc/grafana 3000:3000` — admin/admin |
| **Jaeger** | recebe traces OTLP de 3 dos 4 serviços — ver a ressalva abaixo | `kubectl -n fcg port-forward svc/jaeger 16686:16686` |

> **Por que Jaeger, se a Opção A só exige métricas?** Para cobrir o terceiro pilar da
> observabilidade, que o desafio só pede na Opção B. O `users-api` e o `catalog-api` instrumentam com
> OpenTelemetry e registram `AddSource("MassTransit")`, o que amarra os spans de publicação do outbox
> ao span HTTP que os originou.
>
> **A cadeia da COMPRA fecha num único trace. Medido, não estimado.** `GET /api/services` no Jaeger
> devolve `catalog-api`, `payments-api` e `users-api`, e o fluxo de compra aparece inteiro:
>
> ```
> trace 12a9febb22840ab46a93a61d4df07983 — 9 spans, DOIS serviços
>   +0.0ms     [catalog-api ] POST api/v1/biblioteca
>   +262.0ms   [catalog-api ] outbox send
>   +576.8ms   [catalog-api ] Fcg.Contracts.Events:OrderPlacedEvent send
>   +621.1ms   [payments-api] payments-order-placed receive        <- cruza o broker
>   +660.5ms   [payments-api] payments-order-placed process
>   +1245.0ms  [payments-api] Fcg.Contracts.Events:PaymentProcessedEvent send
>   +1266.3ms  [catalog-api ] catalog-payment-processed receive    <- e volta
>   +1301.5ms  [catalog-api ] catalog-payment-processed process
> ```
>
> O span do `payments-api` carrega os atributos de negócio (`fcg.order.id`, `fcg.payment.status`,
> `fcg.payment.rule`), e o serviço passou a expor `/metrics` — o alvo do Prometheus saiu de `down`
> para `up` (UP=4, DOWN=0). Entregue em
> [payments-api#19](https://github.com/fcg-grupo-16/payments-api/issues/19) e
> [#20](https://github.com/fcg-grupo-16/payments-api/issues/20).
>
> **A cadeia do CADASTRO também fecha.** A `notifications-function` restaura o contexto W3C que o
> MassTransit grava no header `MT-Activity-Id` do envelope e abre um span `Consumer` filho dele.
> Medido no cluster — trace `177e2dcf8e7a`, 5 spans em dois serviços:
>
> ```
> users-api              server    POST api/v1/usuarios
> users-api              producer  outbox send
> users-api              client    outbox process
> users-api              producer  Fcg.Contracts.Events:UserCreatedEvent send
> notifications-function consumer  UserCreatedFunction
> ```
>
> E a compra chega até a notificação: trace `ff866e2a4eb32ae4b59cdc2e9eabf008`, **10 spans em três
> serviços** (`catalog-api`, `payments-api`, `notifications-function`). O span da função e o
> `catalog-payment-processed receive` têm o mesmo pai — os dois consumidores do
> `PaymentProcessedEvent` aparecem lado a lado.
>
> ⚠️ O que **não** é verdade é que isso tenha vindo de uma mudança nova: a instrumentação já estava
> no `main` da Function desde o PR #13; o cluster é que servia uma imagem anterior a ele.

### Como os serviços são descobertos

No **Kubernetes**, por *annotation de pod* — um serviço novo que suba com elas é raspado sem editar
config nenhuma:

```yaml
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
```

No **compose** não existe API de pods para consultar, então os targets são estáticos em
[`docker/prometheus/prometheus.yml`](docker/prometheus/prometheus.yml). Nos dois casos as séries
recebem o label **`service`**, e é isso que faz o **mesmo dashboard** funcionar nos dois ambientes.

### O dashboard

A fonte da verdade é [`observability/fcg-overview.json`](observability/fcg-overview.json),
versionado. O ConfigMap `k8s/41b-grafana-dashboard.yaml` é **derivado** dele:

```bash
./scripts/gen-dashboard-configmap.sh    # regenera o ConfigMap a partir do JSON
```

As quatro métricas exigidas pela Fase 3 vêm **todas do mesmo histograma**
`http_server_request_duration_seconds` — **nenhuma métrica customizada foi necessária**.

Sendo preciso: o ASP.NET Core 8+ já instrumenta o `Meter` `Microsoft.AspNetCore.Hosting` com o
instrumento `http.server.request.duration` por conta própria; o **nome no formato Prometheus** e o
endpoint `/metrics` só passam a existir quando o serviço adiciona o SDK OpenTelemetry com
`AddPrometheusExporter()` + `MapPrometheusScrapingEndpoint()` — que é justamente o escopo de
`users-api#19`, `catalog-api#19` e `payments-api#19`. Os labels usados nas queries
(`http_response_status_code`, `http_request_method`, `http_route`) são os da convenção semântica
estável do OpenTelemetry.

> **Nota sobre o `or vector(0)` na taxa de erro.** Sem nenhum 5xx, a série filtrada **não existe**
> no Prometheus, e vetor vazio dividido por qualquer coisa continua vazio — sem esse guarda, o
> painel mostraria `No data` justamente quando a plataforma está saudável, visualmente idêntico a
> "a stack quebrou". O `clamp_min` no denominador resolve outro problema (o `NaN` de 0/0 quando o
> tráfego cessa); os dois são necessários.


| Painel | Métrica exigida | PromQL |
|---|---|---|
| Latência p50/p95/p99 por serviço | **latência** | `histogram_quantile(0.95, sum by (le, service) (rate(..._bucket[5m])))` |
| Throughput por serviço | **contagem de requisições** | `sum by (service) (rate(..._count[5m]))` |
| Requisições por status code | **contagem por status HTTP** | `sum by (http_response_status_code) (rate(..._count[5m]))` |
| Taxa de erro 5xx | **taxa de erros** | `100 * (sum(rate(..._count{...5xx}[5m])) or vector(0)) / clamp_min(sum(rate(..._count[5m])), 0.001)` |

> ⚠️ **Painel vazio hoje significa falta de tráfego, não falta de instrumentação.** Os três
> serviços ASP.NET expõem `/metrics` desde `users-api#19`, `catalog-api#19` e `payments-api#19`
> (as três fechadas), e a coleta mede **UP=4, DOWN=0** — os quatro alvos são os três serviços mais o
> próprio Prometheus. O que sobra é outra causa: as queries usam `rate(...[5m])`, então sem
> requisições nos últimos cinco minutos não existe série e o painel fica em branco com a plataforma
> perfeitamente saudável. Exercite os fluxos (`./scripts/smoke-test.sh`) antes de julgar o
> dashboard. Para separar um caso do outro, veja **Status → Targets** no Prometheus, ou o painel
> *Saúde da coleta* do próprio dashboard.
>
> ⚠️ **Ao instrumentar, confirme o nome real da métrica** no autocomplete do Prometheus: dependendo
> da versão do exportador ela pode sair como `http_server_request_duration_seconds` ou
> `http_server_duration_seconds`. **9 dos 10 painéis dependem desse nome** (a variável `service`
> inclusive), então uma divergência esvazia o dashboard inteiro de uma vez. Se acontecer:
>
> ```bash
> # 1. veja o nome real
> curl -s localhost:8081/metrics | grep -m1 '^# TYPE.*duration'
> # 2. troque em todas as queries
> sed -i '' 's/http_server_request_duration_seconds/<nome-real>/g' observability/fcg-overview.json
> # 3. regenere o ConfigMap e reaplique
> ./scripts/gen-dashboard-configmap.sh && kubectl apply -f k8s/41b-grafana-dashboard.yaml
> ```
>
> Não é preciso reiniciar o Grafana: o provider relê o diretório a cada 10s (a mudança aparece em
> ~20s). Só os **datasources** exigem `rollout restart`.

```bash
# Verificar a coleta
kubectl -n fcg port-forward svc/prometheus 9090:9090
open http://localhost:9090/targets

# Abrir o dashboard
kubectl -n fcg port-forward svc/grafana 3000:3000
open http://localhost:3000        # admin/admin -> pasta FCG -> "FCG — Visão Geral"
```

> **Portas 9090, 3000 e 4317 ocupadas?** São portas muito disputadas (outra stack de observabilidade
> na máquina, por exemplo). No compose elas são publicadas apenas em `127.0.0.1`; para remapear, use
> o `docker-compose.override.yml` (gitignored), nunca o arquivo versionado:
>
> ```yaml
> services:
>   prometheus:
>     ports: !override
>       - "127.0.0.1:9091:9090"
>   jaeger:
>     ports: !override
>       - "127.0.0.1:16686:16686"
>       - "127.0.0.1:4327:4317"
>       - "127.0.0.1:4328:4318"
> ```
>
> ⚠️ E **confirme a identidade** do que responde antes de concluir que a stack subiu — um
> `curl localhost:9090` pode estar batendo no Prometheus de outro projeto:
> `curl -s localhost:9090/api/v1/status/config | grep cluster` deve mostrar `fcg-compose`
> (ou `fcg-minikube` no cluster).

## Cache distribuído (Redis)

A plataforma provisiona **duas** instâncias de Redis, com propósitos opostos — e a separação é
deliberada ([ADR 0006](docs/adr/0006-redis-dedicado-para-idempotencia.md), issue #35):

| | Cache | Idempotência |
|---|---|---|
| Manifesto | [`k8s/12-infra-redis.yaml`](k8s/12-infra-redis.yaml) | [`k8s/12b-infra-redis-idempotencia.yaml`](k8s/12b-infra-redis-idempotencia.yaml) |
| kind | `Deployment` (sem PVC) | **`StatefulSet`** com `volumeClaimTemplates` |
| Persistência | `--save ""`, `--appendonly no` | **`--appendonly yes`**, `appendfsync everysec` |
| Memória cheia | `allkeys-lru` (descarta) | **`noeviction`** (recusa a escrita) |
| Consumidores | `users-api`, `catalog-api` | `notifications-function` |
| Compose | serviço `redis`, porta `6379` | — (a Function não roda no compose) |

**Por que duas.** O Redis de cache descarta o dado mais frio quando enche, e isso é correto para
cache. Mas a chave de idempotência é **escrita uma vez e lida nunca** — a única leitura é a
duplicata, que é rara —, então ela é sempre o dado mais frio da instância e seria a **primeira** a
ser descartada. Medido: 200 chaves de idempotência viraram 2 sob tráfego normal de cache. Como o
store da Function é *fail-closed*, perder a chave significa **e-mail duplicado** para o cliente.

**Isolamento entre serviços é lógico, por prefixo de chave.** No Redis de cache, cada serviço
escreve sob o prefixo do seu `Redis__InstanceName`: `fcg:users:` e `fcg:catalog:`. A Function usa
`fcg:notifications:` na instância dedicada.

> ⚠️ **Prefixo é organização, não fronteira de segurança.** O Redis roda sem autenticação e sem
> `NetworkPolicy`, então qualquer pod do namespace consegue ler e escrever o keyspace de qualquer
> serviço — um `KEYS fcg:users:*` a partir do `payments-api` funciona. Diferente do
> *database-per-service* do Mongo, isto não é uma barreira: é uma convenção de nomes. Aceitável
> num ambiente de demonstração; em produção exigiria `requirepass`/ACL por serviço e NetworkPolicy
> de ingress.

**O Redis de CACHE roda sem persistência, de propósito.** Sobe com `--save ""` e `--appendonly no`,
e no Kubernetes é um `Deployment` **sem** `PersistentVolumeClaim`. Todo dado ali é reconstruível a
partir do Mongo, então perdê-lo na recriação do Pod é aceitável e evita carregar um PVC que não
agregaria nada. **O de idempotência é o oposto** — AOF em volume persistente —, porque a chave dele
não é reconstruível de lugar nenhum.

**Proteção contra OOM.** `--maxmemory 256mb` com `--maxmemory-policy allkeys-lru`: ao atingir o
teto, o Redis descarta as chaves menos usadas em vez de crescer até estourar. O `limits.memory` do
container é **o dobro** desse teto (512Mi) justamente para o kernel não matar o container antes de
a evicção rodar — o `maxmemory` do Redis contabiliza o allocator, não o RSS, então fragmentação e
buffers de saída de cliente ficam fora daquela conta e entram na do kernel.

```bash
# compose (só o cache; a Function não roda aqui)
docker compose exec redis redis-cli ping
docker compose exec redis redis-cli --scan --pattern 'fcg:*'

# kubernetes — cache
kubectl -n fcg exec deploy/redis -- redis-cli --scan --pattern 'fcg:*'

# kubernetes — idempotência (INSTÂNCIA SEPARADA: as chaves não aparecem no comando acima)
kubectl -n fcg exec statefulset/redis-idempotencia -- redis-cli --scan --pattern 'fcg:notifications:*'
kubectl -n fcg exec statefulset/redis-idempotencia -- redis-cli config get maxmemory-policy appendonly
```

> **Porta 6379 ocupada na sua máquina?** É comum ter outro Redis local. Remapeie **apenas** no
> `docker-compose.override.yml` (gitignored), como já fazemos com o Mongo em `27018` — nunca no
> `docker-compose.yml` versionado:
>
> ```yaml
> services:
>   redis:
>     ports: !override
>       - "6380:6379"
> ```
>
> Os serviços do compose continuam falando com `redis:6379` pela rede interna do docker; o
> remapeamento afeta só o acesso a partir do host.

## Configuração e segredos

- **ConfigMaps** — dados não sensíveis: host do RabbitMQ, nome do database Mongo por
  serviço, issuer/audience do JWT, `ASPNETCORE_ENVIRONMENT`.
- **Secrets** — dados sensíveis: connection string do MongoDB, chave JWT, credenciais
  do RabbitMQ e a connection string do Redis (`Redis__ConnectionString`).
- **Cache (Fase 3):** `Redis__InstanceName` vai no **ConfigMap** de cada serviço (é só um prefixo
  de chave, não sensível); `Redis__ConnectionString` vai no **Secret**, por paridade com as demais
  connection strings — em produção ela carregaria credencial.
- A **chave JWT** (`JwtSettings__SecretKey`) **deve ser idêntica** em `users-api` (emite)
  e `catalog-api` (valida).
- **Databases (database-per-service):** `usersdb` (users-api), `catalogdb` (catalog-api) e
  `paymentsdb` (payments-api). O `paymentsdb` é provisionado aqui (ConfigMap + SealedSecret com
  `?replicaSet=rs0`) e passa a ser consumido pela persistência/idempotência do payments-api
  (issues `payments-api#2`/`#1`). Todos reusam a mesma instância `mongodb` (databases lógicos distintos).
- Os valores são de **demonstração**. NUNCA versione chaves reais.

### Segredos no Kubernetes — Sealed Secrets

No **Kubernetes**, os Secrets **não** são versionados em texto claro. Em vez disso, o repo
versiona **`SealedSecret`s cifrados** ([`k8s/05-sealed-secrets.yaml`](k8s/05-sealed-secrets.yaml)),
usando [Bitnami Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets). Apenas o
**controller do cluster** consegue decifrá-los e materializar os `Secret` reais no namespace `fcg`;
o arquivo cifrado é seguro para commit.

> No `docker-compose` (dev local) os segredos continuam em variáveis de ambiente/âncora YAML —
> Sealed Secrets é um mecanismo **específico de Kubernetes**. Os **valores** são idênticos entre
> compose e k8s; só a forma de armazenamento no cluster muda.

**Pré-requisitos (uma vez por cluster):**

```bash
# 1) CLI kubeseal
brew install kubeseal

# 2) controller no cluster (versão pinada; o deploy-minikube.sh também garante isso)
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.38.4/controller.yaml
kubectl -n kube-system rollout status deploy/sealed-secrets-controller
```

**Gerar / rotacionar os segredos** — edite os valores (ou exporte as env vars para valores reais)
e rode o helper, que regenera o arquivo cifrado:

```bash
# valores de demo por padrão; para valores reais: export JWT_SECRET_KEY=... RABBIT_PASS=... etc.
./scripts/seal-secrets.sh
kubectl apply -f k8s/05-sealed-secrets.yaml   # o controller materializa os Secrets
```

O `scripts/seal-secrets.sh` garante que `JwtSettings__SecretKey` seja **idêntica** em
`users-api-secret` e `catalog-api-secret` (JWT parity).

> ⚠️ **A chave do controller é por-cluster.** Se recriar o minikube (`minikube delete`), o novo
> controller ganha outra chave e os `SealedSecret`s antigos **não decifram mais** — reinstale o
> controller e rode `./scripts/seal-secrets.sh` de novo. Em produção, faça backup da chave do controller.

## Credenciais semeadas (seed)

O `users-api` cria um administrador na inicialização:

- **E-mail:** `admin@fcg.com`
- **Senha:** `Admin@123456`

## Scripts

Todos em `scripts/`, todos idempotentes e seguros para rodar mais de uma vez.

| Script | O que faz | Quando usar |
|---|---|---|
| `deploy-minikube.sh` | build + carga das imagens (tag por commit), instala Kong e KEDA, aplica os manifestos | subir a plataforma no cluster |
| `undeploy-minikube.sh` | remove a plataforma, os controllers e os CRDs | limpar o cluster |
| `verify-fase3.sh` | **checklist da entrega**: 24 checagens dos 5 requisitos, consultando o cluster | antes de gravar o vídeo |
| `smoke-test.sh` | 9 casos de ponta a ponta (11 asserções), em `MODO=compose` ou `MODO=gateway` | validar os fluxos |
| `gateway-test.sh` | matriz de aceite do Kong: 17 asserções — 15 na matriz e 2 de isolamento de rate limit, medidas com **dois pods em IPs distintos** | validar o gateway |
| `keda-test.sh` | ciclo 0→1→0 do scale-to-zero (12 asserções) | validar o serverless |
| `seal-secrets.sh` | gera os `SealedSecret` de `k8s/05-sealed-secrets.yaml` | ao trocar um segredo, ou após `minikube delete` |
| `gen-dashboard-configmap.sh` | regenera o ConfigMap do dashboard a partir do JSON | ao editar o dashboard |

A sequência completa, num cluster do zero:

```bash
minikube delete && minikube start
./scripts/seal-secrets.sh          # a chave do controller é NOVA depois do delete
./scripts/deploy-minikube.sh
./scripts/verify-fase3.sh          # deve terminar em "PRONTO PARA GRAVAR"
```

> `verify-fase3.sh` e `smoke-test.sh` **não se substituem**: o primeiro confere que os componentes
> estão lá e servindo o binário certo; o segundo exercita os fluxos de verdade. Um cluster pode
> passar no primeiro e reprovar no segundo.

## CI — validação de compose e manifestos

Todo **push na `main`** e **todo pull request** dispara o workflow
[`.github/workflows/ci.yml`](.github/workflows/ci.yml), que valida a orquestração
**sem subir nada** (não há cluster nem build de imagem no CI):

| Step | Comando | O que pega |
|---|---|---|
| docker-compose | `docker compose -f docker-compose.yml config -q` | sintaxe/estrutura do compose |
| kubeconform | `kubeconform -strict … -schema-location default -schema-location <catálogo de CRDs>` | schema rigoroso dos manifestos, **incluindo os CRs** — ver a ressalva abaixo sobre até onde isso vai |
| shellcheck | `shellcheck -S warning scripts/*.sh` | semântica dos scripts (o `bash -n` só faz parse) |
| RabbitMQ | `python3 .github/scripts/validar-definitions-rabbitmq.py …` | topologia das filas: JSON, dead-lettering, bindings órfãos |
| Kong | `helm template kong/kong --version … -f gateway/kong-values.yaml` | values inválidos do gateway |
| yamllint | `yamllint -c .yamllint …` | YAML malformado (**bloqueante**, com a config versionada) |

> **Por que kubeconform e não `kubectl --dry-run=client`?** Apesar do nome, o dry-run
> "client" do kubectl moderno **não é offline**: ele precisa de _discovery_ do apiserver
> e do OpenAPI do cluster para validar — sem cluster no runner, falha com
> `connection refused`. O `kubeconform` faz a **mesma validação de schema, offline** e
> mais rigorosa, contra os schemas oficiais do Kubernetes.
>
> O CI usa apenas `-f docker-compose.yml` para ser **determinístico**: valida só o
> arquivo versionado, sem influência de um `docker-compose.override.yml` local
> (gitignored) — o Compose só o carrega automaticamente se ele existir. O `kubeconform`
> roda em versão **pinada** (nunca `latest`).

**Os CRs de terceiros deixaram de ser pulados** — mas o ganho não é uniforme, e vale saber onde ele
para. Antes, `-ignore-missing-schemas` fazia o kubeconform **pular** todo CR sem schema conhecido:
dos **48** recursos de `k8s/`, **13** eram invisíveis ao CI (6 `SealedSecret`, 4 `KongPlugin`, 1
`KongConsumer`, `ScaledObject` e `TriggerAuthentication`) — `k8s/50-keda-notifications.yaml` inteiro
não era validado. Apontando o kubeconform também para o
[catálogo da comunidade](https://github.com/datreeio/CRDs-catalog), os 48 passam a ser validados.

Medido com a versão pinada do CI (kubeconform v0.6.7), mutando os manifestos:

| Mutação | Sem catálogo | Com catálogo |
|---|---|---|
| `k8s/` como está | 35 válidos, **13 pulados** | **48 válidos, 0 pulados** |
| campo inventado no `spec` do `ScaledObject` | passa | **reprova** |
| campo inventado no topo do `KongPlugin` | passa | **passa** |
| `claims_to_verifyy` dentro de `config` | passa | **passa** |
| `plugin: 123` (tipo errado) | passa | reprova |
| `KongPlugin` sem o campo `plugin` | passa | reprova |

> ⚠️ **O caso do Kong continua aberto, e de propósito.** O schema do `KongPlugin` não declara
> `additionalProperties: false` no topo e trata `config` como objeto livre — tem de tratar, já que o
> conteúdo de `config` varia por plugin. Então **um typo em `claims_to_verify` ainda passa verde**, o
> Kong rejeita o plugin, e o gateway devolve 401 sem token (parece funcionar) e 401 **também com
> token válido**.
>
> O caso do KEDA, esse fechou — e era o pior: um campo errado no scaler passava verde e o Deployment
> ficava parado em **0 réplica**, indistinguível de scale-to-zero funcionando, só que nada acorda
> quando chega mensagem. A condição `Ready` **não** basta para distinguir: credencial irresolvível dá
> `Ready=False`, mas `queueName` inexistente dá `Ready=True` até o primeiro poll do trigger.
>
> Por isso a validação comportamental continua obrigatória: `scripts/gateway-test.sh` para o gateway
> e `scripts/keda-test.sh` para o scale-to-zero. O CI não substitui nenhum dos dois.

Para reproduzir o CI localmente:

```bash
docker compose -f docker-compose.yml config -q                       # step 1
kubeconform -strict -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  -ignore-missing-schemas k8s/                                       # step 2
bash -n scripts/*.sh && shellcheck -S warning scripts/*.sh           # step 3
python3 .github/scripts/validar-definitions-rabbitmq.py \
  docker/rabbitmq/definitions.json                                   # step 4
helm template kong kong/kong --version 3.4.1 \
  --namespace kong -f gateway/kong-values.yaml > /dev/null           # step 5
yamllint -c .yamllint k8s/ gateway/ docker-compose.yml .github/      # step 6
```

> `-schema-location default` precisa ser repetido: ao passar qualquer `-schema-location`, o
> kubeconform **substitui** a lista padrão em vez de acrescentar — sem ele, `Deployment`, `Service`
> e companhia ficariam sem schema e seriam pulados, exatamente o oposto do pretendido.

## Como contribuir

O fluxo vale para este repo e para os 4 repos de serviço:

1. **Pegue uma issue** no repositório correspondente e atribua a si mesmo (`assignee`).
2. **Crie um branch** a partir da `main`: `feat/<numero>-descricao-curta` ou `fix/<numero>-descricao-curta`.
3. **Commits** no padrão [Conventional Commits](https://www.conventionalcommits.org) (`feat:`, `fix:`, `chore:`, `test:`, `docs:`). Mensagens em pt-BR para domínio, inglês para termos técnicos.
4. **Abra um PR** para a `main` referenciando a issue (`Closes #<numero>`). O CI precisa passar — nos serviços é build + testes; neste repo é a validação de compose/manifestos (ver seção **CI** acima).
5. **Merge** após review. Nunca commite segredos reais (use ConfigMaps/Secrets e variáveis de ambiente).

Política de idioma: conteúdo de usuário e domínio em **pt-BR**; namespaces, métodos e infraestrutura em **inglês**.

## Versionamento e release de imagens

Cada serviço versiona por **SemVer** via tag git `vX.Y.Z` no seu próprio repositório. Fluxo de release de uma versão:

```bash
# 1. No repo do serviço, com a main estável:
git tag v1.0.0 && git push origin v1.0.0

# 2. Build e publish da imagem no GitHub Container Registry (GHCR):
gh auth token | docker login ghcr.io -u <seu-usuario> --password-stdin
docker build -t ghcr.io/fcg-grupo-16/<servico>:v1.0.0 .
docker push ghcr.io/fcg-grupo-16/<servico>:v1.0.0

# 3. Atualize a imagem no cluster (neste repo, k8s/2x-<servico>.yaml, ou direto):
kubectl set image deploy/<servico> <servico>=ghcr.io/fcg-grupo-16/<servico>:v1.0.0 -n fcg
```

No desenvolvimento local com minikube as imagens são marcadas pelo **commit do repositório de
origem** (`users-api:5f78b28`), não por uma tag móvel. O `deploy-minikube.sh` calcula a tag, builda,
carrega no nó e aplica os manifestos numa **cópia renderizada** com essas tags — os arquivos de `k8s/`
permanecem com `:local` para continuarem sendo YAML puro, validável offline pelo CI.

> **Por que não a tag móvel.** Quando `<servico>:local` já existe no nó e um container a referencia,
> `minikube image load` vira **no-op silencioso** (sai 0, sem mensagem) e `minikube image rm` recusa
> sem `--force`. O pod segue `Running` servindo o binário **antigo**, e `kubectl get` não acusa nada:
> foi assim que métricas, avaliações e cache ficaram invisíveis no cluster (issue #40). Com tag nova a
> cada commit a colisão é impossível, e trocar de commit muda o `image:` do spec, disparando o rollout
> naturalmente — ao contrário de `rollout restart`, que **não resolve** quando o spec não muda.

A pipeline de build/push para o GHCR em cada tag pode ser adicionada como workflow (`release.yml`) em
cada repo — está mapeada como melhoria nas issues.

## Repositórios do grupo

- [orchestration](https://github.com/fcg-grupo-16/orchestration) · [users-api](https://github.com/fcg-grupo-16/users-api) · [catalog-api](https://github.com/fcg-grupo-16/catalog-api) · [payments-api](https://github.com/fcg-grupo-16/payments-api) · [notifications-function](https://github.com/fcg-grupo-16/notifications-function) · [notifications-api](https://github.com/fcg-grupo-16/notifications-api) (deprecado)

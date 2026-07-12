# FIAP Cloud Games (FCG) — Orquestração (Fase 2)

Repositório central de **orquestração** da plataforma FIAP Cloud Games, refatorada de um
monólito .NET para uma arquitetura de **microsserviços orientada a eventos**.

Aqui ficam o `docker-compose.yml` (sobe a plataforma completa localmente) e os manifestos
**Kubernetes** (`/k8s`) para o deploy em cluster. O código de cada microsserviço vive em
seu próprio repositório.

> **Grupo 16** — Org GitHub [`fcg-grupo-16`](https://github.com/fcg-grupo-16)

[![CI](https://github.com/fcg-grupo-16/orchestration/actions/workflows/ci.yml/badge.svg)](https://github.com/fcg-grupo-16/orchestration/actions/workflows/ci.yml)

## Microsserviços

| Serviço | Repositório | Responsabilidade | Eventos |
|---|---|---|---|
| **UsersAPI** | [`users-api`](https://github.com/fcg-grupo-16/users-api) | Cadastro, autenticação (JWT) e autorização | publica `UserCreatedEvent` |
| **CatalogAPI** | [`catalog-api`](https://github.com/fcg-grupo-16/catalog-api) | CRUD de jogos, biblioteca e início da compra | publica `OrderPlacedEvent`; consome `PaymentProcessedEvent` |
| **PaymentsAPI** | [`payments-api`](https://github.com/fcg-grupo-16/payments-api) | Processa (simula) o pagamento | consome `OrderPlacedEvent`; publica `PaymentProcessedEvent` |
| **NotificationsAPI** | [`notifications-api`](https://github.com/fcg-grupo-16/notifications-api) | "Envia" e-mails (log no console) | consome `UserCreatedEvent` e `PaymentProcessedEvent` |

**Stack:** .NET 10 · MongoDB (database por serviço) · RabbitMQ + MassTransit · Docker · Kubernetes.

> **RabbitMQ com plugin de mensagens atrasadas.** O broker roda uma imagem custom
> (`docker/rabbitmq/`: `rabbitmq:3.13.7-management` + `rabbitmq_delayed_message_exchange`),
> exigida pelo **delayed redelivery** (second-level retry) do MassTransit no
> [`catalog-api`](https://github.com/fcg-grupo-16/catalog-api) (issue `catalog-api#4`).
> O compose builda via `build:`; no k8s a imagem `fcg-rabbitmq:local` é construída e carregada
> no minikube pelo `scripts/deploy-minikube.sh`.

## Fluxos orientados a eventos

```mermaid
flowchart LR
    subgraph Cadastro
      U[UsersAPI] -- UserCreatedEvent --> N1[NotificationsAPI<br/>e-mail boas-vindas]
    end
    subgraph Compra
      C[CatalogAPI] -- OrderPlacedEvent --> P[PaymentsAPI]
      P -- PaymentProcessedEvent --> C2[CatalogAPI<br/>grava biblioteca se Approved]
      P -- PaymentProcessedEvent --> N2[NotificationsAPI<br/>e-mail confirmação se Approved]
    end
```

**Fluxo de cadastro:** `UsersAPI` cria o usuário e publica `UserCreatedEvent` → `NotificationsAPI` envia o e-mail de boas-vindas.

**Fluxo de compra:** `CatalogAPI` recebe a requisição de aquisição e publica `OrderPlacedEvent` (UserId, GameId, Price) → `PaymentsAPI` processa e publica `PaymentProcessedEvent` (Approved/Rejected) → `CatalogAPI` grava na biblioteca se aprovado, e `NotificationsAPI` envia o e-mail de confirmação.

## Estrutura de diretórios esperada

Clone os 5 repositórios como irmãos:

```
fiap/
├── orchestration/      (este repo)
├── users-api/
├── catalog-api/
├── payments-api/
└── notifications-api/
```

```bash
gh repo clone fcg-grupo-16/orchestration
gh repo clone fcg-grupo-16/users-api
gh repo clone fcg-grupo-16/catalog-api
gh repo clone fcg-grupo-16/payments-api
gh repo clone fcg-grupo-16/notifications-api
```

## Executar com Docker Compose

A partir deste repositório:

```bash
docker compose up --build
```

Sobe RabbitMQ, MongoDB e os 4 microsserviços. Portas expostas no host:

| Serviço | URL | Swagger |
|---|---|---|
| users-api | http://localhost:8081 | /swagger |
| catalog-api | http://localhost:8082 | /swagger |
| payments-api | http://localhost:8083 | (worker) |
| notifications-api | http://localhost:8084 | (worker) |
| RabbitMQ Management | http://localhost:15672 | guest / guest |
| MongoDB | mongodb://localhost:27017/?replicaSet=rs0 | — |

> Swagger só é exposto em ambiente Development. Para ativá-lo no compose, troque
> `ASPNETCORE_ENVIRONMENT` para `Development` no serviço desejado.

> **MongoDB roda como replica set (`rs0`).** O container sobe com `mongod --replSet rs0` e o
> healthcheck do compose **auto-inicia** o replica set (`rs.initiate(...)`); por isso os serviços
> conectam com `MongoDbSettings__ConnectionString=mongodb://mongodb:27017/?replicaSet=rs0`. O replica
> set é **pré-requisito do outbox transacional da `users-api`** — transações multi-documento do
> MongoDB exigem replica set. Ao editar o `docker-compose.yml`, **não** remova o `--replSet rs0` nem
> o `?replicaSet=rs0` das connection strings, ou o cadastro de usuários passa a falhar.

### Testar os dois fluxos de ponta a ponta

```bash
./scripts/smoke-test.sh          # requer jq
docker compose logs payments-api notifications-api
```

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
./scripts/deploy-minikube.sh
```

Faz o build das imagens `:local`, carrega no minikube e aplica os manifestos.

### Forma manual

```bash
minikube start

# Build + carga das imagens no cluster
for s in users-api catalog-api payments-api notifications-api; do
  docker build -t "$s:local" "../$s"
  minikube image load "$s:local"
done

# Deploy (recursivo por causa das subpastas/ordenação)
kubectl apply -R -f k8s/

# Verificar
kubectl -n fcg get pods
```

Acessar os serviços:

```bash
kubectl -n fcg port-forward svc/users-api 8081:80
kubectl -n fcg port-forward svc/catalog-api 8082:80
kubectl -n fcg port-forward svc/rabbitmq 15672:15672   # Management UI
```

Comunicação interna no cluster usa os nomes de Service (ex.: `http://catalog-api:80`,
`rabbitmq:5672`, `mongodb:27017`).

### Acesso externo via Ingress

Os serviços HTTP voltados ao usuário (`users-api`, `catalog-api`) são expostos por um **Ingress**
([`k8s/30-ingress.yaml`](k8s/30-ingress.yaml)), evitando o `port-forward` manual. `payments-api` e
`notifications-api` são orientados a eventos e **não** têm entrada HTTP externa.

Pré-requisito — o **NGINX Ingress Controller** (o `deploy-minikube.sh` já habilita):

```bash
minikube addons enable ingress
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller
```

Mapeie os hosts para o IP do Ingress e teste:

```bash
echo "$(minikube ip) users.fcg.local catalog.fcg.local" | sudo tee -a /etc/hosts

curl http://users.fcg.local/health              # 200 (users-api usa /health)
curl http://catalog.fcg.local/api/v1/jogos      # 200 (lista de jogos)
```

> **macOS + driver docker:** o `minikube ip` (rede interna do Docker) **não** é alcançável direto
> do host. Rode `minikube tunnel` em outro terminal (expõe o Ingress em `127.0.0.1`) e aponte os
> hosts para `127.0.0.1` no `/etc/hosts`. Alternativa sem `/etc/hosts`: port-forward do controller —
> `kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8080:80` e então
> `curl -H 'Host: catalog.fcg.local' http://localhost:8080/api/v1/jogos`.

O roteamento é por **host**; o path é passado **intacto** ao backend (sem `rewrite-target`), então
rotas como `/api/v1/jogos` chegam inteiras.

Remover:

```bash
./scripts/undeploy-minikube.sh   # ou: kubectl delete -R -f k8s/
```

> O `PersistentVolumeClaim` gerado pelo `volumeClaimTemplates` **não** é removido por
> `kubectl delete -R -f k8s/` — os dados ficam para trás de propósito. Para zerar de vez
> num ambiente de demo: `kubectl -n fcg delete pvc mongo-data-mongodb-0`.

## Configuração e segredos

- **ConfigMaps** — dados não sensíveis: host do RabbitMQ, nome do database Mongo por
  serviço, issuer/audience do JWT, `ASPNETCORE_ENVIRONMENT`.
- **Secrets** — dados sensíveis: connection string do MongoDB, chave JWT e credenciais
  do RabbitMQ.
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

## CI — validação de compose e manifestos

Todo **push na `main`** e **todo pull request** dispara o workflow
[`.github/workflows/ci.yml`](.github/workflows/ci.yml), que valida a orquestração
**sem subir nada** (não há cluster nem build de imagem no CI):

| Step | Comando | O que pega |
|---|---|---|
| docker-compose | `docker compose -f docker-compose.yml config -q` | sintaxe/estrutura do compose |
| kubeconform | `kubeconform -strict -ignore-missing-schemas k8s/` | schema rigoroso dos manifestos (offline) |
| yamllint | `yamllint -d relaxed …` | estilo de YAML (**não-bloqueante** por enquanto) |

> **Por que kubeconform e não `kubectl --dry-run=client`?** Apesar do nome, o dry-run
> "client" do kubectl moderno **não é offline**: ele precisa de _discovery_ do apiserver
> e do OpenAPI do cluster para validar — sem cluster no runner, falha com
> `connection refused`. O `kubeconform` faz a **mesma validação de schema, offline** e
> mais rigorosa, contra os schemas oficiais do Kubernetes.
>
> O CI usa apenas `-f docker-compose.yml` para ser **determinístico**: valida só o
> arquivo versionado, sem influência de um `docker-compose.override.yml` local
> (gitignored) — o Compose só o carrega automaticamente se ele existir. O `kubeconform`
> roda em versão **pinada** (nunca `latest`) e o `-ignore-missing-schemas` evita
> falso-negativo em CRDs sem schema conhecido — é o caso do `SealedSecret`
> (`k8s/05-sealed-secrets.yaml`), que o kubeconform **pula** em vez de reprovar.

Para reproduzir o CI localmente:

```bash
docker compose -f docker-compose.yml config -q             # step 1
kubeconform -strict -summary -ignore-missing-schemas k8s/  # step 2 (brew install kubeconform)
```

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

Para o desenvolvimento local com minikube continuamos usando a tag `:local` (build + `minikube image load`), como descrito acima. A pipeline de build/push para o GHCR em cada tag pode ser adicionada como workflow (`release.yml`) em cada repo — está mapeada como melhoria nas issues.

## Repositórios do grupo

- [orchestration](https://github.com/fcg-grupo-16/orchestration) · [users-api](https://github.com/fcg-grupo-16/users-api) · [catalog-api](https://github.com/fcg-grupo-16/catalog-api) · [payments-api](https://github.com/fcg-grupo-16/payments-api) · [notifications-api](https://github.com/fcg-grupo-16/notifications-api)

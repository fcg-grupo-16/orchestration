# Changelog

Todas as mudanças relevantes deste repositório de orquestração são documentadas aqui.

O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.0.0/)
e o versionamento adere a [Semantic Versioning](https://semver.org/lang/pt-BR/).

## [0.12.0] - 2026-09-09

### Adicionado
- **Redis como camada de cache distribuído da plataforma** (`k8s/12-infra-redis.yaml` + serviço
  `redis` no compose). Requisito obrigatório da Fase 3. Este repositório entrega a **infraestrutura
  e o contrato de configuração**; o consumo pelo código vem depois, em `users-api#20` e
  `catalog-api#21` (cache de consultas onerosas) e `notifications-function#3` (store de
  idempotência). (#25)
- **Contrato de configuração do cache:** `Redis__InstanceName` nos ConfigMaps de `users-api`
  (`fcg:users:`) e `catalog-api` (`fcg:catalog:`); `Redis__ConnectionString` nos SealedSecrets dos
  dois serviços. (#25)
- **initContainer `wait-for-redis`** nos Deployments de `users-api` e `catalog-api`, no mesmo padrão
  dos que já esperam Mongo e RabbitMQ. (#25)
- Seção **"Cache distribuído (Redis)"** no README, incluindo como remapear a porta quando o host já
  tem um Redis na 6379. (#25)

### Notas de implementação
- **`Deployment` sem `PersistentVolumeClaim`, ao contrário do MongoDB.** É cache: todo dado é
  reconstruível a partir do Mongo, então perder o conteúdo na recriação do Pod é aceitável e evita
  carregar um PVC que não agregaria nada. Coerente com o compose (`--save ""`, `--appendonly no`).
- **`--maxmemory 256mb` com `--maxmemory-policy allkeys-lru`**, e `limits.memory` do container
  **acima** desse teto (512Mi, 2× — alinhado com Mongo e RabbitMQ): se fossem iguais, o kernel
  mataria o container (OOMKilled) antes de o Redis aplicar a evicção, e o mecanismo de proteção
  nunca chegaria a rodar. `requests.memory` também em 256Mi (o consumo de regime, não o de idle),
  senão o pod ficaria em QoS Burstable e seria o primeiro candidato a despejo do namespace.
- **Isolamento entre serviços é lógico**, por prefixo de chave (`Redis__InstanceName`), e não por
  instâncias separadas. Mesma filosofia do database-per-service do Mongo, sem o custo de três Redis
  num ambiente de demonstração.
- `Service` do tipo **ClusterIP**, sem rota no Ingress: no Kubernetes o Redis não é acessível de
  fora do cluster. No **compose** a porta é publicada apenas em `127.0.0.1` — o Redis roda sem
  `requirepass` e com `protected-mode no`, então publicar em `0.0.0.0` daria `FLUSHALL` e leitura
  do cache a qualquer máquina na mesma rede.
- **Prefixo de chave é organização, não fronteira de segurança.** Sem autenticação e sem
  `NetworkPolicy`, qualquer pod do namespace lê e escreve o keyspace de qualquer serviço.
  Documentado no README como limitação consciente do ambiente de demonstração.
- `strategy: Recreate` no Deployment: com `RollingUpdate` e `replicas: 1`, o `maxSurge` faria o
  Service balancear entre dois Redis com estados diferentes durante um update — inofensivo para
  cache, mas perda de correção para o store de idempotência da Function.
- `timeoutSeconds`/`failureThreshold` explícitos nas probes, como já fazem os manifestos do Mongo e
  do RabbitMQ: o default de 1s numa exec probe (fork+exec a cada ciclo) gera restart espúrio sob
  throttling de CPU, e um restart aqui apaga o cache inteiro da plataforma.

## [0.11.0] - 2026-09-09

### Adicionado
- **Topologia declarativa das filas de notificação** (`docker/rabbitmq/definitions.json` +
  `load-definitions.conf`, carregados pela imagem custom do broker). Cria exchanges, as filas
  `notifications-user-created` / `notifications-payment-processed`, a dead-letter queue
  `notifications-dlq` e o usuário `guest` **no boot do broker**, sem depender de nenhum serviço .NET.
  Pré-requisito da `notifications-function` (Fase 3): o binding `RabbitMQTrigger` da Azure Functions
  apenas **consome** de uma fila existente — não declara fila, exchange nem binding. Sem isso a
  mensagem publicada cairia num exchange sem binding e seria **descartada em silêncio**. (#28)
- **SealedSecret `notifications-function-secret`** com `RabbitMqConnection` (URI AMQP completa,
  formato exigido pelo binding), `MongoDbSettings__ConnectionString` e `Redis__ConnectionString`. (#28)
- **`docker/rabbitmq/README.md`** documentando a topologia e as três decisões não óbvias do desenho. (#28)

### Notas de implementação
- **Dead-letter aplicado por _policy_, não por `x-dead-letter-exchange` nos `arguments` da fila.**
  Os argumentos participam da checagem de equivalência do `queue.declare`; o MassTransit declara
  estas filas sem argumento nenhum, então declará-las com o argumento faria o `notifications-api`
  morrer no startup com `PRECONDITION_FAILED - inequivalent arg 'x-dead-letter-exchange'` durante
  toda a janela de transição até a remoção do serviço (#29). Verificado empiricamente.
- **O `definitions.json` espelha exatamente a topologia do MassTransit** (capturada com
  `rabbitmqadmin export`), incluindo o exchange intermediário por endpoint. Simplificar para um
  binding direto criaria divergência de propriedades e o mesmo tipo de conflito.
- **O usuário `guest` precisa estar declarado no arquivo.** Com `load_definitions` configurado o
  broker registra `Will not seed default virtual host and user: have definitions to load` e deixa de
  criar o usuário padrão — uma lista `users` vazia derrubaria a autenticação de toda a plataforma.

## [0.10.1] - 2026-07-13

### Corrigido
- **Barreira de memória no health check do RabbitMQ** dos quatro serviços (`users-api`, `catalog-api`,
  `payments-api`, `notifications-api`). A leitura *fast-path* da conexão reutilizada acontecia **fora**
  do `SemaphoreSlim`; sem barreira, o JIT poderia cachear a referência em registrador (leitura *stale*
  entre probes concorrentes) — data race benigno e autocorrigível, mas fechado por rigor. Passou a
  usar `Volatile.Read`/`Volatile.Write` (pareando com o lock, semântica acquire/release), de forma
  **uniforme nos quatro serviços**. Comportamento observável inalterado. Imagens `:local` rebuildadas
  e redeployadas; validado no cluster (4 pods `Ready`, fluxos cadastro/compra OK, broker estável, sem leak).

## [0.10.0] - 2026-07-13

### Adicionado
- **MongoDB (`notificationsdb`) provisionado para o `notifications-api`** — o serviço deixa de ser
  "zero banco" e passa a **persistir o histórico das notificações enviadas** (auditoria/relatórios,
  `notifications-api#2`). Ganha `MongoDbSettings__DatabaseName=notificationsdb` (ConfigMap) e
  `MongoDbSettings__ConnectionString` com `?replicaSet=rs0` (SealedSecret cifrado), no compose e no
  k8s, além do initContainer `wait-for-mongodb` e do `depends_on: mongodb`. `database-per-service`
  preservado (reusa a instância `mongodb`, database lógico novo). Consultável em
  `GET /api/v1/notificacoes`.

### Modificado
- **Probes do `notifications-api` separados**: `livenessProbe → /health/live` e
  `readinessProbe → /health/ready` (antes ambos em `/health`), refletindo o readiness que agora
  cobre **RabbitMQ + MongoDB**. Entregue junto com a maturação do serviço (`notifications-api#6`).
- Imagem `:local` do `notifications-api` rebuildada e recarregada no cluster, incorporando o backlog
  do serviço entregue nesta rodada: idempotência dos consumers (`#1`), retry + dead-letter (`#4`),
  readiness com RabbitMQ sem leak de conexão (`#6`), provider de e-mail plugável `IEmailSender` (`#3`),
  testes de integração com MassTransit Test Harness (`#5`) e persistência do histórico (`#2`).

### Validação
- Pod `Ready` (health check de Mongo + RabbitMQ). Cadastro → registro persistido no `notificationsdb`
  e retornado por `GET /api/v1/notificacoes`. Fluxos cadastro/compra OK. Broker estável (sem leak).

## [0.9.0] - 2026-07-13

### Corrigido
- **Leak de conexões AMQP nos health checks de readiness** dos três serviços que publicam/consomem
  eventos (`users-api#16`, `catalog-api#16`, `payments-api#16`; o payments já tinha o leak corrigido
  em `#14`). O `AddRabbitMQ` do readiness abria uma **conexão AMQP nova a cada checagem** e não a
  fechava (+1 por período de `readinessProbe`, em três serviços), acumulando **milhares** de conexões
  e saturando a memória do broker até o `memory alarm` (que bloqueia os publishers — a mesma classe
  de sintoma tratada pontualmente no watermark da v0.8.0). No cluster, o broker chegou a **~3.7k
  conexões** abertas antes da correção.
- **Correção (por serviço):** o `AddRabbitMQ` passa a usar uma **factory lazy** que cria **uma única**
  `IConnection` no primeiro uso (não bloqueia o startup — o processo sobe mesmo com o broker fora),
  a **reutiliza** em todas as checagens (com `AutomaticRecoveryEnabled`), a **recria** quando ela
  fica fechada (auto-recovery esgotado) via **double-checked locking** (`SemaphoreSlim`), e a
  descarta no shutdown. Não se usou `Lazy<Task<IConnection>>` porque ele cachearia uma `Task`
  falhada (broker fora na 1ª checagem) e prenderia o `/health/ready` em `503` mesmo após o broker
  voltar. Padrão **idêntico** entre os três serviços (paridade). Comportamento observável do
  readiness inalterado: `503` com o broker fora, `200` quando volta — agora **sem** crescimento de
  conexões.

### Modificado
- Imagens `:local` de `users-api`, `catalog-api` e `payments-api` rebuildadas e recarregadas no
  cluster (minikube) para materializar a correção. Nenhum manifesto k8s alterado — o contrato de
  probes (`/health/live` + `/health/ready`) permanece o mesmo; a mudança é interna ao app.

## [0.8.1] - 2026-07-12

### Corrigido
- **Probes do `payments-api` separados** (issue #21): `livenessProbe → /health/live` e
  `readinessProbe → /health/ready`, refletindo os health checks separados entregues em
  `payments-api#6`. Antes ambos apontavam para `/health` (agregado), o que fazia o **liveness**
  depender do RabbitMQ/Mongo — se uma dependência caísse, o pod entrava em restart loop em vez de
  apenas sair do readiness. Validado no cluster (pod `Ready`, `/health/live` e `/health/ready` = 200,
  fluxo cadastro→compra→Approved com o payments persistindo em `paymentsdb`).

## [0.8.0] - 2026-07-12

### Adicionado
- **MongoDB (`paymentsdb`) provisionado para o `payments-api`** (issue #17) — fundação para a
  persistência/idempotência do serviço (`payments-api#2`/`#1`). O `payments-api` deixa de ser
  "zero banco": ganha `MongoDbSettings__DatabaseName=paymentsdb` (ConfigMap) e
  `MongoDbSettings__ConnectionString` com `?replicaSet=rs0` (SealedSecret cifrado), no compose
  e no k8s, além do initContainer `wait-for-mongodb`. Config **aditiva** — consumida a partir da
  `payments-api#2`; comportamento atual inalterado. `database-per-service` preservado (reusa a
  instância `mongodb`, database lógico novo).

### Corrigido
- **Watermark de memória do RabbitMQ agressivo demais** (issue #19) — o `vm_memory_high_watermark.absolute`
  de `384MiB` (introduzido na v0.7.0) tripava o flow control sob acúmulo de filas/conexões, colocando
  as conexões em `blocked`/`blocking` e travando **todos os publishers sem auto-recuperação** (ex.: o
  `users-api` levava ~20s e retornava 500 ao publicar `UserCreatedEvent`). Subido para `576MiB`, com o
  limite de memória do k8s de `768Mi` → `1Gi` (request `512Mi`) — ~448Mi de folga acima do watermark,
  mantendo a proteção de OOM sem bloquear publishers em carga normal.

## [0.7.0] - 2026-07-12

### Adicionado
- **Imagem custom do RabbitMQ com o plugin `rabbitmq_delayed_message_exchange`** (`docker/rabbitmq/`:
  `rabbitmq:3.13.7-management` + plugin `v3.13.0`, com `--checksum` de integridade). É pré-requisito
  do **delayed redelivery** (second-level retry) do MassTransit no `catalog-api` (`catalog-api#4`):
  sem o plugin, o `UseDelayedMessageScheduler`/`UseDelayedRedelivery` quebraria o serviço em runtime.

### Modificado
- `docker-compose.yml`: o serviço `rabbitmq` passa a `build: ./docker/rabbitmq` + `image: fcg-rabbitmq:local`.
- `k8s/11-infra-rabbitmq.yaml`: `image: fcg-rabbitmq:local` + `imagePullPolicy: IfNotPresent`.
- **Hardening de memória do RabbitMQ** (evita `OOMKilled`): a imagem custom passa a definir
  `vm_memory_high_watermark.absolute = 384MiB` (`docker/rabbitmq/rabbitmq.conf`) para o broker
  aplicar flow control antes de estourar o limite do container. No k8s, o limite de memória subiu
  para `768Mi` (request `384Mi`) e o `livenessProbe` ganhou `timeoutSeconds: 10`/`failureThreshold: 3`
  (o `ping` estourava o timeout default de 1s sob carga, causando restart espúrio).
- `scripts/deploy-minikube.sh`: build + `minikube image load` da `fcg-rabbitmq:local`.
- `README.md`: nota sobre a imagem custom e o motivo do plugin.

### Nota de migração
- O deploy no cluster agora **constrói e carrega** a imagem `fcg-rabbitmq:local` (o `deploy-minikube.sh`
  faz isso). Mudança backward-compatible: o plugin presente não altera o uso atual do broker.

## [0.6.0] - 2026-07-12

### Adicionado
- **Ingress (NGINX)** para acesso HTTP externo aos serviços voltados ao usuário. Novo
  `k8s/30-ingress.yaml` (`fcg-ingress`, `ingressClassName: nginx`) com roteamento **por host**:
  `users.fcg.local → users-api:80` e `catalog.fcg.local → catalog-api:80` — substitui o
  `kubectl port-forward` manual por URLs estáveis. `payments-api` e `notifications-api` são
  orientados a eventos e **não** têm entrada HTTP externa (ficam de fora de propósito).
- `README.md`: seção **"Acesso externo via Ingress"** (habilitar o addon, `/etc/hosts`, o caveat
  do `minikube tunnel` no macOS + driver docker, e port-forward do controller como alternativa sem sudo).

### Modificado
- `scripts/deploy-minikube.sh`: habilita o **addon ingress** do minikube (idempotente) e aguarda o
  `ingress-nginx-controller` ficar pronto antes de seguir; dicas de acesso atualizadas para o Ingress.

### Nota técnica
- O Ingress **não** usa `nginx.ingress.kubernetes.io/rewrite-target`: com `path: /` sem capture group,
  o rewrite reescreveria toda requisição para `/`, quebrando rotas como `/api/v1/jogos`. O roteamento é
  por host e o path é passado **intacto** ao backend.
- Os `Service` permanecem **ClusterIP** — o Ingress é o único ponto de entrada HTTP externo; a
  comunicação interna segue pelos nomes de Service. Escopo HTTP local (sem TLS) para o ambiente de demo.

## [0.5.0] - 2026-07-12

### Adicionado
- **Sealed Secrets (Bitnami)** para gerenciar segredos no Kubernetes **sem versioná-los em texto claro**.
  Novo `k8s/05-sealed-secrets.yaml` com **5 `SealedSecret`s cifrados** (`rabbitmq-secret`, `users-api-secret`,
  `catalog-api-secret`, `payments-api-secret`, `notifications-api-secret`) — só o controller do cluster
  decifra; o arquivo cifrado é seguro para commit. O prefixo `05-` os aplica cedo, para o controller
  materializar os `Secret` antes de os Deployments subirem.
- **`scripts/seal-secrets.sh`** — helper que (re)gera/rotaciona os SealedSecrets a partir de valores de
  demonstração (sobrescrevíveis por variáveis de ambiente para segredos reais, que nunca são comitados) e
  garante a **JWT parity** (mesma `JwtSettings__SecretKey` em `users-api-secret` e `catalog-api-secret`).
- `README.md`: seção **"Segredos no Kubernetes — Sealed Secrets"** (instalação do controller, geração,
  rotação e o caveat da chave por-cluster).

### Modificado
- `scripts/deploy-minikube.sh`: instala o **controller Sealed Secrets** (versão **pinada** `v0.38.4`) e
  aguarda o rollout **antes** do `kubectl apply` — `kubectl apply` idempotente, reconciliando na versão pinada.
- `k8s/11/20/21/22/23-*.yaml`: removidos os blocos `kind: Secret` com `stringData` em claro; os `secretRef`
  seguem apontando para os mesmos nomes, agora materializados pelo controller.

### Removido
- Todos os `Secret` com valores sensíveis **em texto claro** dos manifestos versionados.

### Nota de migração
- O deploy no cluster agora **exige o controller Sealed Secrets** instalado. Em um cluster limpo, o
  `scripts/deploy-minikube.sh` cuida disso automaticamente; em um `kubectl apply -R -f k8s/` manual,
  instale o controller antes (ver README), senão os `Secret` não materializam e as APIs não sobem.
- A chave do controller é **por-cluster**: após `minikube delete`, reinstale o controller e rode
  `./scripts/seal-secrets.sh` para regenerar os SealedSecrets (os antigos deixam de decifrar).
- O `docker-compose` (dev local) **não muda** — Sealed Secrets é mecanismo específico de Kubernetes;
  os valores permanecem idênticos entre compose e k8s.

## [0.4.0] - 2026-07-12

### Adicionado
- **Primeiro pipeline de CI do repositório** (`.github/workflows/ci.yml`), disparado em **push na `main`**
  e em **todo pull request**. Valida a orquestração **sem subir cluster nem construir imagens**:
  - `docker compose -f docker-compose.yml config -q` — valida o compose (com `-f` explícito para ser
    **determinístico**, isolando o CI de um `docker-compose.override.yml` local gitignored).
  - `kubeconform -strict -ignore-missing-schemas` (versão **pinada** `v0.6.7`) — validação de schema
    **offline** e rigorosa dos manifestos `k8s/`, contra os schemas oficiais do Kubernetes.
  - `yamllint -d relaxed` — lint de estilo, **não-bloqueante** por enquanto.
- Rede de segurança para as próximas mudanças de infra (Ingress, Sealed Secrets), que são puro YAML novo:
  um erro de indentação ou campo inválido passa a **falhar o PR** antes do merge, não no `kubectl apply`.
- `README.md`: seção **"CI — validação de compose e manifestos"** + badge de status do workflow.

### Nota técnica
- O gate de k8s usa **`kubeconform`** (offline) em vez de `kubectl apply --dry-run=client`: apesar do
  nome, o dry-run "client" do kubectl moderno **não é offline** — exige _discovery_ do apiserver e o
  OpenAPI do cluster, falhando com `connection refused` no runner. O `kubeconform` faz a mesma
  validação de schema de forma totalmente offline e mais rigorosa. Guardrails do workflow:
  `permissions: contents: read` (least privilege) e `concurrency` para cancelar runs superados.

## [0.3.0] - 2026-07-11

### Adicionado
- MongoDB no Kubernetes agora roda como **single-node replica set (`rs0`)**, fechando a lacuna de
  paridade dev/prod com o `docker-compose.yml`. É pré-requisito do **outbox transacional** das APIs
  (transações multi-documento do Mongo exigem replica set) — sem isso, o cadastro de usuário
  funcionava no compose mas **quebrava** no cluster.
- `readinessProbe` no MongoDB que **inicia o replica set de forma idempotente** (mesmo `rs.initiate(...)`
  do healthcheck do compose) e só marca o Pod `Ready` quando o nó é **PRIMARY gravável**
  (`db.hello().isWritablePrimary`), evitando tráfego antes de o Mongo aceitar transações.

### Modificado
- `k8s/10-infra-mongodb.yaml`: o container sobe com `args: ["mongod", "--replSet", "rs0", "--bind_ip_all"]`
  — via `args` (não `command`) para **preservar o ENTRYPOINT** `docker-entrypoint.sh` da imagem
  (invocação byte-equivalente ao compose). O `Service` `mongodb` passou a **headless**
  (`clusterIP: None` + `publishNotReadyAddresses: true`) para dar DNS próprio ao Pod e permitir o
  `rs.initiate` antes de o Pod ficar `Ready`. O DNS interno e a porta 27017 são os mesmos.
- `k8s/20-users-api.yaml` e `k8s/21-catalog-api.yaml`: connection strings dos Secrets passam a usar
  `?replicaSet=rs0`.
- `README.md`: documenta o replica set `rs0` no k8s (paridade com o compose agora completa).

### Nota de migração
- Trocar o `Service` `mongodb` de `ClusterIP` para headless é uma mudança de campo **imutável**: em um
  cluster que já tenha o Service antigo, rode `kubectl delete svc mongodb` uma vez antes do `apply`
  (clusters novos criam headless direto).

## [0.2.0] - 2026-07-11

### Adicionado
- Persistência do MongoDB no Kubernetes via `StatefulSet` + `volumeClaimTemplates`,
  provisionando um `PersistentVolumeClaim` (`mongo-data-mongodb-0`, `2Gi`,
  `storageClassName: standard`). Os dados de `usersdb`/`catalogdb` passam a **sobreviver**
  à recriação do Pod (rollout, `kubectl delete pod`, reagendamento).
- Migração idempotente no `scripts/deploy-minikube.sh`: remoção do `Deployment` antigo do
  MongoDB (`delete --ignore-not-found`) antes do `apply`, já que `Deployment` e `StatefulSet`
  são `kind` distintos (no-op em cluster limpo).

### Modificado
- `k8s/10-infra-mongodb.yaml`: MongoDB migrado de `Deployment` com `emptyDir` para
  `StatefulSet` com PVC. O `Service` `mongodb` (ClusterIP, 27017) permanece idêntico, então
  as APIs seguem conectando por `mongodb://mongodb:27017` **sem mudança de config**.
- `scripts/deploy-minikube.sh`: `rollout status` do MongoDB passa a apontar para
  `statefulset/mongodb`.
- `README.md`: documenta a persistência do MongoDB, o comportamento do PVC no `undeploy` e o
  caveat de que a paridade com o `docker-compose.yml` ainda é parcial (o replica set `rs0`
  ainda não está nos manifestos k8s).

### Removido
- Volume `emptyDir` do MongoDB no Kubernetes (causa da perda de dados entre recriações do Pod).

[0.3.0]: https://github.com/fcg-grupo-16/orchestration/releases/tag/v0.3.0
[0.2.0]: https://github.com/fcg-grupo-16/orchestration/releases/tag/v0.2.0

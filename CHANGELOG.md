# Changelog

Todas as mudanças relevantes deste repositório de orquestração são documentadas aqui.

O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.0.0/)
e o versionamento adere a [Semantic Versioning](https://semver.org/lang/pt-BR/).

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

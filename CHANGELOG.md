# Changelog

Todas as mudanças relevantes deste repositório de orquestração são documentadas aqui.

O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.0.0/)
e o versionamento adere a [Semantic Versioning](https://semver.org/lang/pt-BR/).

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

[0.2.0]: https://github.com/fcg-grupo-16/orchestration/releases/tag/v0.2.0

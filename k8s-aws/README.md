# k8s-aws — manifestos que só existem no EKS

O que está aqui **substitui**, no cluster da AWS, uma parte de `k8s/` que só serve ao minikube. Por isso
o diretório fica fora de `k8s/`: o `kubectl apply -R -f k8s/` do `deploy-minikube.sh` não o aplica, e
o minikube não precisa do External Secrets.

| Arquivo | Substitui, no EKS |
|---|---|
| `00-cluster-secret-store.yaml` | o controller do Sealed Secrets |
| `10-external-secrets.yaml` | `k8s/05-sealed-secrets.yaml` e `k8s/gateway/39-kong-jwt-credential.yaml` |

O `scripts/deploy-eks.sh` aplica `k8s/` **sem** esses dois arquivos, e este diretório no lugar. Decisão e
motivo: [ADR 0011](../docs/adr/0011-segredos-secrets-manager-no-eks.md).

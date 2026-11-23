#!/usr/bin/env bash
# Derruba o ambiente da AWS (#62) na ORDEM que não deixa recurso órfão.
#
# No Learner Lab isto é obrigatório ao fim de cada dia de uso: o control plane do EKS e o Load
# Balancer cobram mesmo com a sessão encerrada, e estourar o orçamento APAGA A CONTA (ADR 0010).
#
# Por que não basta `terraform destroy`: o Load Balancer do Kong (#64) e os volumes EBS dos PVCs são
# criados PELO KUBERNETES, não pelo Terraform. Ele não sabe que existem. Se o cluster for destruído
# antes, o ELB e as ENIs dele seguram a VPC (o destroy trava em "DependencyViolation") e os volumes
# EBS ficam cobrando, órfãos.
#
# Há uma terceira armadilha, medida no primeiro destroy (2026-11-22): os objetos dos OPERADORES —
# ScaledObject e TriggerAuthentication do KEDA, ExternalSecret e ClusterSecretStore do External
# Secrets — têm *finalizers* que só o próprio operador remove. O `terraform destroy` desinstala os dois
# charts, o operador morre primeiro, as CRDs ficam presas esperando objetos que ninguém mais finaliza,
# e o helm estoura o tempo ("context deadline exceeded") com o cluster e a VPC ainda de pé, cobrando.
#
# Ordem:
#   1) Kong (helm uninstall): leva o Service LoadBalancer e, com ele, o NLB e as ENIs
#   2) objetos dos operadores, COM os operadores ainda rodando para finalizá-los
#   3) StatefulSets e PVCs (o driver CSI apaga os volumes EBS)
#   4) namespace fcg
#   5) terraform destroy
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"

CLUSTER=$(terraform -chdir="$TF_DIR" output -raw nome_cluster 2>/dev/null || true)
REGIAO=$(terraform -chdir="$TF_DIR" output -raw regiao 2>/dev/null || echo us-east-1)

if [ -n "$CLUSTER" ] && aws eks describe-cluster --name "$CLUSTER" --region "$REGIAO" > /dev/null 2>&1; then
  # Contexto EXPLÍCITO, nunca o atual: o atual pode ser o minikube, e aí os deletes abaixo
  # "funcionariam" no cluster errado enquanto o ELB da AWS continua lá.
  KUBECONFIG_TMP=$(mktemp)
  trap 'rm -f "$KUBECONFIG_TMP"' EXIT
  aws eks update-kubeconfig --name "$CLUSTER" --region "$REGIAO" --kubeconfig "$KUBECONFIG_TMP" > /dev/null
  K=(kubectl --kubeconfig "$KUBECONFIG_TMP")

  echo "==> 1/5 Removendo o Kong e o Load Balancer"
  if helm --kubeconfig "$KUBECONFIG_TMP" -n kong status kong > /dev/null 2>&1; then
    helm --kubeconfig "$KUBECONFIG_TMP" -n kong uninstall kong --wait --timeout 5m
  fi
  # Qualquer outro Service LoadBalancer que alguém tenha criado à mão segura a VPC do mesmo jeito.
  "${K[@]}" get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' |
    while read -r ns nome; do
      [ -n "$ns" ] && "${K[@]}" -n "$ns" delete svc "$nome" --wait=true
    done

  echo "==> 2/5 Removendo os objetos do KEDA e do External Secrets (com os operadores vivos)"
  for crd in scaledobjects.keda.sh triggerauthentications.keda.sh \
             externalsecrets.external-secrets.io clustersecretstores.external-secrets.io; do
    # Só se a CRD existe: num cluster parcial, `delete` de um tipo desconhecido aborta o script.
    if "${K[@]}" get crd "$crd" > /dev/null 2>&1; then
      "${K[@]}" delete "$crd" --all -A --wait=true --timeout=120s
    fi
  done

  echo "==> 3/5 Removendo StatefulSets e PVCs (o driver EBS CSI apaga os volumes)"
  # Os StatefulSets saem PRIMEIRO. PVC em uso por pod tem o finalizer `pvc-protection` e não some
  # enquanto o pod existir; com o StatefulSet vivo, o pod volta e o delete do PVC espera para sempre.
  "${K[@]}" delete statefulset --all -A --wait=true
  # PVC de volumeClaimTemplate sobrevive à remoção do StatefulSet: precisa sair explicitamente.
  "${K[@]}" delete pvc --all -A --wait=true
  # Espera os PVs sumirem: é a confirmação de que o CSI apagou os volumes na AWS. Com o driver
  # destruído antes disso, os volumes ficariam órfãos.
  for _ in $(seq 1 30); do
    [ -z "$("${K[@]}" get pv -o name 2>/dev/null)" ] && break
    sleep 10
  done
  if [ -n "$("${K[@]}" get pv -o name 2>/dev/null)" ]; then
    echo "ERRO: ainda há PersistentVolumes após 5 min. Confira antes de destruir o cluster:" >&2
    "${K[@]}" get pv >&2
    exit 1
  fi

  echo "==> 4/5 Removendo o namespace da plataforma"
  "${K[@]}" delete namespace fcg --ignore-not-found --wait=true --timeout=180s
else
  echo "==> Cluster não encontrado; pulando a limpeza dentro do Kubernetes"
fi

echo "==> 5/5 terraform destroy"
terraform -chdir="$TF_DIR" destroy "$@"

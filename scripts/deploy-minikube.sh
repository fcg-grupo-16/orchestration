#!/usr/bin/env bash
# Build das imagens dos 4 microsserviços, carga no minikube e deploy no cluster.
# Pré-requisitos: docker, minikube, kubectl.
# Uso: ./scripts/deploy-minikube.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PARENT_DIR="$(cd "$ROOT_DIR/.." && pwd)"
SERVICES=(users-api catalog-api payments-api notifications-api)

echo "==> Garantindo que o minikube está rodando"
minikube status >/dev/null 2>&1 || minikube start

echo "==> Build das imagens locais (:local)"
for svc in "${SERVICES[@]}"; do
  echo "   - $svc"
  docker build -t "${svc}:local" "$PARENT_DIR/${svc}"
done

echo "==> Carregando imagens no minikube"
for svc in "${SERVICES[@]}"; do
  minikube image load "${svc}:local"
done

echo "==> Migração Deployment→StatefulSet do MongoDB (kinds diferentes; no-op em cluster limpo)"
kubectl -n fcg delete deployment mongodb --ignore-not-found

echo "==> Aplicando manifestos (kubectl apply -R -f k8s/)"
kubectl apply -R -f "$ROOT_DIR/k8s/"

echo "==> Aguardando infra (RabbitMQ Deployment, MongoDB StatefulSet) e microsserviços ficarem prontos"
kubectl -n fcg rollout status deploy/rabbitmq --timeout=180s
kubectl -n fcg rollout status statefulset/mongodb --timeout=180s
for svc in "${SERVICES[@]}"; do
  kubectl -n fcg rollout status "deploy/${svc}" --timeout=180s
done

echo
echo "==> Pods:"
kubectl -n fcg get pods
echo
echo "Pronto. Exemplos de acesso:"
echo "  kubectl -n fcg port-forward svc/users-api 8081:80"
echo "  kubectl -n fcg port-forward svc/catalog-api 8082:80"
echo "  kubectl -n fcg port-forward svc/rabbitmq 15672:15672   # Management UI (guest/guest)"

#!/usr/bin/env bash
# (Re)gera k8s/05-sealed-secrets.yaml cifrando os Secrets da plataforma com kubeseal.
#
# Os VALORES abaixo são placeholders de DEMONSTRAÇÃO (idênticos aos que ficavam em claro
# nos manifestos). Para segredos REAIS, exporte as variáveis de ambiente correspondentes
# ANTES de rodar — assim os valores reais nunca são comitados neste script.
#
# Rotação: para trocar um valor, exporte a env var (ou edite o default de demo), rode este
# script e comite o k8s/05-sealed-secrets.yaml regenerado. O controller atualiza o Secret.
#
# Pré-requisitos:
#   - kubeseal instalado (brew install kubeseal)
#   - controller sealed-secrets rodando no cluster (namespace kube-system)
# Uso: ./scripts/seal-secrets.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/../k8s/05-sealed-secrets.yaml"
NS="fcg"
CONTROLLER_NS="kube-system"

# --- valores (placeholders de demo; sobrescreva via env para segredos reais) ---
# JwtSettings__SecretKey DEVE ser idêntica em users-api e catalog-api (o users emite o JWT,
# o catalog valida). Por isso é uma única variável, cifrada nos dois SealedSecrets.
JWT_SECRET_KEY="${JWT_SECRET_KEY:-FiapCloudGames_Demo_SecretKey_Com_Pelo_Menos_256_Bits_Para_HMAC_SHA256!}"
MONGO_USERS_CONN="${MONGO_USERS_CONN:-mongodb://mongodb:27017/?replicaSet=rs0}"
MONGO_CATALOG_CONN="${MONGO_CATALOG_CONN:-mongodb://mongodb:27017/?replicaSet=rs0}"
MONGO_PAYMENTS_CONN="${MONGO_PAYMENTS_CONN:-mongodb://mongodb:27017/?replicaSet=rs0}"
MONGO_NOTIFICATIONS_CONN="${MONGO_NOTIFICATIONS_CONN:-mongodb://mongodb:27017/?replicaSet=rs0}"
RABBIT_USER="${RABBIT_USER:-guest}"
RABBIT_PASS="${RABBIT_PASS:-guest}"

command -v kubeseal >/dev/null || { echo "ERRO: kubeseal não encontrado (brew install kubeseal)." >&2; exit 1; }
command -v kubectl  >/dev/null || { echo "ERRO: kubectl não encontrado." >&2; exit 1; }
kubectl -n "$CONTROLLER_NS" get deploy sealed-secrets-controller >/dev/null 2>&1 || {
  echo "ERRO: controller sealed-secrets não encontrado no namespace $CONTROLLER_NS." >&2
  echo "      Instale-o primeiro (ver scripts/deploy-minikube.sh ou o README)." >&2
  exit 1
}
# Aguarda o controller ficar pronto antes de selar: o kubeseal busca o cert público dele;
# se ainda não estiver Ready, o seal falharia de forma menos clara mais adiante.
kubectl -n "$CONTROLLER_NS" rollout status deploy/sealed-secrets-controller --timeout=120s >/dev/null

# seal <name> <label-app|""> <KEY=VALUE>...
#   gera um Secret em claro (dry-run, nunca aplicado), rotula e o cifra -> SealedSecret.
seal() {
  local name="$1" label_app="$2"; shift 2
  local args=()
  local kv
  for kv in "$@"; do args+=(--from-literal="$kv"); done
  local secret
  secret="$(kubectl create secret generic "$name" -n "$NS" "${args[@]}" --dry-run=client -o json)"
  if [ -n "$label_app" ]; then
    secret="$(printf '%s' "$secret" | kubectl label --local -f - -o json "app=$label_app")"
  fi
  printf '%s' "$secret" | kubeseal --controller-namespace "$CONTROLLER_NS" --format yaml --scope strict
}

{
  echo "# GERADO por scripts/seal-secrets.sh — NÃO editar à mão."
  echo "#"
  echo "# SealedSecrets cifrados (Bitnami Sealed Secrets). SEGUROS para versionar: apenas o"
  echo "# controller DESTE cluster (namespace $CONTROLLER_NS) consegue decifrá-los. Os valores"
  echo "# são de DEMONSTRAÇÃO. Para regenerar/rotacionar: ./scripts/seal-secrets.sh"
  echo "#"
  echo "# JwtSettings__SecretKey é IDÊNTICA em users-api-secret e catalog-api-secret (JWT parity)."
  seal rabbitmq-secret          ""                  "RABBITMQ_DEFAULT_USER=$RABBIT_USER" "RABBITMQ_DEFAULT_PASS=$RABBIT_PASS"
  seal users-api-secret         "users-api"         "MongoDbSettings__ConnectionString=$MONGO_USERS_CONN"  "JwtSettings__SecretKey=$JWT_SECRET_KEY" "RabbitMq__Username=$RABBIT_USER" "RabbitMq__Password=$RABBIT_PASS"
  seal catalog-api-secret       "catalog-api"       "MongoDbSettings__ConnectionString=$MONGO_CATALOG_CONN" "JwtSettings__SecretKey=$JWT_SECRET_KEY" "RabbitMq__Username=$RABBIT_USER" "RabbitMq__Password=$RABBIT_PASS"
  seal payments-api-secret      "payments-api"      "MongoDbSettings__ConnectionString=$MONGO_PAYMENTS_CONN" "RabbitMq__Username=$RABBIT_USER" "RabbitMq__Password=$RABBIT_PASS"
  seal notifications-api-secret "notifications-api" "MongoDbSettings__ConnectionString=$MONGO_NOTIFICATIONS_CONN" "RabbitMq__Username=$RABBIT_USER" "RabbitMq__Password=$RABBIT_PASS"
} > "$OUT"

# `|| true`: grep -c retorna exit 1 quando a contagem é 0, o que sob `set -e` encerraria o
# script mesmo tendo gerado o arquivo. Neutralizamos para reportar a contagem com segurança.
COUNT="$(grep -c 'kind: SealedSecret' "$OUT" || true)"
echo "OK: $OUT gerado ($COUNT SealedSecrets)."

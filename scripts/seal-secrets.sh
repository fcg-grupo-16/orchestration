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
RABBIT_USER="${RABBIT_USER:-guest}"
RABBIT_PASS="${RABBIT_PASS:-guest}"
RABBIT_HOST="${RABBIT_HOST:-rabbitmq}"
# A notifications-function (Fase 3) NÃO aceita host/usuário/senha separados: o binding
# RabbitMQTrigger da Azure Functions exige uma URI AMQP COMPLETA numa única app setting
# (desde a v2 da extensão), cujo NOME é referenciado pelo atributo
# [RabbitMQTrigger(..., ConnectionStringSetting = "RabbitMqConnection")].
# Registra se a conexão veio do AMBIENTE, antes de aplicar o default: serve para avisar sobre a
# armadilha de rotação logo abaixo.
RABBIT_CONNECTION_DO_ENV="${RABBIT_CONNECTION:+sim}"
RABBIT_CONNECTION="${RABBIT_CONNECTION:-amqp://${RABBIT_USER}:${RABBIT_PASS}@${RABBIT_HOST}:5672/}"

# Conexão com FQDN, EXCLUSIVA do scaler do KEDA.
#
# O KEDA resolve este host a partir do pod do OPERADOR, que roda no namespace `keda` — o nome curto
# `rabbitmq` NÃO resolve lá. Medido ao tentar reaproveitar a conexão dos serviços:
#   ScaledObject Ready=False  "error establishing connection to RabbitMQ:
#                              dial tcp: lookup rabbitmq on 10.96.0.10:53: no such host"
# `RABBIT_CONNECTION` acima continua com o nome curto de propósito: quem a consome (os serviços e a
# própria Function) roda dentro de `fcg`. São a MESMA credencial, com escopos de DNS diferentes.
# Só sufixa o namespace quando o host é um nome CURTO. Com RABBIT_HOST=broker.example.com a
# concatenação produziria `broker.example.com.fcg.svc.cluster.local`, que não resolve.
# Par do RABBIT_CONNECTION_DO_ENV acima. A primeira versão do aviso referenciava esta variável sem
# nunca atribuí-la, então o segundo teste era SEMPRE verdadeiro: avisava quem exportou as DUAS
# (fez certo) e ficava calado na divergência inversa. Medido em isolamento.
RABBIT_CONNECTION_FQDN_DO_ENV="${RABBIT_CONNECTION_FQDN:+sim}"

case "$RABBIT_HOST" in
  *.*|localhost) RABBIT_HOST_FQDN="$RABBIT_HOST" ;;
  *)             RABBIT_HOST_FQDN="${RABBIT_HOST}.${NS}.svc.cluster.local" ;;
esac
RABBIT_CONNECTION_FQDN="${RABBIT_CONNECTION_FQDN:-amqp://${RABBIT_USER}:${RABBIT_PASS}@${RABBIT_HOST_FQDN}:5672/}"

# ⚠️ ARMADILHA DE ROTAÇÃO: sobrescrever só uma das duas faz os segredos DIVERGIREM em silêncio, e o
# scaler do KEDA volta a falhar como no defeito original da #29. O caminho recomendado é sobrescrever
# RABBIT_USER/RABBIT_PASS/RABBIT_HOST, de onde as duas derivam.
# Avisa quando EXATAMENTE UMA das duas vier do ambiente — a divergência é simétrica, e a versão
# anterior só olhava um sentido (e, por causa do bug acima, olhava errado).
if { [ -n "$RABBIT_CONNECTION_DO_ENV" ] && [ -z "$RABBIT_CONNECTION_FQDN_DO_ENV" ]; } \
   || { [ -z "$RABBIT_CONNECTION_DO_ENV" ] && [ -n "$RABBIT_CONNECTION_FQDN_DO_ENV" ]; }; then
  echo "AVISO: só UMA das conexões do RabbitMQ veio do ambiente (RABBIT_CONNECTION=${RABBIT_CONNECTION_DO_ENV:-nao}, RABBIT_CONNECTION_FQDN=${RABBIT_CONNECTION_FQDN_DO_ENV:-nao})." >&2
  echo "       Os dois segredos vão DIVERGIR: o dos serviços e o do scaler do KEDA apontariam para" >&2
  echo "       credenciais diferentes, reincidindo no defeito original da #29." >&2
  echo "       Prefira exportar RABBIT_USER/RABBIT_PASS/RABBIT_HOST, de onde as duas derivam." >&2
fi
MONGO_FUNCTION_CONN="${MONGO_FUNCTION_CONN:-mongodb://mongodb:27017/?replicaSet=rs0}"
# Cache distribuído (issue #25). Uma instância para users-api e catalog-api; o isolamento entre
# eles é LÓGICO, por prefixo de chave (Redis__InstanceName, no ConfigMap de cada serviço).
REDIS_CONN="${REDIS_CONN:-redis:6379}"

# ⚠️ A notifications-function aponta para OUTRA instância, e a separação é a correção da issue #35.
# O Redis acima é cache: `allkeys-lru`, sem persistência. A chave de idempotência é escrita uma vez e
# lida nunca, então é sempre o dado mais frio de uma instância compartilhada — e o LRU a despeja
# primeiro (medido: 200 chaves viraram 2 sob tráfego normal de cache). O 12b é `noeviction` com AOF
# em volume persistente.
#
# NÃO aponte esta variável para `redis:6379` "para simplificar": isso reintroduz silenciosamente o
# caminho para e-mail duplicado, e nada no deploy acusaria.
REDIS_IDEMPOTENCIA_CONN="${REDIS_IDEMPOTENCIA_CONN:-redis-idempotencia:6379}"

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
  seal users-api-secret         "users-api"         "MongoDbSettings__ConnectionString=$MONGO_USERS_CONN" "Redis__ConnectionString=$REDIS_CONN"  "JwtSettings__SecretKey=$JWT_SECRET_KEY" "RabbitMq__Username=$RABBIT_USER" "RabbitMq__Password=$RABBIT_PASS"
  seal catalog-api-secret       "catalog-api"       "MongoDbSettings__ConnectionString=$MONGO_CATALOG_CONN" "Redis__ConnectionString=$REDIS_CONN" "JwtSettings__SecretKey=$JWT_SECRET_KEY" "RabbitMq__Username=$RABBIT_USER" "RabbitMq__Password=$RABBIT_PASS"
  seal payments-api-secret      "payments-api"      "MongoDbSettings__ConnectionString=$MONGO_PAYMENTS_CONN" "RabbitMq__Username=$RABBIT_USER" "RabbitMq__Password=$RABBIT_PASS"
  # Fase 3 — notifications-function (serverless). As chaves seguem a convenção de APP SETTINGS do
  # host de Azure Functions, não a de ASP.NET Core dos demais serviços: `RabbitMqConnection` é o
  # nome literal referenciado pelo atributo [RabbitMQTrigger(..., ConnectionStringSetting = ...)].
  # `Redis__ConnectionString` aponta para o Redis DEDICADO de idempotência (#35), não para o de cache.
  seal notifications-function-secret "notifications-function" "RabbitMqConnection=$RABBIT_CONNECTION" "MongoDbSettings__ConnectionString=$MONGO_FUNCTION_CONN" "Redis__ConnectionString=$REDIS_IDEMPOTENCIA_CONN"
  # Credencial do scaler do KEDA (#29). Chave `host` é o nome que o TriggerAuthentication espera.
  # Selada como as demais: a issue #29 propunha um Secret em TEXTO CLARO versionado, o que seria a
  # única credencial em claro do repositório.
  seal keda-rabbitmq-secret "notifications-function" "host=$RABBIT_CONNECTION_FQDN"
} > "$OUT"

# `|| true`: grep -c retorna exit 1 quando a contagem é 0, o que sob `set -e` encerraria o
# script mesmo tendo gerado o arquivo. Neutralizamos para reportar a contagem com segurança.
COUNT="$(grep -c 'kind: SealedSecret' "$OUT" || true)"
echo "OK: $OUT gerado ($COUNT SealedSecrets)."

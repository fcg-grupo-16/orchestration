# shellcheck shell=bash
# Valores e composição dos Secrets da plataforma — FONTE ÚNICA para os dois destinos:
#
#   scripts/seal-secrets.sh          -> SealedSecrets do minikube (k8s/05-sealed-secrets.yaml)
#   scripts/publicar-segredos-aws.sh -> AWS Secrets Manager, lido pelo External Secrets no EKS (#65)
#
# Existe para os dois não divergirem: a paridade tríplice do JWT e a separação da chave de serviço
# (ADR 0007) quebram em silêncio, com 401 no gateway, se um destino tiver um valor e o outro, outro.
#
# Os valores são placeholders de DEMONSTRAÇÃO. Para segredos REAIS, exporte as variáveis de ambiente
# correspondentes antes de rodar o script que importa este arquivo.
#
# Uso: `source` este arquivo e chame `segredos_da_plataforma <funcao>`. A função recebe, por Secret:
#   <nome do Secret> <label app, ou ""> <CHAVE=valor> [<CHAVE=valor>...]

# shellcheck disable=SC2034  # NS e as variáveis abaixo são lidas por quem importa este arquivo.
NS="${NS:-fcg}"

# --- valores (placeholders de demo; sobrescreva via env para segredos reais) ---
# JwtSettings__SecretKey DEVE ser idêntica em users-api e catalog-api (o users emite o JWT,
# o catalog valida). Por isso é uma única variável, cifrada nos dois SealedSecrets.
JWT_SECRET_KEY="${JWT_SECRET_KEY:-FiapCloudGames_Demo_SecretKey_Com_Pelo_Menos_256_Bits_Para_HMAC_SHA256!}"
# Chave de SERVIÇO-A-SERVIÇO (notifications-function#9). DEVE ser DIFERENTE da JWT_SECRET_KEY: a
# separação de privilégio depende disso, e o users-api recusa subir se as duas forem iguais. Quem
# tiver esta chave consegue apenas consultar o contato de um usuário; com a JWT_SECRET_KEY,
# conseguiria assinar um token de Administrador.
SERVICE_AUTH_SECRET_KEY="${SERVICE_AUTH_SECRET_KEY:-FiapCloudGames_Demo_ServiceKey_DISTINTA_Com_256_Bits_Para_HMAC_SHA256!}"
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

segredos_da_plataforma() {
  local registrar="$1"
  "$registrar" rabbitmq-secret          ""                  "RABBITMQ_DEFAULT_USER=$RABBIT_USER" "RABBITMQ_DEFAULT_PASS=$RABBIT_PASS"
  "$registrar" users-api-secret         "users-api"         "MongoDbSettings__ConnectionString=$MONGO_USERS_CONN" "Redis__ConnectionString=$REDIS_CONN"  "JwtSettings__SecretKey=$JWT_SECRET_KEY" "ServiceAuth__SecretKey=$SERVICE_AUTH_SECRET_KEY" "RabbitMq__Username=$RABBIT_USER" "RabbitMq__Password=$RABBIT_PASS"
  "$registrar" catalog-api-secret       "catalog-api"       "MongoDbSettings__ConnectionString=$MONGO_CATALOG_CONN" "Redis__ConnectionString=$REDIS_CONN" "JwtSettings__SecretKey=$JWT_SECRET_KEY" "RabbitMq__Username=$RABBIT_USER" "RabbitMq__Password=$RABBIT_PASS"
  "$registrar" payments-api-secret      "payments-api"      "MongoDbSettings__ConnectionString=$MONGO_PAYMENTS_CONN" "RabbitMq__Username=$RABBIT_USER" "RabbitMq__Password=$RABBIT_PASS"
  # Fase 3 — notifications-function (serverless). As chaves seguem a convenção de APP SETTINGS do
  # host de Azure Functions, não a de ASP.NET Core dos demais serviços: `RabbitMqConnection` é o
  # nome literal referenciado pelo atributo [RabbitMQTrigger(..., ConnectionStringSetting = ...)].
  # `Redis__ConnectionString` aponta para o Redis DEDICADO de idempotência (#35), não para o de cache.
  "$registrar" notifications-function-secret "notifications-function" "RabbitMqConnection=$RABBIT_CONNECTION" "MongoDbSettings__ConnectionString=$MONGO_FUNCTION_CONN" "Redis__ConnectionString=$REDIS_IDEMPOTENCIA_CONN" "ServiceAuth__SecretKey=$SERVICE_AUTH_SECRET_KEY"
  # Credencial do scaler do KEDA (#29). Chave `host` é o nome que o TriggerAuthentication espera.
  # Selada como as demais: a issue #29 propunha um Secret em TEXTO CLARO versionado, o que seria a
  # única credencial em claro do repositório.
  "$registrar" keda-rabbitmq-secret "notifications-function" "host=$RABBIT_CONNECTION_FQDN"
}

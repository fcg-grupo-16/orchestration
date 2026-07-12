#!/usr/bin/env bash
# Smoke test dos dois fluxos orientados a eventos, executado pela REDE INTERNA do
# docker-compose (nomes de serviço), conforme recomendado no CLAUDE.md — evita conflitos
# de porta no host (ex.: outro app ocupando a 8081).
#   Fluxo de cadastro:  POST usuário    -> UserCreatedEvent    -> NotificationsAPI (boas-vindas)
#   Fluxo de compra:    POST biblioteca -> OrderPlacedEvent    -> PaymentsAPI -> PaymentProcessedEvent
#                       -> CatalogAPI (grava biblioteca) + NotificationsAPI (confirmação)
# Requer: 'docker compose up -d' já em execução (jq/curl rodam dentro de um container efêmero).
# Overrides opcionais: FCG_NETWORK, USERS_URL, CATALOG_URL.
set -euo pipefail

NETWORK="${FCG_NETWORK:-fcg_default}"
USERS_URL="${USERS_URL:-http://users-api:8080}"
CATALOG_URL="${CATALOG_URL:-http://catalog-api:8080}"

if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "ERRO: rede docker '$NETWORK' não encontrada." >&2
  echo "      Suba a stack com 'docker compose up -d' (ou defina FCG_NETWORK)." >&2
  exit 1
fi

docker run --rm -i --network "$NETWORK" \
  -e USERS_URL="$USERS_URL" -e CATALOG_URL="$CATALOG_URL" \
  alpine sh -s <<'INNER'
set -eu
apk add --no-cache curl jq >/dev/null 2>&1

EMAIL="player_$(date +%s)@fcg.com"
SENHA="Player@123456"

echo "==> 1) Cadastrando usuário ($EMAIL)  [fluxo cadastro -> UserCreatedEvent]"
curl -fsS -X POST "$USERS_URL/api/v1/usuarios" \
  -H 'Content-Type: application/json' \
  -d "{\"nome\":\"Player Demo\",\"email\":\"$EMAIL\",\"senha\":\"$SENHA\"}" | jq .

echo "==> 2) Login para obter o token JWT"
TOKEN=$(curl -fsS -X POST "$USERS_URL/api/v1/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"senha\":\"$SENHA\"}" | jq -r .token)
echo "    token: $(echo "$TOKEN" | cut -c1-24)..."

echo "==> 3) Listando jogos do catálogo (seed)"
JOGO_ID=$(curl -fsS "$CATALOG_URL/api/v1/jogos" | jq -r '.itens[0].id')
echo "    primeiro jogoId: $JOGO_ID"

echo "==> 4) Iniciando compra (deve retornar 202 Accepted com o orderId no corpo)  [fluxo compra -> OrderPlacedEvent]"
RESP=$(curl -fsS -w '\n%{http_code}' -X POST "$CATALOG_URL/api/v1/biblioteca" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"jogoId\":\"$JOGO_ID\"}")
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
echo "    HTTP $CODE | body: $BODY"
ORDER_ID=$(echo "$BODY" | jq -r .orderId)

echo "==> 5) Aguardando processamento assíncrono do pagamento (8s)"
sleep 8

echo "==> 6) Status do pedido (deve estar 'Approved' se Price <= MaxApprovedAmount)"
curl -fsS "$CATALOG_URL/api/v1/pedidos/$ORDER_ID" -H "Authorization: Bearer $TOKEN" | jq -c '{orderId, status}'

echo "==> 7) Biblioteca do usuário (jogo deve aparecer se aprovado)"
curl -fsS "$CATALOG_URL/api/v1/biblioteca" -H "Authorization: Bearer $TOKEN" | jq .
INNER

echo
echo "Dica: veja os e-mails simulados e a decisão de pagamento nos logs:"
echo "  docker compose logs notifications-api payments-api"

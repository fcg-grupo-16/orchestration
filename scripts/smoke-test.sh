#!/usr/bin/env bash
# Smoke test dos dois fluxos orientados a eventos, via portas expostas pelo docker-compose.
#   Fluxo de cadastro:  POST usuário -> UserCreatedEvent -> NotificationsAPI (e-mail boas-vindas)
#   Fluxo de compra:    POST biblioteca -> OrderPlacedEvent -> PaymentsAPI -> PaymentProcessedEvent
#                       -> CatalogAPI (grava biblioteca) + NotificationsAPI (e-mail confirmação)
# Requer: docker compose up já em execução; 'jq' instalado.
set -euo pipefail

USERS="http://localhost:8081"
CATALOG="http://localhost:8082"
EMAIL="player_$(date +%s)@fcg.com"
SENHA="Player@123456"

echo "==> 1) Cadastrando usuário ($EMAIL)"
curl -fsS -X POST "$USERS/api/v1/usuarios" \
  -H 'Content-Type: application/json' \
  -d "{\"nome\":\"Player Demo\",\"email\":\"$EMAIL\",\"senha\":\"$SENHA\"}" | jq .

echo "==> 2) Login para obter o token JWT"
TOKEN=$(curl -fsS -X POST "$USERS/api/v1/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"senha\":\"$SENHA\"}" | jq -r .token)
echo "    token: ${TOKEN:0:24}..."

echo "==> 3) Listando jogos do catálogo (seed)"
JOGO_ID=$(curl -fsS "$CATALOG/api/v1/jogos" | jq -r '.itens[0].id')
echo "    primeiro jogoId: $JOGO_ID"

echo "==> 4) Iniciando compra (deve retornar 202 Accepted)"
curl -fsS -o /dev/null -w "    HTTP %{http_code}\n" -X POST "$CATALOG/api/v1/biblioteca" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"jogoId\":\"$JOGO_ID\"}"

echo "==> 5) Aguardando processamento assíncrono do pagamento (6s)"
sleep 6

echo "==> 6) Conferindo a biblioteca do usuário (jogo deve aparecer se aprovado)"
curl -fsS "$CATALOG/api/v1/biblioteca" -H "Authorization: Bearer $TOKEN" | jq .

echo
echo "Dica: veja os e-mails simulados e a decisão de pagamento nos logs:"
echo "  docker compose logs notifications-api payments-api"

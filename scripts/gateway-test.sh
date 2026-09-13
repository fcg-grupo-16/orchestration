#!/usr/bin/env bash
# Matriz de aceite do API Gateway (issue #26) contra o cluster.
#
# Por que este script existe: o `kubeconform` do CI NÃO valida os CRDs do Kong (KongPlugin e
# KongConsumer são pulados por falta de schema), então um campo errado num plugin passa verde no
# pipeline. Pior, o modo de falha engana — o gateway devolve 401 sem token (parece funcionar) e
# devolve 401 TAMBÉM com token válido. A única validação real é comportamental, contra um cluster.
#
# Uso: ./scripts/gateway-test.sh     (requer o cluster com a plataforma e o Kong implantados)
set -euo pipefail

GW_PORT="${GW_PORT:-8000}"
GW="http://localhost:${GW_PORT}"
HOSTH="Host: api.fcg.local"
FALHAS=0

for bin in kubectl curl jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERRO: '$bin' não encontrado." >&2; exit 1; }
done

PF=""
cleanup() { [ -n "$PF" ] && kill "$PF" 2>/dev/null || true; }
trap cleanup EXIT

echo "==> Abrindo o proxy do Kong em :${GW_PORT}"
kubectl -n kong port-forward "svc/kong-kong-proxy" "${GW_PORT}:80" >/tmp/gateway-test-pf.log 2>&1 &
PF=$!
for _ in $(seq 1 30); do curl -s -o /dev/null "$GW" && break; sleep 1; done

check() { # nome, esperado, obtido
  if [ "$2" = "$3" ]; then printf "  OK   %-46s %s\n" "$1" "$3"
  else printf "  FALHA %-45s esperado=%s obtido=%s\n" "$1" "$2" "$3"; FALHAS=$((FALHAS+1)); fi
}

code() { curl -s -o /dev/null -w '%{http_code}' -H "$HOSTH" "$@"; }

echo "==> Matriz"
check "1. sem token -> 401" 401 "$(code "$GW/api/v1/jogos")"
check "2. token invalido -> 401" 401 "$(code -H 'Authorization: Bearer lixo' "$GW/api/v1/jogos")"

# O 401 tem de vir do KONG, não do serviço — os dois devolvem 401 e confundi-los seria declarar
# validação de borda inexistente.
SRV=$(curl -si -H "$HOSTH" "$GW/api/v1/jogos" | tr -d '\r' | awk 'tolower($1)=="server:"{print $2}')
case "$SRV" in kong/*) printf "  OK   %-46s %s\n" "3. o 401 vem do Kong" "$SRV";;
  *) printf "  FALHA %-45s server=%s (esperado kong/*)\n" "3. o 401 vem do Kong" "${SRV:-vazio}"; FALHAS=$((FALHAS+1));; esac

printf '{"email":"admin@fcg.com","senha":"Admin@123456"}' > /tmp/gw-login.json
TOKEN=$(curl -s -H "$HOSTH" -H 'Content-Type: application/json' --data-binary @/tmp/gw-login.json \
  "$GW/api/v1/auth/login" | jq -r '.token // empty')
[ -n "$TOKEN" ] && printf "  OK   %-46s 200\n" "4. login publico -> token" \
  || { printf "  FALHA %-45s sem token\n" "4. login publico"; FALHAS=$((FALHAS+1)); }

check "5. com token -> 200" 200 "$(code -H "Authorization: Bearer $TOKEN" "$GW/api/v1/jogos")"

EMAIL="gw-$(date +%s)-$RANDOM@fcg.com"
printf '{"nome":"Gateway Teste","email":"%s","senha":"Teste@123456"}' "$EMAIL" > /tmp/gw-signup.json
check "6. cadastro publico (POST) -> 201" 201 \
  "$(code -H 'Content-Type: application/json' --data-binary @/tmp/gw-signup.json "$GW/api/v1/usuarios")"
check "7. GET usuarios sem token -> 401" 401 "$(code "$GW/api/v1/usuarios")"
check "8. /health nao exposto -> 404" 404 "$(code -H "Authorization: Bearer $TOKEN" "$GW/health")"

RL=$(curl -si -H "$HOSTH" -H "Authorization: Bearer $TOKEN" "$GW/api/v1/jogos" | grep -ic ratelimit || true)
[ "$RL" -gt 0 ] && printf "  OK   %-46s %s headers\n" "9. headers RateLimit-*" "$RL" \
  || { printf "  FALHA %-45s nenhum header RateLimit\n" "9. headers RateLimit-*"; FALHAS=$((FALHAS+1)); }

# ---- O teste que pega o defeito que o resto da matriz NÃO pega ----
# Precisa de DOIS IPs de origem distintos. Motivo: com `limit_by: ip`, dois tokens enviados da
# mesma máquina (pelo mesmo port-forward) chegam ao Kong com o MESMO IP e compartilham a cota —
# comportamento CORRETO, que um teste ingênuo confunde com contador global.
#
# Uma versão anterior deste teste usava dois tokens da mesma origem e acusava falha num sistema
# correto. E a matriz de token único, antes dela, aprovava um sistema com bucket global de verdade
# (`limit_by: consumer`, onde todo token casa com o mesmo KongConsumer porque todos têm
# `iss: FiapCloudGames`). Nenhum dos dois discriminava; dois pods discriminam.
echo "==> Isolamento do rate limit (dois pods, IPs distintos)"
URL_INT="http://kong-kong-proxy.kong.svc.cluster.local:80/api/v1/jogos"
POD_IMG="curlimages/curl:8.11.1"

# Pod A esgota a cota do PRÓPRIO IP.
A_OUT=$(kubectl -n fcg run rl-a-$$ --rm -i --restart=Never --image="$POD_IMG" --quiet \
  --env="TK=$TOKEN" -- sh -c "
    for i in \$(seq 1 140); do
      curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: api.fcg.local' \
        -H \"Authorization: Bearer \$TK\" $URL_INT
    done | sort | uniq -c
  " 2>/dev/null || true)
echo "$A_OUT" | sed 's/^/     pod A: /'

# Pod B: IP diferente, UMA requisição. Tem de passar.
B_CODE=$(kubectl -n fcg run rl-b-$$ --rm -i --restart=Never --image="$POD_IMG" --quiet \
  --env="TK=$TOKEN" -- sh -c "
    curl -s -o /dev/null -w '%{http_code}' -H 'Host: api.fcg.local' \
      -H \"Authorization: Bearer \$TK\" $URL_INT
  " 2>/dev/null | tr -d '[:space:]' || true)

if echo "$A_OUT" | grep -q 429; then
  printf "  OK   %-46s cota do IP A esgotada\n" "10a. limite aplicado por IP"
else
  printf "  FALHA %-45s pod A nunca recebeu 429\n" "10a. limite aplicado por IP"; FALHAS=$((FALHAS+1))
fi

if [ "$B_CODE" = "200" ]; then
  printf "  OK   %-46s pod B (outro IP): 200\n" "10b. isolamento entre IPs"
else
  printf "  FALHA %-45s pod B (outro IP): %s -> contador GLOBAL\n" "10b. isolamento entre IPs" "${B_CODE:-vazio}"
  FALHAS=$((FALHAS+1))
fi

echo
if [ "$FALHAS" -eq 0 ]; then echo "Matriz do gateway: TODOS os testes passaram."; else
  echo "Matriz do gateway: $FALHAS teste(s) FALHARAM."; exit 1; fi

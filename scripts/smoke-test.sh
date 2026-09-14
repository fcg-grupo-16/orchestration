#!/usr/bin/env bash
# Smoke test dos fluxos da plataforma FCG, nos DOIS ambientes.
#
#   ./scripts/smoke-test.sh                  # MODO=compose (padrão): valida o CÓDIGO
#   MODO=gateway ./scripts/smoke-test.sh     # valida GATEWAY + roteamento + JWT no cluster
#
# ⚠️ Os dois modos NÃO rodam no mesmo lugar, e isso é deliberado:
#   • compose  -> as asserções rodam DENTRO de um container efêmero na rede do compose, usando os
#                 NOMES DE SERVIÇO (http://users-api:8080), que são estáveis. Assim o teste não
#                 depende das portas publicadas no host, que o docker-compose.override.yml
#                 (gitignored) remapeia por máquina.
#   • gateway  -> rodam no HOST, contra o port-forward do Kong, porque é o host que tem o
#                 port-forward aberto. Antes: kubectl -n kong port-forward svc/kong-kong-proxy 8000:80
#
# O corpo das asserções é UM só (gerado abaixo), executado nos dois contextos.
# Requer: curl e jq (no modo gateway, no host; no modo compose, instalados no container).
set -euo pipefail

MODO="${MODO:-compose}"
FALHAS=0
TMPD="$(mktemp -d)"
EMAIL="smoke-$(date +%s)-$$@fcg.com"
SENHA="Player@123456"

case "$MODO" in
  compose)
    NETWORK="${FCG_NETWORK:-fcg_default}"
    USERS_BASE="${USERS_URL:-http://users-api:8080}"
    CATALOG_BASE="${CATALOG_URL:-http://catalog-api:8080}"
    HOSTH=""
    # Endereços vistos do HOST (para os casos 8 e 9, que não rodam dentro do container).
    CATALOG_HOST="${CATALOG_HOST_URL:-http://localhost:8082}"
    docker network inspect "$NETWORK" >/dev/null 2>&1 || {
      echo "ERRO: rede docker '$NETWORK' não encontrada. Suba com 'docker compose up -d'." >&2; exit 1; }
    echo "==> Modo COMPOSE (rede $NETWORK; asserções dentro de um container)"
    ;;
  gateway)
    GW="${GATEWAY_URL:-http://localhost:8000}"
    USERS_BASE="$GW"; CATALOG_BASE="$GW"
    HOSTH="api.fcg.local"
    CATALOG_HOST=""   # no cluster o /metrics não passa pelo gateway; usa port-forward (caso 9)
    for bin in curl jq kubectl; do
      command -v "$bin" >/dev/null 2>&1 || { echo "ERRO: '$bin' não encontrado." >&2; exit 1; }
    done
    curl -sf -o /dev/null -H "Host: $HOSTH" "$GW/api/v1/jogos" 2>/dev/null || true
    if ! curl -s -o /dev/null -H "Host: $HOSTH" --max-time 5 "$GW/api/v1/jogos"; then
      echo "ERRO: $GW não responde. Abra o proxy:" >&2
      echo "      kubectl -n kong port-forward svc/kong-kong-proxy 8000:80" >&2
      exit 1
    fi
    echo "==> Modo GATEWAY ($GW, Host: $HOSTH)"
    ;;
  *)
    echo "ERRO: MODO='$MODO' inválido (use 'compose' ou 'gateway')." >&2; exit 1 ;;
esac

# Executa uma expressão no Mongo do ambiente corrente. Usado só pela limpeza.
mongo_eval() {
  if [ "$MODO" = "gateway" ]; then
    kubectl -n fcg exec mongodb-0 -- mongosh --quiet "$1" --eval "$2" 2>/dev/null
  else
    docker compose exec -T mongodb mongosh --quiet "$1" --eval "$2" 2>/dev/null
  fi
}

# Este teste GRAVA dados reais (conta, avaliação, pedido). Sem limpeza, cada execução deixaria
# resíduo permanente — foi exatamente o que aconteceu com o gateway-test.sh antes da #26 (5 contas
# e 34 refresh_tokens acumulados). Não-fatal: limpeza falha não invalida o resultado do teste.
limpar() {
  rm -rf "$TMPD"
  mongo_eval usersdb "var u=db.usuarios.findOne({Email:'$EMAIL'},{_id:1});
     if (u) { db.refresh_tokens.deleteMany({UsuarioId:u._id}); db.usuarios.deleteOne({_id:u._id}); }" \
    >/dev/null 2>&1 || echo "  AVISO: não consegui limpar o resíduo de $EMAIL" >&2
  if [ -n "${AVALIACAO_ID:-}" ]; then
    # ⚠️ `_id` da avaliação é ObjectId, NÃO string. `deleteOne({_id:'<hex>'})` não casa nada e sai
    # 0 — a limpeza PARECIA funcionar e vazava uma avaliação por execução (medido: a coleção foi de
    # 2 para 3 numa execução "limpa"). É o mesmo vazamento silencioso que o gateway-test.sh teve.
    mongo_eval catalogdb "db.avaliacoes.deleteOne({_id: ObjectId('$AVALIACAO_ID')});" >/dev/null 2>&1 \
      || echo "  AVISO: não consegui limpar a avaliação $AVALIACAO_ID" >&2
  fi
  return 0
}
trap limpar EXIT

# ---------------------------------------------------------------------------------------------
# Corpo das asserções (casos 1 a 7). POSIX sh: no modo compose ele roda no `sh` do Alpine.
#
# ⚠️ NENHUMA atribuição aqui usa `VAR=$(curl ... | jq ...)`. O `sh` do Alpine não tem `pipefail`,
# então num pipeline o status é o do ÚLTIMO comando: se o curl falhasse, o jq receberia entrada
# vazia, imprimiria "null" e sairia 0 — a variável ficaria com "null" e o teste seguiria em frente
# reportando sucesso. Era assim que as 4 atribuições da versão anterior deste script funcionavam.
# O padrão correto está em `req()`: captura corpo e código, ASSERTA o código, e só então extrai.
# ---------------------------------------------------------------------------------------------
cat > "$TMPD/casos.sh" <<'INNER'
set -eu
FALHAS=0
ok()    { echo "  [OK]     $1${2:+ ($2)}"; }
falha() { echo "  [FALHA]  $1"; FALHAS=$((FALHAS+1)); }
esperado() { # <descricao> <esperado> <obtido>
  if [ "$3" = "$2" ]; then
    ok "$1" "$3"
  else
    falha "$1 — esperado $2, obtido $3"
    # Sem o corpo, um 000/4xx vira adivinhação. Truncado para não afogar o relatório.
    [ -n "${RESP_BODY:-}" ] && echo "           corpo: $(printf '%s' "$RESP_BODY" | head -c 200)"
  fi
}

H() { [ -n "${HOSTH:-}" ] && printf '%s' "Host: $HOSTH" || printf 'X-Smoke: 1'; }

# req <metodo> <url> [corpo json] -> define RESP_CODE e RESP_BODY. NUNCA usa pipe na atribuição.
req() {
  m="$1"; u="$2"; b="${3:-}"
  # ⚠️ O `if ! ...` NÃO é decorativo. Sob `set -e`, uma falha de CONEXÃO (curl sai 7) mataria o
  # script AQUI, antes de registrar qualquer coisa — e o relatório sairia sem nenhum diagnóstico,
  # só com o sentinela de "não consegui ler o placar". Medido: apontando o catálogo para uma porta
  # morta, o teste reprovava (certo) sem dizer por quê (errado). Capturado, vira código 000 e a
  # asserção normal reporta "esperado 201, obtido 000" com o erro do curl no corpo.
  if [ -n "$b" ]; then
    bruto="$(curl -sS -X "$m" "$u" -H "$(H)" -H 'Content-Type: application/json' \
             ${TOKEN:+-H "Authorization: Bearer $TOKEN"} -d "$b" -w '\n%{http_code}' 2>&1)" || bruto=""
  else
    bruto="$(curl -sS -X "$m" "$u" -H "$(H)" \
             ${TOKEN:+-H "Authorization: Bearer $TOKEN"} -w '\n%{http_code}' 2>&1)" || bruto=""
  fi
  if [ -z "$bruto" ]; then
    RESP_CODE="000"; RESP_BODY="curl falhou ao conectar em $u"
    return 0
  fi
  RESP_CODE="$(printf '%s' "$bruto" | tail -n1)"
  RESP_BODY="$(printf '%s' "$bruto" | sed '$d')"
  # Curl que falha por conexão não imprime código; o -w não chega a rodar e a última linha é a
  # mensagem de erro. Normaliza para 000 em vez de deixar a asserção comparar com texto.
  case "$RESP_CODE" in
    ''|*[!0-9]*) RESP_BODY="$bruto"; RESP_CODE="000" ;;
  esac
}

TOKEN=""

if [ "$MODO" = "gateway" ]; then
  echo "==> [1] Gateway rejeita sem token"
  req GET "$CATALOG_BASE/api/v1/jogos"
  esperado "1. GET /api/v1/jogos sem token -> 401" 401 "$RESP_CODE"
else
  echo "==> [1] (pulado: o compose não tem gateway; o catálogo é anônimo no serviço)"
fi

echo "==> [2] Cadastro (publica UserCreatedEvent)"
req POST "$USERS_BASE/api/v1/usuarios" \
  "{\"nome\":\"Smoke Test\",\"email\":\"$EMAIL\",\"senha\":\"$SENHA\"}"
esperado "2. POST /api/v1/usuarios -> 201" 201 "$RESP_CODE"

echo "==> [3] Login"
req POST "$USERS_BASE/api/v1/auth/login" "{\"email\":\"$EMAIL\",\"senha\":\"$SENHA\"}"
esperado "3. POST /api/v1/auth/login -> 200" 200 "$RESP_CODE"
if [ "$RESP_CODE" = "200" ]; then
  TOKEN="$(printf '%s' "$RESP_BODY" | jq -re .token)" || { falha "3b. token ausente na resposta"; TOKEN=""; }
fi
[ -n "$TOKEN" ] || { echo "  sem token: os casos seguintes não podem rodar"; echo "$FALHAS" > /tmp/smoke.falhas; exit 1; }

echo "==> [4] Catálogo com token"
req GET "$CATALOG_BASE/api/v1/jogos"
esperado "4. GET /api/v1/jogos com token -> 200" 200 "$RESP_CODE"
JOGO_ID=""
if [ "$RESP_CODE" = "200" ]; then
  JOGO_ID="$(printf '%s' "$RESP_BODY" | jq -re '.itens[0].id')" || falha "4b. catálogo sem jogos (seed não rodou?)"
fi

if [ -n "$JOGO_ID" ]; then
  echo "==> [5] Compra (publica OrderPlacedEvent)"
  req POST "$CATALOG_BASE/api/v1/biblioteca" "{\"jogoId\":\"$JOGO_ID\"}"
  esperado "5. POST /api/v1/biblioteca -> 202" 202 "$RESP_CODE"
  ORDER_ID=""
  [ "$RESP_CODE" = "202" ] && ORDER_ID="$(printf '%s' "$RESP_BODY" | jq -re .orderId)" || true

  if [ -n "$ORDER_ID" ]; then
    echo "==> [6] Pedido chega ao fim (payments-api consome e responde)"
    STATUS="Pending"; LIMITE=$(( $(date +%s) + 30 ))
    while [ "$(date +%s)" -lt "$LIMITE" ]; do
      req GET "$CATALOG_BASE/api/v1/pedidos/$ORDER_ID"
      [ "$RESP_CODE" = "200" ] || { sleep 2; continue; }
      STATUS="$(printf '%s' "$RESP_BODY" | jq -re .status)" || STATUS="?"
      [ "$STATUS" != "Pending" ] && break
      sleep 2
    done
    if [ "$STATUS" != "Pending" ] && [ "$STATUS" != "?" ]; then
      ok "6. pedido saiu de Pending" "$STATUS"
    else
      falha "6. pedido continuou 'Pending' após 30s (o payments-api está consumindo?)"
    fi
  fi

  echo "==> [7] NoSQL: avaliação em documento flexível"
  # O controller inteiro é [Authorize]: sem token daria 401 e o caso não provaria o NoSQL.
  req POST "$CATALOG_BASE/api/v1/avaliacoes" \
    "{\"jogoId\":\"$JOGO_ID\",\"nota\":5,\"comentario\":\"smoke test\",\"titulo\":\"ok\",\"contexto\":{\"plataforma\":\"PC\"}}"
  esperado "7. POST /api/v1/avaliacoes -> 201" 201 "$RESP_CODE"
  if [ "$RESP_CODE" = "201" ]; then
    printf '%s' "$RESP_BODY" | jq -re .id > /tmp/smoke.avaliacao 2>/dev/null || true
  fi
  req GET "$CATALOG_BASE/api/v1/jogos/$JOGO_ID/avaliacoes/resumo"
  esperado "7b. GET .../avaliacoes/resumo -> 200" 200 "$RESP_CODE"
  if [ "$RESP_CODE" = "200" ]; then
    if printf '%s' "$RESP_BODY" | jq -e 'has("mediaNota")' >/dev/null 2>&1; then
      ok "7c. resumo agregado traz mediaNota"
    else
      falha "7c. resumo sem o campo mediaNota"
    fi
  fi
fi

echo "$FALHAS" > /tmp/smoke.falhas
INNER

# --- executa o corpo no contexto certo -------------------------------------------------------
if [ "$MODO" = "compose" ]; then
  SAIDA="$(docker run --rm -i --network "$NETWORK" \
    -e MODO="$MODO" -e USERS_BASE="$USERS_BASE" -e CATALOG_BASE="$CATALOG_BASE" \
    -e HOSTH="$HOSTH" -e EMAIL="$EMAIL" -e SENHA="$SENHA" \
    alpine sh -c 'apk add --no-cache curl jq >/dev/null 2>&1; sh -s; echo "FALHAS=$(cat /tmp/smoke.falhas 2>/dev/null || echo 99)"; cat /tmp/smoke.avaliacao 2>/dev/null | sed "s/^/AVALIACAO=/"' \
    < "$TMPD/casos.sh")" || true
else
  export MODO USERS_BASE CATALOG_BASE HOSTH EMAIL SENHA
  SAIDA="$(sh "$TMPD/casos.sh" 2>&1; echo "FALHAS=$(cat /tmp/smoke.falhas 2>/dev/null || echo 99)"; \
           [ -f /tmp/smoke.avaliacao ] && sed 's/^/AVALIACAO=/' /tmp/smoke.avaliacao || true)" || true
fi
# ⚠️ Os `|| true` e o `:-99` não são zelo — protegem justamente o CAMINHO DE FALHA, e os dois
# riscos aqui têm modos de falha OPOSTOS (ambos medidos):
#   • se o corpo morrer antes de imprimir qualquer caso, $SAIDA fica só com as linhas de placar; o
#     `grep -v` não casa nada, sai 1, o `pipefail` propaga e o `set -e` MATA o script aqui, sem
#     relatório nenhum;
#   • já sem linha `FALHAS=`, a aritmética vira `$(( FALHAS + ))` — e isso NÃO mata o script: o
#     bash imprime "arithmetic syntax error", segue adiante e deixa `FALHAS=0`. Uma execução que
#     falhou seria reportada como SUCESSO, com exit 0. É o pior dos dois.
echo "$SAIDA" | grep -v '^FALHAS=\|^AVALIACAO=' || true
PLACAR="$(echo "$SAIDA" | sed -n 's/^FALHAS=//p' | tail -1)"
FALHAS=$(( FALHAS + ${PLACAR:-99} ))
AVALIACAO_ID="$(echo "$SAIDA" | sed -n 's/^AVALIACAO=//p' | tail -1 || true)"
rm -f /tmp/smoke.falhas /tmp/smoke.avaliacao

# --- casos 8 e 9: fora do container, porque dependem do ambiente, não da API ------------------
echo "==> [8] Cache distribuído (Redis)"
# Sem asserção de TEMPO: em máquina de dev a variância engole a diferença e o teste ficaria flaky.
# A prova objetiva é a chave existir com o prefixo configurado (Redis__InstanceName "fcg:catalog:").
if [ "$MODO" = "gateway" ]; then
  CHAVES="$(kubectl -n fcg exec deploy/redis -- redis-cli --scan --pattern 'fcg:catalog:*' 2>/dev/null | tr -d '\r' | grep -c . || true)"
else
  CHAVES="$(docker compose exec -T redis redis-cli --scan --pattern 'fcg:catalog:*' 2>/dev/null | tr -d '\r' | grep -c . || true)"
fi
if [ "${CHAVES:-0}" -gt 0 ]; then
  echo "  [OK]     8. cache povoado (${CHAVES} chave(s) fcg:catalog:*)"
else
  echo "  [FALHA]  8. nenhuma chave fcg:catalog:* após exercitar o catálogo"; FALHAS=$((FALHAS+1))
fi

echo "==> [9] Métricas (direto no serviço — /metrics NÃO é exposto pelo gateway, por decisão da #26)"
if [ "$MODO" = "gateway" ]; then
  kubectl -n fcg port-forward svc/catalog-api 18082:80 >/dev/null 2>&1 &
  PFM=$!; sleep 3
  CORPO="$(curl -s --max-time 5 http://localhost:18082/metrics || true)"
  kill "$PFM" 2>/dev/null || true
else
  CORPO="$(curl -s --max-time 5 "$CATALOG_HOST/metrics" || true)"
fi
if printf '%s' "$CORPO" | grep -q 'http_server_request_duration_seconds'; then
  echo "  [OK]     9. /metrics expõe http_server_request_duration_seconds"
else
  echo "  [FALHA]  9. /metrics sem http_server_request_duration_seconds (imagem obsoleta? ver #40)"
  FALHAS=$((FALHAS+1))
fi

echo
if [ "$FALHAS" -eq 0 ]; then
  echo "TODOS OS CASOS PASSARAM (modo $MODO)"
  exit 0
fi
echo "$FALHAS FALHA(S) no modo $MODO"
exit 1

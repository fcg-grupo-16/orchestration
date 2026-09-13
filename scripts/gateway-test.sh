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
TMPD="$(mktemp -d)"
# Marca o início da execução: a limpeza só remove refresh_token criado DEPOIS disto, para nunca
# apagar sessão que o script não gerou.
INICIO="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
POD_A="rl-a-$$"; POD_B="rl-b-$$"
# O --rm do `kubectl run` é client-side: um Ctrl-C deixaria os pods rodando e martelando o gateway,
# consumindo a cota das execuções seguintes. Por isso os pods entram no cleanup explicitamente.
cleanup() {
  [ -n "$PF" ] && kill "$PF" 2>/dev/null || true
  kubectl -n fcg delete pod "$POD_A" "$POD_B" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  # O script deixava resíduo PERMANENTE no Mongo. São DUAS coisas distintas, e a primeira versão
  # desta limpeza descreveu errado o que acumula:
  #   • o teste de cadastro grava uma CONTA real (5 gw-* já haviam acumulado no usersdb). O cadastro
  #     NÃO cria refresh_token — medido: delta de refresh_tokens = 0 num signup;
  #   • quem cria refresh_token são os LOGINS do próprio teste (dois por execução, do admin), e
  #     esses eram o resíduo que de fato crescia (39 tokens acumulados, 34 do admin).
  # Por isso a limpeza remove a conta criada e os tokens do admin gerados DEPOIS do início desta
  # execução — nunca tokens anteriores, que podem ser de sessão de outra pessoa.
  if [ -n "${EMAIL:-}" ]; then
    kubectl -n fcg exec mongodb-0 -- mongosh --quiet usersdb --eval \
      "var u=db.usuarios.findOne({Email:'$EMAIL'},{_id:1});
       if (u) { db.usuarios.deleteOne({_id:u._id}); }
       var a=db.usuarios.findOne({Email:'admin@fcg.com'},{_id:1});
       if (a) { db.refresh_tokens.deleteMany({UsuarioId:a._id, CriadoEm:{\$gte:new Date('$INICIO')}}); }" \
      >/dev/null 2>&1 \
      || echo "  AVISO: nao consegui limpar o residuo de teste (${EMAIL})" >&2
  fi
  rm -rf "$TMPD"
}
trap cleanup EXIT

echo "==> Abrindo o proxy do Kong em :${GW_PORT}"
kubectl -n kong port-forward "svc/kong-kong-proxy" "${GW_PORT}:80" >"$TMPD/pf.log" 2>&1 &
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

printf '{"email":"admin@fcg.com","senha":"Admin@123456"}' > "$TMPD/login.json"
TOKEN=$(curl -s -H "$HOSTH" -H 'Content-Type: application/json' --data-binary @"$TMPD/login.json" \
  "$GW/api/v1/auth/login" | jq -r '.token // empty')
[ -n "$TOKEN" ] && printf "  OK   %-46s 200\n" "4. login publico -> token" \
  || { printf "  FALHA %-45s sem token\n" "4. login publico"; FALHAS=$((FALHAS+1)); }

check "5. com token -> 200" 200 "$(code -H "Authorization: Bearer $TOKEN" "$GW/api/v1/jogos")"

# REGRESSÃO do blocker da 3ª revisão: `header_names` não fecha as outras duas superfícies do plugin
# jwt. O default de `uri_param_names` é ["jwt"], e a versão anterior deste gateway autenticava por
# `?jwt=<token>`, com o token indo em claro para o access log. Sem estas asserções, reintroduzir o
# default volta a passar verde, porque o caminho do header continua correto.
check "5b. token pela querystring -> 401" 401 "$(code "$GW/api/v1/jogos?jwt=$TOKEN")"
check "5c. token em cookie -> 401" 401 "$(code -H "Cookie: jwt=$TOKEN" "$GW/api/v1/jogos")"
# Sem plugin `cors` no gateway, um OPTIONS anônimo não pode atravessar até o serviço.
check "5d. OPTIONS anonimo -> 401" 401 "$(code -X OPTIONS "$GW/api/v1/jogos")"

EMAIL="gw-$(date +%s)-$RANDOM@fcg.com"
printf '{"nome":"Gateway Teste","email":"%s","senha":"Teste@123456"}' "$EMAIL" > "$TMPD/signup.json"
check "6. cadastro publico (POST) -> 201" 201 \
  "$(code -H 'Content-Type: application/json' --data-binary @"$TMPD/signup.json" "$GW/api/v1/usuarios")"
check "7. GET usuarios sem token -> 401" 401 "$(code "$GW/api/v1/usuarios")"
check "8. /health nao exposto -> 404" 404 "$(code -H "Authorization: Bearer $TOKEN" "$GW/health")"

RL=$(curl -si -H "$HOSTH" -H "Authorization: Bearer $TOKEN" "$GW/api/v1/jogos" | grep -ic ratelimit || true)
[ "$RL" -gt 0 ] && printf "  OK   %-46s %s headers\n" "9. headers RateLimit-*" "$RL" \
  || { printf "  FALHA %-45s nenhum header RateLimit\n" "9. headers RateLimit-*"; FALHAS=$((FALHAS+1)); }

# O fcg-rate-limit-publico foi criado para fechar o caminho de ESCRITA anônimo, mas nenhuma
# asserção o exercitava — um typo nele passaria verde no CI (o kubeconform pula CRDs do Kong) E na
# matriz. Verificação por HEADER de propósito: é barata e não gasta a cota de 20/min que o teste 6
# precisa para cadastrar.
# A asserção mede a rota de CADASTRO, que é o caminho de escrita citado acima — medir só o login
# deixava o buraco aberto: apagar `fcg-rate-limit-publico` da annotation do Ingress de cadastro
# mantinha o teste verde. E-mail duplicado de propósito: devolve 409 sem criar conta e sem gastar a
# cota de 20/min que o teste 6 precisa.
printf '{"nome":"Dup","email":"admin@fcg.com","senha":"Teste@123456"}' > "$TMPD/dup.json"
RLC=$(curl -si -H "$HOSTH" -H 'Content-Type: application/json' --data-binary @"$TMPD/dup.json" \
  "$GW/api/v1/usuarios" | tr -d '\r' | awk '/^RateLimit-Limit:/{print $2; exit}')
check "9b. cadastro publico limitado a 20/min" 20 "${RLC:-vazio}"
RLP=$(curl -si -H "$HOSTH" -H 'Content-Type: application/json' --data-binary @"$TMPD/login.json" \
  "$GW/api/v1/auth/login" | tr -d '\r' | awk '/^RateLimit-Limit:/{print $2; exit}')
check "9c. login publico limitado a 20/min" 20 "${RLP:-vazio}"

# ---- Teste de isolamento do rate limit: determinístico, dois IPs de origem ----
#
# Duas armadilhas que versões anteriores deste bloco tiveram, e que este desenho evita:
#
# 1) JANELA FIXA. O rate-limiting do Kong usa janela alinhada ao MINUTO DE PAREDE, não deslizante
#    (medido: RateLimit-Reset = 60 - segundo atual). Se a virada do minuto cair entre o pod A
#    esgotar e o pod B pedir, o contador zera e B recebe 200 MESMO COM CONTADOR GLOBAL — o teste
#    aprovaria o defeito. Por isso: (a) só começa com janela fresca, e (b) reconfirma no FINAL que
#    A continua em 429, o que prova que a janela não virou durante a medição.
# 2) IP compartilhado. Dois tokens da mesma origem não discriminam nada: com limit_by: ip eles
#    compartilham a cota por definição. Só dois IPs de origem distintos separam as hipóteses.
#
# NOTA sobre o que este teste mede: ele prova isolamento entre PODS (IPs internos). NÃO prova
# isolamento entre clientes externos — via port-forward ou NodePort com externalTrafficPolicy:
# Cluster, todo cliente externo chega com o mesmo IP e o bucket é global. Isso é limitação
# conhecida, documentada no README, e este teste não a contradiz.
echo "==> Isolamento do rate limit (dois pods, IPs distintos)"
URL_INT="http://kong-kong-proxy.kong.svc.cluster.local:80/api/v1/jogos"
POD_IMG="curlimages/curl:8.11.1"

reset_secs() {
  curl -si -H "$HOSTH" -H "Authorization: Bearer $TOKEN" "$GW/api/v1/jogos" \
    | tr -d '\r' | awk '/^RateLimit-Reset:/{print $2; exit}'
}

RS="$(reset_secs || echo 0)"
if [ "${RS:-0}" -lt 30 ]; then
  echo "     janela expira em ${RS}s — aguardando a virada para medir numa janela inteira"
  sleep "$((RS + 2))"
fi

# Pods PERSISTENTES (não --rm): IP estável e permitem reconsultar A depois de B, na mesma janela.
for P in "$POD_A" "$POD_B"; do
  kubectl -n fcg run "$P" --image="$POD_IMG" --restart=Never --command -- sleep 600 >/dev/null 2>&1
done
for P in "$POD_A" "$POD_B"; do
  kubectl -n fcg wait --for=condition=Ready "pod/$P" --timeout=90s >/dev/null 2>&1 \
    || { printf "  FALHA %-45s pod %s nao ficou Ready\n" "10. isolamento" "$P"; FALHAS=$((FALHAS+1)); }
done

# Token vai por stdin para um arquivo dentro do pod — não em --env, que o exporia no spec do Pod
# para qualquer um com `get pods` no namespace.
for P in "$POD_A" "$POD_B"; do
  printf '%s' "$TOKEN" | kubectl -n fcg exec -i "$P" -- sh -c 'cat > /tmp/tk' >/dev/null 2>&1
done

req() { kubectl -n fcg exec "$1" -- sh -c \
  "curl -s -o /dev/null -w '%{http_code}' -H 'Host: api.fcg.local' -H \"Authorization: Bearer \$(cat /tmp/tk)\" $URL_INT" 2>/dev/null | tr -d '[:space:]'; }

A_COUNTS=$(kubectl -n fcg exec "$POD_A" -- sh -c \
  "for i in \$(seq 1 140); do curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: api.fcg.local' -H \"Authorization: Bearer \$(cat /tmp/tk)\" $URL_INT; done | sort | uniq -c" 2>/dev/null)
echo "$A_COUNTS" | sed 's/^/     pod A: /'

A_OK=$(echo "$A_COUNTS" | awk '$2==200{print $1}'); A_OK=${A_OK:-0}
A_429=$(echo "$A_COUNTS" | awk '$2==429{print $1}'); A_429=${A_429:-0}
A_MID=$(req "$POD_A")          # A ainda limitado?
B_CODE=$(req "$POD_B")         # B, outro IP, na MESMA janela
A_END=$(req "$POD_A")          # A ainda limitado DEPOIS de B -> a janela não virou

# 10a: o limite foi aplicado, e perto do configurado (um `minute: 1` acidental não passaria).
if [ "$A_429" -gt 0 ] && [ "$A_OK" -ge 100 ] && [ "$A_MID" = "429" ]; then
  printf "  OK   %-46s %s×200 + %s×429, A segue 429\n" "10a. limite aplicado por IP" "$A_OK" "$A_429"
else
  printf "  FALHA %-45s 200=%s 429=%s A_apos=%s (esperado ~120/+ e 429)\n" \
    "10a. limite aplicado por IP" "$A_OK" "$A_429" "${A_MID:-vazio}"; FALHAS=$((FALHAS+1))
fi

# 10b: B passa E A continua bloqueado -> o 200 de B não veio de virada de janela.
if [ "$B_CODE" = "200" ] && [ "$A_END" = "429" ]; then
  printf "  OK   %-46s B(outro IP)=200 com A ainda em 429\n" "10b. isolamento entre IPs"
elif [ "$B_CODE" = "200" ] && [ "$A_END" != "429" ]; then
  printf "  FALHA %-45s B=200 mas A voltou a %s — a janela virou, resultado INCONCLUSIVO\n" \
    "10b. isolamento entre IPs" "${A_END:-vazio}"; FALHAS=$((FALHAS+1))
else
  printf "  FALHA %-45s B(outro IP)=%s -> contador GLOBAL entre pods\n" \
    "10b. isolamento entre IPs" "${B_CODE:-vazio}"; FALHAS=$((FALHAS+1))
fi

echo
if [ "$FALHAS" -eq 0 ]; then echo "Matriz do gateway: TODOS os testes passaram."; else
  echo "Matriz do gateway: $FALHAS teste(s) FALHARAM."; exit 1; fi

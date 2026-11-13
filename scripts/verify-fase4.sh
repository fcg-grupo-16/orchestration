#!/usr/bin/env bash
# Checklist automatizado da entrega da Fase 4 (#69), consultando o cluster e o endereço público.
#
# Rode ANTES de gravar o vídeo. Como o verify-fase3.sh, confere o requisito de verdade, e não só se o
# objeto existe. Termina com um veredito inequívoco.
#
# Alvos:
#   ./scripts/verify-fase4.sh                 # EKS: cluster e registry lidos do terraform output
#   ALVO=minikube ./scripts/verify-fase4.sh   # minikube: pula o que só existe na AWS (com AVISO)
#
# ⚠️ Não é 100% read-only, de propósito: a seção de busca cria um jogo de teste, edita e remove, porque
# "o índice é fiel ao banco" só se prova escrevendo. O jogo é apagado do Mongo no fim, e o
# POST /reindex que ela pode chamar não apaga nada que esteja ativo.
#
# ⚠️ SEM `set -e`, pelo mesmo motivo do verify-fase3.sh: acumula as falhas e mostra todas.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ALVO="${ALVO:-eks}"
NS="fcg"
FALHOU=0
AVISOS=0

ok()    { echo "  [OK]     $1"; }
fail()  { echo "  [FALHA]  $1"; FALHOU=1; }
aviso() { echo "  [AVISO]  $1"; AVISOS=$((AVISOS+1)); }

for bin in kubectl curl jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERRO: '$bin' não encontrado." >&2; exit 1; }
done

TMPD="$(mktemp -d)"
PF=""
JOGO_ID=""
limpar() {
  [ -n "$PF" ] && kill "$PF" 2>/dev/null
  if [ -n "$JOGO_ID" ]; then
    # O DELETE da API é lógico (Ativo=false); o documento continuaria no Mongo. Sai de verdade aqui.
    kubectl -n "$NS" exec mongodb-0 -c mongodb -- mongosh --quiet catalogdb \
      --eval "db.jogos.deleteOne({_id: ObjectId('$JOGO_ID')})" >/dev/null 2>&1 \
      || echo "  AVISO: não consegui apagar o jogo de teste $JOGO_ID do Mongo" >&2
  fi
  rm -rf "$TMPD"
}
trap limpar EXIT

# --- 0. Pré-condições: o cluster CERTO e o endereço --------------------------------------------------
echo "== 0. Pré-condições"
if [ "$ALVO" = "eks" ]; then
  command -v aws >/dev/null 2>&1 || { echo "ERRO: 'aws' não encontrado." >&2; exit 1; }
  command -v terraform >/dev/null 2>&1 || { echo "ERRO: 'terraform' não encontrado." >&2; exit 1; }
  aws sts get-caller-identity >/dev/null 2>&1 || {
    echo "ERRO: sem credencial AWS. A sessão do lab expirou? Atualize ~/.aws/credentials." >&2; exit 1; }
  CLUSTER="$(terraform -chdir="$ROOT_DIR/terraform" output -raw nome_cluster 2>/dev/null)"
  REGIAO="$(terraform -chdir="$ROOT_DIR/terraform" output -raw regiao 2>/dev/null)"
  REGISTRY="$(terraform -chdir="$ROOT_DIR/terraform" output -raw registry 2>/dev/null)"
  [ -n "$CLUSTER" ] || { echo "ERRO: sem terraform output. Rode ./scripts/terraform-init.sh." >&2; exit 1; }
  # Kubeconfig EXPLÍCITO: o contexto atual pode ser o minikube, e "not found" lá parece plataforma caída.
  export KUBECONFIG="$TMPD/kubeconfig"
  aws eks update-kubeconfig --name "$CLUSTER" --region "$REGIAO" --kubeconfig "$KUBECONFIG" >/dev/null
  LB="$(kubectl -n kong get svc kong-kong-proxy -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
  [ -n "$LB" ] || { echo "ERRO: o Kong não tem endereço público. Rode ./scripts/deploy-eks.sh." >&2; exit 1; }
  GW="http://$LB"
  HOSTH="Host: $LB"
  ok "cluster $CLUSTER ($REGIAO), endereço público $LB"
else
  [ "$(kubectl config current-context 2>/dev/null)" = "minikube" ] \
    || { echo "ERRO: ALVO=minikube, mas o contexto do kubectl é outro." >&2; exit 1; }
  kubectl -n kong port-forward svc/kong-kong-proxy 8030:80 >"$TMPD/pf.log" 2>&1 &
  PF=$!
  GW="http://localhost:8030"
  HOSTH="Host: api.fcg.local"
  for _ in $(seq 1 30); do curl -s -o /dev/null "$GW" && break; sleep 1; done
  ok "minikube, gateway por port-forward (as checagens só da AWS viram AVISO)"
fi
kubectl get ns "$NS" >/dev/null 2>&1 || { echo "ERRO: namespace $NS não existe." >&2; exit 1; }

# --- 1. Kubernetes gerenciado -------------------------------------------------------------------------
echo "== 1. Kubernetes gerenciado e endereço público"
if [ "$ALVO" = "eks" ]; then
  NOS="$(kubectl get nodes -l eks.amazonaws.com/nodegroup --no-headers 2>/dev/null | grep -c ' Ready')"
  [ "${NOS:-0}" -ge 1 ] && ok "$NOS nó(s) do node group gerenciado Ready" \
                        || fail "nenhum nó de node group gerenciado Ready"
else
  aviso "nós gerenciados: só no EKS"
fi
COD="$(curl -s -o /dev/null -w '%{http_code}' -m 10 -H "$HOSTH" "$GW/api/v1/jogos")"
SRV="$(curl -si -m 10 -H "$HOSTH" "$GW/api/v1/jogos" | tr -d '\r' | awk 'tolower($1)=="server:"{print $2}')"
if [ "$COD" = "401" ] && [ "${SRV#kong/}" != "$SRV" ]; then
  ok "gateway responde sem túnel: 401 do Kong ($SRV) sem token"
else
  fail "gateway: esperado 401 do Kong, obtido $COD (server=${SRV:-vazio})"
fi

# --- 2. Registry privado: o pod roda o digest que o ECR tem -------------------------------------------
echo "== 2. Imagens do registry privado"
for alvo in deploy/users-api deploy/catalog-api deploy/payments-api deploy/notifications-function deploy/rabbitmq; do
  IMG="$(kubectl -n "$NS" get "$alvo" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
  nome="${alvo#deploy/}"
  if [ "$ALVO" != "eks" ]; then
    case "$IMG" in *:local) fail "$nome com tag móvel :local (#40)";; *) ok "$nome: $IMG";; esac
    continue
  fi
  case "$IMG" in
    "$REGISTRY"/fcg/*) ;;
    *) fail "$nome não vem do ECR: $IMG"; continue ;;
  esac
  TAG="${IMG##*:}"; REPO="${IMG#"$REGISTRY"/}"; REPO="${REPO%:*}"
  DIG_ECR="$(aws ecr describe-images --region "$REGIAO" --repository-name "$REPO" \
             --image-ids "imageTag=$TAG" --query 'imageDetails[0].imageDigest' --output text 2>/dev/null)"
  if [ "$nome" = "notifications-function" ]; then
    # Em 0 réplica (KEDA) não há pod para comparar: confere só que a tag existe no ECR.
    [ -n "$DIG_ECR" ] && [ "$DIG_ECR" != "None" ] && ok "$nome: ${REPO}:${TAG:0:12} existe no ECR (sem pod: escala a zero)" \
                      || fail "$nome: ${REPO}:${TAG} não existe no ECR"
    continue
  fi
  DIG_POD="$(kubectl -n "$NS" get pods -l "app=$nome" --field-selector=status.phase=Running \
             -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null)"
  if [ -n "$DIG_ECR" ] && [ "${DIG_POD##*@}" = "$DIG_ECR" ]; then
    ok "$nome roda o digest do ECR para ${TAG:0:12} (${DIG_ECR:7:12})"
  else
    fail "$nome: digest do pod (${DIG_POD##*@}) ≠ digest do ECR ($DIG_ECR) para a tag $TAG"
  fi
done

# --- 3. Segredos --------------------------------------------------------------------------------------
echo "== 3. Zero hardcoded credentials"
if [ "$ALVO" = "eks" ]; then
  NAO_SYNC="$(kubectl -n "$NS" get externalsecret -o json 2>/dev/null \
    | jq -r '.items[] | select(([.status.conditions[]? | select(.type=="Ready" and .status=="True")] | length) == 0) | .metadata.name')"
  TOTAL_ES="$(kubectl -n "$NS" get externalsecret --no-headers 2>/dev/null | grep -c .)"
  if [ "${TOTAL_ES:-0}" -ge 8 ] && [ -z "$NAO_SYNC" ]; then
    ok "$TOTAL_ES ExternalSecrets sincronizados do Secrets Manager"
  else
    fail "ExternalSecrets: $TOTAL_ES encontrados, sem sincronizar: ${NAO_SYNC:-nenhum}"
  fi
else
  aviso "External Secrets: só no EKS (o minikube usa Sealed Secrets)"
fi
# Variável sensível com `value:` literal no spec do pod é segredo em claro, mesmo com tudo o mais certo.
EM_CLARO="$(kubectl -n "$NS" get deploy,statefulset -o json \
  | jq -r '.items[] | .metadata.name as $n | .spec.template.spec.containers[].env[]?
           | select((.name | test("(?i)secret|password|senha|connectionstring|token")) and has("value"))
           | "\($n):\(.name)"')"
[ -z "$EM_CLARO" ] && ok "nenhuma variável sensível com valor literal nos pods" \
                   || fail "segredo em claro no spec: $EM_CLARO"
# Paridades que quebram em silêncio (401 no gateway). Compara SEM imprimir valor nenhum.
segredo() { kubectl -n "$NS" get secret "$1" -o json 2>/dev/null | jq -r --arg k "$2" '.data[$k] // empty'; }
J_USERS="$(segredo users-api-secret JwtSettings__SecretKey)"
J_CAT="$(segredo catalog-api-secret JwtSettings__SecretKey)"
J_KONG="$(segredo fcg-jwt-credential secret)"
S_USERS="$(segredo users-api-secret ServiceAuth__SecretKey)"
S_FN="$(segredo notifications-function-secret ServiceAuth__SecretKey)"
[ -n "$J_USERS" ] && [ "$J_USERS" = "$J_CAT" ] && [ "$J_USERS" = "$J_KONG" ] \
  && ok "paridade tríplice do JWT (users-api, catalog-api, Kong)" \
  || fail "chave do JWT DIVERGE entre users-api, catalog-api e o Kong"
[ -n "$S_USERS" ] && [ "$S_USERS" = "$S_FN" ] && [ "$S_USERS" != "$J_USERS" ] \
  && ok "chave de serviço igual em users-api e Function, e diferente da do JWT (ADR 0007)" \
  || fail "chave de serviço diverge, ou é igual à do JWT (ADR 0007)"

# --- 4. Busca avançada --------------------------------------------------------------------------------
echo "== 4. Busca avançada (OpenSearch)"
pod_curl() { # <labels ou ""> <url> -> imprime o código HTTP, ou 000 se não alcançou
  local nome="verifica-os-$RANDOM"
  local lbl=()
  [ -n "$1" ] && lbl=(--labels="$1")
  kubectl -n "$NS" run "$nome" --rm -i --restart=Never "${lbl[@]}" --image=curlimages/curl:8.11.1 \
    --command -- curl -s -o /dev/null -w '%{http_code}' -m 5 "$2" 2>/dev/null | grep -oE '^[0-9]{3}' | head -1
}
C_OK="$(pod_curl "app=catalog-api" "http://opensearch:9200/_cluster/health")"
[ "$C_OK" = "200" ] && ok "OpenSearch alcançável pelo catalog-api" || fail "catalog-api não alcança o OpenSearch (${C_OK:-sem resposta})"
C_NEG="$(pod_curl "" "http://opensearch:9200/_cluster/health")"
if [ "$C_NEG" = "000" ] || [ -z "$C_NEG" ]; then
  ok "OpenSearch RECUSA pod sem o label do catalog-api (NetworkPolicy imposta)"
elif [ "$ALVO" = "eks" ]; then
  fail "OpenSearch respondeu $C_NEG a um pod qualquer: a NetworkPolicy NÃO está imposta (vpc-cni)"
else
  aviso "NetworkPolicy ignorada no minikube padrão (kindnet): pod qualquer obteve $C_NEG"
fi

TOKEN="$(curl -s -m 10 -H "$HOSTH" -H 'Content-Type: application/json' \
  -d '{"email":"admin@fcg.com","senha":"Admin@123456"}' "$GW/api/v1/auth/login" | jq -r '.token // empty')"
if [ -z "$TOKEN" ]; then
  fail "login do admin pelo gateway falhou: sem token, a seção de busca e a de cache não rodam"
else
  AUTH="Authorization: Bearer $TOKEN"
  busca() { curl -s -m 10 -H "$HOSTH" -H "$AUTH" --get --data-urlencode "q=$1" "$GW/api/v1/jogos/search"; }

  # Título PRÓPRIO, com sufixo aleatório: o título de jogo é único, e um nome do seed daria 409. A
  # palavra inventada garante que só o jogo de teste case com as consultas abaixo.
  SUF="$RANDOM"
  printf '{"titulo":"Zephyrion Quest %s","descricao":"Jogo de verificação da Fase 4.","genero":2,"preco":10.00,"dataLancamento":"2024-01-01T00:00:00Z"}' "$SUF" > "$TMPD/jogo.json"
  RESP="$(curl -s -m 15 -H "$HOSTH" -H "$AUTH" -H 'Content-Type: application/json' \
    --data-binary @"$TMPD/jogo.json" "$GW/api/v1/jogos")"
  JOGO_ID="$(echo "$RESP" | jq -r '.id // empty' 2>/dev/null)"
  if [ -z "$JOGO_ID" ]; then
    fail "não consegui criar o jogo de teste: $(echo "$RESP" | head -c 200)"
  else
    contem() { jq -r --arg id "$JOGO_ID" '[.[] | .id] | index($id) != null'; }
    # "qeust": letras trocadas (fuzzy). "zephyrionquest": palavras coladas (o subcampo compacto, o
    # mesmo mecanismo que faz "code quest" achar "CodeQuest").
    for termo in "zephyrion qeust" "zephyrionquest"; do
      R="$(busca "$termo")"
      if [ "$(echo "$R" | contem)" = "true" ]; then
        ok "fuzzy: '$termo' acha 'Zephyrion Quest $SUF'"
      else
        fail "fuzzy: '$termo' não achou o jogo criado (resposta: $(echo "$R" | head -c 200))"
      fi
      echo "$R" | jq -e 'length > 0 and ([.[].score] as $s | $s == ($s | sort | reverse))' >/dev/null 2>&1 \
        && ok "'$termo': resultados em ordem decrescente de score" \
        || fail "'$termo': resultados vazios ou fora da ordem de score"
    done
    curl -s -o /dev/null -m 15 -X PUT -H "$HOSTH" -H "$AUTH" -H 'Content-Type: application/json' \
      -d "{\"titulo\":\"Zephyrion Remasterizado $SUF\",\"descricao\":\"Editado pela verificação.\",\"genero\":2,\"preco\":12.00}" \
      "$GW/api/v1/jogos/$JOGO_ID"
    [ "$(busca "zephyrion remasterizado" | contem)" = "true" ] \
      && ok "índice fiel: a edição aparece na busca" || fail "índice fiel: a edição NÃO aparece na busca"
    curl -s -o /dev/null -m 15 -X DELETE -H "$HOSTH" -H "$AUTH" "$GW/api/v1/jogos/$JOGO_ID"
    [ "$(busca "zephyrion" | contem)" = "false" ] \
      && ok "índice fiel: o jogo removido some da busca" || fail "índice fiel: o jogo removido continua na busca"
  fi
  # O seed entra no Mongo SEM passar pela indexação; índice incompleto = /search que não acha jogo
  # que existe, no meio do vídeo. Compara a contagem do índice com a de jogos ativos no Mongo.
  conta_mongo() { kubectl -n "$NS" exec mongodb-0 -c mongosh -- mongosh --quiet --host 127.0.0.1 catalogdb \
    --eval 'print(db.jogos.countDocuments({Ativo: true}))' 2>/dev/null | tail -1 | tr -d '\r'; }
  conta_indice() { kubectl -n "$NS" exec opensearch-0 -- curl -s 'localhost:9200/jogos/_count' 2>/dev/null | jq -r '.count // empty'; }
  N_MONGO="$(conta_mongo)"; N_INDICE="$(conta_indice)"
  if [ -n "$N_MONGO" ] && [ "$N_MONGO" != "$N_INDICE" ]; then
    curl -s -o /dev/null -m 60 -X POST -H "$HOSTH" -H "$AUTH" "$GW/api/v1/jogos/reindex"
    aviso "índice com ${N_INDICE:-0} jogo(s) e Mongo com $N_MONGO ativo(s): rodei POST /api/v1/jogos/reindex"
    N_INDICE="$(conta_indice)"
  fi
  [ -n "$N_MONGO" ] && [ "$N_MONGO" = "$N_INDICE" ] \
    && ok "índice fiel ao banco: $N_INDICE jogo(s) no índice = $N_MONGO ativo(s) no Mongo" \
    || fail "índice ($N_INDICE) ≠ jogos ativos no Mongo ($N_MONGO), mesmo depois do reindex"

  # --- 5. Cache: o número que o vídeo precisa -------------------------------------------------------
  echo "== 5. Impacto do cache (Redis)"
  # Tamanho de página aleatório = chave de cache que ninguém pediu ainda: a 1ª chamada é miss de
  # verdade, sem depender de o cache estar frio.
  TP=$((37 + RANDOM % 60))
  T1="$(curl -s -o /dev/null -w '%{time_total}' -H "$HOSTH" -H "$AUTH" "$GW/api/v1/jogos?pagina=1&tamanhoPagina=$TP")"
  T2="$(curl -s -o /dev/null -w '%{time_total}' -H "$HOSTH" -H "$AUTH" "$GW/api/v1/jogos?pagina=1&tamanhoPagina=$TP")"
  MS1="$(awk -v t="$T1" 'BEGIN{printf "%.0f", t*1000}')"; MS2="$(awk -v t="$T2" 'BEGIN{printf "%.0f", t*1000}')"
  echo "           1ª chamada (miss, vai ao Mongo): ${MS1} ms"
  echo "           2ª chamada (hit, vem do Redis):  ${MS2} ms"
  if [ "$MS2" -lt "$MS1" ]; then ok "cache mais rápido: ${MS1} ms → ${MS2} ms"
  else aviso "a 2ª chamada não foi mais rápida (${MS1} → ${MS2} ms): rede oscilou? rode de novo"; fi
fi

# --- 6. Serverless -----------------------------------------------------------------------------------
echo "== 6. Serverless (KEDA)"
READY="$(kubectl -n "$NS" get scaledobject notifications-function -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
MIN="$(kubectl -n "$NS" get scaledobject notifications-function -o jsonpath='{.spec.minReplicaCount}' 2>/dev/null)"
[ "$READY" = "True" ] && [ "$MIN" = "0" ] && ok "ScaledObject Ready, minReplicaCount 0 (escala a zero)" \
                                          || fail "ScaledObject: Ready=${READY:-?} min=${MIN:-?}"
echo "           o ciclo 0→1→0 é medido pelo keda-test.sh (GATEWAY_URL=$GW)"

echo
if [ "$FALHOU" -eq 0 ]; then
  [ "$AVISOS" -eq 0 ] && echo "PRONTO PARA GRAVAR (sem pendências)" \
                      || echo "PRONTO PARA GRAVAR ($AVISOS aviso(s) acima — nenhum bloqueia a entrega)"
  exit 0
fi
echo "PENDÊNCIAS ACIMA — a entrega NÃO está completa"
exit 1

#!/usr/bin/env bash
# Checklist automatizado da entrega da Fase 3, consultando o CLUSTER. Read-only: não muda nada.
#
# Rode ANTES de gravar o vídeo. Cada linha corresponde a um requisito do épico #24, e o script
# confere o requisito de verdade em vez de só checar se o objeto existe — a diferença importa:
# na Fase 3 tivemos três requisitos que pareciam entregues (manifesto aplicado, pod Running) e
# estavam INVISÍVEIS no cluster porque o nó servia uma imagem obsoleta (issue #40).
#
# ⚠️ SEM `set -e`: este script ACUMULA falhas e reporta todas de uma vez. Com `-e` ele morreria na
# primeira e esconderia o resto do checklist — que é justamente o que se quer ver. Como não há
# `-e`, a armadilha `VAR=$(cmd | pipe)` sob `pipefail` (que mata o script na atribuição) não se
# aplica aqui.
set -uo pipefail

NS="${NS:-fcg}"
NS_KONG="${NS_KONG:-kong}"
NS_KEDA="${NS_KEDA:-keda}"
FALHOU=0
AVISOS=0

ok()    { echo "  [OK]     $1"; }
fail()  { echo "  [FALHA]  $1"; FALHOU=1; }
aviso() { echo "  [AVISO]  $1"; AVISOS=$((AVISOS+1)); }

command -v kubectl >/dev/null 2>&1 || { echo "ERRO: 'kubectl' não encontrado." >&2; exit 1; }
kubectl get ns "$NS" >/dev/null 2>&1 || { echo "ERRO: namespace '$NS' não existe. Rode ./scripts/deploy-minikube.sh." >&2; exit 1; }

existe() { kubectl -n "$1" get "$2" "$3" >/dev/null 2>&1; }

echo "== 1. API Gateway (Kong) — porta de entrada única"
existe "$NS_KONG" deploy kong-kong && ok "Kong instalado" || fail "Kong ausente (helm upgrade --install kong)"
existe "$NS" kongplugin fcg-jwt && ok "plugin jwt na borda" || fail "KongPlugin fcg-jwt ausente"
existe "$NS" kongplugin fcg-rate-limit && ok "plugin de rate limit" || fail "KongPlugin fcg-rate-limit ausente"
existe "$NS" kongconsumer fcg-api-consumer && ok "consumer do gateway" || fail "KongConsumer fcg-api-consumer ausente"
# A credencial é um Secret com o label `konghq.com/credential: jwt`. Sem o LABEL o Kong ignora o
# Secret e registra "secret has no credential type" — e o efeito engana: o gateway segue devolvendo
# 401 sem token (parece certo) e passa a devolver 401 TAMBÉM com token válido.
if kubectl -n "$NS" get secret fcg-jwt-credential \
     -o jsonpath='{.metadata.labels.konghq\.com/credential}' 2>/dev/null | grep -q '^jwt$'; then
  ok "credencial jwt rotulada para o Kong"
else
  fail "Secret fcg-jwt-credential ausente ou sem o label konghq.com/credential=jwt"
fi
existe "$NS" ingress fcg-gateway-protected && ok "rotas protegidas" || fail "Ingress fcg-gateway-protected ausente"
# O Ingress NGINX legado serviria as MESMAS rotas SEM validar JWT, em paralelo ao Kong: a presença
# dele torna falso o critério "porta de entrada única", mesmo com o Kong impecável.
existe "$NS" ingress fcg-ingress && fail "Ingress NGINX legado AINDA existe: porta de entrada NÃO é única" \
                                || ok "nenhum Ingress legado em paralelo"

echo "== 2. Serverless (KEDA + Azure Functions)"
existe "$NS_KEDA" deploy keda-operator && ok "KEDA instalado" || fail "KEDA ausente"
existe "$NS" scaledobject notifications-function && ok "ScaledObject presente" || fail "ScaledObject ausente"
MIN="$(kubectl -n "$NS" get scaledobject notifications-function -o jsonpath='{.spec.minReplicaCount}' 2>/dev/null)"
[ "$MIN" = "0" ] && ok "minReplicaCount=0 (escala a zero)" || fail "minReplicaCount='$MIN' (esperado 0)"
# `Ready=True` é condição NECESSÁRIA e NÃO SUFICIENTE: medido na #29, um ScaledObject apontando para
# uma fila INEXISTENTE também reporta Ready=True até o primeiro poll do trigger (~18s), quando cai
# para TriggerError. Só o ciclo 0->1->0 do scripts/keda-test.sh prova o scaler de verdade.
READY="$(kubectl -n "$NS" get scaledobject notifications-function -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
[ "$READY" = "True" ] && ok "ScaledObject Ready (necessário, não suficiente — ver keda-test.sh)" \
                      || fail "ScaledObject não está Ready (status='$READY')"
existe "$NS" deploy notifications-api && fail "notifications-api legado AINDA rodando: competing consumer das filas" \
                                      || ok "notifications-api removido"

echo "== 3. Observabilidade (Prometheus + Grafana + Jaeger)"
for d in prometheus grafana jaeger; do
  existe "$NS" deploy "$d" && ok "$d" || fail "$d ausente"
done
existe "$NS" cm grafana-dashboard-fcg && ok "dashboard provisionado" || fail "ConfigMap grafana-dashboard-fcg ausente"
# O detector que importa: TARGET SAUDÁVEL, não Deployment de pé. Com a imagem obsoleta da #40 o
# Prometheus rodava perfeito e TODOS os targets estavam down com 404 — Deployment "prometheus" OK,
# requisito de observabilidade NÃO entregue. Testado nos dois estados.
PFPORT="${PFPORT:-9099}"
kubectl -n "$NS" port-forward svc/prometheus "$PFPORT:9090" >/dev/null 2>&1 &
PF=$!
trap '[ -n "${PF:-}" ] && kill "$PF" 2>/dev/null; rm -f /tmp/fcg-targets.$$.json' EXIT
sleep 4
if curl -sf "http://localhost:$PFPORT/api/v1/targets?state=any" -o "/tmp/fcg-targets.$$.json" 2>/dev/null; then
  LEITURA="$(python3 - "/tmp/fcg-targets.$$.json" <<'PY'
import json, sys
alvos = json.load(open(sys.argv[1]))["data"]["activeTargets"]
up = [t for t in alvos if t["health"] == "up"]
down = [t for t in alvos if t["health"] != "up"]
nomes = lambda ts: ",".join(sorted((t["labels"].get("service") or t["labels"].get("job") or "?") for t in ts))
print(f"{len(up)}|{len(down)}|{nomes(down)}")
PY
)"
  UP="${LEITURA%%|*}"; RESTO="${LEITURA#*|}"; DOWN="${RESTO%%|*}"; QUEM="${RESTO#*|}"
  # São QUATRO alvos: users-api, catalog-api, payments-api e o próprio prometheus. A
  # notifications-function fica de fora de propósito (`prometheus.io/scrape: "false"`): com
  # scale-to-zero o pod vive segundos, incompatível com o pull do Prometheus.
  [ "${UP:-0}" -ge 4 ] && ok "Prometheus raspando: $UP target(s) UP" || fail "só $UP target(s) UP (esperado >= 4)"
  # QUALQUER alvo em down é falha. Até payments-api#19/#20 havia aqui uma exceção que rebaixava o
  # `payments-api` a mero aviso, porque ele não tinha instrumentação e o alvo ficava down em
  # permanência. A exceção foi removida junto com a causa — mantê-la seria pior que texto obsoleto:
  # um alvo caído por motivo REAL passaria como benigno, e o checklist diria "PRONTO PARA GRAVAR".
  if [ "${DOWN:-0}" -gt 0 ]; then
    fail "target(s) down: $QUEM"
  fi
else
  aviso "não consegui consultar o Prometheus via port-forward (pulei a checagem de targets)"
fi
kill "$PF" 2>/dev/null; PF=""

echo "== 4. NoSQL (MongoDB — avaliações em documento flexível)"
existe "$NS" statefulset mongodb && ok "MongoDB (StatefulSet, replica set rs0)" || fail "StatefulSet mongodb ausente"
# Índices, não só a coleção: eles são criados no startup do catalog-api (GarantirIndicesAsync). Se a
# coleção existe mas está sem índice, o serviço que subiu é antigo — foi exatamente o sintoma da #40.
IDX="$(kubectl -n "$NS" exec statefulset/mongodb -- mongosh --quiet catalogdb \
        --eval 'db.avaliacoes.getIndexes().map(i => i.name).join(",")' 2>/dev/null | tr -d '\r')"
case "$IDX" in
  *ix_jogo_data*ux_jogo_usuario*|*ux_jogo_usuario*ix_jogo_data*)
    ok "coleção avaliacoes com ix_jogo_data e ux_jogo_usuario" ;;
  "")
    fail "coleção avaliacoes inexistente ou inacessível (o catalog-api já subiu?)" ;;
  *)
    fail "avaliacoes sem os índices esperados (encontrados: $IDX)" ;;
esac

echo "== 5. Cache distribuído (Redis)"
existe "$NS" deploy redis && ok "Redis (cache)" || fail "Deployment redis ausente"
CHAVES="$(kubectl -n "$NS" exec deploy/redis -- redis-cli --scan --pattern 'fcg:catalog:*' 2>/dev/null | tr -d '\r' | grep -c . )"
if [ "${CHAVES:-0}" -gt 0 ]; then
  ok "cache em uso: $CHAVES chave(s) fcg:catalog:*"
else
  # Zero chaves é ambíguo: pode ser cache quebrado OU catálogo simplesmente não exercitado ainda.
  aviso "nenhuma chave fcg:catalog:* — exercite o catálogo (GET /api/v1/jogos) e rode de novo"
fi

echo "== 6. Idempotência (Redis dedicado, issue #35)"
# Redis de IDEMPOTÊNCIA (issue #35) — instância SEPARADA e durável. Conferir a existência não basta:
# o defeito original era um Redis que existia e estava saudável, mas configurado como cache
# (allkeys-lru, sem persistência), despejando em silêncio as chaves que impedem e-mail duplicado.
# Por isso o detector olha a CONFIGURAÇÃO EFETIVA, consultada do próprio Redis.
if existe "$NS" statefulset redis-idempotencia; then
  ok "Redis de idempotência (StatefulSet, durável)"
  POLITICA="$(kubectl -n "$NS" exec statefulset/redis-idempotencia -- redis-cli config get maxmemory-policy 2>/dev/null | tr -d '\r' | tail -1)"
  [ "$POLITICA" = "noeviction" ] \
    && ok "maxmemory-policy=noeviction (não despeja chave de idempotência)" \
    || fail "maxmemory-policy='$POLITICA' (esperado noeviction — ver #35)"
  AOF="$(kubectl -n "$NS" exec statefulset/redis-idempotencia -- redis-cli config get appendonly 2>/dev/null | tr -d '\r' | tail -1)"
  [ "$AOF" = "yes" ] \
    && ok "appendonly=yes (sobrevive à recriação do Pod)" \
    || fail "appendonly='$AOF' (esperado yes — sem AOF a chave morre com o Pod)"
  # O AOF só é durável se estiver em volume persistente: sem PVC, ele morre junto com o Pod e o
  # `appendonly yes` vira falsa sensação de segurança.
  kubectl -n "$NS" get pvc dados-redis-idempotencia-0 >/dev/null 2>&1 \
    && ok "PVC do AOF provisionado" \
    || fail "PVC dados-redis-idempotencia-0 ausente — o AOF não sobreviveria ao Pod"
else
  fail "StatefulSet redis-idempotencia ausente (a idempotência estaria no Redis de cache — ver #35)"
fi

# A Function tem de apontar para o Redis DEDICADO. Apontar para o de cache reintroduz o defeito sem
# que nada no deploy acuse.
CONN="$(kubectl -n "$NS" get secret notifications-function-secret -o jsonpath='{.data.Redis__ConnectionString}' 2>/dev/null | base64 -d 2>/dev/null)"
case "$CONN" in
  redis-idempotencia:*) ok "Function aponta para o Redis de idempotência" ;;
  "")                   aviso "não consegui ler Redis__ConnectionString do secret da Function" ;;
  *)                    fail "Function aponta para '$CONN' — deveria ser redis-idempotencia:6379 (#35)" ;;
esac

echo "== 7. As imagens do nó são as que acabaram de ser buildadas? (issue #40)"
# Um pod Running com imagem OBSOLETA satisfaz todo `kubectl get` e reprova todo requisito de
# comportamento. A comparação é imageID do pod x Id no daemon do host.
if command -v docker >/dev/null 2>&1; then
  for svc in users-api catalog-api payments-api; do
    TAG="$(kubectl -n "$NS" get deploy "$svc" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
    HOSTID="$(docker image inspect "$TAG" --format '{{.Id}}' 2>/dev/null)"
    # --field-selector: durante um rollout há pod ANTIGO em Terminating, e pegar items[0] às cegas
    # lê o pod errado (me deu um falso "DIVERGE" com o cluster já correto).
    PODID="$(kubectl -n "$NS" get pods -l "app=$svc" --field-selector=status.phase=Running \
             -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null)"
    if [ -z "$HOSTID" ]; then
      aviso "$svc: imagem '$TAG' não existe no daemon local (build em outra máquina?)"
    elif [ "${PODID##*@}" = "$HOSTID" ] || [ "${PODID##*:}" = "${HOSTID##*:}" ]; then
      ok "$svc serve a imagem atual"
    else
      fail "$svc serve imagem OBSOLETA (pod=${PODID##*:} host=${HOSTID##*:}) — ver issue #40"
    fi
  done
else
  aviso "docker não encontrado: pulei a checagem de obsolescência de imagem"
fi

echo
if [ "$FALHOU" -eq 0 ]; then
  [ "$AVISOS" -eq 0 ] && echo "PRONTO PARA GRAVAR (sem pendências)" \
                      || echo "PRONTO PARA GRAVAR ($AVISOS aviso(s) acima — nenhum bloqueia a entrega)"
  exit 0
fi
echo "PENDÊNCIAS ACIMA — a entrega NÃO está completa"
exit 1

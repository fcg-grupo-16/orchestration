#!/usr/bin/env bash
# Matriz de aceite do scale-to-zero da notifications-function (issue #29) contra o cluster.
#
# Por que este script existe: o `kubeconform` do CI PULA os CRs do KEDA (ScaledObject e
# TriggerAuthentication não têm schema publicado), exatamente como pula os do Kong. Um campo errado
# no scaler passa verde no pipeline. E `Ready` ENGANA — mas não como uma versão anterior deste
# comentário afirmava. Medido com ScaledObjects efêmeros, em Deployments dedicados:
#
#   • credencial -> secret inexistente:  Ready=False (ScaledObjectCheckFailed) desde o início e
#     estável (t+8s, t+25s, t+60s), SEM HPA criado, e o operador registra erro em loop
#     ("missing required parameter \"host\" in [triggerMetadata authParams resolvedEnv]").
#     A asserção 1 PEGA este caso — é a classe do primeiro defeito desta issue (nome curto,
#     irresolvível do namespace `keda`), e ele também dá Ready=False.
#   • credencial boa + `queueName` inexistente:  Ready=True (ScaledObjectReady) com HPA criado
#     em t+6s e t+12s, caindo para Ready=False (TriggerError) a partir de t+18s.
#
# Ou seja, o engano real é TEMPORAL: `Ready=True` aparece ANTES do primeiro poll do trigger, então
# ler `Ready` cedo demais aprova um scaler que não alcança a fila. Nos dois casos o Deployment fica
# em 0 réplica, indistinguível de scale-to-zero saudável. A asserção de EXECUÇÃO é a que decide; a
# de `Ready` é necessária e não suficiente.
#
# Uso: ./scripts/keda-test.sh   (requer a plataforma implantada: ./scripts/deploy-minikube.sh)
set -euo pipefail

NS=fcg
DEPLOY=notifications-function
GW_PORT="${GW_PORT:-8020}"
GW="http://localhost:${GW_PORT}"
HOSTH="Host: api.fcg.local"
FALHAS=0

for bin in kubectl curl jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERRO: '$bin' não encontrado." >&2; exit 1; }
done

PF=""
EMAIL=""
TMPD="$(mktemp -d)"
cleanup() {
  [ -n "$PF" ] && kill "$PF" 2>/dev/null || true
  # O teste cadastra um usuário REAL para gerar o UserCreatedEvent. Sem esta limpeza o script
  # deixaria resíduo permanente no usersdb a cada execução.
  if [ -n "$EMAIL" ]; then
    # DOIS bancos, e a primeira versao desta limpeza so cuidava do primeiro:
    #   usersdb.usuarios          -> a conta que o teste cadastra
    #   notificationsdb.notifications -> a Function grava TODA notificacao enviada. Sem isto o
    #     script acumulava um documento por execucao (medido: 29 -> 30), e a tabela do README
    #     afirmava "residuo zero" com base so no usersdb.
    # NAO se mexe em refresh_tokens aqui: este teste nao faz login (zero chamadas a /auth/login) e
    # um cadastro nao gera refresh_token (medido: 43 -> 43). A versao anterior herdou esse delete do
    # gateway-test.sh, onde ele faz sentido; aqui so poderia apagar sessao de TERCEIRO que logasse
    # durante os vários minutos de execucao.
    kubectl -n "$NS" exec mongodb-0 -- mongosh --quiet usersdb --eval \
      "var u=db.usuarios.findOne({Email:'$EMAIL'},{_id:1}); if (u) { db.usuarios.deleteOne({_id:u._id}); }" \
      >/dev/null 2>&1 || echo "  AVISO: nao consegui remover o usuario de teste (${EMAIL})" >&2
    # Sem espera bounded aqui, ao contrário do gateway-test.sh, e de propósito: a asserção 9 já
    # esperou o `Executed ... Succeeded`, então quando o cleanup roda o documento JÁ existe. A janela
    # remanescente é apenas um Ctrl-C logo após o disparo, antes da asserção 9.
    kubectl -n "$NS" exec mongodb-0 -- mongosh --quiet notificationsdb --eval \
      "db.notifications.deleteMany({Recipient:'$EMAIL'});" \
      >/dev/null 2>&1 || echo "  AVISO: nao consegui remover a notificacao de teste (${EMAIL})" >&2
  fi
  rm -rf "$TMPD"
}
trap cleanup EXIT

check() { # nome, esperado, obtido
  if [ "$2" = "$3" ]; then printf "  OK   %-46s %s\n" "$1" "$3"
  else printf "  FALHA %-45s esperado=%s obtido=%s\n" "$1" "$2" "$3"; FALHAS=$((FALHAS+1)); fi
}
replicas() { kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}' 2>/dev/null; }
# ⚠️ A contagem NÃO filtra Terminating, e essa é a diferença entre um teste honesto e um falso
# positivo. Um pod em Terminating ainda tem o consumer AMQP atado e drena mensagem — então tanto para
# "está ocioso?" quanto para "subiu pod novo?" o que vale é o TOTAL. Uma versão anterior filtrava
# `Terminating` e, com `terminationGracePeriodSeconds=30` (default; o manifesto não declara), devolvia
# 0 com um pod vivo por até 30s: a asserção 8 reportava "o KEDA acordou a Function" olhando o pod do
# ciclo ANTERIOR.
pods_totais() { kubectl -n "$NS" get pods -l "app=$DEPLOY" --no-headers 2>/dev/null | wc -l | tr -d ' '; }
pods_nomes()  { kubectl -n "$NS" get pods -l "app=$DEPLOY" -o name 2>/dev/null | tr '\n' ' ' || true; }
fila() { kubectl -n "$NS" exec deploy/rabbitmq -- rabbitmqctl list_queues name messages 2>/dev/null \
  | awk -v q="$1" '$1==q{print $2}'; }

echo "==> Pré-condições do KEDA"
# `|| true` obrigatório: atribuição por substituição de comando propaga o status, e sob `set -e` o
# script morria SEM IMPRIMIR NADA justamente quando o ScaledObject não existe — o caso que esta
# asserção existe para reportar. O fallback `ausente` era código morto.
READY=$(kubectl -n "$NS" get scaledobject "$DEPLOY" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
check "1. ScaledObject Ready" "True" "${READY:-ausente}"
# Sem este HPA o KEDA não está de fato no controle da escala.
# `|| true` obrigatorio: sem HPA, o `kubectl get -o name` sai != 0 e, sob `set -euo pipefail`, o
# script morreria justamente no caso que esta assercao existe para reportar.
HPA=$(kubectl -n "$NS" get hpa "keda-hpa-$DEPLOY" -o name 2>/dev/null | wc -l | tr -d ' ' || true)
check "2. HPA gerenciado pelo KEDA existe" "1" "$HPA"
# As duas filas vêm do definitions.json assado na imagem do broker; o RabbitMQTrigger apenas
# CONSOME de fila existente, então ausência de fila aqui seria evento descartado em silêncio.
for q in notifications-user-created notifications-payment-processed; do
  EX=$(kubectl -n "$NS" exec deploy/rabbitmq -- rabbitmqctl list_queues name 2>/dev/null | grep -cx "$q" || true)
  check "3. fila $q existe" "1" "$EX"
done

echo "==> Estado OCIOSO (o requisito de otimização de recursos)"
# ESPERA o ocioso antes de AFIRMAR o ocioso. Sem isto o script reprovava espuriamente sempre que
# qualquer evento recente tivesse acordado a Function. Medido: rodar o gateway-test.sh minutos antes
# deixa a Function de pé dentro do `cooldownPeriod`, e as asserções 4, 5 e 6 reprovaram num sistema
# ÍNTEGRO — o sintoma revelador foi "pod apareceu em 0s do disparo", porque o pod já estava lá.
# Teto = cooldownPeriod (60s) + margem para a virada do HPA.
echo "     aguardando o estado ocioso (até 150s)"
for _ in $(seq 1 30); do
  if [ "$(replicas)" = "0" ] && [ "$(pods_totais)" -eq 0 ]; then break; fi
  sleep 5
done
check "4. Deployment em 0 replica" "0" "$(replicas)"
check "5. nenhum pod da Function" "0" "$(pods_totais)"
# `Active` fica `Unknown` por alguns segundos logo após o ScaledObject ser criado (observado 2x,
# assentando em <=5s) — EM SISTEMA ÍNTEGRO. Com o scaler quebrado ele fica `Unknown` indefinidamente,
# e então este laço queima os 60s inteiros e a asserção reprova: resultado certo, só mais lento.
# Sem a espera, um keda-test.sh disparado logo depois do deploy reprovaria por janela transitória.
for _ in $(seq 1 12); do
  ATIVO=$(kubectl -n "$NS" get scaledobject "$DEPLOY" \
    -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null || true)
  [ "$ATIVO" = "Unknown" ] || break
  sleep 5
done
check "6. ScaledObject Active=False (fila vazia)" "False" "${ATIVO:-ausente}"

# Pods existentes ANTES do disparo. A asserção 8 tem de exigir um pod DIFERENTE, não "algum pod":
# um pod do ciclo anterior ainda em Terminating era contado como "o KEDA acordou a Function", e isso
# foi medido como FALSO POSITIVO — o log do operador não registrava terceiro ciclo de escala, não
# havia SuccessfulCreate novo, e o ReplicaSet seguia sem pod.
echo "==> DISPARO: evento real pelo gateway"
kubectl -n kong port-forward svc/kong-kong-proxy "${GW_PORT}:80" >"$TMPD/pf.log" 2>&1 &
PF=$!
for _ in $(seq 1 30); do curl -s -o /dev/null "$GW" && break; sleep 1; done
# Capturado AQUI, e não antes da espera do port-forward (que leva até 30s): quanto menor a janela
# entre a captura e o disparo, menor a chance de um pod nascido no meio ser contado como "novo".
PODS_ANTES="$(pods_nomes)"
EMAIL="keda-$(date +%s)-$RANDOM@fcg.com"
printf '{"nome":"KEDA Teste","email":"%s","senha":"Teste@123456"}' "$EMAIL" > "$TMPD/signup.json"
COD=$(curl -s -o /dev/null -w '%{http_code}' -H "$HOSTH" -H 'Content-Type: application/json' \
  --data-binary @"$TMPD/signup.json" "$GW/api/v1/usuarios")
T0=$(date +%s)
check "7. cadastro publico -> 201" "201" "$COD"

echo "==> ESCALA 0 -> 1"
# Margem generosa sobre o pollingInterval (15s): a imagem da Function é amd64 rodando sob emulação
# neste host arm64, então a partida é mais lenta que a dos demais serviços.
SUBIU=nao
for _ in $(seq 1 30); do
  for P in $(pods_nomes); do
    case " $PODS_ANTES " in
      *" $P "*) ;;            # pod que já existia antes do disparo: não conta
      *) SUBIU=sim ;;
    esac
  done
  [ "$SUBIU" = "sim" ] && break
  sleep 5
done
check "8. KEDA acordou a Function" "sim" "$SUBIU"
[ "$SUBIU" = "sim" ] && printf "       (pod apareceu em %ss do disparo)\n" "$(( $(date +%s) - T0 ))"

echo "==> A Function PROCESSOU a mensagem?"
POD=$(kubectl -n "$NS" get pods -l "app=$DEPLOY" --no-headers -o custom-columns=N:.metadata.name 2>/dev/null | head -1 || true)
PROC=nao
if [ -n "$POD" ]; then
  kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=120s >/dev/null 2>&1 || true
  for _ in $(seq 1 24); do
    if kubectl -n "$NS" logs "$POD" --tail=200 2>/dev/null \
       | grep -q "Executed 'Functions.UserCreatedFunction' (Succeeded"; then PROC=sim; break; fi
    sleep 5
  done
fi
# Asserção de EXECUÇÃO, não de "pod subiu": um pod que sobe e falha ao processar deixaria o teste
# verde se olhássemos só a contagem de réplicas.
check "9. UserCreatedFunction executou com sucesso" "sim" "$PROC"
check "10. fila drenada" "0" "$(fila notifications-user-created)"

echo "==> ESCALA 1 -> 0 (cooldownPeriod=60s)"
VOLTOU=nao
for _ in $(seq 1 40); do
  [ "$(replicas)" = "0" ] && { VOLTOU=sim; break; }
  sleep 6
done
check "11. voltou a 0 replica" "sim" "$VOLTOU"
[ "$VOLTOU" = "sim" ] && printf "       (voltou a zero em %ss do disparo)\n" "$(( $(date +%s) - T0 ))"

echo
if [ "$FALHAS" -eq 0 ]; then echo "Matriz do KEDA: TODOS os testes passaram."; else
  echo "Matriz do KEDA: $FALHAS teste(s) FALHARAM."; exit 1; fi

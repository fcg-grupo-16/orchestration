#!/usr/bin/env bash
# Remove todos os recursos FCG do cluster (namespace fcg) e o API Gateway (namespace kong).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ORDEM IMPORTA: os recursos de k8s/gateway/ são CRDs do Kong (KongPlugin, KongConsumer). Se o
# `helm uninstall` rodasse primeiro, os CRDs iriam embora e este delete falharia com
# "no matches for kind KongPlugin" — sob `set -euo pipefail` isso abortaria o script ANTES de
# remover o resto da plataforma. Por isso os manifestos saem primeiro, o gateway depois.
#
# O `|| true` cobre o caso de alguém já ter desinstalado o Kong à mão: aí os CRDs não existem, o
# delete reclama, e não queremos que isso impeça a limpeza do namespace fcg.
# SF4: o `|| true` amplo escondia QUALQUER falha (cluster inalcançável, RBAC, manifesto inválido)
# e o script seguia até imprimir "removidos" com exit 0. Agora só o caso legítimo é tolerado: CRD
# do Kong ausente (alguém já desinstalou o gateway à mão). Qualquer outro erro aborta.
echo "==> Removendo os manifestos (namespace fcg + gateway)"
if ! ERRO=$(kubectl delete -R -f "$ROOT_DIR/k8s/" --ignore-not-found 2>&1); then
  if echo "$ERRO" | grep -q "no matches for kind"; then
    echo "   aviso: CRDs do Kong ou do KEDA ausentes (já removidos à mão) — seguindo"
    echo "$ERRO" | grep -v "no matches for kind" || true
  else
    echo "$ERRO" >&2
    echo "ERRO: falha ao remover os manifestos. Abortando para não reportar sucesso falso." >&2
    exit 1
  fi
else
  echo "$ERRO"
fi

# O Kong é instalado por Helm pelo deploy-minikube.sh, então não sai com `kubectl delete -f`.
# Sem este passo sobravam o release, o namespace, os CRDs, o webhook de admissão e a NodePort
# 30080 — deploy e undeploy ficavam assimétricos.
if command -v helm >/dev/null 2>&1 && helm -n kong status kong >/dev/null 2>&1; then
  echo "==> Desinstalando o Kong (release Helm)"
  # Sem tratamento, uma falha aqui era engolida e o `delete namespace` seguinte apagava os objetos
  # de todo jeito, deixando o release ÓRFÃO no storage do Helm sem sinal nenhum.
  helm -n kong uninstall kong --wait \
    || { echo "ERRO: 'helm uninstall kong' falhou; o release pode ter ficado órfão no storage do" >&2
         echo "      Helm. Verifique com 'helm -n kong list' antes de reinstalar." >&2; exit 1; }
fi
kubectl delete namespace kong --ignore-not-found

# Os CRDs são cluster-scoped e o `helm uninstall` não os remove (o chart os marca para
# preservação, de propósito: removê-los apagaria recursos de QUALQUER outro release do Kong).
#
# SF5: antes isto era incondicional. Se houvesse outro release do Kong no cluster, apagar os CRDs
# levaria em cascata os KongPlugin/KongConsumer dele. Agora só removemos se não houver outro
# release nem CR do Kong fora do namespace fcg.
# SF6: o `-f` do `helm list` filtra pelo NOME do release, não pelo chart. Com '^kong$' um segundo
# Kong chamado `kong-dev` ou `my-kong` não casava, o guard via 0 e os CRDs cluster-wide eram
# apagados, levando os CRs daquele release em cascata — exatamente o dano que este bloco previne.
# Agora o filtro é pelo CHART (kong-*) em QUALQUER namespace, inclusive `kong`. Excluir o namespace
# `kong` — como esta linha fazia — deixava escapar justamente um `kong-dev` instalado nele, ou seja,
# reproduzia o defeito que o parágrafo acima descreve. E a exclusão era desnecessária: a NOSSA
# release já foi desinstalada acima, então não há o que excluir da contagem.
# ⚠️ FAIL-SAFE: qualquer sonda que NÃO CONSIGA se pronunciar PRESERVA os CRDs.
# A primeira versão deste guard falhava ABERTO: `... || echo 0` em pipeline quebrada (python3
# ausente, kind inexistente) era lido como "não há outro release do Kong", e os CRDs eram apagados
# justamente no caso em que não se sabia se havia. Guard de segurança tem de falhar fechado.
PRESERVAR=""

if command -v python3 >/dev/null 2>&1; then
  OUTROS_RELEASES=$(helm list -A -o json 2>/dev/null \
    | python3 -c 'import sys,json;print(sum(1 for r in json.load(sys.stdin) if r.get("chart","").startswith("kong-")))' 2>/dev/null) \
    || PRESERVAR="não foi possível inspecionar os releases Helm"
  [ -n "${OUTROS_RELEASES:-}" ] || PRESERVAR="${PRESERVAR:-lista de releases Helm vazia ou ilegível}"
else
  PRESERVAR="python3 ausente — sem como inspecionar os releases Helm com segurança"
fi

# Os kinds vêm DO CLUSTER, não de uma lista fixa: hardcodar um kind que a versão instalada do KIC
# não tenha faz o `kubectl get` falhar INTEIRO e devolver vazio — outro caminho de falha aberta.
# TODOS os grupos que terminam em konghq.com, não só `configuration.`: assim o guard e o delete
# usam a MESMA lista. Enumerar só um grupo fazia o delete (que casava `konghq.com$`) ter escopo MAIOR
# que o guard — e, ao alinhá-los pelo grupo fixo, um grupo novo trazido por upgrade do KIC passaria a
# ser ignorado em silêncio nos dois.
KINDS=$(kubectl api-resources -o name 2>/dev/null | grep 'konghq\.com$' | tr '\n' ',' | sed 's/,$//')
if [ -n "$KINDS" ]; then
  # NOTA: KongClusterPlugin, KongVault e KongLicense são CLUSTER-SCOPED e saem sem coluna de
  # namespace, então `$1!="fcg"` os conta como "fora de fcg". Isso falha FECHADO (preserva os CRDs),
  # que é o comportamento certo aqui — mas se a plataforma um dia adotar um KongClusterPlugin, o
  # undeploy passa a nunca limpar os CRDs, com a mensagem enganosa "há CRs fora de fcg".
  # O status do `kubectl` tem de ser TESTADO, não descartado: em pipeline o exit é o do último
  # comando (`wc`), então `kubectl get | awk | wc` falhando devolvia CRS_FORA=0 com exit 0 — a sonda
  # se pronunciava com confiança FALSA e os CRDs eram apagados. Medido: com kind inexistente,
  # CRS_FORA='0' e exit=0. Era o MESMO fail-open que o comentário 8 linhas acima diz evitar.
  if CRS_OUT=$(kubectl get "$KINDS" -A --no-headers 2>/dev/null); then
    CRS_FORA=$(printf '%s\n' "$CRS_OUT" | awk 'NF && $1!="fcg"' | wc -l | tr -d ' ')
  else
    PRESERVAR="${PRESERVAR:-não foi possível listar os CRs do Kong}"
  fi
else
  PRESERVAR="${PRESERVAR:-não foi possível enumerar os kinds de configuration.konghq.com}"
fi
if [ -z "$PRESERVAR" ] && [ "${OUTROS_RELEASES:-0}" -eq 0 ] && [ "${CRS_FORA:-0}" -eq 0 ]; then
  echo "==> Removendo os CRDs do Kong"
  # Derivado da MESMA enumeração do guard: antes o guard olhava só `configuration.konghq.com` e o
  # delete apagava tudo que casasse `konghq.com$` — divergência latente (hoje o chart 3.4.1 só tem
  # CRDs desse grupo, mas nada garantia isso). Sem `xargs -r`, que não existe no xargs do BSD/macOS:
  # aqui $KINDS é comprovadamente não-vazio, então a expansão direta é segura.
  # shellcheck disable=SC2046
  kubectl delete crd $(echo "$KINDS" | tr ',' ' ') --ignore-not-found
else
  echo "==> CRDs do Kong PRESERVADOS: ${PRESERVAR:-há release kong-* no cluster \
(${OUTROS_RELEASES:-?}) — pode ser a nossa, se o uninstall acima não rodou — ou CRs fora de fcg \
(${CRS_FORA:-?})}"
fi

# --- KEDA: o deploy instala, o undeploy remove (mesma simetria exigida do Kong) ---
#
# Sem este bloco sobravam o namespace `keda`, os três deployments (operator, metrics-apiserver,
# admission), o webhook de admissão, o apiservice de external metrics e os seis CRDs `keda.sh` —
# enquanto o `k8s/50-keda-notifications.yaml` saía junto dos manifestos acima. Resultado: um
# operador de pé sem nada para reconciliar.
#
# A ORDEM já está garantida: os CRs (ScaledObject/TriggerAuthentication) vivem em `k8s/` e são
# removidos no primeiro passo deste script, antes dos CRDs saírem aqui.
#
# ⚠️ A versão TEM de casar com a do deploy-minikube.sh — a remoção é `delete` da MESMA URL pinada.
KEDA_VERSION="2.20.2"

# Guard análogo ao dos CRDs do Kong, e fail-CLOSED pelo mesmo motivo: o manifesto do release inclui
# os CRDs, que são cluster-scoped. Removê-los levaria em cascata os ScaledObject de QUALQUER outro
# time no cluster. Se a sonda não conseguir se pronunciar, preservamos.
PRESERVAR_KEDA=""
KEDA_KINDS=$(kubectl api-resources -o name 2>/dev/null | grep 'keda\.sh$' | tr '\n' ',' | sed 's/,$//')
if [ -z "$KEDA_KINDS" ]; then
  PRESERVAR_KEDA="nenhum CRD keda.sh no cluster (KEDA já removido, ou nunca instalado)"
elif KEDA_OUT=$(kubectl get "$KEDA_KINDS" -A --no-headers 2>/dev/null); then
  # `$1!="fcg"` também conta CRs cluster-scoped (que saem sem coluna de namespace) — falha fechado.
  KEDA_FORA=$(printf '%s\n' "$KEDA_OUT" | awk 'NF && $1!="fcg"' | wc -l | tr -d ' ')
else
  PRESERVAR_KEDA="não foi possível listar os CRs do KEDA"
fi

if [ -z "$PRESERVAR_KEDA" ] && [ "${KEDA_FORA:-0}" -eq 0 ]; then
  echo "==> Removendo o KEDA v$KEDA_VERSION"
  kubectl delete --ignore-not-found \
    -f "https://github.com/kedacore/keda/releases/download/v${KEDA_VERSION}/keda-${KEDA_VERSION}.yaml"
else
  echo "==> KEDA PRESERVADO: ${PRESERVAR_KEDA:-há CRs do KEDA fora de fcg (${KEDA_FORA:-?})}"
fi

echo "Recursos FCG, gateway e KEDA removidos."

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
    echo "   aviso: CRDs do Kong ausentes (gateway já removido) — seguindo"
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
  helm -n kong uninstall kong --wait || true
fi
kubectl delete namespace kong --ignore-not-found

# Os CRDs são cluster-scoped e o `helm uninstall` não os remove (o chart os marca para
# preservação, de propósito: removê-los apagaria recursos de QUALQUER outro release do Kong).
#
# SF5: antes isto era incondicional. Se houvesse outro release do Kong no cluster, apagar os CRDs
# levaria em cascata os KongPlugin/KongConsumer dele. Agora só removemos se não houver outro
# release nem CR do Kong fora do namespace fcg.
OUTROS_RELEASES=$(helm list -A -f '^kong$' -o json 2>/dev/null | grep -c '"name"' || true)
CRS_FORA=$(kubectl get kongplugins,kongconsumers -A --no-headers 2>/dev/null | awk '$1!="fcg"' | wc -l | tr -d ' ')
if [ "${OUTROS_RELEASES:-0}" -eq 0 ] && [ "${CRS_FORA:-0}" -eq 0 ]; then
  echo "==> Removendo os CRDs do Kong"
  kubectl get crd -o name 2>/dev/null | grep 'konghq.com$' | xargs -r kubectl delete --ignore-not-found
else
  echo "==> CRDs do Kong PRESERVADOS: há outro release (${OUTROS_RELEASES}) ou CRs fora de fcg (${CRS_FORA})"
fi

echo "Recursos FCG e gateway removidos."

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
echo "==> Removendo os manifestos (namespace fcg + gateway)"
kubectl delete -R -f "$ROOT_DIR/k8s/" --ignore-not-found || true

# O Kong é instalado por Helm pelo deploy-minikube.sh, então não sai com `kubectl delete -f`.
# Sem este passo sobravam o release, o namespace, os CRDs, o webhook de admissão e a NodePort
# 30080 — deploy e undeploy ficavam assimétricos.
if command -v helm >/dev/null 2>&1 && helm -n kong status kong >/dev/null 2>&1; then
  echo "==> Desinstalando o Kong (release Helm)"
  helm -n kong uninstall kong --wait || true
fi
kubectl delete namespace kong --ignore-not-found

# Os CRDs são cluster-scoped e o `helm uninstall` não os remove (o chart os marca para
# preservação, de propósito: removê-los apagaria recursos de qualquer outro release do Kong).
# Removemos explicitamente porque neste cluster de demonstração o Kong é só nosso.
echo "==> Removendo os CRDs do Kong"
kubectl get crd -o name 2>/dev/null | grep 'konghq.com$' | xargs -r kubectl delete --ignore-not-found

echo "Recursos FCG e gateway removidos."

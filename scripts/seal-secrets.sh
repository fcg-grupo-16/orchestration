#!/usr/bin/env bash
# (Re)gera k8s/05-sealed-secrets.yaml cifrando os Secrets da plataforma com kubeseal.
#
# Os VALORES abaixo são placeholders de DEMONSTRAÇÃO (idênticos aos que ficavam em claro
# nos manifestos). Para segredos REAIS, exporte as variáveis de ambiente correspondentes
# ANTES de rodar — assim os valores reais nunca são comitados neste script.
#
# Rotação: para trocar um valor, exporte a env var (ou edite o default de demo), rode este
# script e comite o k8s/05-sealed-secrets.yaml regenerado. O controller atualiza o Secret.
#
# Pré-requisitos:
#   - kubeseal instalado (brew install kubeseal)
#   - controller sealed-secrets rodando no cluster (namespace kube-system)
# Uso: ./scripts/seal-secrets.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/../k8s/05-sealed-secrets.yaml"
NS="fcg"
CONTROLLER_NS="kube-system"

# --- valores e composição: FONTE ÚNICA compartilhada com publicar-segredos-aws.sh (#65) ---
# shellcheck source=lib/segredos-plataforma.sh
source "$SCRIPT_DIR/lib/segredos-plataforma.sh"


command -v kubeseal >/dev/null || { echo "ERRO: kubeseal não encontrado (brew install kubeseal)." >&2; exit 1; }
command -v kubectl  >/dev/null || { echo "ERRO: kubectl não encontrado." >&2; exit 1; }
kubectl -n "$CONTROLLER_NS" get deploy sealed-secrets-controller >/dev/null 2>&1 || {
  echo "ERRO: controller sealed-secrets não encontrado no namespace $CONTROLLER_NS." >&2
  echo "      Instale-o primeiro (ver scripts/deploy-minikube.sh ou o README)." >&2
  exit 1
}
# Aguarda o controller ficar pronto antes de selar: o kubeseal busca o cert público dele;
# se ainda não estiver Ready, o seal falharia de forma menos clara mais adiante.
kubectl -n "$CONTROLLER_NS" rollout status deploy/sealed-secrets-controller --timeout=120s >/dev/null

# seal <name> <label-app|""> <KEY=VALUE>...
#   gera um Secret em claro (dry-run, nunca aplicado), rotula e o cifra -> SealedSecret.
seal() {
  local name="$1" label_app="$2"; shift 2
  local args=()
  local kv
  for kv in "$@"; do args+=(--from-literal="$kv"); done
  local secret
  secret="$(kubectl create secret generic "$name" -n "$NS" "${args[@]}" --dry-run=client -o json)"
  if [ -n "$label_app" ]; then
    secret="$(printf '%s' "$secret" | kubectl label --local -f - -o json "app=$label_app")"
  fi
  printf '%s' "$secret" | kubeseal --controller-namespace "$CONTROLLER_NS" --format yaml --scope strict
}

{
  echo "# GERADO por scripts/seal-secrets.sh — NÃO editar à mão."
  echo "#"
  echo "# SealedSecrets cifrados (Bitnami Sealed Secrets). SEGUROS para versionar: apenas o"
  echo "# controller DESTE cluster (namespace $CONTROLLER_NS) consegue decifrá-los. Os valores"
  echo "# são de DEMONSTRAÇÃO. Para regenerar/rotacionar: ./scripts/seal-secrets.sh"
  echo "#"
  echo "# JwtSettings__SecretKey é IDÊNTICA em users-api-secret e catalog-api-secret (JWT parity)."
  echo "# ServiceAuth__SecretKey é IDÊNTICA em users-api-secret e notifications-function-secret, e"
  echo "# obrigatoriamente DIFERENTE da JwtSettings__SecretKey (separação de privilégio, #9)."
  segredos_da_plataforma seal
} > "$OUT"

# `|| true`: grep -c retorna exit 1 quando a contagem é 0, o que sob `set -e` encerraria o
# script mesmo tendo gerado o arquivo. Neutralizamos para reportar a contagem com segurança.
COUNT="$(grep -c 'kind: SealedSecret' "$OUT" || true)"
echo "OK: $OUT gerado ($COUNT SealedSecrets)."

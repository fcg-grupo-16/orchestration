#!/usr/bin/env bash
# Regenera k8s/41b-grafana-dashboard.yaml a partir de observability/fcg-overview.json.
#
# O ConfigMap é DERIVADO: a fonte da verdade é o JSON em k8s/observability/. Editar o YAML
# gerado à mão faz a próxima regeneração descartar a mudança.
#
# Usamos block scalar (`|`) em vez de `kubectl create configmap --from-file`, que embute o JSON
# como uma string escapada de uma linha só — válida, mas ilegível em code review.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$ROOT_DIR/observability/fcg-overview.json"
OUT="$ROOT_DIR/k8s/41b-grafana-dashboard.yaml"

command -v python3 >/dev/null || { echo "ERRO: python3 não encontrado." >&2; exit 1; }
python3 -m json.tool "$SRC" > /dev/null || { echo "ERRO: $SRC não é JSON válido." >&2; exit 1; }

python3 - "$SRC" "$OUT" <<'PY'
import pathlib, sys
src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
body = "".join("    " + ln if ln.strip() else "\n" for ln in src.read_text().splitlines(keepends=True))
out.write_text(f"""# GERADO a partir de observability/fcg-overview.json — NÃO editar à mão.
#
# ConfigMap com o JSON do dashboard do Grafana, montado em /etc/grafana/dashboards pelo Deployment
# de k8s/41-observability-grafana.yaml. A FONTE DA VERDADE é o arquivo em k8s/observability/;
# este aqui é derivado dele.
#
# Para regenerar depois de editar o dashboard:
#   ./scripts/gen-dashboard-configmap.sh
#
# Depois de alterar o dashboard, lembre de incrementar a annotation `fcg.dashboard/revision` no
# Deployment do Grafana — senão o `kubectl apply` atualiza só o ConfigMap e o Pod continua
# servindo o dashboard antigo até alguém matá-lo à mão.
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-fcg
  namespace: fcg
  labels:
    app: grafana
    app.kubernetes.io/part-of: fiap-cloud-games
data:
  fcg-overview.json: |
{body}""")
PY

echo "OK: $OUT regenerado a partir de $SRC."

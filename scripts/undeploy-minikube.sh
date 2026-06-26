#!/usr/bin/env bash
# Remove todos os recursos FCG do cluster (namespace fcg).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
kubectl delete -R -f "$ROOT_DIR/k8s/" --ignore-not-found
echo "Recursos FCG removidos."

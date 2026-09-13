#!/usr/bin/env bash
# Build das imagens dos 4 microsserviços, carga no minikube e deploy no cluster.
# Pré-requisitos: docker, minikube, kubectl.
# Uso: ./scripts/deploy-minikube.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PARENT_DIR="$(cd "$ROOT_DIR/.." && pwd)"
# notifications-api foi DEPRECADO na Fase 3 (#29), substituído pela notifications-function abaixo.
SERVICES=(users-api catalog-api payments-api)
# A notifications-function NÃO entra em SERVICES: o build dela precisa de `--platform linux/amd64`.
# Medido nesta máquina (host arm64, nó do minikube arm64): a base oficial
# `azure-functions/dotnet-isolated` publica SÓ linux/amd64 — conferido em 4-dotnet-isolated8.0,
# 9.0, 10.0, -appservice e -mariner; não existe variante arm64 em tag nenhuma. Sem `--platform` o
# build falha com `no match for platform in manifest`. A imagem amd64 EXECUTA no nó arm64 porque o
# minikube traz binfmt com handler `qemu-x86_64` habilitado (verificado: pod de teste imprimiu
# `x86_64` e saiu com 0). Custo: partida emulada, mais lenta que os demais serviços.
FUNCTIONS=(notifications-function)

# Pré-requisito NOVO desta fase: o Kong 3.x só é distribuído por Helm. Checado ANTES de qualquer
# mutação no cluster — sem isto, o script já teria aplicado o controller de Sealed Secrets e só
# então morreria em "helm: command not found", deixando o cluster em estado parcial.
# Mesmo padrão de scripts/seal-secrets.sh.
if ! command -v helm >/dev/null 2>&1; then
  echo "ERRO: 'helm' não encontrado. Instale com: brew install helm" >&2
  exit 1
fi

echo "==> Garantindo que o minikube está rodando"
minikube status >/dev/null 2>&1 || minikube start

# Controller Sealed Secrets: materializa os SealedSecrets cifrados de k8s/05-sealed-secrets.yaml
# em Secrets reais no namespace fcg. Precisa existir ANTES do `kubectl apply` (o CRD SealedSecret
# e o controller são pré-requisitos). Versão pinada (nunca latest) para reprodutibilidade.
SEALED_SECRETS_VERSION="v0.38.4"
echo "==> Garantindo o controller Sealed Secrets ($SEALED_SECRETS_VERSION)"
# `kubectl apply` é idempotente: aplicamos SEMPRE para reconciliar na versão pinada — se um
# controller de outra versão já existir, ele é atualizado (mantém a reprodutibilidade).
kubectl apply -f "https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/controller.yaml"
kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=120s

# API Gateway (Kong Ingress Controller, issue #26) — substitui o Ingress NGINX: porta de entrada
# ÚNICA (api.fcg.local) com validação de JWT na borda. Modo DB-less: a configuração vem 100% dos
# CRDs/Ingress versionados em k8s/gateway/, nunca de uma Admin API mutável.
#
# ORDEM IMPORTA: o Kong precisa estar instalado ANTES do `kubectl apply -R -f k8s/`, porque os
# CRDs KongPlugin/KongConsumer são pré-requisito dos manifestos em k8s/gateway/. Instalado depois,
# o apply falha com "no matches for kind KongPlugin".
#
# Versão do chart PINADA (nunca latest) para reprodutibilidade. O Kong 3.x só é distribuído por
# Helm — o antigo all-in-one-dbless.yaml foi descontinuado pelo projeto.
KEDA_VERSION="2.20.2"
KONG_CHART_VERSION="3.4.1"
echo "==> Instalando/atualizando o Kong Ingress Controller (chart $KONG_CHART_VERSION)"
helm repo add kong https://charts.konghq.com >/dev/null 2>&1 || true
helm repo update kong >/dev/null
kubectl create namespace kong --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install kong kong/kong \
  --version "$KONG_CHART_VERSION" \
  --namespace kong \
  --values "$ROOT_DIR/gateway/kong-values.yaml" \
  --wait --timeout 300s
kubectl -n kong rollout status deploy/kong-kong --timeout=300s

# --- KEDA (autoscaler orientado a eventos, Fase 3 / #29) ---
#
# Instalado por URL PINADA, seguindo o precedente do controller do Sealed Secrets neste mesmo
# script. NÃO versionamos o YAML em k8s/vendor/: ele entraria no `kubeconform -strict k8s/` do CI e
# no `kubectl apply -R -f k8s/` daqui — mesma razão que mantém gateway/kong-values.yaml e o
# dashboard do Grafana FORA de k8s/.
#
# `--server-side` é obrigatório: o apply clássico falha com `metadata.annotations: Too long` em
# manifestos com CRDs grandes como este.
#
# Vem ANTES do `kubectl apply` porque o ScaledObject de k8s/50-keda-notifications.yaml depende dos
# CRDs keda.sh.
echo "==> Garantindo o KEDA v$KEDA_VERSION"
kubectl apply --server-side \
  -f "https://github.com/kedacore/keda/releases/download/v${KEDA_VERSION}/keda-${KEDA_VERSION}.yaml"
# Nomes CONFERIDOS na v2.20.2 instalada: keda-operator, keda-metrics-apiserver e keda-admission.
# O passo a passo da issue #29 citava `keda-operator-metrics-apiserver`, que NÃO existe nesta versão
# (medido: `Error from server (NotFound)`).
for d in keda-operator keda-metrics-apiserver keda-admission; do
  kubectl -n keda rollout status "deploy/$d" --timeout=180s
done
# O HPA gerenciado pelo KEDA só funciona com este apiservice disponível.
kubectl wait --for=condition=Available --timeout=120s \
  apiservice/v1beta1.external.metrics.k8s.io

echo "==> Build das imagens locais (:local)"
# RabbitMQ custom (base oficial + plugin rabbitmq_delayed_message_exchange).
echo "   - fcg-rabbitmq"
docker build -t "fcg-rabbitmq:local" "$ROOT_DIR/docker/rabbitmq"
for svc in "${SERVICES[@]}"; do
  echo "   - $svc"
  docker build -t "${svc}:local" "$PARENT_DIR/${svc}"
done

for fn in "${FUNCTIONS[@]}"; do
  echo "   - $fn (linux/amd64: a base do Azure Functions não publica arm64)"
  docker build --platform linux/amd64 -t "${fn}:local" "$PARENT_DIR/${fn}"
done

echo "==> Carregando imagens no minikube"
minikube image load "fcg-rabbitmq:local"
for svc in "${SERVICES[@]}"; do
  minikube image load "${svc}:local"
done
for fn in "${FUNCTIONS[@]}"; do
  minikube image load "${fn}:local"
done

echo "==> Migração Deployment→StatefulSet do MongoDB (kinds diferentes; no-op em cluster limpo)"
kubectl -n fcg delete deployment mongodb --ignore-not-found

# Porta de entrada ÚNICA (issue #26): remove o Ingress NGINX legado.
# `kubectl apply -R -f k8s/` NUNCA deleta um objeto cujo manifesto saiu do diretório — então
# apagar k8s/30-ingress.yaml do git não basta: em qualquer cluster que já rodou a main, o
# `fcg-ingress` continuaria servindo users.fcg.local e catalog.fcg.local SEM validação de JWT,
# em paralelo ao Kong. O critério "porta de entrada única" seria falso fora de cluster limpo.
# No-op em cluster novo, como a migração do MongoDB acima.
echo "==> Removendo o Ingress NGINX legado (substituído pelo Kong)"
kubectl -n fcg delete ingress fcg-ingress --ignore-not-found

echo "==> Aplicando manifestos (kubectl apply -R -f k8s/)"
kubectl apply -R -f "$ROOT_DIR/k8s/"

echo "==> Aguardando infra (RabbitMQ Deployment, MongoDB StatefulSet) e microsserviços ficarem prontos"
kubectl -n fcg rollout status deploy/rabbitmq --timeout=180s
kubectl -n fcg rollout status statefulset/mongodb --timeout=180s
# Redis (cache distribuído, issue #25). Precisa estar Ready antes dos serviços: os initContainers
# `wait-for-redis` de users-api/catalog-api bloqueiam até a porta 6379 responder.
kubectl -n fcg rollout status deploy/redis --timeout=180s
for svc in "${SERVICES[@]}"; do
  kubectl -n fcg rollout status "deploy/${svc}" --timeout=180s
done
# FUNCTIONS NÃO entram neste laço de propósito: o KEDA mantém a notifications-function em ZERO
# réplica enquanto as filas estão vazias, e `kubectl rollout status` num Deployment de 0 réplica não
# é sinal útil de saúde. Quem valida a Function é o ciclo 0->1->0 (ver README, issue #29).

# Observabilidade (issue #27) — DEPOIS dos serviços e NÃO-FATAL, de propósito.
# Nenhum initContainer espera por eles, então nada da plataforma depende do rollout.
# E as imagens vêm do Docker Hub (grafana/grafana sozinho tem ~684 MB), ao contrário das dos
# serviços, que são pré-carregadas com `minikube image load`. Num cluster novo com rede modesta o
# pull pode passar do timeout — sob `set -e`, isso mataria o script e reportaria falha num deploy
# cuja parte essencial funcionou. Por isso o `|| echo`.
for obs in prometheus grafana jaeger; do
  kubectl -n fcg rollout status "deploy/${obs}" --timeout=300s \
    || echo "AVISO: '${obs}' ainda não está pronto (provavelmente baixando a imagem). A plataforma não depende dele."
done

echo
echo "==> Pods:"
kubectl -n fcg get pods
echo
echo
echo "Pronto. Acesso externo APENAS pelo API Gateway (porta de entrada única):"
echo "  1) Abra o proxy do Kong (no macOS com driver docker, port-forward é o caminho confiável):"
echo "       kubectl -n kong port-forward svc/kong-kong-proxy 8000:80"
echo "  2) Todas as chamadas levam o Host do gateway:"
echo "       GW=http://localhost:8000; H='Host: api.fcg.local'"
echo "       curl -i -H \"\$H\" \$GW/api/v1/jogos                      # 401 do KONG (sem token)"
echo "       TOKEN=\$(curl -s -H \"\$H\" -H 'Content-Type: application/json' \\"
echo "         -d '{\"email\":\"admin@fcg.com\",\"senha\":\"Admin@123456\"}' \\"
echo "         \$GW/api/v1/auth/login | jq -r .token)"
echo "       curl -i -H \"\$H\" -H \"Authorization: Bearer \$TOKEN\" \$GW/api/v1/jogos   # 200"
echo
echo "  O catálogo é [AllowAnonymous] no serviço, mas a BORDA exige token (decisão da #26)."
echo "  payments-api e notifications-function são event-driven: sem rota no gateway."
echo "  /health* e /metrics não são expostos — o Prometheus raspa os pods dentro do cluster."
echo
echo "Acesso direto aos Services (diagnóstico, sem passar pelo gateway):"
echo "  kubectl -n fcg port-forward svc/users-api 8081:80"
echo "  kubectl -n fcg port-forward svc/catalog-api 8082:80"
echo "  kubectl -n fcg port-forward svc/rabbitmq 15672:15672   # Management UI (guest/guest)"
echo
echo "Observabilidade (Opção A — Prometheus + Grafana; Jaeger para os traces):"
echo "  kubectl -n fcg port-forward svc/grafana 3000:3000        # admin/admin -> pasta FCG"
echo "  kubectl -n fcg port-forward svc/prometheus 9090:9090     # /targets"
echo "  kubectl -n fcg port-forward svc/jaeger 16686:16686       # traces"

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

# --- Tag por COMMIT, não `:local` (issue #40) -------------------------------------------------
# A tag móvel `:local` é a causa raiz de uma classe inteira de "deploy que não muda nada": quando a
# tag JÁ EXISTE no nó, `minikube image load` vira NO-OP SILENCIOSO (rc=0, saída vazia), porque um
# container em execução prende a referência e `minikube image rm` recusa sem `--force`. O pod segue
# `Running` servindo o binário ANTIGO e todo `kubectl get` diz que está tudo certo — foi assim que
# três requisitos da Fase 3 (métricas, avaliações, cache) ficaram invisíveis no cluster.
#
# MEDIDO: com tag NOVA o load funciona sempre (id no nó == id no host), porque não há o que colidir.
# Marcar pelo commit do repositório de origem torna a colisão impossível por construção, em vez de
# remediar a tag móvel depois — que voltaria a prender no deploy seguinte.
#
# Os manifestos versionados continuam com `:local` de propósito: são YAML puro, validável pelo
# kubeconform do CI e aplicável à mão. A substituição acontece numa cópia RENDERIZADA, abaixo.
tag_do_repo() { # <caminho do repo> [subcaminho do contexto de build] -> sha curto
  repo="$1"; escopo="${2:-}"
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    # Sem git (tarball, CI de terceiro): cai para um valor único por execução — nunca `:local`,
    # senão o no-op volta.
    echo "sem-git-$(date +%s)"
    return
  fi
  # O ESCOPO importa quando o contexto de build é uma SUBPASTA do repo. O broker é buildado de
  # docker/rabbitmq, e escopar a tag ao repositório inteiro fazia QUALQUER alteração aqui (um
  # comentário num script, por exemplo) gerar tag nova e RECRIAR o pod do RabbitMQ — churn de
  # conexões e filas por mudança em arquivo nenhum do contexto dele. Medido: o pod do broker foi
  # recriado num deploy cujas únicas alterações estavam em scripts/ e no CI.
  # Para os serviços não há escopo: o contexto de build é o repositório inteiro.
  if [ -n "$escopo" ]; then
    sha="$(git -C "$repo" log -1 --format=%h -- "$escopo")"
    sujo="$(git -C "$repo" status --porcelain -- "$escopo")"
  else
    sha="$(git -C "$repo" rev-parse --short HEAD)"
    sujo="$(git -C "$repo" status --porcelain)"
  fi
  if [ -n "$sujo" ]; then
    # Árvore suja: o SHA NÃO descreve o que está sendo buildado. Reusar a tag traria o no-op de
    # volta na próxima alteração não commitada, então cada build ganha uma tag própria.
    echo "${sha}-sujo-$(date +%s)"
  else
    echo "$sha"
  fi
}

# Mapa servico<TAB>tag. Arquivo em vez de array associativo de propósito: `declare -A` exige bash 4+
# e o /bin/bash do macOS é 3.2.
MAPA_TAGS="$(mktemp)"
RENDER_DIR=""
limpar() {
  rm -f "$MAPA_TAGS"
  [ -n "$RENDER_DIR" ] && rm -rf "$RENDER_DIR"
  return 0
}
trap limpar EXIT

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

echo "==> Build das imagens locais (tag = commit do repositório de origem)"
: > "$MAPA_TAGS"
# O RabbitMQ entra no MESMO esquema, e não é detalhe: a topologia das filas vem do
# definitions.json ASSADO na imagem, então um no-op de carga aqui serviria uma topologia velha —
# fila faltando significa evento descartado em silêncio. O build dele é deste repositório.
TAG="$(tag_do_repo "$ROOT_DIR" "docker/rabbitmq")"
printf '%s\t%s\n' "fcg-rabbitmq" "$TAG" >> "$MAPA_TAGS"
echo "   - fcg-rabbitmq -> fcg-rabbitmq:${TAG}"
docker build -t "fcg-rabbitmq:${TAG}" "$ROOT_DIR/docker/rabbitmq"
for svc in "${SERVICES[@]}"; do
  TAG="$(tag_do_repo "$PARENT_DIR/${svc}")"
  printf '%s\t%s\n' "$svc" "$TAG" >> "$MAPA_TAGS"
  echo "   - $svc -> ${svc}:${TAG}"
  docker build -t "${svc}:${TAG}" "$PARENT_DIR/${svc}"
done

for fn in "${FUNCTIONS[@]}"; do
  TAG="$(tag_do_repo "$PARENT_DIR/${fn}")"
  printf '%s\t%s\n' "$fn" "$TAG" >> "$MAPA_TAGS"
  echo "   - $fn -> ${fn}:${TAG} (linux/amd64: a base do Azure Functions não publica arm64)"
  docker build --platform linux/amd64 -t "${fn}:${TAG}" "$PARENT_DIR/${fn}"
done

echo "==> Carregando imagens no minikube"
# Com tag nova a cada commit o `image load` nunca colide e, portanto, nunca no-opa — que era o
# modo de falha da #40. Não há mais nenhum `docker save | minikube ssh docker load` aqui: além de
# ser remediação e não conserto, aquele pipe só funciona com `--native-ssh=false` (a forma padrão
# não encaminha stdin: "requested load from stdin, but stdin is empty").
while IFS="$(printf '\t')" read -r nome tag; do
  [ -n "$nome" ] || continue
  minikube image load "${nome}:${tag}"
done < "$MAPA_TAGS"

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

# Fase 3 (#29): o notifications-api foi SUBSTITUÍDO pela notifications-function. Apagar
# k8s/23-notifications-api.yaml do git NÃO basta, pela mesma razão do Ingress acima — e aqui a
# consequência é pior: num cluster que já rodou a main, o Deployment legado continua de pé, a
# imagem notifications-api:local continua carregada no minikube e o Secret continua resolvendo o
# envFrom dele. Resultado: ele e a Function viram COMPETING CONSUMERS das mesmas duas filas, cada
# e-mail sai por um dos dois de forma imprevisível, e o teste de aceite do KEDA fica não-determinístico.
# Bônus: o pod legado tem prometheus.io/scrape "true" e o Prometheus do cluster descobre por
# annotation de pod, então o target obsoleto reaparece.
# No-op em cluster limpo, como as duas limpezas acima.
echo "==> Removendo o notifications-api legado (substituído pela Function serverless)"
kubectl -n fcg delete deployment notifications-api --ignore-not-found
kubectl -n fcg delete service notifications-api --ignore-not-found
kubectl -n fcg delete configmap notifications-api-config --ignore-not-found
kubectl -n fcg delete sealedsecret notifications-api-secret --ignore-not-found
kubectl -n fcg delete secret notifications-api-secret --ignore-not-found
# A IMAGEM legada também fica no nó ocupando espaço depois que o Deployment some (encontrada em
# cluster que já rodou a Fase 2). Não-fatal.
minikube ssh -- docker rmi notifications-api:local >/dev/null 2>&1 </dev/null \
  && echo "   - imagem legada notifications-api:local removida do nó" || true

echo "==> Aplicando manifestos (cópia renderizada com as tags por commit)"
# Os arquivos em k8s/ ficam intocados, com `:local`. A troca é feita numa CÓPIA, para que:
#   • o repositório continue com YAML puro, validável offline pelo kubeconform do CI;
#   • mudar de commit mude o `image:` do spec e o rollout aconteça NATURALMENTE, sem
#     `rollout restart` — que, como medido na #40, não resolve nada quando o spec não muda.
RENDER_DIR="$(mktemp -d)"
cp -R "$ROOT_DIR/k8s/." "$RENDER_DIR/"
while IFS="$(printf '\t')" read -r nome tag; do
  [ -n "$nome" ] || continue
  # `sed -i.bak` funciona no BSD (macOS) e no GNU; o sufixo é removido logo abaixo.
  find "$RENDER_DIR" -name '*.yaml' -exec \
    sed -i.bak "s|image: ${nome}:local|image: ${nome}:${tag}|g" {} +
done < "$MAPA_TAGS"
find "$RENDER_DIR" -name '*.yaml.bak' -delete
# Falha ruidosa se alguma substituição não pegou: um `:local` remanescente num dos serviços
# significaria voltar silenciosamente ao comportamento que esta mudança existe para eliminar.
while IFS="$(printf '\t')" read -r nome tag; do
  [ -n "$nome" ] || continue
  if grep -rq "image: ${nome}:local" "$RENDER_DIR"; then
    echo "ERRO: '${nome}:local' sobreviveu à renderização — o manifesto mudou de formato?" >&2
    exit 1
  fi
done < "$MAPA_TAGS"
kubectl apply -R -f "$RENDER_DIR/"

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
# é sinal útil de saúde — esperaria para sempre por um pod que CORRETAMENTE não existe.
#
# O sinal disponível é a condição Ready do ScaledObject. Ela é NECESSÁRIA e NÃO SUFICIENTE: medido
# na #29, um ScaledObject com `queueName` inexistente também reporta Ready=True até o primeiro poll
# do trigger (~18s), só então caindo para TriggerError. Quem prova o scaler é o ciclo 0->1->0 do
# scripts/keda-test.sh.
if kubectl -n fcg get scaledobject notifications-function >/dev/null 2>&1; then
  kubectl -n fcg wait --for=condition=Ready scaledobject/notifications-function --timeout=120s
fi

# Poda das tags antigas no nó: sem isto o nó acumularia uma imagem por commit.
#
# ⚠️ TODO `minikube ssh` aqui leva `</dev/null`, e não é zelo: **`minikube ssh` lê o stdin**, e num
# `while read` alimentado por arquivo ou pipe ele CONSOME o resto da entrada — o laço roda uma vez
# e as demais linhas somem, sem erro nenhum. Medido: laço de 3 linhas com `minikube ssh` dentro
# executa 1 iteração; com `</dev/null`, 3. Foi exatamente assim que a primeira versão desta poda
# removeu só a PRIMEIRA entrada do mapa e deixou as outras quatro `:local` no nó — e o deploy
# terminou com exit 0. (`minikube image load` NÃO tem esse comportamento, também medido: por isso
# o laço de carga acima sempre funcionou.)
#
# A listagem do nó é feita UMA vez, antes do laço, em vez de uma vez por serviço.
echo "==> Podando tags antigas no nó"
TAGS_NO_NO="$(minikube ssh -- docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null </dev/null | tr -d '\r')"
while IFS="$(printf '\t')" read -r nome tag; do
  [ -n "$nome" ] || continue
  # ⚠️ O `|| true` é OBRIGATÓRIO e o motivo é sutil: quando um serviço NÃO tem tag antiga (o caso
  # comum — deploy sem mudança naquele repo), o `grep -v` não casa nada e sai 1. Sob `pipefail` o
  # pipeline inteiro vira não-zero, e sob `set -e` isso MATA O SCRIPT ali — depois de podar apenas
  # a primeira entrada do mapa. Medido: com `set -euo pipefail` o laço morre na iteração 2 com
  # exit 1; sem o `-e`, completa. O sintoma no deploy era mudo: a última linha impressa era
  # "Podando tags antigas no nó" e o `==> Pods:` seguinte nunca aparecia.
  CANDIDATAS="$(echo "$TAGS_NO_NO" | grep "^${nome}:" | grep -v "^${nome}:${tag}\$" || true)"
  [ -n "$CANDIDATAS" ] || continue
  echo "$CANDIDATAS" | while read -r antiga; do
    if minikube ssh -- docker rmi "$antiga" >/dev/null 2>&1 </dev/null; then
      echo "   - removida: $antiga"
    else
      # Não-fatal: uma tag presa não é motivo para reprovar um deploy que funcionou. Mas é
      # REPORTADA — a primeira versão engolia a recusa e a poda virava no-op invisível.
      echo "   - NÃO removida (ainda referenciada?): $antiga"
    fi
  done
done < "$MAPA_TAGS"

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
echo "Serverless (com a fila vazia o KEDA mantém em 0 réplica — é o comportamento esperado):"
echo "  kubectl -n fcg get deploy notifications-function        # deve mostrar 0/0"
echo "  kubectl -n fcg get scaledobject notifications-function  # Ready=True, Active=False"
echo "  ./scripts/keda-test.sh                                  # prova o ciclo 0 -> 1 -> 0"
echo
echo "Checklist da entrega (roda antes de gravar):"
echo "  ./scripts/verify-fase3.sh"
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

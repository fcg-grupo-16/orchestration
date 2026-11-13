#!/usr/bin/env bash
# Sobe a plataforma inteira no EKS (#68), depois do `terraform apply` da #62.
#
# É o equivalente AWS do deploy-minikube.sh. O que muda:
#   - imagens: do ECR (#63), pela tag do SHA da `main` de cada repositório, e não buildadas aqui;
#   - segredos: ExternalSecrets de k8s-aws/ no lugar dos SealedSecrets (#65, ADR 0011);
#   - gateway: Kong com Network Load Balancer público (#64), e não NodePort;
#   - host das rotas: o DNS do Load Balancer no lugar de api.fcg.local (não há domínio próprio).
#
# KEDA e External Secrets já vêm do Terraform. Depois do primeiro deploy, cada serviço se atualiza
# sozinho pelo CI (workflow deploy-servico.yml), com rolling update.
#
# Uso (com a credencial de sessão do lab no ambiente, ex.: AWS_PROFILE=academy):
#   ./scripts/deploy-eks.sh
#
# Variáveis opcionais:
#   TAG_<SERVICO>=<sha>   usa outra tag em vez da `main` (ex.: TAG_CATALOG_API=abc123...)
#   CONSTRUIR_LOCAL=1     se a imagem da `main` não estiver no ECR, constrói a partir do clone ao lado
#                         (../<servico>) e publica. Exige o clone LIMPO e na mesma revisão da `main`.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PARENT_DIR="$(cd "$ROOT_DIR/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"
ORG="fcg-grupo-16"
SERVICOS=(users-api catalog-api payments-api notifications-function)
KONG_CHART_VERSION="3.4.1"   # o mesmo do deploy-minikube.sh e do CI
NS="fcg"

for cmd in aws kubectl helm terraform docker git; do
  command -v "$cmd" >/dev/null || { echo "ERRO: '$cmd' não encontrado." >&2; exit 1; }
done
aws sts get-caller-identity > /dev/null 2>&1 || {
  echo "ERRO: sem credencial AWS válida. Inicie o Learner Lab e atualize ~/.aws/credentials." >&2
  exit 1
}

CLUSTER="$(terraform -chdir="$TF_DIR" output -raw nome_cluster)"
REGIAO="$(terraform -chdir="$TF_DIR" output -raw regiao)"
REGISTRY="$(terraform -chdir="$TF_DIR" output -raw registry)"

RENDER_DIR=""
KUBECONFIG_TMP="$(mktemp)"
limpar() {
  rm -f "$KUBECONFIG_TMP"
  [ -n "$RENDER_DIR" ] && rm -rf "$RENDER_DIR"
  return 0
}
trap limpar EXIT

# Kubeconfig EXPLÍCITO, nunca o contexto atual: ele pode ser o minikube, e aí tudo abaixo "funcionaria"
# no cluster errado. Exportado para o helm usar o mesmo.
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGIAO" --kubeconfig "$KUBECONFIG_TMP" > /dev/null
export KUBECONFIG="$KUBECONFIG_TMP"
echo "==> Cluster: $(kubectl config current-context)"

aws ecr get-login-password --region "$REGIAO" | docker login --username AWS --password-stdin "$REGISTRY" > /dev/null

imagem_existe() { # <repositorio> <tag>
  aws ecr describe-images --region "$REGIAO" --repository-name "fcg/$1" \
    --image-ids "imageTag=$2" > /dev/null 2>&1
}

publicar_local() { # <nome> <contexto de build> <tag>
  # linux/amd64: os nós são t3 (x86). Construir no Mac arm64 sem --platform geraria uma imagem que
  # o nó não executa ("exec format error"), e o pod ficaria em CrashLoopBackOff.
  docker build --platform linux/amd64 -t "$REGISTRY/fcg/$1:$3" "$2"
  docker push "$REGISTRY/fcg/$1:$3"
}

echo "==> Resolvendo as imagens"
MAPA="$(mktemp)"
trap 'limpar; rm -f "$MAPA"' EXIT

for svc in "${SERVICOS[@]}"; do
  var="TAG_$(echo "$svc" | tr '[:lower:]-' '[:upper:]_')"
  tag="${!var:-}"
  if [ -z "$tag" ]; then
    # A `main` do GitHub, e não o clone local: é o que garante que produção reflete a `main`.
    tag="$(git ls-remote "https://github.com/$ORG/$svc.git" refs/heads/main | cut -f1)"
    [ -n "$tag" ] || { echo "ERRO: não consegui ler a main de $ORG/$svc." >&2; exit 1; }
  fi
  if ! imagem_existe "$svc" "$tag"; then
    if [ "${CONSTRUIR_LOCAL:-0}" = "1" ]; then
      repo="$PARENT_DIR/$svc"
      [ "$(git -C "$repo" rev-parse HEAD 2>/dev/null)" = "$tag" ] \
        && [ -z "$(git -C "$repo" status --porcelain)" ] || {
        echo "ERRO: $repo não está limpo e em $tag. Faça checkout da main atualizada antes." >&2
        exit 1
      }
      echo "   - $svc: $tag não está no ECR; construindo do clone local"
      publicar_local "$svc" "$repo" "$tag"
    else
      echo "ERRO: fcg/$svc:$tag não está no ECR." >&2
      echo "      O CI publica na main quando a variável AWS_DEPLOY_HABILITADO da organização é 'true'." >&2
      echo "      Para publicar daqui: CONSTRUIR_LOCAL=1 $0" >&2
      exit 1
    fi
  fi
  echo "   - $svc -> fcg/$svc:$tag"
  printf '%s\t%s\n' "$svc" "$tag" >> "$MAPA"
done

# O broker é imagem deste repositório (topologia das filas assada no definitions.json). A tag é o
# último commit que tocou docker/rabbitmq, como no deploy-minikube.sh, e ela é publicada daqui se faltar.
tag_rabbit="$(git -C "$ROOT_DIR" log -1 --format=%H -- docker/rabbitmq)"
if [ -n "$(git -C "$ROOT_DIR" status --porcelain -- docker/rabbitmq)" ]; then
  echo "ERRO: docker/rabbitmq tem mudança não commitada; a imagem não bateria com a tag." >&2
  exit 1
fi
if ! imagem_existe fcg-rabbitmq "$tag_rabbit"; then
  echo "   - fcg-rabbitmq: publicando $tag_rabbit"
  publicar_local fcg-rabbitmq "$ROOT_DIR/docker/rabbitmq" "$tag_rabbit"
fi
echo "   - fcg-rabbitmq -> fcg/fcg-rabbitmq:$tag_rabbit"
printf '%s\t%s\n' "fcg-rabbitmq" "$tag_rabbit" >> "$MAPA"

echo "==> Kong com Network Load Balancer (chart $KONG_CHART_VERSION)"
helm repo add kong https://charts.konghq.com > /dev/null 2>&1 || true
helm repo update kong > /dev/null
helm upgrade --install kong kong/kong \
  --version "$KONG_CHART_VERSION" \
  --namespace kong --create-namespace \
  --values "$ROOT_DIR/gateway/kong-values.yaml" \
  --values "$ROOT_DIR/gateway/kong-values-eks.yaml" \
  --wait --timeout 300s

echo "==> Aguardando o endereço do Load Balancer"
LB=""
for _ in $(seq 1 60); do
  LB="$(kubectl -n kong get svc kong-kong-proxy -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [ -n "$LB" ] && break
  sleep 5
done
if [ -z "$LB" ]; then
  echo "ERRO: o Service do Kong não recebeu endereço em 5 min. Os eventos dizem o que falta:" >&2
  kubectl -n kong describe svc kong-kong-proxy | tail -15 >&2
  exit 1
fi
echo "   - $LB"

echo "==> Segredos pelo External Secrets"
kubectl apply -f "$ROOT_DIR/k8s/00-namespace.yaml"
kubectl apply -R -f "$ROOT_DIR/k8s-aws/"
if ! kubectl -n "$NS" wait --for=condition=Ready externalsecret --all --timeout=180s; then
  echo "ERRO: ExternalSecret sem sincronizar. Os segredos foram publicados?" >&2
  echo "      ./scripts/publicar-segredos-aws.sh" >&2
  kubectl -n "$NS" get externalsecret >&2
  exit 1
fi

echo "==> Aplicando os manifestos (cópia renderizada para o EKS)"
RENDER_DIR="$(mktemp -d)"
cp -R "$ROOT_DIR/k8s/." "$RENDER_DIR/"
# Fora no EKS: o que o External Secrets substitui (ADR 0011). Aplicá-los falharia (sem o controller do
# Sealed Secrets) ou, no caso da credencial do Kong, sobrescreveria o Secret do Secrets Manager.
rm -f "$RENDER_DIR/05-sealed-secrets.yaml" "$RENDER_DIR/gateway/39-kong-jwt-credential.yaml"
while IFS="$(printf '\t')" read -r nome tag; do
  [ -n "$nome" ] || continue
  find "$RENDER_DIR" -name '*.yaml' -exec \
    sed -i.bak "s|image: ${nome}:local|image: ${REGISTRY}/fcg/${nome}:${tag}|g" {} +
done < "$MAPA"
# Sem domínio próprio, as rotas aceitam o DNS do Load Balancer (decisão da #64).
find "$RENDER_DIR" -name '*.yaml' -exec sed -i.bak "s|host: api.fcg.local|host: ${LB}|g" {} +
find "$RENDER_DIR" -name '*.yaml.bak' -delete
# Guarda: imagem `:local` que sobrou não existe em lugar nenhum e travaria em ImagePullBackOff.
if grep -rn "image: .*:local" "$RENDER_DIR"; then
  echo "ERRO: imagem ':local' sobreviveu à renderização — o manifesto mudou de formato?" >&2
  exit 1
fi
kubectl apply -R -f "$RENDER_DIR/"

echo "==> Aguardando a plataforma"
kubectl -n "$NS" rollout status deploy/rabbitmq --timeout=300s
kubectl -n "$NS" rollout status statefulset/mongodb --timeout=300s
kubectl -n "$NS" rollout status deploy/redis --timeout=180s
kubectl -n "$NS" rollout status statefulset/redis-idempotencia --timeout=180s
kubectl -n "$NS" rollout status statefulset/opensearch --timeout=300s
for svc in users-api catalog-api payments-api; do
  kubectl -n "$NS" rollout status "deploy/$svc" --timeout=300s
done
# NUNCA `rollout status` na notifications-function: o KEDA a mantém em 0 réplica de propósito, e o
# comando esperaria para sempre por um pod que corretamente não existe.
kubectl -n "$NS" wait --for=condition=Ready scaledobject/notifications-function --timeout=180s

echo "==> Verificação pelo endereço público"
# 401 sem token = o Kong respondeu e o plugin jwt está ativo. O DNS do NLB leva alguns minutos para
# propagar na primeira vez; por isso as tentativas.
CODIGO="000"
for _ in $(seq 1 30); do
  CODIGO="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://$LB/api/v1/jogos" || true)"
  [ "$CODIGO" = "401" ] && break
  sleep 10
done
if [ "$CODIGO" != "401" ]; then
  echo "ERRO: GET http://$LB/api/v1/jogos sem token deu $CODIGO; o esperado é 401 do Kong." >&2
  exit 1
fi

echo
echo "OK: plataforma no ar em http://$LB"
echo "    Login: curl -X POST http://$LB/api/v1/auth/login -H 'Content-Type: application/json' -d '{...}'"
echo "    Ao fim do dia: ./scripts/terraform-destroy.sh"

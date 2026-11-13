#!/usr/bin/env bash
# Publica os Secrets da plataforma no AWS Secrets Manager, de onde o External Secrets Operator os
# materializa no cluster EKS (#65, ADR 0011).
#
# Os VALORES vêm de scripts/lib/segredos-plataforma.sh, a MESMA fonte do seal-secrets.sh. É isso que
# mantém a paridade tríplice do JWT (users-api, catalog-api e Kong) e a separação da chave de serviço
# (ADR 0007) iguais no minikube e na AWS. Para segredos reais, exporte as variáveis antes de rodar.
#
# Os segredos (só o "contêiner", sem valor) são criados pelo Terraform (terraform/segredos.tf); este
# script grava a versão com os valores. Valor de segredo NÃO passa pelo Terraform de propósito: ele
# ficaria em claro no estado.
#
# Rotação: exporte o novo valor, rode este script de novo. O External Secrets relê a cada
# `refreshInterval` (k8s-aws/10-external-secrets.yaml) e atualiza o Secret do Kubernetes; os pods
# leem env só no start, então reinicie o Deployment depois (`kubectl -n fcg rollout restart ...`).
#
# Uso (com a credencial de sessão do lab no ambiente, ex.: AWS_PROFILE=academy):
#   ./scripts/publicar-segredos-aws.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGIAO="${REGIAO:-us-east-1}"
PREFIXO="fcg"

# shellcheck source=lib/segredos-plataforma.sh
source "$SCRIPT_DIR/lib/segredos-plataforma.sh"

command -v aws >/dev/null || { echo "ERRO: aws CLI não encontrado." >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERRO: python3 não encontrado (monta o JSON)." >&2; exit 1; }
aws sts get-caller-identity > /dev/null 2>&1 || {
  echo "ERRO: sem credencial AWS válida. Inicie o Learner Lab e atualize ~/.aws/credentials." >&2
  exit 1
}

# Defesa da ADR 0007: o users-api RECUSA subir se as duas chaves forem iguais. Melhor falhar aqui, antes
# de gravar, do que descobrir por CrashLoopBackOff.
if [ "$JWT_SECRET_KEY" = "$SERVICE_AUTH_SECRET_KEY" ]; then
  echo "ERRO: JWT_SECRET_KEY e SERVICE_AUTH_SECRET_KEY são iguais. A chave de serviço tem de ser outra (ADR 0007)." >&2
  exit 1
fi

publicar() {
  local nome="$1"; shift 2   # o label `app` não se aplica ao Secrets Manager; vai no ExternalSecret
  local id="${PREFIXO}/${nome}"
  # O JSON é montado por python3 a partir dos pares CHAVE=valor, e entra no aws CLI pela entrada
  # padrão: o valor não aparece na linha de comando (visível em `ps`) nem no log.
  python3 -c '
import json, sys
par = lambda kv: kv.split("=", 1)
print(json.dumps(dict(par(kv) for kv in sys.argv[1:])))
' "$@" | aws secretsmanager put-secret-value --region "$REGIAO" --secret-id "$id" \
           --secret-string file:///dev/stdin > /dev/null
  echo "   - $id"
}

echo "==> Publicando no Secrets Manager ($REGIAO)"
segredos_da_plataforma publicar

# Credencial do plugin jwt do Kong: a TERCEIRA ponta da paridade do JWT. No minikube ela ainda é o
# Secret em claro de k8s/gateway/39-kong-jwt-credential.yaml; na AWS vem daqui, com o MESMO
# JWT_SECRET_KEY dos serviços. `key` é o Issuer do token (JwtSettings__Issuer).
publicar fcg-jwt-credential "" \
  "kongCredType=jwt" "key=FiapCloudGames" "algorithm=HS256" "secret=$JWT_SECRET_KEY"

echo "OK: segredos publicados. O External Secrets sincroniza no próximo refreshInterval."

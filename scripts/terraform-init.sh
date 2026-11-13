#!/usr/bin/env bash
# Inicializa o Terraform de terraform/ com o estado no S3 (#62).
#
# O nome do bucket leva o ID da conta: nome de bucket é único no mundo, e cada AWS Academy Learner
# Lab é uma conta diferente. Por isso ele não fica versionado em terraform/versions.tf, entra aqui.
#
# Cria o bucket se ainda não existir, com versionamento ligado. Versionamento NÃO é opcional: é o
# que permite voltar um estado corrompido. Acesso público já vem bloqueado em bucket novo.
#
# Uso (com a credencial de sessão do lab no ambiente, ex.: AWS_PROFILE=academy):
#   ./scripts/terraform-init.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGIAO="${REGIAO:-us-east-1}"

# Falha cedo, com mensagem útil, se a sessão do lab expirou (~4 h).
if ! CONTA=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  echo "ERRO: sem credencial AWS válida. Inicie o Learner Lab e atualize ~/.aws/credentials." >&2
  exit 1
fi
BUCKET="fcg-tfstate-${CONTA}"

if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "==> Bucket de estado já existe"
else
  echo "==> Criando o bucket de estado (com versionamento)"
  # us-east-1 é a única região que NÃO aceita LocationConstraint.
  if [ "$REGIAO" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGIAO" > /dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGIAO" \
      --create-bucket-configuration "LocationConstraint=$REGIAO" > /dev/null
  fi
fi
# Idempotente: reaplicar não muda nada, e garante o versionamento mesmo num bucket criado à mão.
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled

terraform -chdir="$ROOT_DIR/terraform" init -backend-config="bucket=$BUCKET" -backend-config="region=$REGIAO" "$@"

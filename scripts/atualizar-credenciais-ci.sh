#!/usr/bin/env bash
# Copia as credenciais da sessão ATUAL do AWS Academy para os secrets da organização no GitHub (#68).
#
# Por que existe: o laboratório não permite criar o provedor OIDC (ADR 0010), então o CI usa as
# credenciais de sessão, que EXPIRAM em ~4 h. Sem atualizar, o push para o ECR e o deploy falham na
# autenticação — e é a primeira coisa que quebra na véspera da gravação.
#
# Lê do perfil local (o mesmo onde você colou as credenciais do lab) e grava como secrets da
# organização, visíveis aos repositórios públicos do grupo. Os valores não passam pela linha de
# comando: o `gh secret set` os recebe pela entrada padrão.
#
# Também liga a variável AWS_DEPLOY_HABILITADO, que faz o CI dos serviços publicar e implantar na main.
# Ao fim do dia, depois do terraform-destroy.sh:  DESLIGAR=1 ./scripts/atualizar-credenciais-ci.sh
#
# Uso: AWS_PROFILE=academy ./scripts/atualizar-credenciais-ci.sh
# Requer: gh autenticado com permissão de admin na organização.
set -euo pipefail
ORG="fcg-grupo-16"
PERFIL="${AWS_PROFILE:-academy}"

command -v gh >/dev/null || { echo "ERRO: gh não encontrado." >&2; exit 1; }

if [ "${DESLIGAR:-0}" = "1" ]; then
  gh variable set AWS_DEPLOY_HABILITADO --org "$ORG" --visibility all --body "false"
  echo "OK: deploy automático DESLIGADO. O CI segue construindo e testando, sem publicar."
  exit 0
fi

aws sts get-caller-identity --profile "$PERFIL" > /dev/null 2>&1 || {
  echo "ERRO: o perfil '$PERFIL' não tem credencial válida. Inicie o lab e cole as credenciais novas." >&2
  exit 1
}

for chave in aws_access_key_id aws_secret_access_key aws_session_token; do
  nome="$(echo "$chave" | tr '[:lower:]' '[:upper:]')"
  aws configure get "$chave" --profile "$PERFIL" | gh secret set "$nome" --org "$ORG" --visibility all
  echo "   - $nome atualizado"
done
gh variable set AWS_DEPLOY_HABILITADO --org "$ORG" --visibility all --body "true"
echo "OK: credenciais da sessão no GitHub, deploy automático LIGADO. Valem até a sessão do lab expirar."

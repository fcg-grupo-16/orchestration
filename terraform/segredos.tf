# Segredos da plataforma no AWS Secrets Manager + External Secrets Operator (#65, ADR 0011).
#
# O Terraform cria só o "contêiner" de cada segredo, SEM valor: valor de segredo no Terraform fica
# em claro no estado. Os valores entram pelo scripts/publicar-segredos-aws.sh, a partir da mesma
# fonte do seal-secrets.sh do minikube.
locals {
  # Os MESMOS nomes dos Secrets do Kubernetes: o ExternalSecret materializa cada um com o nome que os
  # Deployments já usam em `envFrom`, e nenhum manifesto de serviço muda.
  segredos = [
    "rabbitmq-secret",
    "users-api-secret",
    "catalog-api-secret",
    "payments-api-secret",
    "notifications-function-secret",
    "keda-rabbitmq-secret",
    "fcg-jwt-credential",
  ]
}

resource "aws_secretsmanager_secret" "fcg" {
  for_each = toset(local.segredos)

  name        = "fcg/${each.key}"
  description = "FIAP Cloud Games: valores do Secret ${each.key} (namespace fcg). Publicado por scripts/publicar-segredos-aws.sh."

  # SEM janela de recuperação. O padrão (7 a 30 dias) RESERVA o nome depois do delete: o
  # `terraform destroy` do fim do dia faria o `apply` do dia seguinte falhar com "secret scheduled
  # for deletion". Os valores são reconstruíveis pelo script; não há o que recuperar.
  recovery_window_in_days = 0
}

# O operador que lê o Secrets Manager e escreve Secrets nativos no cluster.
#
# Sem IRSA (o Learner Lab não permite criar role nem provedor OIDC), ele usa a credencial do NÓ, a
# LabRole, pelo IMDSv2 — por isso o limite de saltos 2 em eks.tf. A LabRole tem
# secretsmanager:GetSecretValue (verificado por simulação de política).
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.versao_chart_external_secrets
  namespace        = "external-secrets"
  create_namespace = true

  # As CRDs vêm com o chart (installCRDs: true é o padrão). A API servida é a external-secrets.io/v1;
  # a v1beta1 vem desligada nesta versão.
  depends_on = [module.eks]
}

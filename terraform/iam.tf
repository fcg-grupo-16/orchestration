# O Learner Lab NÃO permite criar role (iam:CreateRole negado) nem provedor OIDC. Usamos as roles
# que o laboratório já traz, e o Terraform só as LÊ. Ver ADR 0010, seção 3.

# Role do control plane. O nome tem prefixo e sufixo aleatórios por conta
# (ex.: "c123...-LabEksClusterRole-AbC123"), por isso a busca é por regex, nunca por nome fixo.
data "aws_iam_roles" "cluster" {
  name_regex = "LabEksClusterRole"
}

# Role dos nós. Já tem leitura no ECR, secretsmanager:GetSecretValue (External Secrets, #65) e
# criação/anexo de volume EBS (driver EBS CSI), verificado por simulação de política.
data "aws_iam_role" "nos" {
  name = "LabRole"
}

locals {
  arn_role_cluster = one(data.aws_iam_roles.cluster.arns)
}

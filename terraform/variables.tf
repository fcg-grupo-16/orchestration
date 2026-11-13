# ⚠️ AWS Academy Learner Lab: tentar exceder um limite do laboratório pode DESATIVAR A CONTA na hora,
# apagando tudo (Readme do lab). As validações abaixo existem para que um erro de digitação seja
# recusado pelo `plan`, e não pela AWS. Ver docs/adr/0010-ambiente-aws-academy-e-busca-no-cluster.md.

variable "regiao" {
  description = "Região da AWS. O Learner Lab só permite us-east-1 e us-west-2."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = contains(["us-east-1", "us-west-2"], var.regiao)
    error_message = "O Learner Lab só permite us-east-1 e us-west-2."
  }
}

variable "nome_cluster" {
  description = "Nome do cluster EKS. Também prefixa a VPC."
  type        = string
  default     = "fcg"
}

variable "versao_kubernetes" {
  description = "Versão <major>.<minor> do Kubernetes. A padrão do EKS na conta, em 2026-11-12, era a 1.37."
  type        = string
  default     = "1.37"
}

variable "tipo_instancia_nos" {
  description = "Tipo de instância dos nós. O Learner Lab vai de nano a large."
  type        = string
  default     = "t3.large"

  validation {
    # Recusa xlarge, 2xlarge, metal etc. Só os tamanhos que o laboratório aceita.
    condition     = can(regex("^[a-z][a-z0-9-]*\\.(nano|micro|small|medium|large)$", var.tipo_instancia_nos))
    error_message = "O Learner Lab só aceita instâncias de nano a large. Tentar maior pode desativar a conta."
  }
}

variable "quantidade_nos" {
  description = "Quantidade desejada de nós."
  type        = number
  default     = 2

  validation {
    # O lab permite 9 instâncias simultâneas. O teto aqui fica bem abaixo, para sobrar margem ao
    # rolling update do node group, que sobe um nó novo antes de derrubar o antigo.
    condition     = var.quantidade_nos >= 1 && var.quantidade_nos <= 3
    error_message = "Entre 1 e 3 nós. O lab tem teto de 9 instâncias e o rolling update do node group precisa de folga."
  }
}

variable "versao_chart_keda" {
  description = "Versão do chart do KEDA. A mesma da Fase 3 (scripts/deploy-minikube.sh)."
  type        = string
  default     = "2.20.2"
}

variable "versao_chart_external_secrets" {
  description = "Versão do chart do External Secrets Operator (#65). Serve a API external-secrets.io/v1."
  type        = string
  default     = "2.14.0"
}

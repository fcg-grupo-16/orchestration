terraform {
  # `use_lockfile` (trava nativa do S3, sem tabela DynamoDB) existe a partir da 1.10.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
  }

  # Configuração PARCIAL: o nome do bucket inclui o ID da conta (nome de bucket é único no mundo, e
  # cada Learner Lab é uma conta diferente), por isso entra no `init` e não fica versionado.
  # Use sempre scripts/terraform-init.sh, que cria o bucket se faltar e passa o nome.
  backend "s3" {
    key          = "fase4/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

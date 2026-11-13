provider "aws" {
  region = var.regiao

  default_tags {
    tags = {
      Projeto       = "fiap-cloud-games"
      Fase          = "4"
      GerenciadoPor = "terraform"
    }
  }
}

# Os dois providers abaixo falam com o cluster que este mesmo código cria. O token vem do
# `aws eks get-token` a cada chamada, com a credencial de sessão do laboratório que estiver no
# ambiente: nada de token gravado no estado.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.regiao]
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.regiao]
    }
  }
}

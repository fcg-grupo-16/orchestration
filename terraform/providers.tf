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
  host                   = aws_eks_cluster.fcg.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.fcg.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.fcg.name, "--region", var.regiao]
  }
}

provider "helm" {
  # Configuração e cache de repositórios PRÓPRIOS, dentro de .terraform/ (gitignored). Sem isto o
  # provider lê o ~/.config/helm de quem roda o apply, e um repositório local sem cache (medido: o do
  # kong) faz TODO helm_release falhar com "no cached repo found", mesmo com a URL declarada aqui.
  repository_config_path = "${path.root}/.terraform/helm/repositories.yaml"
  repository_cache       = "${path.root}/.terraform/helm/cache"

  kubernetes = {
    host                   = aws_eks_cluster.fcg.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.fcg.certificate_authority[0].data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.fcg.name, "--region", var.regiao]
    }
  }
}

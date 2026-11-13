data "aws_availability_zones" "disponiveis" {
  state = "available"
}

locals {
  # O EKS exige no mínimo duas zonas. Duas, e não três: cada zona a mais é mais uma subnet e mais
  # IPs, sem ganho para esta entrega.
  zonas = slice(data.aws_availability_zones.disponiveis.names, 0, 2)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = var.nome_cluster
  cidr = "10.0.0.0/16"

  azs             = local.zonas
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  # Os nós ficam em subnet privada e saem para a internet (baixar imagem do ECR e dos registries
  # públicos) por UM NAT Gateway. Um só derruba custo e resiliência: se a zona dele cair, os nós da
  # outra zona perdem a saída. Escolha consciente para esta entrega, registrada no relatório.
  enable_nat_gateway = true
  single_nat_gateway = true

  # Tags que o EKS usa para saber onde criar Load Balancer. Erradas, o Service do Kong (#64) fica
  # com EXTERNAL-IP <pending> para sempre, sem erro claro.
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

output "nome_cluster" {
  value = module.eks.cluster_name
}

output "regiao" {
  value = var.regiao
}

output "configurar_kubectl" {
  description = "Aponta o kubectl para o cluster. Depois, confira o contexto antes de qualquer outro comando."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.regiao}"
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "security_group_nos" {
  description = "Security group dos nós. Serviços fora do cluster (ex.: ElastiCache, ADR 0009) devem aceitar só a partir dele."
  value       = module.eks.node_security_group_id
}

output "registry" {
  description = "Endereço do registry. As imagens ficam em <registry>/fcg/<nome>:<sha do commit>."
  value       = split("/", aws_ecr_repository.fcg["users-api"].repository_url)[0]
}

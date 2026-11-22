output "nome_cluster" {
  value = aws_eks_cluster.fcg.name
}

output "regiao" {
  value = var.regiao
}

output "configurar_kubectl" {
  description = "Aponta o kubectl para o cluster. Depois, confira o contexto antes de qualquer outro comando."
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.fcg.name} --region ${var.regiao}"
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "security_group_nos" {
  description = "Security group do cluster, que os nós do node group usam. Serviços fora do cluster (ex.: ElastiCache, ADR 0009) devem aceitar só a partir dele."
  value       = aws_eks_cluster.fcg.vpc_config[0].cluster_security_group_id
}

output "registry" {
  description = "Endereço do registry. As imagens ficam em <registry>/fcg/<nome>:<sha do commit>."
  value       = split("/", aws_ecr_repository.fcg["users-api"].repository_url)[0]
}

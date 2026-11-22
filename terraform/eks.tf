# Cluster EKS com recursos DIRETOS do provider, e não o módulo terraform-aws-modules/eks.
#
# Por que sem o módulo: ele declara SEMPRE um `data "aws_iam_session_context"`, que chama
# iam:GetRole na role de quem roda o Terraform. No AWS Academy essa role é a `voclabs`, e o
# laboratório nega iam:GetRole nela com um DENY explícito (política Pvoclabs2). O `plan` falha antes
# de criar qualquer coisa, e não há variável do módulo que desligue essa consulta. Medido em
# 2026-11-22, no primeiro `plan` contra a conta.
#
# O uso é pequeno — cluster, node group, launch template e quatro add-ons —, então os recursos diretos
# custam pouco e não dependem de nenhuma chamada de IAM além das que o laboratório permite.

resource "aws_eks_cluster" "fcg" {
  name     = var.nome_cluster
  version  = var.versao_kubernetes
  role_arn = local.arn_role_cluster # LabEksClusterRole: o lab não permite criar role (ADR 0010)

  vpc_config {
    subnet_ids = module.vpc.private_subnets
    # Endpoint público: o grupo e o CI do GitHub (#63, #68) alcançam a API de fora da VPC. A
    # autenticação continua sendo IAM; o que fica aberto é a porta, não o acesso. Em produção de
    # verdade, restringiria por CIDR com `public_access_cidrs`.
    endpoint_public_access  = true
    endpoint_private_access = true # os nós falam com a API por dentro da VPC
  }

  access_config {
    # Só access entries, sem o ConfigMap aws-auth legado.
    authentication_mode = "API"
    # Quem roda o `apply` (a role de sessão do lab) vira admin do cluster. Quem concede é o PRÓPRIO
    # EKS, na criação, sem o Terraform consultar o IAM — é o que substitui o
    # `enable_cluster_creator_admin_permissions` do módulo. O CI usa a mesma role de sessão (#63).
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Sem os add-ons "autogerenciados" que o EKS instala por padrão: os quatro de baixo são add-ons
  # GERENCIADOS, com versão e configuração declaradas aqui (o vpc-cni precisa da NetworkPolicy).
  bootstrap_self_managed_addons = false

  # Criptografia de Secrets por KMS e logs do control plane: desligados para economizar orçamento.
  # Os segredos de verdade moram no Secrets Manager (#65); os logs são cobrados por GB.
  enabled_cluster_log_types = []
}

# --- Add-ons que o nó precisa ANTES de entrar no cluster -----------------------------------------------

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.fcg.name
  addon_name   = "vpc-cni"
  # Liga a imposição de NetworkPolicy. Sem isto, a NetworkPolicy do OpenSearch (#67) é aceita pelo
  # apiserver e IGNORADA em silêncio: qualquer pod lê e apaga os índices.
  configuration_values        = jsonencode({ enableNetworkPolicy = "true" })
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.fcg.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

# --- Nós ---------------------------------------------------------------------------------------------

resource "aws_launch_template" "nos" {
  name_prefix = "${var.nome_cluster}-nos-"

  # ⚠️ Limite de saltos do IMDSv2 = 2. Com 1, só o nó alcança os metadados da instância, e os PODS
  # não. Sem IRSA, é por ali que o driver EBS CSI e o External Secrets (#65) obtêm a credencial da
  # LabRole. Com 1, os PVCs ficam Pending e o erro aparece como timeout no log do controller, não como
  # falta de permissão.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.nome_cluster}-no" }
  }
}

resource "aws_eks_node_group" "padrao" {
  cluster_name    = aws_eks_cluster.fcg.name
  node_group_name = "padrao"
  node_role_arn   = data.aws_iam_role.nos.arn # LabRole: ECR, Secrets Manager e EBS (ADR 0010)
  subnet_ids      = module.vpc.private_subnets

  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = [var.tipo_instancia_nos]

  scaling_config {
    min_size     = 1
    max_size     = 3
    desired_size = var.quantidade_nos
  }

  # Um nó por vez no rolling update do node group: com 2 nós, sobra um servindo.
  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.nos.id
    version = aws_launch_template.nos.latest_version
  }

  # Sem CNI e kube-proxy no cluster, o nó entra e fica NotReady para sempre.
  depends_on = [aws_eks_addon.vpc_cni, aws_eks_addon.kube_proxy]
}

# --- Add-ons que precisam de nó para rodar --------------------------------------------------------------

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.fcg.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.padrao]
}

# Sem driver CSI, os PVCs do Mongo, do Redis de idempotência (ADR 0006) e do OpenSearch ficam Pending
# para sempre. Sem IRSA, o controller usa a credencial do nó (LabRole) pelo IMDS — daí o limite de
# saltos 2 no launch template.
resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.fcg.name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.padrao]
}

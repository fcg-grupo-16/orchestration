module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.29"

  name               = var.nome_cluster
  kubernetes_version = var.versao_kubernetes

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Endpoint público: o grupo e o CI do GitHub (#63, #68) alcançam a API de fora da VPC. A
  # autenticação continua sendo IAM; o que fica aberto é a porta, não o acesso. Em produção de
  # verdade, restringiria por CIDR com `endpoint_public_access_cidrs`.
  endpoint_public_access = true

  # --- Sem IAM próprio: o Learner Lab não deixa criar role nem provedor OIDC (ADR 0010) ---
  create_iam_role = false
  iam_role_arn    = local.arn_role_cluster
  enable_irsa     = false

  # Quem roda o `apply` (a role de sessão do laboratório) vira admin do cluster por access entry.
  # O CI usa a mesma role de sessão (#63), então fica coberto também.
  enable_cluster_creator_admin_permissions = true

  # --- Economia de orçamento ---
  # Criptografia de Secrets do Kubernetes por KMS: desligada. Cria uma chave KMS cobrada por mês e
  # não sabemos se o laboratório permite. Os segredos de verdade passam a morar no Secrets Manager
  # (#65), cifrados lá; o etcd do EKS já é cifrado em disco pela AWS.
  encryption_config = null
  create_kms_key    = false

  # Logs do control plane no CloudWatch: desligados. São cobrados por GB ingerido e não entram em
  # nenhum requisito da fase. Ligar = `enabled_log_types = ["api", "audit", "authenticator"]`.
  enabled_log_types           = []
  create_cloudwatch_log_group = false

  addons = {
    # `before_compute`: o CNI precisa existir antes do nó entrar, senão o nó fica NotReady.
    vpc-cni = {
      before_compute = true
      # Liga a imposição de NetworkPolicy. Sem isto, a NetworkPolicy do OpenSearch (#67) é aceita
      # pelo apiserver e IGNORADA em silêncio: qualquer pod lê e apaga os índices.
      configuration_values = jsonencode({ enableNetworkPolicy = "true" })
    }
    kube-proxy = {
      before_compute = true
    }
    coredns = {}
    # Sem driver CSI, os PVCs do Mongo, do Redis de idempotência (ADR 0006) e do OpenSearch ficam
    # Pending para sempre. Sem IRSA, o controller usa a credencial do nó (LabRole) pelo IMDS.
    aws-ebs-csi-driver = {}
  }

  eks_managed_node_groups = {
    padrao = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.tipo_instancia_nos]

      min_size     = 1
      max_size     = 3
      desired_size = var.quantidade_nos

      create_iam_role = false
      iam_role_arn    = data.aws_iam_role.nos.arn

      # ⚠️ Limite de saltos do IMDSv2 = 2. O padrão do módulo (v21) é 1, que deixa os PODS sem
      # acesso aos metadados da instância — só o próprio nó alcança. Sem IRSA, é por ali que o
      # driver EBS CSI e o External Secrets (#65) obtêm a credencial da LabRole. Com 1, os PVCs
      # ficam Pending e o erro aparece como timeout no log do controller, não como falta de permissão.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
      }
    }
  }
}

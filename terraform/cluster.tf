# Recursos DENTRO do cluster que fazem parte da fundação (#62). O resto da plataforma continua
# entrando pelos manifestos de k8s/ e pelo pipeline de CD (#68).

# StorageClass com o MESMO nome da padrão do minikube. Os StatefulSets de k8s/ pedem
# `storageClassName: standard`; com ela existindo aqui, os manifestos ficam idênticos nos dois
# ambientes, sem overlay nem sed no deploy.
resource "kubernetes_storage_class_v1" "standard" {
  metadata {
    name = "standard"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  # Cria o volume só quando o pod é agendado, na zona do nó escolhido. Com `Immediate`, o volume
  # pode nascer numa zona e o pod ser agendado na outra, e EBS não cruza zona.
  volume_binding_mode = "WaitForFirstConsumer"

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [module.eks]
}

# KEDA por Helm, como na Fase 3: é ele que acorda a notifications-function do zero.
resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = var.versao_chart_keda
  namespace        = "keda"
  create_namespace = true

  depends_on = [module.eks]
}

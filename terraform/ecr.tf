# Registry privado das imagens da plataforma (#63).
#
# São CINCO repositórios, não quatro: a imagem do RabbitMQ é customizada (assa o definitions.json com
# a topologia das filas), e a notifications-function não declara fila nenhuma. Broker sem a imagem
# certa = Function muda, sem erro.
locals {
  imagens = [
    "users-api",
    "catalog-api",
    "payments-api",
    "notifications-function",
    "fcg-rabbitmq",
  ]
}

resource "aws_ecr_repository" "fcg" {
  for_each = toset(local.imagens)

  name = "fcg/${each.key}"

  # Tag não pode ser reescrita. Transforma a classe de erro da #40 (tag reaproveitada, pod servindo
  # binário velho em silêncio) em erro de push, visível no pipeline.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    # Scan básico do ECR: cobre a imagem inteira (sistema operacional incluído), não só os pacotes
    # .NET que o SCA do CI já verifica.
    scan_on_push = true
  }

  # `terraform destroy` ao fim do dia (ADR 0010) precisa conseguir apagar repositório com imagem
  # dentro. As imagens são reconstruíveis pelo CI a partir do commit; nada se perde.
  force_delete = true
}

# Uma imagem por commit enche o repositório rápido, e o laboratório tem orçamento fixo.
resource "aws_ecr_lifecycle_policy" "fcg" {
  for_each   = aws_ecr_repository.fcg
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Mantem as 10 imagens mais recentes"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

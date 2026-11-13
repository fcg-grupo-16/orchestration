# ADR 0011 — Segredos: AWS Secrets Manager no EKS, Sealed Secrets no minikube

- **Status:** aceito; validado offline, falta o teste na conta (ver "Pendente")
- **Data:** 2026-11-13
- **Issue:** [#65](https://github.com/fcg-grupo-16/orchestration/issues/65)
- **Depende de:** [ADR 0010](0010-ambiente-aws-academy-e-busca-no-cluster.md) (sem IRSA no AWS Academy)

## Contexto

O requisito da Fase 4 pede *"Zero Hardcoded Credentials"* e cita por nome a injeção por serviço
gerenciado integrado ao cluster (AWS Secrets Manager ou Azure Key Vault).

Hoje os segredos são **SealedSecrets** (`k8s/05-sealed-secrets.yaml`). Isso já cumpre a letra do
requisito, mas a #65 registrou três atritos observados:

1. **A chave pertence ao cluster.** Recriar o cluster invalida o arquivo inteiro. Na AWS, o cluster sobe
   e desce **todo dia** (ADR 0010), e o atrito vira rotina.
2. **O texto cifrado não é determinístico.** Re-selar o mesmo valor gera outro base64, e o diff mostra
   200 linhas sem mudança real.
3. **Não há caminho de rotação** sem editar o arquivo e reimplantar.

Há ainda uma credencial **em claro** versionada: o Secret `fcg-jwt-credential` do Kong, com valor de
demonstração.

## Decisão

**Opção A da #65 no EKS: Secrets Manager + External Secrets Operator.** O minikube continua com
Sealed Secrets.

| | minikube | EKS |
|---|---|---|
| Origem dos valores | `scripts/lib/segredos-plataforma.sh` | **a mesma** |
| Como entram no cluster | `seal-secrets.sh` → SealedSecret → controller | `publicar-segredos-aws.sh` → Secrets Manager → ExternalSecret |
| Credencial do Kong | `k8s/gateway/39-kong-jwt-credential.yaml` (em claro, demo) | ExternalSecret, **sem nada em claro** |
| Nome do Secret no cluster | `users-api-secret`, … | **o mesmo** |

### Uma fonte de valores para os dois destinos

O risco mais caro desta migração é quebrar em silêncio. Duas regras falham com 401 no gateway e nenhum
erro claro:

- a **paridade tríplice do JWT**: users-api, catalog-api e Kong precisam da mesma chave;
- a **separação da chave de serviço** (ADR 0007).

Por isso os valores e a composição dos Secrets saíram do `seal-secrets.sh` para
`scripts/lib/segredos-plataforma.sh`, lido pelos dois scripts. O refactor foi verificado **byte a
byte**: com um `kubeseal` falso, que devolve o Secret sem cifrar, a saída do script antigo e a do novo
são idênticas. Isso vale com os valores padrão e com valores rotacionados por variável de ambiente.

O script da AWS ainda **recusa publicar** se a chave do JWT e a de serviço forem iguais. É a mesma
regra que faz o `users-api` recusar subir, só que antes de gravar.

### Os nomes não mudam

Cada ExternalSecret materializa o Secret com o **mesmo nome** que os Deployments já usam em `envFrom`.
Nenhum manifesto de serviço muda entre os dois ambientes; muda só a origem do conteúdo. Os manifestos
exclusivos da AWS ficam em `k8s-aws/`, fora de `k8s/`, para o `deploy-minikube.sh` não os aplicar.

### Valor de segredo não passa pelo Terraform

O `terraform/segredos.tf` cria só o **contêiner** de cada segredo. Valor declarado no Terraform fica
**em claro no estado**, que está num bucket S3. Os valores entram pelo script, que monta o JSON e o
envia ao `aws` CLI pela entrada padrão, para não aparecer em `ps` nem em log.

`recovery_window_in_days = 0`: a janela padrão **reserva o nome** por 7 dias depois do delete, e o
`apply` do dia seguinte ao `destroy` falharia.

### Sem IRSA: o operador usa a credencial do nó

O `ClusterSecretStore` não tem bloco `auth`. O operador usa a cadeia padrão de credenciais, que chega à
`LabRole` do nó pelo IMDSv2, o que exige o limite de saltos 2 de `terraform/eks.tf`. É a limitação já
registrada na ADR 0010: **não há menor privilégio por pod**. O desenho de produção daria ao operador uma
role própria (IRSA ou EKS Pod Identity), só com leitura dos segredos `fcg/*`.

## Rotação

1. Exporte o novo valor (ex.: `JWT_SECRET_KEY=...`) e rode `./scripts/publicar-segredos-aws.sh`.
2. O External Secrets relê em até 1 h (`refreshInterval`). Para não esperar:
   `kubectl -n fcg annotate externalsecret <nome> force-sync=$(date +%s) --overwrite`.
3. Os pods leem env só no start: `kubectl -n fcg rollout restart deploy/<servico>`.

Para a chave do JWT, os três consumidores (users-api, catalog-api e o Kong) mudam **juntos**, porque
vêm da mesma variável.

## Pendente

🔶 Teste na conta, quando o AWS Academy voltar:

- o `SecretSynced` dos sete ExternalSecrets;
- a comparação dos valores decodificados com os do minikube (passo 3 da #65);
- `gateway-test.sh` (paridade do JWT) e o fluxo de compra (chave de serviço).

## Alternativas descartadas

- **Opção B, manter Sealed Secrets no EKS.** Funciona, mas leva os três atritos para um cluster que é
  recriado todo dia: o `seal-secrets.sh` teria de rodar a cada `apply`, e o arquivo versionado nunca
  bateria com o cluster do dia.
- **Montar os segredos como volume pelo Secrets Store CSI Driver.** Exigiria mudar os Deployments, que
  hoje leem por `envFrom`, e não traria nada que o External Secrets não entregue.
- **Valores no Terraform (`aws_secretsmanager_secret_version`).** Deixaria os segredos em claro no
  estado.

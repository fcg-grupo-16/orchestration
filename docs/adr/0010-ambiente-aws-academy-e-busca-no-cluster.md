# ADR 0010 — Ambiente AWS Academy Learner Lab, e o OpenSearch dentro do cluster

- **Status:** aceito, com **uma** pendência (o orçamento do laboratório; ver "Pendente")
- **Data:** 2026-11-13
- **Issues:** [#67](https://github.com/fcg-grupo-16/orchestration/issues/67) (busca),
  [#62](https://github.com/fcg-grupo-16/orchestration/issues/62) (cluster),
  [#63](https://github.com/fcg-grupo-16/orchestration/issues/63) (registry e identidade do CI),
  [#65](https://github.com/fcg-grupo-16/orchestration/issues/65) (segredos)
- **Ajusta:** [ADR 0008](0008-provedor-de-nuvem-aws.md). O provedor continua AWS; mudam a busca
  gerenciada e a identidade do CI, e a verificação de cota que ela deixou pendente é respondida aqui.

## Contexto

A ADR 0008 escolheu AWS e deixou uma lista de perguntas sobre a conta, que bloqueava o
provisionamento. A conta chegou: é um **AWS Academy Learner Lab** fornecido pelo curso. As respostas
foram levantadas em 2026-11-12, cruzando o Readme do laboratório com chamadas de leitura e de
**simulação de política** na própria conta. Nenhum recurso foi criado para testar.

| Pergunta da ADR 0008 | Resposta |
|---|---|
| Modalidade | AWS Academy **Learner Lab**. A identidade é uma role assumida (`voclabs`), não um usuário IAM |
| EKS liberado? | **Sim.** `eks:CreateCluster` permitido. O Readme manda usar as roles prontas do laboratório |
| OpenSearch Service liberado? | **Não.** Fora da lista de serviços do Readme; `es:ListDomainNames` dá `AccessDenied` e `es:CreateDomain` dá `implicitDeny` na simulação |
| As sessões expiram? | **Sim**, em ~4 h. Os recursos **persistem**; as instâncias EC2 param ao fim da sessão e voltam na próxima. O control plane do EKS **segue cobrando** parado |
| Teto de gasto | Orçamento fixo por aluno. **Estourar o orçamento desativa a conta e apaga tudo.** Valor: ver "Pendente" |
| Região e tamanho | Só `us-east-1` e `us-west-2`. Instâncias de `nano` a `large`, no máximo 9 simultâneas e 32 vCPU. O Readme avisa que tentar exceder limite pode desativar a conta na hora |
| IAM | **Não** cria role, usuário nem provedor OIDC (`iam:CreateRole` e `iam:CreateOpenIDConnectProvider` negados). Só se usam as roles que o laboratório já traz |
| ECR, Secrets Manager, ELB, S3, ElastiCache | permitidos |

Três dessas respostas contradizem o que a ADR 0008 assumiu: busca gerenciada, OIDC no CI e IRSA.

## Decisão

### 1. O OpenSearch roda **dentro do cluster**, como StatefulSet

O enunciado pede busca **gerenciada**, e a conta que o curso fornece não permite criá-la. O grupo
levou a questão ao professor, com a evidência acima, e a resposta (2026-11-13) foi que **o OpenSearch
no cluster é aceito**.

O desenho vem do que já roda no compose desde a [#74](https://github.com/fcg-grupo-16/orchestration/issues/74),
levado para o Kubernetes:

- **mesma imagem pinada** do compose (`opensearchproject/opensearch:2.19.0`), nó único
  (`discovery.type: single-node`), heap fixo de 512 MiB e teto de memória de 1,5 GiB, que foram
  **medidos** na #74;
- **StatefulSet com volume EBS**, como o Mongo e o Redis de idempotência. O índice é reconstruível a
  partir do Mongo, mas reindexar a cada reinício do pod deixaria a busca vazia até terminar;
- **Service `ClusterIP`**, nunca exposto pelo Kong nem por Load Balancer.

**O código não muda.** A [catalog-api#30](https://github.com/fcg-grupo-16/catalog-api/issues/30) e a
[catalog-api#31](https://github.com/fcg-grupo-16/catalog-api/issues/31) foram escritas contra
conexão direta, sem assinatura AWS. O cliente fala com o OpenSearch do cluster exatamente como fala
com o do compose. O modo SigV4 que a #67 previa para o domínio gerenciado **sai do escopo**.

**Voltar ao gerenciado** num ambiente que permita é trocar `OpenSearch__Endpoint` e acrescentar a
autenticação. Nenhuma linha da busca depende de onde o motor roda.

**O risco que fica e precisa de tratamento na #67:** com o plugin de segurança desligado, qualquer pod
que alcance a porta 9200 lê e apaga índices. No compose isso se resolve publicando só no loopback; no
cluster, a resposta é uma `NetworkPolicy` que só aceita tráfego dos pods do `catalog-api`. 🔶 Isso
depende de ligar o suporte a NetworkPolicy no add-on `vpc-cni` do EKS, o que fica para a #62.

### 2. O CI usa as **credenciais de sessão** do laboratório, porque não há OIDC

Sem `iam:CreateOpenIDConnectProvider`, não existe federação do GitHub Actions com a conta. A
consequência da ADR 0008 — *"nada de credencial estática no CI"* — **não é alcançável neste ambiente.**

O caminho é o mesmo que outros grupos do curso usam: as três variáveis da sessão do laboratório
(`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`) como secrets do GitHub, lidas
pelo `aws-actions/configure-aws-credentials`.

Por que isso ainda atende o requisito *"Zero Hardcoded Credentials"*:

- **nenhuma chave entra em código nem em YAML** — ficam nos secrets cifrados do GitHub;
- são credenciais **temporárias** do STS, que **expiram com a sessão** (~4 h). Não são chave de
  acesso de longa duração, que é o que o requisito procura evitar.

O custo é operacional: **a cada sessão do laboratório, alguém atualiza os três secrets**, ou o CD
falha na autenticação. Isso tem de estar no README e no roteiro do vídeo, porque é a primeira coisa
que quebra na véspera da gravação.

### 3. As roles do laboratório substituem as que o Terraform criaria

| Uso | Role | Observação |
|---|---|---|
| control plane do EKS | `LabEksClusterRole` | o nome tem **prefixo e sufixo aleatórios** por conta. O Terraform a encontra por `data "aws_iam_roles"` com `name_regex`, **nunca** por nome fixo no código |
| nós | `LabRole` | já tem leitura no ECR, `secretsmanager:GetSecretValue` e o que o driver EBS CSI precisa (verificado por simulação) |
| CI | a role da sessão (`voclabs`) | entra no cluster por **access entry** do EKS, não pelo `aws-auth` |

**Sem IRSA.** Sem role própria, não há como dar a um pod uma identidade diferente da do nó. Todo pod
que alcança o serviço de metadados da instância age como `LabRole`. Duas consequências:

- **Para a [#65](https://github.com/fcg-grupo-16/orchestration/issues/65), a opção do External
  Secrets continua viável.** O `SecretStore` usa a credencial do nó em vez de uma service account com
  IRSA, e a `LabRole` lê do Secrets Manager. A suposição *"IRSA disponível, senão esta opção cai"*
  estava errada: cai o IRSA, não a opção.
- **Não há menor privilégio por pod.** É uma limitação do ambiente, não uma escolha, e o relatório
  deve dizê-lo assim. O desenho de produção seria IRSA ou EKS Pod Identity, um por consumidor.

⚠️ Para o pod alcançar o serviço de metadados com IMDSv2, o limite de saltos do launch template dos
nós tem de ser **2**. **Não é o padrão** do módulo `terraform-aws-modules/eks` na v21, que usa 1 (só o
nó alcança). Por isso o `terraform/eks.tf` fixa o valor explicitamente.

### 4. O ambiente é efêmero, e isso muda o hábito de trabalho

- **`terraform destroy` ao fim de cada dia de uso** deixa de ser recomendação. Com os nós parados
  fora da sessão, o control plane do EKS e o Load Balancer continuam consumindo orçamento, e o
  orçamento estourado **apaga a conta**.
- **Nós `t3.large`**, o maior tamanho permitido, e não mais que o necessário. A contagem fica para a
  #62, com o orçamento na mão: a plataforma pede ~2,7 GiB de `requests` sem contar Kong, KEDA e os
  pods do sistema, e o OpenSearch acrescenta ~1 GiB.
- **A conta é pessoal de um integrante.** O `apply` e o CD dependem da sessão dele. O resto do grupo
  desenvolve contra o compose e o minikube, como na Fase 3, e entrega por PR.

## Pendente

🔶 **O valor do orçamento do laboratório.** Ele aparece no painel do Learner Lab e não é legível pela
API (`budgets:DescribeBudgets` não retorna nada). É o número que decide quantos nós, quantas horas de
cluster ligado e se o Redis de cache migra para o ElastiCache — que **é permitido** no laboratório, o
que reduz a pendência da [ADR 0009](0009-servicos-de-dados-gerenciados-vs-in-cluster.md) só ao custo.

## Consequências

- **[#67](https://github.com/fcg-grupo-16/orchestration/issues/67) muda de natureza:** deixa de ser
  Terraform de `aws_opensearch_domain` e passa a ser manifesto Kubernetes, com `NetworkPolicy`.
  Depende da #62 só para existir o cluster; o manifesto pode ser validado no minikube antes.
- **[#63](https://github.com/fcg-grupo-16/orchestration/issues/63) perde a Parte 2 (OIDC):** fica
  com os repositórios do ECR e o login do CI pelas credenciais de sessão. O critério *"publica sem
  nenhum secret de credencial no repositório"* é substituído por *"sem credencial de longa duração"*.
- **[#62](https://github.com/fcg-grupo-16/orchestration/issues/62)** usa as roles do laboratório
  (`create_iam_role = false`, `enable_irsa = false` no módulo), nós `t3.large` em `us-east-1`, e
  acrescenta o access entry da role da sessão.
- **[#65](https://github.com/fcg-grupo-16/orchestration/issues/65)** segue com External Secrets, com
  a credencial do nó.
- **O compose não muda.** O OpenSearch da #74 continua sendo o ambiente de desenvolvimento, e agora é
  também o modelo do que roda no cluster.

## Alternativas descartadas

- **Conta AWS pessoal com o crédito do plano gratuito**, para ter o OpenSearch gerenciado. O
  OpenSearch Service é exclusivo do plano pago, e quem já teve conta AWS não recebe o crédito de conta
  nova. Seria custo do bolso do aluno para atender a um requisito que o ambiente fornecido pelo curso
  não permite.
- **Elastic Cloud**, o outro serviço que o enunciado nomeia. Mesma objeção: conta e cobrança de
  terceiro, fora do ambiente fornecido.
- **Modelo híbrido** — cluster no Academy e busca gerenciada noutra conta. Soma a objeção anterior a
  tráfego entre contas pela internet e a duas credenciais para administrar.
- **Chave de acesso de usuário IAM no CI.** Além de ser exatamente o que o requisito procura evitar, o
  laboratório não permite criar usuário IAM.

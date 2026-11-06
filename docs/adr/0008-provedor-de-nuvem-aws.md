# ADR 0008 — Provedor de nuvem: AWS

**Status:** aceito · **Data:** 2026-11-05 · **Issue:** [#61](https://github.com/fcg-grupo-16/orchestration/issues/61)

## Contexto

A Fase 4 pede que a plataforma saia do cluster local e passe a rodar em **Kubernetes gerenciado**, com
registry privado, busca avançada, gerenciamento de segredos e entrega automatizada. O enunciado deixa
o provedor em aberto: AWS, Azure, Google Cloud ou Oracle Cloud.

A escolha amarra cinco entregáveis de uma vez — cluster, registry, busca, segredos e a identidade que
o CI usa para implantar. Trocar de provedor no meio da fase refaz todos, e por isso esta é a primeira
decisão da fase.

Duas restrições herdadas precisam ser consideradas antes de escolher:

1. **A Fase 3 rodou em `minikube` local.** O enunciado da Fase 4 afirma que o cluster na nuvem foi
   subido na fase anterior; não foi o nosso caso. Provisionar o cluster gerenciado é trabalho novo.
2. **O componente serverless é Azure Functions.** A [ADR 0003](0003-serverless-azure-functions-keda.md)
   escolheu o worker isolado do Azure Functions **rodando em container no Kubernetes com KEDA**,
   justamente porque os planos hospedados da Azure não suportam o trigger de RabbitMQ.

## Decisão

**AWS.**

| Necessidade da Fase 4 | Serviço |
|---|---|
| Kubernetes gerenciado | **EKS** |
| Registry privado de imagens | **ECR** |
| Busca avançada (Elasticsearch) | **Amazon OpenSearch Service** |
| Gerenciamento de segredos | **Secrets Manager** (integração definida na [#65](https://github.com/fcg-grupo-16/orchestration/issues/65)) |
| Identidade do CI, sem credencial estática | **OIDC** do GitHub Actions assumindo role do IAM |
| Exposição externa | **Load Balancer** provisionado pelo Service do Kong ([#64](https://github.com/fcg-grupo-16/orchestration/issues/64)) |

Os serviços de dados — MongoDB, os dois Redis e o RabbitMQ — **não** são decididos aqui. Se ficam
in-cluster ou passam a gerenciados é a [#66](https://github.com/fcg-grupo-16/orchestration/issues/66),
porque a resposta depende de cota e custo, não de provedor.

### O que de fato decidiu: a busca gerenciada

O desafio é mais exigente com a busca do que com o resto. Para NoSQL e cache ele aceita o que já
temos rodando em container; para a busca, pede **serviço gerenciado** e nomeia as opções aceitas:
*"Amazon OpenSearch, Elastic Cloud ou uma instância gerenciada do Elasticsearch"*.

Isso elimina metade dos provedores:

- **AWS** tem o OpenSearch Service como serviço de primeira parte — compatível com a API do
  Elasticsearch e com cliente oficial para .NET.
- **Azure** não tem Elasticsearch de primeira parte. O serviço de busca gerenciado da Azure é o AI
  Search, que **não** é compatível com Elasticsearch e, portanto, não atende ao que o enunciado
  nomeia. O caminho na Azure seria o Elastic Cloud pelo marketplace — ou seja, uma conta e uma
  cobrança de terceiro, fora do plano educacional.
- **Google Cloud** está na mesma situação da Azure.
- **Oracle Cloud** tem OpenSearch gerenciado e Kubernetes gerenciado, e seria tecnicamente viável.

Entre AWS e OCI, decidiu o acesso: é o plano **AWS** que o grupo está providenciando com o professor.

### O resto da plataforma não depende disso

Vale registrar para não superestimar a decisão: **o que existe hoje é todo portátil.** Kong Ingress
Controller, KEDA, Prometheus, Grafana, Jaeger, MongoDB, Redis e RabbitMQ rodam como container em
qualquer Kubernetes. A escolha de provedor não define a arquitetura — define apenas de onde vêm as
peças gerenciadas e quem emite as credenciais.

Isso é uma propriedade desejável e foi deliberada desde a Fase 3: o gateway é CRD versionado, a
observabilidade é manifesto, e a função serverless é container. Se a cota do plano não couber, migrar
de provedor custa reescrever o Terraform e o workflow de CD — não a aplicação.

### Sobre rodar Azure Functions na AWS

Um avaliador vai notar: a função serverless é Azure Functions e o cluster é EKS. **Não é contradição,
e não muda nada do que a ADR 0003 decidiu.**

O que a ADR 0003 escolheu foi o *runtime* do Azure Functions no modelo de **worker isolado**, rodando
como container no Kubernetes, com KEDA fazendo a escala a zero a partir do tamanho da fila. A decisão
foi tomada justamente **contra** os planos hospedados da Azure, porque Consumption e Flex Consumption
não suportam o trigger de RabbitMQ, e os planos que suportam são de instância reservada — sem escala
a zero, que é o requisito.

Ou seja: o host de Functions nunca dependeu da Azure. É uma imagem de container com um binding de
RabbitMQ, e o KEDA é agnóstico de nuvem. Rodá-lo no EKS é a mesma arquitetura, noutro Kubernetes.

A única pendência real daí é o Terraform de Azure que ficou no repositório da função
([notifications-function#18](https://github.com/fcg-grupo-16/notifications-function/issues/18)):
ele provisiona um Function App que ninguém implanta, e precisa de destino explícito.

### Sobre "Pipeline de CI/CD Multi-Cloud"

O enunciado usa essa expressão como título do item, e o corpo esclarece: *"automatizar o ciclo de vida
da aplicação com GitHub Actions ou Azure DevOps"*. Lemos como **ferramenta de pipeline independente
da nuvem**, não como exigência de implantar em mais de um provedor — que seria incoerente com o item
seguinte, que manda escolher **um** provedor.

**GitHub Actions** atende, e é o que já está em uso nos quatro repositórios de serviço.

## Consequências

- **Terraform como IaC**, com estado em backend remoto. Estado em disco local faz só uma pessoa do
  grupo conseguir aplicar — ver [#62](https://github.com/fcg-grupo-16/orchestration/issues/62).
- **Nada de credencial estática no CI.** A autenticação no ECR e no EKS passa pela federação OIDC do
  GitHub Actions, com role assumida por token efêmero. Chave de acesso de longa duração em secret de
  repositório é exatamente o que o requisito 5 da fase manda evitar.
- **O Terraform de Azure da função fica órfão** e precisa de decisão explícita
  ([notifications-function#18](https://github.com/fcg-grupo-16/notifications-function/issues/18)).
  Deixar arquivo que provisiona infraestrutura que ninguém usa, com o CI validando a sintaxe dele,
  dá a impressão de que a plataforma implanta em Azure — o que não é verdade.
- **O custo é contínuo, não por uso.** EKS cobra o control plane por hora mesmo sem tráfego; o Load
  Balancer e o domínio do OpenSearch, idem. Isso muda o hábito de trabalho: em conta educacional, a
  plataforma precisa ser **destruída quando não estiver em uso**, e por isso a #62 exige um
  `terraform destroy` testado, não apenas escrito.
- **O `deploy-minikube.sh` não desaparece.** O caminho local continua sendo o ambiente de
  desenvolvimento e de teste de integração; o cluster gerenciado é o ambiente de produção e de
  demonstração. Manter os dois significa manter dois caminhos de deploy em sincronia — custo que
  aceitamos para não depender de nuvem para desenvolver.

### ⚠️ Verificação de cota — pendente, e bloqueia o provisionamento

Esta ADR decide o **provedor**. O que ela **não** pode decidir sem acesso à conta é o
dimensionamento, e isso bloqueia as issues de provisionamento. Perguntas a responder com o professor,
antes de rodar qualquer `terraform apply`:

- [ ] Que modalidade de plano é — AWS Academy Learner Lab, AWS Educate ou conta com crédito? As três
      têm restrições diferentes, e algumas **limitam quais serviços podem ser criados** e com qual
      role do IAM.
- [ ] **O EKS está liberado nessa modalidade?** É o item mais crítico: sem ele, o requisito de
      Kubernetes gerenciado cai e a decisão de provedor precisa ser reaberta.
- [ ] **O OpenSearch Service está liberado?** Mesma lógica, para o requisito de busca.
- [ ] As sessões expiram? Em modalidades de laboratório, o ambiente é efêmero e **os recursos podem
      ser destruídos ao fim da sessão** — o que inviabiliza "produção" no sentido do desafio e muda o
      plano de gravação do vídeo.
- [ ] Qual o crédito total e o teto de gasto, para dimensionar nós, o domínio de busca e decidir a
      #66 e a #67 com número em vez de palpite.
- [ ] Cota de IP elástico e de Load Balancer na região escolhida.

Enquanto isso não fechar, o épico [#72](https://github.com/fcg-grupo-16/orchestration/issues/72)
mantém a Onda 0 em andamento — as duas ADRs e as duas issues de busca do `catalog-api`, que são
desenvolvidas contra um OpenSearch em container local.

## Alternativas descartadas

- **Azure** — a mais tentadora pela coincidência com o Azure Functions, e a que menos atende. Não tem
  Elasticsearch gerenciado de primeira parte, e o AI Search não é compatível com a API que o
  enunciado nomeia; a saída seria Elastic Cloud pelo marketplace, com cobrança de terceiro fora do
  plano educacional. A coincidência, além disso, é aparente: pela ADR 0003 o host de Functions roda em
  Kubernetes, não em serviço da Azure.
- **Google Cloud** — mesma lacuna de busca gerenciada compatível com Elasticsearch. O GKE é excelente,
  mas o requisito que mais restringe é a busca, não o Kubernetes.
- **Oracle Cloud** — tecnicamente viável: tem OKE e OpenSearch gerenciado, e o free tier é generoso.
  Descartada por acesso, não por mérito: não há caminho de conta pelo curso, e a familiaridade do
  grupo com o ecossistema é menor — numa fase cujo item mais pesado é provisionar cluster, isso vira
  risco de cronograma.
- **Mais de um provedor ao mesmo tempo**, lendo "Multi-Cloud" literalmente — multiplicaria o esforço
  de provisionamento numa fase que já tem o cluster como maior item, sem atender a nada que o
  enunciado peça: o próprio corpo do texto manda escolher **um** provedor.
- **Kubernetes autogerenciado em instâncias (IaaS)** — vedado em letra: *"Não será aceito o uso de
  instâncias isoladas (IaaS) para rodar containers manualmente"*.

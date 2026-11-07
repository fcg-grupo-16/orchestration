# ADR 0009 — Serviços de dados na AWS: o que migra para gerenciado e o que fica no cluster

- **Status:** aceito, com **uma** pendência de custo (Redis de cache — ver "Pendente")
- **Data:** 2026-11-07
- **Issue:** [#66](https://github.com/fcg-grupo-16/orchestration/issues/66)
- **Depende de:** [ADR 0008](0008-provedor-de-nuvem-aws.md) (AWS como provedor)

## Contexto

A plataforma tem quatro peças com estado, todas rodando hoje dentro do cluster:

| Peça | Hoje | Candidato gerenciado na AWS |
|---|---|---|
| MongoDB | StatefulSet, replica set `rs0` de nó único | Amazon DocumentDB |
| Redis de **cache** | Deployment, volátil de propósito (`allkeys-lru`, sem persistência) | ElastiCache |
| Redis de **idempotência** | StatefulSet, AOF + `noeviction` ([ADR 0006](0006-redis-dedicado-para-idempotencia.md)) | ElastiCache ou MemoryDB |
| RabbitMQ | Deployment, imagem customizada com plugin e topologia | Amazon MQ for RabbitMQ |

O enunciado da Fase 4 **só exige serviço gerenciado para a busca**. Para NoSQL e cache, aceita o
que já está rodando em container. Migrar estas quatro peças, portanto, é ganho de maturidade, não
requisito. Esta ADR decide **peça por peça**, porque os requisitos são diferentes. As duas instâncias
de Redis, por exemplo, têm requisitos opostos.

### Como a análise foi feita

Sem conta na AWS, nada pôde ser testado contra os serviços. A análise cruza **o que o código usa de
fato** (levantado nos quatro repositórios de serviço) com a **documentação oficial da AWS**,
consultada em 2026-11-07. Cada afirmação sobre um serviço gerenciado tem a fonte ao lado. O que não
foi possível confirmar está marcado como 🔶 **não verificado**.

O inventário do código mudou a pergunta que a issue fazia. Ela perguntava se o DocumentDB "suporta
transação". Os componentes que precisam funcionar são mais específicos:

| Serviço | O que usa do MongoDB | O que usa do RabbitMQ |
|---|---|---|
| `users-api` | `MassTransit.MongoDb` (**outbox** transacional), `MongoDB.EntityFrameworkCore` 10.0.2 | publish |
| `catalog-api` | outbox e inbox do MassTransit, `MongoDB.EntityFrameworkCore` 10.0.1, agregação com **`$facet`**, índices únicos | `UseDelayedMessageScheduler` + `UseDelayedRedelivery` |
| `payments-api` | `MongoDB.Driver` 3.9.0, idempotência por índice único (**sem** transação) | `UseDelayedMessageScheduler` + `UseDelayedRedelivery` |
| `notifications-function` | `MongoDB.Driver` 3.9.0, histórico | trigger `RabbitMQTrigger`, que **não** declara filas |

## Decisão

| Peça | Decisão | Motivo em uma linha |
|---|---|---|
| **RabbitMQ** | **fica no cluster** | o Amazon MQ não oferece o plugin de mensagem atrasada que dois serviços usam |
| **Redis de idempotência** | **fica no cluster** | o ElastiCache não tem AOF; o MemoryDB atende, e fica registrado como caminho futuro |
| **MongoDB** | **fica no cluster** | o DocumentDB só serve na versão 8.0.2+, e o risco cai sobre o outbox, que não dá para testar sem conta |
| **Redis de cache** | **migra para ElastiCache**, se couber na cota | é a única peça sem impedimento técnico e com rollback trivial |

### RabbitMQ → fica no cluster (eliminado por impedimento técnico)

**O impedimento.** O `catalog-api` e o `payments-api` configuram `UseDelayedMessageScheduler()`, que
depende do plugin `rabbitmq_delayed_message_exchange`. É por causa dele que a imagem `fcg-rabbitmq`
existe: o Dockerfile baixa o `.ez` com checksum e o habilita offline.

O Amazon MQ for RabbitMQ publica a lista fechada de plugins que oferece: management, shovel,
federation, consistent hash exchange, OAuth 2, LDAP, HTTP, SSL certificate, aws, JMS Topic Exchange e
Prometheus ([fonte](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/rabbitmq-basic-elements-plugins.html)).
**O de mensagem atrasada não está nela.**

Migrar exigiria **mudar código em dois serviços**: trocar o scheduler do MassTransit por um que não
dependa do broker (Quartz ou Hangfire, com estado em banco) ou abrir mão do redelivery atrasado, que
hoje absorve indisponibilidades longas do Mongo sem mandar a mensagem para a `_error`. É uma mudança
de comportamento de resiliência, fora do escopo de uma fase de infraestrutura.

**Três outros atritos**, que não eliminam sozinhos mas somam custo:

1. **TLS obrigatório.** O Amazon MQ *"requires strong Transport Layer Security (TLS) encryption for
   all client connections"* ([fonte](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/data-protection.html)),
   e os exemplos usam `amqps://...:5671`. Hoje os três serviços chamam `cfg.Host(host, "/", ...)`
   sem TLS (nenhum `UseSsl` no código), e a Function e o `TriggerAuthentication` do KEDA usam AMQP
   puro. São quatro pontos de mudança.
2. **A nossa política de dead-letter empataria com a da AWS.** O Amazon MQ cria uma política padrão,
   `AWS-DEFAULT-POLICY-SINGLE-INSTANCE`, com **prioridade 0**
   ([fonte](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/rabbitmq-defaults.html)). A
   nossa `notifications-dlx`, no `definitions.json`, **também tem prioridade 0**. O RabbitMQ aplica
   uma política só por fila, e com prioridades iguais a escolha não é garantida, ou seja, o
   dead-letter pode simplesmente não valer. Ela precisaria de prioridade ≥ 1. E aí os limites da
   política padrão da AWS deixariam de valer nessas filas, a menos que fossem copiados para a nossa.
3. **Versão.** O RabbitMQ 4.x no Amazon MQ só existe no tipo de instância `mq.m7g`. O 3.13, que é a
   versão que rodamos, existe também no `mq.t3`, o menor
   ([fonte](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/rabbitmq-version-management.html)).
   Trocar de versão não destrava o plugin: a lista de plugins não muda.

**Sobre a pergunta da issue — como a topologia seria provisionada fora da imagem:** fica registrada
para quando o impedimento for removido. A resposta seria o provider Terraform de RabbitMQ (que fala
com a API de management, suportada pelo Amazon MQ, conforme a mesma página de plugins) declarando
exchanges, filas, bindings e a política de DLX. **Consequência para a
[#63](https://github.com/fcg-grupo-16/orchestration/issues/63): nenhuma.** A imagem `fcg-rabbitmq`
continua existindo, e o repositório dela no ECR também.

### Redis de idempotência → fica no cluster (o MemoryDB atende, como evolução)

A [ADR 0006](0006-redis-dedicado-para-idempotencia.md) exige duas propriedades medidas: **não
despejar chave** (`noeviction`) e **sobreviver à recriação do nó** (AOF).

| Propriedade | ElastiCache | MemoryDB |
|---|---|---|
| `noeviction` | permitido, mas o padrão é `volatile-lru`: precisa de parameter group próprio ([fonte](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/ParameterGroups.Engine.html)) | **padrão** é `noeviction` ([fonte](https://docs.aws.amazon.com/memorydb/latest/devguide/parametergroups.redis.html)) |
| persistência | **AOF não é suportado** desde o Redis OSS 2.8.22 (`appendonly`: *"no longer supported"*, mesma fonte). Sobra snapshot, que perde o que foi gravado depois dele | log transacional Multi-AZ: *"stores data durably across multiple Availability Zones"* ([fonte](https://docs.aws.amazon.com/memorydb/latest/devguide/what-is-memorydb.html)) |
| menor nó | — | `db.t4g.small` ([fonte](https://docs.aws.amazon.com/memorydb/latest/devguide/nodes.supportedtypes.html)) |

**O ElastiCache não atende.** Com snapshot, uma falha do nó entre dois snapshots perde as chaves de
idempotência gravadas no intervalo. Uma reentrega do RabbitMQ nessa janela vira **e-mail duplicado**,
exatamente o defeito que a ADR 0006 corrigiu.

**O MemoryDB atende tecnicamente**, e é o caminho certo se um dia esta peça migrar. Fica no cluster
nesta fase porque é um serviço a mais para provisionar, pagar e proteger, sem requisito do enunciado
pedindo, para uma peça cujo comportamento atual já foi medido e funciona.

### MongoDB → fica no cluster (o DocumentDB é viável só na 8.0.2+, e o risco não é testável)

A verificação que a issue chamou de eliminatória **passa**: o DocumentDB *"supports transactions in
Amazon DocumentDB 4.0 and later"*
([fonte](https://docs.aws.amazon.com/documentdb/latest/developerguide/transactions.html)). Mas o
inventário do código encontrou restrições mais finas:

1. **`$facet` só existe no DocumentDB 8.0.2+.** A tabela de estágios de agregação marca `$facet` como
   **não suportado** em 3.6, 4.0 e 5.0, e suportado no 8.0 a partir do 8.0.2
   ([fonte](https://docs.aws.amazon.com/documentdb/latest/developerguide/mongo-apis.html)). O resumo de
   avaliações do `catalog-api` (`AvaliacaoRepository`) é um `$facet`. **Qualquer versão abaixo
   quebra o endpoint de resumo.** A boa notícia é que a 8.0.2 também resolve as retryable writes, que
   antes exigiam `retryWrites=false`
   ([fonte](https://docs.aws.amazon.com/documentdb/latest/developerguide/retryable-writes.html)). O
   menor tipo de instância com 8.0 é o `db.t4g.medium`
   ([fonte](https://docs.aws.amazon.com/documentdb/latest/developerguide/db-instance-classes.html)).
2. **Dentro de transação, não dá para criar coleção implicitamente.** Na lista de capacidades não
   suportadas em transação: *"insert is not supported if it is not run against an existing
   collection"* (página de transações, acima). O outbox do MassTransit grava **dentro** da transação.
   Num banco recém-criado, o primeiro cadastro de usuário falharia. As coleções teriam de ser
   **pré-criadas** num passo de bootstrap. Levantadas do Mongo atual:
   - `usersdb`: `usuarios`, `refresh_tokens`, `outbox.messages`, `outbox.states`, `inbox.states`
   - `catalogdb`: `jogos`, `pedidos`, `biblioteca_jogos`, `avaliacoes`, `outbox.messages`,
     `outbox.states`, `inbox.states`
3. **`countDocuments()` não é suportado dentro de transação** (mesma lista). 🔶 **Não verificado** se
   o MassTransit ou o provider de EF Core o chamam dentro da transação.
4. 🔶 **Não verificado: o `MongoDB.EntityFrameworkCore` com DocumentDB.** A página de compatibilidade
   do provider não renderiza sem JavaScript, e a da AWS não o menciona. É um provider de EF Core escrito
   contra o MongoDB, rodando contra um banco *compatível com* MongoDB: só o teste responde.
5. **TLS ligado por padrão**, com o parameter group padrão imutável
   ([fonte](https://docs.aws.amazon.com/documentdb/latest/developerguide/security.encryption.ssl.html)).
   As connection strings passam a precisar de `tls=true` e do bundle de CA da AWS dentro das imagens
   dos serviços, ou de um parameter group próprio com TLS desligado, o que não recomendamos.

**Por que isso decide "fica":** os itens 2, 3 e 4 caem todos sobre o **outbox**, que é o que
garante o cadastro (`users-api`) e a compra (`catalog-api`). Não existe emulador local do DocumentDB.
Esses três riscos só seriam medidos com a conta aberta, em cima do caminho mais crítico da plataforma,
numa fase cujo item mais pesado é outro (o cluster). O enunciado aceita o Mongo em container. O ganho
não paga o risco.

**Alternativa registrada, não avaliada:** MongoDB Atlas elimina os itens 1 a 4 por ser MongoDB de
verdade. Mas é conta e cobrança de terceiro, fora do plano educacional, e exige saída do cluster para a
internet. 🔶 Não verificado.

### Redis de cache → migra para ElastiCache, se couber na cota

É a única peça em que nada da análise pesa contra:

- **Perder chave é aceitável por desenho.** É cache-aside com invalidação por geração de chave
  ([ADR 0005](0005-cache-redis-invalidacao-por-geracao.md)). Uma falha do nó esvazia o cache, e a
  próxima leitura vai ao Mongo. Por isso a falta de AOF, que elimina o ElastiCache para a idempotência,
  é irrelevante aqui.
- **A política de despejo que usamos é permitida:** `allkeys-lru` está entre os valores válidos de
  `maxmemory-policy` (fonte da tabela de parâmetros, acima). Precisa de parameter group próprio,
  porque o padrão é `volatile-lru`. Com `volatile-lru`, só as chaves com TTL seriam despejadas.
- **Nenhuma mudança de código.** O `catalog-api` e o `users-api` já leem `Redis__ConnectionString`
  por configuração ([ADR 0005](0005-cache-redis-invalidacao-por-geracao.md)). Muda o valor, que vem
  do gerenciador de segredos da [#65](https://github.com/fcg-grupo-16/orchestration/issues/65).
- **Rollback trivial:** voltar o `Redis__ConnectionString` para `redis:6379` (o Deployment
  in-cluster continua no repositório). O conteúdo do cache é reconstruível, então não há migração de
  dado em nenhum dos dois sentidos.

E ela entrega o que o desafio valoriza: uma peça de dados **gerenciada** na arquitetura, demonstrável
no vídeo, ao lado do OpenSearch.

## Pendente — o que esta ADR ainda não decide

🔶 **Se o Redis de cache migra de fato depende de a conta permitir ElastiCache e do custo de um
`cache.t4g.micro`.** Sem conta, não há número. Verificar com:

```bash
aws elasticache describe-cache-engine-versions --engine redis --query 'CacheEngineVersions[].EngineVersion'
aws pricing get-products --region us-east-1 --service-code AmazonElastiCache \
  --filters Type=TERM_MATCH,Field=instanceType,Value=cache.t4g.micro | head -c 2000
```

Se der `AccessDenied` ou não couber no crédito, **o Redis de cache fica no cluster e esta ADR passa
a "tudo in-cluster"**, o que continua dentro do enunciado. Nesse caso, atualize a tabela da Decisão e
o status.

## Consequências

- **A [#63](https://github.com/fcg-grupo-16/orchestration/issues/63) não muda.** O RabbitMQ fica no
  cluster, e a imagem `fcg-rabbitmq` continua precisando de repositório no ECR.
- **Três peças de dados seguem no EKS:** os StatefulSets `mongodb` e `redis-idempotencia` e o
  Deployment `rabbitmq`. Os dois StatefulSets precisam de volume persistente, e por isso o driver EBS CSI da
  [#62](https://github.com/fcg-grupo-16/orchestration/issues/62) é obrigatório, não opcional.
- **O dimensionamento dos nós da #62 tem de comportar os três.** O Mongo sozinho pede 512Mi de
  `requests` desde a [#71](https://github.com/fcg-grupo-16/orchestration/issues/71).
- **Se o cache migrar:** a [#62](https://github.com/fcg-grupo-16/orchestration/issues/62) ganha um
  `aws_elasticache_cluster` com parameter group próprio (`allkeys-lru`), em subnet privada, com
  security group que só aceita conexões do security group dos nós. O `Redis__ConnectionString` do
  `catalog-api` e do `users-api` passa a vir do Secrets Manager. O Deployment `redis` in-cluster
  continua no repositório, para o rollback e para o compose.
- **O compose não muda.** Desenvolvimento local continua com tudo em container.

## Alternativas descartadas

- **Migrar as quatro peças**, pela leitura de que "gerenciado é sempre mais Cloud-Native". Duas são
  eliminadas por impedimento técnico (RabbitMQ e ElastiCache para idempotência) e uma por risco não
  testável (Mongo). Forçar a migração significaria mudar código de resiliência em dois serviços e
  apostar o outbox num banco só parcialmente compatível, para cumprir algo que o enunciado não pede.
- **Amazon MQ, removendo o redelivery atrasado.** Elimina o impedimento do plugin, mas troca
  resiliência medida (uma indisponibilidade do Mongo de minutos é absorvida sem perder mensagem) por
  conveniência de infraestrutura.
- **ElastiCache para a idempotência, aceitando snapshot.** Reintroduz o e-mail duplicado que a ADR 0006
  corrigiu, só que agora em falha de nó em vez de despejo.
- **DocumentDB 5.0**, que roda em mais tipos de instância. Não tem `$facet`, então quebraria o
  resumo de avaliações.
- **Manter tudo in-cluster sem avaliar.** Seria a mesma decisão para três das quatro peças, mas sem
  saber por quê. A próxima pessoa a perguntar "por que não Amazon MQ?" refaria a análise do zero.

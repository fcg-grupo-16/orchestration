# ADR 0006 — Redis dedicado e durável para o store de idempotência

- **Status:** aceito
- **Data:** 2026-09-14
- **Issue:** [#35](https://github.com/fcg-grupo-16/orchestration/issues/35)

## Contexto

A Fase 3 provisionou **um** Redis para a plataforma, configurado — corretamente — como cache:
`--maxmemory-policy allkeys-lru`, `--save ""`, `--appendonly no`, sem PersistentVolumeClaim. O
comentário do manifesto justificava a ausência de persistência: *"todo dado aqui é reconstruível a
partir do MongoDB"*.

Na mesma fase, a `notifications-function` passou a usar **esse mesmo Redis** como store de
idempotência (`SET NX EX`, TTL de 7 dias), que é o que impede o cliente de receber e-mail duplicado
quando o RabbitMQ reentrega uma mensagem.

As duas decisões não podiam coexistir, e a justificativa acima é **falsa** para a chave de
idempotência: ela não é reconstruível de lugar nenhum.

O conflito não é teórico. Medições registradas na issue:

- um `restart` do Redis zerou o keyspace, incluindo uma chave de idempotência ativa;
- em container descartável com as mesmas flags, **200 chaves de idempotência viraram 2** sob tráfego
  normal de cache (`evicted_keys: 300200`).

E não é azar: a chave de idempotência é **escrita uma vez e lida nunca** — a única leitura é a
duplicata, que é rara. Ela é, por construção, o dado **mais frio** de uma instância compartilhada com
os caches quentes de `users-api` e `catalog-api`, e é exatamente isso que `allkeys-lru` escolhe
despejar primeiro.

O agravante é o contrato do store: ele é **fail-closed**. Sem Redis, a Function não envia e a
mensagem vai para a dead-letter. Reprocessar a DLQ é, portanto, procedimento rotineiro — e é
precisamente a operação que fica insegura se a chave tiver sido despejada nesse meio-tempo.

## Decisão

Uma **segunda instância de Redis, dedicada à idempotência**, em
`k8s/12b-infra-redis-idempotencia.yaml`:

| | Redis de cache (`12-`) | Redis de idempotência (`12b-`) |
|---|---|---|
| kind | `Deployment` | **`StatefulSet`** com `volumeClaimTemplates` |
| persistência | `--save ""`, `--appendonly no` | **`--appendonly yes`**, `--appendfsync everysec` |
| memória cheia | `allkeys-lru` (despeja) | **`noeviction`** (recusa a escrita) |
| `maxmemory` | 256 MB | 64 MB |
| consumidores | `users-api`, `catalog-api` | `notifications-function` |

- **`StatefulSet`, não `Deployment`**, seguindo o precedente que o próprio repositório já
  estabeleceu no `10-infra-mongodb.yaml`: o que é durável usa `volumeClaimTemplates`. A diferença é
  prática, não estética — o PVC de um `volumeClaimTemplate` é **retido** pelo Kubernetes quando o
  StatefulSet é removido, enquanto um PVC declarado à parte em `k8s/` seria apagado pelo
  `kubectl delete -R -f k8s/` do undeploy, levando junto as chaves que o componente existe para
  preservar.
- **`noeviction`** faz o Redis **recusar** escritas quando a memória enche. Combinado com o store
  fail-closed, a mensagem vai para a dead-letter em vez de gerar e-mail sem garantia de unicidade.
  Falhar alto é o comportamento correto aqui; despejar em silêncio é o defeito que esta ADR corrige.
- A connection string da Function passa a vir de `REDIS_IDEMPOTENCIA_CONN` no `seal-secrets.sh`,
  separada de `REDIS_CONN`.

## Consequências

- **A durabilidade é "praticamente completa", não absoluta.** Com `appendfsync everysec`, um
  `kill -9` perde no máximo 1 segundo de escritas — na prática, uma duplicata rara. `always` daria
  durabilidade por escrita ao custo de um fsync por comando, o que não se justifica para o volume
  desta plataforma. Dizer "durável" sem essa ressalva seria impreciso.
- Mais um componente no cluster: ~130 linhas de YAML, 64 MB de memória e um PVC de 1 GB.
- **O `docker-compose.yml` não ganha um segundo Redis**, e isso é deliberado: a
  `notifications-function` não roda no compose (scale-to-zero exige KEDA), então não há consumidor de
  idempotência ali. Replicar o componente seria carregar um serviço que ninguém usa.
- O PVC **sobrevive ao `undeploy-minikube.sh`**, como o do MongoDB. Para descartá-lo de fato:
  `kubectl -n fcg delete pvc dados-redis-idempotencia-0`.
- ⚠️ **A instância nova nasce VAZIA, e isso tem um custo único na virada.** No momento da migração
  havia **36** chaves `fcg:notifications:*` na instância antiga, e elas **não** foram transportadas.
  Consequência concreta: uma mensagem cuja chave de deduplicação estivesse entre elas, se
  reprocessada a partir da dead-letter, seria reenviada — e-mail duplicado, uma vez.
  A janela se fecha sozinha: o TTL do store é de **7 dias**, então após esse prazo nenhuma chave
  antiga teria relevância de qualquer forma.
  **Não foi escrito script de migração de propósito.** Copiar as chaves significaria lê-las de uma
  instância `allkeys-lru` onde elas podem já ter sido despejadas — exatamente o defeito que esta ADR
  corrige. Um script assim daria a impressão de transporte completo sem poder garanti-lo, o que é
  pior do que declarar a lacuna.

## Alternativas descartadas

- **Mover a idempotência para o MongoDB** (opção B da issue). Era a mais atraente na leitura inicial,
  porque o Mongo já é `StatefulSet` com PVC e a Function já carrega o driver. **Foi descartada após
  ler o fluxo:** a marcação acontece **antes** do envio e o histórico é gravado **depois**, e só em
  sucesso — então a escrita de histórico **não pode** absorver a marcação. Seria uma collection nova,
  com índice único e índice TTL, mais um round-trip por mensagem, e uma reescrita do store num
  repositório diferente. O `NotificationRecord`, além disso, declara compatibilidade de formato com
  os documentos da Fase 2, o que torna arriscado impor um índice único àquela collection.
- **Não fazer nada e documentar** (opção C). É o estado que a entrega da Fase 3 levou ao ar, e é
  defensável — a demonstração não depende disso. Mas deixa um caminho conhecido para e-mail
  duplicado, com gatilhos banais: reschedule de pod, drain de nó, bump de imagem.
- **Trocar para `volatile-lru` ou `volatile-ttl`.** **Piora**: essas políticas miram exatamente as
  chaves **com TTL**, que é o caso das nossas.
- **Database lógico separado (`SELECT 1`) na mesma instância.** Não resolve: `maxmemory` e a política
  de evicção são por **instância**, não por database.

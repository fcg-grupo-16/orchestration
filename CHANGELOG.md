# Changelog

Todas as mudanças relevantes deste repositório de orquestração são documentadas aqui.

O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.0.0/)
e o versionamento adere a [Semantic Versioning](https://semver.org/lang/pt-BR/).

## [0.23.0] - 2026-09-14

### Corrigido
- **O `yamllint` do CI dizia "✓" sem olhar `docker/`.** O escopo do passo era
  `k8s/ gateway/ docker-compose.yml .github/`, e o diretório que ficava de fora tinha **8 erros
  reais** contra a mesma `.yamllint` versionada — todos em `docker/prometheus/prometheus.yml`
  (`too many spaces inside braces`, nos mapeamentos de fluxo `labels: { service: ... }`).

  Pior que não ter lint é **parecer** ter: o passo saía verde e o leitor concluía que todo o YAML do
  repositório havia sido verificado. O `docker/` não é acessório — guarda o `prometheus.yml` que
  define os alvos da coleta, o provisionamento do Grafana e as definições do broker.

  Os 8 achados foram corrigidos e o escopo passou a cobrir **todo o YAML rastreado** (24 arquivos,
  nenhum de fora — conferido). A correção é puramente cosmética: a estrutura carregada do
  `prometheus.yml` tem o **mesmo hash** antes e depois, e o `promtool check config` aceita o
  arquivo novo.

  Regra registrada no próprio passo: se algum diretório precisar ficar fora, a exclusão vai no
  `.yamllint` **com o motivo escrito**, nunca implícita na linha de comando — que era o que tornava
  esta lacuna invisível. Fecha #48.

## [0.22.0] - 2026-09-14

### Modificado
- **A documentação deixa de declarar que a cadeia do CADASTRO não fecha: ela fecha, e a da compra
  chega até a notificação.** Medido no cluster:

  | | Antes | Depois |
  |---|---|---|
  | `GET /api/services` do Jaeger | 4 serviços | **5** (+ `notifications-function`) |
  | trace do cadastro | `users-api` em **0 de 10** multi-serviço, e a Function sequer aparecia no Jaeger | **5 spans**, `users-api` + `notifications-function` |
  | trace da compra | 9 spans, 2 serviços | **10 spans, 3 serviços** (+ a Function) |

  A `notifications-function` lê o contexto W3C do header `MT-Activity-Id` do envelope do MassTransit
  — ela **não** usa MassTransit (consome pelo binding `RabbitMQTrigger`), então a costura é explícita.
  Atualizados: diagrama e ressalva do README, ADR 0002, item 3 e tabela de pendências do relatório, e
  o bloco 3b e o "O que não prometer" do roteiro.

### Notas
- ⚠️ **Nada disso veio de código novo neste ciclo.** A instrumentação já estava no `main` da
  `notifications-function` desde o PR #13 daquele repositório. A
  [notifications-function#14](https://github.com/fcg-grupo-16/notifications-function/issues/14), que
  descrevia a Function como não instrumentada, foi aberta **depois** daquele merge e mediu um
  checkout desatualizado. O que faltava era **deploy**: o cluster servia uma imagem anterior ao PR.
  A lição fica registrada porque o modo de falha é silencioso — documentação e issue concordavam
  entre si e ambas estavam erradas.
- A entrada 0.21.0 abaixo continua afirmando que a cadeia do cadastro está aberta. **É histórico e
  fica como está**, pela mesma regra que ela própria aplicou às 0.17.0 e 0.19.0.

## [0.21.0] - 2026-09-14

### Modificado
- **A documentação deixa de declarar que não há trace distribuído: a cadeia da COMPRA fecha.** O
  `payments-api` foi instrumentado em
  [payments-api#19](https://github.com/fcg-grupo-16/payments-api/issues/19) e
  [#20](https://github.com/fcg-grupo-16/payments-api/issues/20) (merge `beaae1e`), e a medição no
  cluster mudou de lado:

  | | Antes | Depois |
  |---|---|---|
  | `GET /api/services` do Jaeger | `catalog-api`, `users-api` | **+ `payments-api`** |
  | traces multi-serviço | **0 de 10** | trace de 9 spans em dois serviços |
  | `/metrics` do payments | 404 | **200**, 28 famílias |
  | alvos do Prometheus | UP=3 DOWN=1 | **UP=4 DOWN=0** |

  O trace `12a9febb22840ab46a93a61d4df07983` percorre
  `catalog-api → RabbitMQ → payments-api → RabbitMQ → catalog-api` num único trace, com
  `fcg.order.id`, `fcg.payment.status` e `fcg.payment.rule` no span do pagamento.
  Atualizados: diagrama e ressalvas do README, ADR 0002, item 3 e tabela de pendências do relatório,
  e os blocos 3b e "O que não prometer" do roteiro do vídeo.

- **O diagrama de arquitetura ganhou a seta OTLP do `payments-api`** e perdeu o rótulo
  `scrape: 404, target down`. Continua sendo o estado real: a `notifications-function` segue **sem**
  seta OTLP, porque segue sem instrumentação.

- **`verify-fase3.sh` volta a reprovar qualquer alvo em `down`, e o limiar sobe de 3 para 4.** O
  script carregava uma exceção que rebaixava o `payments-api` em `down` a simples aviso — correta
  enquanto o serviço não tinha instrumentação, e perigosa no minuto seguinte: um alvo caído por
  motivo **real** passaria como benigno e o checklist diria "PRONTO PARA GRAVAR". O limiar `UP >= 3`
  tinha o mesmo defeito por outro caminho — com quatro alvos, ele passa mesmo com um deles fora do
  ar. Os quatro são os três serviços ASP.NET mais o próprio Prometheus; a `notifications-function`
  fica de fora de propósito (`prometheus.io/scrape: "false"`), porque com scale-to-zero o pod vive
  segundos e é incompatível com o *pull*.

- **O aviso "os painéis ficam vazios até a instrumentação entrar" saiu do README e de dentro do
  próprio dashboard.** O texto morava em `observability/fcg-overview.json` — e, por geração, em
  `k8s/41b-grafana-dashboard.yaml` — ou seja, aparecia **na tela** durante a gravação, afirmando que
  os alvos estão `DOWN` com `404`. No lugar dele ficou a causa que de fato resta para um painel
  vazio: as queries usam `rate(...[5m])` e sem tráfego recente não há série.

### Notas
- ⚠️ **A cadeia do CADASTRO continua aberta, e a distinção importa.** O fluxo da compra é
  `catalog → payments → catalog` e não passa pela Function; o do cadastro é
  `users-api → notifications-function`. Medido agora: os traces do `users-api` seguem em **0 de 10**
  multi-serviço, porque a Function não tem OpenTelemetry — o `UserCreatedEvent` sai com contexto e o
  contexto morre no consumo. É a
  [notifications-function#14](https://github.com/fcg-grupo-16/notifications-function/issues/14).
  Por isso os textos afirmam o trace distribuído **da compra**, e não o da plataforma inteira.
- As entradas 0.17.0 e 0.19.0 continuam descrevendo a cobertura como parcial. **É histórico e fica
  como está** — elas registram o que era verdade quando foram escritas.

## [0.20.0] - 2026-09-14

### Adicionado
- **Redis dedicado e durável para o store de idempotência** (`k8s/12b-infra-redis-idempotencia.yaml`),
  fechando a #35. `StatefulSet` com `volumeClaimTemplates`, `--appendonly yes`,
  `appendfsync everysec`, `--maxmemory 64mb` e **`--maxmemory-policy noeviction`**. Decisão e
  alternativas descartadas no [ADR 0006](docs/adr/0006-redis-dedicado-para-idempotencia.md). (#35)
- **Detectores da #35 no `verify-fase3.sh`**: existência do StatefulSet **não basta** — o defeito
  original era um Redis saudável, porém configurado como cache. O script confere a **configuração
  efetiva** (`maxmemory-policy=noeviction`, `appendonly=yes`), a presença do **PVC** (sem ele o AOF
  morre com o Pod e o `appendonly yes` vira falsa sensação de segurança) e se o secret da Function
  aponta para a instância certa. (#35)

### Corrigido
- **O Redis de cache e o store de idempotência estavam na mesma instância, e as duas configurações
  se excluíam.** O manifesto justificava a ausência de PVC dizendo que "todo dado aqui é
  reconstruível a partir do MongoDB" — verdadeiro para cache, **falso** para a chave que impede
  e-mail duplicado. E o conflito não era teórico: a chave de idempotência é escrita uma vez e lida
  nunca, então é sempre o dado **mais frio** da instância e a primeira que `allkeys-lru` descarta
  (medido na issue: **200 chaves viraram 2** sob tráfego normal de cache). Como o store da Function é
  *fail-closed*, perdê-la significa e-mail duplicado no reprocessamento da dead-letter — que é
  operação rotineira. (#35)
- `k8s/12-infra-redis.yaml`: o comentário afirmava que a `notifications-function` usava aquela
  instância **e**, na mesma frase, que perder o conteúdo era aceitável. As duas coisas não podiam ser
  verdadeiras ao mesmo tempo. (#35)
- `scripts/seal-secrets.sh`: a Function ganhou `REDIS_IDEMPOTENCIA_CONN`, separada de `REDIS_CONN`.
  Antes uma única variável servia os três secrets. Verificado antes de re-selar que os valores no
  cluster batiam com os defaults do script — inclusive a **paridade tripla do JWT** —, para a
  regeneração não trocar nada em silêncio. (#35)
- `scripts/deploy-minikube.sh`: espera o StatefulSet novo com `rollout status statefulset/...`.
  `deploy/` devolveria `NotFound` e, sob `set -e`, mataria o deploy. (#35)
- **A tabela de pendências do relatório de entrega listava #38 e #41 como abertas**, e elas foram
  fechadas na entrega anterior. Atualizada, com uma linha explícita sobre o que já foi resolvido.
- README: a seção de cache dizia que **uma** instância atendia toda a plataforma e ensinava um
  `--scan` no Redis de cache que, a partir de agora, **não mostra** as chaves de idempotência.

### Notas
- **A durabilidade é "praticamente completa", não absoluta.** Com `appendfsync everysec`, um
  `kill -9` perde no máximo 1 segundo de escritas — na prática, uma duplicata rara. `always` custaria
  um fsync por comando, o que não se justifica para o volume desta plataforma. Dizer "durável" sem a
  ressalva seria impreciso.
- **O `docker-compose.yml` não ganha um segundo Redis**, de propósito: a `notifications-function` não
  roda no compose (scale-to-zero exige KEDA), então não há consumidor de idempotência ali.
- O PVC `dados-redis-idempotencia-0` **sobrevive ao `undeploy-minikube.sh`**, como o do MongoDB —
  é a consequência desejada de usar `volumeClaimTemplates`. Para descartá-lo:
  `kubectl -n fcg delete pvc dados-redis-idempotencia-0`.
- ⚠️ **Custo único da virada: a instância nova nasce vazia.** Havia **36** chaves
  `fcg:notifications:*` na instância antiga e elas não foram transportadas — uma mensagem cuja chave
  de deduplicação estivesse entre elas geraria e-mail duplicado se reprocessada da dead-letter. A
  janela fecha sozinha pelo TTL de 7 dias. Não foi escrito script de migração de propósito: copiar
  chaves de uma instância `allkeys-lru` onde elas podem já ter sido despejadas daria impressão de
  transporte completo sem poder garanti-lo.

### Verificado
- **Fiação real**: um cadastro pelo gateway fez a própria Function gravar
  `fcg:notifications:processed:UserCreatedEvent:6aa81ea0…` em `redis-idempotencia`, com **0**
  ocorrências no Redis de cache.
- **Sobrevivência da chave REAL a um restart**: o UID do pod mudou (`126587c5` → `1f2fb7e1`, ou seja,
  recriação de fato) e a chave continuou lá (`exists=1`), com TTL de 604721 s.
- **Controle negativo**: um marcador gravado no Redis de **cache** foi de `exists=1` para `exists=0`
  após o restart daquele pod. É o que torna a prova acima significativa — sem ele, o teste mostraria
  apenas que o Redis funciona, não que as duas instâncias se comportam de forma oposta.
- **Detectores mutation-testados**: com `maxmemory-policy` trocada para `allkeys-lru`, o
  `verify-fase3.sh` acusa `[FALHA]`; restaurada, volta a passar.
- `verify-fase3.sh` completo: **exit 0**, 24 checagens OK e 2 avisos que não bloqueiam.

## [0.19.0] - 2026-09-14

### Corrigido
- **As citações da quebra do trace distribuído apontavam para a issue errada.** A documentação da
  Fase 3 indicava a [payments-api#20](https://github.com/fcg-grupo-16/payments-api/issues/20) como
  rastreadora — mas aquela issue é sobre `/metrics` em **404**, e fui eu quem a abriu. A issue da
  **cadeia de traces** é a
  [payments-api#19](https://github.com/fcg-grupo-16/payments-api/issues/19): **anterior**, parte do
  próprio épico, e que já descrevia o problema nas mesmas palavras — *"sem instrumentar este serviço,
  o trace da compra tem um buraco justamente no meio"* — além de trazer a correção pronta, com o
  `.AddSource("MassTransit")` que costura a cadeia.
  Corrigidas 6 citações em ADR 0002, README (2), relatório de entrega (2) e roteiro do vídeo; a
  tabela de pendências do relatório passou a distinguir as duas issues, que se resolvem pela mesma
  instrumentação mas respondem a perguntas diferentes.
  A evidência medida (Jaeger conhecendo 2 de 4 serviços, 0 de 10 traces multi-serviço, os dois traces
  órfãos da compra) foi levada para a #19, que até então não tinha comentário nenhum.
  ⚠️ O enquadramento anterior também sugeria que a lacuna fosse achado novo. **Não era** — já estava
  rastreada; o que faltava eram os números.

## [0.18.0] - 2026-09-14

### Corrigido
- **Liveness do MongoDB passa a ser TCP, não `exec mongosh` (#41).** O `mongosh` é um cliente Node:
  cada invocação sobe um runtime inteiro. Medido com o nó ocioso: mediana **525 ms**, máximo
  **2999 ms** para um simples `ping`. Sob concorrência — o padrão dos scripts deste repo — três
  invocações simultâneas levaram **3,8 s, 45,9 s e 73,2 s**. Com `timeoutSeconds: 10`, o kubelet
  registrava `command timed out after 10s` seguido de `Killing Container mongodb failed liveness
  probe`, acumulando **17 restarts** com `exitCode: 137` e `reason: Error`. O mesmo teste por TCP:
  **20 conexões, 0 falhas, mediana 2,0 ms, máximo 19,1 ms** — ~260x mais barato na mediana.
  É também o contrato certo: liveness responde "o processo está vivo?", não "as dependências estão
  boas?".
- **Readiness do MongoDB continua `exec` — e tinha de continuar**: é ela que faz o bootstrap
  idempotente do `rs0`, pré-requisito do outbox transacional. O que mudou foi a tolerância:
  `failureThreshold` de 6 para **12** (a mesma filosofia do healthcheck do compose, que usa
  `retries: 10` por conhecer a lentidão do mongosh) e `timeoutSeconds` de 10 para **8**, abaixo do
  `periodSeconds: 10` de propósito — timeout maior que o período faz as execuções se sobreporem, e
  cada uma sobe outro runtime Node, que é a própria contenção que a issue trata. (#41)
- **O `users-api` apontava as DUAS probes para `/health` (#38)** — o endpoint **agregado legado**
  (`MapHealthChecks("/health")` sem predicate), que executa os checks de Mongo, RabbitMQ e Redis.
  Liveness acoplada a dependência **reinicia processo saudável** quando o banco oscila, e como o
  serviço para de consumir a fila ao reiniciar (`Bus stopped`), a oscilação vira atraso de evento.
  Agora usa `/health/live` (`Predicate = _ => false`) e `/health/ready`, como o `catalog-api` e o
  `payments-api` já faziam.
- **`timeoutSeconds` explícito em todos os serviços (#38).** Omitido, o Kubernetes aplica **1
  segundo** — o título da issue dizia "tem `timeoutSeconds: 1`", mas o manifesto **omitia** o campo;
  quem fosse consertar procuraria uma linha inexistente. Em repouso os endpoints respondem em
  milissegundos (medido, n=30: máximo de 25 ms no `users-api`, 35 ms no `catalog-api`, 3 ms no
  `payments-api`); o problema nunca foi endpoint lento, e sim a probe não ter margem para
  **contenção**. Agora `timeoutSeconds: 5` e `failureThreshold: 3` explícitos nos três.

### Verificado
- **Critério literal da #41** — `./scripts/gateway-test.sh` (17/17) e `./scripts/keda-test.sh`
  (12/12) executados de ponta a ponta: `mongodb-0` de **1 para 1** restart, os três serviços em
  **0**, e **zero** falhas de liveness na janela dos dois scripts (os únicos eventos `Killing` são
  teardown esperado: os dois pods do teste de rate limit e a Function voltando a zero pelo KEDA).
- Sob a contenção que antes derrubava tudo, os três serviços registraram **0 restarts** e **zero**
  falhas de liveness; só a readiness oscilou — que é onde a dependência deve ser checada, porque
  falhar ali tira do Service em vez de matar o processo.
- Os valores do manifesto conferem com os do cluster em 8/8 comparações.

### Notas
- **Os limites de memória do MongoDB ficam como estão.** Nenhum dos 17 restarts foi OOM. Forçando
  **quatro** `mongosh` concorrentes dentro do container, o kernel matou o mongod com
  `reason: OOMKilled` — mas isso é carga artificial que eu mesmo gerei medindo; os scripts do repo
  executam um `mongosh` por vez. Registrado no manifesto para quem depurar um OOM aqui não procurar
  no lugar errado.
- ⚠️ **"Não há eventos de OOM" não é prova de nada** — medido nesta base: um container pode terminar
  com `reason: OOMKilled` no status enquanto o `kubectl get events` mostra **zero** eventos de OOM.
  O que identifica morte por probe é o par `reason: Error` + o evento `Killing ... failed liveness
  probe`. Eu havia usado o argumento fraco num comentário de manifesto; foi removido.
- Das medições, **3 restarts do `mongodb-0` e 2 do `users-api` foram causados por mim** ao reproduzir
  a contenção, não pela operação normal da plataforma.

## [0.17.0] - 2026-09-14

### Adicionado
- **Seção `## Arquitetura` no README**, com diagrama Mermaid da plataforma completa e índice dos
  ADRs. ⚠️ O diagrama desenha o estado **real**, não o desejado: não há seta OTLP saindo do
  `payments-api` nem da `notifications-function`, e o scrape do `payments-api` está rotulado como
  **404, target down**. O diagrama pronto que a issue sugeria trazia essas quatro setas como se
  existissem. (#31)
- **5 ADRs em `docs/adr/`** — gateway Kong, observabilidade Opção A, serverless Functions+KEDA,
  NoSQL em avaliações e cache com invalidação por geração. Formato curto: contexto, decisão,
  consequências e alternativas descartadas. (#31)
- **`docs/relatorio-entrega-fase3.md`** e **`docs/roteiro-video.md`**. O roteiro traz uma seção
  explícita **"O que NÃO prometer na narração"**, com as três afirmações que falhariam ao vivo. (#31)

### Corrigido
- **O README afirmava, na `main`, algo que a medição desmente: que o Jaeger "mostra o trace
  distribuído" e que o trace da compra "atravessa `catalog-api → RabbitMQ → payments-api → RabbitMQ
  → catalog-api` sem código adicional".** Medido no cluster: `GET /api/services` do Jaeger devolve
  apenas `catalog-api` e `users-api`, e dos 10 traces mais recentes de cada um, **0 de 10** contêm
  mais de um serviço — a cadeia se parte no `payments-api`, que não tem pacote OpenTelemetry algum
  embora o manifesto defina `OTEL_SERVICE_NAME` e `OTEL_EXPORTER_OTLP_ENDPOINT` para ele. O texto
  agora descreve a cobertura como **parcial (2 de 4 serviços)**, com a evidência. Rastreado em
  [payments-api#20](https://github.com/fcg-grupo-16/payments-api/issues/20) e
  [notifications-function#14](https://github.com/fcg-grupo-16/notifications-function/issues/14) —
  esta última **aberta nesta entrega**, porque o `TODO(#6)` no código da Function apontava para uma
  issue **fechada** e a lacuna não estava sendo rastreada por ninguém. (#31)
- **A tabela de portas estava quebrada em renderização**: um blockquote fora inserido **no meio**
  dela, o que em Markdown encerra a tabela — as sete linhas seguintes (payments, RabbitMQ, MongoDB,
  Redis, Grafana, Prometheus, Jaeger) apareciam como texto solto com pipes na primeira página que o
  avaliador abre. Reescrita como tabela contígua, com coluna de **port-forward do Kubernetes** além
  da porta do compose. (#31)
- **O diagrama "Fluxos orientados a eventos" ainda era o da Fase 2**: mostrava `NotificationsAPI`
  como consumidor nos dois fluxos — serviço removido na #29 —, contradizendo o diagrama novo três
  parágrafos acima. (#31)
- O README dizia que o compose sobe "os 4 microsserviços" (são 3: a Function exige KEDA e não está
  no compose) e anunciava ".NET 10" para tudo (a `notifications-function` é **.NET 8**). (#31)
- **Duas contradições que a própria #30 havia criado**: a seção "Versionamento e release de imagens"
  ainda afirmava que "para o desenvolvimento local continuamos usando a tag `:local`", e a "Forma
  manual" ensinava `minikube image load` sem avisar do **no-op silencioso**. (#31)

### Notas
- **O critério "`grep -rn "fcg.local"` só deve achar `api.fcg.local`" foi cumprido no espírito, não
  na letra.** Restam 5 ocorrências de `users.fcg.local`/`catalog.fcg.local`, e nenhuma é
  configuração viva: duas são entradas de CHANGELOG que **descrevem a remoção** daqueles hosts, duas
  estão no ADR 0001 explicando o contexto da Fase 2, e uma é o comentário do deploy que justifica
  por que o Ingress legado precisa ser apagado explicitamente. Apagá-las destruiria o histórico e a
  justificativa, que é o oposto do que o critério quer.
- **`CLAUDE.md` foi atualizado para a Fase 3 mas NÃO é versionado** — é gitignorado globalmente, e a
  regra do repositório proíbe dar stage nele. O critério de aceite correspondente não pode ser
  satisfeito por commit.
- **O PDF do relatório não é versionado e não foi gerado aqui**: nenhum engine LaTeX existe nesta
  máquina (`pandoc -o .pdf` falha com `'pdflatex' not found`) e o `weasyprint` falha por falta de
  `libgobject`. O caminho testado e funcional está documentado no próprio relatório: exportar HTML
  com `pandoc --embed-resources` e imprimir para PDF. O enunciado aceita **PDF ou TXT**.

## [0.16.0] - 2026-09-13

### Adicionado
- **`scripts/verify-fase3.sh`**: checklist automatizado da entrega, consultando o cluster. Confere o
  requisito, não o objeto — a diferença importa: três requisitos da Fase 3 tinham manifesto aplicado
  e pod `Running` e mesmo assim estavam **invisíveis** no cluster porque o nó servia uma imagem
  obsoleta. Por isso o script mede **saúde dos targets do Prometheus** (e não "o Deployment existe"),
  os **índices** de `catalogdb.avaliacoes` (e não "a coleção existe") e compara o `imageID` do pod com
  o `Id` do host. (#30)
- **`.github/scripts/validar-definitions-rabbitmq.py`**: valida a topologia declarativa do broker no
  CI — JSON, dead-lettering, bindings órfãos, filas inalcançáveis e usuários. ⚠️ A checagem olha a
  **policy**, não `x-dead-letter-exchange` nos `arguments` da fila: os argumentos participam da
  equivalência do `queue.declare` e o MassTransit declara estas filas **sem** argumento nenhum, então
  uma checagem por `arguments` **reprovaria as duas filas corretas**. Medido. O validador é
  mutation-testado: reprova as 7 mutações (policy removida, DLX inexistente, policy casando a própria
  DLQ, binding do DLX ausente, fila sem binding, binding órfão, lista de usuários vazia) e o JSON
  quebrado, e passa no arquivo real. (#30)
- **`.yamllint` versionado** e o step de lint agora **bloqueante**. Antes rodava `-d relaxed` com
  `continue-on-error`: acusava **441** achados e saía **0** — não era gate, era ruído. A config
  desliga `line-length` (os comentários longos dos manifestos são deliberados e eram a origem dos 441)
  e promove o resto a erro. Nesta base o resultado é limpo. (#30)
- **shellcheck no CI.** O `bash -n` só faz **parse**: nesta mesma base um `if [ x ] != [ y ]` passou
  pelo `bash -n` e só o shellcheck pegou. (#30)
- **`helm template` dos values do Kong no CI**, contra `gateway/kong-values.yaml` — o caminho real; o
  arquivo fica fora de `k8s/` de propósito, por não ser manifesto. (#30)

### Modificado
- **Imagens marcadas pelo COMMIT do repositório de origem**, não mais pela tag móvel `:local` (#40).
  Com tag móvel, `minikube image load` vira **no-op silencioso** quando a tag já existe no nó e um
  container a referencia — `minikube image rm` recusa sem `--force`, o `load` não reclama, o pod segue
  `Running` servindo o binário antigo e todo `kubectl get` diz que está tudo certo. Medido: com tag
  **nova** o load sempre funciona (id no nó idêntico ao do host), porque não há o que colidir. É
  conserto estrutural, não remediação: mudar de commit muda o `image:` do spec e o rollout acontece
  naturalmente, sem `rollout restart` — que, também medido, **não resolve nada** quando o spec não
  muda. O `fcg-rabbitmq` entrou no mesmo esquema, e não é detalhe: a topologia das filas vem do
  `definitions.json` assado na imagem, então um no-op ali serviria uma topologia velha, e fila
  faltando significa evento descartado em silêncio. (#30)
  Os arquivos de `k8s/` continuam com `:local` — YAML puro, validável offline pelo CI; a substituição
  acontece numa **cópia renderizada**, com guarda que aborta se alguma substituição não pegar.
  A tag do broker é escopada ao **contexto de build** (`docker/rabbitmq`), não ao repositório
  inteiro: escopada no repo, qualquer alteração aqui — um comentário num script — gerava tag nova e
  **recriava o pod do RabbitMQ**, churn de conexões e filas por mudança em arquivo nenhum do
  contexto dele. Medido: o pod do broker foi recriado num deploy cujas únicas alterações estavam em
  `scripts/` e no CI. Para os serviços não há escopo — o contexto de build é o repositório inteiro.
- O deploy remove também a **imagem** legada `notifications-api:local` do nó; até aqui só os objetos
  do Kubernetes eram limpos e a imagem seguia ocupando espaço. (#30)
- **`scripts/smoke-test.sh` reescrito**: 9 casos em dois modos. `MODO=compose` roda as asserções
  **dentro de um container** na rede do compose (as portas do host são remapeadas por máquina no
  override gitignored); `MODO=gateway` roda **no host**, contra o port-forward do Kong. Cobre os
  requisitos da fase: 401 na borda sem token, cadastro, login, catálogo com token, compra assíncrona
  até sair de `Pending`, avaliação em documento flexível com `mediaNota`, chave no Redis e
  `http_server_request_duration_seconds` no `/metrics`. (#30)
- **As 4 atribuições fail-open do `smoke-test.sh` foram eliminadas.** Elas viviam dentro de um
  heredoc citado, **invisíveis ao shellcheck**, e o `sh` do Alpine não tem `pipefail`: em
  `TOKEN=$(curl … | jq …)` o status é o do **jq**, então um curl morto virava `TOKEN="null"` e o teste
  seguia reportando sucesso. O padrão novo captura corpo e código sem pipe e **asserta o código**
  antes de extrair. (#30)
- **`scripts/deploy-minikube.sh`**: espera o `ScaledObject` com
  `kubectl wait --for=condition=Ready` em vez de `rollout status` na Function — que esperaria para
  sempre por um pod que **corretamente** não existe com a fila vazia. A condição é **necessária e não
  suficiente**, e está anotada como tal: um `queueName` inexistente também dá `Ready=True` até o
  primeiro poll. Mensagem final passou a apontar o serverless e o `verify-fase3.sh`. (#30)
- **`kubeconform` no CI aponta para o catálogo de CRDs da comunidade**: os 13 recursos antes pulados
  passam a ser validados. ⚠️ O ganho **não** é uniforme, e o README registra a medição: fecha o caso do
  KEDA (campo inventado no `spec` do `ScaledObject` agora reprova) e **não** fecha o do Kong — o schema
  do `KongPlugin` não trava `additionalProperties` no topo e trata `config` como objeto livre, então
  um typo em `claims_to_verify` **continua passando**. A validação do gateway segue comportamental. (#30)

### Corrigido
- **A limpeza de resíduo do `smoke-test.sh` não limpava a avaliação.** `_id` é um `ObjectId`, e
  `deleteOne({_id:'<hex>'})` não casa nada e sai **0** — a limpeza parecia funcionar e vazava uma
  avaliação por execução (medido: a coleção foi de 2 para 3 numa execução "limpa"). Corrigido com
  `ObjectId(...)` e verificado: `usuarios` e `avaliacoes` têm a mesma contagem antes e depois. (#30)
- **O relatório do `smoke-test.sh` tinha dois furos no CAMINHO DE FALHA, com modos opostos — a
  sétima e a oitava instância da classe `set -e`/`pipefail` desta entrega, ambas em código novo.**
  Se o corpo morresse antes de imprimir qualquer caso, `$SAIDA` ficava só com as linhas de placar:
  o `grep -v` não casava nada, saía 1, o `pipefail` propagava e o `set -e` **matava o script** sem
  relatório. E sem a linha `FALHAS=`, a aritmética `$(( FALHAS + ))` **não** matava nada — o bash
  imprime "arithmetic syntax error", segue em frente e deixa `FALHAS=0`, de modo que uma execução
  que **falhou** sairia com **exit 0 e "TODOS OS CASOS PASSARAM"**. Este é o pior dos dois: um
  teste que reporta sucesso quando quebrou não é um teste. Medidos em isolamento antes e depois do
  conserto. (#30)
- **Falha de conexão no `smoke-test.sh` reprovava sem dizer por quê.** Sob `set -e`, um curl que não
  conecta matava o script antes de registrar qualquer coisa, e o relatório saía só com o sentinela de
  "não consegui ler o placar". Agora vira código `000` com o erro do curl no corpo. (#30)
- **A poda de tags antigas no nó era um no-op silencioso — por DOIS bugs em sequência, e o
  conserto do primeiro revelou o segundo.** (#30)
  1. **`minikube ssh` lê o stdin.** Dentro de um `while read` alimentado por arquivo, ele consome o
     resto da entrada: o laço roda **uma** vez e as demais linhas somem, sem erro e com exit 0.
     Medido em isolamento: laço de 3 linhas com `minikube ssh` dentro executa **1** iteração; com
     `</dev/null`, **3**. `minikube image load` **não** tem esse comportamento (também medido) —
     por isso o laço de carga sempre funcionou e só a poda falhava.
  2. Com o `</dev/null` posto, a iteração 2 passou a executar e expôs a **sexta instância do
     `set -e` + `pipefail`** desta entrega: quando um serviço não tem tag antiga (o caso comum, um
     deploy sem mudança naquele repo), o `grep -v` não casa nada e sai 1, o `pipefail` propaga e o
     `set -e` **mata o script** ali. Medido: com `set -euo pipefail` o laço morre na iteração 2 com
     exit 1; sem o `-e`, completa. O sintoma era mudo — a última linha era "Podando tags antigas no
     nó" e o `==> Pods:` seguinte nunca aparecia; o exit code ficava mascarado por um pipe no
     comando que invocava o script.
  Corrigido com `</dev/null` em todo `minikube ssh`, candidatas coletadas em variável com
  `|| true`, listagem do nó feita uma única vez, e a recusa do `docker rmi` **reportada** em vez de
  engolida.
  ⚠️ Três hipóteses foram refutadas por medição antes de chegar a estas duas: códigos ANSI na saída
  (os bytes crus mostram só `\r\n`), posição do bloco no script (está no caminho executado) e
  referência de container bloqueando o `rmi` (`docker rmi` devolve `Untagged` e exit 0 mesmo com
  container **em execução** — o `must force` da #40 era outra operação, `minikube image rm` sobre a
  única referência da imagem).
- `k8s/24-notifications-function.yaml`: indentação do comentário final, o único achado do yamllint
  com a config nova. (#30)

## [0.15.0] - 2026-09-13

### Adicionado
- **KEDA 2.20.2 e scale-to-zero da `notifications-function`**, fechando o requisito de *Migração para
  Arquitetura Serverless*: o Deployment fica em **zero réplica** em repouso e o KEDA o acorda quando
  entra mensagem na fila, devolvendo-o a zero quando ela esvazia. Medido no cluster em **duas
  execuções**, e os números variam de propósito — não são especificação: o pod nasceu **6s** e **11s**
  depois do evento (limite superior é o `pollingInterval: 15`, somado à partida emulada da imagem
  amd64), `Executed 'Functions.UserCreatedFunction' (Succeeded, Duration=3080ms)`, fila drenada, e
  voltou a 0 réplica **63s** e **71s** depois do disparo (`cooldownPeriod: 60`). (#29)
- `k8s/50-keda-notifications.yaml`: `TriggerAuthentication` + `ScaledObject` com **dois** triggers
  (uma fila cada; o KEDA escala pelo maior). (#29)
- `k8s/24-notifications-function.yaml`: Deployment e ConfigMap da Function, **cópia** de
  `deploy/k8s/` do repo `notifications-function` — o `kubectl apply -R -f k8s/` daqui nunca aplica o
  diretório do outro repo, então sem a cópia o `ScaledObject` apontaria para um alvo inexistente.
  Deployment **sem `replicas`** de propósito: quem controla a contagem é o KEDA. (#29)
- **`scripts/keda-test.sh`**: matriz de aceite do ciclo 0→1→0 contra o cluster. Existe pela mesma
  razão do `gateway-test.sh`: o `kubeconform` do CI **pula** os CRs do KEDA (sem schema publicado),
  e o engano de `Ready` é **temporal**, medido com `ScaledObject`s efêmeros em Deployments dedicados:
  credencial → secret inexistente dá `Ready=False` (`ScaledObjectCheckFailed`) **estável** e sem HPA,
  caso que a asserção 1 **pega**; já credencial boa com `queueName` inexistente dá **`Ready=True`** com
  HPA criado em t+6s e t+12s, caindo para `Ready=False` (`TriggerError`) em t+18s. Ou seja, ler `Ready`
  **antes do primeiro poll do trigger** aprova um scaler que não alcança a fila. Nos dois casos o
  Deployment fica em 0 réplica, indistinguível de scale-to-zero saudável, e a asserção decisiva é a de
  **execução** (`Executed ... Succeeded`). São 12 asserções, e o script limpa o que cria nas três
  coleções que toca. (#29)
- **As asserções do `keda-test.sh` são mutation-testadas, e a mutação precisa quebrar os DOIS
  triggers.** Trocando o `queueName` de **ambos** por filas inexistentes, o teste **reprova**:
  asserções 1, 8, 9 e 10 falham e o exit é 1. A 8 é a decisiva — ela dizia `sim` contando o pod
  moribundo do ciclo anterior, e agora diz `nao`. Restaurado, volta a 12/12. Um teste que só passa
  não prova nada; este também reprova quando deve.
  ⚠️ **Quebrar só o primeiro trigger NÃO é um controle confiável**, e isso foi medido: duas execuções
  da mesma mutação de um trigger deram resultados diferentes — uma com 1, 8, 9 e 10 reprovando, outra
  com apenas a 1, e o pod acordando em 46s. Com o segundo trigger intacto o KEDA ainda tem um scaler
  saudável, então a escala pode acontecer assim mesmo. Só a mutação dos dois é determinística. (#29)
- Credencial selada `keda-rabbitmq-secret` para o scaler, com **FQDN**. (#29)

### Modificado
- `scripts/deploy-minikube.sh`: instala o KEDA por **URL pinada** antes do `kubectl apply` (o
  `ScaledObject` depende dos CRDs), builda a Function com **`--platform linux/amd64`** num laço
  `FUNCTIONS` separado do de `SERVICES`, e **remove o `notifications-api` legado**. Esta última parte
  era um defeito: apagar `k8s/23-notifications-api.yaml` do git não remove nada de um cluster que já
  rodou a `main` — o Deployment legado voltaria de pé (a imagem segue carregada no minikube, o Secret
  resolve o `envFrom`) e ele e a Function virariam *competing consumers* das mesmas filas, tornando o
  teste de aceite não-determinístico. Mesma razão da limpeza do `fcg-ingress`, que o comentário três
  linhas acima já enunciava. (#29)
- `.github/workflows/ci.yml`: a lacuna conhecida do `kubeconform` passou a citar também os CRs do
  KEDA (`ScaledObject`/`TriggerAuthentication`), não só os do Kong. (#29)
- `docker/rabbitmq/README.md`: a prosa escrita antevendo esta remoção foi para o passado. A decisão
  de dead-letter **por policy** e o exchange intermediário seguem valendo — só mudou o sujeito: quem
  sofreria com divergência de equivalência agora são os **publishers** (`users-api`, `payments-api`
  via MassTransit), não o serviço removido. (#29)

### Removido
- **`notifications-api`** da plataforma: manifesto `k8s/23-notifications-api.yaml`, serviço do
  `docker-compose.yml`, target do Prometheus do compose, `SERVICES` do deploy, secret selado e dica
  de logs do smoke test. O repositório continua existindo, marcado como **deprecado** no README. As
  entradas históricas do CHANGELOG **não** foram reescritas. (#29)

### Notas de implementação
- **A imagem da Function exige `--platform linux/amd64`.** A base oficial
  `azure-functions/dotnet-isolated` publica **só** `linux/amd64` — conferido em `4-dotnet-isolated8.0`,
  `9.0`, `10.0`, `-appservice` e `-mariner`; não existe variante arm64 em tag nenhuma. Sem
  `--platform` o build falha com `no match for platform in manifest`. A imagem amd64 **executa** no
  nó arm64 porque o minikube traz `binfmt` com handler `qemu-x86_64` habilitado (verificado: pod de
  teste imprimiu `x86_64` e saiu com 0). Custo: partida emulada, mais lenta que os demais serviços —
  que são todos arm64 nativos (`dotnet/sdk:10.0` é multi-arch).
- **A credencial do scaler precisa de FQDN, e não é a mesma entrada dos serviços.** Reaproveitar
  `notifications-function-secret.RabbitMqConnection` falhou: o pod do **operador** do KEDA roda no
  namespace `keda`, onde o nome curto não resolve — `dial tcp: lookup rabbitmq on 10.96.0.10:53: no
  such host`. Confirmado por DNS: de `fcg` o nome curto resolve; de `keda` é `NXDOMAIN` e só o FQDN
  responde. Os dois segredos carregam o **mesmo** usuário e senha, e diferem apenas no host.
- **Trocar só o `TriggerAuthentication` não reconstrói o scaler.** O `kubectl apply` responde
  `scaledobject ... unchanged` e o operador segue com o scaler em cache, repetindo o erro antigo (5
  erros citando o host velho nos 90s seguintes à correção do secret). É preciso recriar o
  `ScaledObject`.
- **O HPA criado pelo KEDA aparece com `minReplicas: 1`, e está correto.** O HPA do Kubernetes não
  escala a zero; a transição 0↔1 é do operador do KEDA, por fora dele. Em repouso, `ScalingActive=False`
  com *"scaling is disabled since the replica count of the target is zero"* é o estado normal.
- **Com `AzureWebJobsStorage` vazio o host do Functions reporta `Unhealthy` para sempre**, e não é
  falha: medido, `azure.functions.webjobs.storage` é a **única** sub-checagem não saudável
  (`web_host.lifecycle` e `script_host.lifecycle` = `Healthy`), e a função executa normalmente.
  Configurar um Storage Account só para silenciar o log seria pagar uma dependência por um sintoma.
- **No compose, as filas de notificação ficaram sem consumidor.** A `notifications-function` não
  está no `docker-compose.yml` (scale-to-zero exige KEDA, que só existe no minikube), então desde
  esta remoção `notifications-user-created` e `notifications-payment-processed` **acumulam** mensagens
  no caminho do compose — as filas existem, pois o `definitions.json` está assado na imagem do broker.
  Nada quebra, mas não há e-mail simulado para ver localmente: o fluxo de notificação só é observável
  no cluster. Registrado no cabeçalho do `smoke-test.sh` e no README.
- **O endpoint HTTP de histórico ficou inalcançável.** A Function tem **três** funções — duas com
  `RabbitMQTrigger` e a `NotificationHistoryFunction` com **HTTP** (confirmado no `functions.metadata`
  da imagem). O `notifications-api` servia `GET /api/v1/notificacoes` atrás de um Service; o
  `k8s/24-notifications-function.yaml` não declara `containerPort` nem Service, e o scale-to-zero
  mantém 0 réplica. Não corrigido aqui: expor exigiria Service + pod quente (anulando o
  scale-to-zero) ou ativação por HTTP, além de tratar a `x-functions-key`.
- **Duas afirmações minhas sobre o próprio teste eram falsas, e a origem do erro importa.** (a) Eu
  descrevi o modo de falha do scaler com as duas causas **invertidas** — transcrevi a medição de uma
  revisão adversarial **sem reproduzi-la**, e a reprodução própria mostrou o contrário (ver a nota
  acima). (b) Eu declarei que o `keda-test.sh` passava 12/12 "na condição que o quebrou"; não passava:
  o meu re-run tinha um `sleep 75` no meio (para a leitura atrasada do Mongo) e o
  `terminationGracePeriodSeconds` é **30s**, então o estado já estava genuinamente ocioso e a condição
  tight nunca foi exercida. O defeito que isso escondia era real: `pods_vivos()` filtrava
  `Terminating`, de modo que um pod ainda vivo — com consumer AMQP atado, drenando a mensagem —
  contava como zero, e a asserção 8 reportava "o KEDA acordou a Function" olhando o pod do ciclo
  anterior. Corrigido com `pods_totais()` na espera de ocioso e exigindo pod de **nome diferente** na
  asserção 8.
- **Correções de afirmações desta própria entrega**, encontradas em revisão adversarial e registradas
  por honestidade: (a) "resíduo zero no Mongo" era **falso** — media só `usersdb`, enquanto a Function
  persiste toda notificação em `notificationsdb.notifications`; 14 documentos de teste haviam
  acumulado (12 do `gateway-test.sh`, 2 do `keda-test.sh`) e os dois scripts passaram a limpá-la;
  (b) "7 → 6 SealedSecrets" estava errado — `origin/main` já tinha **6** e HEAD tem **6** (o número 7
  foi um estado transitório da sessão, não do diff); (c) "diff do CHANGELOG +67 −0" estava errado —
  o commit `5858a22` traz **+71 −0** (o total da PR é alvo móvel: muda a cada commit, então citar
  o número da PR numa entrada versionada seria errar de novo); (d) "7 entradas no
  `definitions.json`" estava errado — o arquivo declara **3 filas**, mais 5 exchanges, 5 bindings
  e 1 policy.
- **Ordem da remoção importou.** O `notifications-api` só saiu depois de a Function ter
  comprovadamente consumido um evento real. Com os dois de pé eles são *competing consumers* da mesma
  fila e cada e-mail sai por um dos dois de forma imprevisível — durante a validação isto apareceu de
  fato (`consumers 2` por fila), e a medição só ficou limpa depois de zerar o `notifications-api`.

## [0.14.0] - 2026-09-13

### Adicionado
- **API Gateway (Kong Ingress Controller) como porta de entrada única**, em modo DB-less: host
  único `api.fcg.local`, **validação de JWT na borda** (401 sem token, antes de a requisição sair
  do namespace `kong`), rate limit e correlation-id. Configuração 100% versionada:
  `gateway/kong-values.yaml` (values do chart, pinado em 3.4.1) e `k8s/gateway/` com
  `KongConsumer` + credencial, os plugins e as três rotas. (#26)
- **`scripts/gateway-test.sh`**: executa a matriz de aceite do gateway contra o cluster, incluindo
  o teste de **dois pods** (IPs de origem distintos), que é o único capaz de distinguir isolamento
  por IP de contador global — dois tokens da mesma origem não distinguem. (#26)
- `ForwardedHeaders__*` no ConfigMap de `k8s/20-users-api.yaml`. O `users-api#21` as adicionou no
  ConfigMap do próprio repo, que **não** é aplicado pelo `deploy-minikube.sh` — sem esta cópia a
  feature nascia inerte no cluster e o rate limiter de login viraria bucket global. (#26)

### Modificado
- **O plugin `jwt` passou a aceitar token SÓ pelo header `Authorization`** (`uri_param_names: []`,
  `cookie_names: []`) e a exigir JWT **também no preflight** (`run_on_preflight: true`). Ver as notas
  de implementação: a versão anterior desta entrega aceitava `?jwt=<token>` e deixava `OPTIONS`
  anônimo atravessar. (#26)
- `scripts/undeploy-minikube.sh`: o guard dos CRDs passou a filtrar por **chart** (`kong-*`) em vez
  de por nome de release (`helm list -f` casa com o nome, então um `kong-dev` escapava), a enumerar
  os kinds de `configuration.konghq.com` **a partir do cluster** em vez de uma lista fixa (e o
  delete dos CRDs passou a derivar da mesma enumeração), a contar releases em **qualquer** namespace
  — excluir o namespace `kong` deixava escapar justamente um `kong-dev` instalado nele —, e a
  **falhar fechado** nas duas sondas: a de releases Helm e a de CRs — esta última descartava o
  status do `kubectl` (em pipeline o exit é o do `wc`), então um `get` falhando era lido como
  "nenhum CR fora de `fcg`". O `helm
  uninstall` deixou de ser silenciado com `|| true`. (#26)
- **`GET /api/v1/jogos` passa a exigir token quando acessado pelo gateway**, embora siga
  `[AllowAnonymous]` no serviço. Evita rota ambígua por método no mesmo path e torna a
  demonstração inequívoca. Acesso interno (pod-a-pod, Prometheus, testes) não muda. (#26)
- `scripts/deploy-minikube.sh`: instala o Kong por Helm **antes** do `kubectl apply` (os CRDs são
  pré-requisito dos manifestos de `k8s/gateway/`), remove o `fcg-ingress` legado e passou a exigir
  `helm`, com guard de pré-requisito. (#26)
- `scripts/undeploy-minikube.sh`: passou a desinstalar o gateway (release, namespace e CRDs), na
  ordem correta — os CRDs saem depois dos `KongPlugin`/`KongConsumer`. (#26)

### Removido
- **`k8s/30-ingress.yaml` (Ingress NGINX)** e os hosts `users.fcg.local` / `catalog.fcg.local`,
  substituídos pelo gateway. O `deploy-minikube.sh` apaga o objeto remanescente em clusters que já
  rodaram a versão anterior — `kubectl apply` não remove manifesto que saiu do diretório. (#26)

### Notas de implementação
- **Declarar `header_names` no plugin `jwt` não fecha a querystring nem o cookie.** Os três campos
  são independentes e `uri_param_names` vem com default `["jwt"]`: a primeira versão desta entrega
  autenticava por `?jwt=<token>` — medido, `?jwt=<válido>` devolvia 200 e `?jwt=<forjado>` devolvia
  401, provando que a assinatura era validada a partir da URL — e o token inteiro ia para o **access
  log do Kong em claro**, coletável por qualquer um que leia log de pod. Corrigido com as duas listas
  vazias (medido depois: `?jwt=<válido>` → 401, header → 200), e a matriz ganhou as asserções
  5b/5c/5d para a regressão não voltar a passar verde pelo caminho do header. **O vazamento no log
  não foi eliminado**, só tornado inútil como via de autenticação: um cliente que ainda ponha o token
  na URL continua fazendo o Kong registrá-lo no access log, e esse token segue válido pelo header.
  Eliminá-lo exigiria formato de log sem `$request_uri` — decisão de observabilidade, fora do escopo.
- **`run_on_preflight: false` só faz sentido junto com um plugin `cors`.** Sem cors a exceção não
  habilitava nada e deixava `OPTIONS` anônimo chegar ao serviço (medido: 405 com `Server: Kestrel` e
  a requisição registrada no log do `catalog-api`), contradizendo a promessa de que sem token a
  requisição não sai do namespace `kong`.
- **`scripts/gateway-test.sh` limpa o resíduo que ele mesmo cria.** São duas coisas distintas, e a
  primeira versão desta limpeza descreveu errado o que acumulava: o teste de cadastro grava uma
  **conta** real (cinco já haviam acumulado no `usersdb`), mas **não** cria `refresh_token` — medido,
  o delta de `refresh_tokens` num cadastro é zero. Quem cria `refresh_token` são os **logins do
  próprio teste**, e era esse o resíduo que de fato crescia. A limpeza remove a conta criada e os
  tokens do `admin` gerados **depois do início da execução**, nunca tokens anteriores.
- **A credencial JWT precisa do label `konghq.com/credential`.** O campo `kongCredType` sozinho é a
  convenção antiga, e o webhook de admissão do KIC 3.x recusa o `KongConsumer`. O modo de falha
  engana: plugins e Ingress entram, o gateway devolve 401 sem token (parece funcionar) e devolve
  401 **também com token válido**, por não haver credencial para casar com a claim `iss`.
- **`limit_by: consumer` NÃO limita por usuário nesta topologia.** Todo token emitido pelo
  `users-api` tem `iss: FiapCloudGames`, e o plugin `jwt` resolve o consumer por essa claim — logo
  todos os usuários casam com o único `KongConsumer` e o contador é **global por construção**.
  O rate limit passou a usar `limit_by: ip`, que é o menos errado dos declaráveis — mas
  **o bucket continua global para todo cliente externo, e isso é limitação conhecida, não corrigida**:
  via `port-forward` (único caminho documentado) o Kong registra `127.0.0.1` para todas as
  requisições, e via NodePort o `externalTrafficPolicy: Cluster` faz SNAT para o IP do nó. O
  contador também é compartilhado entre as 5 rotas protegidas (medido: 116→115→114→113→112). São
  120/min para a plataforma inteira vista de fora. O `ForwardedHeaders__*` dos serviços não muda
  isso — ele governa o `RemoteIpAddress` lido do `X-Forwarded-For` que o Kong escreve, e esse valor
  é `127.0.0.1` para todos, então o rate limiter de login do `users-api` também é global.
- **Requisição não autenticada não consome cota nas rotas protegidas.** O plugin `jwt` (prioridade
  1005) roda antes do `rate-limiting` (901) e encerra a requisição: o 401 sai sem headers
  `RateLimit-*`. Flood anônimo com token inválido não é limitado na borda; prioridade de plugin no
  Kong é fixa por tipo. O caminho anônimo é coberto pelo limite das rotas públicas.
- **A Admin API do Kong fica desabilitada (default do chart).** Habilitá-la, mesmo como
  `ClusterIP`, expõe `GET /consumers/.../jwt` — que devolve a chave HS256 **em claro** — a qualquer
  pod do cluster; com ela se forja um token de admin, e a chave é a mesma nos três validadores.
  DB-less também não é read-only: `POST /config` substitui a configuração inteira.
- **Rotas públicas têm limite mais restritivo (20/min) que as protegidas (120/min).** O cadastro é o
  único caminho de escrita anônimo da plataforma e não tem `[EnableRateLimiting]` no serviço —
  sem limite na borda, seria criação ilimitada de contas com um `UserCreatedEvent` por requisição.
- **`gateway/kong-values.yaml` fica fora de `k8s/`** porque `kubectl apply -R -f k8s/` aplicaria o
  arquivo, e um values de Helm não tem `apiVersion`/`kind` — o apply falharia inteiro. Mesma razão
  que levou `observability/fcg-overview.json` a viver fora de `k8s/` na 0.13.0.
- **`kubeconform` não valida os CRDs do Kong** (schema desconhecido): `KongPlugin` e
  `KongConsumer` são pulados, então erro de campo passa verde no CI. A validação real é o
  `gateway-test.sh` contra um cluster.

## [0.13.0] - 2026-09-09

### Adicionado
- **Stack de observabilidade — Opção A do desafio (Prometheus + Grafana)**, implantada 100% via
  manifestos Kubernetes, como o enunciado exige para esta opção: `k8s/40-observability-prometheus.yaml`
  (com RBAC de leitura para a service discovery), `k8s/41-observability-grafana.yaml` e
  `k8s/42-observability-jaeger.yaml`. Equivalentes no `docker-compose.yml` para desenvolvimento. (#27)
- **Dashboard `FCG — Visão Geral` versionado** em `observability/fcg-overview.json`, com os
  quatro painéis exigidos pela fase — latência (p50/p95/p99), throughput, requisições por status
  code HTTP e taxa de erro — mais top-5 de rotas lentas e variável de filtro por serviço. O
  ConfigMap `k8s/41b-grafana-dashboard.yaml` é **derivado** do JSON, regenerado por
  `scripts/gen-dashboard-configmap.sh`. (#27)
- **Jaeger** para traces distribuídos, cobrindo o terceiro pilar da observabilidade que o desafio só
  exige na Opção B. O MassTransit 8 propaga contexto W3C nativamente, então o trace da compra
  atravessa catalog → RabbitMQ → payments → RabbitMQ → catalog sem código adicional. (#27)
- **Contrato de coleta:** annotations `prometheus.io/scrape|port|path` nos Deployments de
  `users-api`, `catalog-api` e `payments-api`, e `OTEL_SERVICE_NAME` / `OTEL_EXPORTER_OTLP_ENDPOINT`
  / `OTEL_EXPORTER_OTLP_PROTOCOL` nos ConfigMaps dos três. (#27)
- Seção **"Observabilidade — escolhemos a Opção A"** no README, com a justificativa da escolha
  (exigência explícita do enunciado), as queries PromQL de cada painel e o procedimento de
  verificação. (#27)

### Notas de implementação
- **Descoberta por annotation de pod, não por lista fixa de targets.** Um serviço novo que suba com
  a annotation é raspado sem editar a config do Prometheus — evita que o `scrape_config` vire uma
  segunda fonte da verdade sobre quais serviços existem. No compose, que não tem API de pods, os
  targets são estáticos; o label `service` é o mesmo nos dois, e é o que faz o **mesmo dashboard**
  servir aos dois ambientes.
- **As quatro métricas exigidas vêm todas do histograma `http_server_request_duration_seconds`**,
  que o ASP.NET Core instrumenta por conta própria e o SDK OpenTelemetry exporta no formato
  Prometheus: um histograma entrega latência (via `histogram_quantile`), contagem (série `_count`)
  e recorte por status code (label) de uma vez. Nenhuma métrica customizada foi necessária.
- **A taxa de erro precisa de `or vector(0)` no numerador.** Sem nenhum 5xx a série filtrada não
  existe no TSDB, e vetor vazio dividido por qualquer coisa continua vazio — o painel mostraria
  `No data` justamente no estado saudável, visualmente idêntico a "a stack quebrou". O `clamp_min`
  no denominador resolve um caso diferente (o `NaN` de 0/0 quando o tráfego cessa); os dois são
  necessários.
- **RBAC do Prometheus é `Role` namespaced, não `ClusterRole`.** A única service discovery é
  `role: pod` restrita ao namespace `fcg`; conceder nodes/services/endpoints cluster-wide seria
  permissão morta.
- **`MEMORY_MAX_TRACES` do Jaeger em 5000, não 20000.** ~62 KiB por trace de 12 spans (medido):
  20000 custariam ~1,25 GB contra um limite de 768Mi — o container seria OOMKilled por volta de
  11,5k traces, ou seja o teto que existe para evitar o OOM ficaria acima do ponto de OOM.
- **Alterar o dashboard não exige reiniciar o Grafana:** o provider relê o diretório a cada 10s e o
  ConfigMap montado propaga (~20s, zero restarts — medido). Datasources, sim, só são lidos no boot.
- **`notifications-api` também instrumentado.** É worker (métricas HTTP quase vazias), mas consome
  `PaymentProcessedEvent` — sem ele o trace da compra apareceria com um ramo cortado no Jaeger.
- **Prometheus, Grafana e Jaeger sem PVC e com `strategy: Recreate`**, mesmo raciocínio do Redis:
  retenção curta, dados descartáveis, e duas instâncias simultâneas atrás do mesmo Service
  produziriam séries/traces partidos durante o rollout.
- **Portas do compose publicadas apenas em `127.0.0.1`.** Prometheus e Jaeger não têm autenticação
  nenhuma e expõem a telemetria inteira da plataforma; o Grafana usa admin/admin. No cluster os três
  são `ClusterIP` sem rota no Ingress.
- **Os painéis ficam vazios até `users-api#19`, `catalog-api#19` e `payments-api#19`.** Este
  repositório entrega a stack e o contrato de coleta; o endpoint `/metrics` nasce nos serviços. Até
  lá os targets aparecem `DOWN` com `404` — que é o comportamento correto e a prova de que a
  descoberta e a rede estão certas.

## [0.12.0] - 2026-09-09

### Adicionado
- **Redis como camada de cache distribuído da plataforma** (`k8s/12-infra-redis.yaml` + serviço
  `redis` no compose). Requisito obrigatório da Fase 3. Este repositório entrega a **infraestrutura
  e o contrato de configuração**; o consumo pelo código vem depois, em `users-api#20` e
  `catalog-api#21` (cache de consultas onerosas) e `notifications-function#3` (store de
  idempotência). (#25)
- **Contrato de configuração do cache:** `Redis__InstanceName` nos ConfigMaps de `users-api`
  (`fcg:users:`) e `catalog-api` (`fcg:catalog:`); `Redis__ConnectionString` nos SealedSecrets dos
  dois serviços. (#25)
- **initContainer `wait-for-redis`** nos Deployments de `users-api` e `catalog-api`, no mesmo padrão
  dos que já esperam Mongo e RabbitMQ. (#25)
- Seção **"Cache distribuído (Redis)"** no README, incluindo como remapear a porta quando o host já
  tem um Redis na 6379. (#25)

### Notas de implementação
- **`Deployment` sem `PersistentVolumeClaim`, ao contrário do MongoDB.** É cache: todo dado é
  reconstruível a partir do Mongo, então perder o conteúdo na recriação do Pod é aceitável e evita
  carregar um PVC que não agregaria nada. Coerente com o compose (`--save ""`, `--appendonly no`).
- **`--maxmemory 256mb` com `--maxmemory-policy allkeys-lru`**, e `limits.memory` do container
  **acima** desse teto (512Mi, 2× — alinhado com Mongo e RabbitMQ): se fossem iguais, o kernel
  mataria o container (OOMKilled) antes de o Redis aplicar a evicção, e o mecanismo de proteção
  nunca chegaria a rodar. `requests.memory` também em 256Mi (o consumo de regime, não o de idle),
  senão o pod ficaria em QoS Burstable e seria o primeiro candidato a despejo do namespace.
- **Isolamento entre serviços é lógico**, por prefixo de chave (`Redis__InstanceName`), e não por
  instâncias separadas. Mesma filosofia do database-per-service do Mongo, sem o custo de três Redis
  num ambiente de demonstração.
- `Service` do tipo **ClusterIP**, sem rota no Ingress: no Kubernetes o Redis não é acessível de
  fora do cluster. No **compose** a porta é publicada apenas em `127.0.0.1` — o Redis roda sem
  `requirepass` e com `protected-mode no`, então publicar em `0.0.0.0` daria `FLUSHALL` e leitura
  do cache a qualquer máquina na mesma rede.
- **Prefixo de chave é organização, não fronteira de segurança.** Sem autenticação e sem
  `NetworkPolicy`, qualquer pod do namespace lê e escreve o keyspace de qualquer serviço.
  Documentado no README como limitação consciente do ambiente de demonstração.
- `strategy: Recreate` no Deployment: com `RollingUpdate` e `replicas: 1`, o `maxSurge` faria o
  Service balancear entre dois Redis com estados diferentes durante um update — inofensivo para
  cache, mas perda de correção para o store de idempotência da Function.
- `timeoutSeconds`/`failureThreshold` explícitos nas probes, como já fazem os manifestos do Mongo e
  do RabbitMQ: o default de 1s numa exec probe (fork+exec a cada ciclo) gera restart espúrio sob
  throttling de CPU, e um restart aqui apaga o cache inteiro da plataforma.

## [0.11.0] - 2026-09-09

### Adicionado
- **Topologia declarativa das filas de notificação** (`docker/rabbitmq/definitions.json` +
  `load-definitions.conf`, carregados pela imagem custom do broker). Cria exchanges, as filas
  `notifications-user-created` / `notifications-payment-processed`, a dead-letter queue
  `notifications-dlq` e o usuário `guest` **no boot do broker**, sem depender de nenhum serviço .NET.
  Pré-requisito da `notifications-function` (Fase 3): o binding `RabbitMQTrigger` da Azure Functions
  apenas **consome** de uma fila existente — não declara fila, exchange nem binding. Sem isso a
  mensagem publicada cairia num exchange sem binding e seria **descartada em silêncio**. (#28)
- **SealedSecret `notifications-function-secret`** com `RabbitMqConnection` (URI AMQP completa,
  formato exigido pelo binding), `MongoDbSettings__ConnectionString` e `Redis__ConnectionString`. (#28)
- **`docker/rabbitmq/README.md`** documentando a topologia e as três decisões não óbvias do desenho. (#28)

### Notas de implementação
- **Dead-letter aplicado por _policy_, não por `x-dead-letter-exchange` nos `arguments` da fila.**
  Os argumentos participam da checagem de equivalência do `queue.declare`; o MassTransit declara
  estas filas sem argumento nenhum, então declará-las com o argumento faria o `notifications-api`
  morrer no startup com `PRECONDITION_FAILED - inequivalent arg 'x-dead-letter-exchange'` durante
  toda a janela de transição até a remoção do serviço (#29). Verificado empiricamente.
- **O `definitions.json` espelha exatamente a topologia do MassTransit** (capturada com
  `rabbitmqadmin export`), incluindo o exchange intermediário por endpoint. Simplificar para um
  binding direto criaria divergência de propriedades e o mesmo tipo de conflito.
- **O usuário `guest` precisa estar declarado no arquivo.** Com `load_definitions` configurado o
  broker registra `Will not seed default virtual host and user: have definitions to load` e deixa de
  criar o usuário padrão — uma lista `users` vazia derrubaria a autenticação de toda a plataforma.

## [0.10.1] - 2026-07-13

### Corrigido
- **Barreira de memória no health check do RabbitMQ** dos quatro serviços (`users-api`, `catalog-api`,
  `payments-api`, `notifications-api`). A leitura *fast-path* da conexão reutilizada acontecia **fora**
  do `SemaphoreSlim`; sem barreira, o JIT poderia cachear a referência em registrador (leitura *stale*
  entre probes concorrentes) — data race benigno e autocorrigível, mas fechado por rigor. Passou a
  usar `Volatile.Read`/`Volatile.Write` (pareando com o lock, semântica acquire/release), de forma
  **uniforme nos quatro serviços**. Comportamento observável inalterado. Imagens `:local` rebuildadas
  e redeployadas; validado no cluster (4 pods `Ready`, fluxos cadastro/compra OK, broker estável, sem leak).

## [0.10.0] - 2026-07-13

### Adicionado
- **MongoDB (`notificationsdb`) provisionado para o `notifications-api`** — o serviço deixa de ser
  "zero banco" e passa a **persistir o histórico das notificações enviadas** (auditoria/relatórios,
  `notifications-api#2`). Ganha `MongoDbSettings__DatabaseName=notificationsdb` (ConfigMap) e
  `MongoDbSettings__ConnectionString` com `?replicaSet=rs0` (SealedSecret cifrado), no compose e no
  k8s, além do initContainer `wait-for-mongodb` e do `depends_on: mongodb`. `database-per-service`
  preservado (reusa a instância `mongodb`, database lógico novo). Consultável em
  `GET /api/v1/notificacoes`.

### Modificado
- **Probes do `notifications-api` separados**: `livenessProbe → /health/live` e
  `readinessProbe → /health/ready` (antes ambos em `/health`), refletindo o readiness que agora
  cobre **RabbitMQ + MongoDB**. Entregue junto com a maturação do serviço (`notifications-api#6`).
- Imagem `:local` do `notifications-api` rebuildada e recarregada no cluster, incorporando o backlog
  do serviço entregue nesta rodada: idempotência dos consumers (`#1`), retry + dead-letter (`#4`),
  readiness com RabbitMQ sem leak de conexão (`#6`), provider de e-mail plugável `IEmailSender` (`#3`),
  testes de integração com MassTransit Test Harness (`#5`) e persistência do histórico (`#2`).

### Validação
- Pod `Ready` (health check de Mongo + RabbitMQ). Cadastro → registro persistido no `notificationsdb`
  e retornado por `GET /api/v1/notificacoes`. Fluxos cadastro/compra OK. Broker estável (sem leak).

## [0.9.0] - 2026-07-13

### Corrigido
- **Leak de conexões AMQP nos health checks de readiness** dos três serviços que publicam/consomem
  eventos (`users-api#16`, `catalog-api#16`, `payments-api#16`; o payments já tinha o leak corrigido
  em `#14`). O `AddRabbitMQ` do readiness abria uma **conexão AMQP nova a cada checagem** e não a
  fechava (+1 por período de `readinessProbe`, em três serviços), acumulando **milhares** de conexões
  e saturando a memória do broker até o `memory alarm` (que bloqueia os publishers — a mesma classe
  de sintoma tratada pontualmente no watermark da v0.8.0). No cluster, o broker chegou a **~3.7k
  conexões** abertas antes da correção.
- **Correção (por serviço):** o `AddRabbitMQ` passa a usar uma **factory lazy** que cria **uma única**
  `IConnection` no primeiro uso (não bloqueia o startup — o processo sobe mesmo com o broker fora),
  a **reutiliza** em todas as checagens (com `AutomaticRecoveryEnabled`), a **recria** quando ela
  fica fechada (auto-recovery esgotado) via **double-checked locking** (`SemaphoreSlim`), e a
  descarta no shutdown. Não se usou `Lazy<Task<IConnection>>` porque ele cachearia uma `Task`
  falhada (broker fora na 1ª checagem) e prenderia o `/health/ready` em `503` mesmo após o broker
  voltar. Padrão **idêntico** entre os três serviços (paridade). Comportamento observável do
  readiness inalterado: `503` com o broker fora, `200` quando volta — agora **sem** crescimento de
  conexões.

### Modificado
- Imagens `:local` de `users-api`, `catalog-api` e `payments-api` rebuildadas e recarregadas no
  cluster (minikube) para materializar a correção. Nenhum manifesto k8s alterado — o contrato de
  probes (`/health/live` + `/health/ready`) permanece o mesmo; a mudança é interna ao app.

## [0.8.1] - 2026-07-12

### Corrigido
- **Probes do `payments-api` separados** (issue #21): `livenessProbe → /health/live` e
  `readinessProbe → /health/ready`, refletindo os health checks separados entregues em
  `payments-api#6`. Antes ambos apontavam para `/health` (agregado), o que fazia o **liveness**
  depender do RabbitMQ/Mongo — se uma dependência caísse, o pod entrava em restart loop em vez de
  apenas sair do readiness. Validado no cluster (pod `Ready`, `/health/live` e `/health/ready` = 200,
  fluxo cadastro→compra→Approved com o payments persistindo em `paymentsdb`).

## [0.8.0] - 2026-07-12

### Adicionado
- **MongoDB (`paymentsdb`) provisionado para o `payments-api`** (issue #17) — fundação para a
  persistência/idempotência do serviço (`payments-api#2`/`#1`). O `payments-api` deixa de ser
  "zero banco": ganha `MongoDbSettings__DatabaseName=paymentsdb` (ConfigMap) e
  `MongoDbSettings__ConnectionString` com `?replicaSet=rs0` (SealedSecret cifrado), no compose
  e no k8s, além do initContainer `wait-for-mongodb`. Config **aditiva** — consumida a partir da
  `payments-api#2`; comportamento atual inalterado. `database-per-service` preservado (reusa a
  instância `mongodb`, database lógico novo).

### Corrigido
- **Watermark de memória do RabbitMQ agressivo demais** (issue #19) — o `vm_memory_high_watermark.absolute`
  de `384MiB` (introduzido na v0.7.0) tripava o flow control sob acúmulo de filas/conexões, colocando
  as conexões em `blocked`/`blocking` e travando **todos os publishers sem auto-recuperação** (ex.: o
  `users-api` levava ~20s e retornava 500 ao publicar `UserCreatedEvent`). Subido para `576MiB`, com o
  limite de memória do k8s de `768Mi` → `1Gi` (request `512Mi`) — ~448Mi de folga acima do watermark,
  mantendo a proteção de OOM sem bloquear publishers em carga normal.

## [0.7.0] - 2026-07-12

### Adicionado
- **Imagem custom do RabbitMQ com o plugin `rabbitmq_delayed_message_exchange`** (`docker/rabbitmq/`:
  `rabbitmq:3.13.7-management` + plugin `v3.13.0`, com `--checksum` de integridade). É pré-requisito
  do **delayed redelivery** (second-level retry) do MassTransit no `catalog-api` (`catalog-api#4`):
  sem o plugin, o `UseDelayedMessageScheduler`/`UseDelayedRedelivery` quebraria o serviço em runtime.

### Modificado
- `docker-compose.yml`: o serviço `rabbitmq` passa a `build: ./docker/rabbitmq` + `image: fcg-rabbitmq:local`.
- `k8s/11-infra-rabbitmq.yaml`: `image: fcg-rabbitmq:local` + `imagePullPolicy: IfNotPresent`.
- **Hardening de memória do RabbitMQ** (evita `OOMKilled`): a imagem custom passa a definir
  `vm_memory_high_watermark.absolute = 384MiB` (`docker/rabbitmq/rabbitmq.conf`) para o broker
  aplicar flow control antes de estourar o limite do container. No k8s, o limite de memória subiu
  para `768Mi` (request `384Mi`) e o `livenessProbe` ganhou `timeoutSeconds: 10`/`failureThreshold: 3`
  (o `ping` estourava o timeout default de 1s sob carga, causando restart espúrio).
- `scripts/deploy-minikube.sh`: build + `minikube image load` da `fcg-rabbitmq:local`.
- `README.md`: nota sobre a imagem custom e o motivo do plugin.

### Nota de migração
- O deploy no cluster agora **constrói e carrega** a imagem `fcg-rabbitmq:local` (o `deploy-minikube.sh`
  faz isso). Mudança backward-compatible: o plugin presente não altera o uso atual do broker.

## [0.6.0] - 2026-07-12

### Adicionado
- **Ingress (NGINX)** para acesso HTTP externo aos serviços voltados ao usuário. Novo
  `k8s/30-ingress.yaml` (`fcg-ingress`, `ingressClassName: nginx`) com roteamento **por host**:
  `users.fcg.local → users-api:80` e `catalog.fcg.local → catalog-api:80` — substitui o
  `kubectl port-forward` manual por URLs estáveis. `payments-api` e `notifications-api` são
  orientados a eventos e **não** têm entrada HTTP externa (ficam de fora de propósito).
- `README.md`: seção **"Acesso externo via Ingress"** (habilitar o addon, `/etc/hosts`, o caveat
  do `minikube tunnel` no macOS + driver docker, e port-forward do controller como alternativa sem sudo).

### Modificado
- `scripts/deploy-minikube.sh`: habilita o **addon ingress** do minikube (idempotente) e aguarda o
  `ingress-nginx-controller` ficar pronto antes de seguir; dicas de acesso atualizadas para o Ingress.

### Nota técnica
- O Ingress **não** usa `nginx.ingress.kubernetes.io/rewrite-target`: com `path: /` sem capture group,
  o rewrite reescreveria toda requisição para `/`, quebrando rotas como `/api/v1/jogos`. O roteamento é
  por host e o path é passado **intacto** ao backend.
- Os `Service` permanecem **ClusterIP** — o Ingress é o único ponto de entrada HTTP externo; a
  comunicação interna segue pelos nomes de Service. Escopo HTTP local (sem TLS) para o ambiente de demo.

## [0.5.0] - 2026-07-12

### Adicionado
- **Sealed Secrets (Bitnami)** para gerenciar segredos no Kubernetes **sem versioná-los em texto claro**.
  Novo `k8s/05-sealed-secrets.yaml` com **5 `SealedSecret`s cifrados** (`rabbitmq-secret`, `users-api-secret`,
  `catalog-api-secret`, `payments-api-secret`, `notifications-api-secret`) — só o controller do cluster
  decifra; o arquivo cifrado é seguro para commit. O prefixo `05-` os aplica cedo, para o controller
  materializar os `Secret` antes de os Deployments subirem.
- **`scripts/seal-secrets.sh`** — helper que (re)gera/rotaciona os SealedSecrets a partir de valores de
  demonstração (sobrescrevíveis por variáveis de ambiente para segredos reais, que nunca são comitados) e
  garante a **JWT parity** (mesma `JwtSettings__SecretKey` em `users-api-secret` e `catalog-api-secret`).
- `README.md`: seção **"Segredos no Kubernetes — Sealed Secrets"** (instalação do controller, geração,
  rotação e o caveat da chave por-cluster).

### Modificado
- `scripts/deploy-minikube.sh`: instala o **controller Sealed Secrets** (versão **pinada** `v0.38.4`) e
  aguarda o rollout **antes** do `kubectl apply` — `kubectl apply` idempotente, reconciliando na versão pinada.
- `k8s/11/20/21/22/23-*.yaml`: removidos os blocos `kind: Secret` com `stringData` em claro; os `secretRef`
  seguem apontando para os mesmos nomes, agora materializados pelo controller.

### Removido
- Todos os `Secret` com valores sensíveis **em texto claro** dos manifestos versionados.

### Nota de migração
- O deploy no cluster agora **exige o controller Sealed Secrets** instalado. Em um cluster limpo, o
  `scripts/deploy-minikube.sh` cuida disso automaticamente; em um `kubectl apply -R -f k8s/` manual,
  instale o controller antes (ver README), senão os `Secret` não materializam e as APIs não sobem.
- A chave do controller é **por-cluster**: após `minikube delete`, reinstale o controller e rode
  `./scripts/seal-secrets.sh` para regenerar os SealedSecrets (os antigos deixam de decifrar).
- O `docker-compose` (dev local) **não muda** — Sealed Secrets é mecanismo específico de Kubernetes;
  os valores permanecem idênticos entre compose e k8s.

## [0.4.0] - 2026-07-12

### Adicionado
- **Primeiro pipeline de CI do repositório** (`.github/workflows/ci.yml`), disparado em **push na `main`**
  e em **todo pull request**. Valida a orquestração **sem subir cluster nem construir imagens**:
  - `docker compose -f docker-compose.yml config -q` — valida o compose (com `-f` explícito para ser
    **determinístico**, isolando o CI de um `docker-compose.override.yml` local gitignored).
  - `kubeconform -strict -ignore-missing-schemas` (versão **pinada** `v0.6.7`) — validação de schema
    **offline** e rigorosa dos manifestos `k8s/`, contra os schemas oficiais do Kubernetes.
  - `yamllint -d relaxed` — lint de estilo, **não-bloqueante** por enquanto.
- Rede de segurança para as próximas mudanças de infra (Ingress, Sealed Secrets), que são puro YAML novo:
  um erro de indentação ou campo inválido passa a **falhar o PR** antes do merge, não no `kubectl apply`.
- `README.md`: seção **"CI — validação de compose e manifestos"** + badge de status do workflow.

### Nota técnica
- O gate de k8s usa **`kubeconform`** (offline) em vez de `kubectl apply --dry-run=client`: apesar do
  nome, o dry-run "client" do kubectl moderno **não é offline** — exige _discovery_ do apiserver e o
  OpenAPI do cluster, falhando com `connection refused` no runner. O `kubeconform` faz a mesma
  validação de schema de forma totalmente offline e mais rigorosa. Guardrails do workflow:
  `permissions: contents: read` (least privilege) e `concurrency` para cancelar runs superados.

## [0.3.0] - 2026-07-11

### Adicionado
- MongoDB no Kubernetes agora roda como **single-node replica set (`rs0`)**, fechando a lacuna de
  paridade dev/prod com o `docker-compose.yml`. É pré-requisito do **outbox transacional** das APIs
  (transações multi-documento do Mongo exigem replica set) — sem isso, o cadastro de usuário
  funcionava no compose mas **quebrava** no cluster.
- `readinessProbe` no MongoDB que **inicia o replica set de forma idempotente** (mesmo `rs.initiate(...)`
  do healthcheck do compose) e só marca o Pod `Ready` quando o nó é **PRIMARY gravável**
  (`db.hello().isWritablePrimary`), evitando tráfego antes de o Mongo aceitar transações.

### Modificado
- `k8s/10-infra-mongodb.yaml`: o container sobe com `args: ["mongod", "--replSet", "rs0", "--bind_ip_all"]`
  — via `args` (não `command`) para **preservar o ENTRYPOINT** `docker-entrypoint.sh` da imagem
  (invocação byte-equivalente ao compose). O `Service` `mongodb` passou a **headless**
  (`clusterIP: None` + `publishNotReadyAddresses: true`) para dar DNS próprio ao Pod e permitir o
  `rs.initiate` antes de o Pod ficar `Ready`. O DNS interno e a porta 27017 são os mesmos.
- `k8s/20-users-api.yaml` e `k8s/21-catalog-api.yaml`: connection strings dos Secrets passam a usar
  `?replicaSet=rs0`.
- `README.md`: documenta o replica set `rs0` no k8s (paridade com o compose agora completa).

### Nota de migração
- Trocar o `Service` `mongodb` de `ClusterIP` para headless é uma mudança de campo **imutável**: em um
  cluster que já tenha o Service antigo, rode `kubectl delete svc mongodb` uma vez antes do `apply`
  (clusters novos criam headless direto).

## [0.2.0] - 2026-07-11

### Adicionado
- Persistência do MongoDB no Kubernetes via `StatefulSet` + `volumeClaimTemplates`,
  provisionando um `PersistentVolumeClaim` (`mongo-data-mongodb-0`, `2Gi`,
  `storageClassName: standard`). Os dados de `usersdb`/`catalogdb` passam a **sobreviver**
  à recriação do Pod (rollout, `kubectl delete pod`, reagendamento).
- Migração idempotente no `scripts/deploy-minikube.sh`: remoção do `Deployment` antigo do
  MongoDB (`delete --ignore-not-found`) antes do `apply`, já que `Deployment` e `StatefulSet`
  são `kind` distintos (no-op em cluster limpo).

### Modificado
- `k8s/10-infra-mongodb.yaml`: MongoDB migrado de `Deployment` com `emptyDir` para
  `StatefulSet` com PVC. O `Service` `mongodb` (ClusterIP, 27017) permanece idêntico, então
  as APIs seguem conectando por `mongodb://mongodb:27017` **sem mudança de config**.
- `scripts/deploy-minikube.sh`: `rollout status` do MongoDB passa a apontar para
  `statefulset/mongodb`.
- `README.md`: documenta a persistência do MongoDB, o comportamento do PVC no `undeploy` e o
  caveat de que a paridade com o `docker-compose.yml` ainda é parcial (o replica set `rs0`
  ainda não está nos manifestos k8s).

### Removido
- Volume `emptyDir` do MongoDB no Kubernetes (causa da perda de dados entre recriações do Pod).

[0.3.0]: https://github.com/fcg-grupo-16/orchestration/releases/tag/v0.3.0
[0.2.0]: https://github.com/fcg-grupo-16/orchestration/releases/tag/v0.2.0

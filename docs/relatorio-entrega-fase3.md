# Tech Challenge — Fase 3 — Relatório de Entrega

> **Como exportar.** Este arquivo é a fonte; o PDF é derivado e **não** é versionado, para não
> divergir do Markdown. Para gerar:
>
> ```bash
> # HTML (sempre funciona; imprima para PDF pelo navegador)
> pandoc docs/relatorio-entrega-fase3.md -s --embed-resources \
>   -o relatorio-entrega-fase3.html
>
> # PDF direto, se houver um engine LaTeX instalado (brew install basictex)
> pandoc docs/relatorio-entrega-fase3.md -o relatorio-entrega-fase3.pdf
> ```
>
> ⚠️ `pandoc ... -o .pdf` **falha sem engine LaTeX** (`'pdflatex' not found`). Nesta máquina nenhum
> engine está instalado, então o caminho testado e funcional é o HTML acima.


## Grupo

**Grupo 16** — organização no GitHub: <https://github.com/fcg-grupo-16>

## Participantes

> ⚠️ **Preencher antes de enviar.** Estes dados não estão em nenhum arquivo do projeto e não podem
> ser inferidos do código ou do histórico do git.

| Nome | Username no Discord | Frente principal |
|---|---|---|
| Felipe Morandini | `<preencher>` | Orquestração · Gateway · Observabilidade |
| `<preencher>` | `<preencher>` | `<preencher>` |
| `<preencher>` | `<preencher>` | `<preencher>` |

## Documentação

- **Guia central:** <https://github.com/fcg-grupo-16/orchestration#readme>
- **Decisões de arquitetura (ADRs):** <https://github.com/fcg-grupo-16/orchestration/tree/main/docs/adr>

## Repositórios

| Repositório | Papel |
|---|---|
| [orchestration](https://github.com/fcg-grupo-16/orchestration) | Compose, manifestos k8s, gateway, observabilidade, scripts |
| [users-api](https://github.com/fcg-grupo-16/users-api) | Cadastro, autenticação (emite o JWT) |
| [catalog-api](https://github.com/fcg-grupo-16/catalog-api) | Catálogo, biblioteca, compra e avaliações (NoSQL) |
| [payments-api](https://github.com/fcg-grupo-16/payments-api) | Processamento de pagamento (event-driven) |
| [notifications-function](https://github.com/fcg-grupo-16/notifications-function) | **Função serverless** de notificações (Azure Functions + KEDA) |
| [notifications-api](https://github.com/fcg-grupo-16/notifications-api) | ⚠️ **DEPRECADO na Fase 3** — substituído pela Function |

## Vídeo

**Duração máxima: 20 minutos.**

`<link do Google Drive — deixar com acesso para qualquer pessoa com o link>`

> ⚠️ **Preencher antes de enviar**, junto com a tabela de participantes acima. São os dois únicos
> campos deste relatório que não podem ser derivados do repositório.

## Como as funcionalidades obrigatórias foram atendidas

### 1. API Gateway

**Kong Ingress Controller 3.x em modo DB-less** (chart 3.4.1, KIC 3.5, Kong 3.9.3), host único
`api.fcg.local`, como **porta de entrada exclusiva** da plataforma. O plugin `jwt` valida o token
**na borda** — sem token válido a resposta é 401 com `Server: kong/3.9.3`, antes de a requisição
alcançar qualquer serviço. Rate limit por IP, mais apertado nas rotas públicas de cadastro e login.
Configuração 100% em CRDs versionados (`k8s/gateway/`), nunca em Admin API mutável. O Ingress NGINX
da Fase 2 foi removido, e o deploy apaga o objeto legado explicitamente.

*Verificação:* `./scripts/gateway-test.sh` — **17 asserções**, incluindo token rejeitado por
querystring e por cookie, `OPTIONS` anônimo, e isolamento de rate limit medido com **dois pods em IPs
distintos**.

### 2. Serverless

**`notifications-function`**: Azure Functions v4, worker isolado (.NET 8), com `RabbitMQTrigger` nas
filas `notifications-user-created` e `notifications-payment-processed`, mais uma função HTTP de
histórico. Scale-to-zero real via **KEDA 2.20.2** (`minReplicaCount: 0`): em repouso o Deployment
fica em **zero réplica**.

*Medido no cluster:* pod nasce **6–11s** após o evento, `Executed 'Functions.UserCreatedFunction'
(Succeeded)`, fila drenada, e retorno a zero **63–75s** após o disparo.

*Por que não o plano Consumption:* o binding RabbitMQ **não é suportado** em Consumption/Flex
Consumption, e os planos que o suportam são de instância reservada — sem escala a zero. Ver
[ADR 0003](adr/0003-serverless-azure-functions-keda.md).

*Verificação:* `./scripts/keda-test.sh` — 12 asserções do ciclo 0→1→0.

### 3. Observabilidade — **Opção A (Prometheus + Grafana)**

Implantados por **manifestos Kubernetes** versionados, como o enunciado exige para a Opção A.
Instrumentação OpenTelemetry nos serviços ASP.NET, com `/metrics` no formato Prometheus. Descoberta
de alvos por annotation de pod. Dashboard provisionado como código a partir de
`observability/fcg-overview.json`, com **10 painéis**: latência p50/p95/p99 por serviço, throughput,
requisições por status HTTP, taxa de erro 5xx, top 5 rotas mais lentas e saúde da coleta.

**Jaeger** acrescenta o pilar de traces, que a Opção A não exige.

> **O trace distribuído da compra existe e é demonstrável.** Medido no cluster: o Jaeger conhece
> `catalog-api`, `payments-api` e `users-api`, e o trace
> `12a9febb22840ab46a93a61d4df07983` costura **9 spans** atravessando
> `catalog-api → RabbitMQ → payments-api → RabbitMQ → catalog-api`, com os atributos de negócio
> (`fcg.order.id`, `fcg.payment.status`, `fcg.payment.rule`) no span do pagamento.
>
> **A cadeia do cadastro fecha igualmente**: `users-api` + `notifications-function`. E a compra
> alcança a notificação: na última verificação ponta a ponta, o maior trace da plataforma tem
> **11 spans atravessando os QUATRO serviços** — `users-api`, `catalog-api`, `payments-api` e
> `notifications-function`. Os quatro aparecem no Jaeger.

### 4. NoSQL

**MongoDB 7** com o driver nativo `MongoDB.Driver` na collection `catalogdb.avaliacoes`: documento
flexível (`tags` e sub-documento `contexto` livre), **aggregation pipeline** para média e
distribuição de notas, e dois índices compostos criados no startup — `ix_jogo_data` (listagem
paginada por jogo) e `ux_jogo_usuario` (**unique**, que faz o banco garantir uma avaliação por
usuário por jogo, devolvendo 409 na segunda). Ver [ADR 0004](adr/0004-nosql-avaliacoes.md).

### 5. Cache distribuído

**Redis 7.4** via `IDistributedCache` + `StackExchange.Redis` em `users-api` e `catalog-api`, com
isolamento lógico por prefixo (`fcg:users:` / `fcg:catalog:`) e **invalidação por geração de chave**:
a geração entra na chave e invalidar é um `INCR` O(1), sem `KEYS` nem varredura. TTLs por natureza do
dado (lista de jogos 60s, jogo 10min, resumo de avaliações 120s, lista de avaliações 30s).

O mesmo Redis serve de **store de idempotência** da `notifications-function` (`SET NX EX` atômico),
ali **fail-closed** — ao contrário do cache dos serviços, que é fail-open. Ver
[ADR 0005](adr/0005-cache-redis-invalidacao-por-geracao.md).

## Verificação ponta a ponta

A plataforma é verificada por **quatro scripts**, todos versionados e todos executados contra o
cluster antes desta entrega:

| Script | O que prova | Resultado |
|---|---|---|
| `./scripts/verify-fase3.sh` | Checklist dos 5 requisitos da fase | **PRONTO PARA GRAVAR (sem pendências)** |
| `./scripts/gateway-test.sh` | Matriz do Kong | **17/17** |
| `./scripts/keda-test.sh` | Ciclo 0 → 1 → 0 | **12/12** |
| `MODO=gateway ./scripts/smoke-test.sh` | Fluxo de negócio pelo gateway | **9/9** |

Além deles, uma passada consolidada com o usuário **preservado** (o `smoke-test.sh` apaga o dele no
fim, e isso esconde a notificação de compra):

| # | Passo | Resultado |
|---|---|---|
| 1 | Cadastro pelo gateway | `201` |
| 2 | Login | token JWT emitido |
| 3 | Catálogo com token | jogo retornado |
| 4 | Compra (`POST /biblioteca`) | `202` — assíncrono, por desenho |
| 5 | Biblioteca após o pagamento | jogo presente (o `payments-api` aprovou e o `catalog-api` gravou) |
| 6 | Avaliação (NoSQL) | `201` |
| 7 | Avaliação duplicada | `409` — o índice `ux_jogo_usuario` recusa no banco |
| 8 | Notificações no `notificationsdb` | **duas**: boas-vindas e confirmação de compra, ambas endereçadas ao **e-mail real** |
| 9 | Trace no Jaeger | **11 spans atravessando os quatro serviços** |

O passo 8 é o que fecha a issue #9: a confirmação chega ao endereço do comprador, não ao `UserId`. E
por viver no MongoDB, essa evidência **sobrevive ao scale-to-zero** — o pod da Function já morreu
quando se consulta, e o registro continua lá. É a forma mais confiável de mostrar a notificação no
vídeo, porque não depende de pegar o pod vivo.

## Como subir e conferir tudo

```bash
minikube delete && minikube start
./scripts/seal-secrets.sh          # a chave do controller é nova depois do delete
./scripts/deploy-minikube.sh       # Kong, KEDA, infra, serviços e observabilidade
./scripts/verify-fase3.sh          # checklist da entrega
```

## Pendências conhecidas

Registradas como issues, e não omitidas:

| Issue | O quê | Afeta a entrega? |
|---|---|---|
| [catalog-api#24](https://github.com/fcg-grupo-16/catalog-api/issues/24) | Um teste de integração falhou de forma intermitente (1 ocorrência); 100 execuções posteriores limpas | **Não.** É intermitência de *teste*, não de aplicação. Nenhum requisito da fase depende dela |

Sobre a #24, o que se sabe está medido e registrado na issue: a falha durou 4 s num teste que leva
11,2 s, e essa janela é dominada pela subida dos containers de teste (MongoDB 4,6–6,4 s, RabbitMQ
5,3–6,3 s) — ou seja, a falha caiu na infraestrutura de teste, não numa asserção da API. A causa raiz
segue desconhecida, e o teste foi instrumentado para que a próxima ocorrência se explique sozinha.
Fechar a issue sem causa raiz seria varrer para baixo do tapete.

Já resolvidas durante a entrega, e listadas aqui porque apareciam em versões anteriores deste
relatório: [notifications-function#9](https://github.com/fcg-grupo-16/notifications-function/issues/9)
(confirmação de compra endereçada ao `UserId` em vez de a um e-mail — hoje a Function resolve o
contato num endpoint interno do `users-api` com credencial de serviço própria,
[ADR 0007](adr/0007-consulta-de-contato-servico-a-servico.md)), [orchestration#35](https://github.com/fcg-grupo-16/orchestration/issues/35) (Redis
volátil usado como store de idempotência — hoje há uma instância dedicada e durável,
[ADR 0006](adr/0006-redis-dedicado-para-idempotencia.md)),
[#38](https://github.com/fcg-grupo-16/orchestration/issues/38) e
[#41](https://github.com/fcg-grupo-16/orchestration/issues/41) (probes que matavam container
saudável), [#40](https://github.com/fcg-grupo-16/orchestration/issues/40) (deploy que não
atualizava as imagens do nó) e
[payments-api#19](https://github.com/fcg-grupo-16/payments-api/issues/19) /
[#20](https://github.com/fcg-grupo-16/payments-api/issues/20) (serviço sem instrumentação — hoje o
trace da compra fecha e o alvo do Prometheus está `up`).

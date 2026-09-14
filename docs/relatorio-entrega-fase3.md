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

`<link do YouTube — até 20 minutos>`

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

> ⚠️ **A cobertura de traces é parcial — 2 dos 4 serviços — e não há trace distribuído entre
> serviços.** Medido: o Jaeger conhece apenas `catalog-api` e `users-api`; `payments-api` e
> `notifications-function` não têm pacote OpenTelemetry. Dos 10 traces mais recentes de cada serviço
> instrumentado, **0 de 10** contêm mais de um serviço — a cadeia da compra se parte no
> `payments-api`, que não propaga o contexto. Rastreado em
> [payments-api#20](https://github.com/fcg-grupo-16/payments-api/issues/20). O que é demonstrável
> hoje é o trace **por serviço**, incluindo os spans de publicação do outbox.

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

## Como subir e conferir tudo

```bash
minikube delete && minikube start
./scripts/seal-secrets.sh          # a chave do controller é nova depois do delete
./scripts/deploy-minikube.sh       # Kong, KEDA, infra, serviços e observabilidade
./scripts/verify-fase3.sh          # checklist da entrega
```

## Pendências conhecidas

Registradas como issues, e não omitidas:

| Issue | O quê |
|---|---|
| [payments-api#20](https://github.com/fcg-grupo-16/payments-api/issues/20) | Serviço sem instrumentação: sem `/metrics` e sem traces — é o que quebra o trace distribuído |
| [orchestration#35](https://github.com/fcg-grupo-16/orchestration/issues/35) | Redis volátil (sem AOF/RDB) sendo usado como store de idempotência |
| [orchestration#38](https://github.com/fcg-grupo-16/orchestration/issues/38) / [#41](https://github.com/fcg-grupo-16/orchestration/issues/41) | Probes de liveness com timeout curto causando restarts |

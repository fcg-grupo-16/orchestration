# ADR 0002 — Observabilidade pela Opção A (Prometheus + Grafana), com Jaeger para traces

- **Status:** aceito
- **Data:** 2026-09-13
- **Issue:** [#27](https://github.com/fcg-grupo-16/orchestration/issues/27)

## Contexto

O enunciado da Fase 3 oferece duas opções de stack de observabilidade e exige que **a escolha seja
documentada**. A entrega precisa subir num minikube, offline, em qualquer máquina do grupo, e ser
demonstrável ao vivo numa gravação de até 20 minutos.

## Decisão

**Opção A — Prometheus + Grafana**, implantados por manifestos versionados em `k8s/`, com
**Jaeger** acrescentado para o pilar de traces.

- **Instrumentação:** OpenTelemetry nos serviços .NET, expondo `/metrics` no formato Prometheus e
  exportando traces por OTLP/gRPC para `http://jaeger:4317`.
- **Descoberta:** o Prometheus descobre alvos por **annotation de pod** (`prometheus.io/scrape`,
  `/port`, `/path`) — um serviço novo entra no scrape sem editar a configuração do Prometheus.
- **Dashboard provisionado como código:** a fonte da verdade é `observability/fcg-overview.json`, e
  `scripts/gen-dashboard-configmap.sh` gera o ConfigMap `k8s/41b-grafana-dashboard.yaml`. São 10
  painéis, cobrindo o que o enunciado pede:

  | Painel | Query |
  |---|---|
  | Latência p50/p95/p99 por serviço | `histogram_quantile(0.95, sum by (le, service) (rate(http_server_request_duration_seconds_bucket[5m])))` |
  | Throughput por serviço | `sum by (service) (rate(http_server_request_duration_seconds_count[5m]))` |
  | Requisições por status HTTP | `sum by (http_response_status_code) (rate(http_server_request_duration_seconds_count[5m]))` |
  | Taxa de erro (5xx) | `100 * sum(rate(..._count{http_response_status_code=~"5.."}[5m])) / clamp_min(sum(rate(..._count[5m])), 1)` |
  | Top 5 rotas mais lentas | `topk(5, histogram_quantile(0.95, sum by (le, service, http_route) (rate(..._bucket[5m]))))` |
  | Saúde da coleta | `count(up{job="fcg-pods"} == 1) or vector(0)` |

## Consequências

- **Custo zero e sem dependência de SaaS** no dia da gravação: nada de conta, chave de API ou limite
  de plano gratuito expirando na hora errada.
- Tudo versionado: o dashboard é revisável em PR como qualquer outro arquivo.
- O painel **"Saúde da coleta"** existe por experiência própria: o Prometheus pode estar
  impecavelmente de pé com **todos os alvos em 404**, o que faz o dashboard inteiro ficar vazio sem
  nenhum erro visível. Aconteceu neste projeto (issue #40), e é por isso que
  `scripts/verify-fase3.sh` afere **saúde de target**, não "o Deployment existe".
- ⚠️ **A cobertura de traces é PARCIAL — 2 dos 4 serviços — e não há trace distribuído.** Medido no
  cluster: `GET /api/services` do Jaeger devolve apenas `catalog-api` e `users-api`; o `payments-api`
  e a `notifications-function` não têm **nenhum** pacote OpenTelemetry, embora os manifestos definam
  `OTEL_SERVICE_NAME` e `OTEL_EXPORTER_OTLP_ENDPOINT` para os dois — configuração para um SDK
  ausente. Consultando os 10 traces mais recentes de cada serviço instrumentado, **0 de 10** contêm
  mais de um serviço:

  ```
  108ab43a6b39  spans=4  [catalog-api]  POST api/v1/biblioteca · outbox send · OrderPlacedEvent send
  162cda3b474c  spans=2  [catalog-api]  catalog-payment-processed receive · process   <-- trace SEPARADO
  ```

  A cadeia real da compra é catalog-api → RabbitMQ → **payments-api** → RabbitMQ → catalog-api. Os
  dois serviços instrumentados registram `AddSource("MassTransit")` exatamente para amarrar publisher
  e consumer, e isso funciona **dentro** de cada um; o elo que falta é o `payments-api`, que não
  continua nem propaga o contexto. Rastreado em
  [payments-api#19](https://github.com/fcg-grupo-16/payments-api/issues/19) — que **antecede** esta
  medição e já descrevia o buraco no meio da cadeia — e em
  [notifications-function#14](https://github.com/fcg-grupo-16/notifications-function/issues/14).
  A [payments-api#20](https://github.com/fcg-grupo-16/payments-api/issues/20) é irmã e trata do
  `/metrics` em 404; as duas se resolvem pela mesma instrumentação.

  **Enquanto isso estiver aberto, a documentação não afirma "trace distribuído da compra".** O que
  existe, e é demonstrável, é o trace **por serviço**, incluindo os spans de publicação do outbox.
- O span do MongoDB não aparece: o driver 3.x exige o pacote
  `MongoDB.Driver.Core.Extensions.DiagnosticSources` para emitir activities, e sem ele um `AddSource`
  seria silenciosamente ignorado — o código registra isso para ninguém "consertar" com uma linha que
  não faz nada.

## Alternativas descartadas

- **Opção B (stack alternativa do enunciado)** — sem ganho para os requisitos desta entrega e com o
  mesmo esforço de instrumentação.
- **Grafana Cloud / Datadog / New Relic** — exigem conta e rede; a demonstração precisa rodar offline.
- **Só Prometheus, sem Jaeger** — atenderia à métrica, mas deixaria o pilar de traces sem nenhuma
  cobertura. Com Jaeger, a cobertura é parcial e **verificável**, o que é melhor do que ausente.

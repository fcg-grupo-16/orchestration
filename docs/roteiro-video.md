# Roteiro do vídeo — Tech Challenge Fase 3

Limite: **20 minutos**. Grave em blocos e edite — tentar uma tomada única com `kubectl` ao vivo é
como se perde a entrega.

## Antes de ligar a câmera

```bash
./scripts/deploy-minikube.sh      # cluster completo
./scripts/verify-fase3.sh         # tem de terminar em "PRONTO PARA GRAVAR"
```

Deixe **cinco terminais** abertos, cada um já no diretório certo e com o comando digitado, só
faltando Enter:

| Terminal | Preparado com |
|---|---|
| 1 — gateway | `kubectl -n kong port-forward svc/kong-kong-proxy 8000:80` (já rodando) |
| 2 — curl | `GW=http://localhost:8000; H='Host: api.fcg.local'` exportados |
| 3 — serverless | `kubectl -n fcg get deploy notifications-function -w` (já rodando) |
| 4 — observabilidade | port-forwards de Grafana, Prometheus e Jaeger (já rodando) |
| 5 — dados | `kubectl -n fcg exec -it mongodb-0 -- mongosh` (já conectado) |

> O pod da Function leva alguns segundos a mais para subir: a imagem é amd64 emulada. Não corte o
> vídeo achando que travou.

## Blocos

| Tempo | Bloco | O que mostrar |
|---|---|---|
| 0:00–1:30 | **Contexto** | Diagrama do README. Os 5 requisitos da fase e onde cada um está |
| 1:30–5:00 | **1. Gateway** | `curl` sem token → **401 com `Server: kong/3.9.3`** (é o gateway, não o serviço); login → token; com token → 200; `?jwt=<token>` → **401** (não se aceita token por querystring); abrir `k8s/gateway/41-kong-plugins.yaml`; `./scripts/gateway-test.sh` → 17/17 |
| 5:00–9:00 | **2. Serverless** | Terminal 3 mostrando **0/0 réplicas**; cadastrar usuário pelo gateway; o pod nascendo ao vivo; `kubectl logs` com `Executed 'Functions.UserCreatedFunction' (Succeeded)`; ~60s depois, **volta a zero**; abrir o `ScaledObject` e o `RabbitMQTrigger` |
| 9:00–13:00 | **3. Observabilidade (Opção A)** | Dashboard do Grafana ao vivo; gerar tráfego e ver p95/throughput reagirem; `/targets` do Prometheus; **dizer em voz alta que a escolha é a Opção A e por quê** |
| 13:00–14:00 | **3b. Traces (cobertura parcial)** | Jaeger: trace do `POST /api/v1/biblioteca` no `catalog-api`, com os spans do **outbox** e da publicação do `OrderPlacedEvent`. **Declarar a limitação:** o `payments-api` ainda não está instrumentado, então a cadeia não fecha entre serviços — está registrado em payments-api#19 |
| 14:00–17:00 | **4. NoSQL** | `POST /api/v1/avaliacoes` → 201; repetir com o mesmo usuário → **409** (índice unique); `GET .../avaliacoes/resumo` → média e distribuição; no `mongosh`: `db.avaliacoes.findOne()` mostrando o `contexto` livre e `db.avaliacoes.getIndexes()` |
| 17:00–19:00 | **5. Cache** | Duas chamadas iguais com `curl -w '%{time_total}'`; `redis-cli --scan --pattern 'fcg:catalog:*'` mostrando a chave com a **geração**; atualizar um jogo; mostrar a geração **incrementada** e a chave nova |
| 19:00–20:00 | **Fechamento** | `./scripts/verify-fase3.sh` verde; README e ADRs |

## Comandos, na ordem

```bash
# ---- 1. Gateway
curl -i -H "$H" $GW/api/v1/jogos                       # 401, Server: kong/3.9.3
TOKEN=$(curl -s -H "$H" -H 'Content-Type: application/json' \
  -d '{"email":"admin@fcg.com","senha":"Admin@123456"}' $GW/api/v1/auth/login | jq -r .token)
curl -i -H "$H" -H "Authorization: Bearer $TOKEN" $GW/api/v1/jogos      # 200
curl -i -H "$H" "$GW/api/v1/jogos?jwt=$TOKEN"                            # 401
./scripts/gateway-test.sh

# ---- 2. Serverless
kubectl -n fcg get deploy notifications-function        # 0/0
curl -s -H "$H" -H 'Content-Type: application/json' \
  -d '{"nome":"Demo","email":"demo-'$(date +%s)'@fcg.com","senha":"Player@123456"}' \
  $GW/api/v1/usuarios
kubectl -n fcg logs -l app=notifications-function --tail=20

# ---- 4. NoSQL
curl -s -X POST -H "$H" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"jogoId":"<id>","nota":5,"comentario":"muito bom","contexto":{"plataforma":"PC"}}' \
  $GW/api/v1/avaliacoes

# ---- 5. Cache
kubectl -n fcg exec deploy/redis -- redis-cli --scan --pattern 'fcg:catalog:*'
```

## O que NÃO prometer na narração

- **"Trace distribuído da compra"** — não existe hoje. O `payments-api` não tem OpenTelemetry, então
  a cadeia se parte em dois traces órfãos (medido: 0 de 10 traces com mais de um serviço). Mostre o
  trace **por serviço** e declare a limitação; é mais forte do que ser pego por ela.
- **E-mail de notificação no `docker compose`** — no compose ninguém consome as filas desde a
  remoção do `notifications-api`. O fluxo de notificação só é observável no cluster.
- **`/metrics` do `payments-api`** — devolve 404; o serviço não tem instrumentação (payments-api#20).
  Se abrir o `/targets` do Prometheus, esse alvo aparece **down**: explique em vez de desviar.

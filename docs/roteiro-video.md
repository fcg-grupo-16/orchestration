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
| 9:00–13:00 | **3. Observabilidade (Opção A)** | Dashboard do Grafana ao vivo; gerar tráfego e ver p95/throughput reagirem; `/targets` do Prometheus — os **quatro** alvos aparecem `up` (UP=4, DOWN=0), pode abrir sem receio; mostrar a métrica de negócio `fcg_payment_decisions_total` com os labels `status` e `rule`; **dizer em voz alta que a escolha é a Opção A e por quê** |
| 13:00–14:00 | **3b. Traces distribuídos (compra e cadastro)** | Jaeger: abrir o trace do `POST /api/v1/biblioteca` e percorrer os **9 spans** atravessando `catalog-api → RabbitMQ → payments-api → RabbitMQ → catalog-api`; mostrar os atributos `fcg.payment.status` e `fcg.payment.rule` no span do pagamento. Depois abrir o trace do **cadastro** (`users-api → notifications-function`, 5 spans) e o da compra que chega à notificação (**10 spans em três serviços**): a plataforma inteira tem trace distribuído |
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

- **"O trace sempre fecha"** — ele fecha porque TODOS os publishers estão instrumentados. Um
  publisher sem OpenTelemetry publica sem o header `MT-Activity-Id`, e o span do consumidor nasce
  como trace próprio: a correlação é best-effort, por desenho. Vale dizer isso ao mostrar o Jaeger.
- **Não prometa o span do MongoDB** — ele não aparece: o driver 3.x exige um pacote extra de
  diagnóstico que a plataforma não usa.
- **E-mail de notificação no `docker compose`** — no compose ninguém consome as filas desde a
  remoção do `notifications-api`. O fluxo de notificação só é observável no cluster.

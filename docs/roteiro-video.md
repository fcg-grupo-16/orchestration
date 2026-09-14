# Roteiro do vídeo — Tech Challenge Fase 3

Limite: **20 minutos**. Grave em blocos e edite — tentar uma tomada única com `kubectl` ao vivo é
como se perde a entrega. Cada bloco abaixo é independente: se um sair ruim, regrave só ele.

---

## Parte 0 — Antes de ligar a câmera

### 0.1 Subir e conferir

```bash
cd orchestration
./scripts/deploy-minikube.sh      # cluster completo (~5 min)
./scripts/verify-fase3.sh         # TEM de terminar em "PRONTO PARA GRAVAR (sem pendências)"
```

Se o `verify-fase3.sh` não terminar verde, **não grave** — o problema aparece no vídeo.

### 0.2 Abrir os port-forwards e ESPERAR ficarem prontos

Este é o erro que mais custa tempo: disparar `curl` antes de o túnel estar de pé devolve `HTTP 000`
ou `404`, e parece bug da aplicação.

```bash
kubectl -n kong port-forward svc/kong-kong-proxy 8000:80 &
kubectl -n fcg  port-forward svc/grafana     3000:3000 &
kubectl -n fcg  port-forward svc/prometheus  9090:9090 &
kubectl -n fcg  port-forward svc/jaeger     16686:16686 &

# espere cada um responder ANTES de seguir
for p in 8000 3000 9090 16686; do
  until curl -s -o /dev/null -m 2 http://127.0.0.1:$p; do sleep 1; done
  echo "porta $p pronta"
done
```

> ⚠️ O Kong vive no namespace **`kong`**, não em `fcg`. Errar o namespace devolve "service not found".

### 0.3 Variáveis e um token de admin já na mão

```bash
export GW=http://localhost:8000
export H='Host: api.fcg.local'
export TOKEN=$(curl -s -H "$H" -H 'Content-Type: application/json' \
  -d '{"email":"admin@fcg.com","senha":"Admin@123456"}' $GW/api/v1/auth/login | jq -r .token)
export JOGO=$(curl -s -H "$H" -H "Authorization: Bearer $TOKEN" \
  "$GW/api/v1/jogos?pagina=1&tamanhoPagina=1" | jq -r '.itens[0].id')
echo "token=${#TOKEN} chars  jogo=$JOGO"
```

> O campo da paginação é **`itens`** (português), não `items`. Errar isso devolve `null` e trava a demo.

### 0.4 Cinco terminais, cada um com o comando já digitado

| Terminal | Deixe pronto com |
|---|---|
| 1 — gateway | os port-forwards da 0.2 rodando |
| 2 — curl | as variáveis da 0.3 exportadas |
| 3 — serverless | `kubectl -n fcg get deploy notifications-function -w` (já rodando) |
| 4 — dados | `kubectl -n fcg exec -it mongodb-0 -- mongosh` (já conectado) |
| 5 — scripts | no diretório `orchestration`, pronto para os `./scripts/*.sh` |

> O pod da Function demora alguns segundos a mais para subir: a imagem é **amd64 emulada** (a base do
> Azure Functions não publica arm64). Não corte o vídeo achando que travou.

---

## Parte 1 — Os blocos

| Tempo | Bloco |
|---|---|
| 0:00–1:30 | Contexto e arquitetura |
| 1:30–5:00 | **Requisito 1** — API Gateway |
| 5:00–8:30 | **Requisito 2** — Serverless com escala a zero |
| 8:30–11:30 | **Requisito 3** — Observabilidade (Opção A) |
| 11:30–13:30 | Traces distribuídos (extra) |
| 13:30–16:00 | **Requisito 4** — NoSQL |
| 16:00–18:00 | **Requisito 5** — Cache distribuído |
| 18:00–19:15 | Fluxo completo de ponta a ponta |
| 19:15–20:00 | Fechamento |

---

### 0:00–1:30 · Contexto

Mostre o diagrama do README do `orchestration`.

**Diga:** a Fase 2 era um monolito; a Fase 3 quebrou em **quatro serviços** com comunicação por
evento (RabbitMQ + MassTransit), **um deles serverless**. São seis repositórios: quatro de serviço,
um de orquestração e o `notifications-api` marcado como **deprecado**.

Nomeie os cinco requisitos e onde cada um está — é o índice do vídeo.

---

### 1:30–5:00 · Requisito 1: API Gateway

```bash
# sem token -> 401, e repare no cabeçalho Server
curl -i -H "$H" $GW/api/v1/jogos | head -5

# login público -> token
curl -s -H "$H" -H 'Content-Type: application/json' \
  -d '{"email":"admin@fcg.com","senha":"Admin@123456"}' $GW/api/v1/auth/login | jq -r .token | head -c 40

# com token -> 200
curl -i -H "$H" -H "Authorization: Bearer $TOKEN" $GW/api/v1/jogos | head -3

# token pela querystring -> 401 (não se aceita credencial em URL)
curl -i -H "$H" "$GW/api/v1/jogos?jwt=$TOKEN" | head -3
```

**O ponto que vale o bloco:** o 401 traz `Server: kong/3.9.3`. **A requisição nem chegou ao serviço** —
a autenticação acontece na borda. Fale isso em voz alta; é a diferença entre "tem um gateway na
frente" e "o gateway está de fato autenticando".

Abra `k8s/gateway/41-kong-plugins.yaml` e mostre que a configuração é **CRD versionado**, não Admin
API mutável.

Feche com a matriz:

```bash
./scripts/gateway-test.sh          # 17/17
```

Destaque as duas últimas asserções: rate limit **por IP**, provado com **dois pods em IPs distintos**
— um recebe 429 enquanto o outro segue em 200.

---

### 5:00–8:30 · Requisito 2: Serverless

```bash
kubectl -n fcg get deploy notifications-function        # 0/0  <- escala a zero REAL
kubectl -n fcg get scaledobject notifications-function  # Ready=True, Active=False
```

**Diga:** em repouso não há pod. Não é `replicas: 1` ocioso — é **zero**.

Dispare um evento real e deixe o terminal 3 à mostra:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H "$H" -H 'Content-Type: application/json' \
  -d '{"nome":"Demo","email":"demo-'$(date +%s)'@fcg.com","senha":"Player@123456"}' \
  $GW/api/v1/usuarios          # 201
```

O pod nasce em **6–11 s**. Quando aparecer:

```bash
kubectl -n fcg logs -l app=notifications-function --tail=20 | grep -i executed
```

Procure `Executed 'Functions.UserCreatedFunction' (Succeeded)`.

Depois abra `k8s/50-keda-notifications.yaml` e mostre `minReplicaCount: 0` e o trigger de fila.

**Espere a volta a zero** (~60–75 s após o disparo) com a câmera ligada — é o requisito de otimização
de recursos acontecendo. Se preferir, prove com o script:

```bash
./scripts/keda-test.sh             # 12/12, incluindo o ciclo 0 -> 1 -> 0
```

**Diga também por que não é o plano Consumption da Azure:** o binding RabbitMQ não é suportado lá, e
os planos que o suportam são de instância reservada, sem escala a zero. Está na ADR 0003.

---

### 8:30–11:30 · Requisito 3: Observabilidade (Opção A)

**Diga explicitamente: "escolhemos a Opção A — Prometheus + Grafana, implantados por manifestos
Kubernetes versionados."** O enunciado oferece opções; deixe claro qual foi.

Grafana em `localhost:3000` (admin/admin) → pasta **FCG** → dashboard **FCG — Visão geral**.

Gere tráfego antes de mostrar, senão os painéis ficam vazios:

```bash
for i in $(seq 1 30); do curl -s -o /dev/null -H "$H" -H "Authorization: Bearer $TOKEN" $GW/api/v1/jogos; done
```

Percorra os painéis: **p50/p95/p99 por serviço**, throughput, requisições por status, **taxa de erro
5xx**, top 5 rotas mais lentas.

Prometheus em `localhost:9090/targets` — pode abrir sem receio:

```
UP = 4   DOWN = 0      (users-api, catalog-api, payments-api, prometheus)
```

> A `notifications-function` fica **de fora de propósito** (`prometheus.io/scrape: "false"`): ela vive
> em zero réplica, e um alvo que some a cada 60 s poluiria o painel de saúde. Explique isso — alguém
> vai perguntar por que são quatro e não cinco.

Feche com a **métrica de negócio**, que é o que separa "instrumentei o framework" de "instrumentei o
domínio":

```bash
kubectl -n fcg port-forward svc/payments-api 18083:80 &
curl -s localhost:18083/metrics | grep fcg_payment_decisions_total
```

Mostre os labels `status` e `rule`.

---

### 11:30–13:30 · Traces distribuídos (extra, não exigido pela Opção A)

Jaeger em `localhost:16686`.

Faça uma compra para gerar o trace fresco:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "$H" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d "{\"jogoId\":\"$JOGO\"}" $GW/api/v1/biblioteca   # 202
```

No Jaeger, busque por `catalog-api` e abra o trace mais longo. Percorra os spans:

```
users-api → catalog-api → RabbitMQ → payments-api → RabbitMQ → catalog-api → notifications-function
```

Na última verificação, o maior trace tinha **11 spans atravessando os quatro serviços**. Abra o span
do pagamento e mostre os atributos de negócio: `fcg.order.id`, `fcg.payment.status`,
`fcg.payment.rule`.

---

### 13:30–16:00 · Requisito 4: NoSQL

```bash
# avaliação com documento flexível
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "$H" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"jogoId\":\"$JOGO\",\"nota\":5,\"titulo\":\"Ótimo\",\"comentario\":\"muito bom\",\"tags\":[\"rpg\"],\"contexto\":{\"plataforma\":\"PC\",\"horasJogadas\":42}}" \
  $GW/api/v1/avaliacoes        # 201

# o MESMO usuário no MESMO jogo -> 409, e quem recusa é o BANCO
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "$H" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"jogoId\":\"$JOGO\",\"nota\":1,\"titulo\":\"Duplicada\",\"comentario\":\"x\",\"tags\":[]}" \
  $GW/api/v1/avaliacoes        # 409

# agregação: média e distribuição
curl -s -H "$H" -H "Authorization: Bearer $TOKEN" $GW/api/v1/jogos/$JOGO/avaliacoes/resumo | jq
```

No terminal 4 (`mongosh`):

```javascript
use catalogdb
db.avaliacoes.findOne()          // mostre tags[] e o sub-documento contexto LIVRE
db.avaliacoes.getIndexes()       // ix_jogo_data e ux_jogo_usuario (unique)
```

**O ponto:** o 409 não vem de um `if` na aplicação — vem do índice **unique** do MongoDB. E o
`contexto` é um sub-documento sem esquema fixo, que é justamente o que justifica NoSQL aqui em vez de
uma coluna a mais no relacional.

---

### 16:00–18:00 · Requisito 5: Cache distribuído

```bash
# primeira chamada (miss) e segunda (hit)
curl -s -o /dev/null -w 'miss: %{time_total}s\n' -H "$H" -H "Authorization: Bearer $TOKEN" $GW/api/v1/jogos
curl -s -o /dev/null -w 'hit:  %{time_total}s\n' -H "$H" -H "Authorization: Bearer $TOKEN" $GW/api/v1/jogos

# as chaves, com a GERAÇÃO embutida no nome
kubectl -n fcg exec deploy/redis -- redis-cli --scan --pattern 'fcg:catalog:*'
kubectl -n fcg exec deploy/redis -- redis-cli GET fcg:catalog:gen:jogos
```

Saída (medida):

```
fcg:catalog:jogos:lista:g1:p1:t1:gentodos      <- o "g1" é a geração
fcg:catalog:gen:jogos
fcg:catalog:gen:avaliacoes:<jogoId>
fcg:catalog:avaliacoes:resumo:<jogoId>
gen:jogos = 1
```

Agora atualize o jogo e mostre a geração **incrementada** e a chave nova nascendo ao lado da antiga.

> ⚠️ Reenvie os **valores originais** do jogo, mudando só o que você quiser mostrar. Um PUT com corpo
> incompleto sobrescreve descrição e preço, e o dado de demonstração fica alterado no meio do vídeo.

```bash
curl -s -o /dev/null -w 'PUT: %{http_code}\n' -X PUT -H "$H" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"titulo":"CodeQuest: A Jornada do Desenvolvedor","descricao":"Um RPG educacional onde você aprende programação enquanto evolui seu personagem.","genero":2,"preco":49.90,"dataLancamento":"2024-03-15T00:00:00Z"}' \
  $GW/api/v1/jogos/$JOGO

kubectl -n fcg exec deploy/redis -- redis-cli GET fcg:catalog:gen:jogos     # agora 2
curl -s -o /dev/null -H "$H" -H "Authorization: Bearer $TOKEN" "$GW/api/v1/jogos?pagina=1&tamanhoPagina=1"
kubectl -n fcg exec deploy/redis -- redis-cli --scan --pattern 'fcg:catalog:jogos:lista:*'
```

Saída (medida):

```
gen:jogos = 2
fcg:catalog:jogos:lista:g0:p1:t1:gentodos      <- órfã: ninguém mais consulta
fcg:catalog:jogos:lista:g2:p1:t1:gentodos      <- a nova
```

**O ponto:** invalidar é um `INCR` **O(1)** numa chave de geração — sem `KEYS`, sem varredura, sem
apagar em massa. A chave antiga fica órfã: ninguém mais a consulta, e o TTL a recolhe sozinho. Mostrar
as duas lado a lado **é** a demonstração.

Mencione o segundo uso do Redis: **store de idempotência** da Function, com `SET NX EX` atômico, e ali
**fail-closed** (ao contrário do cache dos serviços, que é fail-open). Instância **dedicada e
durável**, com `noeviction` e AOF — ADR 0006.

---

### 18:00–19:15 · Fluxo completo, de ponta a ponta

Uma compra inteira, do cadastro à notificação:

```bash
E="video-$(date +%s)@fcg.com"
curl -s -o /dev/null -w 'cadastro:  %{http_code}\n' -X POST -H "$H" -H 'Content-Type: application/json' \
  -d "{\"nome\":\"Demo Video\",\"email\":\"$E\",\"senha\":\"Senha@123456\"}" $GW/api/v1/usuarios
T=$(curl -s -X POST -H "$H" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$E\",\"senha\":\"Senha@123456\"}" $GW/api/v1/auth/login | jq -r .token)
curl -s -o /dev/null -w 'compra:    %{http_code}\n' -X POST -H "$H" -H "Authorization: Bearer $T" \
  -H 'Content-Type: application/json' -d "{\"jogoId\":\"$JOGO\"}" $GW/api/v1/biblioteca
sleep 8
curl -s -H "$H" -H "Authorization: Bearer $T" $GW/api/v1/biblioteca | jq -r '.[0].titulo // .itens[0].titulo'
```

E a notificação, **no MongoDB** — não no log do pod:

```bash
kubectl -n fcg exec mongodb-0 -- mongosh --quiet notificationsdb \
  --eval "db.notifications.find({Recipient:'$E'}).forEach(d=>print(d.Type+' -> '+d.Recipient+' | '+d.Subject))"
```

Saída esperada:

```
UserCreatedEvent      -> video-...@fcg.com | Bem-vindo(a) à FIAP Cloud Games
PaymentProcessedEvent -> video-...@fcg.com | Confirmação de compra
```

**Por que consultar o Mongo e não o log:** a Function já voltou a zero quando você olha, e o log morre
com o pod. O histórico é durável. **É a forma confiável de mostrar a notificação no vídeo.**

**Diga o que esse `Recipient` significa:** o `PaymentProcessedEvent` só carrega o `UserId`. A Function
consulta um endpoint **interno** do `users-api` com um token de **serviço**, assinado por uma chave
**diferente** da dos usuários — a chave dos usuários é compartilhada com `catalog-api` e Kong, e quem
a tem assina até um token de Administrador. Está na ADR 0007.

---

### 19:15–20:00 · Fechamento

```bash
./scripts/verify-fase3.sh          # PRONTO PARA GRAVAR (sem pendências)
```

Mostre rapidamente:

- o `docs/adr/` — sete ADRs, cada uma com alternativas descartadas;
- a seção **"Pendências conhecidas"** do relatório. **Cite a issue aberta em voz alta.** Assumir uma
  intermitência de teste conhecida, medida e documentada pesa a favor, não contra.

---

## O que NÃO prometer na narração

- **"O trace sempre fecha"** — ele fecha porque TODOS os publishers estão instrumentados. Um publisher
  sem OpenTelemetry publica sem o header `MT-Activity-Id`, e o span do consumidor nasce como trace
  próprio: a correlação é best-effort, **por desenho**. Vale dizer isso ao mostrar o Jaeger.
- **Não prometa o span do MongoDB** — ele não aparece: o driver 3.x exige um pacote de diagnóstico que
  a plataforma não usa.
- **Não prometa notificação no `docker compose`** — no compose ninguém consome as filas desde a
  remoção do `notifications-api`. O fluxo de notificação só é observável **no cluster**.
- **Não diga "todas as issues estão fechadas"** — há uma aberta (`catalog-api#24`), de propósito.
- **Não rode `kubectl rollout status` na `notifications-function`** — ela está em 0 réplica por
  desenho, e o comando espera para sempre por um pod que corretamente não existe.

## Duas armadilhas que estragam a tomada

1. **`./scripts/smoke-test.sh` apaga o usuário que cria.** Se você rodar o smoke e depois for procurar
   a notificação daquele usuário, não vai achar — e parece defeito. Use o bloco das 18:00, que
   preserva o usuário.
2. **Port-forward sem espera de prontidão** devolve `HTTP 000` ou `404` e parece bug da aplicação.
   Sempre espere o `until curl ...` da seção 0.2.

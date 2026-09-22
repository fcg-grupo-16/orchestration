# Roteiro do vídeo — Tech Challenge Fase 3

**Script de narração.** Cada bloco tem **FALE** (texto literal, para ler em voz alta) e **MOSTRE**
(o que tem de estar na tela naquele momento). Cada número e cada afirmação das falas foi verificado —
no cluster ou nos manifestos versionados. Você pode ler em voz alta sem revisar.

Limite: **20 minutos**. Grave em blocos e junte na edição. Cada bloco é independente: se um sair
ruim, regrave só ele.

> **Ritmo:** são **1.747 palavras** de fala — cerca de **12min30** a 140 palavras por minuto. Os
> outros 7 minutos são digitar, esperar comando e deixar o KEDA acordar o pod. O tempo sobra de
> propósito: se você estiver adiantado, **não corra**.

---

# Parte 0 — Antes de ligar a câmera

## 0.1 Subir e conferir

O cluster **não sobrevive** entre sessões: o minikube fica `Stopped` depois de um reboot, e o
`kubectl` cai silenciosamente em outro contexto. Comece garantindo os dois:

```bash
minikube status                   # se disser "Stopped", suba: minikube start
kubectl config use-context minikube
kubectl get ns | grep fcg         # sem isto, você está apontando para OUTRO cluster

cd orchestration
./scripts/seal-secrets.sh         # só se o minikube foi recriado (chave nova do controller)
./scripts/deploy-minikube.sh      # ~5 min
./scripts/verify-fase3.sh         # TEM de terminar em "PRONTO PARA GRAVAR (sem pendências)"
```

Se não terminar verde, **não grave**.

> ⚠️ O erro mais traiçoeiro aqui é o `kubectl` apontando para outro cluster: os comandos respondem
> normalmente, só dizem "not found". Parece que a plataforma quebrou, quando é só o contexto errado.

## 0.2 Port-forwards, com espera de prontidão

Disparar `curl` antes do túnel subir devolve `HTTP 000` e parece bug da aplicação.

```bash
kubectl -n kong port-forward svc/kong-kong-proxy 8000:80 &
kubectl -n fcg  port-forward svc/grafana     3000:3000 &
kubectl -n fcg  port-forward svc/prometheus  9090:9090 &
kubectl -n fcg  port-forward svc/jaeger     16686:16686 &
kubectl -n fcg  port-forward svc/payments-api 18083:80 &

for p in 8000 3000 9090 16686 18083; do
  until curl -s -o /dev/null -m 2 http://127.0.0.1:$p; do sleep 1; done
  echo "porta $p pronta"
done
```

> O Kong vive no namespace **`kong`**, não em `fcg`.

## 0.3 Variáveis

```bash
export GW=http://localhost:8000
export H='Host: api.fcg.local'
export TOKEN=$(curl -s -H "$H" -H 'Content-Type: application/json' \
  -d '{"email":"admin@fcg.com","senha":"Admin@123456"}' $GW/api/v1/auth/login | jq -r .token)
export JOGO=$(curl -s -H "$H" -H "Authorization: Bearer $TOKEN" \
  "$GW/api/v1/jogos?pagina=1&tamanhoPagina=1" | jq -r '.itens[0].id')
echo "token=${#TOKEN} chars  jogo=$JOGO"
```

> O campo da paginação é **`itens`**, não `items`.

## 0.4 Tela e terminais

- Esconda a barra de menu e o Dock (`System Settings → Desktop & Dock`), trave **16:9** no CleanShot
  e use **a mesma área em todos os blocos**, senão o enquadramento pula na edição.
- **Aumente a fonte do terminal agora.** Fonte pequena fica ilegível depois da compressão.
- Ligue o **Do Not Disturb automático** do CleanShot.

| Terminal | Deixe pronto com |
|---|---|
| 1 | os port-forwards da 0.2 rodando |
| 2 | as variáveis da 0.3 exportadas — é aqui que você digita |
| 3 | `kubectl -n fcg get deploy notifications-function -w` rodando |
| 4 | `kubectl -n fcg exec -it mongodb-0 -- mongosh` conectado |
| 5 | no diretório `orchestration`, para os `./scripts/*.sh` |

> O pod da Function demora alguns segundos a mais: a imagem é **amd64 emulada**. Não corte achando
> que travou.

---

# Parte 1 — O script

| Tempo | Bloco |
|---|---|
| 0:00–1:30 | Abertura e arquitetura |
| 1:30–5:00 | **Requisito 1** — API Gateway |
| 5:00–8:30 | **Requisito 2** — Serverless |
| 8:30–11:30 | **Requisito 3** — Observabilidade |
| 11:30–13:30 | Traces distribuídos |
| 13:30–16:00 | **Requisito 4** — NoSQL |
| 16:00–18:00 | **Requisito 5** — Cache |
| 18:00–19:15 | Fluxo completo |
| 19:15–20:00 | Fechamento |

---

## Bloco 1 · 0:00–1:30 · Abertura e arquitetura

**MOSTRE:** o diagrama de arquitetura do README do `orchestration`, em tela cheia.

**FALE:**

> Olá. Este é o Tech Challenge da Fase 3 do grupo dezesseis, o FIAP Cloud Games.
>
> Na Fase 2, isso era um monolito. Nesta fase, ele virou quatro microsserviços que conversam por
> evento, usando RabbitMQ com MassTransit — e um deles deixou de ser um container para virar uma
> função serverless.
>
> São quatro serviços: o `users-api` faz cadastro e emite o token; o `catalog-api` cuida de catálogo,
> biblioteca e avaliações; o `payments-api` decide o pagamento; e a `notifications-function` envia os
> e-mails. Tudo isso atrás de um gateway.

**MOSTRE:** aponte com o cursor, no diagrama, o caminho da compra — `catalog-api` → RabbitMQ →
`payments-api` → RabbitMQ → `catalog-api` e `notifications-function`.

**FALE:**

> O fluxo da compra é assim: o catálogo recebe a aquisição e publica um evento. O pagamento decide se
> aprova. E aí duas coisas acontecem em paralelo: o catálogo grava na biblioteca, e a função manda o
> e-mail de confirmação. Ninguém espera ninguém.
>
> Vou mostrar os cinco requisitos obrigatórios, um por um, rodando no cluster. Gateway, serverless,
> observabilidade, NoSQL e cache distribuído.

---

## Bloco 2 · 1:30–5:00 · Requisito 1 — API Gateway

**MOSTRE:** terminal 2. Rode:

```bash
curl -i -H "$H" $GW/api/v1/jogos | head -5
```

**FALE:**

> Primeiro requisito: API Gateway. Estou pedindo o catálogo **sem** token.
>
> Deu quatrocentos e um, como esperado. Mas o que importa aqui é essa linha: `Server: kong slash três
> ponto nove ponto três`.
>
> Isso quer dizer que **a requisição nunca chegou ao serviço**. Quem recusou foi o Kong, na borda. Não
> é só ter um gateway na frente — é o gateway de fato autenticando, antes de gastar um serviço.

**MOSTRE:** rode o login e mostre o token:

```bash
curl -s -H "$H" -H 'Content-Type: application/json' \
  -d '{"email":"admin@fcg.com","senha":"Admin@123456"}' $GW/api/v1/auth/login | jq -r .token | head -c 40
```

**FALE:**

> Agora o login, que é rota pública. O `users-api` emite um JWT.

**MOSTRE:**

```bash
curl -i -H "$H" -H "Authorization: Bearer $TOKEN" $GW/api/v1/jogos | head -3
```

**FALE:**

> Com o token, duzentos. Mesma rota, mesma chamada — só mudou a credencial.

**MOSTRE:**

```bash
curl -i -H "$H" "$GW/api/v1/jogos?jwt=$TOKEN" | head -3
```

**FALE:**

> E aqui um detalhe que a gente fez de propósito. Estou mandando o **mesmo token válido**, mas pela
> query string, na URL. E o gateway recusa.
>
> Isso é decisão de segurança, não limitação: credencial em URL vaza em log de servidor, em histórico
> de navegador e no cabeçalho `Referer`. Só aceitamos no cabeçalho `Authorization`.

**MOSTRE:** abra `k8s/gateway/41-kong-plugins.yaml` no editor, role pelos plugins.

**FALE:**

> A configuração do gateway é toda em CRD versionado, aqui no repositório. Nada de Admin API mutável.
> Quem clonar o repo sobe o mesmo gateway, com os mesmos plugins.

**MOSTRE:** terminal 5:

```bash
./scripts/gateway-test.sh
```

Espere terminar e deixe o resultado na tela.

**FALE:**

> E tem uma matriz de testes do gateway: dezessete asserções. Token na query string, token em cookie,
> `OPTIONS` anônimo, `/health` não exposto, rate limit.
>
> As duas últimas são as que eu mais gosto. O rate limit é **por IP** — e isso é testado com dois pods
> em IPs diferentes: um leva quatrocentos e vinte e nove, e o outro continua em duzentos ao mesmo
> tempo. Se o limite fosse global, os dois cairiam juntos.

---

## Bloco 3 · 5:00–8:30 · Requisito 2 — Serverless

**MOSTRE:** terminal 2:

```bash
kubectl -n fcg get deploy notifications-function
kubectl -n fcg get scaledobject notifications-function
```

**FALE:**

> Segundo requisito: serverless. Esse é o serviço de notificações, que na Fase 2 era um container
> rodando vinte e quatro horas por dia esperando evento.
>
> Repare: **zero de zero réplica**. Não é uma réplica ociosa — é zero. Não existe pod. E o
> `ScaledObject` do KEDA está `Ready` igual a `True`, com `Active` igual a `False`, porque a fila está
> vazia.

**MOSTRE:** deixe o terminal 3 (`get deploy -w`) visível ao lado. Rode no terminal 2:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H "$H" -H 'Content-Type: application/json' \
  -d '{"nome":"Demo","email":"demo-'$(date +%s)'@fcg.com","senha":"Player@123456"}' \
  $GW/api/v1/usuarios
```

**FALE:**

> Vou cadastrar um usuário de verdade, pelo gateway. Isso publica um evento na fila.
>
> E agora é só olhar o terminal da direita. O KEDA está vendo a fila crescer e vai subir o pod.

**MOSTRE:** espere o pod aparecer no `-w` (uns 10 segundos). **Não corte.**

**FALE:**

> Aí está. O pod nasceu em poucos segundos, a partir de zero, porque chegou mensagem.

**MOSTRE:**

```bash
kubectl -n fcg logs -l app=notifications-function --tail=20 | grep -i executed
```

**FALE:**

> E processou: `Executed Functions.UserCreatedFunction, Succeeded`. O e-mail de boas-vindas saiu.

**MOSTRE:** abra `k8s/50-keda-notifications.yaml`, destaque `minReplicaCount: 0` e o trigger de fila.

**FALE:**

> É esse manifesto que faz o trabalho. `minReplicaCount` zero, e a métrica de escala é o tamanho da
> fila do RabbitMQ.
>
> Uma decisão que vale explicar: a gente **não** usou o plano Consumption da Azure. O binding de
> RabbitMQ não é suportado lá, e os planos que suportam são de instância reservada, sem escala a zero
> — o que mataria justamente o requisito. Está registrado na ADR três.

**MOSTRE:** volte ao terminal 3 e espere o pod voltar a zero (~70 s do disparo). Se preferir não
esperar na gravação, corte aqui e rode `./scripts/keda-test.sh` no lugar.

**FALE:**

> E agora o outro lado do requisito, que é o que economiza recurso: sem mensagem na fila, o KEDA
> derruba o pod e volta para zero. Acontece pouco mais de um minuto depois do disparo — o
> `cooldownPeriod` é de sessenta segundos.
>
> Esse ciclo inteiro, zero, um, zero, tem um script que prova em doze asserções.

---

## Bloco 4 · 8:30–11:30 · Requisito 3 — Observabilidade

**MOSTRE:** terminal 2, antes de abrir o Grafana:

```bash
for i in $(seq 1 30); do curl -s -o /dev/null -H "$H" -H "Authorization: Bearer $TOKEN" $GW/api/v1/jogos; done
```

**FALE:**

> Terceiro requisito: observabilidade. O enunciado dá opções, e **a nossa escolha foi a Opção A —
> Prometheus com Grafana**, implantados por manifesto Kubernetes versionado, como a opção pede.
>
> Antes de abrir o painel, vou gerar tráfego, senão os gráficos aparecem vazios e não é isso que eu
> quero mostrar.

**MOSTRE:** navegador em `localhost:3000`, login `admin`/`admin`, pasta **FCG**, dashboard
**FCG — Visão Geral**. Role pelos painéis devagar.

**FALE:**

> Esse dashboard é provisionado como código: ele nasce de um JSON no repositório e vira ConfigMap. Não
> foi montado à mão na interface, então quem subir o cluster recebe o painel pronto.
>
> São dez painéis. Nove de métrica, e um primeiro que explica como ler os outros.
>
> Latência em percentis, p cinquenta, p noventa e cinco e p noventa e nove, por serviço. Throughput.
> Requisições por status HTTP. Taxa de erro cinco-x-x. E as cinco rotas mais lentas.

**MOSTRE:** navegador em `localhost:9090/targets`.

**FALE:**

> E aqui os alvos do Prometheus: quatro no ar, zero fora.
>
> Vai faltar um para quem está contando, e é de propósito: a `notifications-function` está marcada
> para **não** ser raspada. Ela vive em zero réplica — um alvo que desaparece a cada minuto deixaria o
> painel de saúde permanentemente vermelho, sem nenhum problema real acontecendo.

**MOSTRE:** terminal 2:

```bash
curl -s localhost:18083/metrics | grep fcg_payment_decisions_total
```

**FALE:**

> E para fechar, a parte que separa instrumentar o framework de instrumentar o domínio.
>
> Essa é uma métrica **de negócio**: `fcg_payment_decisions_total`, com label de status e de regra.
> Ela não conta requisição HTTP — conta **decisão de pagamento**, aprovada ou recusada, e por qual
> regra. É o tipo de número que o time de produto pergunta, não o time de infra.

---

## Bloco 5 · 11:30–13:30 · Traces distribuídos

**MOSTRE:** terminal 2:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "$H" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d "{\"jogoId\":\"$JOGO\"}" $GW/api/v1/biblioteca
```

**FALE:**

> Esse bloco é um extra — a Opção A não pede trace. Mas sem ele, depurar fluxo assíncrono é adivinhar.
>
> Acabei de fazer uma compra. Ela devolveu **duzentos e dois**, Accepted, não duzentos: a compra é
> assíncrona por desenho. O catálogo aceitou o pedido e publicou o evento; quem decide é o pagamento,
> depois.

**MOSTRE:** navegador em `localhost:16686`. Busque o serviço `catalog-api`, abra o trace mais longo,
expanda os spans.

**FALE:**

> E é aqui que o assíncrono fica visível. Esse é **um único trace**, e ele atravessa os quatro
> serviços: começou no `users-api`, passou pelo catálogo, foi pela fila até o pagamento, voltou pela
> fila, e terminou na função de notificação.
>
> Onze spans. Isso só fecha porque todos os publishers estão instrumentados e o contexto do trace
> viaja **dentro** da mensagem do RabbitMQ.

**MOSTRE:** clique no span do pagamento e abra os atributos (`fcg.order.id`, `fcg.payment.status`,
`fcg.payment.rule`).

**FALE:**

> E no span do pagamento tem atributo de negócio: qual pedido, qual status, qual regra decidiu. Dá
> para responder "por que **este** pagamento foi recusado" sem abrir log.
>
> Uma ressalva honesta: isso é best-effort por desenho. Se alguém publicar um evento sem
> instrumentação, o consumidor começa um trace novo e a corrente quebra. A gente sabe onde isso pode
> acontecer.

---

## Bloco 6 · 13:30–16:00 · Requisito 4 — NoSQL

**MOSTRE:** terminal 2. Cole o bloco inteiro — ele cria um **usuário novo** antes de avaliar:

```bash
# Usuário NOVO a cada tomada. Sem isto, a segunda tomada quebra: o índice unique já teria
# registrado a avaliação da primeira, e o 201 sairia como 409 antes da hora.
EA="avaliador-$(date +%s)@fcg.com"
curl -s -o /dev/null -X POST -H "$H" -H 'Content-Type: application/json' \
  -d "{\"nome\":\"Avaliador\",\"email\":\"$EA\",\"senha\":\"Senha@123456\"}" $GW/api/v1/usuarios
TA=$(curl -s -X POST -H "$H" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EA\",\"senha\":\"Senha@123456\"}" $GW/api/v1/auth/login | jq -r .token)

curl -s -o /dev/null -w 'avaliacao: %{http_code}\n' -X POST -H "$H" -H "Authorization: Bearer $TA" \
  -H 'Content-Type: application/json' \
  -d "{\"jogoId\":\"$JOGO\",\"nota\":5,\"titulo\":\"Ótimo\",\"comentario\":\"muito bom\",\"tags\":[\"rpg\"],\"contexto\":{\"plataforma\":\"PC\",\"horasJogadas\":42}}" \
  $GW/api/v1/avaliacoes
```

**FALE:**

> Quarto requisito: NoSQL. A funcionalidade é avaliação de jogo, em MongoDB, com o driver nativo.
>
> Acabei de criar uma avaliação. Duzentos e um. E repare no corpo que eu mandei: tem um campo
> `contexto`, com plataforma e horas jogadas — um sub-documento **sem esquema fixo**.

**MOSTRE:** repita a mesma chamada, mudando só a nota:

```bash
curl -s -o /dev/null -w 'duplicada: %{http_code}\n' -X POST -H "$H" -H "Authorization: Bearer $TA" \
  -H 'Content-Type: application/json' \
  -d "{\"jogoId\":\"$JOGO\",\"nota\":1,\"titulo\":\"Duplicada\",\"comentario\":\"x\",\"tags\":[]}" \
  $GW/api/v1/avaliacoes
```

> Note o `$TA`: é o **mesmo** usuário da chamada anterior. O índice é por par jogo + usuário — com
> outro token o retorno seria 201, e a demonstração não provaria nada.

**FALE:**

> Agora o **mesmo usuário** avaliando o **mesmo jogo** de novo. Quatrocentos e nove, conflito.
>
> E a parte importante: quem recusou **não foi um `if` na aplicação**. Foi o banco, por um índice
> unique. Validar na aplicação deixa brecha em corrida — duas requisições simultâneas passam as duas.
> O índice não deixa.

**MOSTRE:** terminal 4 (`mongosh`):

```javascript
use catalogdb
db.avaliacoes.getIndexes()
```

**FALE:**

> Aqui estão os índices. O `ux_jogo_usuario`, que é o unique que acabou de recusar. E o
> `ix_jogo_data`, composto, que serve a listagem paginada por jogo.

**MOSTRE:**

```javascript
db.avaliacoes.findOne()
```

**FALE:**

> E esse é o documento. Tags como array, e o `contexto` como sub-documento livre.
>
> É isso que justifica NoSQL aqui, e não uma coluna a mais no relacional: cada avaliação pode trazer
> um contexto diferente, sem migração de esquema.

**MOSTRE:** terminal 2:

```bash
curl -s -H "$H" -H "Authorization: Bearer $TOKEN" $GW/api/v1/jogos/$JOGO/avaliacoes/resumo | jq
```

**FALE:**

> E o resumo é um aggregation pipeline no Mongo: média e distribuição de notas calculadas no banco,
> não trazendo tudo para a memória da aplicação.

---

## Bloco 7 · 16:00–18:00 · Requisito 5 — Cache distribuído

**MOSTRE:** terminal 2:

```bash
curl -s -o /dev/null -w 'primeira: %{time_total}s\n' -H "$H" -H "Authorization: Bearer $TOKEN" $GW/api/v1/jogos
curl -s -o /dev/null -w 'segunda:  %{time_total}s\n' -H "$H" -H "Authorization: Bearer $TOKEN" $GW/api/v1/jogos
```

**FALE:**

> Quinto requisito: cache distribuído, com Redis.
>
> Duas chamadas iguais. A primeira vai ao banco, a segunda vem do cache.

**MOSTRE:**

```bash
kubectl -n fcg exec deploy/redis -- redis-cli --scan --pattern 'fcg:catalog:*'
```

> ⚠️ **Não rode `GET fcg:catalog:gen:jogos` aqui.** Num cache recém-subido essa chave **ainda não
> existe** — o `GET` imprime vazio, e você estaria dizendo "guarde o valor da geração" na frente de uma
> saída em branco. Ausência **é** geração zero, e é por isso que o nome da chave traz `g0`. O contador
> só passa a existir no primeiro `INCR`, que é o próximo passo. Leia a geração **pelo nome da chave**.

**FALE:**

> E aqui está o desenho que eu queria mostrar. Olhe o nome da chave da listagem: ela tem um `g` e um
> número no meio. Esse número é a **geração** do cache.
>
> Guarde esse número, porque eu vou atualizar um jogo agora.

**MOSTRE:**

```bash
curl -s -o /dev/null -w 'PUT: %{http_code}\n' -X PUT -H "$H" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"titulo":"CodeQuest: A Jornada do Desenvolvedor","descricao":"Um RPG educacional onde você aprende programação enquanto evolui seu personagem.","genero":2,"preco":49.90,"dataLancamento":"2024-03-15T00:00:00Z"}' \
  $GW/api/v1/jogos/$JOGO

kubectl -n fcg exec deploy/redis -- redis-cli GET fcg:catalog:gen:jogos
curl -s -o /dev/null -H "$H" -H "Authorization: Bearer $TOKEN" "$GW/api/v1/jogos?pagina=1&tamanhoPagina=1"
kubectl -n fcg exec deploy/redis -- redis-cli --scan --pattern 'fcg:catalog:jogos:lista:*'
```

**FALE:**

> A geração subiu. E na próxima consulta nasceu uma chave nova, com o número novo — do lado da antiga.
>
> A chave antiga continua ali — mas ninguém mais pergunta por ela, e o TTL a recolhe sozinha.
>
> É isso que eu quero destacar: invalidar o cache aqui é **um `INCR`**, uma operação constante. Não tem
> `KEYS`, não tem varredura, não tem apagar em massa. Em Redis, varrer chave para invalidar é o jeito
> clássico de derrubar produção.

**MOSTRE:** nada novo — fale olhando para o terminal.

**FALE:**

> E o Redis tem um segundo uso nesta plataforma: ele é o controle de idempotência da função de
> notificação, com `SET NX`, para não mandar o mesmo e-mail duas vezes.
>
> Mas esse é uma **instância separada**, configurada como banco durável, com `noeviction` e persistência
> ligada. E a razão é direta: o Redis de cache usa `allkeys-lru`, ele **descarta** chave quando falta
> memória. Se a chave de idempotência morresse assim, o cliente receberia e-mail repetido. Cache pode
> perder chave; controle de idempotência não pode.

---

## Bloco 8 · 18:00–19:15 · Fluxo completo

**MOSTRE:** terminal 2, cole o bloco inteiro:

```bash
E="video-$(date +%s)@fcg.com"
curl -s -o /dev/null -w 'cadastro: %{http_code}\n' -X POST -H "$H" -H 'Content-Type: application/json' \
  -d "{\"nome\":\"Demo Video\",\"email\":\"$E\",\"senha\":\"Senha@123456\"}" $GW/api/v1/usuarios
T=$(curl -s -X POST -H "$H" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$E\",\"senha\":\"Senha@123456\"}" $GW/api/v1/auth/login | jq -r .token)
curl -s -o /dev/null -w 'compra:   %{http_code}\n' -X POST -H "$H" -H "Authorization: Bearer $T" \
  -H 'Content-Type: application/json' -d "{\"jogoId\":\"$JOGO\"}" $GW/api/v1/biblioteca
sleep 8
echo "na biblioteca: $(curl -s -H "$H" -H "Authorization: Bearer $T" $GW/api/v1/biblioteca | jq -r '.[0].titulo')"
```

**FALE:**

> Para fechar, o fluxo inteiro de uma vez: cadastro, login, compra.
>
> A compra devolveu duzentos e dois, e oito segundos depois o jogo **está** na biblioteca. Nesse
> intervalo, o evento foi para a fila, o pagamento aprovou, publicou de volta, e o catálogo gravou.
> Nenhuma dessas quatro etapas esperou pela outra.

**MOSTRE:**

```bash
kubectl -n fcg exec mongodb-0 -- mongosh --quiet notificationsdb \
  --eval "db.notifications.find({Recipient:'$E'}).forEach(d=>print(d.Type+' -> '+d.Recipient+' | '+d.Subject))"
```

**FALE:**

> E as notificações desse usuário: duas. Boas-vindas, do cadastro, e confirmação de compra, do
> pagamento aprovado.
>
> Repare no destinatário: é o **e-mail** dele. Isso parece óbvio, mas não era. O evento de pagamento
> só carrega o ID do usuário — a confirmação saía endereçada a um ObjectId. A gente abriu issue,
> e hoje a função consulta um endpoint interno do `users-api` com um token de **serviço**, assinado com
> uma chave **diferente** da chave dos usuários. Porque a chave dos usuários é compartilhada com o
> catálogo e com o gateway: quem a tem assina qualquer token, inclusive de administrador. Dar isso a
> uma função só para ler um e-mail seria privilégio demais.
>
> E eu estou consultando o MongoDB, não o log do pod, por um motivo: o pod já voltou a zero. O log
> morreu com ele; o histórico é durável.

---

## Bloco 9 · 19:15–20:00 · Fechamento

**MOSTRE:** terminal 5:

```bash
./scripts/verify-fase3.sh
```

Deixe terminar em "PRONTO PARA GRAVAR (sem pendências)".

**FALE:**

> Fechando: esse script é o checklist da entrega rodando contra o cluster de verdade. Os cinco
> requisitos, mais as imagens conferidas.

**MOSTRE:** abra a pasta `docs/adr/` no editor, mostre os sete arquivos.

**FALE:**

> E as decisões estão registradas: sete ADRs, cada uma com as alternativas que a gente **descartou** e
> o porquê. Não só o que escolhemos.
>
> Fizemos também o que o requisito de serverless pede por inteiro: o `notifications-api` antigo saiu
> do compose, dos manifestos e do cluster, e o repositório está deprecado e arquivado — com um
> `DEPRECATED.md` explicando o port. Não deletamos de propósito: ele é a rastreabilidade da
> refatoração.
>
> Obrigado.

---

# O que NÃO falar

- **Não diga "o trace sempre fecha".** Ele fecha porque todos os publishers estão instrumentados; um
  publisher sem OpenTelemetry quebra a corrente. O script do Bloco 5 já diz isso do jeito certo.
- **Não prometa o span do MongoDB.** Ele não aparece — o driver 3.x exige um pacote de diagnóstico que
  a plataforma não usa.
- **Não prometa notificação no `docker compose`.** Ninguém consome as filas lá desde a remoção do
  `notifications-api`. O fluxo de notificação só é observável **no cluster**.
- **Não rode `kubectl rollout status` na `notifications-function`.** Ela está em zero réplica por
  desenho, e o comando espera para sempre por um pod que corretamente não existe.

# Duas armadilhas que estragam a tomada

1. **`./scripts/smoke-test.sh` apaga o usuário que cria.** Se rodar o smoke e depois procurar a
   notificação daquele usuário, não vai achar — e parece defeito. Use o Bloco 8, que preserva o
   usuário.
2. **Port-forward sem espera de prontidão** devolve `HTTP 000` e parece bug da aplicação. Use sempre o
   `until curl` da seção 0.2.
3. **O Bloco 6 não se repete com o mesmo usuário.** O índice unique é por par jogo + usuário: se a
   primeira tomada já gravou a avaliação, na segunda o *primeiro* `curl` devolve 409 e a demonstração
   inverte de sentido. O bloco já cria um usuário novo a cada execução — não troque por `$TOKEN`.

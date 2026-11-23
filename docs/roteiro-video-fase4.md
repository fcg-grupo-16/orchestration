# Roteiro do vídeo — Tech Challenge Fase 4 (Pitch Final)

**Script de narração.** Cada bloco tem **FALE** (texto para ler em voz alta) e **MOSTRE** (o que tem de
estar na tela). Os números das falas foram medidos no EKS em 2026-11-22; se a sua tomada der um valor
um pouco diferente, **fale o que aparecer na tela**.

**Limite: 25 minutos.** Grave em blocos e junte na edição. O deploy ao vivo leva ~5 minutos do merge
até a produção (medido: 4min30, sendo 3min35 de build e testes, 17 s de publicação no ECR e 35 s de
rolling update), mais ~2 minutos de checagem do PR antes do merge: ele **começa no Bloco 4 e termina no Bloco 8**, e os blocos de busca, cache e NoSQL são
gravados enquanto a pipeline roda. Na edição, corte as esperas.

| O que o PDF pede no vídeo | Onde |
|---|---|
| Infraestrutura na nuvem: painel da AWS e pods no Kubernetes | Blocos 2 e 3 |
| **Live Deploy**: alterar código, push, pipeline atualizando a produção sozinha | Blocos 4 e 8 |
| Busca Avançada | Bloco 5 |
| Impacto positivo do Cache na resposta da API | Bloco 6 |
| Como o NoSQL foi integrado à arquitetura | Bloco 7 |

---

# Parte 0 — Antes de ligar a câmera

## 0.1 A sessão do laboratório

1. No Canvas, **Start Lab**, e espere a bolinha verde. Confira no painel o **tempo restante**. A
   preparação abaixo leva ~40 minutos, e a gravação, uma hora. **Com menos de 2 horas, não comece.**
2. **AWS Details → Show**: cole as credenciais em `~/.aws/credentials`, seção `[academy]`.
3. Em **todo terminal** que for usar:

```bash
cd ~/Documents/dev/fiap/orchestration
export AWS_PROFILE=academy
```

## 0.2 Subir a plataforma (pule se já estiver no ar)

```bash
./scripts/terraform-init.sh
terraform -chdir=terraform apply           # digite yes; ~20 min
./scripts/publicar-segredos-aws.sh
CONSTRUIR_LOCAL=1 ./scripts/deploy-eks.sh  # ~10 min; termina com "OK: plataforma no ar em http://..."
```

**Ligue o deploy pelo CI.** Sem isso, o deploy ao vivo **não acontece**:

```bash
./scripts/atualizar-credenciais-ci.sh
```

As credenciais do CI são as da sessão do lab e **expiram com ela**. Se você clicar em Start Lab de
novo, rode esse script de novo.

## 0.3 Conferir antes de gravar

```bash
./scripts/verify-fase4.sh      # tem de terminar em "PRONTO PARA GRAVAR"
```

Ele também **indexa o seed** do catálogo no OpenSearch e **aquece** o `catalog-api`. A primeira
chamada depois de um pod subir já levou 75 s; não deixe isso acontecer na frente da câmera.

> ⚠️ **Não rode o `gateway-test.sh` antes de gravar.** Ele estoura de propósito o limite de 20
> logins por minuto, e a próxima tomada começa com 429.

## 0.4 Variáveis (cole em cada terminal)

```bash
export AWS_PROFILE=academy
export KUBECONFIG=~/.kube/fcg-eks
aws eks update-kubeconfig --name fcg --region us-east-1 --kubeconfig "$KUBECONFIG" > /dev/null
GW="http://$(kubectl -n kong get svc kong-kong-proxy -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

# O token expira em 15 MINUTOS. Rode `tk` no começo de cada bloco.
tk() { TOKEN=$(curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"email":"admin@fcg.com","senha":"Admin@123456"}' "$GW/api/v1/auth/login" | jq -r .token); echo "token renovado"; }
tk
JOGO=$(curl -s -H "Authorization: Bearer $TOKEN" "$GW/api/v1/jogos?pagina=1&tamanhoPagina=1" | jq -r '.itens[0].id')
echo "$GW  jogo=$JOGO"
```

> `KUBECONFIG` próprio de propósito: o contexto padrão do `kubectl` pode ser o minikube, e aí todo
> comando responde sobre o cluster errado.

## 0.5 O que deixar aberto

**Navegador**, nesta ordem de abas (região **N. Virginia / us-east-1**):

1. **EKS** → Clusters → `fcg` → aba **Compute** (node group `padrao`).
2. **EKS** → `fcg` → **Resources** → Workloads → Pods, namespace `fcg`.
3. **ECR** → Repositories, e depois `fcg/users-api` aberto (tags = SHA do commit, coluna de scan).
4. **Secrets Manager** → lista com os `fcg/...`.
5. **EC2** → Load Balancers (o NLB do Kong).
6. **GitHub** → `fcg-grupo-16/users-api` → **Actions**.
7. **GitHub** → `fcg-grupo-16/orchestration` → `.github/workflows/deploy-servico.yml`.

**VS Code** com duas pastas:
- `users-api`, aberto em `src/Fcg.Users.Api/Program.cs`, na linha do `const string versaoDaApi`;
- `orchestration`, com `terraform/eks.tf` e `k8s-aws/10-external-secrets.yaml` em abas.

**Terminais** (todos com o bloco 0.4 colado):

| # | Para quê |
|---|---|
| T1 | `kubectl` (pods, nós, rollout) |
| T2 | chamadas à API (busca, cache, NoSQL) |
| T3 | o **loop do deploy ao vivo** (Bloco 4) |
| T4 | o `git` do deploy ao vivo, dentro de `~/Documents/dev/fiap/users-api` |

Fonte do terminal grande (≥ 16 pt). Feche notificações.

---

# Parte 1 — O script

## Bloco 1 · 0:00–1:30 · Abertura

**MOSTRE:** README do `orchestration` no GitHub (diagrama de arquitetura), ou o VS Code.

**FALE:**

> Olá, este é o pitch final do grupo 16 da FIAP Cloud Games, a Fase 4.
>
> A plataforma já era distribuída e observável. Nesta fase atacamos três gargalos: produção
> gerenciada na nuvem, entrega automatizada e performance.
>
> A nuvem é a AWS, pela conta do AWS Academy fornecida pelo curso. Tudo roda num **EKS**, o
> Kubernetes gerenciado da AWS, provisionado por **Terraform**. As imagens ficam no **ECR**, os
> segredos no **Secrets Manager**, e a entrada é um **Network Load Balancer** na frente do Kong, que é
> o nosso API Gateway.
>
> Para dados: MongoDB para os dados flexíveis, Redis para o cache e OpenSearch para a busca. E a
> entrega é por GitHub Actions: o que está na `main` é o que está em produção.

---

## Bloco 2 · 1:30–4:30 · Infraestrutura gerenciada (painel da AWS)

**MOSTRE:** aba 1 (EKS → `fcg` → Compute).

**FALE:**

> Este é o cluster `fcg` no EKS, versão 1.37. O control plane é gerenciado pela AWS, e os nós vêm de
> um **node group gerenciado**: duas instâncias `t3.large`, em duas zonas de disponibilidade, em
> subnet privada. Nada aqui é instância avulsa rodando container na mão.

**MOSTRE:** T1:

```bash
kubectl get nodes -o wide
kubectl -n fcg get pods
```

**FALE:**

> Do lado do Kubernetes: os dois nós, e os pods da plataforma no namespace `fcg`. Os três serviços
> .NET, o MongoDB, os dois Redis, o RabbitMQ, o OpenSearch, e a observabilidade.
>
> Repare que a função de notificações **não tem pod**. É de propósito: ela é serverless, o KEDA a
> mantém em zero réplicas e só a acorda quando chega mensagem na fila. No EKS, ela acorda em uns 7
> segundos.

**MOSTRE:** aba 3 (ECR → repositórios), depois `fcg/users-api`.

**FALE:**

> As imagens ficam no ECR, o registry privado da AWS. Um repositório por imagem, e a tag é o **SHA do
> commit** que gerou a imagem: dá para rastrear qualquer pod até a linha de código.
>
> Os repositórios são **imutáveis**: uma tag não pode ser sobrescrita. E o ECR faz um **scan de
> vulnerabilidades** em todo push, que complementa a verificação de dependências que a pipeline já
> faz.

**MOSTRE:** aba 5 (EC2 → Load Balancers).

**FALE:**

> E a exposição: um Network Load Balancer, criado pelo próprio Kubernetes a partir do Service do Kong.
> Escolhemos o NLB, de camada 4, porque ele **preserva o IP do cliente**. O nosso rate limit é por IP,
> e um balanceador de camada 7 faria todo mundo parecer o mesmo cliente.

**MOSTRE:** VS Code, `orchestration/terraform/eks.tf`.

**FALE:**

> Tudo isso é Terraform: rede, cluster, nós, add-ons, registry e segredos. Sobe do zero com um
> `apply` e desce com um `destroy`.
>
> Um detalhe que vale contar: a conta do Academy **não permite criar roles de IAM**. Então o cluster e
> os nós usam as roles que o laboratório já fornece, e o módulo de EKS da comunidade não serviu, porque
> ele consulta o IAM de um jeito que o lab bloqueia. Escrevemos o cluster com os recursos diretos do
> provider.

---

## Bloco 3 · 4:30–6:30 · Segredos: zero credencial no código

**MOSTRE:** aba 4 (Secrets Manager).

**FALE:**

> Segurança. Nenhuma senha, connection string ou chave está no código ou nos YAML. Elas ficam aqui, no
> **AWS Secrets Manager**.

**MOSTRE:** T1:

```bash
kubectl -n fcg get externalsecret
```

**FALE:**

> E chegam ao cluster pelo **External Secrets Operator**: ele lê o Secrets Manager e cria os Secrets do
> Kubernetes, que os pods recebem como variável de ambiente na hora de subir. Os oito estão
> sincronizados.

**MOSTRE:** VS Code, `orchestration/k8s-aws/10-external-secrets.yaml`.

**FALE:**

> O manifesto só diz **de onde** ler, nunca o valor. E aqui tem um cuidado: a chave de assinatura do
> JWT precisa ser idêntica em três lugares, o serviço que emite o token, o que valida e o Kong. As três
> vêm da mesma origem, e o nosso script de verificação confere essa paridade sem imprimir nenhum valor.

---

## Bloco 4 · 6:30–9:30 · Live Deploy — parte 1: alterar, push e pipeline

**MOSTRE:** T3. Comece o loop **antes** de mexer no código, e deixe rodando até o Bloco 8:

```bash
while true; do
  [ $(( $(date +%s) % 300 )) -lt 2 ] && tk > /dev/null   # renova o token a cada ~5 min
  curl -s -o /dev/null -D - -H "Authorization: Bearer $TOKEN" "$GW/api/v1/usuarios?pagina=1&tamanhoPagina=1" \
    | tr -d '\r' | awk -v t="$(date +%H:%M:%S)" '/^HTTP/{c=$2} tolower($1)=="x-fcg-versao:"{v=$2} END{print t, c, v}'
  sleep 1
done
```

**FALE:**

> Agora o deploy ao vivo. Neste terminal, uma chamada por segundo ao serviço de usuários, pelo
> endereço público. Cada linha mostra o horário, o status HTTP e o header `X-Fcg-Versao`, que diz qual
> versão do binário respondeu. Agora é a `fase4-v1`.

**MOSTRE:** VS Code, `users-api/src/Fcg.Users.Api/Program.cs`. Troque `"fase4-v1"` por `"fase4-v2"`
e salve.

**FALE:**

> Vou mudar o código: a versão passa para `fase4-v2`.

**MOSTRE:** T4:

```bash
git switch main && git pull -q
git switch -c demo/fase4-v2
git commit -am "feat(api): versão fase4-v2 (deploy ao vivo da Fase 4)"
git push -u origin demo/fase4-v2
gh pr create --fill --base main
```

**FALE:**

> Commit, push, e o pull request. A `main` é protegida: nada entra sem pull request e sem a pipeline
> passar.

**MOSTRE:** aba 6 (Actions), o run do PR aberto.

**FALE:**

> Esta é a pipeline de integração. Ela compila, roda os testes de unidade e de integração, verifica
> dependências com vulnerabilidade conhecida, constrói a imagem Docker com a tag do commit e confere
> que o container sobe.

**MOSTRE:** T4, quando o check passar (corte a espera):

```bash
gh pr checks --watch
gh pr merge --squash --delete-branch
```

**FALE:**

> Passou. Faço o merge, e a partir daqui **eu não faço mais nada**. O push na `main` dispara a
> entrega.

**MOSTRE:** aba 6, o run da `main` com os jobs `build-and-test`, `Publicar a imagem no ECR` e
`deploy`.

**FALE:**

> Na `main`, depois do build e dos testes, o job de publicação envia a imagem para o ECR, e o de
> deploy chama um **workflow compartilhado** que fica no repositório de orquestração. Os quatro
> serviços usam o mesmo, em vez de cada um ter uma cópia. Enquanto isso roda, vamos às outras
> demonstrações, e voltamos aqui no final.

---

## Bloco 5 · 9:30–13:00 · Busca avançada

**MOSTRE:** T2:

```bash
tk
busca() { curl -s -H "Authorization: Bearer $TOKEN" --get --data-urlencode "q=$1" "$GW/api/v1/jogos/search" \
  | jq -c '.[] | {titulo, score: (.score*100|round/100)}'; }
busca "codequest"
busca "code quest"
busca "codequets"
```

**FALE:**

> Busca avançada. O endpoint `/search` consulta o **OpenSearch**, e não o MongoDB. São motores
> independentes.
>
> `codequest` acha o CodeQuest. `code quest`, separado, também: o título é indexado também com as
> palavras coladas, e a busca encontra. E `codequets`, com as letras trocadas, também: é o **fuzzy
> search**, que tolera até duas letras erradas.

**MOSTRE:**

```bash
busca "bug huntr"
busca "cyber shild"
busca "arena"
busca "xyzabc"
```

**FALE:**

> Outros erros de digitação: `bug huntr`, `cyber shild`. Cada resultado vem com o **score** de
> relevância e em ordem decrescente: título pesa mais que descrição. E `xyzabc`, que não existe, não
> devolve nada: lista vazia, e não erro.

**MOSTRE:** T2, a sincronização. Crie, ache, edite e remova:

```bash
ID=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"titulo":"Kubernetes Quest","descricao":"Jogo criado ao vivo.","genero":2,"preco":19.90,"dataLancamento":"2026-11-22T00:00:00Z"}' \
  "$GW/api/v1/jogos" | jq -r .id); echo "$ID"
busca "kubernets"
curl -s -o /dev/null -w 'PUT %{http_code}\n' -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"titulo":"Kubernetes Quest Deluxe","descricao":"Editado ao vivo.","genero":2,"preco":24.90}' "$GW/api/v1/jogos/$ID"
busca "deluxe"
curl -s -o /dev/null -w 'DELETE %{http_code}\n' -X DELETE -H "Authorization: Bearer $TOKEN" "$GW/api/v1/jogos/$ID"
busca "kubernets"
```

> O título é único: se for gravar de novo, troque `Kubernetes Quest` por outro nome.

**FALE:**

> E a sincronização. Crio um jogo, e ele já aparece na busca, mesmo com erro de digitação. Edito, e a
> edição aparece. Removo, e ele some.
>
> Quem faz isso é o `catalog-api`: toda escrita no banco também atualiza o índice. Se o OpenSearch
> estiver fora do ar, a escrita no banco **não falha**: fica registrado e um endpoint de reindexação
> reconstrói o índice a partir do banco.

**MOSTRE:** T1, o isolamento:

```bash
kubectl -n fcg run invasor --rm -i --restart=Never --image=curlimages/curl:8.11.1 --command -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://opensearch:9200 || echo "bloqueado"
```

**FALE:**

> Uma decisão para registrar: o enunciado sugere OpenSearch gerenciado, mas o serviço é **bloqueado na
> conta do AWS Academy**. Levamos isso ao professor, e a alternativa aceita foi rodar o OpenSearch
> dentro do cluster, com a mesma API. Migrar para o gerenciado depois é trocar um endereço.
>
> Para compensar o isolamento que o serviço gerenciado daria, há uma NetworkPolicy: **só o
> catalog-api** fala com o OpenSearch. Esse pod qualquer tentou, e foi bloqueado.

---

## Bloco 6 · 13:00–15:30 · O impacto do cache

**MOSTRE:** T2:

```bash
lat() { curl -s -o /dev/null -D - -H "Authorization: Bearer $TOKEN" "$1" | tr -d '\r' \
  | awk -F': ' 'tolower($1)=="x-kong-upstream-latency"{print $2" ms"}'; }
TP=$((100 + RANDOM % 800))
echo "1ª (vai ao MongoDB):  $(lat "$GW/api/v1/jogos?pagina=1&tamanhoPagina=$TP")"
echo "2ª (vem do Redis):    $(lat "$GW/api/v1/jogos?pagina=1&tamanhoPagina=$TP")"
```

> Rode duas ou três vezes, cada vez com um `TP` novo (a linha do `TP` sorteia um tamanho de página
> que ninguém pediu ainda, então a primeira chamada é sempre sem cache).

**FALE:**

> O cache. Duas chamadas iguais ao catálogo. A primeira vai ao MongoDB, a segunda vem do **Redis**.
>
> Eu meço pelo header `X-Kong-Upstream-Latency`, o tempo que o serviço levou visto pelo gateway, e não
> pelo tempo total. Daqui do Brasil até a Virgínia a rede soma uns 280 milissegundos, e isso esconderia
> a diferença.
>
> Nas nossas medições, **entre 15 e 28 milissegundos sem cache, e entre 4 e 8 com cache**: três a
> quatro vezes mais rápido, e uma consulta a menos no banco a cada acerto. Com um catálogo de cinco jogos a diferença absoluta é
> pequena; ela cresce com o volume, porque o custo do Redis não depende do tamanho da consulta.

**MOSTRE:** T1:

```bash
kubectl -n fcg exec deploy/redis -- redis-cli --scan --pattern 'fcg:catalog:*' | head
```

**FALE:**

> As chaves no Redis. Repare no `g` com um número no nome: é a **geração** do cache. Quando um jogo
> muda, em vez de procurar e apagar chaves, a aplicação incrementa a geração. As consultas seguintes
> passam a usar chaves novas, e as antigas expiram sozinhas. Invalidar é uma operação só, de custo
> constante.
>
> Foi isso que vimos agora há pouco: o jogo que eu criei apareceu na listagem na hora, sem esperar o
> cache vencer.

---

## Bloco 7 · 15:30–19:00 · NoSQL na arquitetura

**MOSTRE:** T2, cole o bloco inteiro (usuário novo a cada tomada):

```bash
EA="avaliador-$(date +%s)@fcg.com"
curl -s -o /dev/null -X POST -H 'Content-Type: application/json' \
  -d "{\"nome\":\"Avaliador\",\"email\":\"$EA\",\"senha\":\"Senha@123456\"}" "$GW/api/v1/usuarios"
TA=$(curl -s -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EA\",\"senha\":\"Senha@123456\"}" "$GW/api/v1/auth/login" | jq -r .token)
curl -s -o /dev/null -w 'avaliacao: %{http_code}\n' -X POST -H "Authorization: Bearer $TA" -H 'Content-Type: application/json' \
  -d "{\"jogoId\":\"$JOGO\",\"nota\":5,\"titulo\":\"Ótimo\",\"comentario\":\"muito bom\",\"tags\":[\"rpg\",\"educativo\"],\"contexto\":{\"plataforma\":\"PC\",\"horasJogadas\":\"42\"}}" \
  "$GW/api/v1/avaliacoes"
curl -s -o /dev/null -w 'duplicada: %{http_code}\n' -X POST -H "Authorization: Bearer $TA" -H 'Content-Type: application/json' \
  -d "{\"jogoId\":\"$JOGO\",\"nota\":1,\"titulo\":\"De novo\",\"comentario\":\"x\",\"tags\":[]}" "$GW/api/v1/avaliacoes"
```

**FALE:**

> NoSQL. O MongoDB entra na arquitetura de duas formas.
>
> A primeira, e a que o desafio pede, é o **sistema de avaliações** de jogos, com o driver oficial,
> o `MongoDB.Driver`. Criei uma avaliação: 201. Repare no corpo: `tags` é uma lista, e `contexto` é um
> sub-documento **sem esquema fixo**. Cada avaliação pode trazer um contexto diferente sem migração
> de banco. É o caso clássico de dado flexível.
>
> Em seguida, o mesmo usuário avaliando o mesmo jogo de novo: 409. Quem recusou foi o **banco**, por
> um índice único no par jogo e usuário, e não um `if` na aplicação. Validação na aplicação deixa
> brecha quando duas requisições chegam juntas; o índice não deixa.

**MOSTRE:** T1:

```bash
kubectl -n fcg exec -it mongodb-0 -c mongosh -- mongosh --quiet --host 127.0.0.1 catalogdb \
  --eval 'printjson(db.avaliacoes.getIndexes().map(i => i.name)); printjson(db.avaliacoes.find({Tags: {$size: 2}}, {_id:0, Nota:1, Tags:1, Contexto:1}).sort({_id:-1}).limit(1).toArray())'
```

**FALE:**

> Os índices, com o único que acabou de recusar. E o documento como ele está no banco.

**MOSTRE:** T2:

```bash
curl -s -H "Authorization: Bearer $TOKEN" "$GW/api/v1/jogos/$JOGO/avaliacoes/resumo" | jq
```

**FALE:**

> E o resumo de notas é calculado **no banco**, por um aggregation pipeline, sem trazer as avaliações
> para a memória da aplicação. Esse resumo também passa pelo cache.
>
> A segunda forma é estrutural: cada serviço tem o **seu próprio database** no MongoDB, e o outbox
> transacional do MassTransit grava o evento na mesma transação do dado. É por isso que o MongoDB roda
> como replica set, mesmo com um nó só: transação no Mongo exige replica set.

---

## Bloco 8 · 19:00–22:00 · Live Deploy — parte 2: a produção atualizada

**MOSTRE:** aba 6, o run da `main` concluído (os três jobs verdes). Abra o job `deploy`, passo
"Espera o rollout".

**FALE:**

> Voltando ao deploy. A pipeline terminou: build, testes, imagem publicada no ECR e o deploy, que
> fez um **rolling update** e depois verificou a saúde do serviço de dentro do cluster.

**MOSTRE:** T3 (o loop). Role até o ponto em que a versão muda.

**FALE:**

> E aqui está a prova, de fora do cluster. Durante todo o deploy, chamadas seguidas ao serviço. A
> versão passou de `fase4-v1` para `fase4-v2`, e **todas** as respostas foram 200: nenhuma requisição
> perdida. No ensaio, foram 152 chamadas durante o deploy, todas 200.
>
> Isso é configuração, não sorte. O Kubernetes sobe o pod novo, espera ele ficar pronto, e só então
> tira o antigo. E o pod que sai espera dez segundos antes de encerrar, para o gateway parar de mandar
> tráfego para ele antes do desligamento.

**MOSTRE:** T1:

```bash
kubectl -n fcg get deploy users-api -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n fcg rollout history deploy/users-api
```

**MOSTRE:** aba 3 (ECR, `fcg/users-api`): a tag nova no topo.

**FALE:**

> A imagem em produção é a tag com o SHA do commit que eu acabei de fazer, a mesma que está no ECR.
> Do código à produção sem nenhum comando manual: o que está na `main` é o que está rodando.

---

## Bloco 9 · 22:00–24:00 · Fechamento

**FALE:**

> Fechando. Os três gargalos da fase:
>
> **Produção gerenciada**: EKS com nós gerenciados, provisionado por Terraform, imagens no ECR,
> segredos no Secrets Manager e entrada por Load Balancer.
>
> **Entrega automatizada**: build, teste, verificação de vulnerabilidades, imagem com a tag do commit,
> publicação e rolling update sem indisponibilidade, como acabamos de ver.
>
> **Performance**: MongoDB para os dados flexíveis, Redis com invalidação por geração, e OpenSearch
> para a busca com tolerância a erro e relevância.
>
> E as limitações, que são conscientes e estão documentadas nas ADRs: o OpenSearch roda no cluster
> porque o serviço gerenciado é bloqueado no laboratório, com o aval do professor; o pipeline usa as
> credenciais de sessão do laboratório, porque ele não permite a federação OIDC, que seria o desenho
> de produção; e o endereço é o do Load Balancer, em HTTP, porque não há domínio próprio.
>
> O ambiente é destruído ao fim de cada dia de uso, por um script, porque o orçamento do laboratório é
> fixo. Os links dos repositórios e da documentação estão no relatório. Obrigado.

**MOSTRE:** README do `orchestration` (seções de ADRs e da infraestrutura na AWS).

---

# Depois de gravar

```bash
# no terminal T3: Ctrl+C no loop
./scripts/terraform-destroy.sh                     # digite yes; ~15 min
DESLIGAR=1 ./scripts/atualizar-credenciais-ci.sh   # o CI para de tentar publicar
```

Na próxima gravação, a versão no `Program.cs` já é `fase4-v2`: mude para `fase4-v3`.

---

# O que NÃO falar

- **"OpenSearch gerenciado"**: no nosso caso, ele roda no cluster. Fale sempre "OpenSearch no cluster, com
  aval do professor".
- **"OIDC" como se estivesse em uso**: o CI usa as credenciais de sessão do laboratório.
- **"Alta disponibilidade"**: os serviços têm uma réplica, e o OpenSearch é nó único. O que o vídeo
  prova é o **rolling update sem indisponibilidade**, que é outra coisa.
- **Números que não apareceram na sua tela.** Se o cache der 12 → 5 em vez de 15 → 4, fale 12 e 5.

# Armadilhas que estragam a tomada

| Sintoma | Causa | O que fazer |
|---|---|---|
| 401 em tudo no meio do bloco | o token expira em 15 min | rode `tk` |
| 429 no login | `gateway-test.sh` ou logins demais no último minuto (limite 20/min) | espere 1 minuto |
| `kubectl` responde "not found" ou sobre o minikube | sem o `KUBECONFIG` do bloco 0.4 | cole o bloco 0.4 de novo |
| a busca não acha nada do seed | índice vazio depois de subir | rode o `verify-fase4.sh` (ele reindexa) |
| a primeira chamada (ou o primeiro login) leva dezenas de segundos | serviço frio, recém-subido: o primeiro login depois do deploy levou ~1 min no ensaio | `verify-fase4.sh` antes de gravar aquece |
| o job `Publicar a imagem no ECR` aparece **skipped** | o deploy pelo CI está desligado | `./scripts/atualizar-credenciais-ci.sh` |
| o job de deploy falha na autenticação | a sessão do lab foi renovada e o CI tem a credencial velha | `./scripts/atualizar-credenciais-ci.sh` |
| `X-Fcg-Versao` vazio no loop | a `main` do `users-api` ainda não tem o header | confira se o PR do header (#38) está mergeado e implantado |
| o endereço `$GW` não responde | o Load Balancer muda a cada `deploy-eks.sh` | recalcule `GW` (bloco 0.4) |

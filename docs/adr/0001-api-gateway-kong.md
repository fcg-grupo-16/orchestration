# ADR 0001 — Kong Ingress Controller como única porta de entrada

- **Status:** aceito
- **Data:** 2026-09-13
- **Issue:** [#26](https://github.com/fcg-grupo-16/orchestration/issues/26)

## Contexto

Até a Fase 2 a plataforma expunha **dois hosts** por um Ingress NGINX (`users.fcg.local` e
`catalog.fcg.local`), e cada serviço validava o próprio JWT. Não havia ponto único para aplicar
política: rate limit, correlação de requisições e autenticação de borda teriam de ser reimplementados
em cada serviço, e um serviço novo entraria sem nenhuma dessas garantias por omissão.

A Fase 3 exige um **API Gateway** como porta de entrada da plataforma.

## Decisão

**Kong Ingress Controller 3.x em modo DB-less**, instalado por Helm com o chart **pinado em 3.4.1**
(KIC 3.5, Kong 3.9.3), servindo o host único **`api.fcg.local`**.

- A configuração do gateway vem **100% de CRDs versionados** em `k8s/gateway/` — `KongPlugin`,
  `KongConsumer` e três `Ingress` —, nunca de uma Admin API mutável. O que está no git é o que está
  no cluster.
- O plugin **`jwt`** valida o token **na borda**: sem token válido a requisição recebe 401 **antes**
  de sair do gateway. O `KongConsumer` referencia um Secret rotulado `konghq.com/credential: jwt`,
  cujo segredo é **byte a byte idêntico** ao `JwtSettings__SecretKey` de `users-api` e `catalog-api`.
- O plugin **`rate-limiting`** aplica limite **por IP** (`limit_by: ip`), com teto mais apertado nas
  rotas públicas de cadastro e login.
- O **Ingress NGINX foi removido**, e o `deploy-minikube.sh` apaga o `fcg-ingress` legado
  explicitamente: `kubectl apply` nunca deleta um objeto cujo manifesto saiu do diretório, então
  apagar o arquivo do git não bastaria — em qualquer cluster que já tenha rodado a `main`, o Ingress
  antigo continuaria servindo as rotas **sem** validar JWT, em paralelo ao Kong, e o critério "porta
  de entrada única" seria falso.

## Consequências

- **O contrato observável mudou.** `GET /api/v1/jogos` é `[AllowAnonymous]` **no serviço**, mas a
  **borda exige token**: 200 anônimo no compose, 401 no cluster. Um cliente escrito contra o compose
  pode quebrar no cluster. É deliberado — o gateway é a fronteira de segurança —, mas está
  documentado no README para não surpreender ninguém.
- `/health*` e `/metrics` **não** são expostos pelo gateway; o Prometheus raspa os pods por dentro do
  cluster.
- O `kubeconform` do CI valida os CRDs do Kong contra o catálogo da comunidade, mas o schema do
  `KongPlugin` trata `config` como objeto livre — **um typo dentro de `config` passa verde**. Por
  isso existe o `scripts/gateway-test.sh`, com 17 asserções comportamentais contra o cluster.
- Como o `externalTrafficPolicy` é `Cluster`, há SNAT: o teste de isolamento do rate limit precisa de
  **dois pods com IPs distintos** para ser honesto — medir de um cliente só não prova isolamento.

## Alternativas descartadas

- **Azure APIM / AWS API Gateway** — gateways gerenciados, com custo e dependência de conta em nuvem.
  A entrega precisa subir offline, num minikube, em qualquer máquina do grupo.
- **Manter o Ingress NGINX e validar JWT em cada serviço** — é o estado da Fase 2; não atende ao
  requisito de gateway e espalha a política de segurança por todos os repositórios.
- **Kong com banco (modo tradicional)** — exigiria Postgres só para guardar configuração que já está,
  melhor versionada, no git.

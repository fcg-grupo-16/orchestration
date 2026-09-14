# ADR 0005 — Cache em Redis com invalidação por geração de chave

- **Status:** aceito
- **Data:** 2026-09-13
- **Issues:** [#25](https://github.com/fcg-grupo-16/orchestration/issues/25),
  [catalog-api#21](https://github.com/fcg-grupo-16/catalog-api/issues/21)

## Contexto

A Fase 3 exige **cache distribuído**. A listagem do catálogo é o caso óbvio: é a rota mais lida da
plataforma, o conteúdo muda pouco, e a resposta é paginada e filtrável — ou seja, **uma família de
chaves** por combinação de página, tamanho e gênero, e não uma chave só.

O problema real não é cachear; é **invalidar**. Quando um jogo muda, todas as páginas e todos os
filtros que continham aquele jogo ficam obsoletos de uma vez.

## Decisão

**Redis 7.4.1**, acessado por `IDistributedCache` + `StackExchange.Redis`, com **invalidação por
geração de chave**.

- Isolamento entre serviços é **lógico, por prefixo**: `Redis__InstanceName` vale `fcg:users:` na
  `users-api` e `fcg:catalog:` na `catalog-api`. Uma instância, dois espaços de nome.
- Cada grupo cacheável tem um contador de **geração**, e a geração entra na chave:
  - `jogos:lista:g{geracao}:p{pagina}:t{tamanho}:gen{genero}`
  - `avaliacoes:lista:g{geracao}:{jogoId}:p{pagina}:t{tamanho}`
- Invalidar é **incrementar o contador**: `INCR` numa chave, operação O(1). Todas as chaves da
  geração anterior deixam de ser consultadas no mesmo instante e expiram sozinhas pelo TTL. Nada é
  varrido, nada é apagado em massa.
- TTLs por natureza do dado: listagem de jogos **60s**, jogo individual **10min**, resumo de
  avaliações **120s**, listagem de avaliações **30s**; o padrão do serviço é **120s**.

## Consequências

- A invalidação é **atômica e barata**, e não cresce com o tamanho do cache.
- O custo é **lixo residual**: as chaves da geração antiga continuam ocupando memória até expirarem.
  Com os TTLs acima, isso é segundos a minutos — trade-off deliberado contra varredura.
- O cache dos serviços é **fail-open**: se o Redis cair, a requisição vai ao banco e a plataforma
  continua respondendo, mais devagar. Cache indisponível não pode virar indisponibilidade.
- ⚠️ **O store de idempotência da `notifications-function` é o oposto — fail-CLOSED** (`SET NX EX`
  atômico; sem Redis, a Function recusa processar). São dois usos do mesmo Redis com exigências
  contrárias, e confundi-los reintroduziria e-mail duplicado. A consequência de o Redis desta demo ser
  **volátil, sem AOF/RDB**, está registrada na issue #35.
- `verify-fase3.sh` reporta "nenhuma chave `fcg:catalog:*`" como **aviso**, não falha: zero chaves é
  ambíguo — pode ser cache quebrado ou catálogo simplesmente não exercitado ainda.

## Alternativas descartadas

- **`KEYS`/`SCAN` + delete em massa** — o `IDistributedCache` não tem invalidação por padrão, e
  `KEYS` é **O(n) e bloqueante** no Redis: aceitável num cache de demonstração, desastroso em
  produção. `SCAN` não bloqueia, mas é iterativo e não atômico — durante a varredura convivem chaves
  novas e velhas.
- **Cache em memória por instância (`IMemoryCache`)** — não é distribuído: com duas réplicas, cada
  uma responderia de um estado diferente, e o requisito pede cache distribuído.
- **Cachear no gateway (plugin `proxy-cache` do Kong)** — cacheia a resposta HTTP inteira, mas o
  gateway não sabe quando um jogo mudou; a invalidação continuaria sendo o problema não resolvido.

# ADR 0004 — Avaliações em MongoDB com o driver nativo

- **Status:** aceito
- **Data:** 2026-09-13
- **Issue:** [catalog-api#20](https://github.com/fcg-grupo-16/catalog-api/issues/20)

## Contexto

A Fase 3 exige demonstrar **persistência NoSQL**. O MongoDB já era o store primário da plataforma
desde a Fase 2 (um database por serviço: `usersdb`, `catalogdb`, `paymentsdb`, `notificationsdb`),
mas o acesso acontecia por repositórios CRUD — o que não exercita nada que seja **próprio** de um
banco de documentos. Trocar de banco só para "mostrar NoSQL" seria trocar o problema pelo teatro.

## Decisão

Implementar a feature de **avaliações de jogos** na collection `catalogdb.avaliacoes` usando o
**driver nativo `MongoDB.Driver`**, e não um ORM, escolhendo deliberadamente um caso de uso que só é
confortável em documento:

- **Documento flexível.** Além de `JogoId`, `UsuarioId`, `Nota`, `Comentario` e `Titulo`, a avaliação
  carrega `Tags` (lista livre) e `Contexto` (sub-documento chave/valor arbitrário, ex.:
  `{"plataforma":"PC","horasJogadas":"42"}`). Campos que ainda não existem entram aí **sem migração
  de schema** — é exatamente o ponto do modelo de documento.
- **Aggregation pipeline** para o resumo (`GET /api/v1/jogos/{jogoId}/avaliacoes/resumo`): média das
  notas e distribuição por nota, calculadas **no servidor**, não na aplicação.
- **Índices compostos**, criados no startup por `GarantirIndicesAsync`:
  - `ix_jogo_data` — listagem paginada por jogo, ordenada por data;
  - `ux_jogo_usuario` — **unique**, que faz o banco garantir "um usuário avalia um jogo uma vez"
    (409 no segundo POST), em vez de deixar a regra a cargo de uma verificação de aplicação sujeita a
    corrida.
- **Limites validados na borda**, para "flexível" não virar "cliente grava 10 MB de lixo": nota de 1
  a 5, comentário até 4000 caracteres, no máximo 10 tags, no máximo 20 chaves em `contexto`, chave
  até 50 e valor até 500 caracteres.

## Consequências

- A criação de índices é **best-effort** (envolta em `catch`): uma falha ali não impede o serviço de
  subir. Em compensação, "a coleção existe" **não** significa "a feature está no ar" — por isso o
  `scripts/verify-fase3.sh` confere os **nomes dos índices**, e não a existência da collection. Foi o
  que expôs, no cluster, um `catalog-api` servindo binário antigo (issue #40).
- O unique index é a única defesa real contra avaliação duplicada sob concorrência.
- O trace do Mongo **não** aparece no Jaeger: o driver 3.x só emite as activities com
  `DiagnosticsActivityEventSubscriber` explicitamente configurado, e sem isso um `AddSource` com o
  nome do source é silenciosamente ignorado. Está documentado no código para ninguém "consertar" o
  `AddSource` achando que resolve.

## Alternativas descartadas

- **Trocar por outro banco NoSQL** (DynamoDB, Cosmos) — acrescentaria dependência de nuvem a uma
  entrega que precisa subir offline, sem ganho para o requisito.
- **Manter só CRUD via repositório** — atende ao "usamos MongoDB", mas não demonstra nada específico
  de NoSQL: nem documento flexível, nem aggregation, nem índice composto.
- **Modelar avaliações como sub-documento dentro de `jogos`** — cresceria o documento do jogo sem
  limite e tornaria a paginação por avaliação desconfortável; o limite de 16 MB por documento viraria
  um teto real num jogo popular.

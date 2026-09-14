# ADR 0007 — Consulta de contato serviço-a-serviço, com chave de assinatura própria

**Status:** aceito · **Data:** 2026-09-14 · **Issue:** [notifications-function#9](https://github.com/fcg-grupo-16/notifications-function/issues/9)

## Contexto

A confirmação de compra era endereçada ao **`UserId`**, não a um e-mail:

```
[E-mail] Para: 6aa0d1c10c0877de36606c1e | Assunto: Confirmação de compra
```

O `PaymentProcessedEvent` não carrega endereço — só `OrderId`, `UserId`, `GameId`, `Price` e
`Status`. Enquanto o envio é simulado por log, isso é inofensivo; com um SMTP real, a confirmação
não chegaria a ninguém.

A issue listava três caminhos:

| | Custo |
|---|---|
| **A.** enriquecer o `PaymentProcessedEvent` | contrato byte-idêntico em quatro repositórios; e o `payments-api` também não tem o e-mail |
| **B.** a Function consultar o `users-api` | acoplamento síncrono de um componente serverless |
| **C.** propagar desde o `catalog-api` | espalha dado pessoal por mais um evento e mais um serviço |

## Decisão

**Opção B**, com um endpoint **interno e dedicado**, e com **chave de assinatura própria** para
tokens de serviço.

### Por que um endpoint novo, e não o `GET /api/v1/usuarios/{id}`

O endpoint existente exige token **e** chama `ValidarAcessoAoRecurso`, que só permite ler o
**próprio** id — salvo administrador. A Function não tem identidade de usuário, então usá-lo
implicaria dar-lhe privilégio administrativo.

O endpoint novo devolve **um único campo**:

```
GET /api/v1/usuarios/{id}/contato   →   { "email": "..." }
```

O `UsuarioResponseDto` traria nome, tipo, data de criação e status — dado que quem só precisa
despachar um e-mail não tem por que receber.

### Por que chave própria, e não a `JwtSettings:SecretKey`

Esta é a parte que mais importa. A chave dos usuários é **compartilhada** entre `users-api`,
`catalog-api` e a credencial `fcg-jwt-credential` do Kong (paridade tríplice). Quem a possui assina
**qualquer** token, inclusive com a role `Administrador`. Entregá-la à Function para que ela leia um
e-mail converteria um componente serverless em portador de credencial administrativa da plataforma —
e o "menor privilégio" do endpoint seria ilusório.

Com `ServiceAuth:SecretKey` separada, o pior caso de vazamento do segredo da Function é o acesso aos
endpoints de serviço: hoje, uma consulta que devolve um campo.

A separação foi verificada nos **três** validadores da plataforma:

| validador | resultado com um token de serviço |
|---|---|
| `users-api`, esquema padrão | rejeita — chave diferente |
| `catalog-api` | rejeita — registra um único esquema, com a chave dos usuários |
| Kong (plugin `jwt`) | rejeita — casa credencial por `iss`, e não existe credencial para `FiapCloudGames.Servicos` |

O `users-api` **recusa subir** se `ServiceAuth:SecretKey` for igual a `JwtSettings:SecretKey`: subir
com a separação desfeita em silêncio seria pior que não subir.

### A role `Servico` é inalcançável por login

A role dos usuários sai de `usuario.Tipo.ToString()`, e o enum `TipoUsuario` só produz `Usuario` e
`Administrador`. Nenhum login emite um token com a role `Servico`, mesmo com a chave dos usuários em
mãos. A política também **prende o esquema** (`AuthenticationSchemes`), senão um token de usuário
com a role certa passaria.

## Consequências

- **Acoplamento síncrono**, que era o custo conhecido da Opção B. Mitigado com cache no Redis (o de
  idempotência, já dedicado e durável — ADR 0006), timeout curto e uma política de falha que **não**
  derruba o processamento da mensagem.

  A política acabou com **dois** casos, e o segundo não era previsto quando este ADR foi escrito —
  saiu de uma medição. Na primeira prova ponta a ponta, o `smoke-test.sh` apagou o usuário que ele
  mesmo havia criado, e a `notifications-function` gastou as cinco tentativas batendo no mesmo 404:

  | Falha | Comportamento | Porquê |
  |---|---|---|
  | `users-api` fora, lento ou com erro | a exceção **sobe** | transitória: o host reentrega e, no limite, manda para a dead-letter. Entre adiar e perder em silêncio, adiamos |
  | Usuário inexistente (**404**) | `Warning` e **segue** (ack) | determinística: reentregar bate no mesmo 404 até a DLQ, e quem não existe nunca vai ter e-mail |
- **Mais um segredo no contrato**: `ServiceAuth__SecretKey`, idêntico em `users-api-secret` e
  `notifications-function-secret`, e obrigatoriamente diferente do `JwtSettings__SecretKey`.
- **Configuração ausente devolve 401, não 500.** O `ServiceAuth` é opcional no startup, porque a
  configuração dele mora neste repositório e a imagem do `users-api` pode ser implantada antes —
  exigi-la derrubaria o serviço inteiro em vez de indisponibilizar um endpoint. Medido: com a
  política apontando para um esquema ausente, a aplicação sobe mas o endpoint responde **500**; com
  o esquema sempre registrado e uma chave que nada valida, responde **401**. 5xx por configuração
  faltando contaminaria a taxa de erro, que é um dos painéis obrigatórios da Fase 3.

## Alternativas descartadas

- **Token de serviço com a chave compartilhada** — mais simples, mas concede privilégio
  administrativo amplo a um componente serverless. Foi o que motivou este ADR.
- **Token com `subject` do próprio usuário consultado** — passaria pelo `ValidarAcessoAoRecurso` sem
  role administrativa, mas é personificação: difícil de justificar e pior de auditar.
- **Opções A e C da issue** — descartadas pelo custo de contrato e pelo espalhamento de PII.

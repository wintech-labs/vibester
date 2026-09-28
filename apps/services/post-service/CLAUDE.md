# Post Service

> Contexto específico do microserviço de posts (publicações, curtidas, comentários) do Vibester.
> Este documento complementa o `CLAUDE.md` da raiz do monorepo. Em caso de conflito, o `CLAUDE.md` raiz prevalece nas diretrizes gerais de produto/arquitetura; este arquivo prevalece em convenções específicas deste serviço. Código-fonte é sempre a fonte de verdade final.
>
> **Atenção**: este serviço é o mais diferente dos três já documentados (`auth-service`, `user-service`, `establishment-service`). Não usa PostgreSQL/Prisma — usa **Cassandra** (DataStax Astra) com modelagem "query-first" (tabelas denormalizadas por padrão de leitura). Não tem `AppError`, tem `HttpError`. Não tem nenhuma autenticação (nem JWT registrado). Não copie convenções de outro serviço para cá sem verificar contra o código deste diretório.

---

## Responsabilidade do Serviço

O `post-service` é responsável exclusivamente por:

- criação, leitura, atualização de legenda e remoção (soft delete) de posts (`Post`);
- listagem paginada de posts por usuário e por estabelecimento;
- curtidas (`PostLike`): curtir/descurtir e listar curtidas por post/usuário;
- comentários (`Comment`): criar, listar, editar e remover (soft delete);
- geração de URLs pré-assinadas para upload direto de mídia (imagem e vídeo) ao Cloudflare R2 — cada URL é assinada com o `contentType` do arquivo, ver [`docs/midias-no-post.md`](docs/midias-no-post.md).

Ele **não** possui dados "vivos" de perfil de usuário ou de estabelecimento — cada post guarda uma cópia denormalizada (`userUsername`, `userProfilePicture`, `userVerified`, `establishmentName`, `establishmentLogo`, `establishmentCategory`) recebida no momento da criação, sem sincronização posterior. Se esses dados mudarem no `user-service`/`establishment-service`, os posts já criados **não** são atualizados automaticamente — não assuma que essas cópias estão sempre em dia.

Nunca adicione regras de negócio de autenticação, perfil, feed (agregação/ranqueamento) ou estabelecimento aqui. Se uma feature parece pertencer a outro domínio, ela deve ser feita no serviço correspondente e comunicada via Kafka.

**Exceção única à regra acima**: a criação e a edição de post consultam o `post-validation-service` por HTTP síncrono antes de gravar (ver "Validação de conteúdo"). É a única chamada síncrona que este serviço faz a outro, e existe porque o autor precisa saber que o texto foi recusado **antes** de o post existir — um evento Kafka só avisaria depois de publicado, com o conteúdo já no ar.

---

## Stack e Dependências deste Serviço

- Fastify 5 + `@fastify/cors` (`origin: true`, aberto para qualquer origem — diferente dos outros serviços, que restringem ou desabilitam CORS), `@fastify/helmet` (com `contentSecurityPolicy: false`), `@fastify/compress`, `@fastify/rate-limit` (global, em memória), `@fastify/multipart` (registrado com limites de 10MB/20 arquivos, mas **nenhuma rota usa `request.file()`/`request.parts()` hoje** — configuração morta, ver Segurança).
- **Cassandra** (`cassandra-driver`) apontando para **DataStax Astra** via secure connect bundle (`src/config/cassandra.ts`) — este é o banco principal do serviço, **não** PostgreSQL/Prisma como nos outros três serviços já documentados. Modelagem é "query-first": uma tabela por padrão de acesso (`posts_by_id`, `posts_by_user`, `posts_by_establishment`, etc.), não normalizada.
- Migrations são arquivos `.cql` em `migrations/` (`V00N__nome.cql`), aplicadas por um runner próprio (`scripts/migrate.ts`), que registra versões executadas numa tabela `schema_migrations` no próprio keyspace — não é Prisma Migrate.
- Redis (`ioredis`) — usado só para **cache-aside** de leitura (`cacheAside` em `src/config/redis.ts`); o rate limit **não** usa Redis como store (fica em memória local do processo — ver Segurança/Performance sobre o impacto disso ao escalar horizontalmente).
- Kafka (`kafkajs`) — **produtor apenas** (`src/kafka/producer.ts`, singleton lazy que faz `require("kafkajs")` dentro da função em vez de import no topo — não replique esse padrão sem necessidade, é inconsistente com o resto do arquivo que já usa `import type`); tópicos publicados: `posts` (`post.created`, `post.content.updated`, `post.deleted`, `post.stats.updated`), `post.liked`, `post.unliked`, `post.commented`. Consome dois tópicos, no grupo `post-service-group`: `user.deleted` (ver "Exclusão de conta" no fim deste arquivo) e `post.validation.rejected` (ver "Ocultação pela moderação de imagem"). Publica também `post.moderation.hidden`. **Todo publish passa por `publishEvent(topic, key, eventType, data)` em `src/kafka/events.ts`** — é o único ponto que monta o envelope (`eventId`/`eventType`/`occurredAt`/`data`); nunca chame `producer.send(...)` direto num service nem monte esse envelope na mão, senão volta a divergir entre services como antes dessa unificação.
- `@aws-sdk/client-s3` + `@aws-sdk/s3-request-presigner` — geração de URLs pré-assinadas (PUT) para o cliente subir a imagem direto no R2 (`src/config/r2.ts`, `src/services/upload.service.ts`). É o único fluxo de upload de fato exposto por rota hoje.
- `sharp` — usado só dentro de `UploadService.uploadImages` (redimensiona para 1080px e converte para `.webp`), mas **esse método não é chamado por nenhum controller/rota** — é código morto hoje (só há teste para `generatePresignedUrls`, não para `uploadImages`). Se for implementar upload via multipart no futuro, reaproveite esse método em vez de escrever um novo.
- `zod` é usado para: validação de env (`src/config/env.ts`), validação de `params` dentro dos controllers (`postIdParamsSchema`, `userIdParamsSchema`, `establishmentIdParamsSchema`, `generateUploadUrlsSchema` em `src/schema/post.schema.ts`, chamados via `.parse()`). O body das rotas de escrita passa por **duas camadas**: primeiro o JSON Schema do Fastify em `routes.ts` (forma e tipos), depois Zod no controller para as regras que o JSON Schema não expressa — em `POST /posts` e `POST /posts/upload-url`, `createPostSchema`/`generateUploadUrlsSchema` validam o vínculo entre campos (`media` **ou** `imageUrls`, `contentType` compatível com `type`), que a URL da mídia pertence ao bucket, e normalizam o formato legado para o novo. Ao mexer num, confira o outro: o Fastify roda antes e um `required` desatualizado rejeita o payload antes do Zod ver.
- `fetch` nativo do Node (sem client HTTP novo) para a chamada ao `post-validation-service` em `src/clients/validation.client.ts` — timeout por `AbortController`, ver "Validação de conteúdo".
- Vitest para testes (unit co-localizado em `__tests__` + integration em `tests/integration`), `ioredis-mock` disponível como dependência de teste.

Não introduza um ORM alternativo, outro cliente Redis/Kafka/S3, nem volte a usar PostgreSQL/Prisma neste serviço sem alinhar com o time — reutilize o que já existe.

---

## Estrutura de Pastas

```
src/
  clients/       validation.client.ts                                           → HTTP para o post-validation-service (única chamada síncrona a outro serviço)
  config/        cassandra.ts, redis.ts (cacheAside), r2.ts, env.ts, swagger.ts
  controller/    post.controller.ts, like.controller.ts, comment.controller.ts   → classes, métodos bind() registrados em routes.ts
  services/      post.service.ts, like.service.ts, comment.service.ts, upload.service.ts
    __tests__/                                                                    → testes unitários co-localizados (Vitest)
  repository/    base.repository.ts (wrapper de execute() com prepared statements),
                 post.repository.ts, like.repository.ts, comment.repository.ts     → um método por tabela denormalizada/query
  errors/        http.error.ts                                                    → HttpError(message, statusCode)
                 error.handler.ts                                                 → setErrorHandler compartilhado (server.ts e helper de teste)
  kafka/         producer.ts                                                      → singleton lazy, produtor apenas
                 events.ts                                                        → publishEvent() — único ponto que monta o envelope do evento + métrica kafka_publish_total
  metrics/       registry.ts                                                      → Registry do prom-client + toda métrica do serviço (única fonte — não crie Counter/Histogram solto em outro arquivo)
  schema/        post.schema.ts                                                   → schemas Zod de params e do body de POST /posts e /posts/upload-url (ver Stack)
  types/         post.types.ts, comment.type.ts (singular — inconsistente, cuidado ao criar arquivo novo), like.types.ts
  utils/         cursor.ts                                                        → cursor opaco (base64url) para paginação keyset de posts
                 media.ts                                                         → conversão UDT media_item <-> domínio + fallback de image_urls legado
                 fanout.ts                                                        → runFanout() — Promise.allSettled com métrica de falha parcial, usado pelos *InAllViews de post.repository.ts
  routes.ts                                                                       → registra todas as rotas + schema JSON Schema completo por rota + /health, /ready, /metrics
  plugins.ts                                                                      → registerCorsAndRateLimit() (CORS allowlist/origin:true + rate limit com store Redis) e registerHttpMetrics() (hook onResponse)
  server.ts                                                                       → bootstrap Fastify, plugins, error handler global, connect/disconnect de infra
migrations/      V00N__*.cql                                                      → schema do Cassandra, versionado manualmente
scripts/migrate.ts                                                                → runner de migration próprio (não Prisma)
tests/
  helpers/       fastify.test.helper.ts    → buildServer registra só `routes` (sem cors/helmet/rate-limit/multipart)
  integration/   *.spec.ts por feature (post/like/comment)
  setup/         vitest.setup.ts           → mocka `src/config/env` inteiro (evita exigir env reais do Astra/R2 em teste)
```

`docker-compose.test.yml` só sobe Redis — não há Cassandra nem Kafka reais disponíveis para teste; qualquer teste precisa mockar `repository`/`producer`.

### Padrão de uma feature nova

1. Tipos em `types/<feature>.types.ts` (siga o plural, exceto se for tocar em `comment.type.ts`, que já está no singular por herança do código existente).
2. `repository/<feature>.repository.ts` — classe que estende `BaseRepository`, um método por tabela/query CQL. **Ao adicionar um campo ou contador novo, replique manualmente em todas as tabelas denormalizadas relevantes** (`_by_id`, `_by_user`, `_by_establishment`) — não existe transação/`BATCH` atômico entre elas hoje (ver Performance). Para posts, use os métodos de coordenação já existentes (`createInAllViews`, `updateCaptionInAllViews`, `softDeleteInAllViews`, `updateTotalLikesInAllViews`, `updateTotalCommentsInAllViews` em `post.repository.ts`) em vez de repetir o fan-out condicional (`if (post.establishmentId) ...`) em cada service — é exatamente esse tipo de duplicação que esses métodos existem para evitar.
3. `services/<feature>.service.ts` — classe, injeta repositórios via construtor, lança `HttpError(message, statusCode)` para erros esperados, dispara `publishEvent(...)` (`src/kafka/events.ts`) **depois** de persistir — nunca `producer.send(...)` direto.
4. `controller/<feature>.controller.ts` — classe, um método por rota, `.bind(this)` no registro em `routes.ts`; use os schemas Zod de `schema/post.schema.ts` (`.parse()`) para `params`, mas siga o padrão de JSON Schema do Fastify para `body`/`querystring`/`response` na própria definição da rota.
5. `routes.ts` — registrar com `schema` completo (tags, summary, description, `body`/`params`/`querystring`/`response` por status) e `config.rateLimit` dedicado (`rate_limit_write_max` para escrita, `rate_limit_like_max` para like/unlike) quando a rota for de mutação.
6. Testes unitários do service em `src/services/__tests__` + teste de integração da rota em `tests/integration`.

---

## Validação de conteúdo (`post-validation-service`)

`POST /posts` e `PATCH /posts/:postId` consultam o `post-validation-service` **antes de gravar**. Conteúdo reprovado vira `422` e o post não chega a existir.

Código: `src/clients/validation.client.ts` (transporte) e `PostService.enforceValidation` (política). A separação é intencional — o cliente nunca decide o que fazer com o veredito.

### Indisponibilidade deixa passar — e isso é escolha, não descuido

Se o serviço de validação não responde no orçamento (`POST_VALIDATION_TIMEOUT_MS`, 1s), o post é **publicado assim mesmo**.

O raciocínio: barrar publicação quando o filtro cai transformaria um serviço auxiliar no ponto único de falha do Vibester inteiro — o oposto do que o `CLAUDE.md` raiz pede. O que cobre o outro lado é o **worker** do `post-validation-service`, que revalida tudo que foi publicado e notifica o autor. Conteúdo que escapa durante uma queda é pego depois; uma plataforma que não aceita post não tem conserto retroativo.

O mesmo vale para **chamador sem `Authorization`**: a rota de validação exige JWT e este serviço só repassa o header que recebeu. Sem token não há consulta, e o post passa.

Quem quiser o comportamento oposto muda `enforceValidation`, com os olhos abertos. Não é env var de propósito: é decisão de produto, não de configuração.

### `POST_VALIDATION_MODE` e o rollout

| Modo | Efeito |
|---|---|
| `block` | reprovado vira `422`, post não é criado. **Padrão.** |
| `warn` | consulta e mede, nunca barra. |
| `off` | nem chama. Interruptor de emergência, sem deploy. |

**Suba a primeira vez em `warn`.** Acompanhe `post_validation_total{result="invalid"}` por alguns dias, confirme que a taxa não é falso positivo da blocklist, e só então vire `block`. Ligar direto em `block` faz todo falso positivo virar publicação recusada no primeiro minuto de deploy.

**O manifest de produção (`k8s/deployment.yaml`) sai em `warn`**, e o CI aplica o manifest a cada deploy (`kubectl apply` antes do `set image`) — virar `block` é trocar uma linha nesse arquivo, num diff revisável. O `block` da tabela acima é o padrão do *código* (`src/config/env.ts`), que só vale quando a variável não está definida, como em teste e em ambiente local.

Sobre tamanho: o limite de 500 do serviço de validação é mais apertado que os 2000 do `createPostSchema` daqui, mas o composer do app já corta em 280 — quem publica pelo app não esbarra nele. Ver "Três limites de legenda" no `CLAUDE.md` do `post-validation-service`.

### Detalhes que não são óbvios

1. **A validação roda antes de gerar o `postId` e antes de qualquer escrita.** Post recusado não deve deixar rastro no Cassandra nem publicar `post.created`.
2. **Em `updateCaption`, a checagem de dono vem primeiro.** Quem nem pode editar o post não deve descobrir nada sobre o filtro, e validar antes gastaria uma chamada de rede para devolver `403` no fim.
3. **A edição informa a mídia já existente** (`post.media.length`). Sem isso, apagar a legenda de um post com foto seria lido como post vazio.
4. **`401` do serviço de validação é tratado como indisponibilidade, não como reprovação.** Token expirado é problema de sessão; virar recusa de conteúdo daria ao autor uma mensagem sobre o texto dele que não tem nada a ver com o que aconteceu.
5. **`HttpError` ganhou `details` opcional** para carregar as `issues` no corpo do `422`. Erro sem `details` continua respondendo exatamente `{ message }` — nenhuma resposta existente mudou de forma.
6. **Comentários não são validados.** `POST /posts/:postId/comments` não passa por aqui — lacuna conhecida, e fechá-la é adicionar a mesma chamada no `CommentService`.

### Ocultação pela moderação de imagem

O worker do post-validation-service classifica as imagens de cada post publicado. Quando acha algo grave, publica `post.validation.rejected` com `action: "hide"`. O consumidor daqui (`handleValidationRejectedMessage` em `src/kafka/consumer.ts`) chama **`PostService.hideForModeration`**:

- **Reaproveita o soft delete** (`softDeleteInAllViews` + limpeza de cache + `post.deleted`). É isso que faz a ocultação chegar a todo lugar sem código novo: o feed-service tira o post das timelines e o user-service desconta o contador do perfil. A linha continua no Cassandra marcada `is_deleted`, então restaurar numa contestação é possível.
- **Sem checagem de dono** (quem pede é o sistema) e **idempotente**: post já apagado ou inexistente não é erro nem republica `post.deleted` — reentrega do Kafka não pode virar retry infinito nem descontar o contador duas vezes.
- **Só depois de ocultar publica `post.moderation.hidden`**, de onde o notification-service tira o aviso "sua publicação foi removida". Avisar a partir da recomendação poderia afirmar uma remoção que não aconteceu.
- `action: "notify"` é ignorado aqui (só aviso ao autor, que é do notification-service). Evento antigo sem `action` conta como aviso.
- **`POST_MODERATION_HIDE=off` é o freio de emergência**: o pedido é descartado e sobe `posts_moderation_hidden_total{result="disabled"}`. A alavanca de rollout é o `IMAGE_MODERATION_MODE` do worker de validação — enquanto ele está em `observe`, nenhum pedido chega aqui.

---

## Segurança — obrigatório em qualquer alteração

1. **Este serviço não tem nenhuma autenticação** — nem `@fastify/jwt` está registrado. Todo `userId` vem direto do `body`/`params` da requisição, sem qualquer verificação de identidade. Isso é ainda mais aberto do que o `user-service` (que ao menos registra `@fastify/jwt`, mesmo sem aplicá-lo). Não assuma que a rede interna/gateway resolve isso sozinha — se for expor uma rota nova ou uma rota sensível diretamente a clientes, sinalize essa lacuna explicitamente antes de prosseguir.
2. **`PATCH /posts/:postId` e `DELETE /posts/:postId` agora exigem `userId` no body e verificam o dono** (`post.controller.ts` → `updateCaption`/`softDelete` passam `request.body.userId`; `post.service.ts` compara `post.userId !== currentUserId` e responde `403` antes de mutar, mesmo padrão de `CommentService`). O `userId` é obrigatório no JSON Schema de `routes.ts` — um payload sem ele já recebe `400` antes de chegar ao service. Isso ainda **não é autenticação real** (ver item 1: qualquer chamador pode simplesmente mandar o `userId` de outra pessoa) — só impede o caso mais grave de um chamador nem precisar saber de quem é o post.
3. **Comentários já verificam propriedade corretamente**: `update`/`softDelete` em `comment.service.ts` comparam `comment.userId` com o `userId` do body e retornam `403` em caso de divergência — mantenha esse padrão em qualquer mutação de comentário nova.
4. **Likes**: `unlikePost` exige que exista um `like` daquele `userId` específico antes de remover (`findLikeByPostAndUser`), o que restringe a ação ao "dono" da curtida na prática — mas, como não há verificação de identidade, qualquer chamador pode enviar qualquer `userId` no body e curtir/descurtir em nome de outro usuário.
5. **CORS configurável via `CORS_ALLOWED_ORIGINS`** (env, lista separada por vírgula) — `registerCorsAndRateLimit` (`src/plugins.ts`) usa a lista quando definida; **sem ela, cai em `origin: true`** (aceita qualquer origem) com aviso no log. Nenhum valor foi configurado em produção ainda — enquanto a env var não for definida no k8s, o comportamento efetivo continua sendo o mesmo `origin: true` de antes. Definir a lista de origens de produção é uma decisão de produto, não técnica — não invente valores.
6. **Upload de imagem nunca passa pelo processo do serviço**: o único fluxo ativo é `POST /posts/upload-url`, que gera uma URL pré-assinada (`PutObjectCommand` + `getSignedUrl`, expira em 5 min) para o cliente fazer o `PUT` direto no R2. O post-service nunca vê o binário, então **não há validação de mimetype/tamanho do lado do servidor** para essas imagens — a única defesa é o que o cliente/R2 aplicarem no `PUT`. `@fastify/multipart` está registrado em `server.ts` (limite 10MB/20 arquivos) mas nenhuma rota o usa hoje — não assuma que esse limite protege algo em produção. `createPostSchema` (`schema/post.schema.ts`) valida, além de a URL pertencer ao bucket (`bucketUrlSchema`), que cada `media[].url`/`thumbnailUrl` está sob o prefixo `posts/{userId do body}/` — sem isso, um post podia referenciar mídia de outro usuário (a key é previsível: `posts/<userId>/<uuid>.ext`). Ainda não há checagem de que o objeto foi de fato enviado (fica só no prefixo/posse do path).
7. **Erros**: o `setErrorHandler` global (`server.ts`) trata `ZodError` (400 com lista de `field`/`message`), `HttpError` (usa o `statusCode` da própria instância), erros do Fastify com `statusCode < 500` (repassados como estão) e qualquer outro erro vira `500 { message: "Internal server error" }` com log via `app.log.error({ err: error })`. Siga esse contrato: lance `HttpError` para erros esperados, deixe o resto propagar.
8. **Segredos**: credenciais do Astra (`ASTRA_CLIENT_ID`/`ASTRA_CLIENT_SECRET`/`ASTRA_TOKEN`/o bundle) e do R2 (`R2_ACCESS_KEY_ID`/`R2_SECRET_ACCESS_KEY`) sempre via env/secret do k8s, nunca hardcode. `.env.example` já lista todas como placeholder vazio.
9. **Rate limit usa o Redis como store** (`registerCorsAndRateLimit` em `src/plugins.ts`, opção `redis` do `@fastify/rate-limit` apontando pro mesmo client de `config/redis.ts`, `nameSpace: "post-service-rate-limit-"`) — o contador agora é compartilhado entre réplicas, então já não é mais um bloqueio para tirar o `replicas: 1` fixo do `k8s/deployment.yaml` (mas isso continua sendo uma decisão separada — o deployment não foi alterado). `skipOnError: true`: uma falha do Redis desativa o rate limit até ele voltar, nunca derruba a requisição — mesmo princípio do `cacheAside`.

---

## Performance — obrigatório em qualquer alteração

1. **Modelagem "query-first" do Cassandra**: cada padrão de leitura tem sua própria tabela denormalizada (`posts_by_id`/`posts_by_user`/`posts_by_establishment`, `comments_by_id`/`_by_post`/`_by_user`, `likes_by_post`/`_by_user`). Toda escrita (criar/atualizar/deletar/contador) precisa de **fan-out manual** para todas as tabelas relevantes via `Promise.all` — ao adicionar um campo ou uma tabela denormalizada nova, replique a mudança em todos os métodos de escrita correspondentes do repository, senão as views ficam inconsistentes entre si.
2. **Sem transação atômica entre tabelas denormalizadas** (nenhum uso de `BATCH`/LWT do Cassandra) — uma falha parcial no meio de um `Promise.all` pode deixar `posts_by_id` e `posts_by_user` divergentes (ex.: `total_likes` diferente entre as views), e o código atual não faz rollback nem retry nesse cenário. Considere isso ao avaliar a robustez de qualquer alteração nesse fluxo.
3. **Contadores (`total_likes`/`total_comments`) usam um contador atômico dedicado**: `post_counters` (migration `V015`, colunas `counter`) é a fonte de verdade — `LikeService`/`CommentService` chamam `postRepository.incrementLikes/decrementLikes/incrementComments/decrementComments` (só `UPDATE ... SET col = col + 1`, sem leitura prévia) e depois `getCounters(postId)` para ler o valor absoluto atualizado e propagá-lo para `posts_by_id`/`_by_user`/`_by_establishment` via `updateTotalLikesInAllViews`/`updateTotalCommentsInAllViews`. As colunas `total_likes`/`total_comments` dessas tabelas continuam existindo como cópia de exibição (lida pelo cache-aside), mas `post_counters` é quem nunca perde um incremento sob concorrência — não volte a somar/subtrair em memória a partir do valor lido de `posts_by_id`. **Rollout**: uma linha em `post_counters` só existe após o primeiro incremento (contador do Cassandra não aceita `INSERT` com valor literal) — rode `scripts/backfill-post-counters.ts` uma vez antes/durante o deploy, ou posts com curtidas/comentários anteriores a essa mudança "reiniciam" a exibição a partir de 1 no primeiro like/comentário novo. Esse script não foi validado contra um Cassandra real.
4. **Paginação cursor-based (keyset) existe em todas as listagens que crescem sem limite**: posts (`post.repository.ts`, `(created_at, post_id) < (?, ?)`), comentários por post/usuário (`comments_by_post`/`comments_by_user`, `(created_at, comment_id) < (?, ?)`) e curtidas por usuário (`likes_by_user`, `(liked_at, post_id) < (?, ?)`) usam cursor opaco em `src/utils/cursor.ts` (`encodeCursor`/`decodeCursor` e as variantes `*CommentCursor`/`*LikeCursor`), exposto no header `X-Next-Cursor`. **Curtidas por post são a exceção**: `likes_by_post` é clusterizada por `user_id`, não por `liked_at` (ver migration `V005`) — recriar a tabela clusterizada por tempo exigiria migração de dado não validável sem Cassandra real, então a paginação ali (`encodeLikeByPostCursor`/`decodeLikeByPostCursor`) usa a própria `user_id` como cursor: ordem estável e sem duplicatas/saltos entre páginas, mas não ordenada por recência. Siga o padrão já existente (cursor específico por formato de clustering) para qualquer listagem nova.
6. **Cache-aside** (`cacheAside` em `src/config/redis.ts`, TTL 300s para post por id, 120s para listagens por usuário/estabelecimento) é o padrão para leitura pesada — toda leitura nova de alto tráfego deve seguir esse padrão em vez de ir direto ao Cassandra.
7. **Invalidação de cache é best-effort** (`redis.del(...)` dentro de `try/catch`, loga e segue) — nunca deixe uma falha de cache derrubar a escrita principal.
8. **`isLiked` nunca é cacheado junto do post** — é calculado em tempo de leitura por `viewerId` (`attachIsLiked` em `post.service.ts`, comentário explícito no código sobre por quê), já que o cache de posts é compartilhado entre todos os viewers. Preserve essa separação ao adicionar um campo novo que dependa do usuário autenticado.
9. **Upload de mídia nunca passa pelo processo Node** (fluxo 100% via URL pré-assinada) — bom para escalabilidade, já que não há I/O de arquivo no service; preserve esse padrão em vez de reintroduzir upload via multipart/`sharp` sem necessidade real.
10. **Concorrência limitada nas chamadas ao R2** (`PRESIGN_CONCURRENCY = 5` em `upload.service.ts`, `runWithConcurrency` processa em lotes) — evita saturar o client S3 ao gerar até 20 URLs de uma vez; siga o mesmo padrão para qualquer operação nova em lote contra o R2.
11. Ao adicionar rota nova, pense no custo em alta volumetria (milhões de posts/curtidas/comentários) desde o design da tabela/query Cassandra, não como otimização posterior — Cassandra penaliza fortemente `ALLOW FILTERING`/scans; qualquer padrão de acesso novo provavelmente precisa de uma tabela denormalizada nova, não de uma query ad-hoc sobre uma tabela existente.

---

## Testes

- `npm test` — `vitest run` (config padrão `vitest.config.ts`): roda unit (`src/**/*.test.ts`) + integration (`tests/integration/**/*.spec.ts`) juntos.
- `npm run test:unit` — só unit, via `vitest.unit.config.ts`.
- `npm run test:integration` — só integration, via `vitest.integration.config.ts` (`fileParallelism: false`, execução sequencial, timeout 30s).
- `npm run test:coverage` — `vitest.coverage.config.ts`, thresholds mínimos **70% linhas, 70% funções, 60% branches** sobre `src/services`, `src/controller`, `src/routes.ts` — não reduza para fazer um PR passar.
- `tests/setup/vitest.setup.ts` mocka `src/config/env` inteiro (evita exigir as env vars obrigatórias do Astra/R2 durante os testes).
- `docker-compose.test.yml` só sobe Redis — não há Cassandra nem Kafka reais nos testes; repository e producer precisam ser mockados (`vi.mock`) nos testes de integração.
- `tests/helpers/fastify.test.helper.ts` monta um app minimalista que registra **só** `routes` (sem cors/helmet/rate-limit/multipart) — se uma rota nova depender de algum desses plugins, o teste de integração pode não refletir o comportamento real de produção.

Toda feature nova precisa de: teste unitário do service (incluindo o fan-out para as tabelas denormalizadas e os branches de erro/`HttpError`) e teste de integração da rota.

---

## Variáveis de Ambiente

Toda variável de ambiente é validada por `zod` em `src/config/env.ts` (`envSchema.safeParse(process.env)`, processo encerra com `process.exit(1)` se inválida) — mesmo padrão do `establishment-service`. Não leia `process.env` direto em outro arquivo do `src/`, com a exceção já existente de `scripts/migrate.ts` (roda fora do runtime do server, antes de qualquer conexão, e lê `process.env` diretamente). Propague no `k8s/deployment.yaml` (`secretRef: post-service-secret` para credenciais Astra/R2, `configMapRef: redis-env` para Redis) e no `.env.example` (placeholders vazios, nunca valor real).

As três de validação (`POST_VALIDATION_URL`, `POST_VALIDATION_TIMEOUT_MS`, `POST_VALIDATION_MODE`) ficam em `env:` literal no Deployment, não em Secret: nenhuma é segredo, e deixá-las versionadas faz de `warn` -> `block` um diff revisável em vez de uma edição invisível de Secret.

---

## Infra deste Serviço

- `Dockerfile`: build em 2 estágios (`builder` com `npm install` + `npm run build` + `npm prune --omit=dev`; `runtime` copia `node_modules`/`dist`/`migrations`/`package.json`). `CMD` roda `node dist/scripts/migrate.js && node dist/src/server.js` — as migrations `.cql` são aplicadas automaticamente no start do container (mesmo padrão de `auth-service`/`establishment-service`), usando o runner próprio de `scripts/migrate.ts`, que registra as versões executadas na tabela `schema_migrations` do keyspace.
- `k8s/`: só existem `deployment.yaml` e `service.yaml` — **sem `hpa.yaml`, sem `pdb.yaml`, sem `networkpolicy.yaml`**, diferente dos três serviços já documentados. `replicas: 1` está fixo — o serviço não escala horizontalmente hoje (ver nota de rate limit em memória em Segurança/Performance antes de simplesmente aumentar réplicas).
- O secure connect bundle do Astra é montado via `Secret` + `Volume` (`astra-secure-connect-bundle` em `/etc/astra/secure-connect-bundle.zip`) — `ASTRA_SECURE_CONNECT_BUNDLE` no deployment aponta para o **caminho do arquivo montado**, não para o conteúdo do bundle.
- **Liveness e readiness são separados** (`routes.ts`): `livenessProbe` do `k8s/deployment.yaml` aponta para `/health` (só confirma que o processo Fastify está de pé, não toca em Redis/Cassandra — matar o processo não conserta uma dependência externa fora do ar). `readinessProbe` aponta para `/ready`, que checa as duas: **Cassandra é crítico** (toda rota depende dele, derruba o readiness com `503` se falhar) e **Redis não é** (`cacheAside` já cai pro Cassandra direto quando o Redis falha — Redis fora do ar reporta `status: "degraded"` mas continua `200`, não tira o pod de rotação sozinho). Ao adicionar uma dependência nova, decida explicitamente se ela é crítica (vai pro `/ready`, derruba o readiness) ou best-effort (só reportada, não derruba nada) — não assuma automaticamente.
- **Métricas Prometheus em `/metrics`** (`src/metrics/registry.ts`, biblioteca `prom-client`) — inclui métricas padrão de processo (`collectDefaultMetrics`) e as específicas do serviço: `http_request_duration_seconds`/`http_requests_total` (hook `onResponse` em `plugins.ts`, label `route` = padrão da rota via `request.routeOptions.url`, nunca a URL crua — evita explodir cardinalidade com UUID), `cassandra_query_duration_seconds` (tabela extraída da própria query em `base.repository.ts`, sem precisar anotar cada método), `cassandra_fanout_partial_failure_total` (incrementada por `utils/fanout.ts` quando só parte de um fan-out multi-tabela falha — usado pelos 5 métodos `*InAllViews` de `post.repository.ts`), `cache_result_total`/`cache_invalidation_failure_total` (`config/redis.ts`), `kafka_publish_total` (`kafka/events.ts`), `rate_limit_exceeded_total` (`plugins.ts`), `post_validation_total` (`clients/validation.client.ts` — rótulo `result`: valid/invalid/unavailable/skipped; é a métrica que governa o rollout do `POST_VALIDATION_MODE`, e `unavailable` em alta significa que a validação está deixando tudo passar sem ninguém perceber), `posts_moderation_hidden_total` (`kafka/consumer.ts` — `result`: hidden/already_deleted/not_found/disabled), e contadores de negócio (`posts_created_total`, `likes_total`, `comments_total`, `presigned_url_generated_total`). Toda métrica nova do serviço deve ser registrada em `metrics/registry.ts` — não crie `new client.Counter(...)` solto em outro arquivo.
- Sem tracing distribuído (OpenTelemetry) — fora do escopo por enquanto; log estruturado (Pino) + métricas cobrem a lacuna de observabilidade mais urgente hoje.
- Swagger (`/docs`) é sempre registrado em `server.ts`, sem flag de ambiente (`SWAGGER_ENABLED`) para desligá-lo — diferente do `establishment-service`; não assuma que a documentação fica oculta em produção.

---

## Exclusão de conta (`user.deleted`)

`src/kafka/consumer.ts` (grupo `post-service-group`, iniciado em `server.ts` depois do Cassandra) consome o evento do auth-service e chama `AccountContentDeletionService.deleteAllContent(userId)`:

1. **Posts** — `findByUser` paginado (100): apaga a legenda nas três tabelas (`updateCaptionInAllViews(post, "")`) e chama `PostService.softDelete`, que publica `post.deleted` (feed-service tira das timelines; user-service ajusta o contador).
2. **Curtidas** — `findLikesByUser` paginado → `LikeService.unlikePost` (counters e `post.stats.updated` como num descurtir normal).
3. **Comentários** — `CommentRepository.findByUser` paginado → `CommentService.softDelete`.
4. **Mídia** — `ListObjectsV2` + `DeleteObjects` no R2 sob `posts/<userId>/` (fotos, vídeos, capas **e o avatar**, que sobe pelo mesmo prefixo).

404/409 de algo já removido é ignorado (idempotente); qualquer outro erro sobe e o kafkajs reentrega. O `userId` precisa ser UUID — ele vira prefixo de chave no R2. As linhas de post continuam marcadas `is_deleted` (com legenda vazia e a cópia denormalizada de `userUsername`); o conteúdo de comentários removidos também continua marcado `is_deleted`, sem redação.

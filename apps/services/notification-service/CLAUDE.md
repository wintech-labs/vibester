# Notification Service

> Contexto específico do microserviço de notificações e e-mails transacionais do Vibester.
> Este documento complementa o `CLAUDE.md` da raiz do monorepo. Em caso de conflito, o `CLAUDE.md` raiz prevalece nas diretrizes gerais de produto/arquitetura; este arquivo prevalece em convenções específicas deste serviço. Código-fonte é sempre a fonte de verdade final.
>
> **Atenção**: este serviço tem um papel duplo (notificações in-app + e-mails transacionais) e não possui testes automatizados atualmente. Não copie convenções de outro serviço sem verificar contra o código deste diretório.

---

## Responsabilidade do Serviço

O `notification-service` é responsável exclusivamente por:

- receber eventos Kafka de outros serviços e persistir **notificações in-app** (`follow`, `like`, `comment`, `post_rejected`) para o destinatário;
- **agrupamento de notificações** por tipo/referência na listagem (ex.: múltiplos likes no mesmo post viram um grupo);
- expor endpoints HTTP para **listagem paginada**, **contagem de não lidas** e **marcação de lidas** das notificações do usuário autenticado;
- **envio de e-mails transacionais** (verificação de conta, boas-vindas, recuperação de senha, 2FA) via Kafka (`auth.email.verification`, `user.registered`) ou via chamada HTTP direta dos outros serviços (`POST /notifications/email`, `/reset-password`, `/welcome`, `/2fa`);
- geração e validação de **códigos 2FA** (tabela `TwoFactorCode` no Postgres), com validade de 5 minutos.

Ele **não** possui dados de perfil do usuário nem credenciais — isso é responsabilidade do `user-service` e do `auth-service`, respectivamente. Dados de actor (nome, avatar) são buscados sob demanda no `user-service` via `UserClient`; dados de post são buscados no `post-service` via `PostClient`.

Nunca adicione regras de negócio de autenticação, feed, pagamento ou relacionamento de seguidores aqui. Se uma feature parece pertencer a outro domínio, ela deve ser feita no serviço correspondente e comunicada via Kafka.

---

## Stack e Dependências deste Serviço

- Fastify 5 + `@fastify/cors`, `@fastify/jwt`, `@fastify/swagger` (+ `swagger-ui`)
- **`@fastify/type-provider-zod`** — validação de body/params/querystring e geração de OpenAPI feitas via schemas **Zod**, não JSON Schema manual. Toda rota nova deve seguir esse padrão: `router.get/post/patch(...)` com `app.withTypeProvider<ZodTypeProvider>()`, schemas Zod declarados antes das rotas, `validatorCompiler`/`serializerCompiler` já registrados em `server.ts`.
- Prisma 7 com `@prisma/adapter-pg` (driver adapter sobre `pg.Pool`, mesmo padrão do `auth-service` e `user-service`)
- PostgreSQL — dois modelos: `Notification` (notificações in-app) e `TwoFactorCode` (códigos 2FA com expiração)
- Redis (`ioredis`) — presente na infra (configurado em `src/config/redis.ts`) e exposto no `/health`, mas **ainda não utilizado para cache** — não assuma que dados estão sendo cacheados neste serviço
- Kafka (`kafkajs`) — **somente consumidor** neste serviço; sem produtor. Consome: `auth.email.verification`, `user.registered`, `user.followed`, `post.liked`, `post.commented`, `user.deleted`, `auth.attempts.exceeded`, `auth.password.reset` (email com o código de redefinição, template `password_reset_code.html`; o código nunca vai para o log) e `content.reported` (cada denúncia vira um email para `MODERATION_EMAIL`, padrão `contato@vibester.com.br`, template `content_report.html` com os passos de moderação — é o gatilho do prazo de 24h da App Store)
- `nodemailer` — envio de e-mails via SMTP; funciona em modo dev sem credenciais (apenas loga, não envia)
- `handlebars` — renderização dos templates HTML de e-mail (arquivos em `templates/`)
- Sem testes automatizados atualmente (sem Vitest, sem k6)

Não introduza um ORM alternativo, outro cliente Redis/Kafka, ou mude o motor de templates sem necessidade real — reutilize o que já existe.

---

## Estrutura de Pastas

```
src/
  config/        env.ts, redis.ts, swagger.ts     → configuração/infra, sem lógica de negócio
  controllers/   notification.controller.ts        → rotas HTTP de notificações (list, unread-count, mark-read) + rotas legadas com :userId
                 email.controller.ts               → rotas HTTP de e-mail (email, reset-password, welcome, 2fa, 2fa/validate)
  services/      email.service.ts                  → envio SMTP via nodemailer, com retry (3 tentativas, 2s entre elas)
                 insertNotification.service.ts     → criação de uma linha na tabela notifications
                 listNotifications.service.ts      → buildFeed: busca raw do Prisma → groupNotifications → enrich (UserClient + PostClient)
                 markAllRead.service.ts             → updateMany read=true para o recipientId
                 notificationGrouping.service.ts   → agrupamento in-memory de NotificationRow[] → NotificationGroup[]
                 templateRenderer.service.ts        → renderiza template Handlebars de templates/
                 twoFactor.service.ts              → gera código (crypto.randomInt), salva no Postgres, valida, marca como usado
                 unreadCount.service.ts             → conta grupos não lidos para o recipientId
  clients/       user.client.ts                    → GET /users/profile/:accountId no user-service (com AbortController + timeout)
                 post.client.ts                    → GET de dados de post no post-service (com AbortController + timeout)
  kafka/         consumer.ts                       → consumer singleton; subscreve aos 6 tópicos; despacha para handlers
                 handlers/
                   verification.handler.ts         → auth.email.verification → renderiza two_factor_code.html → enqueueEmail
                   registration.handler.ts         → user.registered → renderiza welcome.html → enqueueEmail
                   follow.handler.ts               → user.followed → insertNotification("follow", ...)
                   postLiked.handler.ts            → post.liked → insertNotification("like", ...)
                   postCommented.handler.ts        → post.commented → insertNotification("comment", ...)
                   userDeleted.handler.ts          → user.deleted → deleta todas as notificações do usuário
                   postValidationRejected.handler.ts → post.validation.rejected (só action "notify") → insertNotification("post_rejected", autor, autor, postId, motivo)
                   postModerationHidden.handler.ts → post.moderation.hidden → insertNotification("post_rejected", ..., "Sua publicação foi removida porque…")
                   postModeration.messages.ts      → código do motivo → texto pt-BR (compartilhado pelos dois handlers acima)
  workers/       email.worker.ts                   → fila in-memory de e-mail com concorrência máxima de 5 workers
  prisma/        index.ts                          → singleton do PrismaClient com adapter pg.Pool
  types/         notification.types.ts             → NotificationRow, NotificationGroup, NotificationGroupResponse, ActorSummary, PostSummary
                 email.types.ts                    → EmailNotification
  generated/                                       → Prisma client gerado (não editar manualmente)
  routes.ts                                        → /health (checa DB + Redis), registra notificationRoutes (/notifications) e emailRoutes (/notifications)
  server.ts                                        → bootstrap Fastify, plugins, connect/disconnect de infra, graceful shutdown
templates/                                         → templates Handlebars (.html): welcome, two_factor_code, reset_password
```

### Padrão de uma feature nova

1. Se precisar de tipos novos, adicionar em `types/notification.types.ts` ou `types/email.types.ts` (ou um arquivo `<feature>.types.ts` novo se o domínio for diferente).
2. `services/<feature>.service.ts` — lógica de negócio e acesso ao Prisma. Não há uma classe de erro dedicada (`AppError`) neste serviço — deixe exceções propagarem e trate no controller.
3. Em `controllers/notification.controller.ts` ou `controllers/email.controller.ts`: declarar o schema Zod antes da função da rota, registrar com `router.get/post/patch(...)`, e no handler fazer `try/catch` que loga (`request.log.error(error)`) e responde `500 { message: "..." }` genérico. Mensagens de erro voltadas ao usuário são em **português**, seguindo o padrão já existente neste serviço.
4. Handlers Kafka em `kafka/handlers/<event>.handler.ts`: sempre com `try/catch` que loga o erro sem relançar (evitar crash do consumer), validar campos obrigatórios do evento antes de usar.
5. Se o handler precisar de um cliente HTTP externo, use `UserClient` ou `PostClient` como referência (AbortController com `httpClientTimeoutMs`, retornar `null` em caso de falha — nunca deixar erro externo travar o fluxo principal).

---

## Segurança — obrigatório em qualquer alteração

1. **Autenticação JWT está ativa nas rotas principais**: `GET /notifications/`, `GET /notifications/unread-count` e `PATCH /notifications/read` usam `preHandler: [authenticate]` que chama `request.jwtVerify()`. As rotas legadas `/:userId/*` **não têm autenticação** — são de compatibilidade transitória e devem ser removidas ou protegidas quando o mobile migrar para as rotas autenticadas.
2. **Rotas de e-mail HTTP (`/email`, `/reset-password`, `/welcome`, `/2fa`) não têm autenticação** — são confiadas à rede interna/gateway, não verificam identidade do chamador. Ao adicionar uma rota nova de e-mail, sinalize se ela precisa de autenticação antes de expô-la.
3. **Códigos 2FA**: gerados com `crypto.randomInt` (nunca `Math.random`), TTL de 5 minutos no Postgres, invalidados (campo `used: true`) imediatamente após validação bem-sucedida. Nunca retornar o código gerado na resposta HTTP.
4. **Validação de entrada via Zod é obrigatória** em toda rota nova (`body`/`params`/`querystring`), incluindo `.email()`, limites de tamanho. Isso é a primeira defesa contra payload malformado.
5. **Clientes HTTP externos com timeout obrigatório**: `UserClient` e `PostClient` usam `AbortController` com `env.httpClientTimeoutMs` (padrão 5000ms). Qualquer nova chamada HTTP externa deve seguir o mesmo padrão — nunca `fetch` sem timeout.
6. **Erros internos nunca vazam para o cliente**: qualquer exceção não esperada deve virar `500 { message: "..." }` genérico; detalhes vão só para `request.log.error`.
7. **CORS**: `origin` vindo de `env.allowedOrigins` (split de `ALLOWED_ORIGINS`), nunca hardcode `*`.
8. **Segredos**: `JWT_SECRET`, `DATABASE_URL`, `KAFKA_BROKERS`, `SMTP_PASSWORD` sempre via env/secret do k8s, nunca hardcode. `.env.example` contém apenas placeholders — nunca commitar `.env` real.
9. **`/health` não deve vazar detalhes de infraestrutura** além dos campos `status`/`db`/`redis` — não adicione connection string, stack trace ou versão de dependência na resposta.

---

## Performance — obrigatório em qualquer alteração

O serviço sustenta leitura de notificações em alta concorrência (toda ação social dispara uma notificação). Ao alterar código:

1. **Agrupamento in-memory é intencional**: `groupNotifications` processa até `rawFetchLimit` (200) linhas em memória para montar os grupos antes de paginar. Esse número é um teto — não busque mais do que isso sem revisar o impacto de memória.
2. **Enrich usa cache de Promises por ator/post dentro de um request**: `ListNotificationsService.enrich` reutiliza Promises já iniciadas (`actorCache`/`postCache`) para não duplicar chamadas HTTP ao `user-service` e `post-service` para o mesmo ID dentro de uma mesma listagem. Mantenha esse padrão se adicionar novos enriquecimentos.
3. **Clientes HTTP são fire-and-forget em caso de falha**: `UserClient.getProfile` e `PostClient.getPost` retornam `null` silenciosamente em caso de timeout ou erro — nunca deixe a falha de um serviço externo derrubar a listagem de notificações.
4. **Fila de e-mail in-memory com concorrência limitada**: `emailQueue` em `email.worker.ts` processa no máximo `MAX_CONCURRENT_WORKERS` (5) envios simultâneos. Isso é adequado para o volume atual, mas não é persistente — e-mails na fila são perdidos em caso de restart. Se a confiabilidade de entrega de e-mail for crítica, considere mover para uma fila persistente (ex.: Kafka com tópico de e-mail).
5. **Reaproveitar singletons de infra**: Prisma (`src/prisma/index.ts`) e Redis (`src/config/redis.ts`) já são singletons — nunca instancie um novo `PrismaClient` ou `Redis` dentro de um service/handler.
6. **Índices do Prisma**: `Notification` tem índice composto `(recipientId, read, createdAt DESC)` para a query de listagem e `(recipientId, type, refId)` para deduplicação; `TwoFactorCode` tem `(email, used, expiresAt)`. Qualquer campo novo de busca frequente precisa de índice equivalente na migration.
7. **Paginação via cursor de data**: `buildFeed` usa `before` (data de corte) + `take: rawFetchLimit` para buscar raw rows, depois limita o resultado dos grupos agrupados a `limit`. Novos endpoints de listagem devem seguir o mesmo padrão de cursor — nunca `findMany` sem `take`.
8. **Operações de I/O independentes em paralelo**: `enrich` usa `Promise.all` para processar todos os grupos concorrentemente. Ao adicionar novos enriquecimentos, prefira paralelismo quando as operações não têm dependência entre si.
9. **Handlers Kafka são síncronos por mensagem (eachMessage)**: cada mensagem é processada até o final antes da próxima. Handlers lentos bloqueiam o consumer — mantenha-os leves e rápidos; o envio de e-mail já é assíncrono via `enqueueEmail` (fire-and-forget).

---

## Testes

Este serviço **não possui testes automatizados** no momento. Ao adicionar uma feature nova:

- Crie testes unitários para os services (especialmente `notificationGrouping.service.ts`, `twoFactor.service.ts`, `listNotifications.service.ts`) mockando Prisma via `vi.mock`.
- Crie testes de integração das rotas mockando Prisma e os clients HTTP externos, usando `app.inject` (seguindo o padrão de `auth-service` e `user-service`).
- Se for adicionar handlers Kafka novos, crie testes equivalentes aos do `user-service` para o consumer.
- Antes de adicionar Vitest, adicione `vitest` e `@vitest/coverage-v8` às `devDependencies` e crie os arquivos de configuração (`vitest.config.ts`, `vitest.integration.config.ts`) seguindo o padrão dos outros serviços.

---

## Variáveis de Ambiente

Todo valor de configuração novo deve passar por `src/config/env.ts` (nunca ler `process.env` direto em outro arquivo), com um default sensato quando fizer sentido, e ser propagado no `k8s/deployment.yaml` e no `.env.example` (com placeholder, nunca valor real).

Variáveis atuais:

| Variável | Padrão | Descrição |
|---|---|---|
| `PORT` | `3006` | Porta HTTP do serviço |
| `DATABASE_URL` | *(obrigatória)* | Connection string PostgreSQL |
| `JWT_SECRET` | `"default-jwt-secret"` | Segredo para verificação de JWT nas rotas autenticadas |
| `KAFKA_BROKERS` | `"localhost:9092"` | Lista de brokers separada por vírgula |
| `REDIS_URL` | `"redis://localhost:6379"` | URL do Redis |
| `ALLOWED_ORIGINS` | `"https://vibester.com.br,http://localhost:3000"` | Origins permitidas no CORS |
| `SMTP_HOST` | `"smtp.gmail.com"` | Host do servidor SMTP |
| `SMTP_PORT` | `587` | Porta SMTP |
| `SMTP_EMAIL` | `""` | Usuário SMTP (vazio = modo dev sem envio real) |
| `SMTP_PASSWORD` | `""` | Senha SMTP |
| `SMTP_FROM_NAME` | `"Vibester"` | Nome do remetente |
| `USER_SERVICE_URL` | `"http://localhost:3003"` | URL base do user-service para enriquecer notificações |
| `POST_SERVICE_URL` | `"http://localhost:3000"` | URL base do post-service para enriquecer notificações |
| `HTTP_CLIENT_TIMEOUT_MS` | `5000` | Timeout em ms para chamadas HTTP externas |
| `TEMPLATES_DIR` | `""` | Diretório dos templates HTML (vazio = usa `templates/` relativo ao CWD) |

---

## Tópicos Kafka Consumidos

| Tópico | Handler | O que faz |
|---|---|---|
| `auth.email.verification` | `verification.handler.ts` | Renderiza `two_factor_code.html` e enfileira e-mail de verificação |
| `user.registered` | `registration.handler.ts` | Renderiza `welcome.html` e enfileira e-mail de boas-vindas |
| `user.followed` | `follow.handler.ts` | Persiste notificação `follow` para o usuário seguido |
| `post.liked` | `postLiked.handler.ts` | Persiste notificação `like` para o autor do post |
| `post.commented` | `postCommented.handler.ts` | Persiste notificação `comment` para o autor do post |
| `user.deleted` | `userDeleted.handler.ts` | Deleta todas as notificações cujo `recipientId` é o usuário removido |
| `post.validation.rejected` | `postValidationRejected.handler.ts` | Persiste notificação `post_rejected` (aviso; o post segue no ar) quando a revalidação do `post-validation-service` reprova um post já publicado. Ignora `action: "hide"`. Ver abaixo |
| `post.moderation.hidden` | `postModerationHidden.handler.ts` | Persiste notificação `post_rejected` dizendo que a publicação **foi removida**. Publicado pelo post-service depois de ocultar o post |

### `post_rejected` — aviso do sistema

- **`actorId` é o próprio autor** só porque o schema de `Notification` exige o campo. Na listagem, `enrich` **não** busca esse ator (devolve `actor: null`, que o app lê como "notificação do Vibester") e **busca** a miniatura do post (`refId`), para o autor saber qual publicação foi reprovada.
- **"Foi removida" só a partir de `post.moderation.hidden`.** Em `post.validation.rejected` o post continua no ar (ou vai ser ocultado pelo post-service, com `action: "hide"`, que este handler ignora). Dizer "removida" a partir da recomendação poderia afirmar algo que não aconteceu. No aviso comum, a instrução que vai junto é excluir, que é a única ação disponível no app hoje (não há edição de legenda).
- **Automutilação (`IMAGE_SELF_HARM`) não é tratada como infração**: o texto é substituído por uma mensagem de apoio com o CVV (188), sem falar em diretrizes. Se o post foi removido por outro motivo e havia também automutilação, a mensagem de apoio vai junto da de remoção.
- **Post apagado não tem miniatura** (`PostClient.getPost` devolve `imageUrl: ""`). Quando quem apagou foi a moderação de imagem, a foto é o que foi removido — e voltaria a aparecer em toda notificação daquele post, inclusive nas curtidas antigas.
- O evento carrega só o **código** do motivo, nunca o termo casado. `MESSAGE_BY_CODE` no handler traduz para pt-BR; código desconhecido cai numa frase genérica.
- Pode chegar duplicado (o worker republica quando o Kafka reentrega a mensagem de origem). O agrupamento por `type:refId` junta as duplicatas numa linha só na listagem.

O consumer usa `groupId: "notification-service-group"`, `fromBeginning: false`, retry com 10 tentativas e `initialRetryTime` de 300ms.

Este serviço **não produz** nenhum evento Kafka.

---

## Infra deste Serviço

- `Dockerfile`: build em 2 estágios (`builder`: `npm ci` → `prisma generate` → `tsc`; `runtime`: `npm ci --omit=dev`, copia `dist/`, `dist/generated`, `templates/`, `prisma/`). O `CMD` roda `prisma migrate deploy` antes de `node dist/server.js` — qualquer migration nova precisa ser compatível com deploy automático sem intervenção manual.
- `k8s/`: `deployment.yaml` (probes em `/health`, recursos limitados, `RollingUpdate`), `hpa.yaml`, `pdb.yaml`, `service.yaml`. Qualquer nova env var sensível deve ir via secret do k8s, nunca em texto plano no manifest.
- Porta padrão: **3006**.
- Sem `--max-old-space-size` explícito no CMD atual — se a memória do pod for ajustada, considere adicionar o flag alinhado ao `resources.limits.memory` do deployment.

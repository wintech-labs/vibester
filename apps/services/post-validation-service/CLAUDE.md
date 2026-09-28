# Post Validation Service

> Contexto específico do microserviço de validação de postagens do Vibester.
> Complementa o `CLAUDE.md` da raiz do monorepo. Em conflito, a raiz prevalece nas diretrizes gerais de produto/arquitetura; este arquivo prevalece nas convenções deste serviço. O código-fonte é sempre a fonte de verdade final.
>
> **Atenção**: este serviço **não tem banco de dados**. Não procure `repository/`, `migrations/` nem runner de migration — não existem, e a ausência é uma decisão, não uma pendência (ver "Por que não há banco"). Ele também **exige JWT**, como o `interaction-service` e diferente do `post-service`.

---

## Por que este serviço existe

Antes deste serviço, o `post-service` aceitava qualquer legenda de até 2000 caracteres e não havia filtro de linguagem, de link ou de spam em lugar nenhum do fluxo de criação de post. A única barreira de conteúdo do Vibester era a denúncia manual (`content.reported`, do `user-service`), que é **reativa**: alguém precisa ver o conteúdo, denunciar, e a moderação analisar.

Este serviço é a barreira preventiva. Ele responde a uma pergunta só, e responde rápido: *este conteúdo pode ser publicado?* O `post-service` faz essa pergunta antes de gravar (ver "Enforcement").

**Ele não cria, não edita e não remove post.** Se uma feature parece ser "fazer algo com o post", ela não é daqui — é do `post-service`.

---

## Responsabilidade do Serviço

- aplicar as regras da comunidade sobre o texto de uma postagem: vazio, tamanho, linguagem proibida, links e spam;
- devolver um veredito síncrono com motivo, rápido o bastante para ficar no caminho da criação do post;
- revalidar de forma assíncrona o que já foi publicado, consumindo `posts` do Kafka;
- classificar as imagens de cada post novo com a API de moderação da OpenAI e recomendar ocultação nas categorias graves (ver "Moderação de imagem");
- publicar `post.validation.rejected` quando a revalidação reprova, para o `notification-service` avisar o autor;
- manter a trilha de auditoria de toda validação realizada.

---

## Os dois caminhos — e por que são dois

O requisito pede API REST com latência abaixo de 200ms **e** processamento assíncrono. Não é contradição: são dois problemas diferentes.

| | `SERVICE_MODE=api` | `SERVICE_MODE=worker` |
|---|---|---|
| Gatilho | `POST /validations/post` | tópico `posts` do Kafka |
| Quando | antes de publicar | depois de publicado |
| Para quê | dar o veredito ao autor enquanto ele escreve | alcançar o que não passou pela rota |
| Depende de | Redis (opcional) | Kafka (crítico) + Redis (opcional) |
| Porta | 3008 | 3008 |

O entrypoint é `src/server.ts`, que despacha para `src/api.ts` ou `src/worker.ts`.

**Não junte os dois modos num processo só** (como o `notification-service` faz): a api escala por requisições/segundo, o worker por lag de partição. Juntos, um obriga o outro a escalar sem necessidade. Mesma decisão do `interaction-service`.

**Nunca renomeie `SERVICE_MODE` para `MODE`**: o Vitest injeta `process.env.MODE=test`, e o boot quebraria em qualquer contexto com ferramental Vite. Está comentado em `src/config/env.ts`.

---

## Enforcement — o que o filtro de fato barra

O `post-service` **chama este serviço antes de gravar** (`src/clients/validation.client.ts` lá) e recusa a criação com `422` quando o veredito é `valid: false`. Vale para `POST /posts` e `PATCH /posts/:postId`.

Três coisas que essa integração **não** faz, e que precisam estar claras:

1. **Indisponibilidade deixa passar.** Se este serviço não responde no orçamento, o `post-service` publica assim mesmo. É deliberado: barrar publicação quando o filtro cai transformaria um serviço auxiliar em ponto único de falha do Vibester. O worker é o que segura o outro lado — conteúdo que escapa numa queda é pego na revalidação. A política está em `PostService.enforceValidation`, não numa env var, porque é decisão de produto.
2. **Chamador sem token passa.** A rota daqui exige JWT e o `post-service` repassa o header `Authorization` que recebeu. O app mobile anexa o header em toda chamada, então na prática cobre o tráfego real; um script ou painel que chame o `post-service` direto, sem token, não é validado.
3. **Post já publicado com problema de texto não é removido.** Para texto, o worker só *avisa* (`action: "notify"`). Quem remove post publicado é a **moderação de imagem**, e só nas categorias graves (ver "Moderação de imagem").

Mesmo na remoção, este serviço **não chama o post-service**: ele publica a recomendação (`action: "hide"`) e o post-service, dono do ciclo de vida do post, decide executar. Fazer a validação deletar o post direto inverteria a dependência.

**Comentários continuam sem validação.** `POST /posts/:postId/comments` não passa por aqui. É a lacuna mais óbvia que sobrou, e fechá-la é adicionar a chamada no `CommentService` do `post-service` — o contrato desta rota já serve, sem mudança aqui.

---

## Moderação de imagem

No Vibester a mídia é obrigatória e a legenda é opcional: num post típico, o conteúdo **é** a foto. O worker classifica cada imagem de `post.created` com a **API de moderação da OpenAI** (`omni-moderation-latest`), que é gratuita.

### Fluxo

```
post.created → worker → para cada mídia (foto; de vídeo, a capa):
    cache no Redis? → senão, POST /v1/moderations com a URL pública → score por categoria
    → política (src/moderation/policy.ts) → allow | notify | hide
  → action mais grave do post:
      hide   → post.validation.rejected { action: "hide" } → post-service oculta
               → post.deleted (feed-service tira das timelines) + post.moderation.hidden
               → notification-service: "sua publicação foi removida porque…"
      notify → post.validation.rejected { action: "notify" } → aviso ao autor, post segue no ar
```

### Decisões que não são óbvias

1. **Uma imagem por chamada.** Com várias entradas, a API devolve um resultado combinado, e não daria para saber qual foto foi reprovada. O evento leva `mediaIndex`.
2. **A imagem vai pela URL pública do R2**: a OpenAI baixa sozinha, e o worker não trafega bytes. Só URL que começa por `MEDIA_PUBLIC_URL` é enviada — o post-service já exige isso, e aqui é defesa em profundidade: este serviço não manda URL arbitrária para um terceiro.
3. **Só conta categoria que a API avaliou na imagem** (`category_applied_input_types`). Ódio, assédio, ilícito e conteúdo sexual com menores são só de texto; o score deles numa entrada de imagem é ruído, e a política não o vê.
4. **O cache guarda o score, não a decisão.** Mudar os limites de `policy.ts` vale na hora para imagens já vistas, sem nova chamada. URL de mídia é UUID e não muda de conteúdo, então reentrega do Kafka não paga a checagem de novo.
5. **Falha da API deixa passar.** 429, 5xx, timeout e rede ganham até 2 novas tentativas (1 s e 3 s; o `Retry-After` do 429 tem precedência). 4xx não é tentado de novo. E há um **orçamento de 45 s por post**: a partição `posts` tem um consumidor só, e um post preso numa API lenta seguraria todos os de trás.
6. **`heartbeat` do Kafka no meio do processamento.** Dez imagens com novas tentativas passam dos 30 s do `sessionTimeout`; sem heartbeat, o Kafka tiraria o worker do grupo e reentregaria a mesma mensagem, em laço.
7. **Automutilação nunca oculta e nunca é tratada como infração.** O aviso é de acolhimento, com o CVV (188) — ver o notification-service.

### Política (ponto de partida, a calibrar)

| Categoria da API | Ação | Por quê |
|---|---|---|
| `sexual` ≥ 0.8 | ocultar | |
| `sexual` 0.5–0.8 | avisar | foto de festa com roupa curta marca `sexual` médio — num app de vida noturna, ocultar aqui seria falso positivo em massa |
| `violence/graphic` ≥ 0.8 / ≥ 0.5 | ocultar / avisar | |
| `violence` ≥ 0.8 | avisar | nunca oculta: uma luta de boxe num bar é evento |
| `self-harm*` ≥ 0.5 | avisar (apoio) | ver item 7 acima |

### Modos (`IMAGE_MODERATION_MODE`)

| Modo | Efeito |
|---|---|
| `off` | não classifica (padrão do código) |
| `observe` | classifica, mede e audita, **sem publicar nada** — padrão do manifest |
| `enforce` | publica a rejeição com `action` |

**Rollout:** subir em `observe`, olhar `image_moderation_score{category="sexual"}` em posts reais por 1–2 semanas, ajustar `policy.ts` e só então virar `enforce` em `k8s/deployment-worker.yaml`. No post-service, `POST_MODERATION_HIDE=off` é o freio de emergência da ocultação.

### O que fica de fora

- **Conteúdo sexual envolvendo menores em imagem**: a API só avalia isso em texto. O padrão para esse caso é comparar com banco de material conhecido — a Cloudflare oferece de graça (CSAM Scanning Tool) para sites atrás dela, se as fotos saírem por domínio próprio proxiado. Não configurado; precisa de teste com R2.
- **Símbolos de ódio e drogas em imagem**: a API não avalia; continua dependendo de denúncia.
- **Vídeo inteiro**: só a capa. Classificar o vídeo exigiria extrair quadros (ffmpeg) no worker.
- **Janela de exposição**: a foto fica no ar alguns segundos. Segurar o post fora do feed até aprovar exigiria um estado "pendente" no post-service e no feed-service.
- **Contestação**: o post fica marcado `is_deleted` no Cassandra, então restaurar é possível — mas não há fluxo para isso.

### Privacidade e limites

- **As fotos vão para a OpenAI.** Isso precisa constar na política de privacidade (`/privacidade` da landing page) antes de ligar `observe`.
- Plano gratuito: **250 requisições/min** (cerca de 360 mil por dia). Se imagem conta no limite de 10 mil tokens/min do plano gratuito, a documentação não diz — o modo `observe` mostra.
- Métricas: `image_moderation_total{result,cached}`, `image_moderation_skipped_total{reason}`, `image_moderation_duration_seconds`, `image_moderation_score{category}`. Auditoria: uma linha `audit: "post-validation-image"` por imagem, com URL, scores e decisão.

---

## Três limites de legenda — 280, 500 e 2000

Convivem três números, em três lugares:

| Onde | Limite | Efeito |
|---|---|---|
| App mobile (`_captionLimit` em `new_publication_screen.dart`) | **280** | o campo não deixa digitar além |
| Este serviço (`MAX_CONTENT_LENGTH`) | **500** | acima disso, `CONTENT_TOO_LONG` → 422 no post-service |
| `createPostSchema` do post-service | **2000** | acima disso, 400 do próprio post-service |

Na prática, **quem publica pelo app nunca chega aos 500**: o composer corta antes. O limite daqui só pega cliente que fale com o post-service direto, e para esses o 2000 do `createPostSchema` virou um limite morto (entre 501 e 2000, o veredito daqui barra antes). Também não há edição de legenda no app, então post antigo não esbarra no limite depois.

Ainda assim, três números para a mesma regra é dívida: o dia em que o app subir o limite do composer, os 500 daqui passam a recusar publicação. `MAX_CONTENT_LENGTH` é env var para que alinhar seja troca de config — ao mexer em qualquer um dos três, confira os outros dois.

---

## O que este serviço NÃO garante

Seja honesto sobre o alcance ao mexer aqui:

- **Não detecta conteúdo malicioso em link.** Saber para onde uma URL aponta exige chamada de rede, e o orçamento da rota é 200ms. O que se faz é o decidível sem I/O: esquema, formato, domínio em lista, encurtador, punycode, IP cru, credencial embutida. Um domínio novo de phishing passa até alguém colocá-lo em `BLOCKED_DOMAINS`. O encaixe natural para resolver isso é uma checagem de reputação (Safe Browsing e equivalentes) **no worker**, onde não há orçamento de latência — nunca na rota síncrona.
- **Imagem é checada depois de publicada, não antes.** A moderação de imagem roda no worker: a foto fica no ar os segundos entre a publicação e o fim da checagem. Vídeo só tem a capa checada, e a API não avalia em imagem símbolos de ódio, drogas nem conteúdo sexual envolvendo menores (ver "Moderação de imagem").
- **Não entende contexto.** Xingamento direcionado a uma pessoa e a mesma palavra em tom de brincadeira são idênticos para uma regex. Termos cujo sentido depende de contexto foram deixados fora da blocklist de propósito (ver `src/rules/data/blocklist.ts`); eles são trabalho da denúncia manual.
- **Não é irreversível.** A blocklist tem falso positivo e falso negativo. As métricas por código existem para medir os dois.

---

## Stack e Dependências deste Serviço

- Fastify 5 + `@fastify/cors` (`origin: true`), `@fastify/helmet`, `@fastify/rate-limit` (store no Redis), `@fastify/jwt` (**obrigatório**).
- **Redis** (`ioredis`) — só cache de veredito e store do rate limit. Best-effort nas duas pontas.
- Kafka (`kafkajs`) — no modo worker, consumidor de `posts` e produtor em `post.validation.rejected`. No modo api o produtor conecta mas a rota não publica.
- `zod` para env (`src/config/env.ts`) e payload (`src/schema/validation.schema.ts`).
- `prom-client` para métricas em `/metrics` (`src/metrics/registry.ts`, única fonte — não crie `Counter` solto em outro arquivo).
- **API de moderação da OpenAI** (só o worker), via `fetch` nativo em `src/moderation/openai.moderator.ts`, sem SDK. Ver "Moderação de imagem".
- **Sem banco de dados.** Sem Cassandra, sem Prisma, sem migration.
- Vitest: unit em `src/**/__tests__`, rota em `tests/integration`. Nenhum teste precisa de infra.

### Por que não há banco

A trilha de auditoria é log estruturado (`src/services/audit.service.ts`) + métricas, não tabela. Uma tabela significaria escrita no caminho síncrono de uma rota com orçamento de 200ms, mais um banco para operar, mais uma dependência capaz de derrubar o `/ready` — para um dado que ninguém consulta por chave primária.

Se um dia aparecer a necessidade de **consultar** a trilha ("mostre as rejeições deste usuário"), aí vira tabela — e quem grava é o **worker**, nunca a api.

### Auditoria — a lacuna de retenção

A decisão acima pressupõe um coletor de logs, e **o cluster não tem nenhum** (nada de Loki/Promtail ou equivalente em `apps/services/monitoring` nem em `k8s/`). Na prática, a trilha vive só no stdout do pod: `kubectl logs` alcança o container atual e o anterior, a rotação do kubelet apaga o resto, e um pod reiniciado leva a trilha junto.

Ou seja: toda validação **é registrada**, mas não fica **guardada**. Para auditoria de verdade, um dos dois:

1. **Coletor de logs no cluster** (Loki + Promtail é o par natural ao lado do Grafana que já existe). Resolve para todos os serviços de uma vez e não muda uma linha daqui — as linhas já saem em JSON com `audit: "post-validation"`. É decisão de infraestrutura.
2. **Persistir a trilha pelo worker**: a api publicaria cada auditoria num tópico Kafka (fora do caminho crítico, o produtor já está conectado) e o worker gravaria em tabela com TTL, no molde de `interactions_by_user` do `interaction-service`. Resolve só para este serviço, e traz banco, migration e credencial para dentro dele.

---

## As regras

Cada regra é uma **função pura** em `src/rules/*.rule.ts`: mesmo texto, mesmo veredito, sem I/O. É isso que torna o cache seguro (recalcular dá sempre o mesmo resultado) e o teste trivial.

`runRules` (`src/rules/index.ts`) roda **todas** e junta o resultado — o usuário recebe tudo que está errado de uma vez, em vez de descobrir um problema por tentativa.

### Calibragem — o ponto mais fácil de errar

O público do Vibester tem 18-27 anos e escreve `VAMOOOO HOJE TEM FESTA!!!`. **Um filtro que derruba isso é pior para o produto do que um que deixa passar um palavrão.** Falso positivo silencia usuário legítimo; falso negativo é recuperável pela denúncia.

Por isso:

- os limiares de spam são altos e quase nenhum sinal sozinho rejeita (`SPAM_THRESHOLD` e `WEIGHTS` em `src/rules/spam.rule.ts`, explícitos no topo do arquivo);
- a blocklist é conservadora, e o que foi deixado de fora está comentado com o motivo;
- palavrão obedece a `PROFANITY_BLOCKS`; **discurso de ódio rejeita sempre** e nenhuma flag desliga.

O bloco `"conteudo legitimo nao pode ser rejeitado"` em `src/rules/__tests__/rules.test.ts` é a rede de proteção disso. Ao mexer em regra, é o primeiro teste a rodar.

### Evasão

`src/rules/normalize.ts` põe texto e blocklist no mesmo alfabeto: NFKD, sem acento, minúscula, homoglifo cirílico/grego, leet, repetição colapsada. Duas armadilhas já pagas:

1. **`\b` só funciona no texto com separador preservado.** A segunda passada (`stripped`, sem separador nenhum) pega `c-a-r-a-l-h-o`, mas não tem fronteira de palavra — por isso só termos marcados `substring` são procurados lá. `porra` não pode ser `substring`: casaria dentro de `porrada`.
2. **Pontuação-leet só vale entre letras.** Traduzir `!` para `i` sempre fazia `porra!` virar `porrai`, que escapava do casamento por palavra inteira — evasão criada pela própria normalização. Há teste de regressão.

**Ao editar `TERMS`, suba `BLOCKLIST_VERSION`.** Ela entra na chave do cache; sem isso, veredito calculado com a lista antiga continua sendo servido até o TTL expirar.

---

## Segurança — obrigatório em qualquer alteração

1. **JWT é obrigatório.** `src/plugins/auth.ts` verifica o token e o controller lê o `accountId` dele. `userId` **nunca** vem do body — e o payload nem aceita o campo (400). Sem token, o endpoint é um oráculo anônimo da blocklist: um script sonda em loop até achar o texto que passa.
2. **Use `accountId`, nunca `userId` do token.** O `auth-service` assina `{ userId, accountId }`; `userId` é o id da linha `Access` (autenticação) e `accountId` é a identidade pública que `post-service`, `user-service` e `feed-service` usam. Use sempre `getAccountId(request)`.
3. **A resposta nunca revela qual termo ou domínio casou.** O detalhe vai só para `auditDetails` → log e métrica. Os tipos são separados (`ValidationIssue` vs `AuditDetail`) justamente para que um `...spread` distraído não vaze. Há teste que falha se vazar.
4. **Erro inesperado vira `500 { message: "Internal server error" }`**, sem `error.message` e sem stack (`src/errors/error.handler.ts`). Num filtro de conteúdo, a mensagem crua contaria como ele funciona por dentro.
5. **Nada de regex construída a partir de entrada do usuário, e nada de quantificador aninhado.** A blocklist vira alternância de literais escapados (linear, sem backtracking); a extração de URL usa um padrão simples de propósito. Um regex "completo" de URL é o exemplo de manual de ReDoS, e aqui o texto vem do usuário.
6. **`bodyLimit` (`MAX_BODY_BYTES`) é a guarda de CPU.** Todas as regras são lineares no tamanho do texto, então limitar a entrada limita o custo. É o que permite rodar todas as regras sem interromper.
7. **Payload é estrito** (`src/config/fastify.ts`): campo desconhecido e tipo errado viram 400, em vez de serem removidos/convertidos em silêncio como o Fastify faz por padrão. Um cliente que mandasse `userId` no body precisa *saber* que o campo foi ignorado.
8. **Rate limit é por conta, não por IP** (`rateLimitKey` em `src/plugins.ts`). Por IP, o limite quebrava no uso real: o chamador principal é o post-service, então todo tráfego chega do IP do pod dele e a plataforma inteira dividiria um balde de `RATE_LIMIT_MAX` por minuto. O 121º post do minuto receberia 429, o post-service trataria como indisponibilidade e publicaria sem validar — a validação se desligaria sozinha sob carga, sem erro visível. A chave é o `accountId` do token **verificado** (decodificar sem verificar deixaria alguém fabricar um id novo por requisição e ganhar balde vazio); sem token válido, cai no IP. `src/__tests__/plugins.ratelimit.test.ts` prova o cenário com o plugin real, e `plugins.wiring.test.ts` quebra se alguém tirar o `keyGenerator`.
9. **Rate limit usa o Redis como store**, compartilhado entre réplicas. `skipOnError: true`: queda do Redis desliga o limite, nunca derruba a requisição. A métrica `rate_limit_exceeded_total` é incrementada em `onExceeded` — **não** em `onExceeding`, que roda em toda requisição ainda dentro do limite e faria a métrica contar tráfego normal como bloqueio.
10. **Segredos** (`JWT_SECRET`) sempre via Secret do k8s.

---

## Performance — obrigatório em qualquer alteração

1. **Orçamento de 200ms.** Todas as regras são CPU pura e lineares; o único I/O da rota é o Redis, com `commandTimeout: 150ms` e `enableOfflineQueue: false` — num orçamento apertado, um Redis lento é pior do que um Redis ausente. Não introduza I/O novo no caminho síncrono; o lugar de checagem que precisa de rede é o worker.
2. **O cache é para latência, não para correção.** As regras são puras, então um miss custa CPU e nada mais. Falha de Redis nunca vira erro para o usuário (`src/config/redis.ts` não lança).
3. **A chave do cache inclui tudo que muda o veredito para o mesmo texto**: versão da blocklist, limites e flags (`src/utils/content-hash.ts`). Sem isso, desligar `PROFANITY_BLOCKS` continuaria reprovando post por um TTL inteiro.
4. **A api não escreve em lugar nenhum.** Sem banco, sem fila. É o que a deixa escalar horizontalmente sem coordenação.
5. **`validation_rules_duration_seconds` mede só as regras**, separado de `http_request_duration_seconds`. É o que distingue "as regras ficaram lentas" de "a rede ficou lenta".
6. **Mensagem malformada não trava a partição**: o handler devolve `processed: false` em vez de lançar, e o worker dá ack. **Só falha de publicação propaga**, para o Kafka reentregar. Preserve a distinção — transformar erro de parse em exceção cria retry infinito numa mensagem envenenada.
7. **Reentrega pode gerar notificação duplicada.** É assumido: o consumidor precisa tolerar.

---

### Carga medida

Gerador de carga em Node contra a api real, com Redis real (cache e rate limit), conteúdo majoritariamente único (força cache miss), metade reprovado, 2.000 contas distintas — a mesma mistura do cenário k6 `load-tests/scenarios/08-post-validation.js`. Um processo, sem limite de CPU, numa máquina de desenvolvimento:

| Simultâneas | Vazão | p95 | p99 | Erros |
|---|---|---|---|---|
| 50 | 736 req/s | 102 ms | 149 ms | 0 |
| 100 | 887 req/s | 163 ms | 251 ms | 0 |
| 150 | 868 req/s | **255 ms** | 421 ms | 0 |

O processo satura perto de **880 req/s**; acima disso a latência é fila no event loop (uma requisição isolada leva ~5 ms). No cluster o pod tem `limits.cpu: 500m`, então satura antes — o `hpa.yaml` existe por isso. Para ter o número do cluster, rode o cenário k6 lá; estes são de referência.

## Health checks

`/health` e `/ready` são endpoints diferentes de propósito.

- `/health` (liveness): só diz que o processo está vivo. Não checa dependência — reiniciar o pod não conserta um Redis fora do ar.
- `/ready` (readiness): **no modo api nunca devolve 503.** Nenhuma dependência é crítica ali: sem Redis ele valida igual, só recalculando; sem Kafka a rota continua respondendo. Reporta `status: "degraded"` com 200, e o lugar de reagir é um alerta sobre `redis: false`, não o balanceador. **No modo worker o Kafka é crítico** e o `/ready` devolve 503 sem consumidor — um worker sem consumidor não faz nada, e mantê-lo "pronto" esconderia a falha.

O `post-service` aponta liveness e readiness para o mesmo `/health`, que checa o banco — o efeito é reiniciar o pod quando o Astra oscila. Não replique isso.

---

## Testes

- `npm test` — unit + rota. **Não precisa de nenhuma infra.**
- `npm run test:unit` — só `src/**/*.test.ts`.
- `npm run test:coverage` — thresholds **70% linhas, 70% funções, 60% branches**. Não reduza para fazer um PR passar: aqui um branch não coberto é um post legítimo derrubado em produção.
- `tests/setup/vitest.setup.ts` mocka `src/config/env` **e** `src/config/redis` — o cache não acerta nada por padrão, para que cada teste de regra exercite as regras de verdade. `src/config/__tests__/redis.test.ts` dá `vi.unmock` e prova o módulo real.
- `tests/helpers/fastify.test.helper.ts` usa as **mesmas opções de AJV** do servidor real (`src/config/fastify.ts`). Se divergirem, o teste valida um comportamento de payload que não é o de produção.

Toda feature nova precisa de: teste unitário da regra (incluindo o caso legítimo que ela **não** pode rejeitar) e teste da rota.

---

## Variáveis de Ambiente

Toda variável é validada por Zod em `src/config/env.ts` (`process.exit(1)` se inválida). Não leia `process.env` direto em outro arquivo do `src/`. Propague em `.env.example` (placeholder vazio) e nos **dois** Deployments do `k8s/`.

---

## Infra deste Serviço

- `Dockerfile`: build em 2 estágios. `npm install --legacy-peer-deps` contorna um bug do arborist (npm 10) com os peers opcionais do vitest. O `CMD` é só `node dist/src/server.js` — **sem migrate**, porque não há banco.
- `k8s/`: `deployment-api.yaml`, `deployment-worker.yaml`, `service.yaml` e `hpa.yaml`. O **worker não tem Service** (nada o chama por HTTP) nem HPA (escala por lag de partição, não por CPU). O worker usa `strategy: Recreate`, para não forçar um rebalance extra do consumer group durante deploy. O Deployment da api **não declara `replicas`**: o HPA é o dono do número, e como o CI faz `kubectl apply` a cada deploy, um `replicas: 1` no YAML derrubaria as réplicas que o HPA subiu.
- CI (`.github/workflows/post-validation-service.yml`) usa `npm ci --legacy-peer-deps`, roda typecheck, unit, rota e o gate de cobertura. No deploy, faz **`kubectl apply -f k8s/` antes do `set image`** (sem isso o primeiro deploy falha — `set image` não cria Deployment — e mudança nos manifests nunca chegaria ao cluster), e a **api sobe antes do worker**: não há migration criando ordem obrigatória, e a api é quem está no caminho quente.
- Os dois Deployments têm `prometheus.io/scrape|port|path` no **template do pod**, que é o que o job `kubernetes-pods` do `monitoring/prometheus.yml` lê. No metadata do Deployment (onde outros serviços do repo colocam) a anotação não tem efeito.
- Observabilidade: log estruturado (Pino na api, JSON no audit) + métricas Prometheus em `/metrics`. Sem tracing distribuído. O que mais faltará primeiro no worker é **lag do consumer group** — não assuma que existe.
- Swagger em `/docs`, sempre registrado, sem flag para desligar.

---

## Primeiro deploy — passo manual

O CI cria tudo que está no repositório (Deployments e Service), mas **não o Secret**: segredo não vive no git, e nenhum workflow do monorepo cria Secret. Antes do primeiro deploy, alguém com acesso ao cluster precisa criar:

```bash
kubectl create secret generic post-validation-service-secret --from-literal=JWT_SECRET='<o mesmo JWT_SECRET do auth-service>' --from-literal=KAFKA_BROKERS='<os mesmos brokers dos outros serviços>' --from-literal=OPENAI_API_KEY='<chave da API da OpenAI>' --from-literal=MEDIA_PUBLIC_URL='<o mesmo R2_PUBLIC_URL do post-service>'
```

`OPENAI_API_KEY` e `MEDIA_PUBLIC_URL` só são usados pelo worker, para a moderação de imagem. Se faltarem, o worker sobe normalmente, com a moderação de imagem desligada e o motivo no log de boot (`Moderação de imagem desligada`).

`REDIS_URL` não entra no Secret: vem do ConfigMap `redis-env`, que já existe no cluster (`apps/services/k8s/redis/configmap.yaml`). Sem o Secret, os pods ficam em `CreateContainerConfigError` e o `rollout status` do CI estoura o timeout.

O `JWT_SECRET` precisa ser **idêntico** ao do auth-service — é ele que assina os tokens que o post-service repassa. Com um valor diferente, toda consulta volta 401, o post-service trata como indisponível e publica sem validar: a integração pareceria funcionar, só que sem barrar nada. `post_validation_total{result="unavailable"}` alto logo depois do deploy é o sintoma.

---

## Integração com o notification-service

O worker publica `post.validation.rejected` no envelope `{ eventId, eventType, occurredAt, data }` — o mesmo que o `post-service` usa. **Isso não é estética**: o `notification-service` desembrulha com `unwrapEventData`, que procura exatamente `eventType` + `data`. Publicar payload solto faria o handler não achar `postId` e descartar a notificação em silêncio (foi o bug que o `envelope.ts` de lá existe para consertar).

Do outro lado, `notification-service/src/kafka/handlers/postValidationRejected.handler.ts` traduz cada código em texto pt-BR e grava uma notificação do tipo `post_rejected` — **só quando `action` é `notify`**. Com `action: "hide"` ele não faz nada: o aviso "foi removida" sai de `post.moderation.hidden`, que o post-service publica depois de ocultar de fato. O evento carrega só o **código** (e `mediaIndex`), nunca o termo casado nem o score — a notificação não pode virar oráculo do filtro.

---

## O que NÃO fazer aqui

- criar, editar, esconder ou remover post (é do `post-service`);
- chamar outro serviço de forma síncrona a partir da rota de validação;
- adicionar I/O no caminho síncrono — checagem que precisa de rede vai no worker;
- devolver ao cliente qual termo/domínio casou;
- aceitar `userId` no body;
- construir regex a partir de entrada do usuário;
- mexer em `TERMS` sem subir `BLOCKLIST_VERSION`;
- baixar o threshold de cobertura para um PR passar.

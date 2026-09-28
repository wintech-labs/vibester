import Fastify from "fastify";
import helmet from "@fastify/helmet";
import compress from "@fastify/compress";
import multipart from "@fastify/multipart";
import { getCassandraClient } from "./config/cassandra";
import { redis } from "./config/redis";
import { routes } from "./routes";
import { registerSwagger } from "./config/swagger";
import { producer } from "./kafka/producer";
import { startConsumer, stopConsumer } from "./kafka/consumer";
import { buildAccountContentDeletionService } from "./services/account-content-deletion.service";
import { PostService } from "./services/post.service";
import { PostRepository } from "./repository/post.repository";
import { LikeRepository } from "./repository/like.repository";
import { env } from "./config/env";
import { registerErrorHandler } from "./errors/error.handler";
import { registerCorsAndRateLimit, registerHttpMetrics } from "./plugins";

const app = Fastify({
    logger: {
        level: "info",
        serializers: {
            req(req) { return { method: req.method, url: req.url }; },
        },
    },
    bodyLimit: 1 * 1024 * 1024,
    requestTimeout: 30000,
});

registerHttpMetrics(app);

app.register(helmet, {
    contentSecurityPolicy: false,
});

app.register(compress, { global: true });

app.register(multipart, {
    limits: {
        fileSize: 10 * 1024 * 1024,
        files: 20,
    },
});

registerErrorHandler(app);

async function start() {
    try {
        // Precisa ser aguardado antes de qualquer outro register/listen: a
        // função é async (faz `await app.register(cors, ...)` internamente
        // antes de registrar o rate limit), então chamá-la sem await deixava
        // o registro do rate limit dependente de sorte de timing em vez de
        // uma garantia explícita de ordem.
        await registerCorsAndRateLimit(app, {
            corsAllowedOrigins: env.cors_allowed_origins,
            rateLimitMax: env.rate_limit_max,
            redis,
        });

        await redis.connect();
        await producer.connect();
        await getCassandraClient().connect();

        // Consumidor do serviço: apaga o conteúdo de contas excluídas
        // (user.deleted, do auth-service) e oculta post que a moderação de
        // imagem pediu (post.validation.rejected com action "hide", do
        // post-validation-service).
        await startConsumer(
            buildAccountContentDeletionService(),
            new PostService(new PostRepository(), new LikeRepository()),
        );

        await registerSwagger(app);
        await app.register(routes);

        await app.listen({
            port: Number(env.port) || 3000,
            host: "0.0.0.0",
        });

        async function gracefulShutdown(signal: string) {
            app.log.info({ signal }, "Iniciando shutdown gracioso");
            try {
                await app.close();
                await stopConsumer();
                await producer.disconnect();
                await getCassandraClient().shutdown();
                await redis.quit();
                app.log.info("Shutdown concluído");
                process.exit(0);
            } catch (err) {
                app.log.error({ err }, "Erro durante shutdown");
                process.exit(1);
            }
        }

        process.on("SIGTERM", () => gracefulShutdown("SIGTERM"));
        process.on("SIGINT", () => gracefulShutdown("SIGINT"));
    } catch (error) {
        app.log.error({ err: error }, "Falha ao iniciar o servidor");
        process.exit(1);
    }
}

start();

import { vi, describe, it, expect, beforeAll, afterAll, beforeEach } from "vitest";

// O workflow de integração não define estes segredos; sem eles o login não
// assina token e as rotas de admin ficam desligadas. Precisam existir antes de
// src/config/env ser carregado.
vi.hoisted(() => {
    process.env.JWT_SECRET ||= "real-test-jwt-secret";
    process.env.ADMIN_API_KEY ||= "real-test-admin-key";
});

const { mockProducerSend } = vi.hoisted(() => ({
    mockProducerSend: vi.fn().mockResolvedValue([]),
}));

vi.mock("../../src/kafka/producer", () => ({
    producer: { connect: vi.fn(), disconnect: vi.fn(), send: mockProducerSend },
}));

import { randomUUID } from "node:crypto";
import { hash } from "bcryptjs";
import prismaClient from "../../src/prisma/index";
import { redis } from "../../src/config/redis";
import { buildServer } from "../helpers/fastify.test.helper";

const EMAIL = "conta.real@example.com";
const OLD_PASSWORD = "senhaAntiga1";

function emittedPasswordCode(email: string): string {
    const msg = mockProducerSend.mock.calls
        .filter(([record]) => record.topic === "auth.password.reset")
        .map(([record]) => JSON.parse(record.messages[0].value) as { email: string; code: string })
        .reverse()
        .find((m) => m.email === email);
    if (!msg) throw new Error(`Nenhum código de senha emitido para ${email}`);
    return msg.code;
}

describe("auth-service — senha, exclusão e suspensão (Postgres + Redis reais)", () => {
    let app: Awaited<ReturnType<typeof buildServer>>;
    let accountId: string;

    const login = (password: string) =>
        app.inject({ method: "POST", url: "/login", payload: { email: EMAIL, password } });

    beforeAll(async () => {
        await redis.connect();
        app = await buildServer();
    });

    afterAll(async () => {
        await app.close();
        await redis.disconnect();
        await prismaClient.$disconnect();
    });

    beforeEach(async () => {
        await prismaClient.access.deleteMany();
        await redis.del(`pwreset:${EMAIL}`);
        await redis.del(`auth:fail:login:${EMAIL}`);
        mockProducerSend.mockClear();

        accountId = randomUUID();
        await prismaClient.access.create({
            data: { accountId, username: "@contareal", email: EMAIL, passwordHash: await hash(OLD_PASSWORD, 10) },
        });
    });

    it("redefine a senha com o código enviado e só a nova senha entra", async () => {
        const forgot = await app.inject({ method: "POST", url: "/password/forgot", payload: { email: EMAIL } });
        expect(forgot.statusCode).toBe(202);

        const code = emittedPasswordCode(EMAIL);
        const wrong = code === "000000" ? "111111" : "000000";
        expect((await app.inject({
            method: "POST", url: "/password/reset",
            payload: { email: EMAIL, code: wrong, password: "senhaNova123" },
        })).statusCode).toBe(422);

        const reset = await app.inject({
            method: "POST", url: "/password/reset",
            payload: { email: EMAIL, code, password: "senhaNova123" },
        });
        expect(reset.statusCode).toBe(200);

        expect((await login(OLD_PASSWORD)).statusCode).toBe(401);
        expect((await login("senhaNova123")).statusCode).toBe(200);

        // Código é de uso único.
        expect((await app.inject({
            method: "POST", url: "/password/reset",
            payload: { email: EMAIL, code, password: "outraSenha123" },
        })).statusCode).toBe(404);
    });

    it("pedido para email sem conta responde igual e não envia nada", async () => {
        const res = await app.inject({ method: "POST", url: "/password/forgot", payload: { email: "ninguem@example.com" } });
        expect(res.statusCode).toBe(202);
        expect(mockProducerSend).not.toHaveBeenCalled();
    });

    it("exclui a conta do token, publica user.deleted e o login deixa de funcionar", async () => {
        const { accessToken: token } = JSON.parse((await login(OLD_PASSWORD)).payload);

        const wrong = await app.inject({
            method: "DELETE", url: "/account", payload: { password: "errada123" },
            headers: { authorization: `Bearer ${token}` },
        });
        expect(wrong.statusCode).toBe(401);
        expect(await prismaClient.access.count()).toBe(1);

        const res = await app.inject({
            method: "DELETE", url: "/account", payload: { password: OLD_PASSWORD },
            headers: { authorization: `Bearer ${token}` },
        });
        expect(res.statusCode).toBe(204);
        expect(await prismaClient.access.findUnique({ where: { accountId } })).toBeNull();

        const deleted = mockProducerSend.mock.calls.find(([record]) => record.topic === "user.deleted");
        expect(JSON.parse(deleted![0].messages[0].value)).toMatchObject({ accountId, userId: accountId });

        expect((await login(OLD_PASSWORD)).statusCode).toBe(401);
    });

    it("conta suspensa não entra; reativada volta a entrar", async () => {
        const headers = { "x-admin-key": process.env.ADMIN_API_KEY! };

        expect((await app.inject({ method: "POST", url: `/admin/accounts/${accountId}/suspend`, headers })).statusCode).toBe(204);
        const row = await prismaClient.access.findUniqueOrThrow({ where: { accountId } });
        expect(row.suspendedAt).toBeInstanceOf(Date);

        expect((await login(OLD_PASSWORD)).statusCode).toBe(403);
        expect((await login("errada123")).statusCode).toBe(401);

        expect((await app.inject({ method: "POST", url: `/admin/accounts/${accountId}/unsuspend`, headers })).statusCode).toBe(204);
        expect((await login(OLD_PASSWORD)).statusCode).toBe(200);
    });

    it("recusa cadastro de menor de 18 anos", async () => {
        const bornAt = new Date();
        bornAt.setUTCFullYear(bornAt.getUTCFullYear() - 17);

        const res = await app.inject({
            method: "POST", url: "/register",
            payload: { username: "menor", name: "Menor", email: "menor@example.com", password: "senha123", bornAt: bornAt.toISOString().slice(0, 10) },
        });

        expect(res.statusCode).toBe(400);
        expect(mockProducerSend).not.toHaveBeenCalled();
    });
});

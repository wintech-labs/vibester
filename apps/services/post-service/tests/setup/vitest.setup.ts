import { vi } from 'vitest';

vi.mock('../../src/config/env', () => ({
  env: {
    port: '3005',
    secure_connect_bundle: '/fake/bundle.zip',
    astra_client_id: 'test-client-id',
    astra_client_secret: 'test-client-secret',
    astra_token: 'test-token',
    keyspace: 'test_keyspace',
    kafka_brokers: 'localhost:9092',
    r2_account_id: 'test-r2-account',
    r2_access_key_id: 'test-r2-key',
    r2_secret_access_key: 'test-r2-secret',
    r2_bucket_name: 'test-bucket',
    r2_public_url: 'https://test.r2.dev',
    redis_url: 'redis://localhost:6379',
    // post-validation-service. `block` é o padrão de produção, e mantê-lo aqui
    // faz os testes exercitarem o caminho real. Os testes existentes continuam
    // passando porque nenhum manda header `Authorization` — sem token o cliente
    // devolve `skipped` antes de qualquer chamada de rede.
    post_validation_url: 'http://post-validation.test',
    post_validation_timeout_ms: 1000,
    post_validation_mode: 'block',
    post_moderation_hide: true,
  },
}));

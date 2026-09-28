import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    globals: true,
    environment: "node",
    include: ["src/**/*.test.ts", "tests/integration/**/*.spec.ts"],
    exclude: ["**/node_modules/**", "**/dist/**"],
    setupFiles: ["tests/setup/vitest.setup.ts"],
    coverage: {
      provider: "v8",
      include: [
        "src/rules/**",
        "src/moderation/**",
        "src/services/**",
        "src/controllers/**",
        "src/kafka/handlers/**",
        "src/utils/**",
        "src/routes.ts",
      ],
      exclude: ["**/__tests__/**"],
      reporter: ["text", "json-summary", "html"],
      thresholds: { lines: 70, functions: 70, branches: 60 },
    },
    reporters: ["verbose"],
  },
});

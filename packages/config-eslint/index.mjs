import js from "@eslint/js";
import globals from "globals";
import tseslint from "typescript-eslint";

export function createBaseConfig({ browser = false, node = true } = {}) {
  return [
    js.configs.recommended,
    ...tseslint.configs.recommended,
    {
      files: ["**/*.{ts,tsx,js,jsx,mjs,cjs}"],
      languageOptions: {
        ecmaVersion: "latest",
        sourceType: "module",
        globals: {
          ...(browser ? globals.browser : {}),
          ...(node ? globals.node : {})
        }
      },
      rules: {
        "no-console": ["warn", { allow: ["warn", "error"] }]
      }
    },
    {
      ignores: [
        "dist/**",
        "build/**",
        "coverage/**",
        "node_modules/**",
        ".turbo/**"
      ]
    }
  ];
}

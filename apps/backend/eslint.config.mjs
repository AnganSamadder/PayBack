import { createBaseConfig } from "@payback/config-eslint";

export default [
  ...createBaseConfig({ node: true }),
  {
    ignores: ["convex/_generated/**"]
  },
  {
    files: ["convex/**/*.ts", "tests/**/*.ts"],
    rules: {
      "@typescript-eslint/no-explicit-any": "off",
      "@typescript-eslint/no-unused-vars": "off",
      "no-console": "off"
    }
  }
];

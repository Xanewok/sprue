import js from "@eslint/js";
import globals from "globals";

export default [
  { ignores: ["**/lib/**", "**/out/**", "**/cache/**", "**/node_modules/**", "**/broadcast/**", "**/deployments/**"] },
  js.configs.recommended,
  {
    languageOptions: { globals: globals.node },
    rules: {
      "no-empty": ["error", { allowEmptyCatch: true }],
      "no-unused-vars": ["error", { ignoreRestSiblings: true }],
    },
  },
];

// eslint-config-next 16 ships flat configs (what `create-next-app` generates
// for Next 16). Upstream's code is kept as written: the rules that arrived
// with eslint-config-next 16 after it was written are turned off by name,
// and only where it trips them.
import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  {
    files: ["**/*.js"],
    rules: {
      // Upstream is CommonJS config files and plain-JS pages.
      "@typescript-eslint/no-require-imports": "off",
    },
  },
  {
    // lib/Store.js applies each Realtime event to its state from an effect,
    // as upstream wrote it; the rule that flags that pattern arrived with
    // eslint-config-next 16, after the example was written.
    files: ["lib/Store.js"],
    rules: { "react-hooks/set-state-in-effect": "off" },
  },
  globalIgnores([".next/**", ".open-next/**", "out/**", "build/**", "next-env.d.ts", "public/**"]),
]);

export default eslintConfig;

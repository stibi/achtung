// Astro's native compiler for Linux x86-64 needs AVX2 and dies with "Illegal instruction"
// on CPUs without it (older Xeons, some VMs). There, this swaps in the compiler's WebAssembly
// build, the way Astro itself does on StackBlitz. Everywhere else it does nothing.
// Loaded before Astro by the package.json scripts (`NODE_OPTIONS=--import=…`), so the
// processes Astro starts in the background load it too.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import module from "node:module";
import { homedir } from "node:os";
import { join } from "node:path";

const native = "@astrojs/compiler-binding-linux-x64-gnu";

function lacksAvx2() {
  if (process.platform !== "linux" || process.arch !== "x64") {
    return false;
  }
  return !/^flags\s*:.*\bavx2\b/m.test(readFileSync("/proc/cpuinfo", "utf8"));
}

/** The WebAssembly build of the compiler version Astro uses, installed once into a cache. */
function webAssemblyCompiler() {
  // astro → @astrojs/compiler-rs → @astrojs/compiler-binding, which loads the native one.
  const binding = ["astro", "@astrojs/compiler-rs", "@astrojs/compiler-binding"].reduce(
    (from, name) => module.createRequire(from).resolve(`${name}/package.json`),
    import.meta.filename,
  );
  const { version } = JSON.parse(readFileSync(binding, "utf8"));
  const cache = join(process.env.XDG_CACHE_HOME ?? join(homedir(), ".cache"), `astro-compiler-wasi-${version}`);
  const entry = join(cache, "node_modules/@astrojs/compiler-binding-wasm32-wasi/astro.wasi.cjs");
  if (!existsSync(entry)) {
    console.warn(`[website] no AVX2: installing Astro's WebAssembly compiler ${version} into ${cache}`);
    mkdirSync(cache, { recursive: true });
    writeFileSync(join(cache, "package.json"), "{}\n");
    execFileSync(
      "pnpm",
      ["add", "--ignore-workspace", "--force", `@astrojs/compiler-binding-wasm32-wasi@${version}`],
      // Without NODE_OPTIONS: pnpm must not load this script again.
      { cwd: cache, stdio: "inherit", env: { ...process.env, NODE_OPTIONS: "" } },
    );
  }
  return entry;
}

if (lacksAvx2()) {
  const compiler = webAssemblyCompiler();
  module.registerHooks({
    resolve: (specifier, context, nextResolve) =>
      nextResolve(specifier === native ? compiler : specifier, context),
  });
}

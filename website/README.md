# Website

The public site at <https://achtunk8s.io>: what the app is, why, how it works, and how to
run your own. Static HTML built by [Astro](https://astro.build), served as
[Cloudflare Workers static assets](https://developers.cloudflare.com/workers/static-assets/).
No JavaScript framework runs in the browser; the only script makes the clips play while
they are on screen.

The site uses the new brand **achtunk8s**, always lowercase, like `k9s` or `kubectl`
("Achtung" with k8s; it sounds the same). The app and the repository are still called
Achtung. The brand, the address and the repository URL live in `src/site.ts`, so the
repository rename is a one-line change there.

## Commands

From the repository root (`pnpm install` there installs the site too; it is part of the
pnpm workspace):

```bash
pnpm --dir website run dev        # live-reloading dev server on :4321
pnpm --dir website run build      # static site into website/dist/
pnpm --dir website run preview    # serve dist/ on :4321
pnpm --dir website run check      # astro check, build, html-validate, link and fragment check
```

`check` runs in the Stop hook and the pre-commit hook (for changes in `website/`,
`docs/media/` and `macos/Icon/`), in CI, and before every deploy. Its link check covers every link inside the site, including
`#fragments`; links to GitHub and other sites are skipped, so it works offline.

On x86-64 Linux CPUs without AVX2, Astro's native compiler crashes with "Illegal
instruction". `scripts/compiler-fallback.mjs`, loaded by every script above, notices and
uses the compiler's WebAssembly build instead (installed once into
`~/.cache/astro-compiler-wasi-<version>`). Elsewhere it does nothing. Run Astro through
`pnpm run astro …`, not `pnpm exec astro …`, so the fallback is loaded.

## Structure

| Path | What |
|---|---|
| `src/site.ts` | Brand, address, repository URL, tagline and description |
| `src/pages/index.astro` | The page: hero, the problem, features, how it works, roadmap, self-hosting |
| `src/pages/404.astro` | Not found (served with status 404, kept out of the sitemap) |
| `src/layouts/Base.astro` | `<head>` (title, description, canonical, Open Graph, Twitter card, JSON-LD), header, footer |
| `src/components/Shot.astro` | A screenshot or clip in a window frame, or a placeholder |
| `src/lib/media.ts` | Finds shots in `docs/media/` |
| `src/pages/og.png.ts` | The Open Graph image, drawn at build time from the app icon and a pixel font |
| `src/pages/favicon.svg.ts`, `apple-touch-icon.png.ts` | Icons from `macos/Icon/AppIcon.svg` |
| `src/pages/posters/[name].webp.ts` | First frame of a clip's GIF, as its poster |
| `src/pages/robots.txt.ts` | `robots.txt`; the sitemap comes from `@astrojs/sitemap` |
| `src/styles/global.css` | All styles; light and dark follow the system |
| `wrangler.jsonc` | Cloudflare config: assets only, no Worker code |

The site copies nothing: the app icon, the coffee-break krysa and the screenshots are read
from where the app keeps them (`macos/Icon/`, `docs/media/`) at build time.

## Screenshots

Each feature shows `docs/media/<name>.mp4` if it exists (with `<name>.png`, or else the
first frame of `<name>.gif`, as its poster), otherwise `docs/media/<name>.png`, otherwise
a placeholder. The build prints a line for each placeholder. The names follow
`docs/media/SHOTLIST.md`; to add a shot, drop the file there and rebuild.

| Feature | File |
|---|---|
| Hero | `achtung-demo.mp4` (exists) |
| Home | `home.png` |
| Live and unread | `live.png` |
| One alert, with its history | `resent.png` |
| Readable alerts, Copy for Agent | `alert-detail.png` |
| Search | `search.png` (or the clip `search.mp4`) |
| Silence | `silence.png` (or `silence.mp4`) |
| Notifications | `notification.png` (or `notification.mp4`) |
| Menu bar | `menu-bar.png` |

## Deploying to Cloudflare

Every push to `main` that touches `website/`, `docs/media/`, `macos/Icon/` or the
lockfile runs `.github/workflows/website.yml`: the same `check` as CI, then
`wrangler deploy` of the built `dist/`. If the check fails, nothing is deployed. Deploys
never overlap; a newer push waits for the running one. Run it by hand from the Actions tab
(**Run workflow**) to redeploy.

The deploy creates or updates the Worker `achtunk8s-website` (static assets only) and the
custom domain `achtunk8s.io` from `routes` in `wrangler.jsonc`; Cloudflare adds the DNS
record and the certificate. Unknown paths get `404.html` with status 404.

Setup, once:

1. **Domain.** Add `achtunk8s.io` to the Cloudflare account as a zone and point the
   registrar's nameservers at Cloudflare. Wait until the zone is **Active**: a Workers
   custom domain needs an active zone, and the hostname must not already have a CNAME
   record.
2. **API token.** My Profile → API Tokens → Create Token → Custom token, named
   "achtunk8s.io deploy", with only these permissions:

   | Scope | Permission | Access |
   |---|---|---|
   | Account | Workers Scripts | Edit |
   | Account | Account Settings | Read |
   | Zone | Workers Routes | Edit |

   Account resources: only this account. Zone resources: Specific zone → `achtunk8s.io`.
   These are the account and zone permissions of the token Cloudflare's own Workers
   Builds creates. Workers Scripts: Edit uploads the Worker and its assets and attaches
   the custom domain; Workers Routes: Edit covers the zone.
3. **GitHub secrets.** Repository → Settings → Secrets and variables → Actions → New
   repository secret:
   - `CLOUDFLARE_API_TOKEN`: the token.
   - `CLOUDFLARE_ACCOUNT_ID`: the account ID (Workers & Pages overview, or the zone's
     overview page, right column).
4. **First deploy.** Actions → Website → Run workflow, on `main`. No `wrangler login` is
   needed anywhere. Then <https://achtunk8s.io> serves the site.
5. **Redirect `www`.** `www.achtunk8s.io` answers with a 301 to `https://achtunk8s.io`,
   keeping the path and the query string. A Cloudflare Redirect Rule does this at the edge,
   before the Worker; nothing in this repository is involved.
   - DNS → Records → add `AAAA`, name `www`, IPv6 address `100::`, **Proxied**. A Redirect
     Rule only acts on proxied traffic; `100::` is a placeholder origin that is never reached.
   - Rules → Overview → Create rule → Redirect Rule, named "www to apex":
     - When incoming requests match: wildcard pattern, request URL `https://www.achtunk8s.io/*`
     - Then: target URL `https://achtunk8s.io/${1}`, status code **301**, **Preserve query
       string** on.
   - SSL/TLS → Edge Certificates → turn on **Always Use HTTPS**, so `http://www…` is
     upgraded first.
   - Check: `curl -sI 'https://www.achtunk8s.io/a/b?c=d'` gives `301` and
     `location: https://achtunk8s.io/a/b?c=d`.

The alternative to the workflow is Cloudflare's Workers Builds (the Worker → Settings →
Builds: root directory `website`, deploy command `pnpm exec wrangler deploy`); use one or
the other, not both.

`compatibility_date` in `wrangler.jsonc` doesn't matter for static assets; leave it.

## Public site rules

The site is public. Examples use made-up names (`prod-eu`, `payments`, `example.com`):
never real hostnames, cluster names or internal URLs.

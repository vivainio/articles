# What Cloudflare's Free Tier Gives Vibe Coders

*2026-07-11*

I built and shipped outpost - a small web app that lets me peek at my tmux sessions (and pushed docs) from a browser - entirely on Cloudflare's free tier. The site itself is a private deploy, but the [push-to-outpost](https://github.com/vivainio/push-to-outpost) CLI that talks to it is public and explains the shape of the thing. No credit card, no "free trial that becomes a bill in 30 days," just a `wrangler login` and a `wrangler.toml`. This is a rundown of what's actually in the free tier, based on that build, with the numbers that matter.

## Why Cloudflare specifically

For a vibe-coding session with Claude Code, the pitch is: you describe an app, get static hosting + a backend + a database + auth, and none of it costs anything until you have real traffic. Cloudflare's free tier is unusually generous compared to AWS/GCP/Azure free tiers, which tend to be time-limited (12 months) or nickel-and-dime you on egress. Cloudflare's free tier is *forever free*, and egress is free everywhere - that matters a lot once you start storing anything in R2 or D1.

## The pieces

### Workers + static assets - static hosting and your backend, one deploy

[Workers](https://developers.cloudflare.com/workers/) can serve a whole static site directly - point a `[assets]` block in `wrangler.toml` at a directory and `wrangler deploy` ships both the static files and your API code as one Worker. Free plan:

- 100,000 requests/day (assets and Worker code share this)
- 100 custom domains per account
- 25 MiB per static file
- No separate build/deploy step for assets - they're just uploaded alongside the Worker

The backend is one `worker/index.ts` file, with API routes matched by hand against `request.url` instead of file-based routing - one file to read top-to-bottom, no guessing which of `onRequest`/`onRequestGet`/a catch-all wins. Wrangler accepts TypeScript natively and strips the types at deploy time with the same esbuild pipeline it always used for Workers, so `.ts` here is a drop-in rename, not a build step you have to invent.

The frontend is a small Preact + Vite app under `ui/` (components, a `lib/` of API/crypto/zip/markdown helpers), built to static files in `web/` by `vite build`. A second Vite config (`vite.viewer.config.ts`) builds the doc viewer that runs inside a sandboxed iframe as a fully separate bundle, on purpose - that iframe runs with an opaque origin (`sandbox="allow-scripts"`, no `allow-same-origin`) and can't load cross-chunk ES module imports, so it can't share a chunk with the main app's build. `npm run build` runs both, then `wrangler deploy` ships the resulting `web/` alongside the Worker as one deploy.

The whole thing is a single exported `fetch` handler, with bindings (D1, R2, ...) arriving on a typed `env`. Static assets never even reach this code - unmatched requests only fall through to the Worker when there's no matching file in `web/`:

```ts
// worker/index.ts
interface SessionRow {
  id: string;
  name: string;
  updated_at: string;
}

async function getSessions(env: Env): Promise<Response> {
  const { results } = await env.TOWER_DB
    .prepare("SELECT id, name, updated_at FROM sessions ORDER BY updated_at DESC")
    .all<SessionRow>();
  return Response.json(results);
}
```

`Env` isn't hand-written - `npx wrangler types` reads your `wrangler.toml` bindings (including the `[assets]` block) and generates a `worker-configuration.d.ts` with a matching `Env` interface (`TOWER_DB: D1Database`, `DOCS_BUCKET: R2Bucket`, etc.), so `env.TOWER_DB.prepare(...)` is fully typed and a typo in a binding name is a compile error instead of a 3am `undefined is not a function`. It's generated, not committed - regenerate it whenever `wrangler.toml` changes, same idea as a lockfile.

No auth code in there at all - Access sits in front of the hostname, so if the request reached this handler it's already authenticated. The one route that bypasses Access (the CLI push endpoint, machine-to-machine) checks its own key instead:

```ts
// worker/index.ts - POST /api/push (Access: Bypass, key-gated in code)
interface PushBody {
  id: string;
  name: string;
}

async function postPush(request: Request, env: Env): Promise<Response> {
  const key = request.headers.get("x-api-key");
  if (!key) return new Response("Missing key", { status: 401 });

  const hashed = await sha256(key);
  const row = await env.TOWER_DB
    .prepare("SELECT id FROM api_keys WHERE key_hash = ?")
    .bind(hashed)
    .first();
  if (!row) return new Response("Invalid key", { status: 401 });

  const body = await request.json<PushBody>();
  await env.TOWER_DB
    .prepare(
      "INSERT INTO sessions (id, name, updated_at) VALUES (?, ?, datetime('now')) " +
      "ON CONFLICT(id) DO UPDATE SET name = excluded.name, updated_at = excluded.updated_at"
    )
    .bind(body.id, body.name)
    .run();

  return Response.json({ ok: true });
}

async function sha256(text: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (pathname === "/api/sessions" && request.method === "GET") return getSessions(env);
    if (pathname === "/api/push" && request.method === "POST") return postPush(request, env);
    return new Response("Not found", { status: 404 });
  },
} satisfies ExportedHandler<Env>;
```

### Workers Builds - git-connected deploys, no secrets to manage

Cloudflare has a native git integration - [Workers Builds](https://developers.cloudflare.com/workers/ci-cd/builds/) - that skips GitHub Actions entirely: connect the repo from the dashboard (Workers & Pages → your Worker → Settings → Builds → Connect), Cloudflare's own GitHub App handles the push events, and it deploys on every push without a workflow file or a token sitting in your repo's secrets. Free plan:

- 3,000 build minutes/month, 1 concurrent build, 20-minute build timeout

Feature branches and PRs get their own deploys for free - `npx wrangler versions upload` instead of a full `wrangler deploy`, with the resulting preview URL posted straight into a PR comment (a commit-scoped URL and a branch-scoped one). No OIDC/trusted-publishing like PyPI's - the docs still only describe API tokens for the GitHub Actions path - but Workers Builds sidesteps the whole question since there's no token to leak in the first place.

### Workers - the compute underneath everything

These are the numbers that actually gate a Worker, static assets or not:

- 100,000 requests/day (resets at midnight UTC)
- 10ms CPU time per request (wall-clock time waiting on I/O - like a D1 query - doesn't count against this)
- 128MB memory, 3MB compressed script size
- 50 subrequests per invocation (fetches, D1 queries, etc. from inside one request)

10ms of CPU sounds terrifying until you realize it's *CPU* time, not request duration. A function that does a D1 query and returns JSON burns maybe 1-2ms of actual CPU; the rest is the runtime waiting on the database, which is free.

### D1 - SQLite that lives at the edge

[D1](https://developers.cloudflare.com/d1/) is Cloudflare's managed SQLite. Free plan:

- 5GB total storage, 500MB per database, 10 databases per account
- 5 million rows read/day, 100,000 rows written/day

That write quota is the one to actually watch for a chatty app - outpost's CLI polling every 15 seconds and updating a handful of rows each time is nowhere near it, but a naive "log every event" design could burn through 100K writes fast. It's plain SQL (`wrangler d1 execute`, or `env.TOWER_DB.prepare(...).bind(...).run()` from a Worker) - no ORM required, no separate database server to provision.

Plain SQLite only allows one writer at a time because the file is opened directly by whatever process is running - two Workers writing to the same file concurrently is exactly the "database is locked" scenario SQLite is known for. D1 sidesteps this structurally: each database is backed by exactly one primary [Durable Object](https://developers.cloudflare.com/durable-objects/), and Durable Objects guarantee there's only ever one live instance of a given object globally. Every Worker talks to that one instance over HTTP instead of opening the SQLite file itself, so writes are naturally serialized through a single owner - not parallel writers racing for a lock, but one queue. That single-threaded processing is also why D1's throughput is duration-bound rather than concurrency-bound: roughly 1,000 queries/second at 1ms each, 10/second at 100ms each, with an "overloaded" error if the queue backs up. Read replication (separate Durable Objects holding read-only copies, opted into with `Sessions`) scales reads across locations, but writes still get forwarded transparently to that same primary.

### KV - a global, eventually-consistent cache

[Workers KV](https://developers.cloudflare.com/kv/) is a key-value store replicated to Cloudflare's edge, good for config, feature flags, or cached responses where slightly-stale-is-fine:

- 1GB storage
- 100,000 reads/day, but only 1,000 writes/day and 1,000 deletes/day

The write quota is tiny - KV is built for read-heavy, write-rarely data. Don't use it as a database; use D1 for that.

### R2 - S3-compatible storage with zero egress fees

[R2](https://developers.cloudflare.com/r2/) is where the free tier gets genuinely disruptive - it's S3-compatible object storage with **no egress charges**, which is the line item that makes S3 expensive at scale.

- 10GB-month storage
- 1M Class A operations/month (writes/lists), 10M Class B operations/month (reads)

outpost uses it for exactly the blob-storage case that fits: pushed zip docs go to R2 instead of D1 - D1 rows aren't a good fit for arbitrary binary blobs, and storing them base64-in-TEXT wastes a third of the space for nothing. The bucket keys are just the doc id, and a one-line lifecycle rule (`wrangler r2 bucket lifecycle add outpost-docs expire-1d --expire-days 1`) auto-deletes objects a day after their last write, which lines up with re-pushing a doc resetting that clock - no cron trigger needed to keep storage from growing forever. Free-tier limits above cover this with room to spare for anything hobby-sized.

### Durable Objects - stateful coordination, now free-tier eligible

[Durable Objects](https://developers.cloudflare.com/durable-objects/) got added to the free plan in 2025 (SQLite-backed ones specifically). Useful once you need strongly-consistent state - a chat room, a game session, a single-writer counter - that a stateless Worker + D1 can't give you cleanly:

- 5GB total DO storage on the free plan
- ~100K requests/day, ~150M rows read/month, ~3M rows written/month
- Each incoming request resets a 30-second CPU budget for that object

outpost doesn't need this (D1 + polling is enough), but it's the thing to reach for if "everyone editing the same doc in real time" shows up in a future vibe-coding session.

### Workers AI - free inference at the edge

[Workers AI](https://developers.cloudflare.com/workers-ai/) runs LLMs, embeddings, and image models on Cloudflare's GPUs, billed in "Neurons":

- 10,000 Neurons/day free, resets at midnight UTC

That's enough for a lot of casual embedding generation or small-model inference tied to a hobby project, without wiring up an OpenAI/Anthropic API key and a billing alert.

### Zero Trust / Access - free auth, no login code

This is the one that saved the most actual work on outpost. [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/policies/access/) sits in front of your domain and requires login (email OTP, Google, GitHub, whatever identity provider you wire up) *before a request even reaches your app*. Free plan: **50 users, no time limit.**

For outpost this means the entire site has zero app-level login code - no session cookies to manage, no password hashing, no "forgot password" flow. An Access Application points at `outpost.<subdomain>.workers.dev`, path `/*`, with a policy of "allow my email only," so every request that reaches the Worker is already authenticated. For a single-user hobby tool this is enormously simpler than writing auth, and even at 50 users it's still free - plenty for "share this internal tool with my team."

**An Access Application matches by hostname and path**, and matching is most-specific-path-wins. For machine-to-machine calls that can't do an interactive login (the local CLI's push agent), a second Application is scoped to just `/api/push` with a **Bypass** policy, and that one route checks its own hashed API key against D1 instead - it's the one route Access doesn't touch. Because a plain `wrangler deploy` overwrites the same `workers.dev` URL rather than minting a new one per deploy, there's exactly one hostname to cover with these two Applications, not a growing set of old preview subdomains.

### Turnstile - free CAPTCHA

Didn't need it here, but worth knowing about: [Turnstile](https://developers.cloudflare.com/turnstile/) is Cloudflare's free, privacy-respecting CAPTCHA replacement, unlimited free usage. If a vibe-coded app has a public form, this is the bot-wall to drop in front of it before someone's contact form becomes a spam pipe.

## What this looks like put together

The outpost stack, entirely free-tier:

```
push-to-outpost CLI --(HTTPS POST, key-gated)--> /api/push (Worker route, Access Bypass)
                                                          |
                                          Cloudflare D1  +  R2 (zip doc blobs)
                                                          |
                       /api/sessions, /api/docs, /api/keys (Worker routes, gated by Access)
                                                          |
                          web/ (Preact app, built by Vite, served by the same Worker)
```

The CLI itself is a separate PyPI package (`pip install push-to-outpost`), so the local agent that captures tmux panes and pushes docs has nothing to do with the Cloudflare deploy - it just talks to `/api/push` over HTTPS with an API key minted and revoked from the site's own **API keys** panel. Static site + API + database + auth, and the entire thing runs comfortably inside the free tier for a single-user tool. `wrangler deploy` and `wrangler d1 execute ... --remote --file=schema.sql` are the only two commands standing between "idea" and "deployed."

## Where it stops being free

None of this is a permanent free lunch if a project takes off - Workers Paid starts at $5/month and buys you 10M requests, 30s CPU time, and proportionally higher everything-else. But for the actual shape of a vibe-coding session - "build a small tool, use it yourself or with a few people, iterate fast" - the free tier isn't a crippled trial. It's the whole stack, forever, until you have a real reason to pay.

## Related writing

- [Packaging Rust CLI Apps to PyPI](packaging-rust-to-pypi.md) covers the other
  side of shipping a tool: putting its local CLI into a familiar package
  ecosystem.
- [A Tiny HTTP Server with Just the Python Standard Library](python-stdlib-webserver/index.md)
  takes the same small-system instinct in the opposite direction—local,
  dependency-free simulators and fakes.

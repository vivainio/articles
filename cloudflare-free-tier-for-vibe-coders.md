# What Cloudflare's Free Tier Gives Vibe Coders

*2026-07-11*

I built and shipped [tmux-tower](https://github.com/vivainio/tmux-tower) - a small web app that lets me peek at my tmux sessions from a browser - entirely on Cloudflare's free tier. No credit card, no "free trial that becomes a bill in 30 days," just a `wrangler login` and a `wrangler.toml`. This is a rundown of what's actually in the free tier, based on that build, with the numbers that matter and the gotchas nobody tells you about.

## Why Cloudflare specifically

For a vibe-coding session with Claude Code, the pitch is: you describe an app, get static hosting + a backend + a database + auth, and none of it costs anything until you have real traffic. Cloudflare's free tier is unusually generous compared to AWS/GCP/Azure free tiers, which tend to be time-limited (12 months) or nickel-and-dime you on egress. Cloudflare's free tier is *forever free*, and egress is free everywhere - that matters a lot once you start storing anything in R2 or D1.

## The pieces

### Workers + static assets - static hosting and your backend, one deploy

[Workers](https://developers.cloudflare.com/workers/) can serve a whole static site directly - point a `[assets]` block in `wrangler.toml` at a directory and `wrangler deploy` ships both the static files and your API code as one Worker. Free plan:

- 100,000 requests/day (assets and Worker code share this)
- 100 custom domains per account
- 25 MiB per static file
- No separate build/deploy step for assets - they're just uploaded alongside the Worker

I actually started tmux-tower on Cloudflare Pages, which did this with file-based routing - drop a file in `functions/api/push.ts` and it became `POST /api/push`, no router to write. Pages is being phased towards Workers as the primary platform, so I migrated: one `worker/index.ts` file with static assets served straight from `web/`, and API routes matched by hand against `request.url` instead of by file path. It's a few more lines than file-based routing, but it's one file to read top-to-bottom instead of nine, and there's no more guessing which of `onRequest`/`onRequestGet`/a catch-all wins.

The whole backend is that one `worker/index.ts` plus a `web/` folder of static HTML/CSS/JS. No framework, no bundler config to write - Wrangler accepts TypeScript natively and strips the types at deploy time with the same esbuild pipeline it always used for Workers, so `.ts` here is a drop-in rename, not a build step you have to invent.

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

The one place TypeScript *doesn't* come free is the client-side script tags in `web/` - those are plain `<script src="app.js">` includes with no module system, and a browser can't run `.ts` directly. Converting that half means owning a small build step yourself: TS source under `src/`, a `tsconfig.json` with `outDir: "web"` and `module: "commonjs"` (files with no top-level `import`/`export` still compile to plain global scripts, matching the existing non-module `<script>` setup), and a `build` npm script that runs before `dev`/`deploy`. The compiled `web/*.js` becomes gitignored build output instead of committed source, same as the generated `Env` type.

### Workers Builds - git-connected deploys, no secrets to manage

I'd been running `wrangler deploy` from a GitHub Actions workflow with a `CLOUDFLARE_API_TOKEN` secret, the standard approach everywhere it's documented. Cloudflare also has a native git integration - [Workers Builds](https://developers.cloudflare.com/workers/ci-cd/builds/) - that skips GitHub Actions entirely: connect the repo from the dashboard (Workers & Pages → your Worker → Settings → Builds → Connect), Cloudflare's own GitHub App handles the push events, and it deploys on every push without a workflow file or a token sitting in your repo's secrets. Free plan:

- 3,000 build minutes/month, 1 concurrent build, 20-minute build timeout

Feature branches and PRs get their own deploys for free - `npx wrangler versions upload` instead of a full `wrangler deploy`, with the resulting preview URL posted straight into a PR comment (a commit-scoped URL and a branch-scoped one). No OIDC/trusted-publishing like PyPI's - the docs still only describe API tokens for the GitHub Actions path - but Workers Builds sidesteps the whole question since there's no token to leak in the first place.

The pleasant surprise: those preview `workers.dev` URLs still redirected to Cloudflare Access login when I checked, meaning Access was covering the whole `*.<subdomain>.workers.dev` pattern, not just the one hostname I'd pointed an Application at - the exact hazard called out above under Zero Trust didn't materialize here. Worth confirming on your own setup rather than assuming, since Access matching is per-hostname and this depends on how broadly your policy's been scoped.

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

That write quota is the one to actually watch for a chatty app - a tmux-pane-pusher polling every 15 seconds and updating a handful of rows each time is nowhere near it, but a naive "log every event" design could burn through 100K writes fast. It's plain SQL (`wrangler d1 execute`, or `env.TOWER_DB.prepare(...).bind(...).run()` from a Worker) - no ORM required, no separate database server to provision.

### KV - a global, eventually-consistent cache

[Workers KV](https://developers.cloudflare.com/kv/) is a key-value store replicated to Cloudflare's edge, good for config, feature flags, or cached responses where slightly-stale-is-fine:

- 1GB storage
- 100,000 reads/day, but only 1,000 writes/day and 1,000 deletes/day

The write quota is tiny - KV is built for read-heavy, write-rarely data. Don't use it as a database; use D1 for that.

### R2 - S3-compatible storage with zero egress fees

[R2](https://developers.cloudflare.com/r2/) is where the free tier gets genuinely disruptive - it's S3-compatible object storage with **no egress charges**, which is the line item that makes S3 expensive at scale.

- 10GB-month storage
- 1M Class A operations/month (writes/lists), 10M Class B operations/month (reads)

I ended up using it for exactly the blob-storage case I was expecting: tmux-tower can now push zip files as docs, and those go to R2 instead of D1 - D1 rows aren't a good fit for arbitrary binary blobs, and storing them base64-in-TEXT wastes a third of the space for nothing. The bucket keys are just the doc id, and a one-line lifecycle rule (`wrangler r2 bucket create tmux-tower-docs` then `wrangler r2 bucket lifecycle add tmux-tower-docs expire-1d --expire-days 1`) auto-deletes objects a day after their last write, which happens to line up perfectly with re-pushing a doc resetting that clock - no cron trigger needed to keep storage from growing forever. Free-tier limits above cover this with room to spare for anything hobby-sized; no separate bucket-billing surprise waiting six months later when someone downloads a file a lot.

### Durable Objects - stateful coordination, now free-tier eligible

[Durable Objects](https://developers.cloudflare.com/durable-objects/) got added to the free plan in 2025 (SQLite-backed ones specifically). Useful once you need strongly-consistent state - a chat room, a game session, a single-writer counter - that a stateless Worker + D1 can't give you cleanly:

- 5GB total DO storage on the free plan
- ~100K requests/day, ~150M rows read/month, ~3M rows written/month
- Each incoming request resets a 30-second CPU budget for that object

I didn't need this for tmux-tower (D1 + polling was enough), but it's the thing to reach for if "everyone editing the same doc in real time" shows up in a future vibe-coding session.

### Workers AI - free inference at the edge

[Workers AI](https://developers.cloudflare.com/workers-ai/) runs LLMs, embeddings, and image models on Cloudflare's GPUs, billed in "Neurons":

- 10,000 Neurons/day free, resets at midnight UTC

That's enough for a lot of casual embedding generation or small-model inference tied to a hobby project, without wiring up an OpenAI/Anthropic API key and a billing alert.

### Zero Trust / Access - free auth, no login code

This is the one that saved me the most actual work on tmux-tower. [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/policies/access/) sits in front of your domain and requires login (email OTP, Google, GitHub, whatever identity provider you wire up) *before a request even reaches your app*. Free plan: **50 users, no time limit.**

For tmux-tower this means the entire site has zero app-level login code - no session cookies to manage, no password hashing, no "forgot password" flow. I just point an Access Application at `tmux-tower.<subdomain>.workers.dev`, set a policy of "allow my email only," and every request that reaches my Worker is already authenticated. For a single-user hobby tool this is enormously simpler than writing auth, and even at 50 users it's still free - plenty for "share this internal tool with my team."

The catch (and this bit me for real, back when tmux-tower was still on Pages): **an Access Application only matches the exact hostname you give it.** Cloudflare Pages gives every single deployment - including old ones from months ago - a permanent unique subdomain like `81f1467b.tmux-tower.pages.dev`, and none of them inherit the Access policy on your main domain unless you explicitly cover them. I had `/api/keys` (a GET *and POST* endpoint with zero app-level auth, relying entirely on Access) sitting wide open on every old deploy subdomain for a while before catching it. This is one of the reasons I moved to Workers with static assets instead: a plain `wrangler deploy` overwrites the same `workers.dev` URL rather than minting a new immutable one per deploy, so there's no fleet of forgotten unprotected subdomains to audit. (Pages-style immutable preview URLs still exist on Workers if you opt into gradual deployments/Versions - just not by default.) If you're still on Pages, protect `*.yourproject.pages.dev` as a *separate application* in addition to the bare domain - one Access app can only hold one hostname pattern (exact match *or* wildcard, not both), so budget for two apps, not one.

For machine-to-machine calls that can't do an interactive login (my local push agent, for instance), give that one route its own Access Application scoped to just that path with a **Bypass** policy, and gate it with your own API key check inside the function instead. That's what `/api/push` does in tmux-tower - it's the one route Access doesn't touch, and it checks a hashed API key from D1 on every request.

### Turnstile - free CAPTCHA

Didn't need it here, but worth knowing about: [Turnstile](https://developers.cloudflare.com/turnstile/) is Cloudflare's free, privacy-respecting CAPTCHA replacement, unlimited free usage. If a vibe-coded app has a public form, this is the bot-wall to drop in front of it before someone's contact form becomes a spam pipe.

## What this looks like put together

The tmux-tower stack, entirely free-tier:

```
tmux-tower CLI --(HTTPS POST, key-gated)--> /api/push (Worker route, Access Bypass)
                                                    |
                                    Cloudflare D1  +  R2 (zip doc blobs)
                                                    |
                     /api/sessions, /api/docs, /api/keys (Worker routes, gated by Access)
                                                    |
                                web/ (static assets, served by the same Worker)
```

Static site + API + database + auth, and the entire thing runs comfortably inside the free tier for a single-user tool. `wrangler deploy` and `wrangler d1 execute ... --remote --file=schema.sql` are the only two commands standing between "idea" and "deployed."

## Where it stops being free

None of this is a permanent free lunch if a project takes off - Workers Paid starts at $5/month and buys you 10M requests, 30s CPU time, and proportionally higher everything-else. But for the actual shape of a vibe-coding session - "build a small tool, use it yourself or with a few people, iterate fast" - the free tier isn't a crippled trial. It's the whole stack, forever, until you have a real reason to pay.

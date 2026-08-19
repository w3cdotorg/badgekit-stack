# badgekit-stack

Docker Compose stack for the resurrected Mozilla BadgeKit (Node 26, 2026).

This repo assumes two sibling clones next to it. The front (`web`) also has an
OIDC auth mode (`AUTH_MODE=oidc`), backed by a local Keycloak service — see
"Keycloak / OIDC login" below.

```
mozilla/
├── badgekit-stack/          (this repo)
├── badgekit-api/            (backend)
└── openbadges-badgekit/     (front)
```

Both app repos have been modernized (see the commit "Modernize dependencies to
run on Node 26" in each) and ship a `Dockerfile` used by `compose.yaml` via
the relative build contexts `../badgekit-api` and `../openbadges-badgekit`.

## Run it

```sh
docker compose up -d --build
# wait for all services to report healthy, then:
./seed.sh
```

That's it — no more manual MySQL container, migrations, or system-seeding
gymnastics. `docker compose up` brings up:

- **mysql** (MySQL 8, port `3306`) — `init.sql` is mounted into
  `/docker-entrypoint-initdb.d/` and runs once, on the first boot of the
  named volume, creating the `badgekit`, `badgekit_test` and `badgekit_web`
  databases and the `badges` / `badgekit` users.
- **api** (badgekit-api backend, port `8080`) — runs migrations then starts.
- **web** (openbadges-badgekit front, port `3001` → container `3000`) — runs
  migrations then starts.

`./seed.sh` creates the `wooclap` system that the front's `OPENBADGER_SYSTEM`
expects, signing a JWT with the shared `MASTER_SECRET`. It's idempotent: a
second run returns a 409 / `ResourceConflict` instead of erroring.

Once seeded, open http://localhost:3001 → "Log In" prompts for an email
address with **no verification** — that's `AUTH_MODE=dev`, the stack's
default (see "Points d'attention" below), and it's what you get out of the
box with no further setup. Real-IdP login (`AUTH_MODE=oidc`, backed by the
local Keycloak service) is a documented opt-in, not the default — see
"Keycloak / OIDC login" below to enable it.

## Verify

```sh
curl -s http://localhost:8080/healthcheck                       # -> {"app":"BadgeKit API",...}
curl -s -o /dev/null -w "%{http_code}" http://localhost:3001/    # -> 200
./seed.sh                                                        # -> {"status":"created",...} or 409
```

## Keycloak / OIDC login

`docker compose up` also brings up **keycloak** (Keycloak 26, port `8180`),
started with `start-dev --import-realm` against `keycloak/realm-badgekit.json`.
That file is a full realm export (`kc.sh export --users realm_file`) of a
realm built headlessly via `kcadm.sh` — no admin-UI clicking involved. It
defines:

- realm `badgekit`
- a confidential client `badgekit-web` (redirect URI
  `http://localhost:3001/auth/callback`, client secret
  `ZrtXW6GRXZSquN6cN1QURy5Lu7g6dpJk` — dev-only, already in `compose.yaml`)
- a test user `dev@wooclap.com` / `dev`, with a verified email

The import was proven from scratch: a brand-new Keycloak container (empty
volume) started with `start-dev --import-realm` against this exact file logs
`Realm 'badgekit' imported` / `Import finished successfully`, and
`http://localhost:8180/realms/badgekit/.well-known/openid-configuration`
resolves immediately after.

`compose.yaml`'s `web` service defaults to `AUTH_MODE: dev` (see above) and
ships the matching `AUTH_MODE=oidc` / `OIDC_*` env block **commented out**
right below it — `docker compose up` on its own never talks to Keycloak for
auth. That's deliberate: `OIDC_ISSUER: http://localhost:8180/...` is only
reachable from the *host* by default, and inside the `web` container
`localhost` means the container itself, not the host running Keycloak's
published port — so shipping that block active-by-default would boot into a
login that can't work. There are two working ways to actually exercise OIDC:

**Caveat réseau** — the OIDC redirects (`authorization_endpoint`, etc.) are
followed by the *browser*, not just the container, so `OIDC_ISSUER` must
resolve identically for both. `http://keycloak:8080` (the compose network
name) would work for the `web` container's server-to-server discovery call
but is unreachable from the host browser; `http://localhost:8180` (the
published port) is reachable from the browser but not from inside another
container unless that container also gets `localhost` routed to the host.

**Option A — run the front on the host** (the way this was actually
validated). Keycloak stays dockerized on `:8180`; the front runs as a plain
Node process on the host, so both the Node process and the browser resolve
`localhost:8180` identically:

```sh
cd ../openbadges-badgekit
source .env
export AUTH_MODE=oidc
export OIDC_ISSUER=http://localhost:8180/realms/badgekit
export OIDC_CLIENT_ID=badgekit-web
export OIDC_CLIENT_SECRET=ZrtXW6GRXZSquN6cN1QURy5Lu7g6dpJk
export OIDC_REDIRECT_URI=http://localhost:3001/auth/callback
node app
```

**Option B — run the front in-container**, by uncommenting *both* the
`AUTH_MODE: oidc` / `OIDC_*` block and the `extra_hosts: ["localhost:host-gateway"]`
line under the `web` service in `compose.yaml`, then `docker compose up -d
--build web`. `host-gateway` routes the container's `localhost` to the
Docker host, so `OIDC_ISSUER=http://localhost:8180/...` then resolves
identically for the `web` container's server-to-server discovery call and
for the host browser — no other changes needed, since the client
ID/secret/redirect URI in that block already match the `badgekit-web`
Keycloak client.

Either way, once the front is running with `AUTH_MODE=oidc`: open
http://localhost:3001, click "Log In", authenticate as `dev@wooclap.com` /
`dev` on the Keycloak login page, and land back on `/directory` logged in
(header shows the email). Logging out (the header's "Logout" link) clears
the session and returns to the logged-out home page — a direct hit on
`/directory` afterwards redirects to `/`, confirming the server-side session
was actually reset, not just the UI.

`ACCESS_LIST` is locked to `'["*@wooclap.com"]'` (see below) — `dev@wooclap.com`
matches it, so this flow works unmodified.

## OB 3.0 dev issuer key

The `api` service's Open Badges 3.0 signing routes (`/.well-known/did.json`,
`/public/credentials/*`) are unconfigured by default — they respond
`503 {code:'SigningNotConfigured'}` until `ISSUER_DID` / `ISSUER_SIGNING_KEY`
**and** `PUBLIC_BASE_URL` are all set. The rest of the API (all 1.x routes)
works identically either way. The key is never stored in the database, never
baked into the image, and never committed — it only ever lives in a
gitignored `.env` in this directory, which `docker compose` reads
automatically.

`PUBLIC_BASE_URL` is **mandatory** whenever signing is configured — every URL
baked into a signed document (`credential.id`, `achievement.id`,
`credentialStatus.statusListCredential`, the status list credential's own
`id`) must come from this one operator-controlled value, never from the
client-controlled `Host` header (an early version derived it from the
request and was fixed — see `docs/ob3-validation-report.md`). `compose.yaml`
defaults it to `http://localhost:8080` for the dev stack; override it (via
`.env` or an env override) whenever `ISSUER_DID`/`ISSUER_SIGNING_KEY` target
a different host, e.g. a tunnel — see "External validation" below.

Generate a dev key and wire it up:

```sh
./gen-dev-key.sh                       # defaults to did:web:localhost%3A8080
docker compose up -d --build api
curl -s http://localhost:8080/.well-known/did.json   # -> 200 with the dev key
```

Re-running `./gen-dev-key.sh` **replaces** the key — it's idempotent in the
sense that it overwrites the previous `ISSUER_DID`/`ISSUER_SIGNING_KEY` lines
in `.env` rather than appending duplicates, but it is not a "rotation" in
the sense of keeping the old key valid alongside the new one. On a real
domain that has already signed credentials, replacing the key invalidates
every one of them (their `proof.verificationMethod` stops resolving to
anything in the current `did.json`). True key rotation — serving multiple
valid keys from `did.json` at once — isn't implemented yet; see
`docs/ob3-operations.md` (§4) for the full explanation and what's tracked
for the Q2 flip. On the throwaway local/test domain this is harmless — pass
a DID to target a different domain, e.g. a disposable `cloudflared` tunnel
hostname for external-validator testing (see `docs/ob3-spike-report.md`):

```sh
./gen-dev-key.sh 'did:web:<random>.trycloudflare.com'
echo 'PUBLIC_BASE_URL=https://<random>.trycloudflare.com' >> .env
docker compose up -d --build api
```

Per the project's test-domain-only policy, never point `ISSUER_DID` at a
real/production domain from this dev stack.

Once a credential is signed, editing the underlying badge does **not**
update it — see `docs/ob3-operations.md` for the full operations reference:
the team convention for editing badges after credentials have been signed
against them (§1), exactly what moment gets snapshotted into a signed
credential and what doesn't (§2, it's the first `GET`, not the award — an
edit landing between the two still gets signed in), the step-by-step runbook
for moving `PUBLIC_BASE_URL`/`ISSUER_DID` to a new domain without corrupting
already-issued credentials (§3), and the honest state of key "rotation"
(§4 — `gen-dev-key.sh` replaces the key, it does not rotate it).

### Issuing a demo credential

Once a dev key is wired up (above), issue a real signed credential through
the API's ordinary auth (a `master`-key signed JWT, the same pattern
`seed.sh` uses for system creation — no code changes needed):

```sh
# 1. Create a badge (image can be any syntactically valid URL — it's stored
#    as a reference, never fetched by the signer).
BODY='{"slug":"ob3-demo","name":"OB3 Demo Badge","earnerDescription":"Demo badge for OB3 credential issuance.","consumerDescription":"Demo badge for OB3 credential issuance.","unique":0,"type":"Badge Type","imageUrl":"http://localhost:8080/public/images/demo.png","criteriaUrl":"http://localhost:8080/criteria/ob3-demo"}'
TOKEN=$(docker compose exec -T api node -e "
const jws = require('jws'); const crypto = require('crypto');
const body = process.argv[1];
const hash = crypto.createHash('sha256').update(body).digest('hex');
console.log(jws.sign({header:{typ:'JWT',alg:'HS256'},
  payload:{key:'master',exp:(Date.now()/1000|0)+300,method:'POST',path:'/systems/wooclap/badges',
           body:{alg:'sha256',hash:hash}},
  secret:process.env.MASTER_SECRET}));" "$BODY")
curl -s -X POST -H "Authorization: JWT token=\"$TOKEN\"" -H "Content-Type: application/json" \
  -d "$BODY" http://localhost:8080/systems/wooclap/badges

# 2. Award it to a recipient (only `email` is required).
BODY='{"email":"demo-recipient@example.org"}'
TOKEN=$(docker compose exec -T api node -e "
const jws = require('jws'); const crypto = require('crypto');
const body = process.argv[1];
const hash = crypto.createHash('sha256').update(body).digest('hex');
console.log(jws.sign({header:{typ:'JWT',alg:'HS256'},
  payload:{key:'master',exp:(Date.now()/1000|0)+300,method:'POST',path:'/systems/wooclap/badges/ob3-demo/instances',
           body:{alg:'sha256',hash:hash}},
  secret:process.env.MASTER_SECRET}));" "$BODY")
curl -s -X POST -H "Authorization: JWT token=\"$TOKEN\"" -H "Content-Type: application/json" \
  -d "$BODY" http://localhost:8080/systems/wooclap/badges/ob3-demo/instances
# -> {"status":"created","instance":{... "credentialUrl":"http://localhost:8080/public/credentials/<slug>", ...}}

# 3. Fetch the signed credential (lazily signed + persisted on first GET).
curl -s http://localhost:8080/public/credentials/<slug>
```

### External validation

`docs/ob3-validation-report.md` records a full external-validator run: a
disposable `cloudflared` tunnel, a badge + instance issued exactly as above
(against the tunnel's `did:web`/`PUBLIC_BASE_URL`), the resulting credential
GET **through the tunnel**, and its submission to the public
[vc.1ed.tech](https://vc.1ed.tech) Open Badges 3.0 Verifier — verdict, review
checklist results (status-list `id` consistency, `Accept:
application/vc+ld+json` support, the inline `@context` on
`credentialSchema[0]` workaround), and a screenshot. **This used a throwaway
`trycloudflare.com` domain only — real issuance awaits the Q2 domain
decision (see `docs/ob3-migration-spec.md`); the tunnel and its key were torn
down immediately after.**

## Points d'attention

- `streamsql` (abandoned Mozilla ORM) is vendored in `vendor/streamsql` in
  both repos, with a `util.format` fix (`%s` semantics changed since
  Node 12).
- `spdy` is stubbed (`vendor/spdy-stub` via npm overrides): broken since
  Node 23, and restify only uses it if the HTTP/2 option is enabled.
- `db-migrate` stays pinned to 0.6: the programmatic API used by
  `bin/db-migrate` disappeared from modern versions — but it runs fine.
- The original test suites (tap 0.4 / mocha 1.x) have been migrated (`tap` 16
  for `badgekit-api`, modern `mocha` for `openbadges-badgekit`) and are green
  in CI for both repos.
- `ACCESS_LIST` on `web` is locked to `'["*@wooclap.com"]'` (was `'["*"]'`
  during initial bring-up) — only that domain can authenticate past the
  `verifyPermission` middleware, in dev-persona mode as well as OIDC.
- w3cdotorg/mozilla-persona was not used: self-hosting Persona (a
  multi-service Node 0.10 stack) wasn't realistic in a day, and Mozilla
  Persona itself was shut down in 2016. The Persona-backed auth code
  (`express-persona-observer`) was removed entirely in a later phase; the
  front now only supports two auth modes, chosen via `AUTH_MODE`: `dev`
  (default — an unverified email prompt, `app/lib/dev-persona.js`) or
  `oidc` (a real IdP, `app/lib/oidc-auth.js`, see "Keycloak / OIDC login"
  above). There is no `USE_PERSONA` toggle and no path back to Persona.
- The driver `mysql` (2.x) doesn't support `caching_sha2_password`, hence
  `--default-authentication-plugin=mysql_native_password` on the MySQL
  service and `mysql_native_password` users in `init.sql`.
- `badgekit_web_test` is the front's (`openbadges-badgekit`) test database:
  its mocha suite DROPs and re-CREATEs it on every run, so `init.sql` grants
  `badgekit` full privileges on it up front (database-level grants survive
  the suite's DROP/CREATE cycle).

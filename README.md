# badgekit-stack

Docker Compose stack for the resurrected Mozilla BadgeKit (Node 26, 2026).

This repo assumes two sibling clones next to it. The front (`web`) also has an
OIDC auth mode (`AUTH_MODE=oidc`), backed by a local Keycloak service — see
"Keycloak / OIDC login" below.

```
mozilla/
├── badgekit-stack/          (this repo)
├── badgekit-api/            (backend, branch phase-1-docker-stack)
└── openbadges-badgekit/     (front, branch phase-1-docker-stack)
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

Once seeded, open http://localhost:3001 → "Log In" asks for an email (dev
auth — see "Points d'attention" below).

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

The front's `web` service ships the matching `AUTH_MODE=oidc` / `OIDC_*` env
block in `compose.yaml`, but **the `web` container is not restarted to use
it** — see the network caveat below. To actually exercise the OIDC flow:

**Caveat réseau** — the OIDC redirects (`authorization_endpoint`, etc.) are
followed by the *browser*, not just the container, so `OIDC_ISSUER` must
resolve identically for both. `http://keycloak:8080` (the compose network
name) works for the `web` container's server-to-server discovery call but is
unreachable from the host browser; `http://localhost:8180` (the published
port) is reachable from the browser but not from inside another container
unless that container also gets `localhost` routed to the host (e.g.
`extra_hosts: ["localhost:host-gateway"]` on `web`). The simplest way to test
today, and the way this was actually validated, is to run the front **outside
Docker** on the host (`AUTH_MODE=oidc node app`, port 3001) with Keycloak
still dockerized on `:8180` — both the Node process and the browser then
resolve `localhost:8180` identically:

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

Then open http://localhost:3001, click "Log In", authenticate as
`dev@wooclap.com` / `dev` on the Keycloak login page, and land back on
`/directory` logged in (header shows the email). Logging out (the header's
"Logout" link) clears the session and returns to the logged-out home page —
a direct hit on `/directory` afterwards redirects to `/`, confirming the
server-side session was actually reset, not just the UI.

`ACCESS_LIST` is locked to `'["*@wooclap.com"]'` (see below) — `dev@wooclap.com`
matches it, so this flow works unmodified.

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
  multi-service Node 0.10 stack) wasn't realistic in a day, so the dev
  bypass (`app/lib/dev-persona.js`) is used instead. Auth: Mozilla Persona
  died in 2016; setting `USE_PERSONA=true` switches back to the original
  Persona client for a self-hosted Persona instance.
- The driver `mysql` (2.x) doesn't support `caching_sha2_password`, hence
  `--default-authentication-plugin=mysql_native_password` on the MySQL
  service and `mysql_native_password` users in `init.sql`.
- `badgekit_web_test` is the front's (`openbadges-badgekit`) test database:
  its mocha suite DROPs and re-CREATEs it on every run, so `init.sql` grants
  `badgekit` full privileges on it up front (database-level grants survive
  the suite's DROP/CREATE cycle).

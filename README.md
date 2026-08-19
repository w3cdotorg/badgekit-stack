# badgekit-stack

Docker Compose stack for the resurrected Mozilla BadgeKit (Node 26, 2026).

This repo assumes two sibling clones next to it:

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

## Points d'attention

- `streamsql` (abandoned Mozilla ORM) is vendored in `vendor/streamsql` in
  both repos, with a `util.format` fix (`%s` semantics changed since
  Node 12).
- `spdy` is stubbed (`vendor/spdy-stub` via npm overrides): broken since
  Node 23, and restify only uses it if the HTTP/2 option is enabled.
- `db-migrate` stays pinned to 0.6: the programmatic API used by
  `bin/db-migrate` disappeared from modern versions — but it runs fine.
- The original test suites (tap 0.4 / mocha 1.x) have NOT been migrated.
- w3cdotorg/mozilla-persona was not used: self-hosting Persona (a
  multi-service Node 0.10 stack) wasn't realistic in a day, so the dev
  bypass (`app/lib/dev-persona.js`) is used instead. Auth: Mozilla Persona
  died in 2016; setting `USE_PERSONA=true` switches back to the original
  Persona client for a self-hosted Persona instance.
- The driver `mysql` (2.x) doesn't support `caching_sha2_password`, hence
  `--default-authentication-plugin=mysql_native_password` on the MySQL
  service and `mysql_native_password` users in `init.sql`.

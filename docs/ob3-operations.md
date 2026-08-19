# OB 3.0 operations reference

Operational reference for running the Open Badges 3.0 signing path
(`/.well-known/did.json`, `/public/credentials/*` in `badgekit-api`) day to
day — the team convention for editing signed badges, exactly what a signed
credential does and doesn't capture, how to move the stack to a new domain
without corrupting already-issued credentials, and the honest state of key
rotation. Everything here was produced by, or formalizes, work already done
in `docs/ob3-migration-spec.md` (§4, decision D7) and
`docs/ob3-validation-report.md` (the tunnel walkthrough this runbook
generalizes) — see those for the full narrative and evidence.

## 1. The D7 convention: editing a badge after it's been signed

`badgekit`'s 1.x badge data (name, criteria, image, description) is mutable —
editing a badge propagates instantly to every 1.x JSON representation, since
those are generated on the fly on every GET. A signed OB 3.0 credential is
the opposite: it's an **immutable snapshot**, frozen at sign time. Editing
the badge afterwards does **not** update any credential already signed
against it — by design (see the migration spec's D7 for the full rejected-
alternatives discussion: re-signing on every edit is illusory, since copies
already downloaded into wallets/files can't be recalled or invalidated, and
freezing badges entirely on first issuance is safer but blocks legitimate
typo fixes).

The team convention that makes this workable:

- **Minor edits are tolerated** — fixing a typo, rewording a sentence,
  correcting a broken link. These don't invalidate credentials already
  signed under the old wording; the divergence is cosmetic.
- **A substantial change — different criteria, a different name, a
  different meaning, a different image — must be a new badge (a new slug),
  not an edit.** A new slug means a new `achievement.id`, so credentials
  already signed against the old badge keep pointing at the old
  (unmodified-in-substance) definition, and newly-issued credentials point
  at the new one. Never overload one slug across a substantial redefinition.
- **The 1.x JSON served at `achievement.id` is informative, not
  authoritative.** If someone edits a badge after credentials referencing it
  have already been signed, `achievement.id` will serve the *current* 1.x
  badge data — which may now read differently than what a given recipient's
  signed credential embedded at issuance time (name, description, criteria
  narrative, image URL are all inlined into `credentialSubject.achievement`
  at sign time — see §5.1 of the migration spec). **The signed copy the
  recipient holds is what was actually awarded and is authoritative for
  that; the live `achievement.id` JSON is a convenience view of the badge's
  current definition, not a claim about what any specific credential says.**

## 2. Snapshot semantics: signed at first GET, not at award

This is a corollary of D7 worth stating explicitly, because it's easy to
assume a credential is "awarded" as soon as `POST .../instances` returns
201, and that's not quite what happens:

- `POST .../instances` creates the badge instance and returns
  `credentialUrl` (and, for webhooks, includes it in the payload) — but
  **does not sign anything yet**. `badgeInstances.credential` is `NULL` at
  this point.
- The credential is built and signed **lazily, on the first `GET
  /public/credentials/:slug`** — whichever request happens to be first wins
  the sign (concurrent first-GETs converge on byte-identical output via a
  compare-and-swap write + authoritative re-read; see `badgekit-api`'s
  `signAndPersistCredential()`). From that point on it's persisted and
  served byte-stably forever, verbatim, regardless of anything else that
  changes afterward.
- **Practical consequence: whatever the badge/issuer/program data looks
  like at the moment of the *first fetch* is what gets permanently baked
  into the signed credential — not what it looked like at award time.** If
  someone edits the badge (even a "minor, tolerated" edit per §1 above)
  between the instance being awarded and the recipient's first fetch of the
  credential, the edit **does** land in the signed copy — there is no
  separate "frozen at award" snapshot taken earlier. Only edits made *after*
  the first successful fetch are excluded.
- Once signed, `validFrom`/`awardedDate` still reflect the instance's actual
  `issuedOn` timestamp (award time) — only the *content* snapshot (name,
  achievement description, criteria, image, issuer org fields) is anchored
  to first-fetch time, not the date fields.

If a workflow needs the credential to reflect exactly what existed at award
time regardless of how quickly it's fetched, the only reliable option today
is to fetch `credentialUrl` immediately after creating the instance (e.g.
right after the `POST .../instances` call that returns it), before any
further badge edits can land in between.

## 3. Domain-move runbook

Formalized from the step-by-step tunnel walkthrough in
`docs/ob3-validation-report.md` (steps 2–7 and "Cleanup"), generalized to any
domain move — not just the disposable tunnel case that report documents.
Moving `PUBLIC_BASE_URL`/`ISSUER_DID` to a new domain (a new tunnel hostname,
a staging host, eventually the real Q2 production domain) is not a
config-only change — get the order wrong and you either 503 the signing
routes or permanently bake the wrong host into a newly-signed credential.

1. **Set `PUBLIC_BASE_URL` and regenerate/reset `ISSUER_DID` together — in
   the same `.env` update, before restarting `api`.** They must name the
   same host[:port]; `badgekit-api` now enforces this at the signing gate
   (a mismatch 503s `SigningNotConfigured`, naming both values, rather than
   silently signing credentials whose issuer identity and content host
   disagree). Use `./gen-dev-key.sh 'did:web:<new-host>'` to generate the
   matching key/DID pair, then set `PUBLIC_BASE_URL=https://<new-host>` (or
   `http://` for a bare host:port target) in `.env` alongside it.
2. **Clear stale credentials** — every row in `badgeInstances.credential`
   that was signed under the *previous* base URL/DID still has the old host
   baked into its `id`/`achievement.id`/`credentialStatus.*` fields. Byte-
   stability means `badgekit-api` will keep serving those verbatim (logging
   a warning when it does, per the coherence-guard fix) rather than silently
   rewriting them — which is correct for anything that's genuinely already
   been issued and possibly downloaded by a recipient, but is very much
   *not* what you want for rows that were only ever signed as scratch/test
   data under a throwaway domain. Clear those explicitly:
   ```sh
   docker compose exec -T mysql mysql -ubadges -pbadges badgekit \
     -e "UPDATE badgeInstances SET credential = NULL"
   ```
   Scope the `UPDATE` (a `WHERE` clause) if some rows are real, already-
   distributed credentials that must keep serving their old-domain content
   verbatim, and only the *new* rows going forward should sign under the new
   domain.
3. **Restart `api`** (`docker compose up -d api`, or `docker compose build
   api && docker compose up -d api` if the image itself changed) so it picks
   up the new `.env` values. Verify before issuing anything real:
   ```sh
   curl -s https://<new-host>/.well-known/did.json     # -> 200, id matches the new ISSUER_DID
   curl -s https://<new-host>/healthcheck               # -> 200
   ```
4. **`system`/`issuer`/`program` `url` fields get signed into every
   credential issued against them (`issuer.url`, via
   `makeIssuerOrganization()`) — they must be real, correct values before
   any real issuance**, not leftover dev/tunnel placeholders. The validation
   report flagged exactly this as a cosmetic-but-real gap: a demo run's
   `issuer.url` was left at `http://localhost:8080` (the system's `url`
   field from `seed.sh`, unrelated to `PUBLIC_BASE_URL`) and got signed into
   the credential unchanged — harmless for a throwaway validation run,
   **not acceptable for real issuance**. Update every system/issuer/program
   `url` field to the real public origin as part of any move to a durable
   (let alone production) domain, before issuing anything meant to last.

## 4. Key "rotation": what `gen-dev-key.sh` actually does

`./gen-dev-key.sh` (with or without a DID argument) **replaces** the
currently-configured `ISSUER_SIGNING_KEY`/`ISSUER_DID` pair in `.env` — it
does not add a second, additional key alongside the first. Concretely:

- On a throwaway dev/test domain, this is harmless and exactly what you want
  when iterating: the "old" key covered nothing that matters.
- **On any domain that has signed real, already-distributed credentials,
  running `gen-dev-key.sh` again invalidates every one of them.** The new
  key's public half is the only one `did.json`'s `verificationMethod` will
  ever list once the new key is in place; any credential signed under the
  old key now has a `proof.verificationMethod` that no longer resolves to
  anything in the current DID document, so every verifier — the public
  vc.1ed.tech validator included — will report a proof-verification failure
  for it, permanently. This is a **replacement**, not a rotation.
- **True key rotation — serving multiple valid keys from `did.json`
  simultaneously (so credentials signed under an older-but-still-listed key
  keep verifying while new signing moves to a newer key) is not implemented
  yet.** `issuer-key.js#getDidDocument()` builds exactly one
  `verificationMethod` entry, from exactly one configured key. Real rotation
  needs `did.json` to carry a `verificationMethod` array (only the newest
  key's `assertionMethod` reference removed once a rotation is fully retired,
  never the older keys dropped from `verificationMethod` while any credential
  signed under them might still need to verify) — this is tracked for the
  Q2 domain-decision flip (see `docs/ob3-migration-spec.md`'s open questions),
  not implemented today.
- Until real rotation lands: treat every `gen-dev-key.sh` run on anything
  other than a disposable test domain as a hard cutover, and expect it to
  retroactively break verification of everything signed before it.

## 5. Schema note: `credential` column charset

`badgeInstances.credential` (added by
`app/migrations/20260819190152-ob3-salt-credential.js` as `MEDIUMTEXT NULL`,
no explicit charset) currently inherits the table's charset, which is
`utf8mb3` in this stack's `init.sql`-provisioned databases (MySQL 8's
historical default, still what `badgekit`'s tables use here). Signed
credential JSON in practice is ASCII-range (base64url/multibase-encoded
proof values, escaped Unicode in any non-ASCII `\uXXXX` JSON string content),
so this isn't a live bug — but **if this schema is ever migrated to
`utf8mb4`** (e.g. to properly support 4-byte characters — emoji, some CJK
extension characters — in badge names/descriptions that then get signed
into a credential's `credentialSubject.achievement.name`/`.description`),
**the `credential` column's charset must be migrated along with it**,
explicitly, in the same migration. A stored signed JSON string containing an
un-representable 4-byte character under `utf8mb3` doesn't fail loudly the
way `mysql` truncation errors usually would in strict mode for this specific
class of column — a MEDIUMTEXT column silently mangling multi-byte
characters into `?`/malformed sequences on write would corrupt an ALREADY-
SIGNED credential's content without invalidating it at write-time, breaking
proof verification the next time it's served. Don't assume a broader
project-wide `utf8mb3` → `utf8mb4` migration automatically covers this
column just because it's `TEXT`-typed — verify it explicitly.

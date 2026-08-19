# Migration Open Badges 1.x → Open Badges 3.0 — spec d'investigation

**Statut : DRAFT — à faire relire avant tout code** (Task 5.1 de la roadmap BadgeKit)
**Périmètre :** `badgekit-api` (émission d'assertions), impacts mineurs sur `openbadges-badgekit` (front) et la stack compose.
**Date :** 2026-08-19

---

## 1. Contexte et objectif

`badgekit-api` émet aujourd'hui des assertions au format Open Badges « 1.x hébergé » (hosted). Ce format
est obsolète : plus aucun backpack/wallet moderne ne le consomme, il n'offre aucune preuve
cryptographique (la « vérification » consiste à re-télécharger le JSON), et l'écosystème 1EdTech est
passé aux Verifiable Credentials du W3C avec Open Badges 3.0.

Objectif de cette spec : documenter ce qu'on émet réellement aujourd'hui (avec des exemples tirés d'un
badge émis en local), trancher les décisions structurantes, et proposer un plan de migration **additif**
(les endpoints 1.x restent en place, on AJOUTE une représentation OB 3.0).

---

## 2. État des lieux : ce que badgekit-api émet aujourd'hui

### 2.1 Surface d'émission (audit du code, master `2c686fb`)

Tout est dans `badgekit-api/app/routes/badge-instances.js` (routes `/public/*`), plus
`app/routes/badges.js` (listing public), `app/routes/images.js` et `app/routes/utils.js`
(construction des URLs de BadgeClass).

| Route | Rôle | Construite par |
|---|---|---|
| `GET /public/assertions/:instanceSlug` | **Assertion** hébergée (le cœur de l'émission) | `makeAssertion()` (badge-instances.js:556) |
| `GET /public/systems/:s/badges/:b` (+ variantes `issuers/`, `programs/`) | **BadgeClass** | `makeBadgeClass()` (badge-instances.js:588) |
| `GET /public/systems/:s` (+ variantes) | **IssuerOrganization** (cascade program > issuer > system) | `makeIssuerOrganization()` (badge-instances.js:642) |
| `GET /public/badges` | Liste des URLs de BadgeClass (`{badgelist: [{location}]}`) | badges.js:17 |
| `GET /public/images/:imageId` | Image du badge (BLOB MySQL ou 301 vers une URL externe) | images.js:5 |

Côté écriture, `POST …/badges/:badgeSlug/instances` (simple et `/bulk`) crée l'instance, répond
`201` avec un header `Location: /public/assertions/:slug`, et déclenche le **webhook** système avec un
payload `{action: 'award', uid, badge, email, assertionUrl, issuedOn, comment}`. Le `DELETE` d'une
instance envoie `{action: 'revoke', …}` — la « révocation » actuelle, c'est la suppression de la ligne
SQL : l'URL d'assertion répond alors 404.

Table `badgeInstances` (modèle `app/models/badge-instance.js`) : `id, slug, email, issuedOn, expires,
claimCode, badgeId`. Le slug (sha1) sert d'identifiant public de l'assertion.

### 2.2 Exemples JSON réels (émis en local le 2026-08-19)

Badge créé via l'API signée (system `wooclap`, MASTER_SECRET), instance décernée à
`alice@example.org`, puis GET sur les trois routes publiques :

**`GET /public/assertions/b91ca0db5d9a4c0cb19b11c85da6645aa6c62bf3`**

```json
{
  "uid": "b91ca0db5d9a4c0cb19b11c85da6645aa6c62bf3",
  "recipient": {
    "identity": "sha256$7a64adf28737ea90719cbdf0b1a87a5effff3753b79c91d717f4f4153ead0498",
    "type": "email",
    "hashed": true
  },
  "badge": "http://localhost:8080/public/systems/wooclap/badges/ob3-spec-demo",
  "verify": {
    "url": "http://localhost:8080/public/assertions/b91ca0db5d9a4c0cb19b11c85da6645aa6c62bf3",
    "type": "hosted"
  },
  "issuedOn": 1787149761
}
```

**`GET /public/systems/wooclap/badges/ob3-spec-demo`**

```json
{
  "name": "OB3 Spec Demo Badge",
  "description": "Demonstrates contribution to the Open Badges 3.0 migration effort.",
  "image": "http://localhost:8080/images/ob3-demo.png",
  "criteria": "http://localhost:8080/criteria/ob3-spec-demo",
  "alignment": [],
  "issuer": "http://localhost:8080/public/systems/wooclap"
}
```

**`GET /public/systems/wooclap`**

```json
{
  "name": "Wooclap System",
  "url": "http://localhost:8080"
}
```

### 2.3 Constats (dette et écarts)

1. **Pas de JSON-LD** : aucune propriété `@context` ni `type` sur les trois documents. C'est la forme
   OBI 1.0 « hosted » ; même la spec 1.1 (qui a introduit `@context`) n'est pas respectée. On émet donc
   du « 1.x de fait », pas du 1.1 strict.
2. **Aucune signature** : `verify.type` vaut toujours `hosted`. Il n'existe aucune gestion de clés dans
   le code (le seul usage de `jws` est l'auth des appels API). La confiance repose entièrement sur le
   fait que l'URL réponde.
3. **Hash récipiendaire non salé** : `sha256$sha256(email)` (badge-instances.js:561), sans sel — un
   annuaire d'emails se brute-force trivialement. OB 3.0 recommande fortement un sel.
4. **Pas de baking** : contrairement à ce que son nom suggère, `app/lib/image-helper.js` ne fait que
   stocker l'image de la BadgeClass (upload BLOB ou URL) ; aucun code de baking n'existe dans
   `badgekit-api` ni dans `openbadges-badgekit` (le baking était historiquement fait par le service
   séparé `openbadges-bakery` côté backpack).
5. **Bug d'URL d'image** : pour une image uploadée (BLOB), `Image.toUrl()` renvoie `/images/<slug>`
   alors que la seule route servie est `/public/images/:imageId` — l'URL d'image d'une BadgeClass à
   image uploadée est donc cassée. Par ailleurs `makeBadgeClass()` calcule une `imageUrl` absolue…
   puis renvoie la valeur relative non résolue (badge-instances.js:590-596). À corriger au passage.
6. **Le front n'est pas couplé au format** : `openbadges-badgekit` ne consomme pas `assertionUrl` ;
   il pilote l'API d'admin. L'impact front de la migration est nul (au pire, afficher la nouvelle URL).
7. Les routes publiques de BadgeClass étaient inaccessibles jusqu'au fix `8b4e723` (double slash
   `/public//systems/…`) — vérifié réparé en local après rebuild de l'image compose.

---

## 3. La cible : Open Badges 3.0 = un Verifiable Credential W3C

Sources primaires (toutes consultées le 2026-08-19, citées en §10) : spec 1EdTech OB 3.0 (Final,
document version 1.4.5), W3C VC Data Model 2.0 (Recommendation, 15 mai 2025), W3C VC-DI-EdDSA,
méthode `did:web` (W3C CCG).

En OB 3.0, le triplet 1.x « assertion → badge → issuer » (trois documents hébergés) devient **un seul
document signé**, un `OpenBadgeCredential` (alias `AchievementCredential`), qui est un Verifiable
Credential VC-DM 2.0 :

| OBI 1.x (émis aujourd'hui) | OB 3.0 | Notes |
|---|---|---|
| Assertion (`uid`, `issuedOn`, `expires`) | `AchievementCredential` : `id` (URL, [1]), `validFrom` [1], `validUntil` [0..1], `awardedDate` [0..1] | dates en ISO 8601 UTC, plus d'epoch |
| `recipient` (`identity`, `type`, `hashed`) | `credentialSubject` (`AchievementSubject`) + `identifier[]` (`IdentityObject`) | `identityHash`, `identityType: "emailAddress"`, `hashed`, `salt` |
| BadgeClass (document séparé, référencé par URL) | `credentialSubject.achievement` (`Achievement`, **imbriqué**) : `id` [1], `name` [1], `description` [1], `criteria` [1], `image` [0..1], `alignment` [0..*] | `criteria` = `{id}` et/ou `{narrative}` |
| IssuerOrganization (document séparé) | `issuer` (`Profile`, imbriqué) : `id` [1], `type: ["Profile"]`, `name`, `url`, `email` | `id` = URI stable de l'émetteur |
| `verify: {type: "hosted", url}` | `proof` (Data Integrity) **ou** enveloppe VC-JWT | la vérification devient cryptographique |
| — | `@context` [2..*] : `https://www.w3.org/ns/credentials/v2` puis `https://purl.imsglobal.org/spec/ob/v3p0/context-3.0.3.json` (ordre imposé) | |
| — | `type: ["VerifiableCredential", "OpenBadgeCredential"]` | |
| — | `credentialSchema`, `credentialStatus`, `refreshService` (optionnels) | |

Points de spec vérifiés qui pilotent nos choix :

- `credentialSubject` : « Either `id` or at least one `identifier` MUST be supplied » — on peut donc
  omettre `credentialSubject.id` (pas de DID récipiendaire) et ne fournir qu'un `IdentityObject`.
- `IdentityHash` : même format qu'en 1.x, `sha256$<hex>`, mais calculé sur `identifiant + sel`
  (exemple de la spec : `sha256$b5809d…` = SHA-256 de `'a@example.comKosher'`, sel `Kosher`).
- Preuves (§8 de la spec) : deux formats. **VC-JWT** (preuve externe, Compact JWS, `alg` **RS256
  minimum imposé**, payload dupliquant `iss`/`sub`/`nbf`/`jti`/`exp` depuis le credential) et
  **Linked Data Proof** (preuve imbriquée `DataIntegrityProof`, conformance « currently limited to the
  Data Integrity EdDSA Cryptosuites v1.0 suite », cryptosuite `eddsa-rdfc-2022`).
- Dépréférencement de clé (§8.5) : le vérifieur résout la clé publique depuis une URI — URL HTTP
  ou DID URL ; seul le support HTTP est exigé des vérifieurs.
- Format de fichier (§5.1/5.2) : credential à preuve imbriquée servi en JSON,
  `Content-Type: application/vc+ld+json` recommandé (`application/json` toléré) ; VC-JWT servi en
  `text/plain` (Compact JWS). Le baking PNG/SVG existe en OB 3.0 (§5.3) mais reste optionnel.
- Guide de certification 1EdTech (v1.3, 2025-12-12) : pour le rôle **Issuer**, les mécanismes de
  preuve supportés par la suite de conformité sont `eddsa-rdfc-2022` et `ecdsa-sd-2023` (Data
  Integrity) ; le test consiste à émettre un badge valide à `conformance@imsglobal.org`. Les
  credentials doivent passer la validation JSON-LD « safe mode ».

---

## 4. Décisions à trancher (avec recommandation)

### D1 — Cible : OB 3.0 directement, sans étape OB 2.0

**Recommandation : oui.** OB 2.0 est un format de transition aujourd'hui en fin de vie côté 1EdTech
(la spec 3.0 se présente explicitement comme l'unification Open Badges / CLR sur les VC). Passer par
2.0 coûterait un cycle complet (contextes, vérification 2.0) pour un format que les wallets modernes
ne privilégient plus. Le coût de mapping 1.x → 3.0 est équivalent au mapping 1.x → 2.0.

### D2 — Format de preuve : Data Integrity `eddsa-rdfc-2022` (recommandé) plutôt que VC-JWT

L'intuition de départ (« VC-JWT avec `jose`, plus simple en Node ») ne survit pas à la lecture des
sources :

| Critère | VC-JWT (§8.2) | Data Integrity `eddsa-rdfc-2022` (§8.3) |
|---|---|---|
| Certification Issuer 1EdTech | non listé dans les « supported proof mechanisms » du guide de certification | **explicitement supporté** (avec `ecdsa-sd-2023`) |
| Validateur public (vc.1ed.tech) | — | vérifie `DataIntegrityProof` / `eddsa-rdfc-2022` |
| Clés | `alg` **RS256 minimum imposé** ⇒ paire RSA, incohérente avec une `verificationMethod` Ed25519 dans le did:web | Ed25519/Multikey — la même clé sert le did:web |
| Forme servie | Compact JWS en `text/plain` — rupture d'UX par rapport à l'assertion JSON hébergée | JSON + `proof` imbriquée, `application/vc+ld+json` — remplaçant naturel de notre assertion hébergée |
| Implémentation Node | `jose` (très simple) | `@digitalbazaar/vc` 7.3.0 + `@digitalbazaar/data-integrity` 2.5.0 + `@digitalbazaar/eddsa-rdfc-2022-cryptosuite` 1.3.0 + `@digitalbazaar/ed25519-multikey` 1.3.1 — plus de dépendances (canonicalisation RDF), mais API haut niveau `vc.issue()` |
| Coût runtime | signature JWS triviale | canonicalisation RDF à chaque signature — négligeable à notre volumétrie, et on peut mettre le credential signé en cache/DB |

**Recommandation : preuve imbriquée `DataIntegrityProof` / `eddsa-rdfc-2022`, clé Ed25519.** C'est le
seul chemin qui coche à la fois la suite de conformité, le validateur public et la cohérence avec
did:web. VC-JWT reste possible plus tard comme *représentation d'export secondaire* (la spec autorise
plusieurs preuves) — hors périmètre initial.

### D3 — Identité de l'émetteur : `did:web` sur le domaine de l'API

**Recommandation : oui, avec l'URL HTTPS en solution de repli documentée.**

- `did:web:<domaine-api>` se résout en `https://<domaine-api>/.well-known/did.json` (spec did:web) :
  zéro infra nouvelle, un simple endpoint statique de plus dans restify. En dev local :
  `did:web:localhost%3A8080` → `https://localhost:8080/.well-known/did.json`.
- Le DID document expose la clé publique Ed25519 en `verificationMethod` (Multikey) référencée par la
  `proof.verificationMethod` (`did:web:<domaine>#key-0`) avec `proofPurpose: "assertionMethod"`.
- `issuer.id` du credential = ce même `did:web`. Le `Profile` reste imbriqué avec `name`/`url`/`email`
  issus de la cascade program > issuer > system (même logique que `makeIssuerOrganization()`).
- Nuance d'honnêteté : la conformance OB 3.0 n'exige que la résolution de clé par URL HTTP ; un
  `issuer.id` HTTPS avec un controller document hébergé ferait aussi l'affaire. On choisit did:web
  parce que c'est le format le mieux compris des wallets VC, pour un coût marginal (~un handler
  statique). Si la résolution did:web pose problème avec un vérifieur donné, le repli est mécanique
  (même document servi sous une URL HTTPS).
- **Attention multi-tenant :** la clé et le DID sont par *déploiement* (domaine API), pas par
  `system`/`issuer` BadgeKit. Tous les systems d'une instance signent avec la même clé ; leurs
  identités « métier » restent dans le `Profile` imbriqué. C'est assumé pour la v1.

### D4 — Identité du récipiendaire : email hashé (salé), pas de DID

**Recommandation : email hashé d'abord.** Comme en 1.x, mais conforme OB 3.0 :

```json
"identifier": [{
  "type": "IdentityObject",
  "hashed": true,
  "identityHash": "sha256$03fa3c990a282b068f5c58c8fd44527052142d8acb69e36c7f9896623701bbbb",
  "identityType": "emailAddress",
  "salt": "a9f2c4a17d0b4e6c"
}]
```

- `identityHash = 'sha256$' + hex(sha256(email + salt))` — concaténation simple, conforme à l'exemple
  normatif de la spec.
- **Sel aléatoire par instance**, stocké en base (nouvelle colonne, §5.3) — corrige au passage le
  hash non salé du 1.x. L'assertion 1.x existante reste inchangée (compat).
- `credentialSubject.id` (DID du récipiendaire) omis — autorisé dès lors qu'un `identifier` est
  fourni. Les DID récipiendaires impliquent wallets et onboarding : hors scope (§9).

### D5 — Compatibilité descendante : tout conserver, AJOUTER `/public/credentials/:id`

**Recommandation : migration purement additive.**

- Les routes 1.x (`/public/assertions/:slug`, BadgeClass, Issuer, images) restent servies à
  l'identique, sans limite de durée annoncée.
- Nouvelle route `GET /public/credentials/:instanceSlug` → le credential OB 3.0 signé.
- `POST …/instances` : la réponse et le payload webhook gagnent un champ `credentialUrl` **à côté**
  de `assertionUrl` (les consommateurs de webhook existants ne cassent pas) ; le header `Location`
  reste sur l'assertion 1.x.
- Suppression d'instance : le credential répond 404 comme l'assertion — voir la limite documentée
  en §9 (un credential signé déjà téléchargé reste cryptographiquement vérifiable).

### D6 — Validation : validateur public 1EdTech + schéma JSON en CI

**Recommandation :**
1. En CI : validation de chaque credential généré par les tests contre le schéma officiel
   `https://purl.imsglobal.org/spec/ob/v3p0/schema/json/ob_v3p0_achievementcredential_schema.json`
   (déclaré aussi dans `credentialSchema` avec `type: "1EdTechJsonSchemaValidator2019"`).
2. Manuellement à chaque jalon : le validateur public 1EdTech (`https://vc.1ed.tech`, code source
   `1EdTech/digital-credentials-public-validator`) — il vérifie la signature `eddsa-rdfc-2022`, pas
   seulement la forme.
3. La **certification** officielle (suite hébergée sur `certification.imsglobal.org` : émettre un
   badge à `conformance@imsglobal.org` + vidéo du parcours récipiendaire) exige d'être membre
   1EdTech : on vise la *conformité testée par le validateur public*, la certification est une
   décision produit/budget séparée.

---

## 5. Modèle de données et endpoints

### 5.1 Credential cible (exemple pour le badge émis en §2.2)

```json
{
  "@context": [
    "https://www.w3.org/ns/credentials/v2",
    "https://purl.imsglobal.org/spec/ob/v3p0/context-3.0.3.json"
  ],
  "id": "https://badges.example.org/public/credentials/b91ca0db5d9a4c0cb19b11c85da6645aa6c62bf3",
  "type": ["VerifiableCredential", "OpenBadgeCredential"],
  "name": "OB3 Spec Demo Badge",
  "issuer": {
    "id": "did:web:badges.example.org",
    "type": ["Profile"],
    "name": "Wooclap System",
    "url": "http://localhost:8080"
  },
  "validFrom": "2026-08-19T14:29:21Z",
  "awardedDate": "2026-08-19T14:29:21Z",
  "credentialSubject": {
    "type": ["AchievementSubject"],
    "identifier": [{
      "type": "IdentityObject",
      "hashed": true,
      "identityHash": "sha256$03fa3c990a282b068f5c58c8fd44527052142d8acb69e36c7f9896623701bbbb",
      "identityType": "emailAddress",
      "salt": "a9f2c4a17d0b4e6c"
    }],
    "achievement": {
      "id": "https://badges.example.org/public/systems/wooclap/badges/ob3-spec-demo",
      "type": ["Achievement"],
      "name": "OB3 Spec Demo Badge",
      "description": "Demonstrates contribution to the Open Badges 3.0 migration effort.",
      "criteria": { "id": "http://localhost:8080/criteria/ob3-spec-demo" },
      "image": { "id": "http://localhost:8080/images/ob3-demo.png", "type": "Image" }
    }
  },
  "credentialSchema": [{
    "id": "https://purl.imsglobal.org/spec/ob/v3p0/schema/json/ob_v3p0_achievementcredential_schema.json",
    "type": "1EdTechJsonSchemaValidator2019"
  }],
  "proof": [{
    "type": "DataIntegrityProof",
    "cryptosuite": "eddsa-rdfc-2022",
    "created": "2026-08-19T14:29:21Z",
    "verificationMethod": "did:web:badges.example.org#key-0",
    "proofPurpose": "assertionMethod",
    "proofValue": "z…"
  }]
}
```

Règles de mapping (mêmes sources de données que `makeAssertion`/`makeBadgeClass`/`makeIssuerOrganization`) :

| Champ OB 3.0 | Source badgekit-api |
|---|---|
| `id` | URL absolue de la nouvelle route credentials (slug d'instance) |
| `validFrom` / `awardedDate` | `instance.issuedOn` en ISO 8601 UTC |
| `validUntil` | `instance.expires` si présent |
| `name` (credential) | `badge.name` |
| `issuer.name/url/email` | cascade program > issuer > system (comme aujourd'hui) |
| `achievement.id` | URL publique 1.x de la BadgeClass (URI stable ; elle continue de servir le JSON 1.x, ce qui est licite — un `id` doit être une URI, pas nécessairement déréférençable en OB 3.0) |
| `achievement.name` | `badge.name` |
| `achievement.description` | `badge.consumerDescription` |
| `achievement.criteria` | `{id: badge.criteriaUrl}` + `narrative` concaténé depuis les lignes `criteria` du badge si présentes |
| `achievement.image` | URL absolue de l'image (corriger le bug §2.3.5 au passage) |
| `achievement.alignment[]` | `badge.alignments` (`targetName`, `targetUrl`, `targetDescription`) |
| `identifier[0]` | email + sel stocké (§5.3) |

### 5.2 Endpoints ajoutés

| Route | Réponse | Notes |
|---|---|---|
| `GET /public/credentials/:instanceSlug` | credential signé, `Content-Type: application/vc+ld+json` | 404 si instance supprimée (même sémantique que l'assertion) ; le credential signé est **persisté** à l'émission (pas re-signé à chaque GET) pour garantir la stabilité binaire de la preuve |
| `GET /.well-known/did.json` | DID document did:web | statique, généré depuis la clé publique configurée |

Modification (additive) : `POST …/instances` et webhooks gagnent `credentialUrl`.

### 5.3 Migration base de données

Une migration `badgeInstances` (mécanisme existant `app/lib/migrations.js`) :

- `salt VARCHAR(32) NOT NULL` — sel aléatoire (hex) généré à l'émission ; backfill pour les instances
  existantes (leur assertion 1.x ne change pas, seul le credential 3.0 utilise le sel).
- `credential MEDIUMTEXT NULL` — le credential signé sérialisé (source de vérité de la preuve).
  Les instances antérieures à la migration sont signées paresseusement au premier GET.

### 5.4 Gestion des clés

- **Génération** : script npm `generate-issuer-key` (Ed25519 via `@digitalbazaar/ed25519-multikey`),
  sortie : seed/clé privée multibase + fragment de DID document.
- **Stockage** : variable d'environnement `ISSUER_SIGNING_KEY` (multibase) + `ISSUER_DID`
  (ex. `did:web:badges.example.org`), injectées par compose/secret manager — cohérent avec
  `MASTER_SECRET` existant. Jamais en base, jamais dans l'image Docker.
- **Publication** : `/.well-known/did.json` liste la clé publique en `verificationMethod`
  (type `Multikey`, id `…#key-0`) et la référence dans `assertionMethod`.
- **Rotation** : nouvelle clé = nouvel id `#key-1` ; les anciennes clés **restent** dans le DID
  document (les credentials déjà émis référencent leur `verificationMethod` d'origine et doivent
  rester vérifiables) ; les nouvelles émissions signent avec la clé courante. Une clé compromise est
  retirée du DID document — ce qui invalide de fait les credentials qu'elle a signés (assumé ;
  la vraie réponse est une status list, hors scope §9).
- **Dev local** : clé de dev committée nulle part ; `seed.sh` étendu pour en générer une jetable.

---

## 6. Plan de rollout

Chaque étape = une PR sur `badgekit-api` (+ compose le cas échéant), mergeable indépendamment,
derrière la relecture de cette spec. Sizing : S ≈ ≤ 1 j, M ≈ 2-3 j, L ≈ 4-5 j.

| Étape | Contenu | Sizing |
|---|---|---|
| **0. Validation de la spec** | Relecture humaine, gel des décisions D1-D6 | S |
| **1. Clés + did:web** | Script de génération, config `ISSUER_SIGNING_KEY`/`ISSUER_DID`, route `/.well-known/did.json`, compose mis à jour, tests | M |
| **2. Builder de credential** | Fonction pure instance→credential (mapping §5.1), migration DB (`salt`, `credential`), validation contre le schéma JSON officiel dans les tests | M |
| **3. Signature + route publique** | Intégration `@digitalbazaar/vc` (`eddsa-rdfc-2022`), persistance du credential signé à l'émission, `GET /public/credentials/:slug`, `credentialUrl` dans réponses/webhooks | M-L |
| **4. Validation externe** | Passage du validateur public `vc.1ed.tech` sur des credentials émis par la stack locale (dev + un domaine public de test pour la résolution did:web), corrections, page de doc dans `badgekit-stack/docs` | M |
| **5. (optionnel, plus tard)** | VC-JWT en export secondaire, baking §5.3, `credentialStatus`/BitstringStatusList, certification 1EdTech | hors scope, non chiffré |

Total cœur (étapes 1-4) : **~8-12 jours-dev**. Risque principal : la canonicalisation JSON-LD en
« safe mode » (tout terme doit être défini par les contextes) — d'où la validation schéma + validateur
public dès l'étape 2/4, pas à la fin.

Dépendances : aucune sur le front ; l'étape 4 nécessite un domaine HTTPS public pour valider la
résolution did:web de bout en bout (le validateur ne résoudra pas `did:web:localhost%3A8080`).

---

## 7. Validation et conformité (détail)

1. **Schéma JSON** (CI, étape 2+) : `ob_v3p0_achievementcredential_schema.json`, référencé dans
   `credentialSchema`.
2. **Validateur public 1EdTech** (étapes 3-4) : `https://vc.1ed.tech` — vérifie structure, contextes,
   *et* la preuve `eddsa-rdfc-2022`. Auto-hébergeable si besoin
   (`github.com/1EdTech/digital-credentials-public-validator`).
3. **Suite de conformité / certification** (`certification.imsglobal.org`, guide v1.3) : test Issuer =
   émettre un badge valide à `conformance@imsglobal.org` + vidéo du parcours de récupération.
   Nécessite l'adhésion 1EdTech → décision séparée, non bloquante pour émettre du 3.0 valide.
4. **Contre-vérification indépendante** : vérifier un credential émis avec une lib tierce
   (`@digitalbazaar/vc.verifyCredential`) dans les tests d'intégration — ne pas se contenter de
   « ça se signe sans erreur ».

---

## 8. Impacts hors badgekit-api

- **openbadges-badgekit (front)** : aucun changement requis (§2.3.6). Amélioration possible :
  afficher `credentialUrl` sur l'écran d'émission.
- **badgekit-stack (compose)** : deux variables d'env de plus sur le service `api`, `seed.sh` étendu
  (génération de clé de dev), doc d'e2e mise à jour.
- **Consommateurs de webhooks** : rien à faire (champ additif).

---

## 9. Ce qu'on ne fait PAS (hors scope assumé)

- **Wallets / présentation** : pas d'OID4VCI, pas de VC API, pas de Verifiable Presentations, pas
  d'intégration backpack. On émet un document signé récupérable par URL, point.
- **API Open Badges 3.0 (§6-7 de la spec)** : le protocole OAuth 2.0 complet (getCredentials,
  upsertCredential, dynamic client registration) est un rôle « Service Provider » entier — non requis
  pour émettre des credentials valides.
- **DID récipiendaire** : `credentialSubject.id` restera absent ; email hashé seulement (D4).
- **Révocation avancée** : pas de `credentialStatus` / BitstringStatusList / 1EdTech Revocation List
  en v1. La suppression d'instance rend l'URL 404, mais **une copie signée déjà téléchargée reste
  vérifiable** — c'est une régression sémantique par rapport au hosted 1.x qu'il faut annoncer
  honnêtement ; la status list est la réponse propre, planifiée mais non incluse.
- **Baking PNG/SVG** (OB 3.0 §5.3) : on n'en fait pas aujourd'hui en 1.x, on n'en fera pas en v1.
- **Endorsements, refreshService, termsOfUse, evidence, résultats/rubrics, CLR** : non mappés (pas de
  données sources dans BadgeKit).
- **VC-JWT** : pas en v1 (D2) ; réévalué si un consommateur concret l'exige.
- **Multi-clé par system/issuer** : une clé par déploiement (D3).

---

## 10. Sources

Toutes consultées le 2026-08-19 :

- Spec Open Badges 3.0 (1EdTech, Final, doc v1.4.5) : https://www.imsglobal.org/spec/ob/v3p0
  — modèle `AchievementCredential`/`AchievementSubject`/`Achievement`/`Profile`/`IdentityObject`
  (annexe B.1), preuves §8 (VC-JWT RS256 min, LDP `eddsa-rdfc-2022`), formats §5, exemples annexe D.
- Guide de certification OB 3.0 (v1.3, 2025-12-12) : https://www.imsglobal.org/spec/ob/v3p0/cert
  — mécanismes de preuve supportés Issuer/Displayer, procédure de test, JSON-LD safe mode.
- W3C Verifiable Credentials Data Model v2.0 (Recommendation, 15 mai 2025) :
  https://www.w3.org/TR/vc-data-model-2.0/ — `@context` de base, `validFrom`/`validUntil`,
  mécanismes de sécurisation (VC-JOSE-COSE vs Data Integrity), `credentialStatus`.
- W3C Data Integrity EdDSA Cryptosuites v1.0 (Recommendation, 15 mai 2025) :
  https://www.w3.org/TR/vc-di-eddsa/ — `eddsa-rdfc-2022`, Multikey.
- did:web Method Specification (W3C CCG) : https://w3c-ccg.github.io/did-method-web/
  — règles de résolution (`/.well-known/did.json`, encodage `%3A` du port).
- Validateur public : https://vc.1ed.tech /
  https://github.com/1EdTech/digital-credentials-public-validator ; suite de conformité :
  https://certification.imsglobal.org/certification/verifiable-credentials
- Libs npm (versions au 2026-08-19) : `@digitalbazaar/vc` 7.3.0, `@digitalbazaar/data-integrity`
  2.5.0, `@digitalbazaar/eddsa-rdfc-2022-cryptosuite` 1.3.0, `@digitalbazaar/ed25519-multikey` 1.3.1,
  `jose` 6.2.9.
- Code audité : `badgekit-api@2c686fb` (`app/routes/badge-instances.js`, `badges.js`, `images.js`,
  `utils.js`, `app/models/badge-instance.js`, `badge.js`, `image.js`, `app/lib/image-helper.js`,
  `middleware.js`) ; exemples §2.2 émis sur la stack compose locale.

---

## 11. Questions ouvertes pour la relecture

1. D2 : ok pour renoncer à VC-JWT en v1 malgré la simplicité de `jose`, au vu des exigences de la
   suite de conformité ?
2. D3 : le domaine public cible pour `did:web` (et donc l'URL canonique des credentials) — lequel ?
3. §5.3 : persister le credential signé en base (recommandé) vs re-signer à chaque GET — un avis
   contraire ?
4. La régression « révocation » (§9) est-elle acceptable en v1 pour nos cas d'usage ?
5. Faut-il corriger le bug d'URL d'image (§2.3.5) dans une PR séparée avant l'étape 2 ?

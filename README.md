# Proxy Nexus — self-hosted Marvel Champions & Arkham Horror LCG deployment

A self-hosted Docker deployment of [Proxy Nexus](https://github.com/mcwookie/proxynexus-rs)
(a proxy card generator, originally for Netrunner/L5R/AGoT/LotR LCG) with
custom-built [Marvel Champions](https://marvelcdb.com) and
[Arkham Horror: The Card Game](https://arkhamdb.com) adapters, plus a
MinIO-backed web frontend for browsing/generating proxies from a browser
instead of the CLI.

## What's in here

```
proxynexus-package/
├── docker-compose.yml     MinIO + web app services
├── Dockerfile.web         Multi-stage build: Dioxus web app -> nginx
├── .env                   MinIO password + Docker host URL (not tracked in git)
├── .env.example           Template for the above
├── proxynexus-rs/         The patched fork (own git repo — see below)
└── data/
    ├── collections/       Card images, mirrored into MinIO on startup
    └── init.sql           Exported catalog + collection metadata
```

`proxynexus-rs/` is its own independent git repository (`origin` ->
`mcwookie/proxynexus-rs`, `upstream` -> `axmccx/proxynexus-rs`) and is
git-ignored by this outer repo — the two don't interact.

## Quick start

```bash
cp .env.example .env
# edit .env: set a real MINIO_ROOT_PASSWORD, and set PROXYNEXUS_COLLECTIONS_URL
# to this machine's real LAN IP/hostname (not "localhost", unless you'll
# only ever browse from this same machine)

docker compose up -d --build
```

Then open `http://<this-machine's-ip>:8050` in a browser.

## What's actually running

- **MinIO** — a self-hosted, S3-compatible object store standing in for
  the original project's Cloudflare R2 bucket, which this fork doesn't
  have credentials for. Serves card images to the web app.
- **web** — the Dioxus web frontend, built from `proxynexus-rs/proxynexus-gui`
  with a patch (`proxynexus-rs/proxynexus-gui/src/components/mod.rs`)
  that makes the image-serving base URL configurable at build time
  (`PROXYNEXUS_COLLECTIONS_URL`) instead of hardcoded to the upstream
  maintainer's bucket.

## Other docs in this repo

- **`SETUP.md`** — full setup walkthrough plus a troubleshooting section
  covering everything that came up building this the first time (MinIO
  CPU compatibility, stale exports, the localhost/IP trap, a gzip
  filename mismatch in the init.sql loading path).
- **`UPDATING_COLLECTION.md`** — how to add a new Marvel Champions or
  Arkham Horror LCG expansion, or fix a mis-matched/missing card, once
  MarvelCDB/ArkhamDB adds it or you spot a mistake. Also covers the
  multi-machine (images on one PC, Docker on another host) workflow and
  a couple of hard-won pitfalls (silently-dropped non-jpg/png images,
  a "ghost collection" trap after a failed `collection add`).
- **`UPSTREAM_SYNC.md`** — how to pull in updates from the original
  `axmccx/proxynexus-rs` repo into the `proxynexus-rs/` fork here.
- **`PACKAGING.md`** — how to re-package and send an updated version of
  this whole setup to someone else.

## The Marvel Champions adapter, briefly

`proxynexus-rs/proxynexus-core/src/games/marvel_champions/` implements
Proxy Nexus's `GameAdapterInfo`/`CatalogProvider` traits against
MarvelCDB's public API. Notable, hard-won details baked into that code:

- Fetches cards **per-pack**, not via the bulk `/api/public/cards/`
  endpoint — the bulk endpoint silently drops some encounter cards.
- Flattens each card's embedded `linked_card` data (MarvelCDB's
  representation of hidden double-sided cards, like a hero's alter-ego
  side) into its own catalog entry — those hidden cards never appear as
  their own row in either listing endpoint otherwise.
- Every MarvelCDB card `code` (including hidden sides) maps to its own
  independent `Card`/`CardVersion`, matching how MarvelCDB's own data
  already treats them — no `~back` image-part logic needed. Concretely:
  Spider-Man/Peter Parker are `01001a`/`01001b`, two separate catalog
  entries, each needing only its own plain front image
  (`01001a@core.jpg`, `01001b@core.jpg`) — **never** `~back`. There's no
  catalog entry for the bare code `01001`, so renaming these to
  `01001@core.jpg` + `01001@core~back.jpg` (the Arkham Horror LCG
  convention, see below) would silently fail to match any official
  printing. See `UPDATING_COLLECTION.md`'s "Double-sided cards: two
  different conventions" section.

A companion Python script (kept outside this repo — see whichever
`lcg-utils`-style location you keep it in) fuzzy-matches scanned card
filenames against this catalog to produce the `{card_id}@{pack_id}.jpg`
naming convention Proxy Nexus expects.

## The Arkham Horror LCG adapter, briefly

`proxynexus-rs/proxynexus-core/src/games/ahlcg/` implements Proxy
Nexus's `GameAdapterInfo`/`CatalogProvider`/`DecklistProvider`/
`CardBackProvider` traits against [ArkhamDB](https://arkhamdb.com)'s
public API — the fullest of the two custom adapters in this fork.
Notable, hard-won details baked into that code:

- Fetches cards **per-pack**, not via the bulk `/api/public/cards/`
  endpoint — confirmed the bulk endpoint is badly incomplete (1,983 cards
  returned against packs.json's summed `total` of 8,422), worse than the
  MarvelCDB bulk-endpoint bug that motivated the same workaround there.
- Unlike MarvelCDB, ArkhamDB keeps **both sides of a double-sided card
  under one `code`** (e.g. an investigator's front/back), with separate
  `imagesrc`/`backimagesrc` fields rather than issuing the back its own
  card entry. That maps directly onto Proxy Nexus's
  `{card_id}@{pack_id}~back` image-part naming convention, so — unlike
  the Marvel Champions adapter — no linked-card flattening is needed.
- `DecklistProvider` (parses `arkhamdb.com/decklist/view/...` URLs) and
  `CardBackProvider` (bundles official player/encounter card-back art
  into MPC zip exports) are both implemented, going further than the
  Marvel Champions adapter currently does (catalog only, for now).

No fuzzy-matching script exists yet for sourcing Arkham Horror card
images — files need to already follow the naming convention using
ArkhamDB's card codes before `collection build`. Two practical traps hit
while first loading a real collection, both covered in
`UPDATING_COLLECTION.md`'s "Known pitfalls" section:

- Source images pulled from scrapers/mod dumps often include `.webp`
  files, which `collection build` silently drops (only
  `.jpg`/`.jpeg`/`.png` are accepted).
- A Tabletop Simulator save exporter (`lcg_tts_processor.py`, kept
  outside this repo) had a bug where it wrote a `~back` file for
  *every* card, not just genuinely double-sided ones — tagging
  single-sided cards with a spurious copy of the generic
  player/encounter card back. Fixed at the source (only write `~back`
  when TTS's own `UniqueBack` flag is true), and cleaned up
  retroactively in an already-exported collection by cross-referencing
  each `~back` file's `(card_id, pack_id)` against ArkhamDB's
  `double_sided` field rather than trusting image-hash deduplication
  (the generic back isn't always byte-identical across scan batches, so
  hashing alone under-counts the spurious files).

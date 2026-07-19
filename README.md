# Proxy Nexus — self-hosted Marvel Champions deployment

A self-hosted Docker deployment of [Proxy Nexus](https://github.com/mcwookie/proxynexus-rs)
(a proxy card generator, originally for Netrunner/L5R/AGoT/LotR LCG) with
a custom-built [Marvel Champions](https://marvelcdb.com) adapter, plus a
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
- **`UPDATING_COLLECTION.md`** — how to add a new Marvel Champions
  expansion, or fix a mis-matched/missing card, once MarvelCDB adds it or
  you spot a mistake.
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
  already treats them — no `~back` image-part logic needed.

A companion Python script (kept outside this repo — see whichever
`lcg-utils`-style location you keep it in) fuzzy-matches scanned card
filenames against this catalog to produce the `{card_id}@{pack_id}.jpg`
naming convention Proxy Nexus expects.

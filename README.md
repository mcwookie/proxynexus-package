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
  with a patch that makes the image-serving base URL configurable at
  build time (`PROXYNEXUS_COLLECTIONS_URL`) instead of hardcoded to the
  upstream maintainer's bucket. This override has to live in **two**
  places — `proxynexus-gui/src/components/mod.rs`'s `build_image_url`
  (preview thumbnails) and `proxynexus-core/src/image_provider.rs`'s
  `RemoteImageProvider` (PDF/MPC generation). The second one was missed
  in the original patch, which silently broke Generate for every game
  until it was caught and fixed — see `UPSTREAM_SYNC.md` and
  `SETUP.md`'s troubleshooting section.

## Other docs in this repo

- **`SETUP.md`** — full setup walkthrough plus a troubleshooting section
  covering everything that came up building this the first time (MinIO
  CPU compatibility, stale exports, the localhost/IP trap, a gzip
  filename mismatch in the init.sql loading path, a missing
  `.dockerignore` plus accumulated Docker build cache filling the host's
  disk entirely).
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
  side) out of the raw per-pack API response during fetch, extracting
  both sides as separate `McdbCard` rows (`hidden`/`back_link` set
  accordingly) — those hidden cards never appear as their own row in
  either listing endpoint otherwise.
- **The hidden side does NOT get its own `Card`/`CardVersion`.**
  Concretely: Spider-Man/Peter Parker are `01001a`/`01001b` in
  MarvelCDB's own data, but only `01001a` is a real catalog entry —
  `01001a` needs both a front (`01001a@core.jpg`) *and* a back
  (`01001a@core~back.jpg`, Peter Parker's art), the same `~back`
  convention as Arkham Horror LCG below, and there's no catalog entry
  for `01001b` at all. **This was gotten wrong for a long time**: an
  earlier version of this adapter (and this doc) treated every code,
  hidden or not, as its own independent front-only card — confirmed via
  MarvelCDB's own `double_sided: false` flag on both sides, which reads
  exactly like "these are two different cards" but isn't a reliable
  signal for physical print layout at all. The real rules: a hero's
  Hero/Alter-Ego forms are one physical card players flip during play,
  exactly like an ArkhamDB investigator. See "Marvel Champions
  hero/alter-ego: one physical card, not two" below for the full
  correction and how it was verified.
- `McdbPack`'s release-date field was named `date_release`, but
  MarvelCDB's actual JSON key is `available` — every pack silently
  deserialized to `None` for as long as this adapter existed, making the
  Set dropdown's date-based sort a complete no-op for this game (order
  was pure `HashMap` chance, not date-related at all). Fixed by renaming
  the field to match; verified against a live catalog sync that Core
  Set/Captain America/Hercules now get real dates
  (`2019-11-01`/`2019-12-20`/`2026-02-20`). See "Set list sort order"
  below.

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

Unlike Marvel Champions, there's no fuzzy-matching script for scanned
physical cards — instead, Arkham Horror card images are sourced from
Tabletop Simulator mod data via `lcg_tts_processor.py` (kept outside
this repo, in `lcg-utils/lcg-tts-processor/`), which extracts individual
card images and identifies each one against ArkhamDB directly from a
TTS save file (the [SCED](https://github.com/Chr1Z93/SCED) mod for
player cards, [SCED-downloads](https://github.com/Chr1Z93/SCED-downloads)
for encounter cards) rather than from a folder of scans. Its `--naming
dbid` mode outputs directly in the `{card_id}@{pack_id}[~back].ext`
convention `collection build` expects. Several practical traps hit while
first loading real collections through it, all covered in
`UPDATING_COLLECTION.md`'s "Known pitfalls" section and in more detail
in that script's own `PROJECT_CONTEXT.md`:

- Source images pulled from scrapers/mod dumps often include `.webp`
  files, which `collection build` silently drops (only
  `.jpg`/`.jpeg`/`.png` are accepted).
- The TTS exporter had a bug where it wrote a `~back` file for *every*
  card, not just genuinely double-sided ones — tagging single-sided
  cards with a spurious copy of the generic player/encounter card back.
  Fixed at the source (only write `~back` when TTS's own `UniqueBack`
  flag is true), and cleaned up retroactively in an already-exported
  collection by cross-referencing each `~back` file's `(card_id,
  pack_id)` against ArkhamDB's `double_sided` field rather than trusting
  image-hash deduplication
  (the generic back isn't always byte-identical across scan batches, so
  hashing alone under-counts the spurious files).
- Its ArkhamDB lookups switched from one bulk API call to per-pack
  fetching, matching this repo's own `ahlcg` Rust adapter — needed for
  consistency (images must resolve to the same `card_id`/`pack_id` the
  Rust catalog uses), not because the bulk endpoint is actually
  incomplete in the way originally assumed (see that script's
  `PROJECT_CONTEXT.md` bug #9 for a self-correction of the original,
  flawed justification).
- Minicard/parallel-front-back variant images could silently win over
  the real card purely by TTS save traversal-order luck (confirmed: 3 of
  5 Core Set investigators exported with their minicard instead of the
  real full-size card). Fixed by always preferring a directly-resolving
  card id over one that only resolved via suffix-stripping, regardless
  of encounter order.

## Set list sort order

The web app's Set dropdown (`proxynexus-gui/src/components/source_selector.rs`)
is sorted by pack release date, newest first, via
`CardStore::get_available_packs()` in `proxynexus-core/src/card_store.rs`.
Two real bugs found while investigating "the list looks unsorted":

- **Packs sharing the same release date had no tiebreak** -- they were
  collected into a `HashMap` before sorting, and Rust's `HashMap`
  iteration order is randomized per-process, so tied packs could appear
  in a different relative order every time the app restarted. This is
  common: e.g. two separate waves of 5 investigator starter decks each
  released entirely on the same day. Fixed by adding pack name as a
  secondary sort key (`(date_release, name)` instead of `date_release`
  alone), which is fully deterministic regardless of `HashMap` order.
- **Marvel Champions had no working date signal at all** -- see the
  `McdbPack`/`date_release` field-name bug noted in the Marvel Champions
  section above. Its entire Set list order was pure `HashMap` chance
  until that was fixed, not merely mis-ordered on ties.

Also added: a "Release date" / "Alphabetical" radio-button toggle above
the Set dropdown, so users aren't stuck with date order if they'd rather
browse alphabetically. Implemented as a GUI-layer-only change (a
`SetSortMode` signal + a `use_memo` that re-sorts the already-fetched
pack list) -- no new queries, no changes to `card_store.rs` beyond the
tiebreak fix above.

## Variant picker: two different cards sharing a title

Reported symptom: for Marvel Champions' Vision set, the hero and
alter-ego preview tiles both showed the wrong card, only one of the two
could be swapped to the right art via the variant picker, and the
"Apply to all 2 copies" button changed *both* tiles together even
though they're supposed to be different cards. Confirmed real and not
Vision-specific -- MarvelCDB has **7 different official cards** literally
titled just "Vision" (an ally, the hero, its alter-ego, and 4 unrelated
villain-form "leader" cards from a different pack).

Root cause: the variant-picker pipeline (`get_available_printings`,
`select_printing`, `apply_variant_overrides` in `proxynexus-core`, plus
the GUI's `preview_grid.rs`/`main.rs`) matched and grouped candidate
printings by **title** at several points, discarding the specific
`card_id` each request actually carried. Title collisions across
genuinely unrelated cards (not just hero/alter-ego pairs, which share a
title precisely because the game doesn't give them distinct names) all
funnel through the same bucket. Three fixes, all keeping the
title-based *candidate list* intact (that's what legitimately lets a
reprinted card -- e.g. Arkham Horror's Carolyn Fern, same design under a
new official code in a later pack -- offer its other printings as
swappable variants) while fixing everything that decides *which slot a
chosen variant actually applies to*:

- **`select_printing()`** (`card_store.rs`) didn't check a candidate's
  `card_id` against the request's `id` at all -- purely sorted on
  printing/collection preference, official-ness, and date. Two
  candidates tied on all of those (as hero/alter-ego commonly are) fell
  back to input order, meaning a request for one specific card could
  silently resolve to a different card's printing. Fixed by prioritizing
  an exact `card_id` match above every other sort key.
- **`apply_variant_overrides()`** (`query.rs`) tracked occurrence counts
  and both override maps (`global_overrides`, `index_overrides`) keyed
  by normalized title. Fixed by keying both by `card_id` instead --
  "Apply to all N copies" now only ever applies to actual copies of the
  *same* card.
- **GUI** (`preview_grid.rs`, `main.rs`) computed the click-to-open
  variant-picker identity and the printings-by-title grouping the same
  title-keyed way. Fixed to group/identify by `card_id`, deriving the
  title only where it's still needed -- looking up the (intentionally
  title-based) candidate list to show in the picker.

Verified with two new regression tests (`card_store.rs`,
`query.rs`) that construct two printings sharing an identical title but
different `card_id`s -- both fail without these fixes and pass with
them -- plus confirmed the full existing test suite (48 tests) still
passes.

## Card back manifest: which generic back does each card need?

Motivation: most cards' generic card back (when proxying without the
official back art) follows their distribution -- a card from an
encounter set needs the encounter back, a card from a player pack needs
the player back. But that heuristic breaks for specific, real cards:

- **Arkham Horror**: some cards are physically included in a player
  investigator pack (e.g. a signature weakness like "Curse of the
  Rougarou," or a scenario's "Dragged Under" treachery bundled into a
  Definitive Edition-style pack) but are mechanically encounter cards
  that get shuffled into the encounter deck, not the player's deck --
  they need the **encounter** back despite their distribution.
- **Marvel Champions**: some cards are bundled into a hero's own player
  pack (e.g. Ms. Marvel's "Home by Dawn" Obligation card, and each hero
  pack's nemesis villain/scheme set) but are mechanically encounter-side
  cards -- same mismatch, inverted.

Distribution (which pack/collection a card ships in) is therefore the
wrong signal. The right one is each card's own **type** --
ArkhamDB/MarvelCDB's `type_code` field (`investigator`/`asset`/`event`
vs. `enemy`/`treachery`/`agenda`, `hero`/`ally`/`upgrade` vs.
`villain`/`obligation`/`main_scheme`, etc.) -- which both APIs report
per-card regardless of which pack that printing shipped in.

Implementation: each adapter now classifies `type_code` into a
`back_type` of `"player"`, `"encounter"`, or `None` (unclassified) via a
`PLAYER_TYPES`/`ENCOUNTER_TYPES` list and a `back_type_for()` helper --
see `games/ahlcg/adapter.rs` and `games/marvel_champions/adapter.rs`.
That flows through `Card` (catalog) → `AvailablePrintingRow` →
`Printing` (`back_type: Option<String>` on each, with a
`cards.back_type` DB column added via an idempotent `ALTER TABLE`
migration in `db_storage.rs`), so it's available anywhere a `Printing`
is -- including generation.

`proxynexus-cli generate pdf`/`generate mpc` now also write a
`<output>_manifest.csv` and `<output>_manifest.json` alongside the PDF/
ZIP (`proxynexus-core/src/manifest.rs`, wired into `main.rs`'s
`handle_generate`), listing every included printing's `card_id`,
`card_title`, `collection`, `pack_id`, `variant`, `side`, `back_type`,
`is_official`, and `date_release` -- so you can look up, per card,
whether it needs a player or encounter back when physically printing.
The web/desktop GUI's PDF/MPC export (`proxynexus-gui/src/export.rs`)
does the same -- generating a PDF or MPC ZIP now also triggers two
extra downloads (native: two extra save-file dialogs),
`proxynexus_export_manifest.csv` and `.json`, built from the same
`manifest.rs` helpers against the exact printings that went into that
export.

Only Arkham Horror and Marvel Champions classify `back_type` today; the
other adapters (Netrunner, L5R, AGOT, LotR LCG) set it to `None` for
every card -- their proxy pipelines don't currently need this
distinction, and LotR LCG's RingsDB API doesn't expose encounter-side
cards at all (`encounter=1` has no effect), so it couldn't be classified
this way even if wanted later.

**If you already have a catalog synced from before this feature**,
`back_type` will read as empty/`null` in the manifest until you run
`catalog update` again -- the classification happens at catalog-sync
time from live API data, not retroactively from the existing DB.
Verified live: `catalog update` for `ahlcg` correctly classified "Curse
of the Rougarou" and "Dragged Under" as `encounter` and "Lady Esprit"/
"Bear Trap"/"Fishing Net" as `player`; for `marvel_champions`, Ms.
Marvel's "Home by Dawn" plus her nemesis set correctly came back
`encounter` while the rest of her hero pack came back `player`.

### AHLCG weaknesses: `type_code` alone is wrong for these

A second, sharper exception to the `type_code`-based rule above: basic
and signature weaknesses (e.g. Mob Goons, ArkhamDB code `08003`) always
print with the **player** back, even when their `type_code` is
`enemy`/`treachery` -- which would otherwise classify as `encounter`
under `PLAYER_TYPES`/`ENCOUNTER_TYPES` alone. Initially asserted (twice,
incorrectly) that ArkhamDB's `type_code`/Rules Reference "encounter
cardtype" language meant these needed the encounter back; corrected
after user pushback citing a physical card observation and a community
TTS mod's card-back catalog showing Mob Goons using the identical
`BackURL`/`"PlayerCard"` tag as ordinary player cards. The `type_code`
still correctly governs how the card *resolves* once drawn (an
"encounter cardtype" card per the Rules Reference -- not controlled by
any player) -- that's a different axis from which card back it's
physically printed with: the card is drawn from, and shuffled back
into, the investigator's own deck, so it has to carry that deck's back
regardless of how it plays.

Implementation: `AhdbCard` gained a `subtype_code` field (ArkhamDB's own
field, `"weakness"`/`"basicweakness"`/absent) -- confirmed via a live
core-set survey to appear only on weakness cards, spanning multiple
`type_code`s (treachery, enemy, event, asset). `back_type_for()` checks
`subtype_code` first and forces `"player"` when set, before falling
through to the normal `type_code`-based classification.

### Cards whose back is a mechanically different card

`back_type` above answers "does this card's front use the player or
encounter generic back" -- but a card can be genuinely double-sided in
two different ways, and only one of them means the back is really just
the same identity's flip side:

- **Same identity, both sides the same generic-back category** (most
  investigators, acts, agendas): ArkhamDB/MarvelCDB represent this as
  one card with `double_sided: true` (ArkhamDB) or already flatten it
  into two independent catalog entries (MarvelCDB's hero/alter-ego
  pairs). `back_type` staying based on the front alone is correct here
  -- both sides are the same player/encounter identity anyway.
- **A genuinely different card on the back** -- e.g. Arkham Horror's
  Carl Sanford ("The Midwinter Gala"), an `asset`/player card up front
  that flips into an `enemy`/encounter card (ArkhamDB code `71034b`) on
  the back. Reported by a user: the manifest showed `back_type=player`
  for this card with no indication its back needed an encounter back
  instead. Root cause: ArkhamDB represents this via a *different*
  mechanism than `double_sided` -- `linked_to_code`/`linked_card`, a
  mechanically distinct card ArkhamDB never lists as its own top-level
  entry in any pack listing (confirmed empirically), only nested inside
  the front card's data.

Verified via a live scan of all 113 ArkhamDB packs: **464 cards** carry
`linked_to_code`, of which **52** have a front/back that classify to a
*different* `back_type` (like Carl Sanford) -- spread across many sets,
not just Midwinter Gala (Path to Carcosa, Feast of Hemlock Vale, The
Scarlet Keys, Machinations Through Time, and others). Also checked
MarvelCDB the same way (all 60 packs, 324 `linked_card` cards, 14
classify differently). Zero 3-level linked-card chains found in either
game's data.

**Marvel Champions' `linked_card` pairs turned out to need a different
fix than this one, not none at all** -- see "Marvel Champions
hero/alter-ego: one physical card, not two" below. An earlier version
of this doc claimed MC's adapter "already fully flattens every
`linked_card` into its own independent catalog entry" and needed no
fix; that was true of the *code* but wrong about whether that behavior
was actually correct -- it wasn't.

**Deliberately does not change `back_type` for anything** -- an earlier
version of this fix considered making `back_type` `None` for any
`double_sided` card (investigators included), but that's wrong: those
cards still need to show which generic back they'd need, `double_sided`
or not. Instead, three new fields are purely additive, populated only
when ArkhamDB's `linked_to_code` is present: `linked_card_code`,
`linked_card_name`, and `linked_card_back_type` (the linked card's own
`back_type`, computed the same way). For Carl Sanford:
`back_type=player` (unchanged) plus `linked_card_code=71034b`,
`linked_card_name=Carl Sanford`, `linked_card_back_type=encounter` --
so the CSV directly shows the mismatch. For the other 412 linked cards
where both sides happen to classify the same, the same fields still
populate (just don't disagree) -- still useful, since it surfaces the
card has a second identity at all.

Threaded through the same chain as `back_type`
(`games/ahlcg/models.rs`'s `AhdbCard::linked_to_code`/`linked_card` →
`games/ahlcg/adapter.rs` → `catalog::Card` → three more `cards` columns
via another idempotent `ALTER TABLE` migration → `AvailablePrintingRow`
→ `Printing` → `manifest::ManifestEntry`/CSV/JSON). Only populated by
the `ahlcg` adapter; every other adapter sets all three to `None`.

### Marvel Champions hero/alter-ego: one physical card, not two

A hero's Hero and Alter-Ego sides (e.g. Vision, `26001a`/`26001b`) were
being cataloged as two entirely separate, independently-printable
cards, each falling back to the generic player back when no image
existed for it. Initially asserted (confidently, twice) that this was
*correct* -- MarvelCDB reports `double_sided: false` on both sides and
gives each its own `code`/`imagesrc`, which reads exactly like "two
different cards." That assertion was wrong; corrected after user
pushback plus a web search confirming the actual rules: "to change from
hero to alter-ego... the player... flips their identity card to its
other side" -- a single physical double-sided card, exactly like an
ArkhamDB investigator's front/back, not two cards. MarvelCDB's
`double_sided` flag doesn't describe physical print layout the way
ArkhamDB's does; it isn't a reliable signal for this at all.

The reliable signal was already sitting unused in `McdbCard`:
`hidden` (true for the non-primary/Alter-Ego side) and `back_link`
(points to the other side's code). `adapter.rs`'s `fetch_catalog()`
was pushing a `Card`/`CardVersion` for *every* code regardless,
including hidden ones, with `linked_card_code`/`name`/`back_type`
hardcoded to `None` -- i.e. the exact opposite of how `ahlcg` already
treats its own `linked_to_code` pairs (see above). Verified live before
trusting the fix needed to be broad: **69 hero cards** across the whole
MarvelCDB catalog carry a `back_link` (every hero, not a handful).

Fixed in `games/marvel_champions/adapter.rs`: a card with `hidden ==
Some(true)` is now skipped entirely -- no independent `Card`/
`CardVersion`, so it can't show up in search or be generated as its own
printing -- and folded into its visible counterpart's
`linked_card_code`/`linked_card_name`/`linked_card_back_type` instead,
mirroring `ahlcg`'s pattern exactly. `back_type` itself is unchanged
(a hero's own `back_type` still correctly falls back to the generic
player back when no real `~back` image exists in the collection --
that fallback behavior was never the bug). Covered by three new unit
tests (`build_cards_and_versions` extracted as a pure, synchronously
testable function): the hidden side gets no independent catalog entry,
the visible side carries the right `linked_card_*` metadata, and an
ordinary card with no `back_link` is unaffected.

The image side needed a matching fix -- `rename_marvel_champions.py`
(a separate `lcg-utils` tool that turns scanned card images into a
Proxy Nexus collection; see its own `rename_marvel_champions.md` for
the full writeup) previously had no way to produce a `~back` file at
all, only ever writing `{card_id}@{pack_id}.{ext}`. A collection built
before this fix has
`26001a@vision.jpg` *and* `26001b@vision.jpg` as two front-only files;
after re-running the updated script against the original scans, it's
`26001a@vision.jpg` (Hero) + `26001a@vision~back.jpg` (Alter-Ego), with
no `26001b@vision.*` at all. **If you have an existing Marvel Champions
collection from before this fix**, `catalog update` alone isn't enough
-- the images themselves need to be regenerated (re-run the renamer
against your original source scans) and the collection rebuilt/re-added,
the same as the catalog does.

## mpc-autofill order XML

`generate mpc` (CLI and GUI) now also writes a companion
`<output>_mpc_autofill.xml` alongside the ZIP -- an order file for
[mpc-autofill](https://github.com/chilli-axe/mpc-autofill) (the
`chilli-axe/mpc-autofill` desktop tool, not to be confused with
MakePlayingCards' own website), which reads it to automatically fill an
entire print order -- front/back placement, cardstock, and foil --
without manually dragging images into MPC's uploader. Workflow: unzip
the MPC ZIP into a folder, drop `order.xml` (renamed from
`<output>_mpc_autofill.xml`, or just point `--directory` at it) into
that same folder, run the desktop tool there.

Schema verified directly against the tool's actual source
(`chilli-axe/mpc-autofill`'s `desktop-tool/src/order.py`/`constants.py`
and its own `tests/test_order.xml` fixture), not guessed:

*   `<details><quantity>`/`<stock>`/`<foil></details>` -- order-level,
    not per-card. `<stock>` must be one of exactly 5 strings (ArkhamDB
    doesn't drive this -- it's a personal print preference); mapped from
    a new `Cardstock` enum in `mpc.rs`
    (`S27`/`S30`/`S33`/`M31`/`P10`) via a `generate mpc --stock`
    CLI flag (`s27`/`s30`/`s33`/`m31`/`p10`, default `s33`) and
    `--foil` (default off). The GUI has no picker for this yet -- always
    emits `(S33) Superior Smooth`, non-foil, matching the CLI's default.
*   `<fronts>`/`<backs>` each list `<card>` elements with `<id>` (a
    local file path -- confirmed the tool's `CardImage.generate_file_path`
    treats `<id>` as local automatically once it resolves to a real file
    on disk, so plain relative paths work, no Google Drive account
    needed), `<sourceType>Local File</sourceType>`, and `<slots>`
    (0-indexed).
*   `<cardback>` is a single order-wide fallback for any slot *not*
    covered by `<backs>` -- **deliberately not relied on for anything**
    here. A mixed print job needs different generic backs on different
    cards (a player card needs the player back, an encounter card needs
    the encounter back), which one fallback image can't express. Instead
    every single card gets its own explicit `<backs>` entry: its real
    extracted `~back` art if it has one (e.g. Carl Sanford gets his own
    back, not a generic one -- see "Cards whose back is a mechanically
    different card" above), otherwise the correct generic player/
    encounter back chosen via that card's own `back_type` (matched by
    substring against the bundled `CardBackProvider` filenames, e.g.
    `ahlcg_player_back.png`). `<cardback>` is only ever consulted for a
    card with no real back art *and* an unclassified `back_type` --
    rare, and any such card is easy to spot and fix by eye in the MPC
    print preview since it'll be visibly wrong.
*   No card-size field exists in the schema at all -- confirmed the
    desktop tool's `MakePlayingCards` target always starts at
    `design/custom-blank-card.html`, which is MakePlayingCards' "Custom
    Game Cards (63 x 88mm)" product -- exactly the product this whole
    pipeline already assumes, so there's nothing to configure here.
    "Card finishing"/"Packaging" (e.g. shrink-wrap) are checkout-level
    choices outside the schema and outside what the desktop tool
    automates at all -- stay manual steps regardless.

Implementation: `generate_mpc_zip` now returns an `MpcZipOutput { zip_bytes,
autofill_slots }` instead of a bare `Vec<u8>` -- `autofill_slots` is built
from a `WrittenImage` record pushed for every file actually written into
the zip (so the XML's paths are guaranteed to exactly match what's really
in the ZIP -- extension included, which isn't knowable ahead of the
image-processing pass since it depends on runtime format detection, not
just the source filename). `build_autofill_slots()` groups those by
physical card copy and resolves each one's back (real part, generic
match, or `None`); `generate_mpc_autofill_xml()` serializes the result.
Verified against a real generation run (Midwinter Gala, 78 cards): parsed
cleanly with Python's `ElementTree`, front slots exactly covered `0..77`
with no gaps, and every single path the XML references was cross-checked
to actually exist in the generated ZIP.

# Proxy Nexus — self-hosted web app package

## Folder layout this expects

```
proxynexus-package/
├── docker-compose.yml
├── Dockerfile.web
├── .env
├── proxynexus-rs/            <- the patched repo
└── data/
    ├── collections/          <- your ~/.proxynexus/collections
    └── init.sql              <- exported catalog/collection metadata
```

## Before sending to your friend (you do this)

1. Copy your whole `proxynexus-rs` repo (with `proxynexus-gui/src/components/mod.rs`
   already patched to read `PROXYNEXUS_COLLECTIONS_URL`) into this folder as
   `proxynexus-rs/`.

2. Copy your local collection images in, **from the same machine where you
   ran `collection add`** (see the important note below):
   ```bash
   mkdir -p data/collections
   cp -r ~/.proxynexus/collections/. data/collections/
   ```

3. Export your catalog + collection metadata, **also from that same
   machine** — `export` reads whatever local database is on the machine
   you run it on, and collections don't exist anywhere else:
   ```bash
   ./proxynexus-rs/target/release/proxynexus-cli export --output data/init.sql
   ```

4. Rename `.env.example` to `.env` and fill in real values:
   ```bash
   mv .env.example .env
   # edit .env:
   #  - replace change-me-please with a real MinIO password
   #  - replace YOUR-DOCKER-HOST-IP with the real LAN IP or hostname of
   #    whatever machine will actually run `docker compose up` -- NOT
   #    "localhost", unless the web app will only ever be opened from
   #    that same machine
   ```

5. Test it yourself first:
   ```bash
   docker compose up -d --build
   ```
   Open `http://<docker-host-ip>:8050`, select Marvel Champions (and, if
   its collection is loaded too, Arkham Horror LCG), pick a set for each,
   and confirm actual card *images* load (not just names with gray
   boxes). Once confirmed, zip up the whole `proxynexus-package/` folder
   and send it over.

## What your friend does

1. Unzip the folder, `cd` into it.
2. Edit `.env` and set `PROXYNEXUS_COLLECTIONS_URL` to **their own**
   Docker host's real LAN IP or hostname — not the one you tested with,
   it needs to match whatever machine they're actually running this on.
3. `docker compose up -d --build`
4. Open `http://<their-docker-host-ip>:8050` in a browser.

That's it — no CLI, no rclone, no manual sync. Everything needed is
already bundled in `data/`.

## Important: `export` must run on the machine that has the collection

`proxynexus-cli export` reads from whatever local `~/.proxynexus`
database exists on the machine you run it on. The catalog (game/pack/card
metadata) auto-populates itself from the network on every CLI run, so
that part will always look fine no matter where you run `export` from.
**Collections do not auto-populate** — they only exist on the machine
where you actually ran `collection add`. If you run `export` on a
different machine (e.g. directly on a separate Docker host), you'll get
a valid-looking `init.sql` with zero collections/printings in it, and
the web app's set list will show sets but no card images. Always run
`collection list` right before `export` to confirm it shows your
collection — if it says "No collections available," you're on the wrong
machine.

## If something breaks

- **`web` container fails to build**: almost certainly a `dioxus-cli`
  version mismatch. Check `proxynexus-rs/proxynexus-gui/Cargo.toml` for
  the pinned `dioxus` version and install a matching `dioxus-cli` version
  in `Dockerfile.web` (the error message reports both versions directly).
- **`minio` container exits immediately (code 127, "CPU does not support
  x86-64-v2")**: the host CPU is older than recent MinIO images require.
  Already worked around in `docker-compose.yml` by pinning both
  `minio/minio` and `minio/mc` to `-cpuv1` tagged releases — if this
  recurs after a future image update, look for newer `-cpuv1` tags on
  Docker Hub.
- **Game doesn't appear in the dropdown at all**: `data/init.sql` is
  missing that game's data, or is stale. Check with:
  `zcat data/init.sql | grep -c marvel_champions` (or `ahlcg` for Arkham
  Horror LCG) — should be non-zero. If it's zero, re-export (see above)
  and rebuild with `docker compose build web --no-cache`.
- **Sets show up, but card images are gray boxes with no picture**: two
  likely causes, check in this order:
  1. `PROXYNEXUS_COLLECTIONS_URL` in `.env` is set to `localhost` but
     you're browsing from a different machine than the Docker host --
     fix the IP and rebuild.
  2. The bucket doesn't actually have the images at the expected path.
     Compare `zcat data/init.sql | grep "INSERT INTO printings" | head -c 500`
     (shows the expected `file_path`) against
     `docker exec proxynexus-minio mc ls --recursive local/proxynexus-collections/ | head`
     (shows what's actually in the bucket) -- the paths should match
     exactly.
- **Page doesn't load at all**: check `docker compose logs web` and
  confirm the `dx build` output was found (`find /app/target/dx -type d
  -name "public"` inside the builder stage — if `dx`'s output directory
  convention changed between versions, this may need adjusting).
- **Clicking Generate (PDF or MPC) does nothing — no output, no visible
  error**: `PROXYNEXUS_COLLECTIONS_URL` needs to be applied in **two**
  separate places, and generation only exercises the second one:
  `proxynexus-gui/src/components/mod.rs`'s `build_image_url` (preview
  thumbnails) and `proxynexus-core/src/image_provider.rs`'s
  `RemoteImageProvider` (PDF/MPC generation). If only the first one has
  the override, thumbnails load fine but every image fetch during
  generation 404s against the upstream `collections.proxynexus.net`
  bucket instead of your own MinIO — and the failure is only logged to
  the browser devtools console, never surfaced in the UI. Confirm both
  files have the override (check `proxynexus-core/src/image_provider.rs`
  for `option_env!("PROXYNEXUS_COLLECTIONS_URL")`), then rebuild with
  `docker compose build web --no-cache`.

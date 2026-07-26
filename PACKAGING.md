# Packaging this up for someone else

Quick reference for re-doing this later (e.g. after updating your
collection) without having to re-derive it from scratch.

## 1. Sanitize `.env` before packaging

`.env` has *your* MinIO password and *your* Docker host's IP baked in —
your friend needs their own IP for their own machine. Don't ship `.env`
itself; regenerate a clean `.env.example` from it instead:

```bash
cd proxynexus-package
cp .env .env.example
sed -i 's/^PROXYNEXUS_COLLECTIONS_URL=.*/PROXYNEXUS_COLLECTIONS_URL=http:\/\/YOUR-DOCKER-HOST-IP:9000\/proxynexus-collections/' .env.example
sed -i 's/^MINIO_ROOT_PASSWORD=.*/MINIO_ROOT_PASSWORD=change-me-please/' .env.example
rm .env
```

## 2. If your collection changed, re-export first

If you've added/updated cards since the last package, redo this on the
machine that actually has the collection loaded (`collection list` should
show it — if it says "No collections available," you're on the wrong
machine):

```bash
cp -r ~/.proxynexus/collections/. data/collections/
./proxynexus-rs/target/release/proxynexus-cli export --output data/init.sql
```

## 3. Tar it up, excluding the bloat

Run this from **one directory above** `proxynexus-package/`, so it
extracts cleanly into that folder instead of dumping loose files:

```bash
cd /path/to/parent-of/proxynexus-package
tar --exclude='proxynexus-package/proxynexus-rs/target' \
    --exclude='proxynexus-package/proxynexus-rs/.git' \
    --exclude='proxynexus-package/proxynexus-rs/*.pnx' \
    --exclude='proxynexus-package/proxynexus-rs/*.pdf' \
    --exclude='proxynexus-package/proxynexus-rs/*_mpc.zip' \
    -czf proxynexus-package.tar.gz proxynexus-package/
```

Excluded on purpose — Docker rebuilds everything fresh inside its own
container, so none of this is needed by the recipient:
- `proxynexus-rs/target/` — your native Rust build cache, can be several GB
- `proxynexus-rs/.git/` — if present
- `proxynexus-rs/*.pnx`, `*.pdf`, `*_mpc.zip` — leftover CLI test artifacts

Note: a `.dockerignore` at the `proxynexus-package/` root excludes these
same paths (plus `data/collections/`) from the `docker compose build`
context too — but that's a separate mechanism for a separate problem
(build context size/disk space on whoever runs `docker compose build`,
confirmed to matter: without it, build context was 23GB+ and caused a
real "no space left on device" failure — see `SETUP.md`). Keep excluding
them here in the tar as well; `.dockerignore` doesn't shrink what you
ship in the archive itself. `data/collections/` is deliberately **not**
tar-excluded, unlike in `.dockerignore` — the recipient actually needs
those images; the `web` build just doesn't.

## 4. Check the size before sending

```bash
du -sh proxynexus-package.tar.gz
```

With a large card image collection in `data/collections/`, this can
easily be multiple GB — too big for email/chat attachments. Use a
file-sharing service, USB drive, or something like Syncthing/rsync
directly between machines instead.

## 5. What to tell your friend

Point them at `SETUP.md` inside the package — it covers unpacking,
setting up their own `.env` (their own IP, their own password), running
`docker compose up -d --build`, and a full troubleshooting section for
everything that came up while building this the first time (MinIO CPU
compatibility, stale exports, the localhost/IP trap, etc.).

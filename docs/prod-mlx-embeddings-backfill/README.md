# Production MLX Embeddings Backfill — 2026-04-27

This is a durable record of the first production run of the new MLX-based
semantic embeddings backfill against the live Neon Postgres database, plus the
narrow reliability/perf change shipped alongside it.

The backfill writes 768-dimension vectors into `semantic_embeddings` using the
local MLX EmbeddingGemma runtime. It coexists with the older Ollama-provider
rows; the search skill is already filtered to MLX rows by hash, so MLX results
are used immediately and the legacy rows are left in place.

## Embedding metadata used

| Field                       | Value                                       |
| --------------------------- | ------------------------------------------- |
| `embedding_provider`        | `mlx`                                       |
| `embedding_model`           | `mlx-community/embeddinggemma-300m-4bit`    |
| `embedding_model_version`   | `4bit`                                      |
| `embedding_dimension`       | `768`                                       |
| Source content path         | local-only (MLX runtime, no external API)   |

## Pre-flight checks

- Branch cut from a fresh `origin/main` (latest commit `cdcc4ab Filter search
  skill to MLX embedding versions`).
- `pnpm install` — already up to date.
- DB reachable with `skills/picardo-internal-db/scripts/psql.sh -At -c "select
  current_database(), now();"` (database `neondb`). `DATABASE_URL` was loaded
  through the helper from the local-only `references/credentials.env`; no
  credentials were echoed, logged, or committed.
- Pending migration applied: `1777330160000_set-mlx-embedding-defaults`.
  - The `picardo-db migrate up` post-step `pg_dump --schema-only` emitted a
    server/client version mismatch warning (Neon server `18.2`, local
    `pg_dump 16.13`); the migration itself was committed successfully and
    confirmed via `select name from public.pgmigrations where name = ...`.
    No live data was touched by this — schema dump only writes a local file.
- MLX runtime sanity check returned `768`:

  ```sh
  uv run --with mlx-embeddings --with mlx python -c "from mlx_embeddings import load; ..."
  ```

## Initial state

Active rows in `semantic_embeddings` before the run:

| provider | model                                    | version | active rows |
| -------- | ---------------------------------------- | ------- | ----------- |
| ollama   | embeddinggemma                           | latest  | 3,286       |
| mlx      | mlx-community/embeddinggemma-300m-4bit   | 4bit    | 3           |

## Reliability fix shipped with this run

During the first foreground attempt of `pnpm picardo-db embeddings backfill
--apply`, observed throughput was ~0.6 chunks/sec — extrapolating to ~5 hours
to embed ~9.7k chunks. Cause: `embedChunks` was spawning a fresh `uv run ...
python ...` process per source record, which re-loaded the MLX model
(~3–5s) every time. A multi-hour run that re-pays model load on every
record is fragile to laptop sleep, network blips, OOM, etc.

Narrow fix in `src/commands/backfill-embeddings.ts`:

- The MLX Python script became a long-lived worker that loads the model
  once on startup, signals `{"ready": true}` on stdout, then reads
  newline-delimited `{"texts": [...]}` requests from stdin and writes
  newline-delimited `{"embeddings": [...]}` responses on stdout.
- Node spawns the worker once on first stale record (`MlxEmbedder.start`),
  reuses it for all candidates, and closes it in `finally` via
  `MlxEmbedder.stop()` (with a defensive 5s SIGTERM fallback).
- All other behavior — defaults, dry-run mode, hash-based skip, archive of
  stale chunks, transactional writes — is unchanged.

The backfill remains MLX-only; no Ollama path was reintroduced. Source text
still travels only between the local Node process, the local MLX worker, and
the database.

## Production run

```sh
pnpm picardo-db embeddings backfill           # dry-run (capture counts)
pnpm picardo-db embeddings backfill --apply   # write
```

Dry-run summary:

```
Found 5481 source record(s).
Done. source_records=5481 chunks=9739 stale_records=5478 skipped_records=3
  embedded_chunks=0 written_chunks=0 archived_chunks=0
```

`--apply` summary (after the persistent-worker fix):

```
Applying semantic embedding backfill for all target types.
Found 5481 source record(s).
Progress: stale_records=100  embedded_chunks=100   written_chunks=100
Progress: stale_records=200  embedded_chunks=275   written_chunks=275
Progress: stale_records=300  embedded_chunks=3028  written_chunks=3028
... (every 100 stale records) ...
Progress: stale_records=5400 embedded_chunks=9658  written_chunks=9658
Done. source_records=5481 chunks=9739 stale_records=5415 skipped_records=66
  embedded_chunks=9673 written_chunks=9673 archived_chunks=0
```

`skipped_records=66` reflects records whose chunk hashes already matched
existing MLX rows (3 from a prior smoke test plus ~63 from a partial first
attempt that was killed before optimization). The hash-based idempotency
prevented any duplicate work or mid-stream conflicts.

`archived_chunks=0` because no source content shrank below a previously
indexed chunk count during this run.

## Post-backfill verification

Active rows by provider/model/version:

| provider | model                                    | version | active rows |
| -------- | ---------------------------------------- | ------- | ----------- |
| mlx      | mlx-community/embeddinggemma-300m-4bit   | 4bit    | **9,739**   |
| ollama   | embeddinggemma                           | latest  | 3,286       |

Active MLX rows by `target_type`:

| target_type                     | active rows |
| ------------------------------- | ----------- |
| interaction                     | 4,016       |
| document                        | 3,163       |
| extracted_fact                  | 1,064       |
| person                          | 476         |
| call_transcript                 | 277         |
| ai_note                         | 248         |
| organization_research_profile   | 216         |
| organization                    | 216         |
| partnership_integration         | 22          |
| partnership_service             | 21          |
| partnership                     | 20          |

Other invariants:

- `embedding_dimension` min/max for active MLX rows: `768 / 768`.
- `0` archived semantic embeddings overall (no soft-delete fallout).
- `5,481` distinct `(target_type, target_id)` pairs covered by MLX — matches
  the source candidate count from `fetchSourceCandidates`.
- Sanity probe on `match_semantic_embeddings(...)` using an existing
  document-target vector returned 20 hits (`document=11`, `interaction=9`),
  confirming cosine search is healthy. No source text was printed.

## Gates

All run from a clean working tree on the backfill branch:

- `pnpm typecheck` — pass
- `pnpm lint` — pass
- `pnpm test` — 22 / 22 pass (4 files)
- `pnpm build` — pass
- `pnpm picardo-db embeddings backfill --help` — pass

## Safety

- No credentials were printed, logged, or committed. `DATABASE_URL` is loaded
  exclusively through `psql.sh` and the backfill command's existing
  `loadEnvironment()` from local-only `credentials.env`.
- Only authorized writes were performed: `migrate up` (one pending migration)
  and `embeddings backfill --apply`. No `DROP`, `TRUNCATE`, broad `DELETE`,
  or rollback was executed.
- No transcript, AI-note, fact, or other source content is included in this
  report or any commit message.
- Source text travels only Node → local MLX worker → Postgres. No external
  embedding API was contacted at any point.

## Follow-ups (non-blocking)

- Optional: add a follow-up migration (or operations task) to soft-archive
  the legacy Ollama rows once we confirm MLX semantic search quality in
  production for a few days. The search skill is already filtered to MLX
  rows, so this is purely housekeeping.
- Optional: bump the local `pg_dump` to v18 so `migrate up` can refresh
  `schema.sql` automatically against Neon 18.x. Today the migration succeeds
  and only the post-step dump is skipped — non-blocking.

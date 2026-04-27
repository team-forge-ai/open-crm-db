---
name: picardo-db-search
description: Search Picardo's internal Postgres CRM using full-text search, pgvector semantic embeddings, or hybrid retrieval. Use when Codex needs to find organizations, people, interactions, documents, transcripts, notes, facts, partnerships, services, or integrations in the Picardo database with local EmbeddingGemma, MLX, and Postgres search functions.
---

# Picardo DB Search

Use this skill for read-only search against Picardo's internal Postgres CRM.
It combines:

- entity-level full-text search via `search_crm_full_text`
- chunk-level full-text search via `match_full_text_embeddings`
- semantic vector search via `match_semantic_embeddings`

The schema snapshot is in `../../schema.sql`. For entity meanings and privacy
rules, read `../picardo-internal-db/references/schema.md` and
`../picardo-internal-db/references/ai-ingestion.md` when needed.

## Safety

Treat the CRM as production-like data. Searches are read-only. Do not print
credentials, full transcripts, or full AI notes. Return row IDs, target types,
titles, scores, and short excerpts; summarize sensitive matches instead of
dumping raw content.

Use the existing Picardo DB helper so credentials stay local:

```bash
../picardo-internal-db/scripts/psql.sh -c "select now();"
```

The search script uses `DATABASE_URL` when already set. Otherwise it looks for
local-only `credentials.env` files in this repo, `~/.codex/skills`, then
`~/.agents/skills`.

## Fast Path

Semantic search uses MLX EmbeddingGemma through `uv` by default, so no local
server is required. The first run downloads Python wheels and the MLX model;
later runs reuse the local caches.

```bash
uv run --with mlx-embeddings --with mlx python -c "from mlx_embeddings import load; load('mlx-community/embeddinggemma-300m-4bit')"
```

Run hybrid search:

```bash
scripts/search.sh "genomics lab ordering"
scripts/search.sh "genomics lab ordering" --limit 20 --target-types document,ai_note,call_transcript
```

The script prints JSONL from the available search paths. By default it runs:

1. entity-level full-text search over source CRM tables
2. chunk-level full-text search over `semantic_embeddings.content`
3. semantic search after embedding the query locally with MLX using the
   retrieval query prefix `task: search result | query: `

Useful options:

```bash
scripts/search.sh "query" --no-semantic
scripts/search.sh "query" --no-full-text
scripts/search.sh "query" --mlx-model mlx-community/embeddinggemma-300m-4bit
scripts/search.sh "query" --mlx-model-version 4bit
scripts/search.sh "query" --query-prefix ""
scripts/search.sh "query" --min-similarity 0.3
scripts/search.sh "query" --snippet-chars 300
```

## Direct SQL

Use direct SQL when you need a custom shape or joins.

Entity full-text:

```sql
select *
from search_crm_full_text(
  'genomics lab ordering',
  20,
  array['organization', 'document', 'ai_note']
);
```

Chunk full-text:

```sql
select *
from match_full_text_embeddings(
  'genomics lab ordering',
  20,
  array['document', 'ai_note', 'call_transcript']
);
```

Semantic search requires a 768-dimensional query vector from an EmbeddingGemma
variant compatible with the backfilled vectors:

```sql
select *
from match_semantic_embeddings(
  '[...]'::vector,
  20,
  array['document', 'ai_note', 'call_transcript']
);
```

Use `pnpm picardo-db embeddings backfill --apply` to populate or refresh
`semantic_embeddings` before relying on semantic results.

## Result Triage

For precise names, emails, product terms, and quoted phrases, trust full-text
matches first. For vague intent, concepts, and "find things related to..."
prompts, trust semantic matches first. For important answers, inspect overlap
between entity full-text, chunk full-text, and semantic hits before summarizing.

Target types supported by the search functions include:

`organization`, `organization_research_profile`, `person`, `interaction`,
`document`, `partnership`, `partnership_service`,
`partnership_integration`, `call_transcript`, `ai_note`, and
`extracted_fact`.

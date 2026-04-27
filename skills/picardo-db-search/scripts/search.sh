#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  search.sh "query" [options]

Options:
  --limit N                  Results per search path, 1-100. Default: 10.
  --target-types a,b,c       Comma-separated target_type filter.
  --mlx-model MODEL           MLX embedding model. Default: mlx-community/embeddinggemma-300m-4bit.
  --query-prefix TEXT         Prefix added to semantic queries. Default: task: search result | query: .
  --min-similarity N         Minimum semantic similarity. Default: 0.35.
  --snippet-chars N          Max excerpt characters. Default: 500.
  --no-semantic              Skip embedding generation and vector search.
  --no-full-text             Skip entity/chunk full-text search.
  -h, --help                 Show this help.

Output is JSONL. Each row includes search_type plus IDs, scores, and a short
headline/content excerpt.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SKILL_DIR}/../.." && pwd)"
PSQL_HELPER="${PICARDO_DB_PSQL:-${REPO_ROOT}/skills/picardo-internal-db/scripts/psql.sh}"

if [[ -z "${DATABASE_URL:-}" && -z "${PICARDO_DB_CREDENTIALS:-}" ]]; then
  for candidate in \
    "${REPO_ROOT}/skills/picardo-internal-db/references/credentials.env" \
    "${HOME}/.codex/skills/picardo-internal-db/references/credentials.env" \
    "${HOME}/.agents/skills/picardo-internal-db/references/credentials.env"
  do
    if [[ -f "${candidate}" ]]; then
      export PICARDO_DB_CREDENTIALS="${candidate}"
      break
    fi
  done
fi

QUERY=""
LIMIT="10"
TARGET_TYPES=""
MLX_MODEL="${MLX_EMBEDDING_MODEL:-mlx-community/embeddinggemma-300m-4bit}"
QUERY_PREFIX="${PICARDO_SEARCH_QUERY_PREFIX:-task: search result | query: }"
MIN_SIMILARITY="0.35"
SNIPPET_CHARS="500"
RUN_SEMANTIC="1"
RUN_FULL_TEXT="1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --limit)
      LIMIT="${2:-}"
      shift 2
      ;;
    --target-types)
      TARGET_TYPES="${2:-}"
      shift 2
      ;;
    --mlx-model)
      MLX_MODEL="${2:-}"
      shift 2
      ;;
    --query-prefix)
      QUERY_PREFIX="${2-}"
      shift 2
      ;;
    --min-similarity)
      MIN_SIMILARITY="${2:-}"
      shift 2
      ;;
    --snippet-chars)
      SNIPPET_CHARS="${2:-}"
      shift 2
      ;;
    --no-semantic)
      RUN_SEMANTIC="0"
      shift
      ;;
    --no-full-text)
      RUN_FULL_TEXT="0"
      shift
      ;;
    --*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "${QUERY}" ]]; then
        QUERY="$1"
      else
        echo "Unexpected positional argument: $1" >&2
        usage >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [[ -z "${QUERY}" ]]; then
  usage >&2
  exit 2
fi

if ! [[ "${LIMIT}" =~ ^[0-9]+$ ]] || (( LIMIT < 1 || LIMIT > 100 )); then
  echo "--limit must be an integer from 1 to 100." >&2
  exit 2
fi

if ! [[ "${SNIPPET_CHARS}" =~ ^[0-9]+$ ]] || (( SNIPPET_CHARS < 80 || SNIPPET_CHARS > 2000 )); then
  echo "--snippet-chars must be an integer from 80 to 2000." >&2
  exit 2
fi

if ! [[ "${MIN_SIMILARITY}" =~ ^0(\.[0-9]+)?$|^1(\.0+)?$ ]]; then
  echo "--min-similarity must be a decimal from 0 to 1." >&2
  exit 2
fi

if [[ ! -x "${PSQL_HELPER}" ]]; then
  echo "Could not find executable psql helper: ${PSQL_HELPER}" >&2
  exit 1
fi

run_psql() {
  "${PSQL_HELPER}" \
    -X \
    -q \
    -v ON_ERROR_STOP=1 \
    -v search_query="${QUERY}" \
    -v result_limit="${LIMIT}" \
    -v target_types="${TARGET_TYPES}" \
    -v snippet_chars="${SNIPPET_CHARS}" \
    "$@"
}

if [[ "${RUN_FULL_TEXT}" == "1" ]]; then
  run_psql <<'SQL'
\pset footer off
\pset tuples_only on
\pset format unaligned
with filter as (
  select case
    when nullif(:'target_types', '') is null then null::text[]
    else array(
      select btrim(target_type)
      from unnest(string_to_array(:'target_types', ',')) as target_type
      where btrim(target_type) <> ''
    )
  end as target_types
)
select jsonb_build_object(
  'search_type', 'entity_full_text',
  'target_type', target_type,
  'target_id', target_id,
  'title', title,
  'subtitle', subtitle,
  'occurred_at', occurred_at,
  'rank', rank,
  'headline', left(regexp_replace(coalesce(headline, ''), '\s+', ' ', 'g'), :snippet_chars),
  'metadata', metadata
)::text
from search_crm_full_text(:'search_query', :result_limit, (select target_types from filter));

with filter as (
  select case
    when nullif(:'target_types', '') is null then null::text[]
    else array(
      select btrim(target_type)
      from unnest(string_to_array(:'target_types', ',')) as target_type
      where btrim(target_type) <> ''
    )
  end as target_types
)
select jsonb_build_object(
  'search_type', 'chunk_full_text',
  'id', id,
  'target_type', target_type,
  'target_id', target_id,
  'chunk_index', chunk_index,
  'rank', rank,
  'embedding_provider', embedding_provider,
  'embedding_model', embedding_model,
  'embedding_model_version', embedding_model_version,
  'content', left(regexp_replace(content, '\s+', ' ', 'g'), :snippet_chars),
  'metadata', metadata
)::text
from match_full_text_embeddings(:'search_query', :result_limit, (select target_types from filter));
SQL
fi

if [[ "${RUN_SEMANTIC}" == "1" ]]; then
  if ! command -v uv >/dev/null 2>&1; then
    echo "uv is required for MLX semantic search." >&2
    exit 1
  fi

  QUERY_EMBEDDING="$(
    HF_HUB_DISABLE_PROGRESS_BARS=1 uv run --quiet --with mlx-embeddings --with mlx python - "${QUERY}" "${MLX_MODEL}" "${QUERY_PREFIX}" <<'PY'
from mlx_embeddings import load
import mlx.core as mx
import sys

query, model_name, query_prefix = sys.argv[1:4]
text = query if not query_prefix or query.startswith("task:") else f"{query_prefix}{query}"

model, tokenizer = load(model_name)
encoded = tokenizer([text], padding=True, truncation=True, return_tensors="mlx")
embedding = model(encoded["input_ids"], encoded["attention_mask"]).text_embeds[0]
mx.eval(embedding)

if embedding.shape[0] != 768:
    raise SystemExit(f"Expected a 768-dimensional embedding, got {embedding.shape[0]}")

print("[" + ",".join(str(float(value)) for value in embedding.tolist()) + "]")
PY
  )"

  "${PSQL_HELPER}" \
    -X \
    -q \
    -v ON_ERROR_STOP=1 \
    -v query_embedding="${QUERY_EMBEDDING}" \
    -v result_limit="${LIMIT}" \
    -v target_types="${TARGET_TYPES}" \
    -v min_similarity="${MIN_SIMILARITY}" \
    -v snippet_chars="${SNIPPET_CHARS}" <<'SQL'
\pset footer off
\pset tuples_only on
\pset format unaligned
with filter as (
  select case
    when nullif(:'target_types', '') is null then null::text[]
    else array(
      select btrim(target_type)
      from unnest(string_to_array(:'target_types', ',')) as target_type
      where btrim(target_type) <> ''
    )
  end as target_types
)
select jsonb_build_object(
  'search_type', 'semantic',
  'id', id,
  'target_type', target_type,
  'target_id', target_id,
  'chunk_index', chunk_index,
  'similarity', similarity,
  'embedding_provider', embedding_provider,
  'embedding_model', embedding_model,
  'embedding_model_version', embedding_model_version,
  'content', left(regexp_replace(content, '\s+', ' ', 'g'), :snippet_chars),
  'metadata', metadata
)::text
from match_semantic_embeddings(:'query_embedding'::vector, :result_limit, (select target_types from filter)) m
where m.similarity >= (:min_similarity)::double precision;
SQL
fi

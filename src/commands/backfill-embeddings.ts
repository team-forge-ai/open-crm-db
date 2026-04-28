import crypto from 'node:crypto'
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { homedir } from 'node:os'
import path from 'node:path'
import dotenv from 'dotenv'
import pg from 'pg'
import { findRepoRoot, loadConfig } from '../config.js'

const DEFAULT_PROVIDER = 'mlx'
const DEFAULT_MODEL = 'mlx-community/embeddinggemma-300m-4bit'
const DEFAULT_MODEL_VERSION = '4bit'
const DEFAULT_CHUNK_SIZE = 6_000
const DEFAULT_CHUNK_OVERLAP = 500
const DEFAULT_EMBED_BATCH_SIZE = 8
const EMBEDDING_DIMENSION = 768
// Persistent MLX worker: load the model once, then read newline-delimited JSON
// requests from stdin and write newline-delimited JSON responses to stdout.
// This avoids paying the model-load cost (~3-5s) for every source record.
const MLX_EMBED_SCRIPT = `
import json
import sys
from mlx_embeddings import load
import mlx.core as mx

model_name = sys.argv[1]
batch_size = int(sys.argv[2])

model, tokenizer = load(model_name)
sys.stdout.write(json.dumps({"ready": True}) + "\\n")
sys.stdout.flush()

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        request = json.loads(line)
        texts = request["texts"]
        embeddings = []
        for start in range(0, len(texts), batch_size):
            batch = texts[start:start + batch_size]
            encoded = tokenizer(batch, padding=True, truncation=True, return_tensors="mlx")
            output = model(encoded["input_ids"], encoded["attention_mask"])
            batch_embeddings = output.text_embeds
            mx.eval(batch_embeddings)
            embeddings.extend(batch_embeddings.tolist())
        sys.stdout.write(json.dumps({"embeddings": embeddings}) + "\\n")
    except Exception as exc:  # noqa: BLE001
        sys.stdout.write(json.dumps({"error": str(exc)}) + "\\n")
    sys.stdout.flush()
`

const TARGET_TYPES = [
  'organization',
  'organization_research_profile',
  'person',
  'interaction',
  'document',
  'partnership',
  'partnership_service',
  'partnership_integration',
  'call_transcript',
  'ai_note',
  'extracted_fact',
  'team_member',
  'task_project',
  'task',
  'task_comment',
] as const

type TargetType = (typeof TARGET_TYPES)[number]

export interface BackfillEmbeddingsOptions {
  apply?: boolean
  batchSize?: number
  chunkOverlap?: number
  chunkSize?: number
  credentialsEnvPath?: string
  force?: boolean
  limit?: number
  model?: string
  modelVersion?: string
  provider?: string
  targetType?: string
  verbose?: boolean
}

interface NormalizedOptions {
  apply: boolean
  batchSize: number
  chunkOverlap: number
  chunkSize: number
  force: boolean
  limit: number | null
  model: string
  modelVersion: string
  provider: string
  targetTypes: TargetType[]
  verbose: boolean
}

interface SourceCandidate {
  target_type: TargetType
  target_id: string
  title: string | null
  updated_at: Date | null
  content: string
}

interface ContentChunk {
  index: number
  content: string
  hash: string
}

interface ExistingChunk {
  chunk_index: number
  content_sha256: string
}

interface BackfillStats {
  archived: number
  candidates: number
  chunks: number
  embedded: number
  skipped: number
  stale: number
  written: number
}

export async function backfillEmbeddings(
  options: BackfillEmbeddingsOptions = {},
): Promise<void> {
  const repoRoot = findRepoRoot()
  loadEnvironment(repoRoot, options.credentialsEnvPath)

  const normalized = normalizeOptions(options)
  const databaseUrl = loadConfig({ skipDotenv: true }).databaseUrl
  const pool = new pg.Pool({ connectionString: databaseUrl })
  const stats: BackfillStats = {
    archived: 0,
    candidates: 0,
    chunks: 0,
    embedded: 0,
    skipped: 0,
    stale: 0,
    written: 0,
  }

  let embedder: MlxEmbedder | null = null
  try {
    await assertEmbeddingSchema(pool)
    if (normalized.apply) {
      await assertMlxRuntime()
    }

    const candidates = await fetchSourceCandidates(pool, normalized)
    stats.candidates = candidates.length
    const existingByTarget = await fetchExistingChunksByTarget(pool, normalized)

    console.log(
      `${normalized.apply ? 'Applying' : 'Dry run:'} semantic embedding backfill for ${describeTargets(
        normalized.targetTypes,
      )}.`,
    )
    console.log(`Found ${candidates.length} source record(s).`)

    for (const candidate of candidates) {
      const chunks = chunkContent(candidate.content, {
        chunkSize: normalized.chunkSize,
        overlap: normalized.chunkOverlap,
      })
      stats.chunks += chunks.length

      const existing = existingByTarget.get(targetKey(candidate)) ?? []
      const stale = normalized.force || chunksChanged(chunks, existing)
      if (!stale) {
        stats.skipped += 1
        continue
      }

      stats.stale += 1
      if (!normalized.apply) {
        if (normalized.verbose) {
          console.log(
            `Would embed ${candidate.target_type} ${candidate.target_id}: ${chunks.length} chunk(s).`,
          )
        }
        continue
      }

      if (!embedder) {
        embedder = await MlxEmbedder.start(normalized)
      }
      const embeddings = await embedChunks(embedder, normalized, chunks)
      stats.embedded += embeddings.length
      await writeChunks(pool, normalized, candidate, chunks, embeddings)
      const archived = await archiveStaleChunks(
        pool,
        normalized,
        candidate,
        chunks.length,
      )
      stats.archived += archived
      stats.written += chunks.length

      if (normalized.verbose) {
        console.log(
          `Embedded ${candidate.target_type} ${candidate.target_id}: ${chunks.length} chunk(s).`,
        )
      } else if (stats.stale % 100 === 0) {
        console.log(
          `Progress: stale_records=${stats.stale} embedded_chunks=${stats.embedded} written_chunks=${stats.written}`,
        )
      }
    }

    console.log(
      [
        `Done. source_records=${stats.candidates}`,
        `chunks=${stats.chunks}`,
        `stale_records=${stats.stale}`,
        `skipped_records=${stats.skipped}`,
        `embedded_chunks=${stats.embedded}`,
        `written_chunks=${stats.written}`,
        `archived_chunks=${stats.archived}`,
      ].join(' '),
    )

    if (!normalized.apply) {
      console.log('Dry run only. Re-run with --apply to write embeddings.')
    }
  } finally {
    if (embedder) {
      await embedder.stop()
    }
    await pool.end()
  }
}

function loadEnvironment(repoRoot: string, credentialsEnvPath?: string): void {
  dotenv.config({ path: path.join(repoRoot, '.env'), override: false })

  if (process.env.DATABASE_URL) {
    return
  }

  const credentialPaths = [
    credentialsEnvPath,
    path.join(
      repoRoot,
      'skills',
      'open-crm-db',
      'references',
      'credentials.env',
    ),
    path.join(
      homedir(),
      '.codex',
      'skills',
      'open-crm-db',
      'references',
      'credentials.env',
    ),
    path.join(
      homedir(),
      '.agents',
      'skills',
      'open-crm-db',
      'references',
      'credentials.env',
    ),
  ].filter((p): p is string => Boolean(p))

  for (const credentialPath of credentialPaths) {
    dotenv.config({ path: credentialPath, override: false })
    if (process.env.DATABASE_URL) {
      break
    }
  }
}

function normalizeOptions(options: BackfillEmbeddingsOptions): NormalizedOptions {
  const chunkSize = positiveInteger(options.chunkSize, DEFAULT_CHUNK_SIZE)
  const chunkOverlap = positiveInteger(
    options.chunkOverlap,
    DEFAULT_CHUNK_OVERLAP,
  )
  if (chunkOverlap >= chunkSize) {
    throw new Error('--chunk-overlap must be smaller than --chunk-size.')
  }

  return {
    apply: Boolean(options.apply),
    batchSize: positiveInteger(options.batchSize, DEFAULT_EMBED_BATCH_SIZE),
    chunkOverlap,
    chunkSize,
    force: Boolean(options.force),
    limit:
      options.limit === undefined ? null : positiveInteger(options.limit, 0),
    model: nonBlank(options.model, DEFAULT_MODEL),
    modelVersion: nonBlank(options.modelVersion, DEFAULT_MODEL_VERSION),
    provider: nonBlank(options.provider, DEFAULT_PROVIDER),
    targetTypes: parseTargetTypes(options.targetType),
    verbose: Boolean(options.verbose),
  }
}

function positiveInteger(value: number | undefined, fallback: number): number {
  if (value === undefined || !Number.isFinite(value)) {
    return fallback
  }
  const integer = Math.trunc(value)
  if (integer < 0) {
    throw new Error('Numeric options must be zero or greater.')
  }
  return integer
}

function nonBlank(value: string | undefined, fallback: string): string {
  const normalized = value?.trim()
  return normalized ? normalized : fallback
}

function parseTargetTypes(value: string | undefined): TargetType[] {
  if (!value?.trim()) {
    return [...TARGET_TYPES]
  }

  const parsed = value
    .split(',')
    .map((part) => part.trim())
    .filter(Boolean)

  const invalid = parsed.filter(
    (part): part is string => !TARGET_TYPES.includes(part as TargetType),
  )
  if (invalid.length > 0) {
    throw new Error(
      `Unknown target type(s): ${invalid.join(', ')}. Expected one of: ${TARGET_TYPES.join(
        ', ',
      )}.`,
    )
  }

  return [...new Set(parsed as TargetType[])]
}

async function assertEmbeddingSchema(pool: pg.Pool): Promise<void> {
  const result = await pool.query<{ exists: boolean }>(
    `
      select exists (
        select 1
          from information_schema.tables
         where table_schema = 'public'
           and table_name = 'semantic_embeddings'
      ) as exists
    `,
  )

  if (!result.rows[0]?.exists) {
    throw new Error(
      'semantic_embeddings does not exist. Run `pnpm open-crm-db migrate up` before backfilling embeddings.',
    )
  }
}

async function assertMlxRuntime(): Promise<void> {
  await runProcess('uv', ['--version'], '')
}

async function fetchSourceCandidates(
  pool: pg.Pool,
  options: NormalizedOptions,
): Promise<SourceCandidate[]> {
  const result = await pool.query<SourceCandidate>(
    `
      with candidates as (
        select
          'organization'::text as target_type,
          o.id as target_id,
          o.name as title,
          o.updated_at,
          concat_ws(E'\\n',
            'Organization: ' || o.name,
            'Legal name: ' || o.legal_name,
            'Domain: ' || o.domain::text,
            'Website: ' || o.website,
            'Description: ' || o.description,
            'Industry: ' || o.industry,
            'Headquarters: ' || concat_ws(', ', o.hq_city, o.hq_region, o.hq_country),
            'Notes: ' || o.notes
          ) as content
        from organizations o
        where o.archived_at is null

        union all

        select
          'organization_research_profile'::text,
          orp.id,
          coalesce(orp.canonical_name, orp.domain::text, 'Organization research profile'),
          orp.updated_at,
          concat_ws(E'\\n',
            'Organization research profile: ' || orp.canonical_name,
            'Website: ' || orp.website,
            'Domain: ' || orp.domain::text,
            'Description: ' || orp.one_line_description,
            'Category: ' || orp.category,
            'Healthcare relevance: ' || orp.healthcare_relevance,
            'Partnership fit: ' || orp.partnership_fit,
            'Partnership fit rationale: ' || orp.partnership_fit_rationale,
            'Offerings: ' || nullif(orp.offerings::text, '[]'),
            'Likely use cases: ' || nullif(orp.likely_use_cases::text, '[]'),
            'Integration signals: ' || nullif(orp.integration_signals::text, '[]'),
            'Compliance signals: ' || nullif(orp.compliance_signals::text, '[]'),
            'Key public people: ' || nullif(orp.key_public_people::text, '[]'),
            'Suggested tags: ' || nullif(orp.suggested_tags::text, '[]'),
            'Review flags: ' || nullif(orp.review_flags::text, '[]')
          )
        from organization_research_profiles orp

        union all

        select
          'person'::text,
          p.id,
          p.full_name,
          p.updated_at,
          concat_ws(E'\\n',
            'Person: ' || p.full_name,
            'Display name: ' || p.display_name,
            'Preferred name: ' || p.preferred_name,
            'Headline: ' || p.headline,
            'Summary: ' || p.summary,
            'Location: ' || concat_ws(', ', p.city, p.region, p.country),
            'Timezone: ' || p.timezone,
            'Website: ' || p.website,
            'Notes: ' || p.notes
          )
        from people p
        where p.archived_at is null

        union all

        select
          'interaction'::text,
          i.id,
          coalesce(i.subject, i.type::text || ' interaction'),
          i.updated_at,
          concat_ws(E'\\n',
            'Interaction: ' || i.subject,
            'Type: ' || i.type::text,
            'Direction: ' || i.direction::text,
            'Occurred at: ' || i.occurred_at::text,
            'Location: ' || i.location,
            'Body: ' || i.body
          )
        from interactions i
        where i.archived_at is null

        union all

        select
          'document'::text,
          d.id,
          d.title,
          d.updated_at,
          concat_ws(E'\\n',
            'Document: ' || d.title,
            'Type: ' || d.document_type,
            'Summary: ' || d.summary,
            'Authored at: ' || d.authored_at::text,
            'Occurred at: ' || d.occurred_at::text,
            'Source path: ' || d.source_path,
            'Body: ' || d.body
          )
        from documents d
        where d.archived_at is null

        union all

        select
          'partnership'::text,
          p.id,
          p.name,
          p.updated_at,
          concat_ws(E'\\n',
            'Partnership: ' || p.name,
            'Type: ' || p.partnership_type,
            'Stage: ' || p.stage,
            'Priority: ' || p.priority,
            'Strategic rationale: ' || p.strategic_rationale,
            'Commercial model: ' || p.commercial_model,
            'Status notes: ' || p.status_notes
          )
        from partnerships p
        where p.archived_at is null

        union all

        select
          'partnership_service'::text,
          ps.id,
          ps.name,
          ps.updated_at,
          concat_ws(E'\\n',
            'Partnership service: ' || ps.name,
            'Service type: ' || ps.service_type,
            'Status: ' || ps.status,
            'Patient facing: ' || ps.patient_facing::text,
            'Clinical use: ' || ps.clinical_use,
            'Data modalities: ' || nullif(ps.data_modalities::text, '[]')
          )
        from partnership_services ps
        where ps.archived_at is null

        union all

        select
          'partnership_integration'::text,
          pi.id,
          pi.integration_type || ' integration',
          pi.updated_at,
          concat_ws(E'\\n',
            'Partnership integration: ' || pi.integration_type,
            'Status: ' || pi.status,
            'Sync direction: ' || pi.sync_direction,
            'Data formats: ' || nullif(pi.data_formats::text, '[]'),
            'Consent required: ' || pi.consent_required::text,
            'BAA required: ' || pi.baa_required::text,
            'Notes: ' || pi.notes
          )
        from partnership_integrations pi
        where pi.archived_at is null

        union all

        select
          'call_transcript'::text,
          ct.id,
          coalesce(i.subject, 'Call transcript'),
          ct.updated_at,
          concat_ws(E'\\n',
            'Call transcript: ' || coalesce(i.subject, ct.id::text),
            'Format: ' || ct.format::text,
            'Language: ' || ct.language,
            'Transcribed by: ' || ct.transcribed_by,
            'Transcript: ' || ct.raw_text
          )
        from call_transcripts ct
        left join interactions i on i.id = ct.interaction_id

        union all

        select
          'ai_note'::text,
          an.id,
          coalesce(an.title, an.kind::text || ' AI note'),
          an.updated_at,
          concat_ws(E'\\n',
            'AI note: ' || an.title,
            'Kind: ' || an.kind::text,
            'Model: ' || an.model,
            'Generated at: ' || an.generated_at::text,
            'Content: ' || an.content
          )
        from ai_notes an

        union all

        select
          'extracted_fact'::text,
          ef.id,
          ef.key,
          ef.updated_at,
          concat_ws(E'\\n',
            'Extracted fact: ' || ef.key,
            'Subject type: ' || ef.subject_type::text,
            'Value: ' || ef.value_text,
            'Structured value: ' || ef.value_json::text,
            'Confidence: ' || ef.confidence::text,
            'Observed at: ' || ef.observed_at::text,
            'Source excerpt: ' || ef.source_excerpt
          )
        from extracted_facts ef

        union all

        select
          'team_member'::text,
          iu.id,
          iu.name,
          iu.updated_at,
          concat_ws(E'\\n',
            'Team member: ' || iu.name,
            'Title: ' || iu.title,
            'Email: ' || iu.email::text,
            'Bot: ' || iu.is_bot::text
          )
        from team_members iu
        where iu.archived_at is null

        union all

        select
          'task_project'::text,
          tp.id,
          tp.name,
          tp.updated_at,
          concat_ws(E'\\n',
            'Task project: ' || tp.name,
            'Summary: ' || tp.summary,
            'Description: ' || tp.description,
            'Status: ' || concat_ws(' / ', tp.status_name, tp.status_type),
            'Priority: ' || concat_ws(' / ', tp.priority_label, tp.priority_value::text),
            'Start date: ' || tp.start_date::text,
            'Target date: ' || tp.target_date::text,
            'Source URL: ' || tp.source_url
          )
        from task_projects tp
        where tp.archived_at is null

        union all

        select
          'task'::text,
          t.id,
          coalesce(t.source_identifier || ': ' || t.title, t.title),
          t.updated_at,
          concat_ws(E'\\n',
            'Task: ' || coalesce(t.source_identifier || ': ' || t.title, t.title),
            'Project: ' || tp.name,
            'Team: ' || tt.name,
            'Status: ' || ts.name,
            'Status type: ' || ts.status_type,
            'Assignee: ' || assignee.name,
            'Creator: ' || creator.name,
            'Priority: ' || concat_ws(' / ', t.priority_label, t.priority_value::text),
            'Due date: ' || t.due_date::text,
            'Started at: ' || t.started_at::text,
            'Completed at: ' || t.completed_at::text,
            'Canceled at: ' || t.canceled_at::text,
            'Source URL: ' || t.source_url,
            'Git branch: ' || t.git_branch_name,
            'Description: ' || t.description
          )
        from tasks t
        left join task_projects tp on tp.id = t.project_id
        left join task_teams tt on tt.id = t.team_id
        left join task_statuses ts on ts.id = t.status_id
        left join team_members assignee on assignee.id = t.assignee_member_id
        left join team_members creator on creator.id = t.creator_member_id
        where t.archived_at is null

        union all

        select
          'task_comment'::text,
          tc.id,
          coalesce(t.source_identifier || ' comment', 'Task comment'),
          tc.updated_at,
          concat_ws(E'\\n',
            'Task comment on: ' || coalesce(t.source_identifier || ': ' || t.title, t.title),
            'Author: ' || iu.name,
            'Created at: ' || tc.source_created_at::text,
            'Comment: ' || tc.body
          )
        from task_comments tc
        join tasks t on t.id = tc.task_id
        left join team_members iu on iu.id = tc.author_member_id
        where tc.archived_at is null
      )
      select
        target_type::text as target_type,
        target_id::text as target_id,
        title,
        updated_at,
        content
      from candidates
      where target_type = any($1::text[])
        and length(trim(content)) > 0
      order by target_type, updated_at nulls first, target_id
      limit $2
    `,
    [options.targetTypes, options.limit],
  )

  return result.rows
}

function chunkContent(
  content: string,
  options: { chunkSize: number; overlap: number },
): ContentChunk[] {
  const normalized = content.replace(/\r\n/g, '\n').trim()
  if (!normalized) {
    return []
  }

  const chunks: ContentChunk[] = []
  let start = 0
  while (start < normalized.length) {
    const maxEnd = Math.min(start + options.chunkSize, normalized.length)
    let end = maxEnd
    if (maxEnd < normalized.length) {
      const newline = normalized.lastIndexOf('\n\n', maxEnd)
      const sentence = normalized.lastIndexOf('. ', maxEnd)
      const space = normalized.lastIndexOf(' ', maxEnd)
      const minBreak = start + Math.floor(options.chunkSize * 0.65)
      const breakPoint = [newline, sentence + 1, space]
        .filter((candidate) => candidate > minBreak)
        .sort((a, b) => b - a)[0]
      if (breakPoint !== undefined) {
        end = breakPoint
      }
    }

    const chunk = normalized.slice(start, end).trim()
    if (chunk) {
      chunks.push({
        index: chunks.length,
        content: chunk,
        hash: sha256(chunk),
      })
    }

    if (end >= normalized.length) {
      break
    }
    start = Math.max(end - options.overlap, start + 1)
  }

  return chunks
}

function sha256(content: string): string {
  return crypto.createHash('sha256').update(content).digest('hex')
}

async function fetchExistingChunksByTarget(
  pool: pg.Pool,
  options: NormalizedOptions,
): Promise<Map<string, ExistingChunk[]>> {
  const result = await pool.query<
    ExistingChunk & { target_id: string; target_type: TargetType }
  >(
    `
      select
        target_type::text as target_type,
        target_id::text as target_id,
        chunk_index,
        content_sha256
        from semantic_embeddings
       where target_type = any($1::text[])
         and embedding_provider = $2
         and embedding_model = $3
         and embedding_model_version = $4
         and archived_at is null
       order by target_type, target_id, chunk_index
    `,
    [
      options.targetTypes,
      options.provider,
      options.model,
      options.modelVersion,
    ],
  )

  const byTarget = new Map<string, ExistingChunk[]>()
  for (const row of result.rows) {
    const key = targetKey({
      target_id: row.target_id,
      target_type: row.target_type,
    })
    const rows = byTarget.get(key) ?? []
    rows.push({
      chunk_index: row.chunk_index,
      content_sha256: row.content_sha256,
    })
    byTarget.set(key, rows)
  }
  return byTarget
}

function targetKey(input: {
  target_id: string
  target_type: TargetType
}): string {
  return `${input.target_type}:${input.target_id}`
}

function chunksChanged(chunks: ContentChunk[], existing: ExistingChunk[]): boolean {
  if (chunks.length !== existing.length) {
    return true
  }

  return chunks.some((chunk, index) => {
    const existingChunk = existing[index]
    return (
      existingChunk?.chunk_index !== chunk.index ||
      existingChunk.content_sha256 !== chunk.hash
    )
  })
}

async function embedChunks(
  embedder: MlxEmbedder,
  options: NormalizedOptions,
  chunks: ContentChunk[],
): Promise<number[][]> {
  const inputs = chunks.map((chunk) => `title: none | text: ${chunk.content}`)
  const embeddings = await embedder.embed(inputs)

  if (embeddings.length !== chunks.length) {
    throw new Error('MLX embedding worker returned an unexpected response.')
  }

  return embeddings.map((embedding, index) => {
    if (!isNumberArray(embedding)) {
      throw new Error(`MLX embedding ${index} is not a numeric vector.`)
    }
    if (embedding.length !== EMBEDDING_DIMENSION) {
      throw new Error(
        `Expected ${EMBEDDING_DIMENSION}-dimension embeddings from ${options.model}, received ${embedding.length}.`,
      )
    }
    return embedding
  })
}

class MlxEmbedder {
  private constructor(
    private readonly child: ChildProcessWithoutNullStreams,
    private buffer: string,
    private pending: {
      resolve: (value: unknown[]) => void
      reject: (error: Error) => void
    }[],
    private exitError: Error | null,
  ) {}

  static async start(options: NormalizedOptions): Promise<MlxEmbedder> {
    const child = spawn(
      'uv',
      [
        'run',
        '--quiet',
        '--with',
        'mlx-embeddings',
        '--with',
        'mlx',
        'python',
        '-c',
        MLX_EMBED_SCRIPT,
        options.model,
        String(options.batchSize),
      ],
      {
        env: { ...process.env, HF_HUB_DISABLE_PROGRESS_BARS: '1' },
        stdio: ['pipe', 'pipe', 'pipe'],
      },
    )
    child.stdout.setEncoding('utf8')
    child.stderr.setEncoding('utf8')

    const embedder = new MlxEmbedder(child, '', [], null)

    let stderrTail = ''
    child.stderr.on('data', (chunk: string) => {
      stderrTail = (stderrTail + chunk).slice(-2000)
    })

    child.stdout.on('data', (chunk: string) => {
      embedder.handleStdout(chunk)
    })

    child.on('error', (err) => {
      embedder.fail(err)
    })

    child.on('close', (code) => {
      embedder.fail(
        new Error(
          `MLX embedder exited with code ${code ?? 'unknown'}: ${stderrTail.trim()}`,
        ),
      )
    })

    // Wait for the worker to signal readiness.
    await new Promise<void>((resolve, reject) => {
      const onReady = (line: string) => {
        try {
          const parsed = JSON.parse(line) as { ready?: boolean; error?: string }
          if (parsed.ready) {
            embedder.removeReadyListener(onReady)
            resolve()
          } else if (parsed.error) {
            embedder.removeReadyListener(onReady)
            reject(new Error(`MLX embedder failed to start: ${parsed.error}`))
          }
        } catch (err) {
          embedder.removeReadyListener(onReady)
          reject(err instanceof Error ? err : new Error(String(err)))
        }
      }
      embedder.readyListeners.push(onReady)
      child.once('error', reject)
      child.once('close', (code) => {
        if (code !== 0) {
          reject(
            new Error(
              `MLX embedder exited before becoming ready (code ${code ?? 'unknown'}): ${stderrTail.trim()}`,
            ),
          )
        }
      })
    })

    return embedder
  }

  private readyListeners: Array<(line: string) => void> = []

  private removeReadyListener(listener: (line: string) => void): void {
    this.readyListeners = this.readyListeners.filter((l) => l !== listener)
  }

  private handleStdout(chunk: string): void {
    this.buffer += chunk
    let newlineIndex: number
    while ((newlineIndex = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, newlineIndex).trim()
      this.buffer = this.buffer.slice(newlineIndex + 1)
      if (!line) {
        continue
      }

      if (this.readyListeners.length > 0) {
        for (const listener of this.readyListeners) {
          listener(line)
        }
        continue
      }

      this.handleResponse(line)
    }
  }

  private handleResponse(line: string): void {
    const next = this.pending.shift()
    if (!next) {
      return
    }
    try {
      const parsed = JSON.parse(line) as {
        embeddings?: unknown[]
        error?: string
      }
      if (parsed.error) {
        next.reject(new Error(`MLX embedder error: ${parsed.error}`))
        return
      }
      if (!Array.isArray(parsed.embeddings)) {
        next.reject(new Error('MLX embedder returned no embeddings array.'))
        return
      }
      next.resolve(parsed.embeddings)
    } catch (err) {
      next.reject(err instanceof Error ? err : new Error(String(err)))
    }
  }

  private fail(error: Error): void {
    if (!this.exitError) {
      this.exitError = error
    }
    while (this.pending.length > 0) {
      const next = this.pending.shift()
      next?.reject(this.exitError)
    }
  }

  async embed(texts: string[]): Promise<unknown[]> {
    if (this.exitError) {
      throw this.exitError
    }
    return new Promise<unknown[]>((resolve, reject) => {
      this.pending.push({ resolve, reject })
      this.child.stdin.write(JSON.stringify({ texts }) + '\n')
    })
  }

  async stop(): Promise<void> {
    if (this.child.exitCode !== null || this.child.killed) {
      return
    }
    await new Promise<void>((resolve) => {
      this.child.once('close', () => resolve())
      try {
        this.child.stdin.end()
      } catch {
        // ignore
      }
      // Defensive timeout — if the worker hangs, force kill.
      setTimeout(() => {
        if (this.child.exitCode === null && !this.child.killed) {
          this.child.kill('SIGTERM')
        }
      }, 5000).unref()
    })
  }
}

function isNumberArray(value: unknown): value is number[] {
  return (
    Array.isArray(value) &&
    value.every((item) => typeof item === 'number' && Number.isFinite(item))
  )
}

async function runProcess(
  command: string,
  args: string[],
  stdin: string,
  extraEnv: NodeJS.ProcessEnv = {},
): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    const child = spawn(command, args, {
      env: { ...process.env, ...extraEnv },
      stdio: ['pipe', 'pipe', 'pipe'],
    })
    let stdout = ''
    let stderr = ''

    child.stdout.setEncoding('utf8')
    child.stderr.setEncoding('utf8')
    child.stdout.on('data', (chunk) => {
      stdout += chunk
    })
    child.stderr.on('data', (chunk) => {
      stderr += chunk
    })
    child.on('error', reject)
    child.on('close', (code) => {
      if (code === 0) {
        resolve(stdout.trim())
      } else {
        reject(
          new Error(
            `${command} exited with code ${code ?? 'unknown'}: ${stderr.trim()}`,
          ),
        )
      }
    })

    child.stdin.write(stdin)
    child.stdin.end()
  })
}

async function writeChunks(
  pool: pg.Pool,
  options: NormalizedOptions,
  candidate: SourceCandidate,
  chunks: ContentChunk[],
  embeddings: number[][],
): Promise<void> {
  const client = await pool.connect()
  try {
    await client.query('begin')
    for (const chunk of chunks) {
      const embedding = embeddings[chunk.index]
      if (!embedding) {
        throw new Error(`Missing embedding for chunk ${chunk.index}.`)
      }

      await client.query(
        `
          insert into semantic_embeddings (
            target_type,
            target_id,
            chunk_index,
            content,
            content_sha256,
            embedding_provider,
            embedding_model,
            embedding_model_version,
            embedding_dimension,
            embedding,
            metadata,
            archived_at,
            embedded_at
          )
          values (
            $1,
            $2::uuid,
            $3,
            $4,
            $5,
            $6,
            $7,
            $8,
            $9,
            $10::vector,
            $11::jsonb,
            null,
            now()
          )
          on conflict (
            target_type,
            target_id,
            embedding_provider,
            embedding_model,
            embedding_model_version,
            chunk_index
          )
          where archived_at is null
          do update
             set content = excluded.content,
                 content_sha256 = excluded.content_sha256,
                 embedding_dimension = excluded.embedding_dimension,
                 embedding = excluded.embedding,
                 metadata = excluded.metadata,
                 archived_at = null,
                 embedded_at = excluded.embedded_at
        `,
        [
          candidate.target_type,
          candidate.target_id,
          chunk.index,
          chunk.content,
          chunk.hash,
          options.provider,
          options.model,
          options.modelVersion,
          EMBEDDING_DIMENSION,
          vectorLiteral(embedding),
          JSON.stringify({
            title: candidate.title,
            source_updated_at: candidate.updated_at?.toISOString() ?? null,
            backfill_command: 'open-crm-db embeddings backfill',
          }),
        ],
      )
    }
    await client.query('commit')
  } catch (err) {
    await client.query('rollback')
    throw err
  } finally {
    client.release()
  }
}

async function archiveStaleChunks(
  pool: pg.Pool,
  options: NormalizedOptions,
  candidate: SourceCandidate,
  activeChunkCount: number,
): Promise<number> {
  const result = await pool.query(
    `
      update semantic_embeddings
         set archived_at = now()
       where target_type = $1
         and target_id = $2::uuid
         and embedding_provider = $3
         and embedding_model = $4
         and embedding_model_version = $5
         and archived_at is null
         and chunk_index >= $6
    `,
    [
      candidate.target_type,
      candidate.target_id,
      options.provider,
      options.model,
      options.modelVersion,
      activeChunkCount,
    ],
  )
  return result.rowCount ?? 0
}

function vectorLiteral(embedding: number[]): string {
  return `[${embedding.join(',')}]`
}

function describeTargets(targetTypes: TargetType[]): string {
  if (targetTypes.length === TARGET_TYPES.length) {
    return 'all target types'
  }
  return targetTypes.join(', ')
}

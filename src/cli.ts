#!/usr/bin/env node
import { Command } from 'commander'
import { migrateCreate } from './commands/migrate-create.js'
import { migrateDown } from './commands/migrate-down.js'
import { migrateStatus } from './commands/migrate-status.js'
import { migrateUp } from './commands/migrate-up.js'
import { info } from './commands/info.js'
import { enrich, type EnrichOptions } from './commands/enrich.js'
import {
  backfillEmbeddings,
  type BackfillEmbeddingsOptions,
} from './commands/backfill-embeddings.js'
import {
  importLinear,
  type ImportLinearOptions,
} from './commands/import-linear.js'

export function buildProgram(): Command {
  const program = new Command()
  program
    .name('picardo-db')
    .description(
      'Picardo internal database CLI — applies SQL migrations and prints schema/connection guidance.',
    )
    .version('0.1.0')

  const migrate = program
    .command('migrate')
    .description('Manage SQL migrations against the configured DATABASE_URL.')

  migrate
    .command('up')
    .description('Apply all pending migrations.')
    .option('-n, --count <n>', 'Apply at most N pending migrations.', (v) =>
      Number.parseInt(v, 10),
    )
    .action(async (opts: { count?: number }) => {
      await migrateUp(
        opts.count !== undefined && Number.isFinite(opts.count)
          ? { count: opts.count }
          : {},
      )
    })

  migrate
    .command('down')
    .description('Revert the most recent migration (or N most recent).')
    .option('-n, --count <n>', 'Revert N migrations.', (v) =>
      Number.parseInt(v, 10),
    )
    .action(async (opts: { count?: number }) => {
      await migrateDown({
        count:
          opts.count !== undefined && Number.isFinite(opts.count)
            ? opts.count
            : 1,
      })
    })

  migrate
    .command('status')
    .description('Show applied vs pending migrations.')
    .action(async () => {
      await migrateStatus()
    })

  migrate
    .command('create <name>')
    .description('Scaffold a new SQL migration file.')
    .action(async (name: string) => {
      await migrateCreate({ name })
    })

  const embeddings = program
    .command('embeddings')
    .description('Generate and backfill local semantic-search embeddings.')

  embeddings
    .command('backfill')
    .description(
      'Backfill semantic_embeddings from CRM source records using local MLX.',
    )
    .option(
      '--apply',
      'Write embeddings. Defaults to dry-run without calling the embedding model.',
    )
    .option(
      '--batch-size <n>',
      'Embedding request batch size.',
      (v) => Number.parseInt(v, 10),
    )
    .option(
      '--chunk-overlap <n>',
      'Overlapping characters between adjacent chunks.',
      (v) => Number.parseInt(v, 10),
    )
    .option(
      '--chunk-size <n>',
      'Maximum characters per source text chunk.',
      (v) => Number.parseInt(v, 10),
    )
    .option(
      '--credentials-env-path <path>',
      'Path to a local env file containing DATABASE_URL.',
    )
    .option('--force', 'Re-embed records even when active chunk hashes match.')
    .option(
      '--limit <n>',
      'Maximum source records to inspect.',
      (v) => Number.parseInt(v, 10),
    )
    .option(
      '--model <model>',
      'MLX embedding model.',
      'mlx-community/embeddinggemma-300m-4bit',
    )
    .option('--model-version <version>', 'Model version label.', '4bit')
    .option('--provider <provider>', 'Embedding provider label.', 'mlx')
    .option(
      '--target-type <types>',
      'Comma-separated target types to backfill. Defaults to all supported types.',
    )
    .option('--verbose', 'Print one line per stale source record.')
    .action(async (opts: BackfillEmbeddingsOptions) => {
      await backfillEmbeddings(opts)
    })

  program
    .command('info')
    .description('Print connection and schema guidance.')
    .action(() => {
      info()
    })

  program
    .command('enrich')
    .description(
      'Enrich organizations and people from public web sources using Perplexity Sonar.',
    )
    .option(
      '--apply',
      'Write updates, extracted facts, and AI notes. Defaults to dry-run.',
    )
    .option(
      '--entity <entity>',
      'Which entities to enrich: organizations/companies, people/contacts, or both.',
      'both',
    )
    .option(
      '--force',
      'Include rows already marked with prior Perplexity enrichment metadata.',
    )
    .option(
      '--limit <n>',
      'Maximum rows per selected entity type.',
      (v) => Number.parseInt(v, 10),
      10,
    )
    .option(
      '--missing-profile-only',
      'For organizations, only select rows missing the current research profile.',
    )
    .option('--model <model>', 'Perplexity model id.', 'sonar')
    .option(
      '--perplexity-env-path <path>',
      'Path to an env file containing PERPLEXITY_API_KEY.',
    )
    .option(
      '--search-context <size>',
      'Perplexity search context size: low, medium, or high.',
      'low',
    )
    .action(async (opts: EnrichOptions) => {
      await enrich(validateEnrichOptions(opts))
    })

  const linear = program
    .command('linear')
    .description('Import task-management data from Linear.')

  linear
    .command('import')
    .description(
      'Import Linear users, teams, statuses, labels, projects, issues, comments, attachments, and relations.',
    )
    .option(
      '--apply',
      'Write imported records. Defaults to dry-run inventory only.',
    )
    .option(
      '--concurrency <n>',
      'Maximum concurrent Linear MCP detail requests.',
      (v) => Number.parseInt(v, 10),
    )
    .option(
      '--credentials-env-path <path>',
      'Path to a local env file containing DATABASE_URL.',
    )
    .option(
      '--exclude-archived',
      'Do not ask Linear for archived issues/teams.',
    )
    .option(
      '--limit <n>',
      'Maximum Linear issues to inspect/import.',
      (v) => Number.parseInt(v, 10),
    )
    .option(
      '--mcp-url <url>',
      'Linear MCP endpoint.',
      'https://mcp.linear.app/mcp',
    )
    .option('--skip-comments', 'Skip importing Linear comments.')
    .option('--skip-relations', 'Skip importing Linear issue relations.')
    .option('--verbose', 'Print Linear MCP progress and proxy logs.')
    .action(async (opts: ImportLinearOptions & { excludeArchived?: boolean }) => {
      await importLinear({
        ...opts,
        includeArchived: opts.excludeArchived ? false : undefined,
      })
    })

  return program
}

function validateEnrichOptions(opts: EnrichOptions): EnrichOptions {
  const entity = normalizeEntityOption(opts.entity ?? 'both')
  if (!entity) {
    throw new Error(
      '--entity must be one of: organizations, companies, people, contacts, both.',
    )
  }

  const searchContext = opts.searchContext ?? 'low'
  if (!['low', 'medium', 'high'].includes(searchContext)) {
    throw new Error('--search-context must be one of: low, medium, high.')
  }

  return {
    ...opts,
    entity,
    searchContext,
  }
}

function normalizeEntityOption(
  entity: EnrichOptions['entity'],
): 'organizations' | 'people' | 'both' | null {
  if (entity === 'companies') {
    return 'organizations'
  }
  if (entity === 'contacts') {
    return 'people'
  }
  if (entity === 'organizations' || entity === 'people' || entity === 'both') {
    return entity
  }
  return null
}

async function main(): Promise<void> {
  const program = buildProgram()
  try {
    await program.parseAsync(process.argv)
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    console.error(`picardo-db: ${message}`)
    process.exitCode = 1
  }
}

// Only run when invoked directly. When imported in tests we use buildProgram().
const invokedDirectly =
  process.argv[1] !== undefined &&
  /\/(cli|picardo-db)(\.[mc]?[jt]s)?$/.test(process.argv[1])

if (invokedDirectly) {
  void main()
}

#!/usr/bin/env node
import { Command } from 'commander'
import { migrateCreate } from './commands/migrate-create.js'
import { migrateDown } from './commands/migrate-down.js'
import { migrateStatus } from './commands/migrate-status.js'
import { migrateUp } from './commands/migrate-up.js'
import { info } from './commands/info.js'
import {
  backfillEmbeddings,
  type BackfillEmbeddingsOptions,
} from './commands/backfill-embeddings.js'

export function buildProgram(): Command {
  const program = new Command()
  program
    .name('open-crm-db')
    .description(
      'open-crm-db CLI — applies SQL migrations and prints schema/connection guidance for a generic headless CRM Postgres database.',
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

  return program
}

async function main(): Promise<void> {
  const program = buildProgram()
  try {
    await program.parseAsync(process.argv)
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    console.error(`open-crm-db: ${message}`)
    process.exitCode = 1
  }
}

// Only run when invoked directly. When imported in tests we use buildProgram().
const invokedDirectly =
  process.argv[1] !== undefined &&
  /\/(cli|open-crm-db)(\.[mc]?[jt]s)?$/.test(process.argv[1])

if (invokedDirectly) {
  void main()
}

#!/usr/bin/env node
import { Command } from 'commander'
import { migrateCreate } from './commands/migrate-create.js'
import { migrateDown } from './commands/migrate-down.js'
import { migrateStatus } from './commands/migrate-status.js'
import { migrateUp } from './commands/migrate-up.js'
import { info } from './commands/info.js'

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
    .option(
      '-n, --count <n>',
      'Apply at most N pending migrations.',
      (v) => Number.parseInt(v, 10),
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

import { loadConfig } from '../config.js'
import {
  diffMigrations,
  fetchAppliedMigrations,
  listMigrationFiles,
} from '../migrations.js'

export async function migrateStatus(): Promise<void> {
  const config = loadConfig()
  const [files, applied] = await Promise.all([
    listMigrationFiles(config.migrationsDir),
    fetchAppliedMigrations({
      databaseUrl: config.databaseUrl,
      migrationsTable: config.migrationsTable,
      migrationsSchema: config.migrationsSchema,
    }),
  ])

  const status = diffMigrations(files, applied)
  const total = files.length

  console.log(`Migrations directory : ${config.migrationsDir}`)
  console.log(
    `Tracking table        : ${config.migrationsSchema}.${config.migrationsTable}`,
  )
  console.log(
    `On disk: ${total}    applied: ${status.applied.length}    pending: ${status.pending.length}    orphaned: ${status.orphaned.length}`,
  )
  console.log('')

  if (status.applied.length > 0) {
    console.log('Applied:')
    for (const m of status.applied) {
      const ts = m.runOn ? m.runOn.toISOString() : 'unknown time'
      console.log(`  [x] ${m.name}    (${ts})`)
    }
    console.log('')
  }

  if (status.pending.length > 0) {
    console.log('Pending:')
    for (const m of status.pending) {
      console.log(`  [ ] ${m.name}`)
    }
    console.log('')
  }

  if (status.orphaned.length > 0) {
    console.log('Orphaned (in DB but not on disk):')
    for (const m of status.orphaned) {
      console.log(`  [?] ${m.name}`)
    }
    console.log('')
  }

  if (status.pending.length === 0 && status.orphaned.length === 0) {
    console.log('Database is up to date.')
  }
}

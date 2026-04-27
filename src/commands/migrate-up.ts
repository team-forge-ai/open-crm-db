import { loadConfig } from '../config.js'
import { runMigrations } from '../runner.js'

export interface MigrateUpOptions {
  count?: number
}

export async function migrateUp(options: MigrateUpOptions = {}): Promise<void> {
  const config = loadConfig()
  await runMigrations({
    config,
    direction: 'up',
    ...(options.count !== undefined ? { count: options.count } : {}),
  })
}

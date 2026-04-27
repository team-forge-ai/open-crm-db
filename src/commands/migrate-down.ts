import { loadConfig } from '../config.js'
import { runMigrations } from '../runner.js'

export interface MigrateDownOptions {
  count?: number
}

export async function migrateDown(
  options: MigrateDownOptions = {},
): Promise<void> {
  const config = loadConfig()
  await runMigrations({
    config,
    direction: 'down',
    count: options.count ?? 1,
  })
}

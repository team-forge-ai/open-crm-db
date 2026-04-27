import runner from 'node-pg-migrate'
import type { PicardoDbConfig } from './config.js'
import { dumpSchema } from './schema-dump.js'

/**
 * Thin wrapper around node-pg-migrate's programmatic runner. Centralizing the
 * options here means the CLI commands stay tiny and we can swap libraries
 * later without scattering the config.
 */
export async function runMigrations(params: {
  config: PicardoDbConfig
  direction: 'up' | 'down'
  /** How many migrations to run. Defaults: up = all, down = 1. */
  count?: number
}): Promise<void> {
  await runner({
    databaseUrl: params.config.databaseUrl,
    dir: params.config.migrationsDir,
    direction: params.direction,
    migrationsTable: params.config.migrationsTable,
    schema: params.config.migrationsSchema,
    migrationsSchema: params.config.migrationsSchema,
    singleTransaction: false,
    count: params.count,
    verbose: true,
  })

  const target = await dumpSchema({
    databaseUrl: params.config.databaseUrl,
    outputPath: params.config.schemaDumpPath,
  })
  console.log(`Schema dumped to ${target}`)
}

import path from 'node:path'
import { loadPaths } from '../config.js'
import { createMigration } from '../migrations.js'

export interface MigrateCreateOptions {
  name: string
}

export async function migrateCreate(
  options: MigrateCreateOptions,
): Promise<string> {
  const paths = loadPaths()
  const target = await createMigration({
    migrationsDir: paths.migrationsDir,
    templatePath: paths.migrationTemplate,
    name: options.name,
  })
  console.log(`Created migration: ${path.relative(process.cwd(), target)}`)
  return target
}

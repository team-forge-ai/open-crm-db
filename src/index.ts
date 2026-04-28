// Public library surface. Most users should drive the CLI; these exports are
// here for tests and for any internal tool that wants to reuse the helpers.
export {
  loadConfig,
  loadPaths,
  findRepoRoot,
  type OpenCrmDbConfig,
  type ConfigOptions,
} from './config.js'

export {
  buildMigrationFilename,
  createMigration,
  diffMigrations,
  fetchAppliedMigrations,
  listMigrationFiles,
  parseMigrationFilename,
  readMigrationTemplate,
  slugifyMigrationName,
  type AppliedMigration,
  type MigrationFile,
  type MigrationStatus,
} from './migrations.js'

export { runMigrations } from './runner.js'
export {
  buildPgDumpConnectionEnv,
  dumpSchema,
  filterSchemaDump,
  type PgDumpConnectionEnv,
  type SchemaDumpOptions,
} from './schema-dump.js'
export { buildProgram } from './cli.js'

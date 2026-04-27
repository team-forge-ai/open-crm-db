import { execFile } from 'node:child_process'
import fs from 'node:fs/promises'
import path from 'node:path'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)

export interface SchemaDumpOptions {
  databaseUrl: string
  outputPath: string
}

export interface PgDumpConnectionEnv {
  PGDATABASE?: string
  PGHOST?: string
  PGPASSWORD?: string
  PGPORT?: string
  PGSSLMODE?: string
  PGUSER?: string
}

export async function dumpSchema(options: SchemaDumpOptions): Promise<string> {
  await fs.mkdir(path.dirname(options.outputPath), { recursive: true })

  const { DATABASE_URL: _databaseUrl, ...baseEnv } = process.env
  let stdout: string
  try {
    const result = await execFileAsync('pg_dump', ['-s', '-O', '-x'], {
      env: {
        ...baseEnv,
        ...buildPgDumpConnectionEnv(options.databaseUrl),
      },
      maxBuffer: 50 * 1024 * 1024,
    })
    stdout = result.stdout
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    throw new Error(`Failed to dump schema with pg_dump: ${message}`, {
      cause: err,
    })
  }

  await fs.writeFile(options.outputPath, filterSchemaDump(stdout))
  return options.outputPath
}

export function filterSchemaDump(sql: string): string {
  const lines = sql.split('\n').filter((line) => {
    return (
      !line.startsWith('SET ') &&
      !line.includes('set_config') &&
      !line.startsWith('\\restrict') &&
      !line.startsWith('\\unrestrict')
    )
  })

  return `${lines.join('\n').trimEnd()}\n`
}

export function buildPgDumpConnectionEnv(
  databaseUrl: string,
): PgDumpConnectionEnv {
  const parsed = new URL(databaseUrl)
  const database = parsed.pathname.replace(/^\//, '')
  const sslMode = parsed.searchParams.get('sslmode')

  return {
    ...(database ? { PGDATABASE: decode(database) } : {}),
    ...(parsed.hostname ? { PGHOST: parsed.hostname } : {}),
    ...(parsed.password ? { PGPASSWORD: decode(parsed.password) } : {}),
    ...(parsed.port ? { PGPORT: parsed.port } : {}),
    ...(sslMode ? { PGSSLMODE: sslMode } : {}),
    ...(parsed.username ? { PGUSER: decode(parsed.username) } : {}),
  }
}

function decode(value: string): string {
  try {
    return decodeURIComponent(value)
  } catch {
    return value
  }
}

import fs from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  buildMigrationFilename,
  createMigration,
  diffMigrations,
  listMigrationFiles,
  parseMigrationFilename,
  readMigrationTemplate,
  slugifyMigrationName,
} from '../migrations.js'

describe('slugifyMigrationName', () => {
  it('lowercases, strips punctuation and collapses spaces to hyphens', () => {
    expect(slugifyMigrationName('Add People Table!')).toBe('add-people-table')
    expect(slugifyMigrationName("Don't break")).toBe('dont-break')
    expect(slugifyMigrationName('  multi   space  ')).toBe('multi-space')
  })

  it('throws for empty results', () => {
    expect(() => slugifyMigrationName('!!!')).toThrow(/empty slug/)
  })
})

describe('buildMigrationFilename', () => {
  it('produces <ts>_<slug>.sql', () => {
    const fixed = new Date('2026-04-27T00:00:00Z')
    const filename = buildMigrationFilename('Add People Table', fixed)
    expect(filename).toBe(`${fixed.getTime()}_add-people-table.sql`)
  })
})

describe('parseMigrationFilename', () => {
  it('parses well-formed filenames', () => {
    const parsed = parseMigrationFilename('1700000000000_initial-schema.sql')
    expect(parsed).not.toBeNull()
    expect(parsed!.timestamp).toBe(1_700_000_000_000)
    expect(parsed!.slug).toBe('initial-schema')
    expect(parsed!.name).toBe('1700000000000_initial-schema')
  })

  it('returns null for non-matching files (READMEs etc.)', () => {
    expect(parseMigrationFilename('README.md')).toBeNull()
    expect(parseMigrationFilename('garbage.sql')).toBeNull()
    expect(parseMigrationFilename('123_Bad_Slug.sql')).toBeNull()
  })
})

describe('listMigrationFiles', () => {
  it('returns [] for missing directories', async () => {
    const files = await listMigrationFiles(
      path.join(os.tmpdir(), `open-crm-db-not-here-${Date.now()}`),
    )
    expect(files).toEqual([])
  })

  it('returns sorted parsed migrations from a real directory', async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'open-crm-db-list-'))
    await fs.writeFile(path.join(dir, 'README.md'), '# ignore me')
    await fs.writeFile(path.join(dir, '200_b-second.sql'), '-- Up Migration')
    await fs.writeFile(path.join(dir, '100_a-first.sql'), '-- Up Migration')
    const files = await listMigrationFiles(dir)
    expect(files.map((f) => f.name)).toEqual(['100_a-first', '200_b-second'])
  })
})

describe('diffMigrations', () => {
  it('classifies pending/applied/orphaned correctly', () => {
    const files = [
      { filename: '1_a.sql', timestamp: 1, slug: 'a', name: '1_a' },
      { filename: '2_b.sql', timestamp: 2, slug: 'b', name: '2_b' },
      { filename: '3_c.sql', timestamp: 3, slug: 'c', name: '3_c' },
    ]
    const applied = [
      { name: '1_a', runOn: new Date('2026-01-01') },
      { name: '2_b', runOn: new Date('2026-01-02') },
      { name: '99_orphan', runOn: new Date('2026-01-03') },
    ]
    const status = diffMigrations(files, applied)
    expect(status.applied.map((a) => a.name)).toEqual(['1_a', '2_b'])
    expect(status.pending.map((p) => p.name)).toEqual(['3_c'])
    expect(status.orphaned.map((o) => o.name)).toEqual(['99_orphan'])
  })
})

describe('readMigrationTemplate', () => {
  it('reads a real template file', async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'open-crm-db-tpl-'))
    const tpl = path.join(dir, 'migration.sql')
    await fs.writeFile(tpl, '-- Custom Up\n-- Custom Down\n')
    expect(await readMigrationTemplate(tpl)).toContain('Custom Up')
  })

  it('falls back to a default for missing templates', async () => {
    const tpl = path.join(os.tmpdir(), `open-crm-db-tpl-missing-${Date.now()}.sql`)
    expect(await readMigrationTemplate(tpl)).toContain('-- Up Migration')
  })
})

describe('createMigration', () => {
  let workdir: string
  beforeEach(async () => {
    workdir = await fs.mkdtemp(path.join(os.tmpdir(), 'open-crm-db-create-'))
  })
  afterEach(async () => {
    await fs.rm(workdir, { recursive: true, force: true })
  })

  it('creates a timestamped SQL file from the template', async () => {
    const template = path.join(workdir, 'migration.sql')
    await fs.writeFile(template, '-- Up Migration\n-- Down Migration\n')

    const target = await createMigration({
      migrationsDir: path.join(workdir, 'migrations'),
      templatePath: template,
      name: 'Add cool table',
      now: new Date('2026-04-27T00:00:00Z'),
    })

    expect(target.endsWith('_add-cool-table.sql')).toBe(true)
    const content = await fs.readFile(target, 'utf8')
    expect(content).toContain('-- Up Migration')
    expect(content).toContain('-- Down Migration')
  })

  it('refuses to overwrite an existing file with the same name', async () => {
    const template = path.join(workdir, 'migration.sql')
    await fs.writeFile(template, '-- Up Migration\n')

    const fixed = new Date('2026-04-27T00:00:00Z')
    await createMigration({
      migrationsDir: path.join(workdir, 'migrations'),
      templatePath: template,
      name: 'same name',
      now: fixed,
    })
    await expect(
      createMigration({
        migrationsDir: path.join(workdir, 'migrations'),
        templatePath: template,
        name: 'same name',
        now: fixed,
      }),
    ).rejects.toThrow()
  })
})

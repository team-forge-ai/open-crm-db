import { describe, expect, it } from 'vitest'
import { buildPgDumpConnectionEnv, filterSchemaDump } from '../schema-dump.js'

describe('filterSchemaDump', () => {
  it('removes noisy pg_dump session lines while keeping schema content', () => {
    const sql = [
      '-- Dumped by pg_dump version 18.3',
      'SET statement_timeout = 0;',
      "SELECT pg_catalog.set_config('search_path', '', false);",
      '\\restrict abc123',
      'CREATE TABLE public.people (id uuid PRIMARY KEY);',
      '\\unrestrict abc123',
      '',
    ].join('\n')

    expect(filterSchemaDump(sql)).toBe(
      [
        '-- Dumped by pg_dump version 18.3',
        'CREATE TABLE public.people (id uuid PRIMARY KEY);',
        '',
      ].join('\n'),
    )
  })
})

describe('buildPgDumpConnectionEnv', () => {
  it('maps a postgres URL into pg_dump environment variables', () => {
    expect(
      buildPgDumpConnectionEnv(
        'postgres://user:p%40ss@example.com:5433/picardo?sslmode=require',
      ),
    ).toEqual({
      PGDATABASE: 'picardo',
      PGHOST: 'example.com',
      PGPASSWORD: 'p@ss',
      PGPORT: '5433',
      PGSSLMODE: 'require',
      PGUSER: 'user',
    })
  })

  it('allows local URLs to fall back to the current OS user', () => {
    expect(buildPgDumpConnectionEnv('postgres://localhost/picardo')).toEqual({
      PGDATABASE: 'picardo',
      PGHOST: 'localhost',
    })
  })
})

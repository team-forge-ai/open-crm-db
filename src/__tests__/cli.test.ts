import { describe, expect, it } from 'vitest'
import { buildProgram } from '../cli.js'

describe('buildProgram', () => {
  it('exposes all expected commands', () => {
    const program = buildProgram()
    const top = program.commands.map((c) => c.name())
    expect(top).toEqual(
      expect.arrayContaining([
        'migrate',
        'embeddings',
        'linear',
        'info',
        'enrich',
      ]),
    )

    const migrate = program.commands.find((c) => c.name() === 'migrate')!
    const sub = migrate.commands.map((c) => c.name())
    expect(sub).toEqual(
      expect.arrayContaining(['up', 'down', 'status', 'create']),
    )

    const embeddings = program.commands.find((c) => c.name() === 'embeddings')!
    const embeddingSub = embeddings.commands.map((c) => c.name())
    expect(embeddingSub).toEqual(expect.arrayContaining(['backfill']))

    const linear = program.commands.find((c) => c.name() === 'linear')!
    const linearSub = linear.commands.map((c) => c.name())
    expect(linearSub).toEqual(expect.arrayContaining(['import']))
  })

  it('emits help text that mentions the binary name', () => {
    const program = buildProgram()
    const help = program.helpInformation()
    expect(help).toContain('picardo-db')
    expect(help).toContain('migrate')
    expect(help).toContain('embeddings')
    expect(help).toContain('linear')
    expect(help).toContain('info')
    expect(help).toContain('enrich')
  })
})

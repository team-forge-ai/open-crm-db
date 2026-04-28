import { describe, expect, it } from 'vitest'
import {
  normalizeWebDomain,
  validateOrganizationIdentity,
} from '../commands/enrich.js'

const baseEnrichment = {
  canonicalName: 'Picardo',
  website: 'https://picardo.health',
  domain: 'picardo.health',
  oneLineDescription: 'Picardo is a healthcare AI company.',
  category: 'other' as const,
  healthcareRelevance: 'Relevant to healthcare AI.',
  partnershipFit: 'medium' as const,
  partnershipFitRationale: 'Relevant internal healthcare platform.',
  offerings: ['AI primary care'],
  likelyUseCasesForPicardo: ['Internal profile'],
  integrationSignals: [],
  complianceSignals: [],
  keyPublicPeople: [],
  suggestedTags: [],
  reviewFlags: [],
  facts: [
    {
      key: 'primary_domain',
      valueText: 'picardo.health',
      confidence: 1,
      sourceUrl: 'https://picardo.health',
      sourceExcerpt: 'Picardo',
    },
  ],
}

describe('normalizeWebDomain', () => {
  it('normalizes URLs and bare domains', () => {
    expect(normalizeWebDomain('https://www.Picardo.health/about')).toBe(
      'picardo.health',
    )
    expect(normalizeWebDomain('picardo.health')).toBe('picardo.health')
  })
})

describe('validateOrganizationIdentity', () => {
  it('accepts matching returned domains', () => {
    expect(
      validateOrganizationIdentity(
        { domain: 'picardo.health', website: 'https://picardo.health' },
        baseEnrichment,
      ),
    ).toEqual({ valid: true })
  })

  it('rejects a returned profile for a different company domain', () => {
    const result = validateOrganizationIdentity(
      { domain: 'picardo.health', website: 'https://picardo.health' },
      {
        ...baseEnrichment,
        canonicalName: 'Workstreet',
        website: 'https://www.workstreet.com',
        domain: 'workstreet.com',
        facts: [
          {
            key: 'founded_year',
            valueText: '2019',
            confidence: 1,
            sourceUrl: 'https://www.cbinsights.com/company/workstreet',
            sourceExcerpt: 'Workstreet was founded in 2019.',
          },
        ],
      },
    )

    expect(result.valid).toBe(false)
    expect(result).toMatchObject({
      reason: expect.stringContaining('workstreet.com'),
    })
  })

  it('accepts source-url matches when returned domain fields are null', () => {
    expect(
      validateOrganizationIdentity(
        { domain: 'picardo.health', website: 'https://picardo.health' },
        {
          ...baseEnrichment,
          website: null,
          domain: null,
        },
      ),
    ).toEqual({ valid: true })
  })

  it('allows sparse unknown profiles without sources', () => {
    expect(
      validateOrganizationIdentity(
        { domain: 'unknown.example', website: 'https://unknown.example' },
        {
          ...baseEnrichment,
          canonicalName: null,
          website: null,
          domain: null,
          oneLineDescription: null,
          category: null,
          healthcareRelevance: null,
          partnershipFit: 'unknown',
          partnershipFitRationale: null,
          offerings: [],
          likelyUseCasesForPicardo: [],
          integrationSignals: [],
          complianceSignals: [],
          keyPublicPeople: [],
          suggestedTags: [],
          reviewFlags: ['No public sources found.'],
          facts: [],
        },
      ),
    ).toEqual({ valid: true })
  })
})

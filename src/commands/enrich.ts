import { homedir } from 'node:os'
import path from 'node:path'
import { createPerplexity } from '@ai-sdk/perplexity'
import { generateObject } from 'ai'
import dotenv from 'dotenv'
import pg, { type PoolClient } from 'pg'
import { z } from 'zod'
import { findRepoRoot, loadConfig } from '../config.js'

const PROMPT_FINGERPRINT = 'perplexity-crm-enrichment-v2'
const DEFAULT_MODEL = 'sonar'

const organizationCategories = [
  'provider_network',
  'genomics',
  'lab',
  'imaging',
  'hospital_system',
  'research_institution',
  'payer',
  'health_share',
  'pharmacy',
  'supplement',
  'ai_infrastructure',
  'data_provider',
  'other',
] as const

const partnershipFitLevels = [
  'low',
  'medium',
  'high',
  'strategic',
  'unknown',
] as const

type EntitySelection = 'organizations' | 'people' | 'both'
type EntityOption = EntitySelection | 'companies' | 'contacts'
type SearchContextSize = 'low' | 'medium' | 'high'

export interface EnrichOptions {
  apply?: boolean
  entity?: EntityOption
  force?: boolean
  limit?: number
  missingProfileOnly?: boolean
  model?: string
  perplexityEnvPath?: string
  searchContext?: SearchContextSize
}

interface OrganizationCandidate {
  id: string
  name: string
  domain: string | null
  website: string | null
  description: string | null
  industry: string | null
  hq_city: string | null
  hq_region: string | null
  hq_country: string | null
  people: string[]
}

interface PersonCandidate {
  id: string
  full_name: string
  headline: string | null
  summary: string | null
  city: string | null
  region: string | null
  country: string | null
  linkedin_url: string | null
  website: string | null
  primary_email_domain: string | null
  affiliations: Array<{
    organizationName: string
    organizationDomain: string | null
    title: string | null
  }>
}

interface EnrichmentContext {
  pool: pg.Pool
  apply: boolean
  modelId: string
  sourceId: string | null
  searchContext: SearchContextSize
}

interface FactInput {
  key: string
  valueText: string
  confidence: number | null
  sourceUrl: string | null
  sourceExcerpt: string | null
}

const factSchema = z.object({
  key: z.string().min(1),
  valueText: z.string().min(1),
  confidence: z.number().min(0).max(1).nullable().optional(),
  sourceUrl: z.string().nullable().optional(),
  sourceExcerpt: z.string().nullable().optional(),
})

const organizationSchema = z.object({
  canonicalName: z.string().nullable(),
  website: z.string().nullable(),
  domain: z.string().nullable(),
  oneLineDescription: z.string().nullable(),
  category: z.enum(organizationCategories).nullable(),
  healthcareRelevance: z.string().nullable(),
  partnershipFit: z.enum(partnershipFitLevels).nullable(),
  partnershipFitRationale: z.string().nullable(),
  offerings: z.array(z.string().min(1)).max(12).default([]),
  likelyUseCasesForPicardo: z.array(z.string().min(1)).max(8).default([]),
  integrationSignals: z.array(z.string().min(1)).max(8).default([]),
  complianceSignals: z.array(z.string().min(1)).max(8).default([]),
  keyPublicPeople: z
    .array(
      z.object({
        name: z.string().min(1),
        title: z.string().nullable().optional(),
        sourceUrl: z.string().nullable().optional(),
        confidence: z.number().min(0).max(1).nullable().optional(),
      }),
    )
    .max(8)
    .default([]),
  suggestedTags: z.array(z.string().min(1)).max(8).default([]),
  reviewFlags: z.array(z.string().min(1)).max(8).default([]),
  facts: z.array(factSchema).max(10).default([]),
})

const personSchema = z.object({
  headline: z.string().nullable().optional(),
  summary: z.string().nullable().optional(),
  linkedinUrl: z.string().nullable().optional(),
  website: z.string().nullable().optional(),
  city: z.string().nullable().optional(),
  region: z.string().nullable().optional(),
  country: z.string().nullable().optional(),
  currentTitle: z.string().nullable().optional(),
  currentOrganization: z.string().nullable().optional(),
  summaryNote: z.string().nullable().optional(),
  facts: z.array(factSchema).max(10).default([]),
})

type OrganizationEnrichment = z.infer<typeof organizationSchema>
type PersonEnrichment = z.infer<typeof personSchema>

export async function enrich(options: EnrichOptions = {}): Promise<void> {
  const repoRoot = findRepoRoot()
  loadEnvironment(repoRoot, options.perplexityEnvPath)

  const databaseUrl = loadConfig({ skipDotenv: true }).databaseUrl
  const apiKey = getPerplexityApiKey()
  const modelId = options.model ?? DEFAULT_MODEL
  const limit = positiveInteger(options.limit, 10)
  const entity = normalizeEntitySelection(options.entity ?? 'both')
  const searchContext = options.searchContext ?? 'low'
  const apply = Boolean(options.apply)

  const pool = new pg.Pool({ connectionString: databaseUrl })

  try {
    const sourceId = apply ? await ensurePerplexitySource(pool) : null
    const ctx: EnrichmentContext = {
      pool,
      apply,
      modelId,
      sourceId,
      searchContext,
    }

    console.log(
      `${apply ? 'Applying' : 'Dry run:'} Perplexity enrichment with ${modelId} (${searchContext} search context).`,
    )

    if (entity === 'organizations' || entity === 'both') {
      await enrichOrganizations(ctx, {
        apiKey,
        limit,
        force: Boolean(options.force),
        missingProfileOnly: Boolean(options.missingProfileOnly),
      })
    }

    if (entity === 'people' || entity === 'both') {
      await enrichPeople(ctx, apiKey, limit, Boolean(options.force))
    }
  } finally {
    await pool.end()
  }
}

function loadEnvironment(repoRoot: string, perplexityEnvPath?: string): void {
  dotenv.config({ path: path.join(repoRoot, '.env'), override: false })

  if (!process.env.DATABASE_URL) {
    const credentialPaths = [
      path.join(
        repoRoot,
        'skills',
        'picardo-internal-db',
        'references',
        'credentials.env',
      ),
      path.join(
        homedir(),
        '.codex',
        'skills',
        'picardo-internal-db',
        'references',
        'credentials.env',
      ),
      path.join(
        homedir(),
        '.agents',
        'skills',
        'picardo-internal-db',
        'references',
        'credentials.env',
      ),
    ]

    for (const credentialPath of credentialPaths) {
      dotenv.config({ path: credentialPath, override: false })
      if (process.env.DATABASE_URL) {
        break
      }
    }
  }

  dotenv.config({
    path:
      perplexityEnvPath ??
      path.join(homedir(), 'repos', 'cursor-agent', '.env'),
    override: false,
  })

  if (!process.env.PERPLEXITY_API_KEY && process.env.PPLX_API_KEY) {
    process.env.PERPLEXITY_API_KEY = process.env.PPLX_API_KEY
  }
}

function getPerplexityApiKey(): string {
  const apiKey = process.env.PERPLEXITY_API_KEY
  if (!apiKey) {
    throw new Error(
      'PERPLEXITY_API_KEY is not set. Set it in the environment or in ~/repos/cursor-agent/.env.',
    )
  }
  return apiKey
}

function normalizeEntitySelection(entity: EntityOption): EntitySelection {
  if (entity === 'companies') {
    return 'organizations'
  }
  if (entity === 'contacts') {
    return 'people'
  }
  return entity
}

async function enrichOrganizations(
  ctx: EnrichmentContext,
  options: {
    apiKey: string
    limit: number
    force: boolean
    missingProfileOnly: boolean
  },
): Promise<void> {
  const candidates = await fetchOrganizationCandidates(ctx.pool, {
    limit: options.limit,
    force: options.force,
    missingProfileOnly: options.missingProfileOnly,
  })
  console.log(`Found ${candidates.length} organization candidate(s).`)

  for (const candidate of candidates) {
    try {
      const enrichment = await generateOrganizationEnrichment(
        options.apiKey,
        ctx.modelId,
        ctx.searchContext,
        candidate,
      )
      const updates = organizationUpdates(candidate, enrichment)
      const facts = normalizeFacts(enrichment.facts)

      console.log(
        `${ctx.apply ? 'Applying' : 'Would enrich'} organization ${candidate.name}: ${describeOrganizationChanges(
          enrichment,
          updates,
          facts,
        )}`,
      )

      if (ctx.apply) {
        await writeOrganizationEnrichment(
          ctx,
          candidate,
          enrichment,
          updates,
          facts,
        )
      }
    } catch (err) {
      console.error(
        `Skipping organization ${candidate.name}: ${errorMessage(err)}`,
      )
    }
  }
}

async function enrichPeople(
  ctx: EnrichmentContext,
  apiKey: string,
  limit: number,
  force: boolean,
): Promise<void> {
  const candidates = await fetchPersonCandidates(ctx.pool, limit, force)
  console.log(`Found ${candidates.length} person candidate(s).`)

  for (const candidate of candidates) {
    const enrichment = await generatePersonEnrichment(
      apiKey,
      ctx.modelId,
      ctx.searchContext,
      candidate,
    )
    const updates = personUpdates(candidate, enrichment)
    const facts = normalizeFacts(enrichment.facts)

    console.log(
      `${ctx.apply ? 'Applying' : 'Would enrich'} person ${candidate.full_name}: ${describeChanges(
        updates,
        facts,
      )}`,
    )

    if (ctx.apply) {
      await writePersonEnrichment(ctx, candidate, enrichment, updates, facts)
    }
  }
}

async function generateOrganizationEnrichment(
  apiKey: string,
  modelId: string,
  searchContext: SearchContextSize,
  candidate: OrganizationCandidate,
): Promise<OrganizationEnrichment> {
  const model = createPerplexity({ apiKey })(modelId)
  const result = await generateObject({
    model,
    schema: organizationSchema,
    temperature: 0,
    maxOutputTokens: 1200,
    experimental_repairText: async ({ text }) => extractJsonObjectText(text),
    providerOptions: {
      perplexity: {
        web_search_options: {
          search_context_size: searchContext,
        },
      },
    },
    system: publicResearchSystemPrompt(),
    prompt: `Enrich this CRM organization using current public web sources.

Return null for any field that is not clearly supported by public sources.
Do not infer sensitive, private, or medical information.
Prefer the organization's official website and credible company profile pages.
Focus on CRM intelligence for Picardo, a healthcare company evaluating partnerships, services, integrations, and relationship context.
If an official domain or website is provided, use it as the primary disambiguation clue.
For established public organizations, make a best effort to populate the core profile fields instead of returning an empty profile; record uncertainty in reviewFlags.
Do not include bracket citation markers like [1] in text fields. Put URLs in sourceUrl fields instead.

Return:
- canonicalName: the public canonical name.
- website/domain: official public web presence.
- oneLineDescription: one concise factual sentence.
- category: one of ${organizationCategories.join(', ')}.
- healthcareRelevance: why this organization matters in healthcare or why it likely does not.
- partnershipFit: one of ${partnershipFitLevels.join(', ')}.
- partnershipFitRationale: concise reason for the fit rating.
- offerings: public products/services/capabilities.
- likelyUseCasesForPicardo: plausible partnership or CRM use cases, only if supported by public facts.
- integrationSignals: public API, EHR, FHIR, SFTP, portal, webhook, data, or implementation clues.
- complianceSignals: HIPAA, SOC 2, HITRUST, CLIA, CAP, BAA, privacy, security, or similar public signals.
- keyPublicPeople: only notable public people relevant to a partnership or account motion.
- suggestedTags: short CRM tags like hospital_system, genomics, api_available, compliance_review.
- reviewFlags: uncertainties, ambiguity, stale-looking data, or human-review concerns.
- facts: durable, source-backed facts not already obvious from the top-level fields.

Existing CRM data:
${JSON.stringify(
  {
    name: candidate.name,
    domain: candidate.domain,
    website: candidate.website,
    description: candidate.description,
    industry: candidate.industry,
    headquarters: {
      city: candidate.hq_city,
      region: candidate.hq_region,
      country: candidate.hq_country,
    },
    knownPeople: candidate.people.slice(0, 8),
  },
  null,
  2,
)}`,
  })

  printUsage(candidate.name, result.response.modelId, result.usage)
  return result.object
}

async function generatePersonEnrichment(
  apiKey: string,
  modelId: string,
  searchContext: SearchContextSize,
  candidate: PersonCandidate,
): Promise<PersonEnrichment> {
  const model = createPerplexity({ apiKey })(modelId)
  const result = await generateObject({
    model,
    schema: personSchema,
    temperature: 0,
    maxOutputTokens: 1200,
    experimental_repairText: async ({ text }) => extractJsonObjectText(text),
    providerOptions: {
      perplexity: {
        web_search_options: {
          search_context_size: searchContext,
        },
      },
    },
    system: publicResearchSystemPrompt(),
    prompt: `Enrich this CRM contact using current public web sources.

Return null for any field that is not clearly supported by public sources.
Do not infer sensitive, private, or medical information.
Do not search for or return private contact details. Use the email domain only as a disambiguator.

Existing CRM data:
${JSON.stringify(
  {
    fullName: candidate.full_name,
    headline: candidate.headline,
    summary: candidate.summary,
    location: {
      city: candidate.city,
      region: candidate.region,
      country: candidate.country,
    },
    linkedinUrl: candidate.linkedin_url,
    website: candidate.website,
    primaryEmailDomain: candidate.primary_email_domain,
    affiliations: candidate.affiliations,
  },
  null,
  2,
)}`,
  })

  printUsage(candidate.full_name, result.response.modelId, result.usage)
  return result.object
}

function publicResearchSystemPrompt(): string {
  return `You enrich a headless CRM from public sources.
Return only fields supported by public evidence.
Avoid speculation. If sources conflict, use the most authoritative source or return null.
Keep summaries concise and factual.
Facts must have stable snake_case keys, a short valueText, confidence from 0 to 1, and sourceUrl/sourceExcerpt when available.`
}

async function fetchOrganizationCandidates(
  pool: pg.Pool,
  options: { limit: number; force: boolean; missingProfileOnly: boolean },
): Promise<OrganizationCandidate[]> {
  const result = await pool.query<OrganizationCandidate>(
    `
      select
        o.id::text,
        o.name,
        o.domain::text,
        o.website,
        o.description,
        o.industry,
        o.hq_city,
        o.hq_region,
        o.hq_country,
        coalesce(
          jsonb_agg(distinct p.full_name) filter (where p.id is not null),
          '[]'::jsonb
        ) as people
      from organizations o
      left join affiliations a on a.organization_id = o.id and a.is_current
      left join people p on p.id = a.person_id and p.archived_at is null
      where o.archived_at is null
        and (
          (
            not exists (
              select 1
                from organization_research_profiles orp
               where orp.organization_id = o.id
                 and orp.prompt_fingerprint = $3
            )
          )
          or (
            not $4::boolean
            and (
              $2::boolean
              or o.description is null
              or o.industry is null
              or o.website is null
            )
          )
        )
        and (
          not $4::boolean
          or not exists (
            select 1
              from organization_research_profiles orp
             where orp.organization_id = o.id
               and orp.prompt_fingerprint = $3
          )
        )
      group by o.id
      order by (o.metadata ? 'perplexity_enrichment') desc, o.updated_at asc
      limit $1
    `,
    [
      options.limit,
      options.force,
      PROMPT_FINGERPRINT,
      options.missingProfileOnly,
    ],
  )
  return result.rows
}

async function fetchPersonCandidates(
  pool: pg.Pool,
  limit: number,
  force: boolean,
): Promise<PersonCandidate[]> {
  const result = await pool.query<PersonCandidate>(
    `
      select
        p.id::text,
        p.full_name,
        p.headline,
        p.summary,
        p.city,
        p.region,
        p.country,
        p.linkedin_url,
        p.website,
        case
          when p.primary_email::text like '%@%'
            then lower(split_part(p.primary_email::text, '@', 2))
          else null
        end as primary_email_domain,
        coalesce(
          jsonb_agg(
            distinct jsonb_build_object(
              'organizationName', o.name,
              'organizationDomain', o.domain::text,
              'title', a.title
            )
          ) filter (where o.id is not null),
          '[]'::jsonb
        ) as affiliations
      from people p
      left join affiliations a on a.person_id = p.id and a.is_current
      left join organizations o on o.id = a.organization_id and o.archived_at is null
      where p.archived_at is null
        and (
          $2::boolean
          or p.headline is null
          or p.summary is null
          or p.linkedin_url is null
          or p.country is null
          or not (p.metadata ? 'perplexity_enrichment')
        )
      group by p.id
      order by p.updated_at asc
      limit $1
    `,
    [limit, force],
  )
  return result.rows
}

function organizationUpdates(
  candidate: OrganizationCandidate,
  enrichment: OrganizationEnrichment,
): Record<string, string | null> {
  return compactRecord({
    website: blank(candidate.website) ? textOrNull(enrichment.website) : null,
    description: blank(candidate.description)
      ? textOrNull(enrichment.oneLineDescription)
      : null,
    industry: blank(candidate.industry)
      ? categoryLabel(enrichment.category)
      : null,
  })
}

function personUpdates(
  candidate: PersonCandidate,
  enrichment: PersonEnrichment,
): Record<string, string | null> {
  return compactRecord({
    headline: blank(candidate.headline)
      ? textOrNull(enrichment.headline)
      : null,
    summary: blank(candidate.summary) ? textOrNull(enrichment.summary) : null,
    linkedin_url: blank(candidate.linkedin_url)
      ? textOrNull(enrichment.linkedinUrl)
      : null,
    website: blank(candidate.website) ? textOrNull(enrichment.website) : null,
    city: blank(candidate.city) ? textOrNull(enrichment.city) : null,
    region: blank(candidate.region) ? textOrNull(enrichment.region) : null,
    country: blank(candidate.country) ? textOrNull(enrichment.country) : null,
  })
}

async function writeOrganizationEnrichment(
  ctx: EnrichmentContext,
  candidate: OrganizationCandidate,
  enrichment: OrganizationEnrichment,
  updates: Record<string, string | null>,
  facts: FactInput[],
): Promise<void> {
  const client = await ctx.pool.connect()
  try {
    await client.query('begin')
    await client.query(
      `
        update organizations
           set website = coalesce(nullif(website, ''), nullif($2, '')),
               description = coalesce(nullif(description, ''), nullif($3, '')),
               industry = coalesce(nullif(industry, ''), nullif($4, '')),
               domain = coalesce(domain, nullif($5, '')::citext),
               metadata = metadata || jsonb_build_object('perplexity_enrichment', $6::jsonb)
         where id = $1::uuid
      `,
      [
        candidate.id,
        updates.website,
        updates.description,
        updates.industry,
        blank(candidate.domain) ? textOrNull(enrichment.domain) : null,
        metadataPayload(ctx.modelId, enrichment),
      ],
    )

    await upsertOrganizationResearchProfile(client, {
      organizationId: candidate.id,
      sourceId: requireSourceId(ctx),
      modelId: ctx.modelId,
      enrichment,
    })
    await upsertOrganizationTags(client, {
      organizationId: candidate.id,
      sourceId: requireSourceId(ctx),
      tags: enrichment.suggestedTags,
    })

    await insertFacts(client, {
      subjectType: 'organization',
      subjectId: candidate.id,
      sourceId: requireSourceId(ctx),
      facts,
    })
    await insertAiNote(client, {
      subjectType: 'organization',
      subjectId: candidate.id,
      sourceId: requireSourceId(ctx),
      modelId: ctx.modelId,
      title: `Perplexity enrichment for ${candidate.name}`,
      content:
        textOrNull(enrichment.partnershipFitRationale) ??
        textOrNull(enrichment.healthcareRelevance) ??
        textOrNull(enrichment.oneLineDescription) ??
        'Public enrichment completed.',
      sourceUrls: collectOrganizationSourceUrls(enrichment, facts),
    })
    await client.query('commit')
  } catch (err) {
    await client.query('rollback')
    throw err
  } finally {
    client.release()
  }
}

async function writePersonEnrichment(
  ctx: EnrichmentContext,
  candidate: PersonCandidate,
  enrichment: PersonEnrichment,
  updates: Record<string, string | null>,
  facts: FactInput[],
): Promise<void> {
  const client = await ctx.pool.connect()
  try {
    await client.query('begin')
    await client.query(
      `
        update people
           set headline = coalesce(nullif(headline, ''), nullif($2, '')),
               summary = coalesce(nullif(summary, ''), nullif($3, '')),
               linkedin_url = coalesce(nullif(linkedin_url, ''), nullif($4, '')),
               website = coalesce(nullif(website, ''), nullif($5, '')),
               city = coalesce(nullif(city, ''), nullif($6, '')),
               region = coalesce(nullif(region, ''), nullif($7, '')),
               country = coalesce(nullif(country, ''), nullif($8, '')),
               metadata = metadata || jsonb_build_object('perplexity_enrichment', $9::jsonb)
         where id = $1::uuid
      `,
      [
        candidate.id,
        updates.headline,
        updates.summary,
        updates.linkedin_url,
        updates.website,
        updates.city,
        updates.region,
        updates.country,
        metadataPayload(ctx.modelId, enrichment),
      ],
    )

    await insertFacts(client, {
      subjectType: 'person',
      subjectId: candidate.id,
      sourceId: requireSourceId(ctx),
      facts,
    })
    await insertAiNote(client, {
      subjectType: 'person',
      subjectId: candidate.id,
      sourceId: requireSourceId(ctx),
      modelId: ctx.modelId,
      title: `Perplexity enrichment for ${candidate.full_name}`,
      content:
        textOrNull(enrichment.summaryNote) ??
        textOrNull(enrichment.summary) ??
        'Public enrichment completed.',
      sourceUrls: facts.map((fact) => fact.sourceUrl).filter(nonNullable),
    })
    await client.query('commit')
  } catch (err) {
    await client.query('rollback')
    throw err
  } finally {
    client.release()
  }
}

async function upsertOrganizationResearchProfile(
  client: PoolClient,
  input: {
    organizationId: string
    sourceId: string
    modelId: string
    enrichment: OrganizationEnrichment
  },
): Promise<void> {
  await client.query(
    `
      insert into organization_research_profiles (
        organization_id,
        source_id,
        model,
        model_version,
        prompt_fingerprint,
        canonical_name,
        website,
        domain,
        one_line_description,
        category,
        healthcare_relevance,
        partnership_fit,
        partnership_fit_rationale,
        offerings,
        likely_use_cases,
        integration_signals,
        compliance_signals,
        key_public_people,
        suggested_tags,
        review_flags,
        source_urls,
        raw_enrichment,
        researched_at
      )
      values (
        $1::uuid,
        $2::uuid,
        'perplexity',
        $3,
        $4,
        $5,
        $6,
        $7::citext,
        $8,
        $9,
        $10,
        $11,
        $12,
        $13::jsonb,
        $14::jsonb,
        $15::jsonb,
        $16::jsonb,
        $17::jsonb,
        $18::jsonb,
        $19::jsonb,
        $20::jsonb,
        $21::jsonb,
        now()
      )
      on conflict (organization_id, prompt_fingerprint) do update
        set source_id = excluded.source_id,
            model = excluded.model,
            model_version = excluded.model_version,
            canonical_name = excluded.canonical_name,
            website = excluded.website,
            domain = excluded.domain,
            one_line_description = excluded.one_line_description,
            category = excluded.category,
            healthcare_relevance = excluded.healthcare_relevance,
            partnership_fit = excluded.partnership_fit,
            partnership_fit_rationale = excluded.partnership_fit_rationale,
            offerings = excluded.offerings,
            likely_use_cases = excluded.likely_use_cases,
            integration_signals = excluded.integration_signals,
            compliance_signals = excluded.compliance_signals,
            key_public_people = excluded.key_public_people,
            suggested_tags = excluded.suggested_tags,
            review_flags = excluded.review_flags,
            source_urls = excluded.source_urls,
            raw_enrichment = excluded.raw_enrichment,
            researched_at = excluded.researched_at
    `,
    [
      input.organizationId,
      input.sourceId,
      input.modelId,
      PROMPT_FINGERPRINT,
      textOrNull(input.enrichment.canonicalName),
      textOrNull(input.enrichment.website),
      textOrNull(input.enrichment.domain),
      textOrNull(input.enrichment.oneLineDescription),
      textOrNull(input.enrichment.category),
      textOrNull(input.enrichment.healthcareRelevance),
      textOrNull(input.enrichment.partnershipFit),
      textOrNull(input.enrichment.partnershipFitRationale),
      JSON.stringify(cleanStringArray(input.enrichment.offerings)),
      JSON.stringify(
        cleanStringArray(input.enrichment.likelyUseCasesForPicardo),
      ),
      JSON.stringify(cleanStringArray(input.enrichment.integrationSignals)),
      JSON.stringify(cleanStringArray(input.enrichment.complianceSignals)),
      JSON.stringify(cleanKeyPublicPeople(input.enrichment.keyPublicPeople)),
      JSON.stringify(cleanStringArray(input.enrichment.suggestedTags)),
      JSON.stringify(cleanStringArray(input.enrichment.reviewFlags)),
      JSON.stringify(collectOrganizationSourceUrls(input.enrichment, [])),
      JSON.stringify(input.enrichment),
    ],
  )
}

async function upsertOrganizationTags(
  client: PoolClient,
  input: { organizationId: string; sourceId: string; tags: string[] },
): Promise<void> {
  for (const tag of input.tags.map(normalizeTag).filter(nonNullable)) {
    const result = await client.query<{ id: string }>(
      `
        insert into tags (slug, label)
        values ($1, $2)
        on conflict (slug) do update
          set label = excluded.label
        returning id::text
      `,
      [tag.slug, tag.label],
    )

    const tagId = result.rows[0]?.id
    if (!tagId) {
      continue
    }

    await client.query(
      `
        insert into taggings (tag_id, target_type, target_id, source_id)
        values ($1::uuid, 'organization', $2::uuid, $3::uuid)
        on conflict (tag_id, target_type, target_id) do nothing
      `,
      [tagId, input.organizationId, input.sourceId],
    )
  }
}

async function insertFacts(
  client: PoolClient,
  input: {
    subjectType: 'organization' | 'person'
    subjectId: string
    sourceId: string
    facts: FactInput[]
  },
): Promise<void> {
  for (const fact of input.facts) {
    await client.query(
      `
        insert into extracted_facts (
          subject_type,
          subject_id,
          key,
          value_text,
          confidence,
          source_id,
          source_excerpt,
          metadata
        )
        select
          $1::entity_type,
          $2::uuid,
          $3,
          $4,
          $5,
          $6::uuid,
          $7,
          jsonb_build_object(
            'source_url',
            $8::text,
            'prompt_fingerprint',
            $9::text
          )
        where not exists (
          select 1
            from extracted_facts
           where subject_type = $1::entity_type
             and subject_id = $2::uuid
             and key = $3
             and value_text is not distinct from $4
             and source_id is not distinct from $6::uuid
        )
      `,
      [
        input.subjectType,
        input.subjectId,
        fact.key,
        fact.valueText,
        fact.confidence,
        input.sourceId,
        fact.sourceExcerpt,
        fact.sourceUrl,
        PROMPT_FINGERPRINT,
      ],
    )
  }
}

async function insertAiNote(
  client: PoolClient,
  input: {
    subjectType: 'organization' | 'person'
    subjectId: string
    sourceId: string
    modelId: string
    title: string
    content: string
    sourceUrls: string[]
  },
): Promise<void> {
  await client.query(
    `
      insert into ai_notes (
        kind,
        subject_type,
        subject_id,
        title,
        content,
        model,
        model_version,
        prompt_fingerprint,
        source_id,
        metadata
      )
      select
        'summary',
        $1::entity_type,
        $2::uuid,
        $3,
        $4,
        'perplexity',
        $5,
        $6,
        $7::uuid,
        jsonb_build_object('source_urls', $8::jsonb)
      where not exists (
        select 1
          from ai_notes
         where subject_type = $1::entity_type
           and subject_id = $2::uuid
           and prompt_fingerprint = $6
           and source_id is not distinct from $7::uuid
      )
    `,
    [
      input.subjectType,
      input.subjectId,
      input.title,
      input.content,
      input.modelId,
      PROMPT_FINGERPRINT,
      input.sourceId,
      JSON.stringify(input.sourceUrls),
    ],
  )
}

async function ensurePerplexitySource(pool: pg.Pool): Promise<string> {
  const result = await pool.query<{ id: string }>(
    `
      insert into sources (slug, name, description, metadata)
      values (
        'perplexity',
        'Perplexity Sonar API',
        'Public web enrichment via Perplexity Sonar and Vercel AI SDK.',
        jsonb_build_object('prompt_fingerprint', $1::text)
      )
      on conflict (slug) do update
        set name = excluded.name,
            description = excluded.description,
            metadata = sources.metadata || excluded.metadata
      returning id::text
    `,
    [PROMPT_FINGERPRINT],
  )

  return (
    result.rows[0]?.id ?? fail('Could not create or load perplexity source.')
  )
}

function normalizeFacts(facts: z.infer<typeof factSchema>[]): FactInput[] {
  return facts
    .map((fact) => ({
      key: normalizeFactKey(fact.key),
      valueText: truncateRequired(fact.valueText, 500),
      confidence: fact.confidence ?? null,
      sourceUrl: truncateOptional(fact.sourceUrl, 500),
      sourceExcerpt: truncateOptional(fact.sourceExcerpt, 500),
    }))
    .filter((fact) => fact.key.length > 0 && fact.valueText.length > 0)
}

function normalizeFactKey(key: string): string {
  return key
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .slice(0, 80)
}

function metadataPayload(
  modelId: string,
  enrichment: OrganizationEnrichment | PersonEnrichment,
): string {
  return JSON.stringify({
    enriched_at: new Date().toISOString(),
    model: 'perplexity',
    model_version: modelId,
    prompt_fingerprint: PROMPT_FINGERPRINT,
    source_urls: normalizeFacts(enrichment.facts)
      .map((fact) => fact.sourceUrl)
      .filter(nonNullable),
  })
}

function compactRecord(
  input: Record<string, string | null>,
): Record<string, string | null> {
  return Object.fromEntries(
    Object.entries(input).filter(([, value]) => value !== null),
  )
}

function categoryLabel(
  category: OrganizationEnrichment['category'],
): string | null {
  const value = textOrNull(category)
  if (!value) {
    return null
  }
  return value
    .split('_')
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ')
}

function collectOrganizationSourceUrls(
  enrichment: OrganizationEnrichment,
  facts: FactInput[],
): string[] {
  return uniqueStrings([
    ...normalizeFacts(enrichment.facts)
      .map((fact) => fact.sourceUrl)
      .filter(nonNullable),
    ...facts.map((fact) => fact.sourceUrl).filter(nonNullable),
    ...enrichment.keyPublicPeople
      .map((person) => textOrNull(person.sourceUrl))
      .filter(nonNullable),
  ])
}

function normalizeTag(value: string): { slug: string; label: string } | null {
  const label = textOrNull(value)
  if (!label) {
    return null
  }

  const slug = label
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .slice(0, 80)

  if (!slug) {
    return null
  }

  return { slug, label: label.slice(0, 120) }
}

function describeOrganizationChanges(
  enrichment: OrganizationEnrichment,
  updates: Record<string, string | null>,
  facts: FactInput[],
): string {
  const profilePieces = [
    textOrNull(enrichment.category) ? `category ${enrichment.category}` : null,
    textOrNull(enrichment.partnershipFit)
      ? `fit ${enrichment.partnershipFit}`
      : null,
    enrichment.offerings.length > 0
      ? `${enrichment.offerings.length} offering(s)`
      : null,
    enrichment.likelyUseCasesForPicardo.length > 0
      ? `${enrichment.likelyUseCasesForPicardo.length} use case(s)`
      : null,
    enrichment.integrationSignals.length > 0
      ? `${enrichment.integrationSignals.length} integration signal(s)`
      : null,
  ].filter(nonNullable)

  const fields = Object.keys(updates)
  const pieces = [
    profilePieces.length === 0 ? 'profile saved' : profilePieces.join(', '),
    fields.length === 0 ? null : `fields ${fields.join(', ')}`,
    facts.length === 0 ? null : `${facts.length} fact(s)`,
  ].filter(nonNullable)

  return pieces.join('; ')
}

function describeChanges(
  updates: Record<string, string | null>,
  facts: FactInput[],
): string {
  const fields = Object.keys(updates)
  const pieces = [
    fields.length === 0 ? null : `fields ${fields.join(', ')}`,
    facts.length === 0 ? null : `${facts.length} fact(s)`,
  ].filter(nonNullable)

  return pieces.length === 0 ? 'no high-confidence updates' : pieces.join('; ')
}

function textOrNull(value: string | null | undefined): string | null {
  const trimmed = value?.replace(/\[\d+(?:,\s*\d+)*\]/g, '').trim()
  return trimmed ? trimmed : null
}

function truncateOptional(
  value: string | null | undefined,
  maxLength: number,
): string | null {
  const trimmed = textOrNull(value)
  return trimmed ? trimmed.slice(0, maxLength) : null
}

function truncateRequired(value: string, maxLength: number): string {
  return textOrNull(value)?.slice(0, maxLength) ?? ''
}

function blank(value: string | null): boolean {
  return textOrNull(value) === null
}

function cleanStringArray(values: string[]): string[] {
  return values.map((value) => textOrNull(value)).filter(nonNullable)
}

function cleanKeyPublicPeople(
  people: OrganizationEnrichment['keyPublicPeople'],
): OrganizationEnrichment['keyPublicPeople'] {
  const cleaned: OrganizationEnrichment['keyPublicPeople'] = []
  for (const person of people) {
    const name = textOrNull(person.name)
    if (!name) {
      continue
    }
    cleaned.push({
      name,
      title: textOrNull(person.title),
      sourceUrl: textOrNull(person.sourceUrl),
      confidence: person.confidence ?? null,
    })
  }
  return cleaned
}

function nonNullable<T>(value: T | null | undefined): value is T {
  return value !== null && value !== undefined
}

function uniqueStrings(values: string[]): string[] {
  return [...new Set(values)]
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}

function extractJsonObjectText(text: string): string | null {
  const fenced = /```(?:json)?\s*([\s\S]*?)```/i.exec(text)
  if (fenced?.[1]) {
    return fenced[1].trim()
  }

  const start = text.indexOf('{')
  const end = text.lastIndexOf('}')
  if (start >= 0 && end > start) {
    return text.slice(start, end + 1)
  }

  return null
}

function requireSourceId(ctx: EnrichmentContext): string {
  return ctx.sourceId ?? fail('Missing source id while applying enrichment.')
}

function positiveInteger(value: number | undefined, fallback: number): number {
  if (value === undefined || !Number.isFinite(value) || value < 1) {
    return fallback
  }
  return Math.floor(value)
}

function printUsage(
  name: string,
  modelId: string,
  usage: { totalTokens?: number },
): void {
  console.log(
    `  ${name}: ${modelId}, ${usage.totalTokens ?? 'unknown'} total token(s).`,
  )
}

function fail(message: string): never {
  throw new Error(message)
}

# open-crm-db Sync Workflows

Use these patterns with `scripts/psql.sh`. Keep transcript bodies and AI note
content out of chat responses.

## Inspect Status

```sql
select name, run_on
from public.pgmigrations
order by id;

select table_name
from information_schema.tables
where table_schema = 'public'
  and table_type = 'BASE TABLE'
order by table_name;

select slug, name
from sources
order by slug;
```

## Ensure Source

```sql
insert into sources (slug, name, description)
values (:'source_slug', :'source_name', :'source_description')
on conflict (slug) do update
set name = excluded.name,
    description = coalesce(excluded.description, sources.description)
returning id;
```

## Resolve Person By Email

```sql
select p.id, p.full_name, p.primary_email
from people p
left join person_emails e on e.person_id = p.id
where p.primary_email = :'email'
   or e.email = :'email'
limit 10;
```

## Create Person With Email

```sql
select *
from crm_import_person_from_email(
  :'source_slug',
  :'full_name',
  :'email',
  coalesce(nullif(:'external_kind', ''), 'contact'),
  nullif(:'external_id', ''),
  '{}'::jsonb
);
```

If `person_id` is null, do not create a CRM person for that sender or
attendee. Use the returned `reason_codes` to decide whether to link an
organization by email domain, keep the raw handle in interaction metadata, or
ignore a machine notification sender.

## Create Organization From Email Domain

```sql
select *
from crm_import_organization_from_email(
  :'source_slug',
  :'organization_name',
  :'email',
  coalesce(nullif(:'external_kind', ''), 'email_domain'),
  nullif(:'external_id', ''),
  '{}'::jsonb
);
```

If `organization_id` is null, do not create a standalone organization for that
domain. Preserve the raw email/domain in interaction metadata for later review.

## Upsert Interaction

```sql
with src as (
  select id from sources where slug = :'source_slug'
)
insert into interactions (
  type,
  direction,
  subject,
  body,
  occurred_at,
  ended_at,
  duration_seconds,
  source_id,
  source_external_id,
  metadata
)
select
  :'interaction_type'::interaction_type,
  nullif(:'direction', '')::interaction_direction,
  nullif(:'subject', ''),
  nullif(:'body', ''),
  :'occurred_at'::timestamptz,
  nullif(:'ended_at', '')::timestamptz,
  nullif(:'duration_seconds', '')::integer,
  src.id,
  :'source_external_id',
  coalesce(nullif(:'metadata_json', '')::jsonb, '{}'::jsonb)
from src
on conflict (source_id, source_external_id) do update
set subject = excluded.subject,
    body = coalesce(excluded.body, interactions.body),
    occurred_at = excluded.occurred_at,
    ended_at = excluded.ended_at,
    duration_seconds = excluded.duration_seconds,
    metadata = interactions.metadata || excluded.metadata
returning id;
```

## Add Participant

Set exactly one of `person_id` or `organization_id`.

```sql
insert into interaction_participants (
  interaction_id,
  person_id,
  role,
  handle,
  display_name
)
values (
  :'interaction_id'::uuid,
  :'person_id'::uuid,
  :'role'::participant_role,
  nullif(:'handle', ''),
  nullif(:'display_name', '')
)
on conflict (interaction_id, person_id, role)
where person_id is not null
do update
set handle = coalesce(excluded.handle, interaction_participants.handle),
    display_name = coalesce(excluded.display_name, interaction_participants.display_name)
returning id;
```

## Upsert Transcript

```sql
with src as (
  select id from sources where slug = :'source_slug'
)
insert into call_transcripts (
  interaction_id,
  format,
  language,
  raw_text,
  segments,
  recording_url,
  source_id,
  source_external_id,
  transcribed_by,
  transcribed_at,
  metadata
)
select
  :'interaction_id'::uuid,
  :'format'::transcript_format,
  nullif(:'language', ''),
  :'raw_text',
  nullif(:'segments_json', '')::jsonb,
  nullif(:'recording_url', ''),
  src.id,
  :'source_external_id',
  nullif(:'transcribed_by', ''),
  nullif(:'transcribed_at', '')::timestamptz,
  coalesce(nullif(:'metadata_json', '')::jsonb, '{}'::jsonb)
from src
on conflict (source_id, source_external_id) do update
set raw_text = excluded.raw_text,
    segments = coalesce(excluded.segments, call_transcripts.segments),
    recording_url = coalesce(excluded.recording_url, call_transcripts.recording_url),
    transcribed_by = coalesce(excluded.transcribed_by, call_transcripts.transcribed_by),
    transcribed_at = coalesce(excluded.transcribed_at, call_transcripts.transcribed_at),
    metadata = call_transcripts.metadata || excluded.metadata
returning id;
```

## Upsert Document

Use for memos, research notes, strategy docs, meeting-note documents, contract
summaries, repo markdown, and other durable knowledge artifacts that are not
necessarily interactions.

```sql
with src as (
  select id from sources where slug = :'source_slug'
)
insert into documents (
  title,
  document_type,
  body,
  body_format,
  summary,
  authored_at,
  occurred_at,
  source_id,
  source_external_id,
  source_path,
  metadata
)
select
  :'title',
  :'document_type',
  nullif(:'body', ''),
  coalesce(nullif(:'body_format', ''), 'markdown'),
  nullif(:'summary', ''),
  nullif(:'authored_at', '')::timestamptz,
  nullif(:'occurred_at', '')::timestamptz,
  src.id,
  nullif(:'source_external_id', ''),
  nullif(:'source_path', ''),
  coalesce(nullif(:'metadata_json', '')::jsonb, '{}'::jsonb)
from src
on conflict (source_id, source_external_id)
where source_external_id is not null
do update
set title = excluded.title,
    document_type = excluded.document_type,
    body = coalesce(excluded.body, documents.body),
    body_format = excluded.body_format,
    summary = coalesce(excluded.summary, documents.summary),
    authored_at = coalesce(excluded.authored_at, documents.authored_at),
    occurred_at = coalesce(excluded.occurred_at, documents.occurred_at),
    source_path = coalesce(excluded.source_path, documents.source_path),
    metadata = documents.metadata || excluded.metadata
returning id;
```

## Link Document To Person

Use roles such as `author`, `mentioned`, `subject`, `reviewer`, `owner`, or
`signatory`.

```sql
insert into document_people (document_id, person_id, role, notes, metadata)
values (
  :'document_id'::uuid,
  :'person_id'::uuid,
  :'role',
  nullif(:'notes', ''),
  coalesce(nullif(:'metadata_json', '')::jsonb, '{}'::jsonb)
)
on conflict (document_id, person_id, role) do update
set notes = coalesce(excluded.notes, document_people.notes),
    metadata = document_people.metadata || excluded.metadata
returning id;
```

## Link Document To Organization

```sql
insert into document_organizations (
  document_id,
  organization_id,
  role,
  notes,
  metadata
)
values (
  :'document_id'::uuid,
  :'organization_id'::uuid,
  :'role',
  nullif(:'notes', ''),
  coalesce(nullif(:'metadata_json', '')::jsonb, '{}'::jsonb)
)
on conflict (document_id, organization_id, role) do update
set notes = coalesce(excluded.notes, document_organizations.notes),
    metadata = document_organizations.metadata || excluded.metadata
returning id;
```

## Link Document To Interaction

```sql
insert into document_interactions (
  document_id,
  interaction_id,
  role,
  notes,
  metadata
)
values (
  :'document_id'::uuid,
  :'interaction_id'::uuid,
  coalesce(nullif(:'role', ''), 'related'),
  nullif(:'notes', ''),
  coalesce(nullif(:'metadata_json', '')::jsonb, '{}'::jsonb)
)
on conflict (document_id, interaction_id, role) do update
set notes = coalesce(excluded.notes, document_interactions.notes),
    metadata = document_interactions.metadata || excluded.metadata
returning id;
```

## Insert AI Note

```sql
insert into ai_notes (
  kind,
  interaction_id,
  document_id,
  title,
  content,
  content_format,
  model,
  model_version,
  prompt_fingerprint,
  source_id,
  metadata
)
select
  :'kind'::ai_note_kind,
  nullif(:'interaction_id', '')::uuid,
  nullif(:'document_id', '')::uuid,
  nullif(:'title', ''),
  :'content',
  'markdown',
  nullif(:'model', ''),
  nullif(:'model_version', ''),
  nullif(:'prompt_fingerprint', ''),
  (select id from sources where slug = :'source_slug'),
  coalesce(nullif(:'metadata_json', '')::jsonb, '{}'::jsonb)
returning id;
```

## Insert Extracted Fact

Facts are append-only.

```sql
insert into extracted_facts (
  subject_type,
  subject_id,
  key,
  value_text,
  value_json,
  confidence,
  interaction_id,
  document_id,
  source_id,
  source_excerpt,
  observed_at,
  metadata
)
select
  :'subject_type'::entity_type,
  :'subject_id'::uuid,
  :'key',
  nullif(:'value_text', ''),
  nullif(:'value_json', '')::jsonb,
  nullif(:'confidence', '')::numeric,
  nullif(:'interaction_id', '')::uuid,
  nullif(:'document_id', '')::uuid,
  (select id from sources where slug = :'source_slug'),
  nullif(:'source_excerpt', ''),
  coalesce(nullif(:'observed_at', '')::timestamptz, now()),
  coalesce(nullif(:'metadata_json', '')::jsonb, '{}'::jsonb)
returning id;
```

## Verification Queries

```sql
select count(*) as interactions from interactions;
select count(*) as transcripts from call_transcripts;
select count(*) as documents from documents;
select count(*) as ai_notes from ai_notes;
select count(*) as extracted_facts from extracted_facts;

select i.id, i.type, i.subject, i.occurred_at, s.slug as source, i.source_external_id
from interactions i
left join sources s on s.id = i.source_id
order by i.occurred_at desc
limit 20;
```

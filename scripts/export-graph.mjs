#!/usr/bin/env node

import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..')
const outDir = path.resolve(
  process.argv[2] ?? path.join(repoRoot, 'visualizations', 'crm-graph'),
)

const psqlCandidates = [
  path.join(repoRoot, 'skills', 'open-crm-db', 'scripts', 'psql.sh'),
  path.join(
    homedir(),
    '.codex',
    'skills',
    'open-crm-db',
    'scripts',
    'psql.sh',
  ),
]
const psql =
  psqlCandidates.find(
    (candidate) => existsSync(candidate) && hasCredentials(candidate),
  ) ?? psqlCandidates.find((candidate) => existsSync(candidate))

if (!psql) {
  throw new Error(
    `Could not find psql helper. Checked:\n${psqlCandidates.join('\n')}`,
  )
}

function hasCredentials(candidate) {
  if (process.env.DATABASE_URL) {
    return true
  }

  return existsSync(
    path.resolve(
      path.dirname(candidate),
      '..',
      'references',
      'credentials.env',
    ),
  )
}

const sql = String.raw`
with nodes as (
  select jsonb_build_object(
    'id', 'organization:' || id,
    'type', 'organization',
    'label', name,
    'subtitle', concat_ws(' | ', nullif(domain::text, ''), nullif(industry, ''), nullif(hq_city, '')),
    'archived', archived_at is not null,
    'meta', jsonb_build_object('domain', domain, 'industry', industry, 'city', hq_city, 'country', hq_country)
  ) node
  from organizations
  where archived_at is null

  union all
  select jsonb_build_object(
    'id', 'person:' || id,
    'type', 'person',
    'label', full_name,
    'subtitle', concat_ws(' | ', nullif(headline, ''), nullif(city, ''), nullif(country, '')),
    'archived', archived_at is not null,
    'meta', jsonb_build_object('headline', headline, 'city', city, 'country', country)
  ) node
  from people
  where archived_at is null

  union all
  select jsonb_build_object(
    'id', 'interaction:' || id,
    'type', 'interaction',
    'label', left(concat(type::text, ': ', coalesce(nullif(subject, ''), to_char(occurred_at, 'YYYY-MM-DD'))), 140),
    'subtitle', concat_ws(' | ', direction::text, to_char(occurred_at, 'YYYY-MM-DD HH24:MI')),
    'archived', archived_at is not null,
    'meta', jsonb_build_object('interaction_type', type, 'direction', direction, 'occurred_at', occurred_at, 'duration_seconds', duration_seconds)
  ) node
  from interactions
  where archived_at is null

  union all
  select jsonb_build_object(
    'id', 'document:' || id,
    'type', 'document',
    'label', left(title, 160),
    'subtitle', concat_ws(' | ', document_type, to_char(coalesce(authored_at, occurred_at, created_at), 'YYYY-MM-DD')),
    'archived', archived_at is not null,
    'meta', jsonb_build_object('document_type', document_type, 'authored_at', authored_at, 'occurred_at', occurred_at, 'source_path', source_path)
  ) node
  from documents
  where archived_at is null

  union all
  select jsonb_build_object(
    'id', 'tag:' || id,
    'type', 'tag',
    'label', label,
    'subtitle', slug,
    'archived', false,
    'meta', jsonb_build_object('slug', slug, 'color', color)
  ) node
  from tags

  union all
  select jsonb_build_object(
    'id', 'source:' || id,
    'type', 'source',
    'label', slug,
    'subtitle', name,
    'archived', false,
    'meta', jsonb_build_object('name', name)
  ) node
  from sources

  union all
  select jsonb_build_object(
    'id', 'transcript:' || id,
    'type', 'transcript',
    'label', concat('Transcript ', left(id::text, 8)),
    'subtitle', concat_ws(' | ', format::text, nullif(language, ''), to_char(coalesce(transcribed_at, created_at), 'YYYY-MM-DD')),
    'archived', false,
    'meta', jsonb_build_object('format', format, 'language', language, 'transcribed_by', transcribed_by)
  ) node
  from call_transcripts

  union all
  select jsonb_build_object(
    'id', 'fact:' || id,
    'type', 'fact',
    'label', key,
    'subtitle', concat_ws(' | ', subject_type::text, to_char(observed_at, 'YYYY-MM-DD'), case when confidence is null then null else concat('confidence ', confidence::text) end),
    'archived', false,
    'meta', jsonb_build_object('key', key, 'subject_type', subject_type, 'observed_at', observed_at, 'confidence', confidence)
  ) node
  from extracted_facts

  union all
  select jsonb_build_object(
    'id', 'ai_note:' || id,
    'type', 'ai_note',
    'label', left(coalesce(nullif(title, ''), kind::text), 140),
    'subtitle', concat_ws(' | ', kind::text, model, to_char(generated_at, 'YYYY-MM-DD')),
    'archived', false,
    'meta', jsonb_build_object('kind', kind, 'model', model, 'generated_at', generated_at)
  ) node
  from ai_notes
),
edges as (
  select jsonb_build_object(
    'id', 'affiliation:' || id,
    'source', 'person:' || person_id,
    'target', 'organization:' || organization_id,
    'type', 'affiliation',
    'label', coalesce(nullif(title, ''), case when is_current then 'current affiliation' else 'past affiliation' end),
    'directed', true,
    'weight', case when is_current then 2 else 1 end,
    'meta', jsonb_build_object('title', title, 'department', department, 'is_current', is_current, 'is_primary', is_primary)
  ) edge
  from affiliations

  union all
  select jsonb_build_object(
    'id', 'participant-person:' || id,
    'source', 'person:' || person_id,
    'target', 'interaction:' || interaction_id,
    'type', 'participant',
    'label', role::text,
    'directed', false,
    'weight', 1,
    'meta', jsonb_build_object('role', role, 'handle', handle, 'display_name', display_name)
  ) edge
  from interaction_participants
  where person_id is not null

  union all
  select jsonb_build_object(
    'id', 'participant-org:' || id,
    'source', 'organization:' || organization_id,
    'target', 'interaction:' || interaction_id,
    'type', 'participant',
    'label', role::text,
    'directed', false,
    'weight', 1,
    'meta', jsonb_build_object('role', role, 'handle', handle, 'display_name', display_name)
  ) edge
  from interaction_participants
  where organization_id is not null

  union all
  select jsonb_build_object(
    'id', 'document-person:' || id,
    'source', 'document:' || document_id,
    'target', 'person:' || person_id,
    'type', 'document_person',
    'label', role,
    'directed', false,
    'weight', 1,
    'meta', jsonb_build_object('role', role)
  ) edge
  from document_people

  union all
  select jsonb_build_object(
    'id', 'document-organization:' || id,
    'source', 'document:' || document_id,
    'target', 'organization:' || organization_id,
    'type', 'document_organization',
    'label', role,
    'directed', false,
    'weight', 1,
    'meta', jsonb_build_object('role', role)
  ) edge
  from document_organizations

  union all
  select jsonb_build_object(
    'id', 'document-interaction:' || id,
    'source', 'document:' || document_id,
    'target', 'interaction:' || interaction_id,
    'type', 'document_interaction',
    'label', role,
    'directed', false,
    'weight', 1,
    'meta', jsonb_build_object('role', role)
  ) edge
  from document_interactions

  union all
  select jsonb_build_object(
    'id', 'relationship:' || id,
    'source', source_entity_type::text || ':' || source_entity_id,
    'target', target_entity_type::text || ':' || target_entity_id,
    'type', 'relationship',
    'label', coalesce(nullif(label, ''), edge_type::text),
    'directed', true,
    'weight', 2,
    'meta', jsonb_build_object('edge_type', edge_type, 'label', label, 'start_date', start_date, 'end_date', end_date)
  ) edge
  from relationship_edges

  union all
  select jsonb_build_object(
    'id', 'tagging:' || id,
    'source', target_type || ':' || target_id,
    'target', 'tag:' || tag_id,
    'type', 'tagging',
    'label', 'tagged',
    'directed', false,
    'weight', 1,
    'meta', jsonb_build_object('target_type', target_type)
  ) edge
  from taggings

  union all
  select jsonb_build_object(
    'id', 'transcript-interaction:' || id,
    'source', 'interaction:' || interaction_id,
    'target', 'transcript:' || id,
    'type', 'transcript',
    'label', 'has transcript',
    'directed', true,
    'weight', 1,
    'meta', jsonb_build_object('format', format, 'language', language)
  ) edge
  from call_transcripts

  union all
  select jsonb_build_object(
    'id', 'fact-subject:' || id,
    'source', 'fact:' || id,
    'target', subject_type::text || ':' || subject_id,
    'type', 'fact_subject',
    'label', key,
    'directed', true,
    'weight', 1,
    'meta', jsonb_build_object('key', key, 'confidence', confidence)
  ) edge
  from extracted_facts

  union all
  select jsonb_build_object(
    'id', 'fact-interaction:' || id,
    'source', 'fact:' || id,
    'target', 'interaction:' || interaction_id,
    'type', 'fact_source',
    'label', 'derived from',
    'directed', true,
    'weight', 1,
    'meta', jsonb_build_object('source_kind', 'interaction')
  ) edge
  from extracted_facts
  where interaction_id is not null

  union all
  select jsonb_build_object(
    'id', 'fact-document:' || id,
    'source', 'fact:' || id,
    'target', 'document:' || document_id,
    'type', 'fact_source',
    'label', 'derived from',
    'directed', true,
    'weight', 1,
    'meta', jsonb_build_object('source_kind', 'document')
  ) edge
  from extracted_facts
  where document_id is not null

  union all
  select jsonb_build_object(
    'id', 'ai-note-interaction:' || id,
    'source', 'ai_note:' || id,
    'target', 'interaction:' || interaction_id,
    'type', 'ai_note',
    'label', kind::text,
    'directed', true,
    'weight', 1,
    'meta', jsonb_build_object('anchor', 'interaction', 'kind', kind)
  ) edge
  from ai_notes
  where interaction_id is not null

  union all
  select jsonb_build_object(
    'id', 'ai-note-document:' || id,
    'source', 'ai_note:' || id,
    'target', 'document:' || document_id,
    'type', 'ai_note',
    'label', kind::text,
    'directed', true,
    'weight', 1,
    'meta', jsonb_build_object('anchor', 'document', 'kind', kind)
  ) edge
  from ai_notes
  where document_id is not null

  union all
  select jsonb_build_object(
    'id', 'ai-note-subject:' || id,
    'source', 'ai_note:' || id,
    'target', subject_type::text || ':' || subject_id,
    'type', 'ai_note',
    'label', kind::text,
    'directed', true,
    'weight', 1,
    'meta', jsonb_build_object('anchor', 'subject', 'kind', kind)
  ) edge
  from ai_notes
  where subject_type is not null and subject_id is not null

  union all
  select jsonb_build_object(
    'id', 'source-interaction:' || id,
    'source', 'source:' || source_id,
    'target', 'interaction:' || id,
    'type', 'provenance',
    'label', 'source',
    'directed', true,
    'weight', 1,
    'meta', jsonb_build_object('table', 'interactions')
  ) edge
  from interactions
  where source_id is not null

  union all
  select jsonb_build_object(
    'id', 'source-document:' || id,
    'source', 'source:' || source_id,
    'target', 'document:' || id,
    'type', 'provenance',
    'label', 'source',
    'directed', true,
    'weight', 1,
    'meta', jsonb_build_object('table', 'documents')
  ) edge
  from documents
  where source_id is not null

  union all
  select jsonb_build_object(
    'id', 'source-transcript:' || id,
    'source', 'source:' || source_id,
    'target', 'transcript:' || id,
    'type', 'provenance',
    'label', 'source',
    'directed', true,
    'weight', 1,
    'meta', jsonb_build_object('table', 'call_transcripts')
  ) edge
  from call_transcripts
  where source_id is not null

  union all
  select jsonb_build_object(
    'id', 'external-identity:' || id,
    'source', 'source:' || source_id,
    'target', entity_type::text || ':' || entity_id,
    'type', 'external_identity',
    'label', coalesce(kind, 'external id'),
    'directed', true,
    'weight', 1,
    'meta', jsonb_build_object('kind', kind, 'url', url)
  ) edge
  from external_identities
)
select jsonb_build_object(
  'generatedAt', now(),
  'nodes', coalesce((select jsonb_agg(node order by node->>'type', node->>'label') from nodes), '[]'::jsonb),
  'edges', coalesce((select jsonb_agg(edge order by edge->>'type', edge->>'label') from edges), '[]'::jsonb)
)::text;
`

const raw = execFileSync(psql, ['-X', '-t', '-A', '-c', sql], {
  encoding: 'utf8',
  maxBuffer: 1024 * 1024 * 128,
})

const graph = JSON.parse(raw.trim())
const nodeIds = new Set(graph.nodes.map((node) => node.id))
graph.edges = graph.edges.filter(
  (edge) => nodeIds.has(edge.source) && nodeIds.has(edge.target),
)
graph.counts = {
  nodes: countBy(graph.nodes, 'type'),
  edges: countBy(graph.edges, 'type'),
  totalNodes: graph.nodes.length,
  totalEdges: graph.edges.length,
}

mkdirSync(outDir, { recursive: true })
writeFileSync(
  path.join(outDir, 'graph-data.json'),
  `${JSON.stringify(graph, null, 2)}\n`,
)
writeFileSync(path.join(outDir, 'graph.graphml'), graphToGraphml(graph))
writeFileSync(path.join(outDir, 'index.html'), buildHtml(graph))

console.log(
  `Wrote ${graph.nodes.length} nodes and ${graph.edges.length} edges to ${outDir}`,
)

function countBy(items, key) {
  return items.reduce((acc, item) => {
    acc[item[key]] = (acc[item[key]] ?? 0) + 1
    return acc
  }, {})
}

function graphToGraphml(data) {
  const lines = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<graphml xmlns="http://graphml.graphdrawing.org/xmlns">',
    '  <key id="label" for="all" attr.name="label" attr.type="string"/>',
    '  <key id="type" for="all" attr.name="type" attr.type="string"/>',
    '  <key id="subtitle" for="node" attr.name="subtitle" attr.type="string"/>',
    '  <key id="archived" for="node" attr.name="archived" attr.type="boolean"/>',
    '  <key id="directed" for="edge" attr.name="directed" attr.type="boolean"/>',
    '  <key id="weight" for="edge" attr.name="weight" attr.type="double"/>',
    '  <graph id="open-crm-db" edgedefault="undirected">',
  ]

  for (const node of data.nodes) {
    lines.push(`    <node id="${xml(node.id)}">`)
    lines.push(`      <data key="label">${xml(node.label)}</data>`)
    lines.push(`      <data key="type">${xml(node.type)}</data>`)
    lines.push(`      <data key="subtitle">${xml(node.subtitle ?? '')}</data>`)
    lines.push(
      `      <data key="archived">${node.archived ? 'true' : 'false'}</data>`,
    )
    lines.push('    </node>')
  }

  for (const edge of data.edges) {
    lines.push(
      `    <edge id="${xml(edge.id)}" source="${xml(edge.source)}" target="${xml(edge.target)}">`,
    )
    lines.push(`      <data key="label">${xml(edge.label)}</data>`)
    lines.push(`      <data key="type">${xml(edge.type)}</data>`)
    lines.push(
      `      <data key="directed">${edge.directed ? 'true' : 'false'}</data>`,
    )
    lines.push(`      <data key="weight">${Number(edge.weight ?? 1)}</data>`)
    lines.push('    </edge>')
  }

  lines.push('  </graph>', '</graphml>')
  return `${lines.join('\n')}\n`
}

function xml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;')
}

function buildHtml(data) {
  const json = JSON.stringify(data).replaceAll('<', '\\u003c')
  return String.raw`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>open-crm-db Graph</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f7f6f2;
      --panel: #ffffff;
      --text: #171717;
      --muted: #6a6f76;
      --border: #d8d5cb;
      --shadow: 0 12px 32px rgba(20, 24, 31, 0.12);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      overflow: hidden;
      background: var(--bg);
      color: var(--text);
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      letter-spacing: 0;
    }
    canvas { display: block; width: 100vw; height: 100vh; cursor: grab; }
    canvas.dragging { cursor: grabbing; }
    .topbar {
      position: fixed;
      top: 12px;
      left: 12px;
      right: 12px;
      display: grid;
      grid-template-columns: minmax(260px, 420px) auto minmax(280px, 1fr);
      gap: 10px;
      pointer-events: none;
      align-items: start;
    }
    .panel {
      pointer-events: auto;
      background: rgba(255, 255, 255, 0.93);
      border: 1px solid var(--border);
      box-shadow: var(--shadow);
      border-radius: 8px;
      backdrop-filter: blur(12px);
    }
    .brand { padding: 12px 14px; }
    h1 {
      margin: 0;
      font-size: 16px;
      font-weight: 760;
      line-height: 1.2;
    }
    .stats {
      margin-top: 6px;
      color: var(--muted);
      font-size: 12px;
      line-height: 1.45;
    }
    .controls {
      padding: 10px;
      display: grid;
      gap: 8px;
    }
    input[type="search"] {
      width: 100%;
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 9px 10px;
      font: inherit;
      font-size: 13px;
      background: #fff;
      color: var(--text);
    }
    button {
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 8px 10px;
      font: inherit;
      font-size: 12px;
      background: #fff;
      color: var(--text);
      cursor: pointer;
    }
    button:hover { border-color: #9fa4aa; }
    .buttons { display: flex; gap: 8px; flex-wrap: wrap; }
    .filters {
      padding: 10px;
      display: grid;
      grid-template-columns: repeat(3, minmax(120px, 1fr));
      gap: 7px 12px;
      max-height: 190px;
      overflow: auto;
    }
    label {
      display: flex;
      gap: 7px;
      align-items: center;
      color: #2f3237;
      font-size: 12px;
      white-space: nowrap;
    }
    .swatch {
      width: 10px;
      height: 10px;
      border-radius: 50%;
      border: 1px solid rgba(0, 0, 0, 0.18);
      flex: 0 0 auto;
    }
    .side {
      position: fixed;
      right: 12px;
      bottom: 12px;
      width: min(380px, calc(100vw - 24px));
      max-height: calc(100vh - 250px);
      overflow: auto;
      padding: 12px 14px;
      pointer-events: auto;
    }
    .side h2 {
      margin: 0 0 4px;
      font-size: 14px;
      line-height: 1.25;
      overflow-wrap: anywhere;
    }
    .pill {
      display: inline-flex;
      align-items: center;
      gap: 5px;
      margin-bottom: 8px;
      color: var(--muted);
      font-size: 12px;
    }
    .detail {
      display: grid;
      grid-template-columns: 92px 1fr;
      gap: 6px 10px;
      font-size: 12px;
      line-height: 1.45;
    }
    .detail dt { color: var(--muted); }
    .detail dd { margin: 0; overflow-wrap: anywhere; }
    .legend {
      position: fixed;
      left: 12px;
      bottom: 12px;
      padding: 10px;
      display: flex;
      gap: 10px;
      flex-wrap: wrap;
      max-width: min(720px, calc(100vw - 420px));
      pointer-events: auto;
      font-size: 12px;
      color: #32363b;
    }
    .legend-item { display: inline-flex; align-items: center; gap: 6px; }
    @media (max-width: 900px) {
      .topbar { grid-template-columns: 1fr; right: 12px; }
      .filters { grid-template-columns: repeat(2, minmax(120px, 1fr)); max-height: 135px; }
      .legend { display: none; }
      .side { max-height: 35vh; }
    }
  </style>
</head>
<body>
  <canvas id="graph"></canvas>
  <div class="topbar">
    <section class="panel brand">
      <h1>open-crm-db Graph</h1>
      <div class="stats" id="stats"></div>
    </section>
    <section class="panel controls">
      <input id="search" type="search" placeholder="Search names, titles, tags">
      <div class="buttons">
        <button id="fit">Fit</button>
        <button id="toggleEdges">Edges</button>
        <button id="clear">Clear</button>
      </div>
    </section>
    <section class="panel filters" id="filters"></section>
  </div>
  <section class="panel side" id="details"></section>
  <section class="panel legend" id="legend"></section>
  <script>
    const graph = ${json};
    const colors = {
      organization: "#2b6f9f",
      person: "#cf5a36",
      interaction: "#5b7f38",
      document: "#8b5aa8",
      tag: "#c09528",
      source: "#333b45",
      transcript: "#20847a",
      fact: "#b13b66",
      ai_note: "#6b6fbd"
    };
    const centers = {
      source: { x: -60, y: -40 },
      tag: { x: -30, y: -420 },
      organization: { x: -560, y: -70 },
      person: { x: -230, y: 80 },
      interaction: { x: 220, y: 0 },
      document: { x: 560, y: 190 },
      transcript: { x: 530, y: -230 },
      fact: { x: 120, y: 380 },
      ai_note: { x: 360, y: 400 }
    };
    const edgeColors = {
      affiliation: "#64748b",
      participant: "#94a3b8",
      document_person: "#b48ac6",
      document_organization: "#b48ac6",
      document_interaction: "#b48ac6",
      relationship: "#ef4444",
      tagging: "#d6a231",
      transcript: "#2aa198",
      fact_subject: "#c65b84",
      fact_source: "#d27b9b",
      ai_note: "#7c83d6",
      provenance: "#9aa0a6",
      external_identity: "#77808c"
    };

    const canvas = document.getElementById("graph");
    const ctx = canvas.getContext("2d");
    const search = document.getElementById("search");
    const stats = document.getElementById("stats");
    const details = document.getElementById("details");
    const filters = document.getElementById("filters");
    const legend = document.getElementById("legend");
    const nodeById = new Map(graph.nodes.map((node) => [node.id, node]));
    const degree = new Map(graph.nodes.map((node) => [node.id, 0]));
    for (const edge of graph.edges) {
      degree.set(edge.source, (degree.get(edge.source) ?? 0) + 1);
      degree.set(edge.target, (degree.get(edge.target) ?? 0) + 1);
    }
    for (const node of graph.nodes) node.degree = degree.get(node.id) ?? 0;

    const nodeTypes = [...new Set(graph.nodes.map((node) => node.type))].sort();
    const edgeTypes = [...new Set(graph.edges.map((edge) => edge.type))].sort();
    const enabledNodeTypes = new Set(nodeTypes);
    const enabledEdgeTypes = new Set(edgeTypes);
    let showEdges = true;
    let selected = null;
    let hovered = null;
    let transform = { x: window.innerWidth / 2, y: window.innerHeight / 2, scale: 0.72 };
    let dragging = false;
    let last = null;

    layout();
    buildFilters();
    buildLegend();
    fit();
    renderDetails();

    function layout() {
      const grouped = new Map();
      for (const node of graph.nodes) {
        if (!grouped.has(node.type)) grouped.set(node.type, []);
        grouped.get(node.type).push(node);
      }
      for (const [type, nodes] of grouped) {
        nodes.sort((a, b) => b.degree - a.degree || a.label.localeCompare(b.label));
        const center = centers[type] ?? { x: 0, y: 0 };
        const spread = Math.max(74, Math.sqrt(nodes.length) * 24);
        nodes.forEach((node, index) => {
          const angle = index * 2.399963229728653;
          const radius = spread * Math.sqrt(index + 1) * 0.78;
          node.x = center.x + Math.cos(angle) * radius;
          node.y = center.y + Math.sin(angle) * radius;
          node.r = Math.min(18, 5 + Math.sqrt(node.degree + 1) * 1.55);
        });
      }
    }

    function buildFilters() {
      filters.innerHTML = "";
      for (const type of nodeTypes) {
        const label = document.createElement("label");
        label.innerHTML = '<input type="checkbox" checked data-node-type="' + type + '"><span class="swatch" style="background:' + colors[type] + '"></span>' + title(type) + ' (' + (graph.counts.nodes[type] ?? 0) + ')';
        filters.appendChild(label);
      }
      for (const type of edgeTypes) {
        const label = document.createElement("label");
        label.innerHTML = '<input type="checkbox" checked data-edge-type="' + type + '"><span class="swatch" style="background:' + (edgeColors[type] ?? '#999') + '"></span>' + title(type) + ' (' + (graph.counts.edges[type] ?? 0) + ')';
        filters.appendChild(label);
      }
      filters.addEventListener("change", (event) => {
        const input = event.target;
        if (input.dataset.nodeType) updateSet(enabledNodeTypes, input.dataset.nodeType, input.checked);
        if (input.dataset.edgeType) updateSet(enabledEdgeTypes, input.dataset.edgeType, input.checked);
        draw();
      });
    }

    function buildLegend() {
      legend.innerHTML = nodeTypes.map((type) => '<span class="legend-item"><span class="swatch" style="background:' + colors[type] + '"></span>' + title(type) + '</span>').join("");
    }

    function updateSet(set, value, checked) {
      if (checked) set.add(value);
      else set.delete(value);
    }

    function resize() {
      const dpr = window.devicePixelRatio || 1;
      canvas.width = Math.floor(window.innerWidth * dpr);
      canvas.height = Math.floor(window.innerHeight * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      draw();
    }

    function visibleNodeSet() {
      const query = search.value.trim().toLowerCase();
      const ids = new Set();
      for (const node of graph.nodes) {
        if (!enabledNodeTypes.has(node.type)) continue;
        if (query && !(String(node.label) + " " + String(node.subtitle ?? "") + " " + String(node.type)).toLowerCase().includes(query)) continue;
        ids.add(node.id);
      }
      return ids;
    }

    function draw() {
      const visible = visibleNodeSet();
      ctx.clearRect(0, 0, window.innerWidth, window.innerHeight);
      ctx.save();
      ctx.translate(transform.x, transform.y);
      ctx.scale(transform.scale, transform.scale);

      const visibleEdges = graph.edges.filter((edge) => showEdges && enabledEdgeTypes.has(edge.type) && visible.has(edge.source) && visible.has(edge.target));
      ctx.lineCap = "round";
      for (const edge of visibleEdges) {
        const a = nodeById.get(edge.source);
        const b = nodeById.get(edge.target);
        ctx.globalAlpha = 0.18;
        ctx.strokeStyle = edgeColors[edge.type] ?? "#999";
        ctx.lineWidth = Math.max(0.8, Math.min(3, Number(edge.weight ?? 1))) / transform.scale;
        ctx.beginPath();
        ctx.moveTo(a.x, a.y);
        ctx.lineTo(b.x, b.y);
        ctx.stroke();
      }
      ctx.globalAlpha = 1;

      for (const node of graph.nodes) {
        if (!visible.has(node.id)) continue;
        const active = selected === node || hovered === node;
        ctx.beginPath();
        ctx.fillStyle = colors[node.type] ?? "#555";
        ctx.strokeStyle = active ? "#111" : "rgba(255,255,255,0.9)";
        ctx.lineWidth = active ? 3 / transform.scale : 1.4 / transform.scale;
        ctx.arc(node.x, node.y, node.r * (active ? 1.22 : 1), 0, Math.PI * 2);
        ctx.fill();
        ctx.stroke();
        if (node.archived) {
          ctx.strokeStyle = "#111";
          ctx.lineWidth = 1 / transform.scale;
          ctx.beginPath();
          ctx.moveTo(node.x - node.r, node.y - node.r);
          ctx.lineTo(node.x + node.r, node.y + node.r);
          ctx.stroke();
        }
      }

      const labels = [...graph.nodes].filter((node) => visible.has(node.id) && (node.degree > 12 || node === hovered || node === selected)).slice(0, 220);
      ctx.font = Math.max(10, 12 / transform.scale) + "px Inter, system-ui, sans-serif";
      ctx.textBaseline = "middle";
      for (const node of labels) {
        ctx.fillStyle = "rgba(255,255,255,0.88)";
        const text = short(node.label, 34);
        const width = ctx.measureText(text).width;
        ctx.fillRect(node.x + node.r + 4, node.y - 10 / transform.scale, width + 8 / transform.scale, 20 / transform.scale);
        ctx.fillStyle = "#1e2328";
        ctx.fillText(text, node.x + node.r + 8, node.y);
      }
      ctx.restore();
      stats.textContent = visible.size.toLocaleString() + " of " + graph.nodes.length.toLocaleString() + " nodes | " + visibleEdges.length.toLocaleString() + " of " + graph.edges.length.toLocaleString() + " edges | " + new Date(graph.generatedAt).toLocaleString();
    }

    function fit() {
      const visible = [...visibleNodeSet()].map((id) => nodeById.get(id)).filter(Boolean);
      if (!visible.length) return;
      const xs = visible.map((node) => node.x);
      const ys = visible.map((node) => node.y);
      const minX = Math.min(...xs);
      const maxX = Math.max(...xs);
      const minY = Math.min(...ys);
      const maxY = Math.max(...ys);
      const pad = 160;
      const scale = Math.min(window.innerWidth / Math.max(1, maxX - minX + pad), window.innerHeight / Math.max(1, maxY - minY + pad));
      transform.scale = Math.max(0.18, Math.min(1.4, scale));
      transform.x = window.innerWidth / 2 - ((minX + maxX) / 2) * transform.scale;
      transform.y = window.innerHeight / 2 - ((minY + maxY) / 2) * transform.scale;
      draw();
    }

    function screenToWorld(point) {
      return { x: (point.x - transform.x) / transform.scale, y: (point.y - transform.y) / transform.scale };
    }

    function nearest(point) {
      const world = screenToWorld(point);
      const visible = visibleNodeSet();
      let best = null;
      let bestDistance = Infinity;
      for (const node of graph.nodes) {
        if (!visible.has(node.id)) continue;
        const distance = Math.hypot(node.x - world.x, node.y - world.y);
        if (distance < bestDistance && distance <= node.r + 8 / transform.scale) {
          best = node;
          bestDistance = distance;
        }
      }
      return best;
    }

    function renderDetails() {
      const node = selected ?? hovered;
      if (!node) {
        details.innerHTML = '<h2>Graph Overview</h2><span class="pill">Generated ' + new Date(graph.generatedAt).toLocaleString() + '</span><dl class="detail"><dt>Nodes</dt><dd>' + graph.nodes.length.toLocaleString() + '</dd><dt>Edges</dt><dd>' + graph.edges.length.toLocaleString() + '</dd><dt>Format</dt><dd>HTML, JSON, GraphML</dd></dl>';
        return;
      }
      const related = graph.edges.filter((edge) => edge.source === node.id || edge.target === node.id).slice(0, 18);
      details.innerHTML = '<h2>' + escapeHtml(node.label) + '</h2><span class="pill"><span class="swatch" style="background:' + colors[node.type] + '"></span>' + title(node.type) + '</span><dl class="detail"><dt>Subtitle</dt><dd>' + escapeHtml(node.subtitle || "") + '</dd><dt>Degree</dt><dd>' + node.degree + '</dd><dt>ID</dt><dd>' + escapeHtml(node.id) + '</dd><dt>Links</dt><dd>' + related.map((edge) => escapeHtml(edge.label || edge.type) + ' -> ' + escapeHtml((nodeById.get(edge.source === node.id ? edge.target : edge.source) || {}).label || "")).join("<br>") + '</dd></dl>';
    }

    function title(value) {
      return value.replaceAll("_", " ").replace(/\b\w/g, (char) => char.toUpperCase());
    }

    function short(value, length) {
      return value.length > length ? value.slice(0, length - 1) + "..." : value;
    }

    function escapeHtml(value) {
      return String(value ?? "").replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);
    }

    canvas.addEventListener("pointerdown", (event) => {
      dragging = true;
      last = { x: event.clientX, y: event.clientY };
      canvas.setPointerCapture(event.pointerId);
      canvas.classList.add("dragging");
    });
    canvas.addEventListener("pointermove", (event) => {
      if (dragging && last) {
        transform.x += event.clientX - last.x;
        transform.y += event.clientY - last.y;
        last = { x: event.clientX, y: event.clientY };
        draw();
        return;
      }
      const next = nearest({ x: event.clientX, y: event.clientY });
      if (next !== hovered) {
        hovered = next;
        renderDetails();
        draw();
      }
    });
    canvas.addEventListener("pointerup", (event) => {
      dragging = false;
      canvas.releasePointerCapture(event.pointerId);
      canvas.classList.remove("dragging");
      const node = nearest({ x: event.clientX, y: event.clientY });
      if (node) selected = node;
      renderDetails();
      draw();
    });
    canvas.addEventListener("wheel", (event) => {
      event.preventDefault();
      const before = screenToWorld({ x: event.clientX, y: event.clientY });
      const factor = Math.exp(-event.deltaY * 0.001);
      transform.scale = Math.max(0.08, Math.min(5, transform.scale * factor));
      transform.x = event.clientX - before.x * transform.scale;
      transform.y = event.clientY - before.y * transform.scale;
      draw();
    }, { passive: false });
    document.getElementById("fit").addEventListener("click", fit);
    document.getElementById("toggleEdges").addEventListener("click", () => { showEdges = !showEdges; draw(); });
    document.getElementById("clear").addEventListener("click", () => { search.value = ""; selected = null; fit(); renderDetails(); });
    search.addEventListener("input", () => { selected = null; draw(); renderDetails(); });
    window.addEventListener("resize", resize);
    resize();
  </script>
</body>
</html>
`
}

import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { homedir } from 'node:os'
import path from 'node:path'
import dotenv from 'dotenv'
import pg, { type PoolClient } from 'pg'
import { findRepoRoot, loadConfig } from '../config.js'

const DEFAULT_MCP_URL = 'https://mcp.linear.app/mcp'
const LINEAR_SOURCE_SLUG = 'linear'

export interface ImportLinearOptions {
  apply?: boolean
  concurrency?: number
  credentialsEnvPath?: string
  includeArchived?: boolean
  limit?: number
  mcpUrl?: string
  skipComments?: boolean
  skipRelations?: boolean
  verbose?: boolean
}

interface NormalizedOptions {
  apply: boolean
  concurrency: number
  includeArchived: boolean
  limit: number | null
  mcpUrl: string
  skipComments: boolean
  skipRelations: boolean
  verbose: boolean
}

interface LinearUser {
  id: string
  name: string
  email: string
  displayName?: string
  avatarUrl?: string
  isActive?: boolean
  isAdmin?: boolean
  isGuest?: boolean
}

interface LinearTeam {
  id: string
  name: string
  key?: string
  icon?: string | null
  color?: string | null
  description?: string | null
  archivedAt?: string | null
}

interface LinearStatus {
  id: string
  name: string
  type: string
  color?: string | null
  description?: string | null
  position?: number | null
}

interface LinearLabel {
  id: string
  name: string
  color?: string | null
  description?: string | null
}

interface LinearPriority {
  value: number
  name: string
}

interface LinearIssue {
  id: string
  title: string
  description?: string | null
  priority?: LinearPriority | null
  url?: string | null
  gitBranchName?: string | null
  createdAt?: string | null
  updatedAt?: string | null
  archivedAt?: string | null
  completedAt?: string | null
  startedAt?: string | null
  canceledAt?: string | null
  dueDate?: string | null
  slaStartedAt?: string | null
  slaMediumRiskAt?: string | null
  slaHighRiskAt?: string | null
  slaBreachesAt?: string | null
  slaType?: string | null
  status?: string | null
  statusType?: string | null
  labels?: string[]
  createdBy?: string | null
  createdById?: string | null
  assignee?: string | null
  assigneeId?: string | null
  project?: string | null
  projectId?: string | null
  team?: string | null
  teamId?: string | null
  estimate?: number | null
}

interface LinearRelationTarget {
  id: string
  title?: string
}

interface LinearIssueDetail extends LinearIssue {
  attachments?: LinearAttachment[]
  relations?: {
    blocks?: LinearRelationTarget[]
    blockedBy?: LinearRelationTarget[]
    relatedTo?: LinearRelationTarget[]
    duplicateOf?: LinearRelationTarget | null
  }
}

interface LinearProject {
  id: string
  name: string
  summary?: string | null
  description?: string | null
  icon?: string | null
  color?: string | null
  url?: string | null
  createdAt?: string | null
  updatedAt?: string | null
  startedAt?: string | null
  completedAt?: string | null
  canceledAt?: string | null
  startDate?: string | null
  targetDate?: string | null
  priority?: LinearPriority | null
  lead?: Partial<LinearUser> | null
  status?: {
    id?: string
    name?: string
    type?: string
  } | null
  teams?: Array<Pick<LinearTeam, 'id' | 'name' | 'key'>>
  members?: LinearUser[]
}

interface LinearComment {
  id: string
  body: string
  createdAt?: string | null
  updatedAt?: string | null
  author?: Partial<LinearUser> | string | null
}

interface LinearAttachment {
  id?: string
  title?: string | null
  subtitle?: string | null
  url?: string | null
  contentType?: string | null
}

interface LinearInventory {
  users: LinearUser[]
  teams: LinearTeam[]
  statusesByTeamId: Map<string, LinearStatus[]>
  labels: LinearLabel[]
  projects: LinearProject[]
  issues: LinearIssueDetail[]
  commentsByIssueId: Map<string, LinearComment[]>
}

interface ImportStats {
  attachments: number
  comments: number
  labels: number
  projects: number
  relations: number
  statuses: number
  taggings: number
  tasks: number
  teams: number
  users: number
}

interface IdMaps {
  internalUsers: Map<string, string>
  taskTeams: Map<string, string>
  taskStatuses: Map<string, string>
  taskProjects: Map<string, string>
  tasks: Map<string, string>
  tags: Map<string, string>
}

interface McpResponse {
  jsonrpc: string
  id?: number
  result?: unknown
  error?: unknown
}

interface McpToolResult {
  content?: Array<{ text?: string }>
}

export async function importLinear(
  options: ImportLinearOptions = {},
): Promise<void> {
  const repoRoot = findRepoRoot()
  loadEnvironment(repoRoot, options.credentialsEnvPath)

  const normalized = normalizeOptions(options)
  const mcp = new LinearMcpClient(normalized)
  let pool: pg.Pool | null = null

  try {
    await mcp.connect()
    const inventory = await fetchInventory(mcp, normalized)
    const stats = summarizeInventory(inventory)

    console.log(
      `${normalized.apply ? 'Applying' : 'Dry run:'} Linear import from ${normalized.mcpUrl}.`,
    )
    console.log(formatStats(stats))

    if (!normalized.apply) {
      console.log('Dry run only. Re-run with --apply to write imported data.')
      return
    }

    const databaseUrl = loadConfig({ skipDotenv: true }).databaseUrl
    pool = new pg.Pool({ connectionString: databaseUrl })
    const written = await writeInventory(pool, inventory)
    console.log(`Imported. ${formatStats(written)}`)
  } finally {
    await mcp.close()
    if (pool) {
      await pool.end()
    }
  }
}

function loadEnvironment(repoRoot: string, credentialsEnvPath?: string): void {
  dotenv.config({ path: path.join(repoRoot, '.env'), override: false })

  if (process.env.DATABASE_URL) {
    return
  }

  const credentialPaths = [
    credentialsEnvPath,
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
  ].filter((p): p is string => Boolean(p))

  for (const credentialPath of credentialPaths) {
    dotenv.config({ path: credentialPath, override: false })
    if (process.env.DATABASE_URL) {
      break
    }
  }
}

function normalizeOptions(options: ImportLinearOptions): NormalizedOptions {
  return {
    apply: Boolean(options.apply),
    concurrency: positiveInteger(options.concurrency, 6),
    includeArchived: options.includeArchived !== false,
    limit:
      options.limit === undefined || options.limit === null
        ? null
        : positiveInteger(options.limit, 0),
    mcpUrl: options.mcpUrl ?? DEFAULT_MCP_URL,
    skipComments: Boolean(options.skipComments),
    skipRelations: Boolean(options.skipRelations),
    verbose: Boolean(options.verbose),
  }
}

async function fetchInventory(
  mcp: LinearMcpClient,
  options: NormalizedOptions,
): Promise<LinearInventory> {
  const [usersResult, teamsResult, labelsResult, issuesResult] =
    await Promise.all([
      mcp.callTool<{ users?: LinearUser[] }>('list_users', { limit: 250 }),
      mcp.callTool<{ teams?: LinearTeam[] }>('list_teams', {
        limit: 250,
        includeArchived: options.includeArchived,
      }),
      mcp.callTool<{ labels?: LinearLabel[] }>('list_issue_labels', {
        limit: 250,
      }),
      mcp.callTool<{ issues?: LinearIssue[] }>('list_issues', {
        limit: options.limit ?? 250,
        includeArchived: options.includeArchived,
        orderBy: 'updatedAt',
      }),
    ])

  const users = usersResult.users ?? []
  const teams = teamsResult.teams ?? []
  const labels = labelsResult.labels ?? []
  const listedIssues = (issuesResult.issues ?? []).slice(
    0,
    options.limit ?? undefined,
  )

  const statusesEntries = await mapLimit(teams, options.concurrency, async (t) => {
    const result = await mcp.callTool<LinearStatus[] | { statuses?: LinearStatus[] }>(
      'list_issue_statuses',
      { team: t.id },
    )
    return [t.id, Array.isArray(result) ? result : result.statuses ?? []] as const
  })
  const statusesByTeamId = new Map<string, LinearStatus[]>(statusesEntries)

  const details = await mapLimit(
    listedIssues,
    options.concurrency,
    async (issue, index) => {
      if (options.verbose && index % 25 === 0) {
        console.log(`Fetched issue detail ${index + 1}/${listedIssues.length}`)
      }
      return mcp.callTool<LinearIssueDetail>('get_issue', {
        id: issue.id,
        includeRelations: !options.skipRelations,
        includeCustomerNeeds: false,
      })
    },
  )

  const commentsByIssueId = new Map<string, LinearComment[]>()
  if (!options.skipComments) {
    const commentEntries = await mapLimit(
      details,
      options.concurrency,
      async (issue, index) => {
        if (options.verbose && index % 25 === 0) {
          console.log(`Fetched comments ${index + 1}/${details.length}`)
        }
        const result = await mcp.callTool<{ comments?: LinearComment[] }>(
          'list_comments',
          { issueId: issue.id, limit: 250 },
        )
        return [issue.id, result.comments ?? []] as const
      },
    )
    for (const [issueId, comments] of commentEntries) {
      commentsByIssueId.set(issueId, comments)
    }
  }

  const projectRefs = uniqueBy(
    details
      .filter((issue) => issue.projectId && issue.project)
      .map((issue) => ({ id: requireString(issue.projectId), name: issue.project })),
    (project) => project.id,
  )

  const projects = await mapLimit(
    projectRefs,
    options.concurrency,
    async (project) =>
      mcp.callTool<LinearProject>('get_project', {
        query: project.id,
        includeMilestones: false,
        includeMembers: true,
        includeResources: false,
      }),
  )

  return {
    users,
    teams,
    statusesByTeamId,
    labels,
    projects,
    issues: details,
    commentsByIssueId,
  }
}

async function writeInventory(
  pool: pg.Pool,
  inventory: LinearInventory,
): Promise<ImportStats> {
  const client = await pool.connect()
  const maps: IdMaps = {
    internalUsers: new Map(),
    taskTeams: new Map(),
    taskStatuses: new Map(),
    taskProjects: new Map(),
    tasks: new Map(),
    tags: new Map(),
  }
  const stats = emptyStats()

  try {
    await client.query('begin')
    const sourceId = await ensureLinearSource(client)

    for (const user of inventory.users) {
      maps.internalUsers.set(user.id, await upsertInternalUser(client, sourceId, user))
      stats.users += 1
    }

    for (const team of inventory.teams) {
      maps.taskTeams.set(team.id, await upsertTaskTeam(client, sourceId, team))
      stats.teams += 1
    }

    for (const [teamSourceId, statuses] of inventory.statusesByTeamId) {
      const teamId = maps.taskTeams.get(teamSourceId)
      if (!teamId) {
        continue
      }
      for (const status of statuses) {
        maps.taskStatuses.set(
          statusKey(teamSourceId, status.name),
          await upsertTaskStatus(client, sourceId, teamId, status),
        )
        stats.statuses += 1
      }
    }

    for (const project of inventory.projects) {
      maps.taskProjects.set(
        project.id,
        await upsertTaskProject(client, sourceId, project, maps),
      )
      stats.projects += 1
    }

    for (const project of inventory.projects) {
      await upsertTaskProjectTeams(client, project, maps)
    }

    for (const label of inventory.labels) {
      maps.tags.set(label.name, await upsertTag(client, label))
      stats.labels += 1
    }

    for (const issue of inventory.issues) {
      maps.tasks.set(issue.id, await upsertTask(client, sourceId, issue, maps))
      stats.tasks += 1
    }

    for (const issue of inventory.issues) {
      stats.taggings += await upsertTaskTags(client, sourceId, issue, maps)
      stats.attachments += await upsertTaskAttachments(client, sourceId, issue, maps)
      stats.comments += await upsertTaskComments(
        client,
        sourceId,
        issue,
        inventory.commentsByIssueId.get(issue.id) ?? [],
        maps,
      )
    }

    for (const issue of inventory.issues) {
      stats.relations += await upsertTaskRelations(client, sourceId, issue, maps)
    }

    await client.query('commit')
    return stats
  } catch (err) {
    await client.query('rollback')
    throw err
  } finally {
    client.release()
  }
}

async function ensureLinearSource(client: PoolClient): Promise<string> {
  const result = await client.query<{ id: string }>(
    `
      insert into sources (slug, name, description)
      values ($1, 'Linear', 'Tasks, projects, comments, labels, and workflow states sourced from Linear.')
      on conflict (slug) do update
        set name = excluded.name,
            description = excluded.description
      returning id::text
    `,
    [LINEAR_SOURCE_SLUG],
  )
  return requireRowId(result.rows[0], 'linear source')
}

async function upsertInternalUser(
  client: PoolClient,
  sourceId: string,
  user: LinearUser,
): Promise<string> {
  const result = await client.query<{ id: string }>(
    `
      insert into team_members (
        name,
        title,
        email,
        avatar_url,
        is_active,
        is_bot,
        source_id,
        source_external_id,
        metadata
      )
      values ($1, $2, $3::citext, $4, $5, $6, $7::uuid, $8, $9::jsonb)
      on conflict (email) do update
        set name = excluded.name,
            avatar_url = excluded.avatar_url,
            is_active = excluded.is_active,
            is_bot = excluded.is_bot,
            source_id = excluded.source_id,
            source_external_id = excluded.source_external_id,
            metadata = excluded.metadata
      returning id::text
    `,
    [
      user.displayName ?? user.name,
      null,
      user.email,
      user.avatarUrl ?? null,
      user.isActive !== false,
      user.email.endsWith('@linear.linear.app') || user.name === 'Linear',
      sourceId,
      user.id,
      JSON.stringify({
        linearName: user.name,
        displayName: user.displayName ?? null,
        isAdmin: user.isAdmin ?? null,
        isGuest: user.isGuest ?? null,
      }),
    ],
  )
  return requireRowId(result.rows[0], `team member ${user.email}`)
}

async function upsertTaskTeam(
  client: PoolClient,
  sourceId: string,
  team: LinearTeam,
): Promise<string> {
  const result = await client.query<{ id: string }>(
    `
      insert into task_teams (
        name,
        key,
        description,
        icon,
        color,
        source_id,
        source_external_id,
        metadata,
        archived_at
      )
      values ($1, $2, $3, $4, $5, $6::uuid, $7, $8::jsonb, $9::timestamptz)
      on conflict (source_id, source_external_id) where source_external_id is not null
        do update set
          name = excluded.name,
          key = excluded.key,
          description = excluded.description,
          icon = excluded.icon,
          color = excluded.color,
          metadata = excluded.metadata,
          archived_at = excluded.archived_at
      returning id::text
    `,
    [
      team.name,
      team.key ?? null,
      team.description ?? null,
      team.icon ?? null,
      team.color ?? null,
      sourceId,
      team.id,
      JSON.stringify({ linear: team }),
      team.archivedAt ?? null,
    ],
  )
  return requireRowId(result.rows[0], `task team ${team.name}`)
}

async function upsertTaskStatus(
  client: PoolClient,
  sourceId: string,
  teamId: string,
  status: LinearStatus,
): Promise<string> {
  const result = await client.query<{ id: string }>(
    `
      insert into task_statuses (
        team_id,
        name,
        status_type,
        position,
        color,
        description,
        source_id,
        source_external_id,
        metadata
      )
      values ($1::uuid, $2, $3, $4, $5, $6, $7::uuid, $8, $9::jsonb)
      on conflict (source_id, source_external_id) where source_external_id is not null
        do update set
          team_id = excluded.team_id,
          name = excluded.name,
          status_type = excluded.status_type,
          position = excluded.position,
          color = excluded.color,
          description = excluded.description,
          metadata = excluded.metadata
      returning id::text
    `,
    [
      teamId,
      status.name,
      normalizeStatusType(status.type),
      status.position ?? null,
      status.color ?? null,
      status.description ?? null,
      sourceId,
      status.id,
      JSON.stringify({ linear: status }),
    ],
  )
  return requireRowId(result.rows[0], `task status ${status.name}`)
}

async function upsertTaskProject(
  client: PoolClient,
  sourceId: string,
  project: LinearProject,
  maps: IdMaps,
): Promise<string> {
  const result = await client.query<{ id: string }>(
    `
      insert into task_projects (
        name,
        summary,
        description,
        icon,
        color,
        status_name,
        status_type,
        priority_value,
        priority_label,
        lead_member_id,
        start_date,
        target_date,
        started_at,
        completed_at,
        canceled_at,
        source_id,
        source_external_id,
        source_url,
        metadata
      )
      values (
        $1, $2, $3, $4, $5, $6, $7, $8, $9, $10::uuid, $11::date, $12::date,
        $13::timestamptz, $14::timestamptz, $15::timestamptz, $16::uuid, $17,
        $18, $19::jsonb
      )
      on conflict (source_id, source_external_id) where source_external_id is not null
        do update set
          name = excluded.name,
          summary = excluded.summary,
          description = excluded.description,
          icon = excluded.icon,
          color = excluded.color,
          status_name = excluded.status_name,
          status_type = excluded.status_type,
          priority_value = excluded.priority_value,
          priority_label = excluded.priority_label,
          lead_member_id = excluded.lead_member_id,
          start_date = excluded.start_date,
          target_date = excluded.target_date,
          started_at = excluded.started_at,
          completed_at = excluded.completed_at,
          canceled_at = excluded.canceled_at,
          source_url = excluded.source_url,
          metadata = excluded.metadata,
          archived_at = null
      returning id::text
    `,
    [
      project.name,
      project.summary ?? null,
      project.description ?? null,
      project.icon ?? null,
      project.color ?? null,
      project.status?.name ?? null,
      normalizeProjectStatusType(project.status?.type ?? null),
      project.priority?.value ?? 0,
      project.priority?.name ?? null,
      findInternalUserId(maps, project.lead),
      project.startDate ?? null,
      project.targetDate ?? null,
      project.startedAt ?? null,
      project.completedAt ?? null,
      project.canceledAt ?? null,
      sourceId,
      project.id,
      project.url ?? null,
      JSON.stringify({ linear: project }),
    ],
  )
  return requireRowId(result.rows[0], `task project ${project.name}`)
}

async function upsertTaskProjectTeams(
  client: PoolClient,
  project: LinearProject,
  maps: IdMaps,
): Promise<void> {
  const projectId = maps.taskProjects.get(project.id)
  if (!projectId) {
    return
  }
  for (const team of project.teams ?? []) {
    const teamId = maps.taskTeams.get(team.id)
    if (!teamId) {
      continue
    }
    await client.query(
      `
        insert into task_project_teams (project_id, team_id)
        values ($1::uuid, $2::uuid)
        on conflict (project_id, team_id) do nothing
      `,
      [projectId, teamId],
    )
  }
}

async function upsertTag(
  client: PoolClient,
  label: LinearLabel,
): Promise<string> {
  const slug = `linear:${slugify(label.name)}`
  const result = await client.query<{ id: string }>(
    `
      insert into tags (slug, label, description, color)
      values ($1, $2, $3, $4)
      on conflict (slug) do update
        set label = excluded.label,
            description = excluded.description,
            color = excluded.color
      returning id::text
    `,
    [slug, label.name, label.description ?? null, label.color ?? null],
  )
  return requireRowId(result.rows[0], `tag ${label.name}`)
}

async function upsertTask(
  client: PoolClient,
  sourceId: string,
  issue: LinearIssueDetail,
  maps: IdMaps,
): Promise<string> {
  const result = await client.query<{ id: string }>(
    `
      insert into tasks (
        team_id,
        status_id,
        project_id,
        creator_member_id,
        assignee_member_id,
        title,
        description,
        priority_value,
        priority_label,
        estimate,
        due_date,
        started_at,
        completed_at,
        canceled_at,
        source_created_at,
        source_updated_at,
        source_id,
        source_external_id,
        source_identifier,
        source_number,
        source_url,
        git_branch_name,
        sla_started_at,
        sla_medium_risk_at,
        sla_high_risk_at,
        sla_breaches_at,
        sla_type,
        metadata,
        archived_at
      )
      values (
        $1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6, $7, $8, $9, $10,
        $11::date, $12::timestamptz, $13::timestamptz, $14::timestamptz,
        $15::timestamptz, $16::timestamptz, $17::uuid, $18, $19, $20, $21, $22,
        $23::timestamptz, $24::timestamptz, $25::timestamptz, $26::timestamptz,
        $27, $28::jsonb, $29::timestamptz
      )
      on conflict (source_id, source_external_id) where source_external_id is not null
        do update set
          team_id = excluded.team_id,
          status_id = excluded.status_id,
          project_id = excluded.project_id,
          creator_member_id = excluded.creator_member_id,
          assignee_member_id = excluded.assignee_member_id,
          title = excluded.title,
          description = excluded.description,
          priority_value = excluded.priority_value,
          priority_label = excluded.priority_label,
          estimate = excluded.estimate,
          due_date = excluded.due_date,
          started_at = excluded.started_at,
          completed_at = excluded.completed_at,
          canceled_at = excluded.canceled_at,
          source_created_at = excluded.source_created_at,
          source_updated_at = excluded.source_updated_at,
          source_identifier = excluded.source_identifier,
          source_number = excluded.source_number,
          source_url = excluded.source_url,
          git_branch_name = excluded.git_branch_name,
          sla_started_at = excluded.sla_started_at,
          sla_medium_risk_at = excluded.sla_medium_risk_at,
          sla_high_risk_at = excluded.sla_high_risk_at,
          sla_breaches_at = excluded.sla_breaches_at,
          sla_type = excluded.sla_type,
          metadata = excluded.metadata,
          archived_at = excluded.archived_at
      returning id::text
    `,
    [
      findRequiredMapValue(maps.taskTeams, issue.teamId, `team for ${issue.id}`),
      maps.taskStatuses.get(statusKey(requireString(issue.teamId), issue.status ?? '')),
      issue.projectId ? maps.taskProjects.get(issue.projectId) ?? null : null,
      issue.createdById ? maps.internalUsers.get(issue.createdById) ?? null : null,
      issue.assigneeId ? maps.internalUsers.get(issue.assigneeId) ?? null : null,
      issue.title,
      issue.description ?? null,
      issue.priority?.value ?? 0,
      issue.priority?.name ?? null,
      issue.estimate ?? null,
      issue.dueDate ?? null,
      issue.startedAt ?? null,
      issue.completedAt ?? null,
      issue.canceledAt ?? null,
      issue.createdAt ?? null,
      issue.updatedAt ?? null,
      sourceId,
      issue.id,
      issue.id,
      parseIssueNumber(issue.id),
      issue.url ?? null,
      issue.gitBranchName ?? null,
      issue.slaStartedAt ?? null,
      issue.slaMediumRiskAt ?? null,
      issue.slaHighRiskAt ?? null,
      issue.slaBreachesAt ?? null,
      issue.slaType ?? null,
      JSON.stringify({
        linear: {
          status: issue.status ?? null,
          statusType: issue.statusType ?? null,
          labels: issue.labels ?? [],
          createdBy: issue.createdBy ?? null,
          assignee: issue.assignee ?? null,
          project: issue.project ?? null,
          team: issue.team ?? null,
        },
      }),
      issue.archivedAt ?? null,
    ],
  )
  return requireRowId(result.rows[0], `task ${issue.id}`)
}

async function upsertTaskTags(
  client: PoolClient,
  sourceId: string,
  issue: LinearIssueDetail,
  maps: IdMaps,
): Promise<number> {
  const taskId = maps.tasks.get(issue.id)
  if (!taskId) {
    return 0
  }
  let count = 0
  for (const label of issue.labels ?? []) {
    const tagId = maps.tags.get(label)
    if (!tagId) {
      continue
    }
    await client.query(
      `
        insert into taggings (tag_id, target_type, target_id, source_id)
        values ($1::uuid, 'task', $2::uuid, $3::uuid)
        on conflict (tag_id, target_type, target_id) do nothing
      `,
      [tagId, taskId, sourceId],
    )
    count += 1
  }
  return count
}

async function upsertTaskAttachments(
  client: PoolClient,
  sourceId: string,
  issue: LinearIssueDetail,
  maps: IdMaps,
): Promise<number> {
  const taskId = maps.tasks.get(issue.id)
  if (!taskId) {
    return 0
  }
  let count = 0
  for (const [index, attachment] of (issue.attachments ?? []).entries()) {
    const sourceExternalId = attachment.id ?? `${issue.id}:attachment:${index}`
    await client.query(
      `
        insert into task_attachments (
          task_id,
          title,
          subtitle,
          url,
          content_type,
          source_id,
          source_external_id,
          source_url,
          metadata
        )
        values ($1::uuid, $2, $3, $4, $5, $6::uuid, $7, $8, $9::jsonb)
        on conflict (source_id, source_external_id) where source_external_id is not null
          do update set
            task_id = excluded.task_id,
            title = excluded.title,
            subtitle = excluded.subtitle,
            url = excluded.url,
            content_type = excluded.content_type,
            source_url = excluded.source_url,
            metadata = excluded.metadata,
            archived_at = null
      `,
      [
        taskId,
        attachment.title ?? null,
        attachment.subtitle ?? null,
        attachment.url ?? null,
        attachment.contentType ?? null,
        sourceId,
        sourceExternalId,
        attachment.url ?? null,
        JSON.stringify({ linear: attachment }),
      ],
    )
    count += 1
  }
  return count
}

async function upsertTaskComments(
  client: PoolClient,
  sourceId: string,
  issue: LinearIssueDetail,
  comments: LinearComment[],
  maps: IdMaps,
): Promise<number> {
  const taskId = maps.tasks.get(issue.id)
  if (!taskId) {
    return 0
  }
  let count = 0
  for (const [index, comment] of comments.entries()) {
    const sourceExternalId = comment.id || `${issue.id}:comment:${index}`
    await client.query(
      `
        insert into task_comments (
          task_id,
          author_member_id,
          body,
          source_id,
          source_external_id,
          source_created_at,
          source_updated_at,
          metadata
        )
        values ($1::uuid, $2::uuid, $3, $4::uuid, $5, $6::timestamptz, $7::timestamptz, $8::jsonb)
        on conflict (source_id, source_external_id) where source_external_id is not null
          do update set
            task_id = excluded.task_id,
            author_member_id = excluded.author_member_id,
            body = excluded.body,
            source_created_at = excluded.source_created_at,
            source_updated_at = excluded.source_updated_at,
            metadata = excluded.metadata,
            archived_at = null
      `,
      [
        taskId,
        findInternalUserId(maps, comment.author),
        comment.body,
        sourceId,
        sourceExternalId,
        comment.createdAt ?? null,
        comment.updatedAt ?? null,
        JSON.stringify({ linear: comment }),
      ],
    )
    count += 1
  }
  return count
}

async function upsertTaskRelations(
  client: PoolClient,
  sourceId: string,
  issue: LinearIssueDetail,
  maps: IdMaps,
): Promise<number> {
  const relations = issue.relations
  const taskId = maps.tasks.get(issue.id)
  if (!relations || !taskId) {
    return 0
  }

  let count = 0
  const inputs: Array<{ type: string; target: LinearRelationTarget }> = [
    ...(relations.blocks ?? []).map((target) => ({ type: 'blocks', target })),
    ...(relations.blockedBy ?? []).map((target) => ({
      type: 'blocked_by',
      target,
    })),
    ...(relations.relatedTo ?? []).map((target) => ({ type: 'related', target })),
  ]
  if (relations.duplicateOf) {
    inputs.push({ type: 'duplicate', target: relations.duplicateOf })
  }

  for (const input of inputs) {
    const relatedTaskId = maps.tasks.get(input.target.id)
    if (!relatedTaskId) {
      continue
    }
    await client.query(
      `
        insert into task_relations (
          task_id,
          related_task_id,
          relation_type,
          source_id,
          metadata
        )
        values ($1::uuid, $2::uuid, $3, $4::uuid, $5::jsonb)
        on conflict (task_id, related_task_id, relation_type) where archived_at is null
          do update set
            source_id = excluded.source_id,
            metadata = excluded.metadata
      `,
      [
        taskId,
        relatedTaskId,
        input.type,
        sourceId,
        JSON.stringify({ linear: input.target }),
      ],
    )
    count += 1
  }

  return count
}

class LinearMcpClient {
  private child: ChildProcessWithoutNullStreams | null = null
  private buffer = ''
  private nextId = 1
  private readonly pending = new Map<
    number,
    {
      reject: (reason?: unknown) => void
      resolve: (value: unknown) => void
      timer: NodeJS.Timeout
    }
  >()

  constructor(private readonly options: NormalizedOptions) {}

  async connect(): Promise<void> {
    this.child = spawn('npx', ['-y', 'mcp-remote', this.options.mcpUrl], {
      stdio: ['pipe', 'pipe', 'pipe'],
    })

    this.child.stdout.on('data', (chunk: Buffer) => {
      this.handleStdout(chunk.toString())
    })

    this.child.stderr.on('data', (chunk: Buffer) => {
      if (this.options.verbose) {
        process.stderr.write(chunk)
      }
    })

    this.child.on('exit', () => {
      for (const [id, pending] of this.pending) {
        clearTimeout(pending.timer)
        pending.reject(new Error(`Linear MCP server exited before response ${id}`))
      }
      this.pending.clear()
    })

    await this.request('initialize', {
      protocolVersion: '2024-11-05',
      capabilities: {},
      clientInfo: {
        name: 'picardo-linear-import',
        version: '0.1.0',
      },
    })
    this.notify('notifications/initialized', {})
  }

  async close(): Promise<void> {
    if (!this.child) {
      return
    }
    this.child.kill()
    this.child = null
  }

  async callTool<T>(name: string, args: Record<string, unknown> = {}): Promise<T> {
    const result = (await this.request('tools/call', {
      name,
      arguments: args,
    })) as McpToolResult
    return parseToolResult<T>(result)
  }

  private request(method: string, params: unknown): Promise<unknown> {
    const child = this.requireChild()
    const id = this.nextId++
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n')

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`Timed out waiting for Linear MCP ${method}`))
      }, 90_000)
      this.pending.set(id, { resolve, reject, timer })
    })
  }

  private notify(method: string, params: unknown): void {
    this.requireChild().stdin.write(
      JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n',
    )
  }

  private handleStdout(chunk: string): void {
    this.buffer += chunk
    while (this.buffer.includes('\n')) {
      const idx = this.buffer.indexOf('\n')
      const line = this.buffer.slice(0, idx).trim()
      this.buffer = this.buffer.slice(idx + 1)
      if (!line) {
        continue
      }
      const message = JSON.parse(line) as McpResponse
      if (message.id === undefined) {
        continue
      }
      const pending = this.pending.get(message.id)
      if (!pending) {
        continue
      }
      this.pending.delete(message.id)
      clearTimeout(pending.timer)
      if (message.error) {
        pending.reject(new Error(JSON.stringify(message.error)))
      } else {
        pending.resolve(message.result)
      }
    }
  }

  private requireChild(): ChildProcessWithoutNullStreams {
    if (!this.child) {
      throw new Error('Linear MCP client is not connected.')
    }
    return this.child
  }
}

function parseToolResult<T>(result: McpToolResult): T {
  const text = result.content?.map((item) => item.text ?? '').join('\n') ?? ''
  if (!text) {
    return {} as T
  }
  return JSON.parse(text) as T
}

async function mapLimit<T, U>(
  items: T[],
  limit: number,
  fn: (item: T, index: number) => Promise<U>,
): Promise<U[]> {
  const output: U[] = new Array<U>(items.length)
  let cursor = 0
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (cursor < items.length) {
        const index = cursor
        cursor += 1
        output[index] = await fn(items[index] as T, index)
      }
    }),
  )
  return output
}

function summarizeInventory(inventory: LinearInventory): ImportStats {
  const relationCount = inventory.issues.reduce(
    (total, issue) =>
      total +
      (issue.relations?.blocks?.length ?? 0) +
      (issue.relations?.blockedBy?.length ?? 0) +
      (issue.relations?.relatedTo?.length ?? 0) +
      (issue.relations?.duplicateOf ? 1 : 0),
    0,
  )
  return {
    users: inventory.users.length,
    teams: inventory.teams.length,
    statuses: [...inventory.statusesByTeamId.values()].reduce(
      (total, statuses) => total + statuses.length,
      0,
    ),
    labels: inventory.labels.length,
    projects: inventory.projects.length,
    tasks: inventory.issues.length,
    comments: [...inventory.commentsByIssueId.values()].reduce(
      (total, comments) => total + comments.length,
      0,
    ),
    attachments: inventory.issues.reduce(
      (total, issue) => total + (issue.attachments?.length ?? 0),
      0,
    ),
    relations: relationCount,
    taggings: inventory.issues.reduce(
      (total, issue) => total + (issue.labels?.length ?? 0),
      0,
    ),
  }
}

function emptyStats(): ImportStats {
  return {
    attachments: 0,
    comments: 0,
    labels: 0,
    projects: 0,
    relations: 0,
    statuses: 0,
    taggings: 0,
    tasks: 0,
    teams: 0,
    users: 0,
  }
}

function formatStats(stats: ImportStats): string {
  return [
    `users=${stats.users}`,
    `teams=${stats.teams}`,
    `statuses=${stats.statuses}`,
    `labels=${stats.labels}`,
    `projects=${stats.projects}`,
    `tasks=${stats.tasks}`,
    `comments=${stats.comments}`,
    `attachments=${stats.attachments}`,
    `relations=${stats.relations}`,
    `taggings=${stats.taggings}`,
  ].join(' ')
}

function findInternalUserId(
  maps: IdMaps,
  user: Partial<LinearUser> | string | null | undefined,
): string | null {
  if (!user || typeof user === 'string') {
    return null
  }
  if (user.id && maps.internalUsers.has(user.id)) {
    return maps.internalUsers.get(user.id) ?? null
  }
  if (user.email) {
    for (const [sourceId, id] of maps.internalUsers) {
      if (sourceId === user.email) {
        return id
      }
    }
  }
  return null
}

function findRequiredMapValue(
  map: Map<string, string>,
  key: string | null | undefined,
  label: string,
): string {
  if (!key) {
    throw new Error(`Missing ${label}.`)
  }
  const value = map.get(key)
  if (!value) {
    throw new Error(`Could not resolve ${label}: ${key}`)
  }
  return value
}

function statusKey(teamId: string, statusName: string): string {
  return `${teamId}:${statusName.toLowerCase()}`
}

function normalizeStatusType(type: string): string {
  if (['backlog', 'unstarted', 'started', 'completed', 'canceled'].includes(type)) {
    return type
  }
  return 'backlog'
}

function normalizeProjectStatusType(type: string | null): string | null {
  if (!type) {
    return null
  }
  if (
    ['backlog', 'planned', 'started', 'paused', 'completed', 'canceled'].includes(
      type,
    )
  ) {
    return type
  }
  return null
}

function parseIssueNumber(identifier: string): number | null {
  const match = identifier.match(/-(\d+)$/)
  return match ? Number.parseInt(match[1] as string, 10) : null
}

function slugify(value: string): string {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
}

function uniqueBy<T>(items: T[], keyFn: (item: T) => string): T[] {
  const seen = new Set<string>()
  const output: T[] = []
  for (const item of items) {
    const key = keyFn(item)
    if (seen.has(key)) {
      continue
    }
    seen.add(key)
    output.push(item)
  }
  return output
}

function positiveInteger(value: number | undefined, fallback: number): number {
  if (value === undefined || !Number.isFinite(value) || value < 1) {
    return fallback
  }
  return Math.floor(value)
}

function requireString(value: string | null | undefined): string {
  if (!value) {
    throw new Error('Expected string value.')
  }
  return value
}

function requireRowId(row: { id: string } | undefined, label: string): string {
  if (!row?.id) {
    throw new Error(`Failed to upsert ${label}.`)
  }
  return row.id
}

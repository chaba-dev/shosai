import type { PluginAPI } from '@ampcode/plugin'

export const description = 'Queue Shosai production promotions and approve exact Play deployments in Amp.'

const repo = '/repos/chaba-dev/shosai'
const actions = `${repo}/actions`
const workflow = {
  internal: { path: '.github/workflows/ci.yml', event: 'push', environment: 'PLAY_INTERNAL' },
  production: { path: '.github/workflows/play-production.yml', event: 'workflow_dispatch', environment: 'PLAY_PRODUCTION' },
} as const
type Track = keyof typeof workflow

function versionCode(value: unknown): string {
  if (typeof value !== 'string' || !/^[1-9][0-9]{0,9}$/.test(value) || Number(value) > 2100000000) {
    throw new Error('Expected a Play version code from 1 to 2100000000.')
  }
  return value
}

async function github(path: string, signal: AbortSignal, token?: string, body?: object) {
  signal.throwIfAborted()
  const response = await fetch(`https://api.github.com${path}`, {
    signal,
    redirect: 'error',
    headers: {
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2026-03-10',
      ...(token && { Authorization: `Bearer ${token}` }),
      ...(body && { 'Content-Type': 'application/json' }),
    },
    ...(body && { method: 'POST', body: JSON.stringify(body) }),
  })
  if (!response.ok) throw new Error(`GitHub returned HTTP ${response.status}. For a write, inspect the run before retrying.`)
  return response.status === 204 ? null : response.json()
}

async function pendingDeployment(runId: number, track: Track, token: string | undefined, signal: AbortSignal) {
  const base = `${actions}/runs/${runId}`
  const policy = workflow[track]
  const run = await github(base, signal, token)
  if (run.id !== runId || run.path !== policy.path || run.event !== policy.event || run.head_branch !== 'main'
    || run.head_repository?.id !== 1194321001 || !/^[0-9a-f]{40}$/.test(run.head_sha)
    || !Number.isSafeInteger(run.run_attempt) || run.run_attempt < 1) {
    throw new Error('This is not an eligible Shosai main-branch release run.')
  }
  // Public run data identifies the candidate. Only authenticated pending-deployment data authorizes approval.
  let environmentId: number | undefined
  if (token) {
    const pending = await github(`${base}/pending_deployments`, signal, token)
    const environment = pending.find((item: { environment: { name: string } }) => item.environment.name === policy.environment)
    if (!environment?.current_user_can_approve || !Number.isSafeInteger(environment.environment.id)) {
      throw new Error(`Your GitHub account cannot approve this pending ${policy.environment} deployment.`)
    }
    environmentId = environment.environment.id
  }

  let code: string
  if (track === 'internal') {
    const jobs = await github(`${base}/attempts/${run.run_attempt}/jobs?per_page=100`, signal, token)
    const matching = jobs.jobs.flatMap((job: { name: string }) => {
      const match = /^play-internal \/ Upload to Play internal \(version ([0-9]+)\)$/.exec(job.name)
      return match ? [match[1]] : []
    })
    if (matching.length !== 1) throw new Error('No unique signed internal bundle is ready in this run attempt.')
    code = versionCode(matching[0])
  } else {
    code = versionCode(/^Promote Shosai to Play production \(version ([0-9]+)\)$/.exec(run.display_title)?.[1])
  }
  return { code, sha: run.head_sha, attempt: run.run_attempt, environmentId }
}

const tokenField = {
  name: 'github_token', label: 'GitHub token for your reviewer account (private input)', value: '', secret: true,
}

export default function (amp: PluginAPI) {
  amp.registerTool({
    name: 'shosai_queue_play_production',
    description: 'Queue a Shosai production promotion for an explicit internal Play version code. It still needs separate approval.',
    inputSchema: {
      type: 'object', required: ['version_code'], additionalProperties: false,
      properties: { version_code: { type: 'string' } },
    },
    async execute(input, { ui, signal }) {
      const code = versionCode(input.version_code)
      const answer = await ui.confirm({
        title: 'Queue Shosai production promotion?',
        message: `Queue version **${code}** for Production. This does not publish it; you must approve the resulting deployment separately.`,
        confirmButtonText: 'Queue promotion', requireHuman: true, endTurnOnDecline: true, fields: [tokenField],
      })
      if (!answer?.github_token?.trim()) return 'No promotion queued.'
      const result = await github(`${actions}/workflows/play-production.yml/dispatches`, signal, answer.github_token.trim(), {
        ref: 'main', inputs: { version_code: code },
      })
      if (!Number.isSafeInteger(result?.workflow_run_id)) {
        return 'GitHub accepted the dispatch but did not identify its run. Find it in GitHub Actions before retrying.'
      }
      return `Queued production version ${code} in run ${result.workflow_run_id}. Wait for PLAY_PRODUCTION to request approval: https://github.com/chaba-dev/shosai/actions/runs/${result.workflow_run_id}`
    },
  })

  amp.registerTool({
    name: 'shosai_approve_play_deployment',
    description: 'Show an owner-only confirmation for one waiting Shosai GitHub Actions run, then submit its GitHub deployment approval. Does not upload directly.',
    inputSchema: {
      type: 'object', required: ['track', 'run_id'], additionalProperties: false,
      properties: { track: { type: 'string', enum: ['internal', 'production'] }, run_id: { type: 'integer', minimum: 1 } },
    },
    async execute(input, { ui, signal }) {
      const { track, run_id: runId } = input
      if ((track !== 'internal' && track !== 'production') || typeof runId !== 'number' || !Number.isSafeInteger(runId) || runId < 1) {
        throw new Error('Specify a Play track and a GitHub Actions run ID.')
      }
      const candidate = await pendingDeployment(runId, track, undefined, signal)
      const title = track === 'internal' ? 'Upload to Play Internal testing' : 'Promote to Play Production'
      const answer = await ui.confirm({
        title: `${title}?`,
        message: `Shōsai (\`dev.shosai.reader\`), version **${candidate.code}**, commit \`${candidate.sha.slice(0, 12)}\`. [Run ${runId}, attempt ${candidate.attempt}](https://github.com/chaba-dev/shosai/actions/runs/${runId}).`,
        confirmButtonText: title,
        requireHuman: true,
        endTurnOnDecline: true,
        fields: [
          { type: 'link', name: 'play', label: 'Open Play Console', value: 'https://play.google.com/console/' },
          { type: 'checkbox', name: 'clear', label: 'I checked Publishing overview for unrelated changes ready to send and coordinated with other publishers.', value: 'false' },
          tokenField,
        ],
      })
      if (answer?.clear !== 'true' || !answer.github_token?.trim()) return 'No deployment approved.'
      const token = answer.github_token.trim()
      const current = await pendingDeployment(runId, track, token, signal)
      if (current.code !== candidate.code || current.attempt !== candidate.attempt || current.sha !== candidate.sha) {
        throw new Error('The candidate changed during confirmation. No deployment approved.')
      }
      const result = await github(`${actions}/runs/${runId}/pending_deployments`, signal, token, {
        environment_ids: [current.environmentId], state: 'approved', comment: `Approved in Amp for ${track} version ${current.code}.`,
      })
      if (!Array.isArray(result) || !result.some(deployment => deployment.environment === workflow[track].environment && deployment.sha === current.sha)) {
        return `GitHub accepted the review request, but the deployment result could not be confirmed. Check run ${runId}; do not retry blindly.`
      }
      return `Approved ${track} version ${current.code}. This is not publication confirmation; check https://github.com/chaba-dev/shosai/actions/runs/${runId}`
    },
  })
}

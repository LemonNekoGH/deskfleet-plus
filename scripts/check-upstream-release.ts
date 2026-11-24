import { appendFileSync, readFileSync } from "node:fs"
import { join, resolve } from "node:path"

export const DEFAULT_UPSTREAM_REPO = "yet-another-ai/deskfleet"
export const REQUIRED_ANDROID_DAEMON_ASSET = "deskfleet-linux-arm64.tar.gz"

const STABLE_TAG_PATTERN = /^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$/u

export interface GitHubReleaseAsset {
  name: string
  size: number
  browser_download_url?: string
}

export interface GitHubRelease {
  tag_name: string
  draft: boolean
  prerelease: boolean
  html_url?: string
  published_at?: string | null
  assets?: GitHubReleaseAsset[]
}

export interface UpstreamAssetCheck {
  repo: string
  requestedTag: string
  upstreamTag: string
  assetName: string
  assetSize: number
  releaseUrl: string
}

export interface LatestUpstreamCheck {
  repo: string
  localVersion: string
  upstreamTag: string
  upstreamVersion: string
  hasLinuxArm64Asset: boolean
  needsSync: boolean
  readyToRelease: boolean
  releaseUrl: string
}

export type FetchLike = typeof fetch

export function isStableReleaseTag(tag: string): boolean {
  return STABLE_TAG_PATTERN.test(tag)
}

export function upstreamLookupTags(tag: string): string[] {
  const normalized = tag.trim()
  if (!normalized.startsWith("v")) {
    throw new Error(`Release tag must start with "v": ${tag}`)
  }
  const core = normalized.split("-", 1)[0]!
  return core === normalized ? [normalized] : [normalized, core]
}

export function findNonEmptyAsset(
  release: GitHubRelease,
  assetName = REQUIRED_ANDROID_DAEMON_ASSET,
): GitHubReleaseAsset | undefined {
  return (release.assets ?? []).find(asset => asset.name === assetName && asset.size > 0)
}

function githubHeaders(token?: string): Record<string, string> {
  const headers: Record<string, string> = {
    accept: "application/vnd.github+json",
    "x-github-api-version": "2022-11-28",
    "user-agent": "deskfleet-plus-release-sync",
  }
  if (token?.trim()) headers.authorization = `Bearer ${token.trim()}`
  return headers
}

async function fetchRelease(
  apiBase: string,
  path: string,
  token: string | undefined,
  fetchImpl: FetchLike,
): Promise<GitHubRelease | undefined> {
  const response = await fetchImpl(`${apiBase}${path}`, { headers: githubHeaders(token) })
  if (response.status === 404) return undefined
  if (!response.ok) {
    throw new Error(`GitHub API ${path} failed (${response.status}): ${await response.text()}`)
  }
  return await response.json() as GitHubRelease
}

export async function verifyUpstreamReleaseAsset(options: {
  tag: string
  repo?: string
  assetName?: string
  token?: string
  apiBase?: string
  fetchImpl?: FetchLike
}): Promise<UpstreamAssetCheck> {
  const repo = options.repo ?? DEFAULT_UPSTREAM_REPO
  const assetName = options.assetName ?? REQUIRED_ANDROID_DAEMON_ASSET
  const apiBase = (options.apiBase ?? "https://api.github.com").replace(/\/+$/u, "")
  const fetchImpl = options.fetchImpl ?? fetch
  const stableRequested = isStableReleaseTag(options.tag)
  const candidates = upstreamLookupTags(options.tag)

  for (const candidate of candidates) {
    const release = await fetchRelease(
      apiBase,
      `/repos/${repo}/releases/tags/${encodeURIComponent(candidate)}`,
      options.token,
      fetchImpl,
    )
    if (!release) continue
    if (release.draft) {
      throw new Error(`Upstream release ${repo}@${candidate} is still a draft`)
    }
    if (stableRequested && release.prerelease) {
      throw new Error(`Upstream release ${repo}@${candidate} is a prerelease, not a stable release`)
    }
    const asset = findNonEmptyAsset(release, assetName)
    if (!asset) {
      throw new Error(`Upstream release ${repo}@${candidate} is missing non-empty asset ${assetName}`)
    }
    return {
      repo,
      requestedTag: options.tag,
      upstreamTag: release.tag_name,
      assetName: asset.name,
      assetSize: asset.size,
      releaseUrl: release.html_url ?? `https://github.com/${repo}/releases/tag/${release.tag_name}`,
    }
  }

  throw new Error(
    `Upstream release not found for ${options.tag} in ${repo} (checked: ${candidates.join(", ")})`,
  )
}

export async function checkLatestUpstreamRelease(options: {
  localVersion: string
  repo?: string
  assetName?: string
  token?: string
  apiBase?: string
  fetchImpl?: FetchLike
}): Promise<LatestUpstreamCheck> {
  const repo = options.repo ?? DEFAULT_UPSTREAM_REPO
  const assetName = options.assetName ?? REQUIRED_ANDROID_DAEMON_ASSET
  const apiBase = (options.apiBase ?? "https://api.github.com").replace(/\/+$/u, "")
  const fetchImpl = options.fetchImpl ?? fetch
  const release = await fetchRelease(apiBase, `/repos/${repo}/releases/latest`, options.token, fetchImpl)
  if (!release || release.draft || release.prerelease || !isStableReleaseTag(release.tag_name)) {
    throw new Error(`No published stable release found in ${repo}`)
  }
  const upstreamVersion = release.tag_name.slice(1)
  const hasLinuxArm64Asset = Boolean(findNonEmptyAsset(release, assetName))
  const needsSync = upstreamVersion !== options.localVersion
  return {
    repo,
    localVersion: options.localVersion,
    upstreamTag: release.tag_name,
    upstreamVersion,
    hasLinuxArm64Asset,
    needsSync,
    readyToRelease: needsSync && hasLinuxArm64Asset,
    releaseUrl: release.html_url ?? `https://github.com/${repo}/releases/tag/${release.tag_name}`,
  }
}

function readLocalVersion(repoRoot: string): string {
  const pkg = JSON.parse(readFileSync(join(repoRoot, "package.json"), "utf8")) as { version?: string }
  if (!pkg.version) throw new Error("package.json is missing version")
  return pkg.version
}

async function main(): Promise<void> {
  const args = process.argv.slice(2)
  const repo = process.env.DESKFLEET_UPSTREAM_REPO ?? DEFAULT_UPSTREAM_REPO
  const token = process.env.GH_TOKEN ?? process.env.GITHUB_TOKEN
  const apiBase = process.env.GITHUB_API_URL ?? "https://api.github.com"

  const requireIndex = args.indexOf("--require-tag")
  if (requireIndex >= 0) {
    const tag = args[requireIndex + 1]
    if (!tag) throw new Error("Usage: node scripts/check-upstream-release.ts --require-tag <vX.Y.Z>")
    const result = await verifyUpstreamReleaseAsset({ tag, repo, token, apiBase })
    console.log(
      `Verified ${result.repo}@${result.upstreamTag} has ${result.assetName} (${result.assetSize} bytes)`,
    )
    return
  }

  if (args.includes("--check-latest")) {
    const repoRoot = resolve(import.meta.dirname, "..")
    const result = await checkLatestUpstreamRelease({
      localVersion: readLocalVersion(repoRoot),
      repo,
      token,
      apiBase,
    })
    if (process.env.GITHUB_OUTPUT) {
      appendFileSync(
        process.env.GITHUB_OUTPUT,
        [
          `upstream_tag=${result.upstreamTag}`,
          `upstream_version=${result.upstreamVersion}`,
          `local_version=${result.localVersion}`,
          `has_linux_arm64_asset=${result.hasLinuxArm64Asset}`,
          `needs_sync=${result.needsSync}`,
          `ready_to_release=${result.readyToRelease}`,
          "",
        ].join("\n"),
      )
    }
    console.log(JSON.stringify(result, null, 2))
    return
  }

  throw new Error(
    "Usage: node scripts/check-upstream-release.ts (--require-tag <vX.Y.Z> | --check-latest)",
  )
}

if (import.meta.main) await main()

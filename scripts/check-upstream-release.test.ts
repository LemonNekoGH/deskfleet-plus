import assert from "node:assert/strict"
import test from "node:test"
import {
  checkLatestUpstreamRelease,
  type FetchLike,
  type GitHubRelease,
  isStableReleaseTag,
  REQUIRED_ANDROID_DAEMON_ASSET,
  upstreamLookupTags,
  verifyUpstreamReleaseAsset,
} from "./check-upstream-release.ts"

function stubFetch(responses: Record<string, { status: number; body: unknown }>): FetchLike {
  return (async (input: string | URL | Request) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url
    const pathname = new URL(url).pathname
    const hit = responses[pathname]
    if (!hit) return new Response("not found", { status: 404 })
    return new Response(typeof hit.body === "string" ? hit.body : JSON.stringify(hit.body), {
      status: hit.status,
      headers: { "content-type": "application/json" },
    })
  }) as FetchLike
}

function release(overrides: Partial<GitHubRelease> = {}): GitHubRelease {
  return {
    tag_name: "v0.23.0",
    draft: false,
    prerelease: false,
    html_url: "https://github.com/yet-another-ai/deskfleet/releases/tag/v0.23.0",
    assets: [{ name: REQUIRED_ANDROID_DAEMON_ASSET, size: 12_345_678 }],
    ...overrides,
  }
}

test("stable tag detection and prerelease fallback candidates", () => {
  assert.equal(isStableReleaseTag("v0.23.0"), true)
  assert.equal(isStableReleaseTag("v1.2.3"), true)
  assert.equal(isStableReleaseTag("v0.23.0-rc.1"), false)
  assert.equal(isStableReleaseTag("0.23.0"), false)
  assert.deepEqual(upstreamLookupTags("v0.23.0"), ["v0.23.0"])
  assert.deepEqual(upstreamLookupTags("v0.23.0-plus.1"), ["v0.23.0-plus.1", "v0.23.0"])
})

test("verifyUpstreamReleaseAsset succeeds when upstream stable release includes linux-arm64 archive", async () => {
  const result = await verifyUpstreamReleaseAsset({
    tag: "v0.23.0",
    fetchImpl: stubFetch({
      "/repos/yet-another-ai/deskfleet/releases/tags/v0.23.0": { status: 200, body: release() },
    }),
  })
  assert.equal(result.upstreamTag, "v0.23.0")
  assert.equal(result.assetName, REQUIRED_ANDROID_DAEMON_ASSET)
  assert.equal(result.assetSize, 12_345_678)
})

test("verifyUpstreamReleaseAsset falls back to base upstream version for fork prereleases", async () => {
  const result = await verifyUpstreamReleaseAsset({
    tag: "v0.23.0-plus.1",
    fetchImpl: stubFetch({
      "/repos/yet-another-ai/deskfleet/releases/tags/v0.23.0": { status: 200, body: release() },
    }),
  })
  assert.equal(result.requestedTag, "v0.23.0-plus.1")
  assert.equal(result.upstreamTag, "v0.23.0")
})

test("verifyUpstreamReleaseAsset rejects missing, draft, prerelease, or asset-less upstream releases", async () => {
  await assert.rejects(
    verifyUpstreamReleaseAsset({ tag: "v0.23.0", fetchImpl: stubFetch({}) }),
    /Upstream release not found/,
  )
  await assert.rejects(
    verifyUpstreamReleaseAsset({
      tag: "v0.23.0",
      fetchImpl: stubFetch({
        "/repos/yet-another-ai/deskfleet/releases/tags/v0.23.0": { status: 200, body: release({ draft: true }) },
      }),
    }),
    /still a draft/,
  )
  await assert.rejects(
    verifyUpstreamReleaseAsset({
      tag: "v0.23.0",
      fetchImpl: stubFetch({
        "/repos/yet-another-ai/deskfleet/releases/tags/v0.23.0": { status: 200, body: release({ prerelease: true }) },
      }),
    }),
    /not a stable release/,
  )
  await assert.rejects(
    verifyUpstreamReleaseAsset({
      tag: "v0.23.0",
      fetchImpl: stubFetch({
        "/repos/yet-another-ai/deskfleet/releases/tags/v0.23.0": {
          status: 200,
          body: release({ assets: [{ name: REQUIRED_ANDROID_DAEMON_ASSET, size: 0 }] }),
        },
      }),
    }),
    /missing non-empty asset deskfleet-linux-arm64\.tar\.gz/,
  )
})

test("checkLatestUpstreamRelease reports sync readiness based on version and asset presence", async () => {
  const ready = await checkLatestUpstreamRelease({
    localVersion: "0.22.0",
    fetchImpl: stubFetch({
      "/repos/yet-another-ai/deskfleet/releases/latest": { status: 200, body: release() },
    }),
  })
  assert.equal(ready.needsSync, true)
  assert.equal(ready.hasLinuxArm64Asset, true)
  assert.equal(ready.readyToRelease, true)

  const missingAsset = await checkLatestUpstreamRelease({
    localVersion: "0.22.0",
    fetchImpl: stubFetch({
      "/repos/yet-another-ai/deskfleet/releases/latest": {
        status: 200,
        body: release({ assets: [] }),
      },
    }),
  })
  assert.equal(missingAsset.needsSync, true)
  assert.equal(missingAsset.hasLinuxArm64Asset, false)
  assert.equal(missingAsset.readyToRelease, false)

  const upToDate = await checkLatestUpstreamRelease({
    localVersion: "0.23.0",
    fetchImpl: stubFetch({
      "/repos/yet-another-ai/deskfleet/releases/latest": { status: 200, body: release() },
    }),
  })
  assert.equal(upToDate.needsSync, false)
  assert.equal(upToDate.readyToRelease, false)
})

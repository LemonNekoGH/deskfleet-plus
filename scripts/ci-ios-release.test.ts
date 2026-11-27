import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { delimiter, join } from "node:path"
import test from "node:test"

const workflow = (name: string) => readFileSync(new URL(`../.github/workflows/${name}.yml`, import.meta.url), "utf8").replace(/\r\n/g, "\n")
const job = (source: string, name: string) => source.split(`\n  ${name}:\n`)[1]?.split(/^  \w+:\n/m)[0] ?? ""
const step = (source: string, name: string) => source.split(`      - name: ${name}\n`)[1]?.split(/^      - /m)[0] ?? ""
const script = (source: string) => {
  const body = source.split("        run: |\n")[1]
  assert.ok(body, "Expected a Bash step")
  return body.split("\n").map(line => line.slice(10)).join("\n")
}

test("signed iOS rehearsal is explicit, production-scoped, and does not run other platforms", () => {
  const build = workflow("build")
  const dispatch = build.split("  workflow_dispatch:\n")[1]?.split("  workflow_call:")[0]
  assert.match(dispatch ?? "", /signed_ios:[\s\S]*?type: boolean[\s\S]*?default: false/)
  assert.equal(job(build, "package"), "")
  for (const input of ["run_android", "run_ios"]) {
    assert.match(dispatch ?? "", new RegExp(`${input}:[\\s\\S]*?type: boolean[\\s\\S]*?default: true`), `workflow_dispatch must default ${input} to true`)
  }
  assert.match(job(build, "android"), /if: \$\{\{ !inputs\.signed_ios && \(inputs\.production_release \|\| inputs\.run_android\) \}\}/)
  const ios = job(build, "ios")
  assert.match(ios, /if: \$\{\{ inputs\.signed_ios \|\| inputs\.production_release \|\| inputs\.run_ios \}\}/)
  assert.match(ios, /environment: \$\{\{ \(inputs\.production_release \|\| inputs\.signed_ios\) && 'production' \|\| '' \}\}/)
  assert.match(step(ios, "Build iOS archive (smoke)"), /!inputs\.production_release && !inputs\.signed_ios/)
  assert.match(step(ios, "Build production iOS Web assets and unsigned sideload IPA"), /DESKFLEET_IOS_UNSIGNED_IPA: "1"/)
  assert.doesNotMatch(build, /publish-ios-release|altool --upload/)
})

test("only profile preparation receives API credentials in the iOS build", () => {
  const ios = job(workflow("build"), "ios")
  const preparation = step(ios, "Download and validate iOS distribution profiles")
  assert.match(preparation, /IOS_APP_PROFILE_NAME: \$\{\{ vars\.IOS_APP_PROFILE_NAME \}\}/)
  assert.match(preparation, /IOS_BROADCAST_PROFILE_NAME: \$\{\{ vars\.IOS_BROADCAST_PROFILE_NAME \}\}/)
  assert.match(preparation, /APPLE_API_KEY_PATH:/)
  assert.match(preparation, /scripts\/prepare-ios-signing\.ts/)
  assert.doesNotMatch(step(ios, "Build production iOS Web assets and signed IPA"), /APPLE_API_/)
  assert.ok(ios.indexOf("Download and validate iOS distribution profiles") < ios.indexOf("Build production iOS Web assets and signed IPA"))
  assert.match(step(ios, "Upload iOS IPA"), /apps\/web\/ios\/App\/output\/\*\.ipa/)
  assert.match(step(ios, "Upload iOS IPA"), /apps\/web\/ios\/App\/output\/release\.json/)
  const diagnostics = step(ios, "Upload iOS build diagnostics")
  assert.match(diagnostics, /failure\(\)/)
  assert.match(diagnostics, /path: apps\/web\/ios\/App\/diagnostics\//)
  assert.doesNotMatch(diagnostics, /App\.xcarchive|\.p12|\.p8|mobileprovision/)
})

test("the iOS simulator and archive jobs share the pinned Xcode toolchain", () => {
  const archive = job(workflow("build"), "ios")
  const developerDir = archive.match(/DEVELOPER_DIR: (.+)/)?.[1]
  assert.match(developerDir ?? "", /^\/Applications\/Xcode_27\.\d+(?:\.\d+)?\.app\/Contents\/Developer$/)
  for (const source of [archive, job(workflow("test"), "ios")]) {
    assert.match(source, /^    runs-on: xcode-27$/m)
    assert.equal(source.match(/DEVELOPER_DIR: (.+)/)?.[1], developerDir)
  }
})

test("draft GitHub release consumes mobile artifacts without store publication jobs", () => {
  const publishYaml = workflow("publish")
  const release = job(publishYaml, "release")
  assert.match(release, /needs: \[validate, test, build, ios_guest\]/)
  assert.match(release, /name: deskfleet-android-apk/)
  assert.match(release, /name: deskfleet-ios/)
  assert.match(release, /deskfleet-\$VERSION-android-arm64\.apk/)
  assert.match(release, /deskfleet-\$VERSION-ios-arm64\.ipa/)
  assert.equal(job(publishYaml, "testflight"), "")
  assert.equal(job(publishYaml, "google_play"), "")
})

test("failed P12 import still records the keychain and removes credential files", { skip: process.platform === "win32" }, context => {
  const directory = mkdtempSync(join(tmpdir(), "deskfleet-ios-credentials-"))
  context.after(() => rmSync(directory, { recursive: true, force: true }))
  const output = join(directory, "outputs")
  const calls = join(directory, "security-calls")
  writeFileSync(join(directory, "security"), `#!/bin/sh
printf '%s\\n' "$1" >> "$DESKFLEET_SECURITY_CALLS"
if [ "$1" = import ]; then exit 23; fi
`, { mode: 0o755 })
  const env = {
    ...process.env,
    PATH: `${directory}${delimiter}${process.env.PATH ?? ""}`,
    RUNNER_TEMP: directory,
    GITHUB_OUTPUT: output,
    DESKFLEET_SECURITY_CALLS: calls,
    DESKTOP_SERVER_URL: "https://fleet.example.com",
    APPLE_TEAM_ID: "EXAMPLETEAM",
    IOS_DIST_CERT_P12: Buffer.from("fixture certificate").toString("base64"),
    IOS_DIST_CERT_PASSWORD: "fixture-password",
    APPLE_API_KEY_P8: Buffer.from("fixture key").toString("base64"),
    APPLE_API_KEY_ID: "FIXTUREKEY",
    APPLE_API_ISSUER: "fixture-issuer",
    DESKFLEET_IOS_APP_PROFILE_UUID: "",
    DESKFLEET_IOS_BROADCAST_PROFILE_UUID: "",
  }
  const ios = job(workflow("build"), "ios")
  const imported = spawnSync("bash", ["--noprofile", "--norc", "-eo", "pipefail", "-c", script(step(ios, "Prepare iOS release signing credentials"))], { env, encoding: "utf8" })
  assert.equal(imported.status, 23, imported.stderr)
  const values = Object.fromEntries(readFileSync(output, "utf8").trim().split("\n").map(line => line.split("=")))
  assert.equal(values.keychain_path, join(directory, "deskfleet-ios-signing.keychain-db"))
  assert.ok(existsSync(join(directory, "deskfleet-ios-dist.p12")))
  assert.ok(existsSync(values.key_path))
  const cleanup = step(ios, "Remove iOS signing credentials")
  assert.match(cleanup, /always\(\)/)
  const removed = spawnSync("bash", ["--noprofile", "--norc", "-eo", "pipefail", "-c", script(cleanup).replaceAll("${{ steps.ios_credentials.outputs.keychain_path }}", values.keychain_path)], { env, encoding: "utf8" })
  assert.equal(removed.status, 0, removed.stderr)
  assert.match(readFileSync(calls, "utf8"), /delete-keychain/)
  assert.equal(existsSync(join(directory, "deskfleet-ios-dist.p12")), false)
  assert.equal(existsSync(values.key_path), false)
})

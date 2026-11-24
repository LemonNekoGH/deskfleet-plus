import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test, { type TestContext } from "node:test"

const repoRoot = join(import.meta.dirname, "..")

function workflowYaml(name: string): string {
  return readFileSync(join(repoRoot, `.github/workflows/${name}.yml`), "utf8").replace(/\r\n/g, "\n")
}

function workflowJobs(yaml: string): string[] {
  const jobsSection = yaml.split(/^jobs:\n/m)[1] ?? ""
  return [...jobsSection.matchAll(/^  ([a-z0-9_-]+):$/gm)].map(match => match[1]!)
}

function androidCredentialStep(context: TestContext) {
  const yaml = workflowYaml("build")
  const block = yaml.match(/^      - name: Prepare Android release keystore\n[\s\S]*?^        run: \|\n((?:          .*\n)+)/m)?.[1]
  assert.ok(block, "Missing Prepare Android release keystore step")
  const script = block.replace(/^ {10}/gm, "")
  const directory = mkdtempSync(join(tmpdir(), "deskfleet-android-release-"))
  context.after(() => rmSync(directory, { recursive: true, force: true }))
  const bash = process.platform === "win32"
    ? join(process.env.ProgramFiles ?? "C:\\Program Files", "Git", "bin", "bash.exe")
    : "bash"
  return (variables: NodeJS.ProcessEnv) => spawnSync(bash, ["--noprofile", "--norc", "-eo", "pipefail", "-c", script], {
    encoding: "utf8",
    env: {
      ...process.env,
      RUNNER_TEMP: directory,
      GITHUB_OUTPUT: join(directory, "output"),
      DESKTOP_SERVER_URL: "",
      ANDROID_KEYSTORE_BASE64: "",
      ANDROID_KEYSTORE_PASSWORD: "",
      ANDROID_KEY_ALIAS: "",
      ANDROID_KEY_PASSWORD: "",
      ANDROID_GOOGLE_SERVICES_JSON: "",
      ...variables,
    },
  })
}

test("fork keeps mobile-only workflows and blocks upstream desktop packaging resurrection", () => {
  for (const deleted of ["nix.yml", "nix-server.yml", "aur.yml", "aur-publish.yml", "linux-packages.yml"]) {
    assert.equal(
      existsSync(join(repoRoot, ".github/workflows", deleted)),
      false,
      `Pruned upstream workflow .github/workflows/${deleted} must not be restored on DeskFleet Plus`,
    )
  }
  assert.deepEqual(workflowJobs(workflowYaml("ci")), ["changes", "test", "build", "gate", "prune_caches"])
  assert.deepEqual(workflowJobs(workflowYaml("test")), ["preflight", "android", "ios"])
  assert.deepEqual(workflowJobs(workflowYaml("build")), ["android", "ios"])
  const publishYaml = workflowYaml("publish")
  assert.deepEqual(workflowJobs(publishYaml), ["validate", "test", "build", "ios_guest", "release"])
  assert.match(publishYaml, /scripts\/check-upstream-release\.ts --require-tag/)
  assert.match(publishYaml, /uses:\s*\.\/\.github\/workflows\/ios-guest-riscv64\.yml/)
  assert.match(workflowYaml("ios-guest-riscv64"), /^  workflow_call:/m)
  assert.match(
    workflowYaml("build"),
    /VITE_DESKFLEET_SERVER_URL:\s*\$\{\{\s*vars\.VITE_DESKFLEET_SERVER_URL \|\| 'https:\/\/deskfleet\.yetanother\.ai'\s*\}\}/,
  )
  const readme = readFileSync(join(repoRoot, "README.md"), "utf8")
  assert.match(readme, /DeskFleet Plus/, "README.md must stay DeskFleet Plus focused and not be overwritten by upstream")
  assert.match(readme, /moe\.remon\.deskfleet\.plus/, "README.md must document the DeskFleet Plus package ID")
})

test("production Android build rejects an unset or empty API origin before decoding credentials", context => {
  const run = androidCredentialStep(context)
  for (const origin of ["", undefined]) {
    const result = run({
      DESKTOP_SERVER_URL: origin ?? "",
      ANDROID_KEYSTORE_BASE64: Buffer.from("fixture").toString("base64"),
      ANDROID_KEYSTORE_PASSWORD: "pass",
      ANDROID_KEY_ALIAS: "alias",
      ANDROID_KEY_PASSWORD: "pass",
    })
    assert.notEqual(result.status, 0)
    assert.match(result.stdout, /::error::Set VITE_DESKFLEET_SERVER_URL in the production environment/)
  }
})

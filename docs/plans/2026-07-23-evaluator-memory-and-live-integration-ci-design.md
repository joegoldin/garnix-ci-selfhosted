# Evaluator Memory Visibility and Live Integration CI

## Context and success criteria

The self-hosted evaluator currently applies an 8 GiB `RLIMIT_AS` through
`prlimit`. Large flake evaluations can exhaust that virtual address-space
limit, after which Git/libgit2 reports `unable to create thread` and the
process can end with signal 11. The dashboard currently presents the generic
package-evaluation message and raw stderr, so the operator has to infer that
the configured limit caused the failure.

The Configure page already manages per-repository build-timeout overrides, and
the `repo_config.max_eval_memory` database column already exists, but there is
no API or UI for that column.

Separately, `Integration.FlakesSpec` is intentionally a live integration
suite. It exchanges a GitHub App JWT for an installation token, calls the real
repository and collaborator APIs, and fetches real private flake inputs. CI
currently cannot perform that work because the committed development secret is
redacted and the upstream test App installation and fixture repositories are
not controlled by this deployment.

This work is complete when:

1. the default evaluator address-space limit is 16 GiB;
2. every configured per-repository evaluator limit is at least 16 GiB;
3. an administrator can set or clear that limit from the existing per-repo
   overrides UI without disturbing the timeout override;
4. evaluator allocation failure is identified plainly in the dashboard log,
   including the effective limit and where to change it;
5. the live GitHub integration suite runs in CI with a dedicated,
   least-privilege test App and controlled fixture repositories;
6. CI cannot bypass the live integration examples and fails closed when their
   credentials are missing or invalid.

## Evaluator memory configuration

### Default and validation

Change `defaultRepoConfig.maxEvalMemory` from 8 GiB to 16 GiB. Treat 16 GiB as
the minimum accepted value for a repository override. The backend is the
validation authority; the frontend also sets `min=16` for immediate feedback.
Values are whole GiB in the API and UI and remain bytes in `repo_config`.

Clearing a repository override restores the 16 GiB default. Existing database
rows below 16 GiB are clamped to 16 GiB when read so the new floor takes effect
immediately without a data migration. A new override write persists the
validated byte count.

### API compatibility

Keep the existing timeout routes and their semantics unchanged:

- `PUT /api/configure/repo/:owner/:repo`
- `DELETE /api/configure/repo/:owner/:repo`

Add independent evaluator-memory routes:

- `PUT /api/configure/repo/:owner/:repo/evaluation-memory`
- `DELETE /api/configure/repo/:owner/:repo/evaluation-memory`

The PUT body is `{ "gibibytes": 16 }`. The timeout route changes only
`build_timeout_minutes`; the memory route changes only `max_eval_memory`.
This avoids an old frontend, a partial deployment, or a timeout-only edit
silently clearing a memory override.

The Configure settings response exposes:

- `default_max_eval_memory_gib: 16`;
- one combined `repo_overrides` row per repository where either
  `build_timeout_minutes` or `max_eval_memory` is set;
- nullable `build_timeout_minutes`;
- nullable `max_eval_memory_gib`.

Rows backed only by other `repo_config` fields, such as private-cache policy,
are not presented as runtime overrides.

### Configure page

Keep one “Per-repo overrides” section. Its editor contains:

- repository picker;
- optional max build time in hours;
- optional max evaluation memory in GiB, with a 16 GiB minimum;
- save and clear controls.

Each row displays both effective override values, using “default” for an
inherited field. Editing or clearing one field preserves the other. When both
fields inherit defaults, the row disappears.

## Dashboard failure reason

Retain the raw Nix stderr and reproduction command, but precede them with a
specific operator-facing log line when evaluation fails with a known
address-space allocation signature. The classifier recognizes the allocation
messages Nix, Git/libgit2, and the C++ runtime emit under the `prlimit` cap,
including:

- `unable to create thread`;
- `Cannot allocate memory`;
- `std::bad_alloc`;
- `virtual memory exhausted`.

The message is deliberately phrased as an allocation failure under the limit,
not as a host OOM claim:

> Nix evaluation could not allocate memory under this repository's 16 GiB
> limit. Increase “Max evaluation memory” under Configure → Per-repo
> overrides.

The dashboard and GitHub check output already consume the run-reporter log
stream, so this makes the reason visible in both places without adding a second
failure-state database. Non-matching failures retain the current generic
message. Tests cover matching, non-matching, configured-limit rendering, and
preservation of raw stderr.

## Live GitHub integration CI

### What remains live

`Integration.FlakesSpec` remains an integration suite. It continues to use:

- a real GitHub App private key to sign a JWT;
- GitHub's real installation-token endpoint;
- the real repository metadata and collaborator endpoints;
- real private repositories with intentionally different access graphs;
- Nix's real authenticated private-input fetch and store cleanup;
- the real Garnix checkout, authorization, evaluation, build, and reporting
  pipeline used by the existing harness.

No GitHub response, access token, private-input fetch, or authorization result
is replaced by a fixture or mock. The existing local reporter capture remains
only as the assertion sink for the completed end-to-end run.

### Dedicated test App

Create a separate GitHub App for this integration suite. Do not give CI the
production Garnix App private key. Install the test App only on the controlled
fixture repositories using “Only select repositories.”

Required repository permissions:

- **Contents: read**, for authenticated Git fetches of private flake inputs;
- **Metadata: read**, for repository visibility and collaborator queries.

The App does not need checks, statuses, administration, webhook events, or
user-authentication permissions. Installation tokens remain short-lived and
cannot exceed the App installation's selected repositories or permissions.

### Controlled fixture repositories

Copy the upstream integration fixtures into repositories controlled by this
deployment:

1. a private source repository equivalent to `test-repo-private`;
2. a private “minimal collaborators” repository;
3. a private “maximal collaborators” repository whose collaborator set
   intentionally differs from the minimal repository;
4. an inaccessible private repository owned by a different account or
   organization for the expected-denial scenario.

Install the test App on the first three and not on the inaccessible repository.
Update the integration flakes, lock files, expected messages, source-store
paths, and installation ID to these controlled fixtures. Pin every fixture
input to an exact revision so a test exercises authorization and fetching
rather than branch-head resolution.

The installation ID becomes an explicit
`GITHUB_APP_INSTALLATION_ID` integration-test setting instead of an upstream
constant. CI must report a clear setup error if the App ID, installation ID, or
private key is absent.

### CI secret delivery

The committed `secrets/dev.yaml` cannot safely hold a live credential because
its development decryption key is in the public repository. Keep that file
redacted.

Use the existing action-specific secret mechanism instead:

1. obtain the `backend_specs` action public key from
   `/api/keys/joegoldin/garnix-ci-selfhosted/actions/backend_specs/key.public`;
2. encrypt a payload containing `GITHUB_APP_ID`,
   `GITHUB_APP_INSTALLATION_ID`, and `GITHUB_APP_PK` to that public key;
3. commit only the encrypted payload;
4. have the packaged `backend_specs` wrapper decrypt it at runtime with
   `GARNIX_ACTION_PRIVATE_KEY_FILE`, export the three variables, set a
   non-secret test webhook value, and run the suite;
5. abort before the suite starts if decryption or private-key parsing fails.

The private key is not placed in Nix derivation arguments, the Nix store,
process arguments, or logs. Fork pull requests do not receive the action
private key. Because trusted action code can still read its decrypted secret,
the dedicated App and selected-repository installation are the security
boundary.

The existing descoped action token remains useful for authenticated public
input resolution and its larger rate limit. It does not replace the dedicated
test App, because the integration suite must prove App JWT exchange,
installation scoping, repository visibility, and private-input authorization.

## Test strategy

Implementation follows red-green cycles for:

- the 16 GiB default and read-time floor;
- database listing, set, and clear behavior for memory-only, timeout-only, and
  combined overrides;
- Configure API JSON and authorization contracts;
- frontend parsing, editing, independent clearing, and minimum validation;
- evaluator-memory failure classification and dashboard log text;
- integration secret parsing, fail-closed diagnostics, and environment
  plumbing;
- the live integration examples that previously failed.

Verification is intentionally focused. Run the previously failing evaluator,
Configure, frontend settings, and `Integration.FlakesSpec` examples rather than
the complete backend suite. No integration example is skipped in CI.

## Follow-up coverage

Add one cache-backed integration example that builds a public fixture with a
real private input, uploads its output, and asserts both that
`repo_config.private_cache` is enabled and that the object exists only in the
authenticated private cache bucket. The current suites cover those links
separately (live private-input fetching, automatic private-cache selection,
and S3 private-bucket routing), but do not yet assert the full chain in one
test.

## Rollout

1. Create the dedicated GitHub App and controlled fixture repositories.
2. Install the App on only the intended fixtures and record its installation
   ID.
3. Generate and commit the action-key-encrypted integration payload.
4. Implement and run the focused tests locally, including one live private
   input success and each access-denial case.
5. Commit and push Garnix CI.
6. Update the dotfiles `garnix-ci` input, build the erdtree closure, commit,
   and push dotfiles.
7. Rebuild erdtree so the backend/frontend use the 16 GiB default and new
   Configure API.
8. Retrigger `backend_specs` and confirm that the live integration suite and
   evaluator-heavy dotfiles checks complete successfully.

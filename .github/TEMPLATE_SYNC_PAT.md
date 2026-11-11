# Template sync with a personal access token

This guide sets up the workflow `.github/workflows/template-sync-pat.yml`, the flavour of template sync that authenticates with a personal access token. A repository keeps one flavour only; the other, which uses a GitHub App, is described in `TEMPLATE_SYNC_APP.md`, the guide of the same name in this directory.

A repository created from the template receives later changes of the template as a pull request that a bot opens. The workflow runs `AndreasAugustin/actions-template-sync`, compares the template with the repository, and opens or updates one pull request titled `chore(template): merge template changes` with the label `template_sync`. A maintainer reviews it like any other pull request. In the template repository itself both sync workflows compare `$GITHUB_REPOSITORY` with their source in the first step, write a notice and do nothing.

## Credentials

The workflow needs one secret, `PERSONAL_ACCESS_TOKEN`. Without it the job succeeds with a notice and nothing is synchronised. It is also skipped, with a notice, when the secrets of the App flavour exist: a repository that has both flavours would open two sync pull requests, so the App wins.

Create a fine-grained personal access token for a user that may write to the repository (a dedicated machine user is better than a person):

1. Open the settings of the account, Developer settings, Personal access tokens, Fine-grained tokens, Generate new token.
2. Select the repository as the only resource and set an expiry. Write the expiry in your calendar: an expired token makes the job fail until it is replaced.
3. Add the secret `PERSONAL_ACCESS_TOKEN` to the repository with the token as its value.

The token also reads the template repository. When the template is private, the token's owner must be allowed to read it; a fine-grained token limited to one repository cannot, so use a classic token with the `repo` and `workflow` scopes in that case.

## Permissions

Give the token exactly these repository permissions:

| Permission | Access | Why |
| --- | --- | --- |
| Contents | read and write | the action pushes its sync branch |
| Pull requests | read and write | the action opens and updates the pull request |
| Workflows | read and write | a sync may change files under `.github/workflows/` |
| Metadata | read | mandatory |

## Schedule

The workflow runs on the first day of every month at 00:00 UTC (`0 0 1 * *`) and on demand through "Run workflow" (`workflow_dispatch`). An open sync pull request is updated in place (`is_force_push_pr`). Run it by hand after the template publishes a change that you need earlier.

## `.templatesyncignore`

The file `.templatesyncignore` at the root of the repository lists the paths that the sync never touches, one per line, in the `.gitignore` format, without comments. The template ships it with two groups: the files that belong to the service, and the template-owned files that a service extends. Add a path to keep it out of the sync; remove a path to receive the template's version of it. A file that exists only in your repository is never touched by a sync. Everything else is synchronised: the shared crates, the `xtask` crate, the workflows, the `Makefile` and `make/`, the scripts, the Bats suite, the guidance and the skills.

## The label for protected configuration

The sync pull request is a pull request like any other: the check `validate-configuration` of the workflow `Change control` runs on it. When the sync changes a protected item (the lint policy, a gate threshold, a protected value in `make/gates.mk` or `make/tool-versions.mk`, the load-test budgets, the toolchain files, among others), the check fails until a maintainer adds the label `approved-config-change` to the pull request. Read the diff of the protected items before you add the label: it approves exactly what the diff shows. The title check skips pull requests with the label `template_sync`.

## Keep only one flavour

Both flavours do the same thing and would open competing pull requests. Keep one:

1. Delete the workflow file of the other flavour, `template-sync-app.yml` in `.github/workflows`, and its guide, `TEMPLATE_SYNC_APP.md` in `.github`. Both are named here without their directory on purpose: the documentation check (`make docs-check`) reports a citation of a path that does not exist, and this guide is synchronised from the template, so an edit that removes the citation would come back with the next sync.
2. Delete the secrets that only the removed flavour used.
3. Open the deletion as a normal pull request. The sync would restore a deleted file, so add the deleted paths to `.templatesyncignore`.
4. Search your own documents (`README.md`, for example) for citations of the deleted files and name them without their directory, as this guide does.

## The template changes that do not propagate

A repository created from a template shares no history with it, so the sync action merges without a common ancestor and resolves every difference in favour of the template. A file that a service extends would lose the service's additions, so `.templatesyncignore` lists these files and the sync never touches them. A change that the template makes to such a file does not arrive; apply it by hand.

The ignored files are the service-owned files (`README.md`, `CHANGELOG.md`, `Cargo.toml`, `Cargo.lock`, `.sqlx/`, `migrations/`, the contract snapshots, `workspace.dsl`, `bmalph/config.json`, `specs/`, the example context `crates/company-subdomain/`, the feature files `features/api_docs.feature`, `features/example_api_resource.feature`, `features/graphql.feature` and `features/http_errors.feature`, `tests/Load/config.json.dist`, `docs/requests.http`) and the template-owned files that a service extends:

| File | What a service adds | What does not arrive |
| --- | --- | --- |
| `Cargo.toml` | its crates, dependencies and the package identity | changes of the lint policy (`[workspace.lints]`), of the shared dependency versions and of the other workspace tables |
| `tests/Load/config.json.dist` | its scenarios and endpoints | changes of the load-test budgets and shapes |
| `.env`, `.env.test`, `docs/environment.md` | variables of its own adapters and their reference entries | new or changed variables of the template |
| `docs/adr/` | its own decision records | new or changed template decision records |
| `.github/dependabot.yml` | ecosystems and ignore rules | changes of the update schedule and groups |
| `.claude/skills/README.md` | the index lines of its own skills | the index line of a new template skill (the skill itself arrives) |
| `architecture.toml` | third-party crates on the allow-list of a layer | changes of the layer rules |
| `deny.toml`, `.trivyignore`, `.gitleaksignore`, `_typos.toml`, `.cargo/mutants.toml` | dated exceptions | changes of the template's own policy in these files |
| `crates/internal/health-check/domain/src/value_object/dependency.rs` and its `dependency/` tests, `crates/internal/health-check/infrastructure/src/probe.rs` | a dependency and the module declaration of its probe | changes of the health-check wiring |
| `crates/service/Cargo.toml`, `src/bootstrap`, `src/cli`, `src/config`, `src/http.rs`, `src/openapi`, `src/graphql/schema` of that crate | wiring, commands, configuration, routes and schema roots | changes of the service wiring |
| `crates/service/src/http/router/tests.rs` and `crates/service/tests/integration/bootstrap.rs`, `migrate.rs`, `serve.rs`, `panic.rs` | the tests that construct `Adapters` and use the routes, the table and the migration of the example context; a service keeps them in step with its wiring | changes of these tests |
| `tests/support/`, `tests/e2e/` | test doubles, world and step definitions | changes of the test support |
| files changed through an extension seam (see `docs/extension-seams.md`) | the change the seam describes; the service adds each synchronised path it changes to its own `.templatesyncignore` in the same pull request | changes of these files: the template does not ignore them, so its fixes reach every service that has not changed them; apply them by hand to a file you ignore |

`docs/repository-settings.md` is synchronised too: a service lists the jobs of its own pull-request workflows in docs/repository-settings-service.md, which the template does not ship and a sync never touches. `Makefile` and `docs/make-targets.md` are synchronised, not ignored: a service defines its own targets in make/service.mk, which the `Makefile` loads, and documents them in docs/make-targets-service.md. The template ships neither file, so a sync cannot change them.

`.templatesyncignore` itself is on the list: the service owns its copy. The file in the template is the reference.

### Deletions and renames do not propagate

A file that the template deletes or renames is not removed from your repository. With no common ancestor the merge cannot see a deletion: the old file exists only on your side, so the merge keeps it as your own file, and the sync action does not delete files (`is_force_deletion` is not set, and a squash merge would find nothing to delete anyway). A stale Bats file or workflow then keeps running against targets that no longer exist, and the pull requests of your repository turn red with nothing in the sync pull request to explain it. After every sync, find the files that exist in your repository and no longer in the template, and delete them in the sync pull request. With the template added as a remote (see below):

```sh
git fetch template main
git diff --name-only --diff-filter=A template/main HEAD
```

The command lists every path that your repository has and the template does not. Most of them are your own files; the template's former files are among them, so read the list against `git log --diff-filter=DR --name-status template/main` and delete the paths that the template removed or renamed. A path that you keep on purpose belongs in `.templatesyncignore`.

### Apply an ignored change by hand

1. Add the template as a remote once and fetch it:

   ```sh
   git remote add template <URL of the template repository>
   git fetch template main
   ```

2. Find what changed in the template since you last looked, for one file or for all ignored paths:

   ```sh
   git diff HEAD template/main -- Cargo.toml tests/Load/config.json.dist
   ```

   Differences that your service made on purpose appear in the diff too; read it as a list of candidates, not as a patch to apply wholesale. After a sync, `git log template/main -- <path>` shows the template commits that touched a path.
3. Copy the template's change into your file and keep your own additions. For `Cargo.toml` that means the lint tables and dependency versions; for the load-test budgets the four `threshold` values.
4. Open a normal pull request. A change to a protected file (the lint policy and the budgets are protected) needs the label `approved-config-change`.
5. Run `make ci` before merging.

Do this after every sync pull request, and at least once a quarter, so that the service does not fall behind the template's lint policy, budgets and exception lists.

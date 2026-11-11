# Automatic release

Every push to `main` can produce a release: a version number, a changelog entry, a tag and a GitHub release, without a human step. The workflow is `.github/workflows/release.yml` and the work is done by `scripts/release.sh`, which uses cocogitto. This guide describes the flow, the version rules and what to set up in a repository created from the template.

## Release flow

1. A pull request is squash-merged into `main`. The squashed commit subject is the checked pull-request title, in the form `type(#issue): subject`.
2. The workflow `Release` starts on the push. It does nothing when the head commit is already a release commit (its message contains `[skip ci]`).
3. The first step looks for the two secrets `VILNACRM_APP_ID` and `VILNACRM_APP_PRIVATE_KEY`. Without them the job writes the notice `Release skipped: GitHub App secrets are not configured` and succeeds; nothing is released.
4. With the secrets, the job creates a short-lived token of the GitHub App, checks out the full history with that token and installs cocogitto.
5. `scripts/release.sh` asks cocogitto for the next version from the conventional commits since the last tag. When no commit requires a bump, it prints that and exits successfully: nothing to release.
6. Otherwise cocogitto runs the pre-bump hook `scripts/set-version.sh`, which sets the version in the workspace manifest and refreshes `Cargo.lock`, prepends the new section to `CHANGELOG.md`, commits and tags `v<version>`.
7. The script amends the commit message to `chore(release): v<version> [skip ci]`, moves the tag onto the amended commit and pushes the commit to `main` and the tag.
8. It creates the GitHub release `v<version>` with the changelog section of that version as its notes.

Only one release runs at a time and a running release is never cancelled. When two pushes arrive together, the later run releases both changes. A push that is rejected because `main` moved fails the job; the next push to `main` releases both changes.

A maintainer can start a release by hand with the `workflow_dispatch` input `version` (`x.y.z`). The run then executes `scripts/release.sh --version <x.y.z>`. This is how `1.0.0` is cut: no commit does it on its own.

## Version rules

The version follows the conventional commit types of the squashed commits:

| Commit | Effect |
| --- | --- |
| `fix` | patch release |
| `feat` | minor release |
| footer `BREAKING CHANGE:` | major release; below `1.0.0` the minor number is raised instead |
| `build`, `chore`, `ci`, `docs`, `perf`, `refactor`, `style`, `test` | no release |

Rules that follow from this:

- While the version is `0.y.z`, a breaking change raises the minor number (`0.1.0` becomes `0.2.0`), not the major number. Release `1.0.0` by hand with the input `version`, when the service declares its interface stable.
- The first release is the version in the workspace manifest, which is `0.1.0` in the template, whether the first releasable commit is a `feat` or a `fix`. The script passes the manifest version to the first bump.
- Dependency updates by Dependabot use the types `build`, `ci` and `chore`. They cause no release by themselves; they are released with the next `feat` or `fix`.
- Only user-visible changes appear in the changelog: `feat`, `fix`, `perf` and breaking changes. The other types are omitted.
- The release commit carries `[skip ci]`, so it starts no workflow, and the job also checks the message as a second barrier. A commit whose subject is not conventional does not stop the bump; it is ignored.

## Create the GitHub App

The release must push to `main` and create a release. The token of the workflow itself is read-only, so the workflow uses an App. Create it once for the account or organisation:

1. Open the settings of the account or organisation, Developer settings, GitHub Apps, New GitHub App.
2. Give it a name, a home page URL (the repository URL is enough) and disable the webhook.
3. Set the repository permissions to exactly the ones the workflows use and nothing else:

   | Permission | Access | Used for |
   | --- | --- | --- |
   | Contents | read and write | push of the release commit and tag; creating the release |
   | Pull requests | read and write | the template-sync App flavour opens its pull request |
   | Workflows | read and write | the template-sync App flavour may change files under `.github/workflows/` |
   | Metadata | read | mandatory, granted automatically |

   When you use the App for the release only and not for template sync, Contents (read and write) and Metadata (read) are enough. The release job requests only `contents: write` for its token.
4. Choose "Only on this account" for the installation scope, create the App and note its App ID.
5. Generate a private key and keep the downloaded `.pem` file.
6. Install the App on the repository (or on every repository of the organisation that uses the template).

## The two secrets

Add them as repository secrets (or as organisation secrets shared with the repository):

| Secret | Value |
| --- | --- |
| `VILNACRM_APP_ID` | the App ID from step 4 |
| `VILNACRM_APP_PRIVATE_KEY` | the complete content of the `.pem` file, including the `BEGIN` and `END` lines |

The names are fixed by the workflows. The action that creates the token currently reads the App ID through the input `app-id`, which its newer versions replace with `client-id`; when the pinned action is raised to a version that drops `app-id`, switch the input in `release.yml` and `template-sync-app.yml` to the client ID of the App, and keep the secret names.

## Permission to push to `main`

Branch protection of `main` normally rejects a direct push. Allow the App to push without a pull request: in the protection rule or ruleset of `main`, add the App to the identities that may bypass the pull-request requirement (or to the push allow-list, depending on the protection model). The App must also be allowed past required status checks for the push, because the release commit starts no workflow and so has no checks. `docs/repository-settings.md` lists the other settings of a repository.

Without this permission the job fails at the push step. The commit and tag exist only in the runner, so nothing is half-released; fix the permission and push a new change to `main`.

## Behaviour without secrets

A repository without the two secrets is fully usable. The `Release` workflow runs on every push, writes the notice `Release skipped: GitHub App secrets are not configured`, and succeeds. No version, tag or release is created, and the changelog stays as it is. The same holds for the App flavour of template sync. Add the secrets when you want releases; the next push to `main` releases every releasable commit since the last tag.

# Releasing Mux Swift Upload SDK

This guide describes the current maintainer release process for
`swift-upload-sdk`.

## How To Use This Guide

- Humans can use the manual checklist for a concise overview of the release
  flow.
- AI agents must follow the agent-assisted runbook. Use the manual checklist as
  summary context, not as the execution procedure.

## How Distribution Works

Swift Package Manager and CocoaPods use different publish paths:

- Swift Package Manager resolves versions from Git tags. Once `vX.Y.Z` exists
  on GitHub, SwiftPM clients can resolve that version.
- The GitHub release is used for release notes and discoverability. In this
  repo, merging a PR from a `releases/vX.Y.Z` branch triggers
  `.github/workflows/tagged-release-pr.yml`, which creates a draft GitHub
  release for the merged commit. A draft release can exist before the public Git
  tag exists; verify the tag after publishing.
- CocoaPods is published manually after the GitHub release/tag exists by running
  `pod trunk push Mux-Upload-SDK.podspec`.

Two version values must stay in sync:

- `Sources/MuxUploadSDK/PublicAPI/SemanticVersion.swift` — the SDK version
  reported by the library.
- `Mux-Upload-SDK.podspec` — the CocoaPods version and source tag.

## Manual Release Checklist

1. Confirm the target version and verify the intended changes are merged to
   `main`.
2. Create `releases/vX.Y.Z` from `origin/main`, bump both version files, run
   validation, and open a release PR.
3. Review and curate the generated release notes on the release PR.
4. After the release PR is approved, merge it and wait for the workflow comment
   linking to the draft GitHub release.
5. Review and publish the GitHub release. Confirm this creates the release tag;
   the tag is what makes the SwiftPM version available.
6. Run `pod spec lint`, then publish CocoaPods with `pod trunk push`.
7. Update the Mux documentation site in a separate PR when the release changes
   customer-facing docs.

## Agent-Assisted Release Runbook

Follow this section when using an AI agent to prepare or publish a new SDK
version.

### Agent Rules

- Ask for the target version before changing files. Do not infer patch, minor,
  or major unless the maintainer explicitly asks you to.
- Release branches use the `releases/vX.Y.Z` format. Do not use personal or
  agent prefixes for release branches.
- Keep release PRs small. A release PR should only update
  `SemanticVersion.swift` and `Mux-Upload-SDK.podspec` unless the maintainer
  explicitly includes another release-related change.
- The two version values must match exactly. Never bump one file without the
  other.
- The current repo workflow creates a draft GitHub release when the release PR
  is merged. Prefer publishing that draft after review. If the workflow fails,
  stop and ask before creating a release manually.
- Let maintainers collaborate on release notes. Draft notes are useful, but do
  not treat generated notes as final if a human edits them.
- CocoaPods publishing can require trunk authorization. Check authorization
  before publishing. If CocoaPods asks for registration or email confirmation,
  stop and report the exact prompt. Do not try to bypass the maintainer's
  email-auth step.
- For follow-up branches outside this repo, such as documentation site updates,
  use the maintainer's normal initials-style prefix. Ask for it if it is not
  already clear. Do not invent agent-specific prefixes for team-visible
  branches.
- If validation, merge, release, CocoaPods publish, or docs steps fail, stop and
  report the failure, the command that failed, and the safest next step. Do not
  silently continue past a failed release step.
- When asked to continue an interrupted release, inspect the current branch, PR,
  tag, GitHub release, CocoaPods version, and docs state first. Resume from the
  first incomplete step instead of starting over.

### Prepare The Release PR

1. Confirm the target version with the maintainer.
   - Example: `1.1.1`
   - The release branch and tag will be `releases/v1.1.1` and `v1.1.1`.

2. Verify the intended feature changes are already merged to `main`.
   - Check the relevant feature PRs.
   - Fetch the latest main and tags:
     ```sh
     git fetch origin main --tags
     ```
   - Confirm `origin/main` contains the intended release contents.

3. Check the current version and release state.
   ```sh
   git tag --list 'v*' --sort=-version:refname
   gh release list --limit 20
   ./scripts/version-check.sh
   ```
   Confirm `SemanticVersion.swift`, `Mux-Upload-SDK.podspec`, the latest Git
   tag, and the latest published GitHub release all match before bumping.

4. Create a release branch from `origin/main`.
   ```sh
   git switch -c releases/vX.Y.Z origin/main
   ```
   If using a worktree, use the maintainer's normal local worktree convention:
   ```sh
   git worktree add <worktree-path> -b releases/vX.Y.Z origin/main
   ```

5. Bump both version files to the same `X.Y.Z` value.
   - `Sources/MuxUploadSDK/PublicAPI/SemanticVersion.swift`: update `major`,
     `minor`, and `patch`.
   - `Mux-Upload-SDK.podspec`: update `s.version`.

6. Confirm both values match.
   ```sh
   ./scripts/version-check.sh
   ```

7. Validate the release branch.
   ```sh
   xcrun swift test
   git diff --check
   ```
   If CocoaPods is available locally, also run a local pod lint:
   ```sh
   pod lib lint Mux-Upload-SDK.podspec --allow-warnings
   ```
   Use `pod lib lint` here because the release tag does not exist yet. Do not
   run `pod spec lint` until after the GitHub release creates the `vX.Y.Z` tag.
   If CocoaPods is not available or lint cannot run locally, report that clearly
   in the PR.

8. Commit the version bump.
   ```sh
   git add Sources/MuxUploadSDK/PublicAPI/SemanticVersion.swift Mux-Upload-SDK.podspec
   git commit -m "Version Bump"
   ```

9. Push the release branch.
   ```sh
   git push -u origin releases/vX.Y.Z
   ```

10. Open a release PR.
    - Base: `main`
    - Head: `releases/vX.Y.Z`
    - Title: `Releases/vX.Y.Z`
    - Body:
      ```md
      ## Summary
      - bump SDK version from A.B.C to X.Y.Z
      ```

11. Wait for the changelog workflow to update the PR, then review and curate
    the release notes with the maintainer.

12. Stop until the PR is approved.

### Publish The GitHub Release

Continue only after the release PR is approved.

1. Merge the release PR.
   - Use the repository's normal merge method.
   - If merging from the CLI, preserve the release PR title/body unless the
     maintainer asks for a specific merge style.

2. Fetch the merged main branch and tags.
   ```sh
   git fetch origin main --tags
   ```

3. Verify `origin/main` contains the new version values.
   ```sh
   git show origin/main:Sources/MuxUploadSDK/PublicAPI/SemanticVersion.swift
   git show origin/main:Mux-Upload-SDK.podspec
   ```

4. Wait for the release workflow to create the draft GitHub release.
   ```sh
   gh release view vX.Y.Z --json tagName,name,url,targetCommitish,publishedAt,isDraft,isPrerelease
   ```
   Confirm:
   - `tagName` is `vX.Y.Z`.
   - `isDraft` is `true`.
   - `targetCommitish` corresponds to the merged release PR.

5. If the draft release was not created, stop and inspect the GitHub Actions run
   before doing anything manually.

6. Prepare final release notes.
   - Start from the release PR body or generated changelog.
   - Focus on customer-visible behavior and API changes.
   - Remove internal ticket IDs, implementation-only notes, and confusing
     generated wording.
   - If the maintainer edits notes in GitHub or another place, use the
     maintainer-edited version as final.

7. Stop and get maintainer approval of the final release notes before
   publishing.

8. Publish the draft GitHub release.
   - The draft may be published in the GitHub UI.
   - Or use the CLI after final notes are approved:
     ```sh
     gh release edit vX.Y.Z \
       --title "vX.Y.Z" \
       --notes "<release notes>" \
       --draft=false
     ```

9. Verify the release and tag.
   ```sh
   git fetch origin main --tags
   gh release view vX.Y.Z --json tagName,name,url,targetCommitish,publishedAt,isDraft,isPrerelease
   git rev-list -n 1 vX.Y.Z
   git rev-parse origin/main
   ```
   Confirm the release is published, not a draft, and not marked as a prerelease
   unless that was intentional. The tag commit should match the merged release
   PR commit on `origin/main`.

### Publish CocoaPods

Continue only after the GitHub release and tag exist.

1. Verify the local checkout is on the released commit or an up-to-date
   `origin/main` containing the released version.
   ```sh
   git fetch origin main --tags
   git rev-list -n 1 vX.Y.Z
   git rev-parse origin/main
   ./scripts/version-check.sh
   ```

2. Verify CocoaPods trunk access.
   ```sh
   pod trunk me
   ```
   If this shows the expected CocoaPods account, continue. If trunk access is
   not configured, register with the Mux iOS SDK email:
   ```sh
   pod trunk register ios-sdk@mux.com '<Your Name>'
   ```
   This sends an authorization email to `ios-sdk@mux.com`. Stop and ask a
   maintainer to complete the email confirmation, then resume from
   `pod trunk me`.

3. Lint the podspec.
   ```sh
   pod spec lint Mux-Upload-SDK.podspec --allow-warnings
   ```

4. Publish the pod.
   ```sh
   pod trunk push Mux-Upload-SDK.podspec --allow-warnings
   ```

5. Verify CocoaPods sees the new version.
   ```sh
   pod trunk info Mux-Upload-SDK
   ```
   Confirm `X.Y.Z` appears in the published versions.

### Update Public Docs

After the SDK release is published, update the Mux documentation site in a
separate PR when release notes or customer-facing behavior require docs changes.
Treat this as part of the release being fully done when docs changes are needed.

1. Read the final GitHub release notes.
   ```sh
   gh release view vX.Y.Z --repo muxinc/swift-upload-sdk --json body,url,name,tagName
   ```

2. Work in the repository that owns the Mux documentation site. Use your local
   checkout of that repo, and create the docs branch from the latest
   `origin/main`.

3. Inspect the Swift Upload SDK docs page:
   `apps/web/app/docs/_guides/developer/upload-video-directly-from-ios-or-ipados.mdx`

4. Decide whether docs need updates.
   - Update docs when the release changes customer-facing behavior, setup,
     defaults, or API usage.
   - Do not add a new how-to section when behavior is automatic and there is no
     new customer-facing API. A short sentence may be enough.
   - If no docs change is needed, report that decision and why.

5. Use a team branch prefix for documentation site branches.
   - Use the maintainer's normal initials-style prefix, e.g.
     `<maintainer-initials>/swift-upload-X.Y.Z-docs`.
   - Ask for it if unsure.
   - Avoid agent-specific prefixes.

6. Validate the docs diff.
   ```sh
   git diff --check
   ```

7. Open a docs PR for the update and wait for review.
   The SDK release can be considered complete after the docs PR is merged, or
   after the maintainer confirms no docs update is needed.

## Common Pitfalls

- Do not bump one version file without the other. `SemanticVersion.swift` and
  `Mux-Upload-SDK.podspec` must always match.
- Do not skip `./scripts/version-check.sh`.
- Do not create a release branch with a personal or agent prefix. Use
  `releases/vX.Y.Z`.
- Do not publish the GitHub release before the release PR is merged.
- Do not manually create a replacement release/tag if the workflow fails without
  first inspecting the failed Actions run.
- Do not assume SwiftPM availability means CocoaPods is published. CocoaPods is
  a separate manual `pod trunk push` step.
- Do not run `pod spec lint` before the GitHub release/tag exists. Use
  `pod lib lint` for release PR validation and `pod spec lint` after the tag
  exists.
- Do not continue through CocoaPods auth prompts. Stop and let the maintainer
  complete email authorization.
- Do not publish generated release notes if a maintainer edited the final notes.

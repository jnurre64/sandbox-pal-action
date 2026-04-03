# Pending Tasks

Tracked locally until GitHub issue creation is available via the bot account.

## PRs to merge

- [x] **PR: OSS hygiene files** — branch `chore/oss-hygiene` (merged)
- [x] **PR: Versioning policy docs** — branch `docs/versioning-policy` (merged)
- [x] **PR #10: Dependabot — bump actions/checkout v4 to v6** (merged)

## Issues to create on GitHub

- [ ] **Establish GitHub Releases and review versioning strategy**
  - Create Releases from existing tags (at minimum v1.0.0 and v1.1.2) with notes from CHANGELOG.md
  - Verify `v1` major version tag points to latest release
  - Review whether version bumps to date accurately reflect SemVer
  - Optionally add a release automation workflow (tag push auto-creates Release)
  - Reference: versioning policy in docs/versioning.md

## GitHub UI tasks

- [x] Add repository topics (done)
- [x] Verify security features are on (done)
- [ ] Disable Wiki tab (recommended — docs/ already covers all documentation needs)
- [x] Disable Projects tab (done)
- [ ] Enable Discussions — deferred, will enable if the need arises

## Bot account permissions

- [ ] Update pennyworth-bot fine-grained PAT to add Issues and Pull requests write access
  Blocked by GitHub roadmap #601 (fine-grained PATs cannot scope to repos where the token owner is a collaborator, only repos they own). Will migrate when GitHub ships collaborator support.
  Git push works via SSH deploy key. Only `gh` CLI API operations are affected.

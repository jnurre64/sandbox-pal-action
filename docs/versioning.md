# Versioning

This project follows [Semantic Versioning (SemVer) 2.0.0](https://semver.org/) and the [GitHub Actions versioning convention](https://github.com/actions/toolkit/blob/main/docs/action-versioning.md) for major version tags.

## Version Format

**MAJOR.MINOR.PATCH** (e.g., `v1.2.3`)

| Component | When to bump | Example |
|-----------|-------------|---------|
| **PATCH** | Bug fixes that don't change behavior users depend on | Fix a typo in error message, fix a crash in cleanup |
| **MINOR** | New features or capabilities added in a backwards-compatible way | Add a new notification backend, add a new config option |
| **MAJOR** | Breaking changes to the public interface | Rename config keys, change label names, alter workflow inputs |

## What Counts as the Public Interface

These are the things governed by SemVer — changes to any of these determine which version component to bump:

- Configuration keys and their expected values (`AGENT_*` variables)
- Label names and the state machine transitions
- Workflow inputs and outputs (the `workflow_call` interface)
- Prompt output format conventions (JSON action fields)
- CLI arguments to `sandbox-pal-dispatch.sh` and `cleanup.sh`
- Environment variables consumed or exported by the dispatch scripts

Internal implementation details (function names, log format, file paths within scripts) are NOT part of the public interface and can change freely.

## Major Version Tags

Users reference this project in workflow files via major version tags:

```yaml
uses: jnurre64/sandbox-pal-action/.github/workflows/sandbox-pal-triage.yml@v1
```

The `v1` tag is a mutable pointer that always tracks the latest `v1.x.y` release. After tagging a new release:

```bash
git tag -fa v1 -m "Update v1 tag to v1.x.y"
git push origin v1 --force
```

This is the standard GitHub Actions convention. Users referencing `@v1` automatically get patch and minor updates without changing their workflow files.

## When to Release

**Release when there is user-facing value.** Not every merge to main needs a tag.

**Tag (release) these:**
- Bug fixes that affect users
- New features that are complete and tested
- Security patches (release immediately)

**Don't tag these — just merge to main:**
- Refactoring with no behavior change
- Test additions or improvements
- CI/CD configuration changes
- Documentation updates

**Batch related changes.** Multiple small fixes merged in one session are one PATCH release, not several.

## Release Checklist

1. Update `CHANGELOG.md` — move items from `[Unreleased]` to a new version section with today's date
2. Commit the changelog update
3. Create an annotated tag: `git tag -a v1.x.y -m "Release v1.x.y"`
4. Push the tag: `git push origin v1.x.y`
5. Update the major version tag (see above)
6. Create a GitHub Release from the tag with notes from the changelog

## Changelog

The changelog follows [Keep a Changelog](https://keepachangelog.com/) format. When merging user-facing changes, add a line to the `[Unreleased]` section. Categories: Added, Changed, Deprecated, Removed, Fixed, Security.

## Protecting the v1 Compatibility Commitment

Before making any change, ask: **"Would this break someone using `@v1` today?"**

If yes, either:
1. Find a backwards-compatible approach (support both old and new, deprecate the old)
2. Save it for a future v2 release

Avoid bumping to v2 until there is a substantial set of breaking changes that justify it. Individual breaking changes should be deferred or made backwards-compatible whenever possible.

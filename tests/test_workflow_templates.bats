#!/usr/bin/env bats
# Guards on the workflow templates that /setup installs.

load 'helpers/test_helper'

TEMPLATES_DIR="${BATS_TEST_DIRNAME}/../.claude/skills/setup/templates"

_notice_templates() {
    grep -l "actor-filter-notice:" "$TEMPLATES_DIR"/*.yml "$TEMPLATES_DIR"/standalone/*.yml
}

# The actor-filter-notice job of one template, to the end of the file
_notice_job() {
    sed -n '/^  actor-filter-notice:/,$p' "$1"
}

@test "REGRESSION v1.4.1: programmatic dispatch runs are named after their event and issue (#81)" {
    local f
    for f in "$TEMPLATES_DIR/caller-dispatch.yml" "$TEMPLATES_DIR/standalone/sandbox-pal-dispatch.yml"; do
        run grep -E '^run-name: .*github\.event\.action.*client_payload\.issue_number' "$f"
        assert_success
    done
}

@test "REGRESSION v1.4.1: label-triggered runs name the label, the issue and the actor (#81)" {
    local f
    for f in $(_notice_templates); do
        run grep -E '^run-name: .*github\.event\.label\.name.*github\.event\.issue\.number.*github\.actor' "$f"
        assert_success
    done
}

@test "REGRESSION v1.4.1: the actor-filter notice runs where the pipeline runs and cannot fail the run (#84)" {
    local f
    [ "$(_notice_templates | wc -l)" -eq 6 ]
    for f in $(_notice_templates); do
        run _notice_job "$f"
        refute_output --partial "ubuntu-latest"
        assert_output --partial "runs-on: [self-hosted, agent]"
        assert_output --partial "continue-on-error: true"
    done
}

@test "REGRESSION v1.4.1: the actor-filter notice needs no gh on the runner and posts once per issue (#84)" {
    local f
    for f in $(_notice_templates); do
        run _notice_job "$f"
        refute_output --regexp '(^|[^a-z])gh issue comment'
        assert_output --partial "curl"
        assert_output --partial "<!-- sandbox-pal:actor-filter-notice -->"
        assert_output --partial "already posted"
        # Event fields reach the shell through env, not by interpolation
        refute_output --regexp 'run: \|[^#]*\$\{\{ github\.event'
    done
}

#!/usr/bin/env python3
"""Validate schemas and normalize Claude results or a single Codex exec turn.

No remote/file schema retrieval. Diagnostics never echo response or schema data.
"""
import json
import os
import re
import sys


# The Claude CLI's wording for a subscription usage window that has closed — the 5-hour
# session limit, the weekly limit, and the per-model (Opus/Sonnet/Fable) limits. Matched
# case-insensitively against the whole envelope; see normalize().
USAGE_LIMIT_WORDS = ("usage limit", "session limit", "weekly limit", "opus limit", "sonnet limit",
                     "fable limit", "hit your limit", "usage_limit")


def reject_constant(value):
    raise ValueError("Non-JSON constant")


def loads(text):
    return json.loads(text, parse_constant=reject_constant)


def validator_for(schema):
    from jsonschema.validators import validator_for as select_validator
    from referencing import Registry

    cls = select_validator(schema, default=None) if isinstance(schema, dict) and "$schema" in schema else select_validator(schema)
    if cls is None:
        raise ValueError("Unsupported schema draft")
    cls.check_schema(schema)

    def check_refs(value):
        if isinstance(value, dict):
            for key, child in value.items():
                if key in ("$ref", "$dynamicRef", "$recursiveRef") and (not isinstance(child, str) or not child.startswith("#")):
                    raise ValueError("Only in-document schema references are supported")
                check_refs(child)
        elif isinstance(value, list):
            for child in value:
                check_refs(child)

    check_refs(schema)
    return cls(schema, registry=Registry())


def normalize(raw, phase, code, schema_text, stderr=""):
    result = dict(version=1, engine="claude", phase=phase, process_exit_code=code,
                  status="success", error=None, result_text="", structured_output=None,
                  schema_status="not_checked" if schema_text else "disabled",
                  permission_denials=[], denials_available=False,
                  usage=dict(input_tokens=None, output_tokens=None, cached_input_tokens=None), cost_usd=None)

    def fail(kind, message, status="failed"):
        result.update(status=status, error=dict(kind=kind, message=message, detail=detail_line()), structured_output=None)

    def detail_line():
        """The evidence a failed phase leaves behind — redacted by scrub()/redact_secrets,
        bounded so it fits a log line or an issue comment, empty when nothing was said."""
        parts = []
        for label, value in (("subtype", data.get("subtype")), ("terminal_reason", data.get("terminal_reason")),
                             ("api_error_status", data.get("api_error_status"))):
            if value not in (None, ""):
                parts.append(f"{label}={value}")
        if code:
            parts.append(f"exit={code}")
        for value in (data.get("errors"), data.get("error"), data.get("result"), stderr):
            text = " ".join(str(value).split()) if value not in (None, "", [], {}) else ""
            if text:
                parts.append(text[:300] + ("…" if len(text) > 300 else ""))
                break
        return " · ".join(parts)

    try:
        data = scrub(loads(raw))
        if not isinstance(data, dict):
            raise ValueError("Expected object")
    except (ValueError, TypeError):
        data = {}
        fail("transport", "Missing or malformed worker result")

    text = data.get("result", data.get("result_text", ""))
    result["result_text"] = text if isinstance(text, str) else ""
    denials = data.get("permission_denials")
    if isinstance(denials, list):
        result.update(permission_denials=denials, denials_available=True)
    usage = data.get("usage")
    if isinstance(usage, dict):
        for source, target in [("input_tokens", "input_tokens"), ("output_tokens", "output_tokens"), ("cache_read_input_tokens", "cached_input_tokens")]:
            value = usage.get(source)
            if type(value) in (int, float) and value >= 0:
                result["usage"][target] = value
    cost = data.get("total_cost_usd")
    if type(cost) in (int, float) and cost >= 0:
        result["cost_usd"] = cost

    subtype = str(data.get("subtype", ""))
    detail = " ".join(str(data.get(key, "")) for key in ("terminal_reason", "api_error_status", "result", "errors", "error")).lower() + " " + stderr.lower()
    semantic_error = data.get("is_error") is True or subtype.startswith("error_") or bool(data.get("error"))
    if semantic_error or code:
        kind, message = "unknown", "API error or worker failure"
        # Order matters. A subscription usage window ("Usage limit reached · resets 4:50pm",
        # session/weekly/per-model limits) resets on its own and is named before billing so it
        # is never reported as an exhausted quota; a 429 is named before "quota" because the
        # CLI's own rate-limit wording can carry that substring.
        if any(word in detail for word in ("unauthorized", "authentication", "invalid api key", "401", "not logged in")):
            kind, message = "auth", "API error: authentication failed"
        elif subtype in ("error_max_turns", "error_max_turns_reached", "error_max_budget_usd"):
            # The subtype is authoritative for a cap the harness itself set, whatever the text says.
            kind, message = "limit", "Worker turn or budget limit reached"
        elif any(word in detail for word in USAGE_LIMIT_WORDS):
            kind, message = "usage_limit", "API error: usage limit reached (the window resets on its own; re-dispatch after it does)"
        elif "429" in detail or "rate limit" in detail:
            kind, message = "rate_limit", "API error: rate limited"
        elif any(word in detail for word in ("credit balance", "billing", "insufficient_quota", "quota")):
            kind, message = "quota", "API error: quota exhausted"
        elif any(word in detail for word in ("permission denied", "not permitted", "refused")):
            kind, message = "permission", "Worker permission refusal"
        elif code in (126, 127) or "configuration" in detail:
            kind, message = "configuration", "Worker configuration or executable unavailable"
        fail(kind, message)
    elif not (isinstance(text, str) and text or "structured_output" in data or subtype == "success"):
        fail("transport", "Missing terminal worker result")
    if code == 124:
        fail("transport", "Worker timed out", "timed_out")
    elif code in (130, 143):
        fail("transport", "Worker cancelled", "cancelled")

    if result["status"] == "success":
        if schema_text:
            try:
                validator = validator_for(loads(schema_text))
                if "structured_output" not in data:
                    raise ValueError("Missing structured result")
                validator.validate(data["structured_output"])
                result.update(schema_status="valid", structured_output=data["structured_output"])
            except Exception:
                result["schema_status"] = "invalid"
                fail("schema", "Configured schema was not satisfied by structured output")
        else:
            result["structured_output"] = data.get("structured_output")
    return result


def scrub(value):
    if isinstance(value, str):
        for name, secret in os.environ.items():
            if any(part in name for part in ("TOKEN", "SECRET", "PASSWORD", "API_KEY", "APIKEY", "CREDENTIAL")) and len(secret) >= 8:
                value = value.replace(secret, f"[REDACTED:{name}]")
        value = re.sub(r"github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}", "[REDACTED_TOKEN]", value)
        value = re.sub(r"(Authorization:\s*(?:Token|Bearer|Basic)\s+)[^\s\"']+", r"\1[REDACTED]", value, flags=re.IGNORECASE)
        return value
    if isinstance(value, dict):
        return {scrub(key): scrub(child) for key, child in value.items()}
    if isinstance(value, list):
        return [scrub(child) for child in value]
    return value


def normalize_codex(raw, phase, code, schema_text, final_text, stderr=""):
    """Translate native exec events into the existing result contract.

    This parser does not invoke Codex. The adapter must supply a
    fresh, private --output-last-message capture as well as the JSONL stream.
    Tool errors may be recovered; only turn-level failures are terminal failures.
    """
    data = {}
    thread_seen = started = terminal = False
    message = None
    malformed = False
    try:
        for line in raw.splitlines():
            if not line.strip():
                continue
            event = loads(line)
            if not isinstance(event, dict) or not isinstance(event.get("type"), str):
                raise ValueError("Invalid event")
            kind = event["type"]
            if terminal:
                raise ValueError("Events after terminal result")
            if kind == "thread.started":
                if thread_seen or started or not isinstance(event.get("thread_id"), str) or not event["thread_id"]:
                    raise ValueError("Invalid thread start")
                thread_seen = True
            elif kind == "turn.started":
                if not thread_seen or started:
                    raise ValueError("Invalid turn start")
                started = True
            elif kind == "item.completed":
                item = event.get("item")
                if not isinstance(item, dict):
                    raise ValueError("Invalid item")
                if item.get("type") == "agent_message":
                    if not started or not isinstance(item.get("text"), str):
                        raise ValueError("Invalid message")
                    message = item["text"]
            elif kind in ("turn.completed", "turn.failed"):
                if not started:
                    raise ValueError("Terminal event without turn")
                terminal = True
                if kind == "turn.failed":
                    data.update(is_error=True, error=event.get("error") or "Worker turn failed")
                usage = event.get("usage")
                if isinstance(usage, dict):
                    data["usage"] = {"input_tokens": usage.get("input_tokens"),
                                     "output_tokens": usage.get("output_tokens"),
                                     "cache_read_input_tokens": usage.get("cached_input_tokens")}
            elif kind == "error":
                # A stream-level error must not be mistaken for an item-level
                # command failure that the agent subsequently recovered from.
                data.update(is_error=True, error=event.get("message") or "Worker stream error")
        if not terminal or message is None or not message.strip():
            malformed = True
        # Compare before redaction: different secrets must not become matching
        # final messages merely because both redact to the same placeholder.
        if final_text is None or message is None or final_text.rstrip("\n") != message.rstrip("\n"):
            malformed = True
    except (ValueError, TypeError):
        malformed = True

    if message is not None:
        data["result"] = message
    if not malformed and not data.get("is_error"):
        data["subtype"] = "success"
        if schema_text:
            try:
                data["structured_output"] = loads(final_text)
            except (ValueError, TypeError):
                pass  # Shared schema validation reports a missing/invalid result.

    result = normalize(json.dumps(data), phase, code, schema_text, stderr)
    result["engine"] = "codex"
    if malformed and not code and not data.get("is_error"):
        result.update(status="failed", error=dict(kind="transport", message="Incomplete or inconsistent Codex result"),
                      structured_output=None, schema_status="not_checked" if schema_text else "disabled")
    return result


def main():
    mode = sys.argv[1]
    if mode == "check-dependency":
        validator_for({})
    elif mode == "check-schema":
        with open(sys.argv[2], encoding="utf-8") as stream:
            schema = loads(stream.read())
        validator_for(schema)
        print(json.dumps(schema, separators=(",", ":")))
    elif mode == "normalize":
        with open(sys.argv[5], encoding="utf-8", errors="replace") as stream:
            stderr = stream.read()
        print(json.dumps(normalize(sys.stdin.read(), sys.argv[2], int(sys.argv[3]), sys.argv[4], stderr), separators=(",", ":")))
    elif mode == "normalize-codex":
        with open(sys.argv[5], encoding="utf-8", errors="replace") as stream:
            stderr = stream.read()
        try:
            with open(sys.argv[6], encoding="utf-8") as stream:
                final_text = stream.read()
        except (OSError, UnicodeError):
            final_text = None
        print(json.dumps(normalize_codex(sys.stdin.read(), sys.argv[2], int(sys.argv[3]), sys.argv[4], final_text, stderr), separators=(",", ":")))
    else:
        raise ValueError("Unknown operation")


if __name__ == "__main__":
    main()

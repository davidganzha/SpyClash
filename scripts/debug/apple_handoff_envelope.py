"""LLDB-only inspection of an owned Apple completion attempt.

Import with `command script import /absolute/path/apple_handoff_envelope.py`.
At AppleSessionCompletionSession's decidePolicyFor navigationAction breakpoint,
run `apple-handoff-envelope`. It does not resume, change policy, make requests,
read cookies/storage, or print a URL or query value. See README-apple-handoff.md.
"""

import hashlib
import json
from urllib.parse import parse_qsl, urlsplit


TRUSTED_HOSTS = {"spyclash.com", "app.base44.com"}
APP_ID = "69a0e57fa939f578082f8091"
# A closed vocabulary: unknown path segments and query names never reach output.
# These words are labels for observation, not a navigation allowlist.
PATH_WORDS = {
    "api", "apps", "auth", "sso", "login", "callback", "authorize", "token",
    "exchange", "code", "session", "complete", "success", "error", "redirect",
    "auth-error", "auth-success", "login-success", "set-session", "verify",
    "verification", "consent", "home", "functions", "appleAuthBroker",
    "MobileAppleAuthCallback.html", "MobileAuthCallback.html", "cdn-cgi",
    "challenge-platform", "v1", "v2",
}
QUERY_NAMES = {
    "action", "ticket", "code", "auth_code", "authorization_code", "state",
    "access_token", "auth_provider", "error", "error_description", "from_url",
    "redirect_uri", "returnTo", "app_id", "is_new_user", "session_id", "token",
}


def envelope(raw):
    """Returns only bounded labels, counts and a path digest; drops all values."""
    try:
        if not isinstance(raw, str) or len(raw.encode("utf-8")) > 64_000:
            return {"destination": "invalid"}
        parts = urlsplit(raw)
        canonical = (
            parts.scheme == "https" and parts.netloc in TRUSTED_HOSTS
            and parts.username is None and parts.password is None
            and parts.port is None
        )
        if not canonical:
            return {"destination": "noncanonical"}
        items = parse_qsl(parts.query, keep_blank_values=True, max_num_fields=32)
        names = [name for name, _ in items]
        path = parts.path
        segments = path.split("/")
        redacted = [
            "<app_id>" if segment == APP_ID else
            segment if segment in PATH_WORDS or segment == "" else "<other>"
            for segment in segments[:16]
        ]
        return {
            "destination": "trusted_https",
            "host": parts.hostname,
            "path_shape": "/".join(redacted),
            "path_sha256": hashlib.sha256(path.encode("utf-8")).hexdigest(),
            "path_segments": min(len(segments), 17),
            "query_names": sorted(set(names) & QUERY_NAMES),
            "other_query_names": min(sum(name not in QUERY_NAMES for name in names), 32),
            "duplicate_query_names": len(names) != len(set(names)),
            "has_fragment": bool(parts.fragment),
        }
    except (TypeError, ValueError, UnicodeError):
        return {"destination": "invalid"}


def inspect(debugger, command, result, internal_dict):
    # Import lazily, so envelope privacy checks run without LLDB or a device.
    import lldb

    if command.strip():
        result.SetError("apple-handoff-envelope accepts no arguments")
        return
    process = debugger.GetSelectedTarget().GetProcess()
    if not process.IsValid() or process.GetState() != lldb.eStateStopped:
        result.SetError("Pause an owned debug build at its Apple navigation policy first")
        return
    frame = process.GetSelectedThread().GetSelectedFrame()
    function = frame.GetFunctionName() or ""
    if "AppleSessionCompletionSession" not in function or "decidePolicyFor" not in function:
        result.SetError("Select the AppleSessionCompletionSession navigationAction policy frame")
        return
    options = lldb.SBExpressionOptions()
    options.SetLanguage(lldb.eLanguageTypeSwift)
    options.SetIgnoreBreakpoints(True)
    options.SetUnwindOnError(True)
    options.SetTimeoutInMicroSeconds(500_000)
    # The credential-bearing string stays transiently in debugger memory. Never
    # print evaluation errors: LLDB may embed source values in their messages.
    value = frame.EvaluateExpression('navigationAction.request.url?.absoluteString ?? ""', options)
    if not value.GetError().Success():
        result.SetError("Destination unavailable; use an unoptimized debug build with Swift symbols")
        return
    try:
        raw = json.loads(value.GetSummary() or "null")
    except (TypeError, ValueError):
        result.SetError("Destination summary unavailable; no data was displayed")
        return
    result.AppendMessage(json.dumps(envelope(raw), ensure_ascii=True, sort_keys=True))


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(
        "command script add -f " + __name__ + ".inspect apple-handoff-envelope"
    )

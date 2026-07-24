"""
Generic secret scrubber — data-driven public core.

Patterns are DATA (patterns-public.json), not code. Each pattern has a `class`:
  core       — unambiguous token shapes (PEM, AKIA, ghp_, JWT, ...). All tiers.
  dsn-creds  — connection strings WITH credentials (user:pass@). core+dsn-creds and full.
  prose      — label=value / shared-key. `full` only (noisy on code repos).

A --tier selects which classes apply:
  core            -> {core}
  core+dsn-creds  -> {core, dsn-creds}
  full            -> {core, dsn-creds, prose}

Vendor- or project-specific patterns (a SaaS token format, an integration domain,
non-English labels) are NEVER in this public file. They load at runtime from a
private overlay JSON (same schema) via --patterns, kept in the project Vault.
Only regex DATA is loaded — never executable code. Values are never printed.
"""
import json
import os
import re

TIERS = {
    "core": {"core"},
    "core+dsn-creds": {"core", "dsn-creds"},
    "full": {"core", "dsn-creds", "prose"},
}

_SECRETLIKE = re.compile(r"[\d!@#$%^&*]")


def _compile_flags(spec):
    flags = 0
    for ch in spec.get("flags", ""):
        flags |= {"i": re.I, "m": re.M, "s": re.S}.get(ch, 0)
    return flags


_REQUIRED = {"id", "regex", "replacement"}
_CLASSES = {"core", "dsn-creds", "prose"}


def load_patterns(path):
    """Load a pattern file (public or private overlay). Returns list of dicts:
    {id, class, rx (compiled), replacement, context (bool)}.

    Raises ValueError on any malformed pattern (missing key, bad class, invalid
    regex) so the caller can fail-closed with a clean message — never a traceback."""
    with open(path, "r", encoding="utf-8") as fh:
        doc = json.load(fh)
    if not isinstance(doc.get("patterns"), list):
        raise ValueError(f"{path}: top-level 'patterns' must be a list")
    out = []
    for s in doc["patterns"]:
        missing = _REQUIRED - set(s)
        if missing:
            raise ValueError(f"pattern {s.get('id', '?')!r} missing keys: {sorted(missing)}")
        cls = s.get("class", "core")
        if cls not in _CLASSES:
            raise ValueError(f"pattern {s['id']!r}: unknown class {cls!r}")
        try:
            rx = re.compile(s["regex"], _compile_flags(s))
        except re.error as e:
            raise ValueError(f"pattern {s['id']!r}: invalid regex: {e}")
        out.append({
            "id": s["id"],
            "class": cls,
            "rx": rx,
            "replacement": s["replacement"],
            "context": bool(s.get("context")),
            # weak_guard: {"secret": <group>, "compare": <group?>} — skip the match when the
            # captured credential is a well-known default or equals another group (user==pass).
            "weak_guard": s.get("weak_guard"),
        })
    return out


def _looks_secret(val):
    if "@" in val or "://" in val or val.startswith("/") or val.startswith("http"):
        return False
    if re.search(r"\.[a-z]{2,}\b", val, re.I):  # domain / filename
        return False
    if len(val) < 6 or len(val) > 64:
        return False
    return bool(_SECRETLIKE.search(val))


# Well-known default / dummy credentials — never a real leaked secret. This is a
# CURATED layer; an entropy layer can be added on top later without touching callers.
WEAK_SECRETS = {
    "postgres", "postgresql", "mysql", "mariadb", "mongo", "mongodb", "redis", "rabbitmq",
    "root", "admin", "administrator", "user", "username", "guest", "public", "anonymous",
    "password", "passwd", "pass", "pwd", "secret", "changeme", "change-me", "changethis",
    "example", "test", "testing", "tests", "demo", "sample", "dev", "develop", "development",
    "local", "localhost", "none", "null", "empty", "default", "temp", "temporary",
    "123456", "12345678", "123456789", "qwerty", "letmein", "abc123", "password123",
}

# Inline allow-marker: a line containing this token opts its matches out (deliberate
# fixtures / canaries). Self-documenting, visible in the diff, review-gated — replaces
# the central ignore-list, scales per-line without a growing file.
ALLOW_MARKER = "scrub:allow"


def _is_weak_cred(secret, compare=None):
    if compare is not None and secret == compare:   # user == pass
        return True
    return secret.lower() in WEAK_SECRETS


def _line_allows(text, pos):
    ls = text.rfind("\n", 0, pos) + 1
    le = text.find("\n", pos)
    le = len(text) if le < 0 else le
    return ALLOW_MARKER in text[ls:le]


PUBLIC_PATTERNS_PATH = os.path.join(os.path.dirname(__file__), "patterns-public.json")


def scrub(text, patterns, tier="core"):
    """Apply patterns whose class is enabled by `tier`. Returns (text, count).

    Per-match guards (uniform for every pattern): an inline `scrub:allow` marker on
    the match's line, a `context` free-text secret-likeness check, and a `weak_guard`
    default/dummy-credential skip. A match survives all guards -> redacted + counted."""
    if tier not in TIERS:
        raise ValueError(f"unknown tier {tier!r}; valid: {', '.join(TIERS)}")
    classes = TIERS[tier]
    counter = [0]
    for p in patterns:
        if p["class"] not in classes:
            continue
        ctx = p["context"]
        wg = p.get("weak_guard")
        repl_str = p["replacement"]

        def repl(m, ctx=ctx, wg=wg, repl_str=repl_str):
            if _line_allows(text, m.start()):
                return m.group(0)
            if ctx and not _looks_secret(m.group(2)):
                return m.group(0)
            if wg:
                secret = m.group(wg["secret"])
                compare = m.group(wg["compare"]) if wg.get("compare") else None
                if _is_weak_cred(secret, compare):
                    return m.group(0)
            counter[0] += 1
            return m.expand(repl_str)

        text = p["rx"].sub(repl, text)
    return text, counter[0]


TEXT_EXTS = {".md", ".txt", ".rst", ".jsonl", ".eml", ".json", ".yaml", ".yml",
             ".csv", ".toml", ".ini", ".env", ".cfg", ".sh", ".py", ".js", ".ts"}


def _is_binary(path):
    try:
        with open(path, "rb") as fh:
            return b"\x00" in fh.read(4096)
    except OSError:
        return True


def iter_files(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, _, files in os.walk(p):
                for f in files:
                    fp = os.path.join(root, f)
                    if os.path.splitext(f)[1].lower() in TEXT_EXTS and not _is_binary(fp):
                        yield fp
        elif os.path.isfile(p) and not _is_binary(p):
            yield p

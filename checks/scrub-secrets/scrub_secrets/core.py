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


def _apply_context(rx, replacement, text, counter):
    def repl(m):
        if _looks_secret(m.group(2)):
            counter[0] += 1
            return m.expand(replacement)
        return m.group(0)
    return rx.sub(repl, text)


PUBLIC_PATTERNS_PATH = os.path.join(os.path.dirname(__file__), "patterns-public.json")


def scrub(text, patterns, tier="core"):
    """Apply patterns whose class is enabled by `tier`. Returns (text, count)."""
    if tier not in TIERS:
        raise ValueError(f"unknown tier {tier!r}; valid: {', '.join(TIERS)}")
    classes = TIERS[tier]
    counter = [0]
    for p in patterns:
        if p["class"] not in classes:
            continue
        if p["context"]:
            text = _apply_context(p["rx"], p["replacement"], text, counter)
        else:
            text, n = p["rx"].subn(p["replacement"], text)
            counter[0] += n
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

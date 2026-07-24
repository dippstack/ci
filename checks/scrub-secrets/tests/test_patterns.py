"""Synthetic secrets only — no real keys, no vendor names. Every pattern gets a
positive case and a counter-example; tiers get boundary cases (a code-tier gate
must NOT fire on prose-class `password=`, which is what keeps code repos quiet).
"""
import json
import os
import tempfile

from scrub_secrets.core import scrub, load_patterns, PUBLIC_PATTERNS_PATH

PATTERNS = load_patterns(PUBLIC_PATTERNS_PATH)

# (label, text, tier, must_redact)
CASES = [
    # core — fire at every tier
    ("pem", "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----", "core", True),
    ("pem-prose", "generate a private key with openssl", "core", False),
    ("api-uuid", "api-12345678-1234-1234-1234-1234567890ab", "core", True),
    ("api-word", "the api-gateway service", "core", False),
    ("sk-ant", "sk-ant-abcdefghij0123456789KLMN", "core", True),
    ("ghp", "ghp_" + "a" * 36, "core", True),
    ("aws", "AKIAABCDEFGHIJKLMNOP", "core", True),
    ("aws-word", "AKIA is a prefix", "core", False),
    ("jwt", "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY.SflKxwRJSMeKKF2QT4", "core", True),
    ("bearer", "Authorization: Bearer abcdefghij0123456789KLMNOP", "core", True),

    # dsn-creds — the fix that started this: creds required, placeholder ignored
    ("dsn-creds-code", "postgres://user:s3cretPW@db.host:5432/app", "core+dsn-creds", True),
    ("dsn-bare", "postgres://localhost:5432/app", "core+dsn-creds", False),
    ("dsn-ellipsis", "connect with `postgres://…` for a shared server", "core+dsn-creds", False),
    ("dsn-not-in-core", "postgres://user:s3cretPW@db.host:5432/app", "core", False),  # core tier ignores DSN
    # pilot-discovered false positives: env-interpolated password / loopback test DBs must NOT fire
    ("dsn-env-pass", "DB_URL=postgres://postgres:${PG_PASS}@localhost:${PG_PORT}/gbrain", "core+dsn-creds", False),
    ("dsn-env-esc", "DATABASE_URL=postgresql://postgres:${esc}@postgres:5432/postgres", "core+dsn-creds", False),
    ("dsn-loopback", "DATABASE_URL: postgres://yan:yan@127.0.0.1:55432/yan", "core+dsn-creds", False),
    ("dsn-env-user", "postgres://${DB_USER}:x@remote:5432/db", "core+dsn-creds", False),
    ("dsn-localhostdb-real", "postgres://u:R3alPw99xz@localhostdb.example:5432/x", "core+dsn-creds", True),  # host merely starts with 'localhost'
    # weak/default creds are not real secrets (curated triviality layer) — skipped fleet-wide
    ("dsn-default-docker", "postgresql://postgres:postgres@postgres:5432/postgres", "core+dsn-creds", False),
    ("dsn-user-eq-pass", "postgres://svc:svc@prod.example.com:5432/app", "core+dsn-creds", False),
    ("dsn-weak-changeme", "postgres://app:changeme@prod.example.com/db", "core+dsn-creds", False),
    ("dsn-real-highentropy", "postgres://app:Xk9nOtweak12aB@prod.example.com/db", "core+dsn-creds", True),
    ("dsn-test-fixture", "postgres://u:p@h/db", "core+dsn-creds", False),
    ("dsn-short-pass", "postgres://user:abc@host/db", "core+dsn-creds", False),

    # prose — only at full; a code-tier gate must stay quiet on these
    ("password-full", "password=Hunter2xyz", "full", True),
    ("password-code-quiet", "password=Hunter2xyz", "core+dsn-creds", False),  # KEY: no FP on code repos
    ("token-full", "api_key: A1b2C3d4E5f6", "full", True),
    ("shared-key-full", "shared key: 9f8e7d6c5b4a", "full", True),
    ("password-word", "the password is wrong", "full", False),
    # prose false positives: `token = <prose>` in research docs is not a secret (entropy/shape gate)
    ("kv-prose-cyrillic", "token = a11y/perf-ручка", "full", False),   # non-ASCII value
    ("kv-prose-weak", "token=example", "full", False),                 # dictionary default
    ("kv-prose-path", "secret = /etc/ssl/cert", "full", False),        # path, not a secret
    ("kv-prose-short", "pwd = ok", "full", False),                     # too short / trivial
]


def test_tiered_patterns():
    for label, text, tier, must in CASES:
        out, n = scrub(text, PATTERNS, tier)
        if must:
            assert n >= 1 and "REDACTED" in out, f"{label}@{tier}: expected redaction, got {out!r}"
        else:
            assert n == 0, f"{label}@{tier}: unexpected redaction, got {out!r}"


def test_tier_is_cumulative():
    dsn = "postgres://u:p4ssW0rd9@h/db"
    assert scrub(dsn, PATTERNS, "core")[1] == 0
    assert scrub(dsn, PATTERNS, "core+dsn-creds")[1] == 1
    assert scrub(dsn, PATTERNS, "full")[1] == 1


def test_idempotent():
    text = "password=Hunter2xyz and postgres://u:p4ssW0rd9@h/db"
    once, _ = scrub(text, PATTERNS, "full")
    twice, n2 = scrub(once, PATTERNS, "full")
    assert once == twice and n2 == 0


def test_no_value_leak():
    out, _ = scrub("password=SuperSecret9", PATTERNS, "full")
    assert "SuperSecret9" not in out


def test_private_overlay():
    # overlay demonstrates vendor/private patterns loaded at runtime — neutral synthetic here.
    spec = {"patterns": [
        {"id": "vendor-x", "class": "core", "regex": r"\bZZ-[0-9]{6}\b", "replacement": "[REDACTED-VENDOR]"},
        {"id": "custom-label", "class": "prose", "context": True, "flags": "i",
         "regex": r"(customlabel\s*[:=]\s*)(\S{6,})", "replacement": r"\1[REDACTED]"},
    ]}
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(spec, fh)
        path = fh.name
    try:
        patterns = PATTERNS + load_patterns(path)
        out, n = scrub("code ZZ-123456 customlabel: Qwerty12", patterns, "full")
        assert "ZZ-123456" not in out and n >= 2
    finally:
        os.unlink(path)


def test_inline_allow_marker():
    # a deliberate fixture/canary on a line with the marker is skipped; without it, caught.
    got = scrub("key AKIAABCDEFGHIJKLMNOP  # scrub:allow", PATTERNS, "core")
    assert got[1] == 0, "marked line must be skipped"
    unmarked = scrub("key AKIAABCDEFGHIJKLMNOP", PATTERNS, "core")
    assert unmarked[1] == 1, "unmarked line must be caught"
    # marker only affects its own line
    two = "AKIAABCDEFGHIJKLMNOP  # scrub:allow\nAKIAZZZZZZZZZZZZZZZZ"
    assert scrub(two, PATTERNS, "core")[1] == 1, "marker must not leak to other lines"


def test_bad_tier_raises():
    import pytest
    with pytest.raises(ValueError):
        scrub("x", PATTERNS, "ful")


def test_load_patterns_rejects_malformed():
    import pytest
    for bad in (
        {"patterns": [{"id": "x", "regex": "a"}]},                  # missing replacement
        {"patterns": [{"id": "x", "regex": "(", "replacement": "y"}]},  # invalid regex
        {"patterns": [{"id": "x", "class": "nope", "regex": "a", "replacement": "y"}]},  # bad class
        {"patterns": "notalist"},                                   # patterns not a list
    ):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump(bad, fh)
            p = fh.name
        try:
            with pytest.raises(ValueError):
                load_patterns(p)
        finally:
            os.unlink(p)


def test_cli_requires_tier_and_flag_values():
    from scrub_secrets.cli import main
    assert main(["--check", "/dev/null"]) == 3      # no --tier
    assert main(["--tier"]) == 3                     # --tier without value
    assert main(["--tier", "ful", "--check", "/dev/null"]) == 3  # bad tier value
    assert main(["--patterns"]) == 3                 # --patterns without value

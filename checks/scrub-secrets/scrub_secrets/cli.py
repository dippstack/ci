"""CLI for the generic secret scrubber.

    scrub-secrets --tier core+dsn-creds --check <path...>   # CI gate: exit 2 if found
    scrub-secrets --tier full --in-place <path...>          # redact in place
    scrub-secrets --tier full --patterns .config/scrub-extra.json --check <path...>
    cat file | scrub-secrets --tier full                    # stdin -> stdout
    scrub-secrets --list-tiers
    scrub-secrets --version

--tier is validated (a typo fails loudly, never silently degrades). --patterns
loads a PRIVATE overlay (same schema) from the project Vault; may be repeated.
Only counts and file paths are printed — never secret values.
"""
import os
import sys

from . import __version__
from .core import scrub, load_patterns, iter_files, TIERS, PUBLIC_PATTERNS_PATH


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    mode = "in-place"
    tier = "core"
    overlays = []
    public_path = PUBLIC_PATTERNS_PATH
    paths = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--in-place":
            mode = "in-place"
        elif a == "--check":
            mode = "check"
        elif a == "--version":
            print(f"scrub-secrets {__version__}")
            return 0
        elif a == "--list-tiers":
            print(" ".join(TIERS))
            return 0
        elif a == "--tier":
            i += 1
            tier = argv[i]
        elif a == "--patterns":
            i += 1
            overlays.append(argv[i])
        elif a == "--public":
            i += 1
            public_path = argv[i]
        else:
            paths.append(a)
        i += 1

    if tier not in TIERS:
        sys.stderr.write(f"error: unknown --tier {tier!r}; valid: {', '.join(TIERS)}\n")
        return 3

    patterns = load_patterns(public_path)
    for ov in overlays:
        patterns += load_patterns(ov)

    if not paths:  # stdin -> stdout
        out, _ = scrub(sys.stdin.read(), patterns, tier)
        sys.stdout.write(out)
        return 0

    total = hits = red = 0
    for fp in iter_files(paths):
        try:
            with open(fp, "r", encoding="utf-8") as fh:
                data = fh.read()
        except (UnicodeDecodeError, IsADirectoryError, OSError):
            continue
        out, n = scrub(data, patterns, tier)
        total += 1
        if n:
            hits += 1
            red += n
            print(f"  [scrub] {n} secret(s) in {os.path.relpath(fp)}")
            if mode == "in-place":
                with open(os.path.realpath(fp), "w", encoding="utf-8") as fh:
                    fh.write(out)
    verb = "would redact" if mode == "check" else "redacted"
    print(f"[scrub] tier={tier}: {verb} {red} secret(s) across {hits}/{total} file(s)")
    return 2 if (mode == "check" and red) else 0


if __name__ == "__main__":
    sys.exit(main())

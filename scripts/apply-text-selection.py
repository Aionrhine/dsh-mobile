#!/usr/bin/env python3
"""Idempotently enable text selection on chat message bodies.

Upstream (Clarklevis1995/dsh-mobile) renders assistant Markdown and user
bubbles without `.textSelection(.enabled)`, so long-press never produces
selection handles. See issue #47.
"""
import pathlib
import sys

CONV = pathlib.Path("DeepSeekHarnessMobile/Views/ConversationView.swift")
MOD = ".textSelection(.enabled)"


def patch_after(lines, anchor, times=1):
    """Insert MOD right after the first `times` lines whose stripped text == anchor."""
    patched = 0
    out = []
    for line in lines:
        out.append(line)
        if patched < times and line.strip() == anchor:
            indent = line[: len(line) - len(line.lstrip())]
            out.append(f"{indent}{MOD}\n")
            patched += 1
    return out, patched


def main() -> int:
    if not CONV.exists():
        print(f"missing {CONV}", file=sys.stderr)
        return 1
    src = CONV.read_text(encoding="utf-8")
    if src.count(MOD) > 3:
        print("already patched, nothing to do")
        return 0

    lines = src.splitlines(keepends=True)
    lines, markdown_hits = patch_after(lines, ".dynamicTypeSize(.large)")
    lines, bubble_hits = patch_after(lines, "Text(item.text).appFont(.body)")

    if markdown_hits != 1 or bubble_hits != 1:
        print(
            f"anchor miss (markdown={markdown_hits}, bubble={bubble_hits}); "
            "upstream code moved, fix scripts/apply-text-selection.py",
            file=sys.stderr,
        )
        return 2

    CONV.write_text("".join(lines), encoding="utf-8")
    print("patched:", markdown_hits + bubble_hits, "sites")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
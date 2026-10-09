#!/usr/bin/env python3
"""Velostream worker runner — OpenRouter-routed models (deepseek, haiku, glm).

A thin shim over `velo_worker_runner.py`, which holds the whole implementation
and is parameterised by provider profile (#2007 F7).

The FILENAME is load-bearing and is why this is a shim rather than a rename:
`velo-dispatch`, `velo-pr-gate`, `velo-status`'s pgrep pattern and
`skills/velo-local/SKILL.md` all reference these paths, and velo-status names a
running worker from its process argv. Merging the two 1030-line near-clones
without breaking any of that means keeping both entry points and sharing the body.
"""
from __future__ import annotations

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from velo_worker_runner import run  # noqa: E402

if __name__ == "__main__":
    run("openrouter")

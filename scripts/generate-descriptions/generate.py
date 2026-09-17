#!/usr/bin/env python3
"""
Installory descriptions corpus generator.

Fetches one-line package descriptions from:
  - Homebrew formulae and casks  (bulk API — two requests total)
  - PyPI top packages            (seed list from hugovk/top-pypi-packages)
  - npm popular packages         (seed list from seeds/npm-seed-list.json)

Output: ../../App/Resources/descriptions.json

Usage:
  python3 generate.py                  full run (all registries, all packages)
  python3 generate.py --check          validate without replacing the corpus
  python3 generate.py --limit 500 --output /tmp/descriptions.json
  python3 generate.py --no-pip --output /tmp/descriptions.json

Partial runs (`--limit` or `--no-*`) never overwrite the production corpus by
default. Direct them to an explicit scratch `--output`, use `--check`, or pass
the intentionally unsafe `--allow-partial` override.

The script is resumable: per-package responses are cached in .cache/ and
reused on re-runs. Interrupt at any time — the next run picks up where
this one left off.

Seed lists (the package names to fetch) are committed in seeds/. If an
upstream seed source fails, the committed list is the fallback, ensuring
reproducible re-runs on air-gapped or rate-limited machines.

Requires Python 3.9+. No third-party dependencies (stdlib only).
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
OUTPUT = REPO_ROOT / "App" / "Resources" / "descriptions.json"
CACHE_DIR = SCRIPT_DIR / ".cache"
SEEDS_DIR = SCRIPT_DIR / "seeds"

MAX_DESC_LEN = 200  # Characters; longer descriptions are truncated with "…"

MANAGER_PREFIXES = ("brew", "brewCask", "pip", "npm")

# A full production generation must remain plausibly complete even when there is
# no prior corpus to compare against. They are intentionally conservative;
# last-good retention below provides the tighter release-to-release guard.
PRODUCTION_MIN_COUNTS = {
    "brew": 6_000,
    "brewCask": 3_500,
    "pip": 800,
    "npm": 200,
}

# Also protect against regressions relative to the checked-in last-good corpus.
# A single full run may lose at most 20% of any manager's descriptions.
LAST_GOOD_RETENTION = 0.80


class CorpusValidationError(ValueError):
    """Raised when generated output is unsafe or internally inconsistent."""

# ---------------------------------------------------------------------------
# Hardcoded npm fallback seed
# Used only when seeds/npm-seed-list.json is absent AND the npm search API
# is unreachable. Covers the most depended-upon packages as of 2026-05.
# ---------------------------------------------------------------------------

_NPM_HARDCODED_SEED: list[str] = [
    # Core utilities
    "lodash", "underscore", "ramda", "immer", "immutable",
    "rxjs", "async", "bluebird", "p-limit", "p-queue",
    # HTTP / networking
    "axios", "node-fetch", "got", "superagent", "ky",
    "cors", "helmet", "compression", "cookie-parser", "socket.io", "ws",
    # React ecosystem
    "react", "react-dom", "react-router", "react-router-dom",
    "redux", "react-redux", "@reduxjs/toolkit", "mobx", "zustand",
    "@testing-library/react", "react-query", "swr",
    # Meta-frameworks
    "next", "gatsby", "nuxt", "svelte", "@sveltejs/kit",
    # Vue / Angular
    "vue", "vuex", "vue-router", "@angular/core",
    # Build tools
    "webpack", "rollup", "parcel", "vite", "esbuild", "turbo", "nx", "lerna",
    # Babel
    "@babel/core", "@babel/preset-env", "@babel/preset-react",
    # TypeScript
    "typescript", "ts-node", "tsx",
    "@types/node", "@types/react", "@types/lodash",
    # Testing
    "jest", "vitest", "mocha", "chai", "jasmine",
    "cypress", "puppeteer", "playwright", "@playwright/test",
    "@testing-library/react",
    # Linting / formatting
    "eslint", "prettier", "stylelint",
    # Database / ORM
    "mongoose", "sequelize", "knex", "prisma", "typeorm",
    "pg", "mysql2", "sqlite3", "better-sqlite3", "redis", "ioredis",
    # Auth / security
    "jsonwebtoken", "passport", "bcrypt", "bcryptjs",
    # Validation
    "joi", "yup", "zod", "ajv",
    # CLI
    "commander", "yargs", "minimist", "inquirer",
    "chalk", "ora", "cli-progress", "boxen",
    # File system
    "glob", "rimraf", "mkdirp", "fs-extra", "chokidar",
    # Process management
    "nodemon", "pm2", "concurrently", "npm-run-all", "cross-env",
    # Date / time
    "moment", "dayjs", "date-fns", "luxon",
    # ID generation
    "uuid", "nanoid", "shortid",
    # Config / env
    "dotenv", "config", "convict",
    # Logging
    "winston", "pino", "morgan", "debug",
    # Web scraping / parsing
    "cheerio", "jsdom",
    # GraphQL
    "graphql", "@apollo/client", "apollo-server",
    # Misc
    "sharp", "nodemailer", "stripe", "aws-sdk",
    "tailwindcss", "sass", "postcss", "autoprefixer",
    "semver", "normalize-url", "husky", "lint-staged",
]

# The registry search API requires a real search term; `text=*` now returns 400.
# These deterministic terms span the major npm ecosystems while keeping refreshes
# bounded. Search results are popularity-weighted, paged at the documented API
# maximum, deduplicated across terms, and appended to committed seeds in stable
# lexical order.
_NPM_SEARCH_QUERIES: tuple[str, ...] = (
    "javascript",
    "typescript",
    "node",
    "react",
    "vue",
    "angular",
    "svelte",
    "web",
    "server",
    "cli",
    "testing",
    "build",
    "database",
    "http",
    "graphql",
    "css",
    "security",
    "validation",
    "logging",
)
_NPM_SEARCH_PAGE_SIZE = 250
_NPM_SEARCH_MAX_PAGES_PER_QUERY = 2
_NPM_SEARCH_MAX_NEW_NAMES = 5_000
_NPM_SEARCH_DELAY_SECONDS = 0.25

# ---------------------------------------------------------------------------
# Normalization
# ---------------------------------------------------------------------------

def normalize_pip(name: str) -> str:
    """PEP 503: lowercase then collapse runs of [-_.] to a single hyphen."""
    return re.sub(r"[-_.]+", "-", name.lower())


def normalize_npm(name: str) -> str:
    """npm names are already lowercase; just lowercase defensively."""
    return name.lower()

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

_UA = "Installory-description-generator/1.0 (https://github.com/william-ricchiuti/Installory)"


def _get(url: str, retries: int = 3) -> bytes:
    """Fetch URL bytes with exponential-backoff retries. Raises on final failure."""
    for attempt in range(retries):
        try:
            req = urllib.request.Request(
                url,
                headers={"User-Agent": _UA, "Accept": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.read()
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                raise  # permanent; don't retry
            if attempt == retries - 1:
                raise
            time.sleep(1.5 ** attempt)
        except Exception:
            if attempt == retries - 1:
                raise
            time.sleep(1.5 ** attempt)
    raise RuntimeError("unreachable")


def fetch_json(url: str) -> object:
    return json.loads(_get(url))


def truncate(text: str) -> str:
    """Trim to MAX_DESC_LEN, appending ellipsis if cut."""
    text = (text or "").strip()
    if len(text) > MAX_DESC_LEN:
        text = text[:MAX_DESC_LEN].rstrip() + "…"
    return text

# ---------------------------------------------------------------------------
# Homebrew
# ---------------------------------------------------------------------------

def fetch_homebrew() -> dict[str, str]:
    result: dict[str, str] = {}

    print("Homebrew: fetching formulae …", flush=True)
    formulae = fetch_json("https://formulae.brew.sh/api/formula.json")
    assert isinstance(formulae, list)
    for item in formulae:
        name = (item.get("name") or "").strip()
        desc = (item.get("desc") or "").strip()
        if name and desc:
            result[f"brew:{name}"] = truncate(desc)
    brew_count = sum(1 for k in result if k.startswith("brew:"))
    print(f"  {brew_count} formulae", flush=True)

    print("Homebrew: fetching casks …", flush=True)
    casks = fetch_json("https://formulae.brew.sh/api/cask.json")
    assert isinstance(casks, list)
    for item in casks:
        token = (item.get("token") or "").strip()
        desc = (item.get("desc") or "").strip()
        if token and desc:
            result[f"brewCask:{token}"] = truncate(desc)
    cask_count = sum(1 for k in result if k.startswith("brewCask:"))
    print(f"  {cask_count} casks", flush=True)

    return result

# ---------------------------------------------------------------------------
# PyPI
# ---------------------------------------------------------------------------

def _load_pypi_seed(limit: int | None) -> list[str]:
    seed_file = SEEDS_DIR / "pypi-seed-list.json"

    if seed_file.exists():
        with open(seed_file) as f:
            names: list[str] = json.load(f)
        print(f"  Using {len(names)} names from seeds/pypi-seed-list.json", flush=True)
    else:
        url = (
            "https://hugovk.github.io/top-pypi-packages/"
            "top-pypi-packages-30-days.min.json"
        )
        try:
            data = fetch_json(url)
            assert isinstance(data, dict) and "rows" in data
            names = [row["project"] for row in data["rows"]]
            SEEDS_DIR.mkdir(parents=True, exist_ok=True)
            with open(seed_file, "w") as f:
                json.dump(names, f, indent=2)
            print(
                f"  Fetched {len(names)} names → seeds/pypi-seed-list.json",
                flush=True,
            )
        except Exception as exc:
            print(
                f"  WARNING: could not fetch PyPI seed list: {exc}",
                file=sys.stderr,
                flush=True,
            )
            names = []

    return names[:limit] if limit is not None else names


def fetch_pypi(limit: int | None) -> dict[str, str]:
    print("PyPI: loading seed list …", flush=True)
    names = _load_pypi_seed(limit)
    if not names:
        print("  No PyPI packages to fetch.", flush=True)
        return {}

    print(f"PyPI: fetching {len(names)} packages …", flush=True)
    cache_dir = CACHE_DIR / "pypi"
    cache_dir.mkdir(parents=True, exist_ok=True)

    result: dict[str, str] = {}
    fetched = cached = failed = 0
    _bad_summaries = {"unknown", "fixme", "todo", "tbd", "n/a", "none", ""}

    for i, name in enumerate(names, 1):
        cache_file = cache_dir / f"{urllib.parse.quote(name, safe='')}.json"
        data: dict | None = None

        if cache_file.exists():
            try:
                with open(cache_file) as f:
                    data = json.load(f)
                cached += 1
            except Exception:
                cache_file.unlink(missing_ok=True)

        if data is None:
            try:
                raw = _get(f"https://pypi.org/pypi/{urllib.parse.quote(name)}/json")
                data = json.loads(raw)
                with open(cache_file, "wb") as f:
                    f.write(raw)
                fetched += 1
                time.sleep(0.12)
            except Exception as exc:
                failed += 1
                if failed <= 10:
                    print(f"  SKIP {name}: {exc}", file=sys.stderr, flush=True)
                continue

        if data:
            summary = ((data.get("info") or {}).get("summary") or "").strip()
            if summary.lower() not in _bad_summaries:
                key = f"pip:{normalize_pip(name)}"
                result[key] = truncate(summary)

        if i % 500 == 0:
            print(
                f"  … {i}/{len(names)} "
                f"(fetched={fetched}, cached={cached}, failed={failed})",
                flush=True,
            )

    print(
        f"  {len(result)} descriptions "
        f"(fetched={fetched}, cached={cached}, failed={failed})",
        flush=True,
    )
    return result

# ---------------------------------------------------------------------------
# npm
# ---------------------------------------------------------------------------

def _load_npm_seed(limit: int | None) -> list[str]:
    seed_file = SEEDS_DIR / "npm-seed-list.json"

    if seed_file.exists():
        with open(seed_file) as f:
            names: list[str] = json.load(f)
        print(f"  Using {len(names)} names from seeds/npm-seed-list.json", flush=True)
        # Attempt to expand if fewer than 1000 packages in the committed list
        # and no --limit flag is forcing a small run.
        if limit is None and len(names) < 1000:
            names = _try_expand_npm_seed(names, seed_file)
    else:
        print("  seeds/npm-seed-list.json not found; fetching from npm …", flush=True)
        names = _try_expand_npm_seed([], seed_file)

    return names[:limit] if limit is not None else names


def _try_expand_npm_seed(existing: list[str], seed_file: Path) -> list[str]:
    """Try to fetch a larger npm seed list from the registry search API.

    Each curated query fails independently, so a bad response never discards
    existing seeds or results from successful pages. Falls back to the hardcoded
    list only when search yields nothing new. Saves a stable result to seed_file
    so future runs are reproducible.
    """
    fetched_names: list[str] = []
    existing_set: set[str] = set()
    for raw_name in existing:
        if not isinstance(raw_name, str):
            continue
        name = normalize_npm(raw_name.strip())
        if name and name not in existing_set:
            fetched_names.append(name)
            existing_set.add(name)

    discovered: set[str] = set()
    page_size = min(max(_NPM_SEARCH_PAGE_SIZE, 1), 250)
    max_new_names = max(_NPM_SEARCH_MAX_NEW_NAMES, 0)
    reached_bound = False

    print("  Fetching npm seed list from registry search API …", flush=True)
    for query in _NPM_SEARCH_QUERIES:
        for page in range(max(_NPM_SEARCH_MAX_PAGES_PER_QUERY, 0)):
            from_idx = page * page_size
            params = urllib.parse.urlencode(
                (
                    ("text", query),
                    ("size", page_size),
                    ("from", from_idx),
                    ("quality", "0.0"),
                    ("maintenance", "0.0"),
                    ("popularity", "1.0"),
                )
            )
            url = (
                "https://registry.npmjs.org/-/v1/search"
                f"?{params}"
            )
            try:
                data = fetch_json(url)
                if not isinstance(data, dict) or not isinstance(data.get("objects"), list):
                    raise ValueError("response is missing an objects array")
                objects = data["objects"]
            except Exception as exc:
                print(
                    f"  WARNING: npm search query {query!r} at offset "
                    f"{from_idx} failed: {exc}",
                    file=sys.stderr,
                    flush=True,
                )
                break

            if not objects:
                break

            page_names: set[str] = set()
            for obj in objects:
                if not isinstance(obj, dict):
                    continue
                package = obj.get("package")
                if not isinstance(package, dict):
                    continue
                raw_name = package.get("name")
                if not isinstance(raw_name, str):
                    continue
                name = normalize_npm(raw_name.strip())
                if name:
                    page_names.add(name)

            for name in sorted(page_names):
                if name in existing_set or name in discovered:
                    continue
                if len(discovered) >= max_new_names:
                    reached_bound = True
                    break
                discovered.add(name)
                if len(discovered) >= max_new_names:
                    reached_bound = True
                    break

            if reached_bound:
                break

            total = data.get("total")
            consumed = from_idx + len(objects)
            if isinstance(total, int) and not isinstance(total, bool) and consumed >= total:
                break
            if len(objects) < page_size:
                break
            time.sleep(_NPM_SEARCH_DELAY_SECONDS)

        if reached_bound:
            break

    if discovered:
        fetched_names.extend(sorted(discovered))
    else:
        print(
            "  WARNING: npm search produced no new names. "
            "Using the hardcoded fallback seed.",
            file=sys.stderr,
            flush=True,
        )
        fallback_additions = 0
        for raw_name in _NPM_HARDCODED_SEED:
            name = normalize_npm(raw_name.strip())
            if name not in existing_set:
                if fallback_additions >= max_new_names:
                    break
                fetched_names.append(name)
                existing_set.add(name)
                fallback_additions += 1

    print(f"  Fetched {len(fetched_names)} names total.", flush=True)

    if fetched_names:
        seed_file.parent.mkdir(parents=True, exist_ok=True)
        serialized = json.dumps(fetched_names, indent=2) + "\n"
        if not seed_file.exists() or seed_file.read_text(encoding="utf-8") != serialized:
            seed_file.write_text(serialized, encoding="utf-8")
            print(f"  Saved {len(fetched_names)} names → {seed_file.name}", flush=True)

    return fetched_names


def fetch_npm(limit: int | None) -> dict[str, str]:
    print("npm: loading seed list …", flush=True)
    names = _load_npm_seed(limit)
    if not names:
        print("  No npm packages to fetch.", flush=True)
        return {}

    print(f"npm: fetching {len(names)} packages …", flush=True)
    cache_dir = CACHE_DIR / "npm"
    cache_dir.mkdir(parents=True, exist_ok=True)

    result: dict[str, str] = {}
    fetched = cached = failed = 0

    for i, name in enumerate(names, 1):
        # Filesystem-safe cache key: @scope/pkg → AT_scope__pkg
        safe_name = name.replace("@", "AT_").replace("/", "__")
        cache_file = cache_dir / f"{safe_name}.json"
        data: dict | None = None

        if cache_file.exists():
            try:
                with open(cache_file) as f:
                    data = json.load(f)
                cached += 1
            except Exception:
                cache_file.unlink(missing_ok=True)

        if data is None:
            # Scoped packages: @types/node → @types%2Fnode (@ kept, / encoded)
            encoded = urllib.parse.quote(name, safe="@")
            url = f"https://registry.npmjs.org/{encoded}/latest"
            try:
                raw = _get(url)
                data = json.loads(raw)
                with open(cache_file, "wb") as f:
                    f.write(raw)
                fetched += 1
                time.sleep(0.12)
            except Exception as exc:
                failed += 1
                if failed <= 10:
                    print(f"  SKIP {name}: {exc}", file=sys.stderr, flush=True)
                continue

        if data:
            desc = (data.get("description") or "").strip()
            if desc:
                key = f"npm:{normalize_npm(name)}"
                result[key] = truncate(desc)

        if i % 500 == 0:
            print(
                f"  … {i}/{len(names)} "
                f"(fetched={fetched}, cached={cached}, failed={failed})",
                flush=True,
            )

    print(
        f"  {len(result)} descriptions "
        f"(fetched={fetched}, cached={cached}, failed={failed})",
        flush=True,
    )
    return result

# ---------------------------------------------------------------------------
# Corpus validation and output
# ---------------------------------------------------------------------------


def description_counts(descriptions: dict[str, str]) -> dict[str, int]:
    """Return manager counts after validating every description entry."""
    counts = {manager: 0 for manager in MANAGER_PREFIXES}

    for key, description in descriptions.items():
        if not isinstance(key, str):
            raise CorpusValidationError("description keys must be strings")
        manager, separator, name = key.partition(":")
        if not separator or manager not in counts or not name:
            raise CorpusValidationError(f"invalid description key: {key!r}")
        if not isinstance(description, str) or not description.strip():
            raise CorpusValidationError(f"description for {key!r} must be non-empty text")
        if len(description) > MAX_DESC_LEN + 1:
            raise CorpusValidationError(
                f"description for {key!r} exceeds the {MAX_DESC_LEN}-character limit"
            )
        if manager == "pip" and name != normalize_pip(name):
            raise CorpusValidationError(f"pip key is not PEP 503 normalized: {key!r}")
        if manager == "npm" and name != normalize_npm(name):
            raise CorpusValidationError(f"npm key is not lowercase: {key!r}")
        counts[manager] += 1

    return counts


def build_corpus(
    descriptions: dict[str, str],
    *,
    generated: str | None = None,
) -> dict[str, object]:
    """Build a corpus whose declared counts are derived from its keys."""
    return {
        "generated": generated or datetime.now(timezone.utc).isoformat(),
        "counts": description_counts(descriptions),
        "descriptions": descriptions,
    }


def validate_corpus(
    corpus: object,
    *,
    enforce_production_floors: bool = False,
    last_good_counts: dict[str, int] | None = None,
) -> None:
    """Validate schema, key/count consistency, and optional production floors."""
    if not isinstance(corpus, dict):
        raise CorpusValidationError("corpus root must be a JSON object")

    generated = corpus.get("generated")
    counts = corpus.get("counts")
    descriptions = corpus.get("descriptions")
    if not isinstance(generated, str) or not generated.strip():
        raise CorpusValidationError("corpus.generated must be a non-empty timestamp")
    try:
        datetime.fromisoformat(generated.replace("Z", "+00:00"))
    except ValueError as exc:
        raise CorpusValidationError("corpus.generated must be an ISO-8601 timestamp") from exc

    if not isinstance(counts, dict) or set(counts) != set(MANAGER_PREFIXES):
        raise CorpusValidationError(
            f"corpus.counts must contain exactly: {', '.join(MANAGER_PREFIXES)}"
        )
    for manager, count in counts.items():
        if isinstance(count, bool) or not isinstance(count, int) or count < 0:
            raise CorpusValidationError(f"count for {manager!r} must be a non-negative integer")
    if not isinstance(descriptions, dict):
        raise CorpusValidationError("corpus.descriptions must be a JSON object")

    actual_counts = description_counts(descriptions)
    if counts != actual_counts:
        raise CorpusValidationError(
            f"declared counts {counts!r} do not match description keys {actual_counts!r}"
        )
    if sum(counts.values()) != len(descriptions):
        raise CorpusValidationError("manager counts do not add up to the description total")

    if not enforce_production_floors:
        return

    for manager in MANAGER_PREFIXES:
        minimum = PRODUCTION_MIN_COUNTS[manager]
        if last_good_counts is not None:
            previous = last_good_counts.get(manager)
            if isinstance(previous, int) and not isinstance(previous, bool):
                minimum = max(minimum, math.ceil(previous * LAST_GOOD_RETENTION))
        if counts[manager] < minimum:
            raise CorpusValidationError(
                f"{manager} produced {counts[manager]} descriptions; "
                f"a production write requires at least {minimum}"
            )


def load_corpus(path: Path) -> dict[str, object]:
    """Load and structurally validate an existing last-good corpus."""
    try:
        with open(path, encoding="utf-8") as file:
            corpus = json.load(file)
    except (OSError, json.JSONDecodeError) as exc:
        raise CorpusValidationError(f"could not read last-good corpus at {path}: {exc}") from exc
    validate_corpus(corpus)
    return corpus


def write_corpus_atomic(corpus: dict[str, object], output: Path) -> None:
    """Write compact JSON beside the destination, then atomically replace it."""
    validate_corpus(corpus)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=output.parent,
            prefix=f".{output.name}.",
            suffix=".tmp",
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
            json.dump(corpus, temporary, ensure_ascii=False, separators=(",", ":"))
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_path, output)
        temporary_path = None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate Installory package descriptions corpus."
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        metavar="N",
        help="Cap pip and npm to N packages each (useful for fast partial runs).",
    )
    parser.add_argument("--no-pip", action="store_true", help="Skip PyPI.")
    parser.add_argument("--no-npm", action="store_true", help="Skip npm.")
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        metavar="PATH",
        help=(
            "Write to PATH instead of the production corpus. Partial runs are safe "
            "when directed to a separate output."
        ),
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help=(
            "Fetch and validate without replacing an output corpus. "
            "Ignored caches and missing seed files may still be updated."
        ),
    )
    parser.add_argument(
        "--allow-partial",
        action="store_true",
        help=(
            "Explicitly allow --limit/--no-* output to replace the production corpus. "
            "This bypasses production count floors and is intentionally unsafe."
        ),
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _argument_parser()
    args = parser.parse_args(argv)

    if args.limit is not None and args.limit <= 0:
        parser.error("--limit must be greater than zero")

    partial = args.limit is not None or args.no_pip or args.no_npm
    output = (args.output or OUTPUT).expanduser().resolve()
    production_output = output == OUTPUT.resolve()

    if args.allow_partial and not partial:
        parser.error("--allow-partial is only valid with --limit or --no-*")
    if partial and production_output and not args.check and not args.allow_partial:
        parser.error(
            "partial runs cannot overwrite App/Resources/descriptions.json by default; "
            "use --output PATH, --check, or explicitly pass --allow-partial"
        )

    descriptions: dict[str, str] = {}

    # Homebrew is always fetched — it's bulk and fast.
    descriptions.update(fetch_homebrew())

    if not args.no_pip:
        descriptions.update(fetch_pypi(args.limit))

    if not args.no_npm:
        descriptions.update(fetch_npm(args.limit))

    try:
        corpus = build_corpus(descriptions)
        last_good_counts: dict[str, int] | None = None
        enforce_production_floors = production_output and not partial
        if enforce_production_floors and output.exists():
            last_good = load_corpus(output)
            stored_counts = last_good["counts"]
            assert isinstance(stored_counts, dict)
            last_good_counts = {
                manager: stored_counts[manager] for manager in MANAGER_PREFIXES
            }
        validate_corpus(
            corpus,
            enforce_production_floors=enforce_production_floors,
            last_good_counts=last_good_counts,
        )
    except CorpusValidationError as exc:
        print(f"\nERROR: refusing to replace the corpus: {exc}", file=sys.stderr)
        return 1

    counts = corpus["counts"]
    assert isinstance(counts, dict)
    total = sum(counts.values())
    if args.check:
        print(f"\n✓ {total} descriptions validated; output corpus unchanged")
    else:
        write_corpus_atomic(corpus, output)
        try:
            display_output = output.relative_to(REPO_ROOT)
        except ValueError:
            display_output = output
        print(f"\n✓ {total} descriptions written atomically to {display_output}")
    print(
        f"  brew={counts['brew']}, cask={counts['brewCask']}, "
        f"pip={counts['pip']}, npm={counts['npm']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

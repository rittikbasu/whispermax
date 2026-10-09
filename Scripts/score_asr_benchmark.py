#!/usr/bin/env python3
"""Score JSONL transcription output against a local reference manifest."""

from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from pathlib import Path


TOKEN = re.compile(r"[^\W_]+(?:['’][^\W_]+)*", re.UNICODE)
LATENCY_KEYS = ("latency_seconds", "processing_seconds", "request_seconds")


def read_json(path: Path):
    with path.open(encoding="utf-8") as source:
        return json.load(source)


def read_jsonl(path: Path) -> list[dict]:
    rows = []
    with path.open(encoding="utf-8") as source:
        for line_number, line in enumerate(source, 1):
            if not line.strip():
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as error:
                raise ValueError(f"{path}:{line_number}: {error.msg}") from error
    return rows


def tokens(text: str) -> list[str]:
    normalized = unicodedata.normalize("NFKC", text).casefold()
    return TOKEN.findall(normalized)


def edit_distance(left, right) -> int:
    if len(left) < len(right):
        left, right = right, left
    previous = list(range(len(right) + 1))
    for index, item in enumerate(left, 1):
        current = [index]
        for column, other in enumerate(right, 1):
            current.append(min(
                current[-1] + 1,
                previous[column] + 1,
                previous[column - 1] + (item != other),
            ))
        previous = current
    return previous[-1]


def contains_phrase(haystack: list[str], phrase: list[str]) -> bool:
    return any(haystack[i:i + len(phrase)] == phrase for i in range(len(haystack)))


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def score(manifest_path: Path, results_path: Path, label: str) -> dict:
    manifest = read_json(manifest_path)
    if isinstance(manifest, dict):
        manifest = manifest.get("samples")
    if not isinstance(manifest, list):
        raise ValueError("manifest must be a list or an object with a samples list")

    references = {}
    for row in manifest:
        sample_id = row.get("sample_id")
        if not sample_id or sample_id in references:
            raise ValueError(f"manifest has a missing or duplicate sample_id: {sample_id!r}")
        references[sample_id] = row

    predictions = {}
    result_rows = read_jsonl(results_path)
    for row in result_rows:
        sample_id = row.get("sample_id")
        if not sample_id or sample_id in predictions:
            raise ValueError(f"results have a missing or duplicate sample_id: {sample_id!r}")
        if not isinstance(row.get("text"), str):
            raise ValueError(f"result {sample_id!r} has no string text field")
        predictions[sample_id] = row

    missing = sorted(references.keys() - predictions.keys())
    extra = sorted(predictions.keys() - references.keys())
    if missing or extra:
        raise ValueError(f"sample mismatch: {len(missing)} missing, {len(extra)} extra")

    word_errors = reference_words = char_errors = reference_chars = 0
    exact = failed_terms = failed_samples = 0
    latencies = []
    for sample_id, reference in references.items():
        expected = tokens(reference.get("reference", ""))
        actual = tokens(predictions[sample_id]["text"])
        word_errors += edit_distance(expected, actual)
        reference_words += len(expected)
        expected_chars = " ".join(expected)
        actual_chars = " ".join(actual)
        char_errors += edit_distance(expected_chars, actual_chars)
        reference_chars += len(expected_chars)
        exact += expected == actual

        misses = 0
        for term in reference.get("protected_terms", []):
            phrase = tokens(term)
            if phrase and not contains_phrase(actual, phrase):
                misses += 1
        failed_terms += misses
        failed_samples += bool(misses)

        result = predictions[sample_id]
        latency_key = next((key for key in LATENCY_KEYS if key in result), None)
        if latency_key:
            latencies.append(float(result[latency_key]))

    summary = {
        "label": label,
        "samples": len(references),
        "reference_words": reference_words,
        "word_edits": word_errors,
        "wer_percent": round(100 * word_errors / reference_words, 3),
        "reference_characters": reference_chars,
        "character_edits": char_errors,
        "cer_percent": round(100 * char_errors / reference_chars, 3),
        "exact_transcripts": exact,
        "protected_term_misses": failed_terms,
        "samples_with_protected_term_miss": failed_samples,
    }
    if latencies:
        summary["latency_ms"] = {
            "p50": round(percentile(latencies, 0.50) * 1000, 1),
            "p95": round(percentile(latencies, 0.95) * 1000, 1),
        }
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True, help="JSONL with sample_id and text")
    parser.add_argument("--label", default="model")
    args = parser.parse_args()
    try:
        result = score(args.manifest, args.results, args.label)
    except (OSError, ValueError, TypeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

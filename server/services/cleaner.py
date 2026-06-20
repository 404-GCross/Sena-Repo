"""Filename cleaner — extract platform and game name from archive filenames."""

from __future__ import annotations

import re

from models.game import Platform
from utils.regex_patterns import (
    ExtractionResult,
    compile_custom_patterns,
    extract_platform_and_name,
)


def clean_filename(
    filename: str,
    custom_patterns: list[dict] | None = None,
) -> ExtractionResult | None:
    """Extract platform and game name from a filename.

    Args:
        filename: The archive filename (e.g. "[PC]Game1.rar").
        custom_patterns: Optional list of custom regex patterns from config.

    Returns:
        ExtractionResult if recognized, None if not a game file.
    """
    compiled = compile_custom_patterns(custom_patterns or [])
    result = extract_platform_and_name(filename, compiled)

    if result is None:
        return None

    # Remove any remaining brackets or whitespace artifacts from game name
    result.game_name = _clean_name(result.game_name)
    return result


def _clean_name(name: str) -> str:
    """Clean up the extracted game name."""
    # Remove any remaining bracket pairs
    name = re.sub(r"\[.*?\]", "", name)
    name = re.sub(r"【.*?】", "", name)
    name = re.sub(r"\(.*?\)", "", name)
    # Trim and collapse whitespace
    name = re.sub(r"\s+", " ", name).strip()
    # Remove trailing version patterns (v1.0, 1.0.2) but NOT standalone numbers (sequel markers)
    name = re.sub(r"\s*v?\d+\.\d+(\.\d+)*$", "", name).strip()
    # Remove platform-related suffixes
    name = re.sub(r"\s*安卓直装版", "", name).strip()
    name = re.sub(r"\s*直装版", "", name).strip()
    return name


def normalize_company_name(name: str) -> str:
    """Normalize a company/folder name for consistent matching."""
    return name.strip()

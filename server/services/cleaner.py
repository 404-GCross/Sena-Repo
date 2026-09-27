"""Filename cleaner — normalize game folder names."""

from __future__ import annotations

import re


def _clean_name(name: str) -> str:
    """Clean up a game name."""
    # Remove bracket pairs
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

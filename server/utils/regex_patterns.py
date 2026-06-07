"""Regex patterns for extracting platform and game name from filenames."""

from __future__ import annotations

import re
from dataclasses import dataclass

from models.game import Platform


@dataclass
class ExtractionResult:
    platform: Platform
    game_name: str


# Built-in patterns ordered by priority (first match wins)
BUILTIN_PATTERNS: list[tuple[re.Pattern, Platform]] = [
    # [PC]GameName.rar
    (re.compile(r"\[PC\](.+)", re.IGNORECASE), Platform.PC),
    # [KRKR]GameName.zip
    (re.compile(r"\[KRKR\](.+)", re.IGNORECASE), Platform.KRKR),
    # [KR]GameName.zip (alternative KRKR notation)
    (re.compile(r"\[KR\](.+)", re.IGNORECASE), Platform.KRKR),
    # [Ty]GameName.zip
    (re.compile(r"\[Ty\](.+)", re.IGNORECASE), Platform.TYRANOR),
    # [ONS]GameName.7z
    (re.compile(r"\[ONS\](.+)", re.IGNORECASE), Platform.ONS),
    # 直装_GameName.apk
    (re.compile(r"直装_(.+)", re.IGNORECASE), Platform.DIRECT),

    # ── Fallback: fuzzy patterns for files without brackets ──

    # Contains "安卓直装" or "直装版" in name
    (re.compile(r"(.+?)安卓", re.IGNORECASE), Platform.DIRECT),
    (re.compile(r"(.+?)直装", re.IGNORECASE), Platform.DIRECT),
    # Contains "kirikiroid" → KRKR
    (re.compile(r"(?i).*kirikiroid.*(.+)", re.IGNORECASE), Platform.KRKR),
    # Contains "tyranor" → Tyranor
    (re.compile(r"(?i).*tyranor.*(.+)", re.IGNORECASE), Platform.TYRANOR),
]

# Extensions that indicate Android直装 even without explicit marker
DIRECT_INSTALL_EXTENSIONS = {".apk"}


def extract_platform_and_name(
    filename: str, custom_patterns: list[tuple[re.Pattern, str]] | None = None
) -> ExtractionResult | None:
    """Extract platform and game name from a filename.

    Returns None if no pattern matches (non-game file).
    The game name is cleaned of the file extension.
    """
    # Remove file extension for matching
    name_no_ext = re.sub(r"\.(rar|zip|7z|apk|tar|gz|xz)$", "", filename, flags=re.IGNORECASE)

    # Try custom patterns first
    if custom_patterns:
        for pattern, platform_str in custom_patterns:
            m = pattern.match(name_no_ext)
            if m:
                try:
                    platform = Platform(platform_str)
                except ValueError:
                    continue
                game_name = m.group("name") if "name" in pattern.groupindex else m.group(1)
                return ExtractionResult(platform=platform, game_name=game_name.strip())

    # Try built-in patterns
    for pattern, platform in BUILTIN_PATTERNS:
        m = pattern.match(name_no_ext)
        if m:
            return ExtractionResult(
                platform=platform,
                game_name=m.group(1).strip(),
            )

    # Fallback: any .apk without a recognized platform = Android直装
    if re.search(r"\.apk$", filename, re.IGNORECASE):
        return ExtractionResult(
            platform=Platform.DIRECT,
            game_name=re.sub(r"\.apk$", "", filename, flags=re.IGNORECASE).strip(),
        )

    # Fallback: any archive without a recognized platform = PC
    if re.search(r"\.(rar|zip|7z|tar|gz|xz)$", filename, re.IGNORECASE):
        return ExtractionResult(
            platform=Platform.PC,
            game_name=name_no_ext.strip(),
        )

    return None


def compile_custom_patterns(
    patterns: list[dict],
) -> list[tuple[re.Pattern, str]]:
    """Compile custom regex patterns from config.

    Each pattern dict should have:
        - pattern: regex string (must have 'name' group)
        - platform: platform string (PC, KRKR, Ty, ONS, 直装)
    """
    compiled = []
    for p in patterns:
        pattern_str = p.get("pattern", "")
        platform_str = p.get("platform", "")
        if not pattern_str or not platform_str:
            continue
        try:
            compiled.append((re.compile(pattern_str, re.IGNORECASE), platform_str))
        except re.error:
            continue
    return compiled

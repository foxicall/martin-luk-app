#!/usr/bin/env python3
"""Build the bundled offline UI font from an existing local CJK font.

This is a maintenance utility, not a preview/build prerequisite: the generated
font is committed in assets/fonts/. It never downloads a font or license.
Requires fontTools (``python -m pip install fonttools``). Use the exact font and
copyright supplied by your distributor when overriding the source paths.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from fontTools import subset
from fontTools.ttLib import TTFont


FAMILY = "MartinPreviewSans"
POSTSCRIPT_NAME = f"{FAMILY}-Regular"


def license_text(copyright_path: Path, original_copyright: str) -> str:
    """Preserve the distributor's font copyright and verbatim OFL 1.1 text."""
    source = copyright_path.read_text(encoding="utf-8")
    # Debian's copyright format indents license paragraphs and encodes blank
    # lines as a single dot. Decode only this formatting, without paraphrasing.
    marker = "License: SIL-1.1\n"
    sections = source.split(marker)
    license_section = next(
        (section for section in sections[1:] if "SIL OPEN FONT LICENSE" in section),
        None,
    )
    if license_section is None:
        raise ValueError(f"No complete SIL OFL 1.1 found in {copyright_path}")
    paragraphs: list[str] = []
    for line in license_section.splitlines():
        if line.startswith("License:"):
            break
        value = line[1:] if line.startswith(" ") else line
        paragraphs.append("" if value == "." else value)
    body = "\n".join(paragraphs).strip()
    if "OTHER DEALINGS IN THE FONT SOFTWARE." not in body:
        raise ValueError("OFL source is incomplete; cannot redistribute font")
    font_stanza = source.split("Files: *\n", 1)[1].split("\n\n", 1)[0]
    distributor_notice = font_stanza.split("\nLicense:", 1)[0].strip()
    return (
        f"{original_copyright}\n{distributor_notice}\n\n"
        "Bundled derivative: MartinPreviewSans (Traditional Chinese UI subset).\n"
        "Original font: Noto Sans CJK TC Regular.\n"
        "Source: https://github.com/notofonts/noto-cjk\n\n"
        f"{body}\n"
    )


def rename_font(font: TTFont) -> None:
    """Rename the modified font, including CFF internal names."""
    names = {
        1: FAMILY,
        2: "Regular",
        3: f"MartinPreviewSans;Regular;UI-Subset-1",
        4: f"{FAMILY} Regular",
        6: POSTSCRIPT_NAME,
        16: FAMILY,
        17: "Regular",
        18: f"{FAMILY} Regular",
    }
    name_table = font["name"]
    name_table.names = [record for record in name_table.names if record.nameID not in names]
    for name_id, value in names.items():
        name_table.setName(value, name_id, 3, 1, 0x409)
        name_table.setName(value, name_id, 0, 4, 0)
    if "CFF " in font:
        cff = font["CFF "].cff
        cff.fontNames = [POSTSCRIPT_NAME]
        top = cff.topDictIndex[0]
        top.FamilyName = FAMILY
        top.FullName = f"{FAMILY} Regular"
        if hasattr(top, "FDArray"):
            for index, dictionary in enumerate(top.FDArray):
                if hasattr(dictionary, "FontName"):
                    dictionary.FontName = f"{POSTSCRIPT_NAME}-FDArray{index:02d}"


def requested_characters(project_root: Path) -> set[int]:
    """Include UI and stock dictionary names so autocomplete stays offline."""
    sources = sorted((project_root / "lib").rglob("*.dart"))
    preview = project_root / "preview" / "index.html"
    if preview.is_file():
        sources.append(preview)
    dictionary = project_root / "stocks_master.json"
    if dictionary.is_file():
        sources.append(dictionary)
    if not sources:
        raise ValueError(f"No application source found in {project_root}")
    requested = {ord(character) for path in sources for character in path.read_text(encoding="utf-8")}
    for start, end in [
        (0x20, 0x7E),       # Printable ASCII.
        (0x2000, 0x206F),   # Typography: dashes, quotes, ellipsis.
        (0x20A0, 0x20CF),   # Currency symbols.
        (0x2190, 0x21FF),   # Arrows.
        (0x3000, 0x303F),   # CJK punctuation.
        (0xFF00, 0xFFEF),   # Full-width and half-width forms.
    ]:
        requested.update(range(start, end + 1))
    return requested


def build(args: argparse.Namespace) -> dict[str, object]:
    if not args.source_font.is_file():
        raise FileNotFoundError(f"Local source font does not exist: {args.source_font}")
    if not args.license_source.is_file():
        raise FileNotFoundError(f"Local font license does not exist: {args.license_source}")
    font = TTFont(args.source_font, fontNumber=args.font_index, recalcTimestamp=False)
    try:
        original_family = font["name"].getDebugName(1)
        if original_family != "Noto Sans CJK TC":
            raise ValueError(f"Expected Traditional Chinese face, found {original_family!r}")
        original_copyright = font["name"].getDebugName(0) or ""
        license_notice = license_text(args.license_source, original_copyright)
        requested = requested_characters(args.project_root)
        original_cmap = font.getBestCmap()
        available = requested.intersection(original_cmap)
        missing_cjk = sorted(code for code in requested - available if 0x3400 <= code <= 0x9FFF)
        if missing_cjk:
            raise ValueError(f"Source font lacks UI Chinese glyphs: {missing_cjk}")
        options = subset.Options()
        options.name_IDs = ["*"]
        options.name_legacy = True
        options.name_languages = ["*"]
        options.layout_features = ["*"]
        options.notdef_glyph = True
        options.notdef_outline = True
        options.recalc_timestamp = False
        subsetter = subset.Subsetter(options=options)
        subsetter.populate(unicodes=available)
        subsetter.subset(font)
        rename_font(font)
        args.output_dir.mkdir(parents=True, exist_ok=True)
        extension = ".otf" if font.sfntVersion == "OTTO" else ".ttf"
        output = args.output_dir / f"{FAMILY}{extension}"
        font.save(output)
        (args.output_dir / "OFL.txt").write_text(license_notice, encoding="utf-8")
        with TTFont(output) as generated:
            missing = available - generated.getBestCmap().keys()
            if missing:
                raise ValueError(f"Subset lost requested glyphs: {sorted(missing)}")
            glyph_count = len(generated.getGlyphOrder())
        return {
            "font": str(output),
            "family": FAMILY,
            "bytes": output.stat().st_size,
            "glyphs": glyph_count,
            "covered_codepoints": len(available),
            "missing_cjk": missing_cjk,
            "unsupported_symbols": [f"U+{code:04X}" for code in sorted(requested - available) if code >= 0x20],
        }
    finally:
        font.close()


def main() -> None:
    project_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-font", type=Path, default=Path("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"))
    parser.add_argument("--font-index", type=int, default=3, help="TTC face index; default 3 is Traditional Chinese")
    parser.add_argument("--license-source", type=Path, default=Path("/usr/share/doc/fonts-noto-cjk/copyright"))
    parser.add_argument("--project-root", type=Path, default=project_root)
    parser.add_argument("--output-dir", type=Path, default=project_root / "assets" / "fonts")
    args = parser.parse_args()
    try:
        print(json.dumps(build(args), ensure_ascii=False, indent=2))
    except (OSError, ValueError) as error:
        parser.exit(1, f"Offline font generation failed: {error}\n")


if __name__ == "__main__":
    main()

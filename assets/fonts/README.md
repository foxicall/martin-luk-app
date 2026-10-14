# Offline preview font

`MartinPreviewSans.otf` is a renamed Traditional Chinese subset of Noto Sans
CJK TC Regular, bundled under the SIL Open Font License 1.1. See `OFL.txt` for
the original copyright notices and the complete license.

The font includes the current application UI, Mock and master dictionary stock names, ASCII, and
common punctuation/symbols. It avoids external Chinese font downloads during
Flutter Web preview. New API stock names may require additional glyphs: expand
this subset or bundle the complete original font under its license when using
arbitrary live-market data.

The included font is ready for Flutter; no regeneration or fontTools install is
required to preview or build the application. To regenerate after changing UI
or stock dictionary text, use existing local Noto Sans CJK TC font and distributor copyright:

```bash
python scripts/prepare_preview_font.py \
  --source-font /usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc \
  --font-index 3 \
  --license-source /usr/share/doc/fonts-noto-cjk/copyright
```

This maintenance script requires Python with fontTools and never downloads files.
The `font-index` is checked against the family name, so a different TTC face is
not silently bundled. Commit the regenerated font and retain `OFL.txt` together.

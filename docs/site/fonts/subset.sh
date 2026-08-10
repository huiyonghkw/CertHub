#!/usr/bin/env bash
# Regenerate fonts/hkw-sans-sc-subset.woff2 from all docs/site HTML+CSS text.
# 文案大改后必重跑，否则新字掉回 PingFang（最粗≈600），标题发虚。
# Needs: python3 + fontTools[woff]; source Noto Sans SC variable.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NOTO_SRC="${NOTO_SRC:-$HOME/.claude/skills/hekouwang-content-skill/assets/fonts/NotoSansSC-Variable-FULL.woff2}"
OUT="$ROOT/fonts/hkw-sans-sc-subset.woff2"
TMP="$(mktemp -t hkw-subset.XXXXXX.woff2)"
CHARS="$(mktemp -t hkw-chars.XXXXXX.txt)"

python3 - <<'PY' "$ROOT" "$CHARS"
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
text = ''
for p in sorted(root.rglob('*.html')):
    text += p.read_text(encoding='utf-8', errors='ignore')
text += (root / 'assets/site.css').read_text(encoding='utf-8')
# SVG labels also show on marketing pages
for p in sorted((root / 'images').glob('*.svg')):
    text += p.read_text(encoding='utf-8', errors='ignore')
text = re.sub(r'<script[^>]*>.*?</script>', '', text, flags=re.S|re.I)
text = re.sub(r'<style[^>]*>.*?</style>', '', text, flags=re.S|re.I)
text = re.sub(r'<[^>]+>', '', text)
extra = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789¥·→←✓'
# hero + pain must never miss
extra += '证书大概每90天一轮难的是部署产品痛点申请不是最难的'
chars = sorted(set(text + extra))
out = ''.join(c for c in chars if c not in '\r\n\t')
Path(sys.argv[2]).write_text(out, encoding='utf-8')
print('glyph request', len(out))
PY

[[ -f "$NOTO_SRC" ]] || { echo "Missing NOTO_SRC: $NOTO_SRC" >&2; exit 1; }

python3 -m fontTools.subset "$NOTO_SRC" \
  --output-file="$TMP" \
  --flavor=woff2 \
  --text-file="$CHARS" \
  --layout-features='*' \
  --glyph-names --symbol-cmap --legacy-cmap \
  --notdef-outline --notdef-glyph --recommended-glyphs

python3 - <<'PY' "$TMP"
from fontTools.ttLib import TTFont
from pathlib import Path
p = Path(__import__('sys').argv[1])
f = TTFont(p)
for nameID, s in [(1,'HKW Sans SC'),(2,'Regular'),(4,'HKW Sans SC'),(6,'HKWSansSC'),(16,'HKW Sans SC'),(17,'Regular')]:
    f['name'].setName(s, nameID, 3, 1, 0x409)
    f['name'].setName(s, nameID, 3, 1, 0x804)
f.save(p)
print('glyphs', len(f.getGlyphOrder()), 'size KB', round(p.stat().st_size/1024, 1))
PY

mv "$TMP" "$OUT"
rm -f "$CHARS"
echo "Wrote $OUT"

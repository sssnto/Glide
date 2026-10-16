#!/usr/bin/env python3
"""Build Glide's OFL subtitle fallback from Noto Sans CJK SC 2.004 (fonttools 4.60.1)."""
import argparse
import hashlib
from pathlib import Path
from fontTools.ttLib import TTFont

SOURCE_SHA256 = '2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b'


def prepare(source, target):
    if hashlib.sha256(source.read_bytes()).hexdigest() != SOURCE_SHA256:
        raise SystemExit('Unexpected Noto Sans CJK SC 2.004 source checksum')
    font = TTFont(source, recalcTimestamp=False)
    names = font['name']
    # libVLC 3's libass module hardcodes Helvetica Neue as its default family.
    # A legacy family alias lets its *default* cover CJK without overriding ASS
    # font tags, positions or styles. CoreText uses the separate typographic
    # family/PostScript name. Glyphs and original copyright/license stay intact.
    values = {1: 'Helvetica Neue', 2: 'Regular', 3: 'GlideSubtitleFallback-2.004',
              4: 'Glide Subtitle Fallback Regular', 6: 'GlideSubtitleFallback-Regular',
              16: 'Glide Subtitle Fallback', 17: 'Regular'}
    for record in list(names.names):
        if record.nameID in values:
            names.removeNames(nameID=record.nameID)
    for name_id, value in values.items():
        names.setName(value, name_id, 3, 1, 0x409)
        names.setName(value, name_id, 1, 0, 0)
    cff = font['CFF '].cff
    cff.fontNames = ['GlideSubtitleFallback-Regular']
    cff.topDictIndex[0].FamilyName = 'Glide Subtitle Fallback'
    cff.topDictIndex[0].FullName = 'Glide Subtitle Fallback Regular'
    target.parent.mkdir(parents=True, exist_ok=True)
    font.save(target)
    print(hashlib.sha256(target.read_bytes()).hexdigest(), target)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('target', type=Path)
    args = parser.parse_args()
    prepare(args.source, args.target)

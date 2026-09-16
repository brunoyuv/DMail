#!/usr/bin/env python3
# MPL-2.0. D-only metadata adaptation of Apache-2.0 MathJax TeX font.
from pathlib import Path
import hashlib, json
import fontTools
from fontTools.ttLib import TTFont
from fontTools.otlLib.builder import buildMathTable
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.boundsPen import BoundsPen

root = Path(__file__).resolve().parents[2]
source = root / '.tools/math-render/node_modules/@mathjax/mathjax-tex-font/chtml/woff2/mjx-tex-n.woff2'
out = root / '.tools/math-render/mathml-font'
out.mkdir(parents=True, exist_ok=True)
target = out / 'dmail-tex-mathml.woff2'
font = TTFont(source, recalcBBoxes=False, recalcTimestamp=False)
assert font['head'].unitsPerEm == 1000 and font['post'].underlineThickness == 0
# MathML Core uses post.underlineThickness when no OpenType MATH table exists.
# The CHTML font leaves it zero because C draws rules in CSS. Use C's pinned
# FontData.defaultParams.rule_thickness (0.06em), solely in D's font copy.
# https://www.w3.org/TR/mathml-core/#layout-constants-mathconstants
font['post'].underlineThickness = 60
# C carries these TeX values in JavaScript rather than in its web fonts. Native
# MathML needs a MATH table plus the actual display glyphs, not CSS scaling of
# the inline glyph. Keep unrelated constants at their previous MathML fallback
# values (rounded to font units); all existing outlines and advances stay fixed.
# MathConstants is a fixed-size table: omitting fields would encode zero, not
# retain the browser fallback. See MathML Core section 5.1.
os2 = font['OS/2']
constants = {
    'ScriptPercentScaleDown': 71, 'ScriptScriptPercentScaleDown': 50,
    'DisplayOperatorMinHeight': 1300, 'AxisHeight': 250,
    'UpperLimitGapMin': 111, 'UpperLimitBaselineRiseMin': 200,
    'LowerLimitGapMin': 167, 'LowerLimitBaselineDropMin': 600,
    'AccentBaseHeight': os2.sxHeight,
    # C script drops are multiplied by its script scale before positioning
    # against the base. Native MATH constants are in the base's font units.
    # Leaving these at zero wrongly raises inline sum superscripts to its top.
    'SubscriptShiftDown': 150, 'SubscriptBaselineDropMin': 50 * .71,
    'SubscriptTopMax': .8 * 442,
    'SuperscriptShiftUp': 363, 'SuperscriptShiftUpCramped': 289,
    'SuperscriptBaselineDropMax': 386 * .71,
    'SuperscriptBottomMin': .25 * 442,
    'SubSuperscriptGapMin': 180,
    'SuperscriptBottomMaxWithSubscript': .8 * 442,
    'SpaceAfterScript': 50,
    'StackGapMin': 180, 'StackDisplayStyleGapMin': 420,
    'FractionNumeratorGapMin': 60, 'FractionNumDisplayStyleGapMin': 180,
    'FractionRuleThickness': 60, 'FractionDenominatorGapMin': 60,
    'FractionDenomDisplayStyleGapMin': 180,
    'OverbarVerticalGap': 180, 'OverbarRuleThickness': 60, 'OverbarExtraAscender': 60,
    'UnderbarVerticalGap': 180, 'UnderbarRuleThickness': 60, 'UnderbarExtraDescender': 60,
    'RadicalVerticalGap': 75, 'RadicalDisplayStyleVerticalGap': 60 + .25 * os2.sxHeight,
    'RadicalRuleThickness': 60, 'RadicalExtraAscender': 60,
    'RadicalKernBeforeDegree': 5000 / 18, 'RadicalKernAfterDegree': -10000 / 18,
    'RadicalDegreeBottomRaisePercent': 60,
}
large_source = source.with_name('mjx-tex-lo.woff2')
large = TTFont(large_source, recalcBBoxes=False, recalcTimestamp=False)
assert large['head'].unitsPerEm == 1000
large_set, base_set = large.getGlyphSet(), font.getGlyphSet()
operators = [0x220F, 0x2210, 0x2211, 0x222B, 0x222C, 0x222D, 0x222E,
             0x22C0, 0x22C1, 0x22C2, 0x22C3, 0x2A00, 0x2A01, 0x2A02, 0x2A04, 0x2A06]
top = font['CFF '].cff.topDictIndex[0]
order = list(font.getGlyphOrder())
variants, corrections, added = {}, {}, {}
def height(glyph_set, name):
    pen = BoundsPen(glyph_set)
    glyph_set[name].draw(pen)
    return round(pen.bounds[3] - pen.bounds[1])
for code in operators:
    base_name = font.getBestCmap()[code]
    source_name = large.getBestCmap()[code]
    name = base_name + '.display'
    pen = T2CharStringPen(large['hmtx'][source_name][0], large_set)
    large_set[source_name].draw(pen)
    charstring = pen.getCharString(private=top.Private, globalSubrs=font['CFF '].cff.GlobalSubrs)
    top.CharStrings.charStrings[name] = len(top.CharStrings.charStringsIndex)
    top.CharStrings.charStringsIndex.append(charstring)
    order.append(name)
    font['hmtx'][name] = large['hmtx'][source_name]
    variants[base_name] = [(base_name, height(base_set, base_name)), (name, height(large_set, source_name))]
    added[name] = source_name
    if 0x222B <= code <= 0x222E:
        # Pinned C large-integral italic correction, for side scripts/limits.
        # C adds it to the layout width in JS. OpenType expects it included in
        # the advance, then subtracts it for lower scripts. Without that width,
        # native lower scripts overlap the integral's lower stroke.
        corrections[name] = 388
        advance, bearing = font['hmtx'][name]
        font['hmtx'][name] = (advance + corrections[name], bearing)
top.charset = order
font.setGlyphOrder(order)
buildMathTable(font, constants=constants, italicsCorrections=corrections,
               vertGlyphVariants=variants)
font.save(target)
original = TTFont(source, recalcBBoxes=False, recalcTimestamp=False)
adapted = TTFont(target, recalcBBoxes=False, recalcTimestamp=False)
assert set(adapted.keys()) == set(original.keys()) | {'MATH'}
for tag in original.keys():
    if tag not in ('GlyphOrder', 'head', 'post', 'CFF ', 'hmtx', 'hhea', 'maxp', 'OS/2', 'cmap'):
        assert original.getTableData(tag) == adapted.getTableData(tag), tag
assert adapted['post'].underlineThickness == 60
# Ignore only the file checksum in head; every other head value is preserved.
original['head'].checkSumAdjustment = adapted['head'].checkSumAdjustment
assert original.getTableData('head') == adapted.getTableData('head')
original['post'].underlineThickness = 60
assert original.getTableData('post') == adapted.getTableData('post')
# FontTools normalizes the last Unicode index for the unchanged non-BMP cmap.
assert adapted['OS/2'].usLastCharIndex == 0xFFFF
original['OS/2'].usLastCharIndex = adapted['OS/2'].usLastCharIndex
assert original.getTableData('OS/2') == adapted.getTableData('OS/2')
def drawing(glyph_set, name):
    pen = RecordingPen()
    glyph_set[name].draw(pen)
    return pen.value
old_set, new_set = original.getGlyphSet(), adapted.getGlyphSet()
for name in original.getGlyphOrder():
    assert drawing(old_set, name) == drawing(new_set, name), name
    assert original['hmtx'][name] == adapted['hmtx'][name], name
for name, source_name in added.items():
    assert drawing(large_set, source_name) == drawing(new_set, name), name
    advance, bearing = large['hmtx'][source_name]
    assert (advance + corrections.get(name, 0), bearing) == adapted['hmtx'][name], name
assert adapted.getBestCmap() == original.getBestCmap()
assert [(t.platformID, t.platEncID, t.format, t.cmap) for t in adapted['cmap'].tables] == [
    (t.platformID, t.platEncID, t.format, t.cmap) for t in original['cmap'].tables]
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
record = {'source': '@mathjax/mathjax-tex-font/chtml/woff2/mjx-tex-n.woff2',
          'sourceSha256': sha(source), 'sha256': sha(target), 'fontToolsVersion': fontTools.__version__,
          'largeOperatorSource': '@mathjax/mathjax-tex-font/chtml/woff2/mjx-tex-lo.woff2',
          'largeOperatorSourceSha256': sha(large_source),
          'change': 'D-only MATH operator metrics and 16 display variants; rule thickness 60; original glyphs preserved',
          'mathConstants': constants, 'displayVariants': variants,
          'displayAdvanceCorrections': corrections,
          'adapterSha256': sha(Path(__file__)), 'originalGlyphsAndAdvancesUnchanged': True,
          'displayGlyphsMatchCommonHTML': True, 'license': 'Apache-2.0'}
(out / 'provenance.json').write_text(json.dumps(record, indent=2) + '\n')

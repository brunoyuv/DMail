#!/usr/bin/env python3
"""Native operator-layout invariants for the bundled D font (synthetic only)."""
import unittest
import hashlib
from pathlib import Path
from fontTools.ttLib import TTFont
from fontTools.pens.recordingPen import RecordingPen

ROOT = Path(__file__).resolve().parents[1]
FONT_DIR = ROOT / '.tools/math-render/node_modules/@mathjax/mathjax-tex-font/chtml/woff2'


class FiraMathFontTest(unittest.TestCase):
    def setUp(self):
        self.path = ROOT / 'port/markdown-math/fonts/FiraMath-Regular.otf'
        self.font = TTFont(self.path)

    def test_upstream_bytes_and_license_are_preserved(self):
        self.assertEqual(hashlib.sha256(self.path.read_bytes()).hexdigest(),
                         '2028cbd3dd4d8c0cf1608520eb4759956a83a67931d7b6d8e7c313520186e35b')
        self.assertIn('SIL Open Font License', self.font['name'].getDebugName(13))
        notice = (ROOT / 'licenses/firamath.txt').read_bytes()
        self.assertEqual(notice, (ROOT / 'harmony/entry/src/main/resources/rawfile/licenses/firamath.txt').read_bytes())

    def test_ordinary_math_and_sigma_have_explicit_glyphs(self):
        cmap = self.font.getBestCmap()
        for code in [ord('x'), ord('1'), ord('+'), 0x03A3, 0x1D465, 0x1D6F4]:
            self.assertIn(code, cmap)
        self.assertNotEqual(cmap[0x03A3], cmap[0x2211])

    def test_sums_products_integrals_have_real_display_variants(self):
        variants = self.font['MATH'].table.MathVariants
        for code in [0x220F, 0x2210, 0x2211, 0x222B, 0x222C, 0x222D, 0x222E]:
            glyph = self.font.getBestCmap()[code]
            index = variants.VertGlyphCoverage.glyphs.index(glyph)
            records = variants.VertGlyphConstruction[index].MathGlyphVariantRecord
            self.assertGreaterEqual(len(records), 2)
            self.assertNotEqual(records[0].VariantGlyph, records[-1].VariantGlyph)
            self.assertLess(records[0].AdvanceMeasurement, records[-1].AdvanceMeasurement)
            self.assertGreaterEqual(records[-1].AdvanceMeasurement,
                                    self.font['MATH'].table.MathConstants.DisplayOperatorMinHeight)

    def test_rules_limits_and_missing_operator_fallback_remain_available(self):
        constants = self.font['MATH'].table.MathConstants
        for field in ['FractionRuleThickness', 'RadicalRuleThickness', 'UpperLimitGapMin', 'LowerLimitGapMin']:
            self.assertGreater(getattr(constants, field).Value, 0)
        fallback = TTFont(ROOT / '.tools/math-render/mathml-font/dmail-tex-mathml.woff2')
        for code in [0x22C0, 0x22C1, 0x22C2, 0x22C3, 0x2A00, 0x2A01, 0x2A02, 0x2A04, 0x2A06]:
            glyph = fallback.getBestCmap()[code]
            self.assertIn(glyph, fallback['MATH'].table.MathVariants.VertGlyphCoverage.glyphs)


class MathOperatorFontTest(unittest.TestCase):
    def setUp(self):
        self.font = TTFont(ROOT / '.tools/math-render/mathml-font/dmail-tex-mathml.woff2')

    def test_sum_has_distinct_inline_and_display_shapes(self):
        font = self.font
        variants = font['MATH'].table.MathVariants
        index = variants.VertGlyphCoverage.glyphs.index(font.getBestCmap()[0x2211])
        records = variants.VertGlyphConstruction[index].MathGlyphVariantRecord
        self.assertEqual([(r.VariantGlyph, r.AdvanceMeasurement) for r in records],
                         [('summation', 1000), ('summation.display', 1400)])
        minimum = font['MATH'].table.MathConstants.DisplayOperatorMinHeight
        self.assertLess(records[0].AdvanceMeasurement, minimum)
        self.assertGreaterEqual(records[1].AdvanceMeasurement, minimum)
        self.assertNotEqual(font.getBestCmap()[0x03A3], font.getBestCmap()[0x2211])

    def test_limits_have_gaps_and_math_axis_matches_tex(self):
        values = self.font['MATH'].table.MathConstants
        self.assertEqual(values.AxisHeight.Value, 250)
        self.assertEqual(values.UpperLimitGapMin.Value, 111)
        self.assertEqual(values.UpperLimitBaselineRiseMin.Value, 200)
        self.assertEqual(values.LowerLimitGapMin.Value, 167)
        self.assertEqual(values.LowerLimitBaselineDropMin.Value, 600)
        # Side scripts need nonzero base drops too: default zero puts the
        # superscript above the inline sum instead of alongside its upper arm.
        self.assertEqual(values.SuperscriptBaselineDropMax.Value, 274)
        self.assertEqual(values.SubscriptBaselineDropMin.Value, 36)
        # Adding MATH must not zero previously visible fraction/radical bars.
        self.assertEqual(values.FractionRuleThickness.Value, 60)
        self.assertEqual(values.RadicalRuleThickness.Value, 60)
        self.assertGreater(values.ScriptPercentScaleDown, 0)
        self.assertGreater(values.ScriptScriptPercentScaleDown, 0)

    def test_original_inline_glyphs_and_display_glyphs_keep_upstream_shapes(self):
        original = TTFont(FONT_DIR / 'mjx-tex-n.woff2')
        large = TTFont(FONT_DIR / 'mjx-tex-lo.woff2')
        self.assertEqual(self.font.getBestCmap(), original.getBestCmap())
        current_set = self.font.getGlyphSet()
        def drawing(glyph_set, name):
            pen = RecordingPen()
            glyph_set[name].draw(pen)
            return pen.value
        for name in self.font.getGlyphOrder():
            upstream = large if name.endswith('.display') else original
            source_name = name.removesuffix('.display')
            self.assertEqual(drawing(current_set, name), drawing(upstream.getGlyphSet(), source_name), name)
            advance, bearing = upstream['hmtx'][source_name]
            if name in ('integral.display', 'uni222C.display', 'uni222D.display', 'uni222E.display'):
                advance += 388
            self.assertEqual(self.font['hmtx'][name], (advance, bearing), name)

    def test_display_integral_advance_includes_italic_correction(self):
        values = self.font['MATH'].table.MathGlyphInfo.MathItalicsCorrectionInfo
        correction = values.ItalicsCorrection[values.Coverage.glyphs.index('integral.display')].Value
        self.assertEqual(correction, 388)
        advance = self.font['hmtx']['integral.display'][0]
        self.assertEqual(advance, 944)
        self.assertEqual(advance - correction, 556)


if __name__ == '__main__':
    unittest.main()

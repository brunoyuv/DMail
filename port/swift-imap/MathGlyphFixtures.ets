// Synthetic reference output from pinned MathJax on Node; Apache-2.0 notices in licenses/mathjax.txt.
interface MathGlyphFixture { source: string; display: boolean; renderer: string; markup: string; }
export const mathGlyphFixtures: MathGlyphFixture[] = [
  {
    "source": "a+b",
    "display": false,
    "renderer": "commonhtml",
    "markup": "<mjx-container class=\"MathJax\" jax=\"CHTML\" overflow=\"overflow\"><mjx-math data-latex=\"a+b\" breakable=\"true\" class=\"TEX-N\"><mjx-mi data-latex=\"a\"><mjx-c class=\"mjx-c1D44E\">𝑎</mjx-c></mjx-mi><mjx-break size=\"3\"> </mjx-break><mjx-mo data-latex=\"+\"><mjx-c class=\"mjx-c2B\">+</mjx-c></mjx-mo><mjx-mi space=\"3\" data-latex=\"b\"><mjx-c class=\"mjx-c1D44F\">𝑏</mjx-c></mjx-mi></mjx-math></mjx-container>"
  },
  {
    "source": "a+b",
    "display": false,
    "renderer": "mathml",
    "markup": "<math class=\"dmail-native-math\" xmlns=\"http://www.w3.org/1998/Math/MathML\" data-latex=\"a+b\">\n  <mi data-latex=\"a\">a</mi>\n  <mo data-latex=\"+\">+</mo>\n  <mi data-latex=\"b\">b</mi>\n</math>"
  },
  {
    "source": "\\frac{a}{b}+x^2",
    "display": false,
    "renderer": "commonhtml",
    "markup": "<mjx-container class=\"MathJax\" jax=\"CHTML\" overflow=\"overflow\"><mjx-math data-latex=\"\\frac{a}{b}+x^2\" breakable=\"true\" class=\"TEX-N\"><mjx-mfrac data-latex=\"\\frac{a}{b}\"><mjx-frac><mjx-num><mjx-nstrut></mjx-nstrut><mjx-mi size=\"s\" data-latex=\"a\"><mjx-c class=\"mjx-c1D44E\">𝑎</mjx-c></mjx-mi></mjx-num><mjx-dbox><mjx-dtable><mjx-line></mjx-line><mjx-row><mjx-den><mjx-dstrut></mjx-dstrut><mjx-mi size=\"s\" data-latex=\"b\"><mjx-c class=\"mjx-c1D44F\">𝑏</mjx-c></mjx-mi></mjx-den></mjx-row></mjx-dtable></mjx-dbox></mjx-frac></mjx-mfrac><mjx-break size=\"3\"> </mjx-break><mjx-mo data-latex=\"+\"><mjx-c class=\"mjx-c2B\">+</mjx-c></mjx-mo><mjx-msup space=\"3\" data-latex=\"x^2\"><mjx-mi data-latex=\"x\"><mjx-c class=\"mjx-c1D465\">𝑥</mjx-c></mjx-mi><mjx-script style=\"vertical-align: 0.363em;\"><mjx-mn size=\"s\" data-latex=\"2\"><mjx-c class=\"mjx-c32\">2</mjx-c></mjx-mn></mjx-script></mjx-msup></mjx-math></mjx-container>"
  },
  {
    "source": "\\frac{a}{b}+x^2",
    "display": false,
    "renderer": "mathml",
    "markup": "<math class=\"dmail-native-math\" xmlns=\"http://www.w3.org/1998/Math/MathML\" data-latex=\"\\frac{a}{b}+x^2\">\n  <mfrac data-latex=\"\\frac{a}{b}\">\n    <mi data-latex=\"a\">a</mi>\n    <mi data-latex=\"b\">b</mi>\n  </mfrac>\n  <mo data-latex=\"+\">+</mo>\n  <msup data-latex=\"x^2\">\n    <mi data-latex=\"x\">x</mi>\n    <mn data-latex=\"2\">2</mn>\n  </msup>\n</math>"
  },
  {
    "source": "\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}",
    "display": true,
    "renderer": "commonhtml",
    "markup": "<mjx-container class=\"MathJax\" jax=\"CHTML\" overflow=\"overflow\" display=\"true\"><mjx-math data-latex=\"\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}\" display=\"true\" class=\"TEX-N\"><mjx-munderover data-latex=\"\\sum_{i=1}^{n}\"><mjx-over style=\"padding-bottom: 0.192em; padding-left: 0.51em;\"><mjx-TeXAtom size=\"s\" data-latex=\"{n}\" texclass=\"ORD\"><mjx-mi data-latex=\"n\"><mjx-c class=\"mjx-c1D45B\">𝑛</mjx-c></mjx-mi></mjx-TeXAtom></mjx-over><mjx-box><mjx-munder><mjx-row><mjx-base><mjx-mo data-latex=\"\\sum\"><mjx-c class=\"mjx-c2211 TEX-LO\">∑</mjx-c></mjx-mo></mjx-base></mjx-row><mjx-row><mjx-under style=\"padding-top: 0.167em; padding-left: 0.148em;\"><mjx-TeXAtom size=\"s\" data-latex=\"{i=1}\" texclass=\"ORD\"><mjx-mi data-latex=\"i\"><mjx-c class=\"mjx-c1D456\">𝑖</mjx-c></mjx-mi><mjx-mo data-latex=\"=\"><mjx-c class=\"mjx-c3D\">=</mjx-c></mjx-mo><mjx-mn data-latex=\"1\"><mjx-c class=\"mjx-c31\">1</mjx-c></mjx-mn></mjx-TeXAtom></mjx-under></mjx-row></mjx-munder></mjx-box></mjx-munderover><mjx-mi space=\"2\" data-latex=\"i\"><mjx-c class=\"mjx-c1D456\">𝑖</mjx-c></mjx-mi><mjx-mo space=\"4\" data-latex=\"=\"><mjx-c class=\"mjx-c3D\">=</mjx-c></mjx-mo><mjx-mfrac space=\"4\" data-latex=\"\\frac{n(n+1)}{2}\"><mjx-frac type=\"d\"><mjx-num><mjx-nstrut type=\"d\"></mjx-nstrut><mjx-mrow data-latex=\"n(n+1)\"><mjx-mi data-latex=\"n\"><mjx-c class=\"mjx-c1D45B\">𝑛</mjx-c></mjx-mi><mjx-mo data-latex=\"(\"><mjx-c class=\"mjx-c28\">(</mjx-c></mjx-mo><mjx-mi data-latex=\"n\"><mjx-c class=\"mjx-c1D45B\">𝑛</mjx-c></mjx-mi><mjx-mo space=\"3\" data-latex=\"+\"><mjx-c class=\"mjx-c2B\">+</mjx-c></mjx-mo><mjx-mn space=\"3\" data-latex=\"1\"><mjx-c class=\"mjx-c31\">1</mjx-c></mjx-mn><mjx-mo data-latex=\")\"><mjx-c class=\"mjx-c29\">)</mjx-c></mjx-mo></mjx-mrow></mjx-num><mjx-dbox><mjx-dtable><mjx-line type=\"d\"></mjx-line><mjx-row><mjx-den><mjx-dstrut type=\"d\"></mjx-dstrut><mjx-mn data-latex=\"2\"><mjx-c class=\"mjx-c32\">2</mjx-c></mjx-mn></mjx-den></mjx-row></mjx-dtable></mjx-dbox></mjx-frac></mjx-mfrac></mjx-math></mjx-container>"
  },
  {
    "source": "\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}",
    "display": true,
    "renderer": "mathml",
    "markup": "<math class=\"dmail-native-math\" xmlns=\"http://www.w3.org/1998/Math/MathML\" data-latex=\"\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}\" display=\"block\">\n  <munderover data-latex=\"\\sum_{i=1}^{n}\">\n    <mo data-latex=\"\\sum\" class=\"dmail-native-operator\">&#x2211;</mo>\n    <mrow data-mjx-texclass=\"ORD\" data-latex=\"{i=1}\">\n      <mi data-latex=\"i\">i</mi>\n      <mo data-latex=\"=\">=</mo>\n      <mn data-latex=\"1\">1</mn>\n    </mrow>\n    <mrow data-mjx-texclass=\"ORD\" data-latex=\"{n}\">\n      <mi data-latex=\"n\">n</mi>\n    </mrow>\n  </munderover>\n  <mi data-latex=\"i\">i</mi>\n  <mo data-latex=\"=\">=</mo>\n  <mfrac data-latex=\"\\frac{n(n+1)}{2}\">\n    <mrow data-latex=\"n(n+1)\">\n      <mi data-latex=\"n\">n</mi>\n      <mo data-latex=\"(\" stretchy=\"false\">(</mo>\n      <mi data-latex=\"n\">n</mi>\n      <mo data-latex=\"+\">+</mo>\n      <mn data-latex=\"1\">1</mn>\n      <mo data-latex=\")\" stretchy=\"false\">)</mo>\n    </mrow>\n    <mn data-latex=\"2\">2</mn>\n  </mfrac>\n</math>"
  },
  {
    "source": "\\alpha+\\beta=\\gamma",
    "display": true,
    "renderer": "commonhtml",
    "markup": "<mjx-container class=\"MathJax\" jax=\"CHTML\" overflow=\"overflow\" display=\"true\"><mjx-math data-latex=\"\\alpha+\\beta=\\gamma\" display=\"true\" class=\"TEX-N\"><mjx-mi data-latex=\"\\alpha\"><mjx-c class=\"mjx-c1D6FC\">𝛼</mjx-c></mjx-mi><mjx-mo space=\"3\" data-latex=\"+\"><mjx-c class=\"mjx-c2B\">+</mjx-c></mjx-mo><mjx-mi space=\"3\" data-latex=\"\\beta\"><mjx-c class=\"mjx-c1D6FD\">𝛽</mjx-c></mjx-mi><mjx-mo space=\"4\" data-latex=\"=\"><mjx-c class=\"mjx-c3D\">=</mjx-c></mjx-mo><mjx-mi space=\"4\" data-latex=\"\\gamma\"><mjx-c class=\"mjx-c1D6FE\">𝛾</mjx-c></mjx-mi></mjx-math></mjx-container>"
  },
  {
    "source": "\\alpha+\\beta=\\gamma",
    "display": true,
    "renderer": "mathml",
    "markup": "<math class=\"dmail-native-math\" xmlns=\"http://www.w3.org/1998/Math/MathML\" data-latex=\"\\alpha+\\beta=\\gamma\" display=\"block\">\n  <mi data-latex=\"\\alpha\">&#x3B1;</mi>\n  <mo data-latex=\"+\">+</mo>\n  <mi data-latex=\"\\beta\">&#x3B2;</mi>\n  <mo data-latex=\"=\">=</mo>\n  <mi data-latex=\"\\gamma\">&#x3B3;</mi>\n</math>"
  },
  {
    "source": "\\sqrt{x^2+y^2}",
    "display": true,
    "renderer": "commonhtml",
    "markup": "<mjx-container class=\"MathJax\" jax=\"CHTML\" overflow=\"overflow\" display=\"true\"><mjx-math data-latex=\"\\sqrt{x^2+y^2}\" display=\"true\" class=\"TEX-N\"><mjx-msqrt data-latex=\"\\sqrt{x^2+y^2}\"><mjx-sqrt><mjx-surd><mjx-mo><mjx-c class=\"mjx-c221A TEX-SO\">√</mjx-c></mjx-mo></mjx-surd><mjx-box style=\"padding-top: 0.173em;\"><mjx-msup data-latex=\"x^2\"><mjx-mi data-latex=\"x\"><mjx-c class=\"mjx-c1D465\">𝑥</mjx-c></mjx-mi><mjx-script style=\"vertical-align: 0.289em;\"><mjx-mn size=\"s\" data-latex=\"2\"><mjx-c class=\"mjx-c32\">2</mjx-c></mjx-mn></mjx-script></mjx-msup><mjx-mo space=\"3\" data-latex=\"+\"><mjx-c class=\"mjx-c2B\">+</mjx-c></mjx-mo><mjx-msup space=\"3\" data-latex=\"y^2\"><mjx-mi data-latex=\"y\"><mjx-c class=\"mjx-c1D466\">𝑦</mjx-c></mjx-mi><mjx-script style=\"vertical-align: 0.289em; margin-left: 0.05em;\"><mjx-mn size=\"s\" data-latex=\"2\"><mjx-c class=\"mjx-c32\">2</mjx-c></mjx-mn></mjx-script></mjx-msup></mjx-box></mjx-sqrt></mjx-msqrt></mjx-math></mjx-container>"
  },
  {
    "source": "\\sqrt{x^2+y^2}",
    "display": true,
    "renderer": "mathml",
    "markup": "<math class=\"dmail-native-math\" xmlns=\"http://www.w3.org/1998/Math/MathML\" data-latex=\"\\sqrt{x^2+y^2}\" display=\"block\">\n  <msqrt data-latex=\"\\sqrt{x^2+y^2}\">\n    <msup data-latex=\"x^2\">\n      <mi data-latex=\"x\">x</mi>\n      <mn data-latex=\"2\">2</mn>\n    </msup>\n    <mo data-latex=\"+\">+</mo>\n    <msup data-latex=\"y^2\">\n      <mi data-latex=\"y\">y</mi>\n      <mn data-latex=\"2\">2</mn>\n    </msup>\n  </msqrt>\n</math>"
  },
  {
    "source": "\\int_0^1 x\\,dx=\\frac{1}{2}",
    "display": true,
    "renderer": "commonhtml",
    "markup": "<mjx-container class=\"MathJax\" jax=\"CHTML\" overflow=\"overflow\" display=\"true\"><mjx-math data-latex=\"\\int_0^1 x\\,dx=\\frac{1}{2}\" display=\"true\" class=\"TEX-N\"><mjx-msubsup data-latex=\"\\int_0^1\"><mjx-mo data-latex=\"\\int\"><mjx-c class=\"mjx-c222B TEX-LO\">∫</mjx-c></mjx-mo><mjx-script style=\"vertical-align: -0.896em; margin-left: -0.388em;\"><mjx-mn size=\"s\" data-latex=\"1\" style=\"margin-left: 0.647em;\"><mjx-c class=\"mjx-c31\">1</mjx-c></mjx-mn><mjx-spacer style=\"margin-top: 1.513em;\"></mjx-spacer><mjx-mn size=\"s\" data-latex=\"0\"><mjx-c class=\"mjx-c30\">0</mjx-c></mjx-mn></mjx-script></mjx-msubsup><mjx-mi space=\"2\" data-latex=\"x\"><mjx-c class=\"mjx-c1D465\">𝑥</mjx-c></mjx-mi><mjx-mspace data-latex=\"\\,\" style=\"width: 0.167em;\"></mjx-mspace><mjx-mi data-latex=\"d\"><mjx-c class=\"mjx-c1D451\">𝑑</mjx-c></mjx-mi><mjx-mi data-latex=\"x\"><mjx-c class=\"mjx-c1D465\">𝑥</mjx-c></mjx-mi><mjx-mo space=\"4\" data-latex=\"=\"><mjx-c class=\"mjx-c3D\">=</mjx-c></mjx-mo><mjx-mfrac space=\"4\" data-latex=\"\\frac{1}{2}\"><mjx-frac type=\"d\"><mjx-num><mjx-nstrut type=\"d\"></mjx-nstrut><mjx-mn data-latex=\"1\"><mjx-c class=\"mjx-c31\">1</mjx-c></mjx-mn></mjx-num><mjx-dbox><mjx-dtable><mjx-line type=\"d\"></mjx-line><mjx-row><mjx-den><mjx-dstrut type=\"d\"></mjx-dstrut><mjx-mn data-latex=\"2\"><mjx-c class=\"mjx-c32\">2</mjx-c></mjx-mn></mjx-den></mjx-row></mjx-dtable></mjx-dbox></mjx-frac></mjx-mfrac></mjx-math></mjx-container>"
  },
  {
    "source": "\\int_0^1 x\\,dx=\\frac{1}{2}",
    "display": true,
    "renderer": "mathml",
    "markup": "<math class=\"dmail-native-math\" xmlns=\"http://www.w3.org/1998/Math/MathML\" data-latex=\"\\int_0^1 x\\,dx=\\frac{1}{2}\" display=\"block\">\n  <msubsup data-latex=\"\\int_0^1\">\n    <mo data-latex=\"\\int\" class=\"dmail-native-operator\">&#x222B;</mo>\n    <mn data-latex=\"0\">0</mn>\n    <mn data-latex=\"1\">1</mn>\n  </msubsup>\n  <mi data-latex=\"x\">x</mi>\n  <mspace width=\"0.167em\" data-latex=\"\\,\"></mspace>\n  <mi data-latex=\"d\">d</mi>\n  <mi data-latex=\"x\">x</mi>\n  <mo data-latex=\"=\">=</mo>\n  <mfrac data-latex=\"\\frac{1}{2}\">\n    <mn data-latex=\"1\">1</mn>\n    <mn data-latex=\"2\">2</mn>\n  </mfrac>\n</math>"
  },
  {
    "source": "\\begin{pmatrix}a&b\\\\c&d\\end{pmatrix}",
    "display": true,
    "renderer": "commonhtml",
    "markup": "<mjx-container class=\"MathJax\" jax=\"CHTML\" overflow=\"overflow\" display=\"true\"><mjx-math data-latex=\"\\begin{pmatrix}a&amp;b\\\\c&amp;d\\end{pmatrix}\" display=\"true\" class=\"TEX-N\"><mjx-mrow data-latex=\"\\begin{pmatrix}a&amp;b\\\\c&amp;d\\end{pmatrix}\"><mjx-mo><mjx-c class=\"mjx-c28 TEX-S3\">(</mjx-c></mjx-mo><mjx-mtable style=\"min-width: 2.052em;\"><mjx-table><mjx-itable><mjx-mtr style=\"height: 0.705em;\"><mjx-mtd style=\"padding-right: 0.5em; padding-bottom: 0.2em;\"><mjx-mi data-latex=\"a\"><mjx-c class=\"mjx-c1D44E\">𝑎</mjx-c></mjx-mi><mjx-tstrut></mjx-tstrut></mjx-mtd><mjx-mtd style=\"padding-left: 0.5em; padding-bottom: 0.2em;\"><mjx-mi data-latex=\"b\"><mjx-c class=\"mjx-c1D44F\">𝑏</mjx-c></mjx-mi><mjx-tstrut></mjx-tstrut></mjx-mtd></mjx-mtr><mjx-mtr style=\"height: 0.705em;\"><mjx-mtd style=\"padding-right: 0.5em; padding-top: 0.2em;\"><mjx-mi data-latex=\"c\"><mjx-c class=\"mjx-c1D450\">𝑐</mjx-c></mjx-mi><mjx-tstrut></mjx-tstrut></mjx-mtd><mjx-mtd style=\"padding-left: 0.5em; padding-top: 0.2em;\"><mjx-mi data-latex=\"d\"><mjx-c class=\"mjx-c1D451\">𝑑</mjx-c></mjx-mi><mjx-tstrut></mjx-tstrut></mjx-mtd></mjx-mtr></mjx-itable></mjx-table></mjx-mtable><mjx-mo><mjx-c class=\"mjx-c29 TEX-S3\">)</mjx-c></mjx-mo></mjx-mrow></mjx-math></mjx-container>"
  },
  {
    "source": "\\begin{pmatrix}a&b\\\\c&d\\end{pmatrix}",
    "display": true,
    "renderer": "mathml",
    "markup": "<math class=\"dmail-native-math\" xmlns=\"http://www.w3.org/1998/Math/MathML\" data-latex=\"\\begin{pmatrix}a&amp;b\\\\c&amp;d\\end{pmatrix}\" display=\"block\">\n  <mrow data-mjx-texclass=\"INNER\" data-latex=\"\\begin{pmatrix}a&amp;b\\\\c&amp;d\\end{pmatrix}\">\n    <mo data-mjx-texclass=\"OPEN\">(</mo>\n    <mtable columnspacing=\"1em\" rowspacing=\"4pt\">\n      <mtr>\n        <mtd>\n          <mi data-latex=\"a\">a</mi>\n        </mtd>\n        <mtd>\n          <mi data-latex=\"b\">b</mi>\n        </mtd>\n      </mtr>\n      <mtr>\n        <mtd>\n          <mi data-latex=\"c\">c</mi>\n        </mtd>\n        <mtd>\n          <mi data-latex=\"d\">d</mi>\n        </mtd>\n      </mtr>\n    </mtable>\n    <mo data-mjx-texclass=\"CLOSE\">)</mo>\n  </mrow>\n</math>"
  },
  {
    "source": "\\left(\\frac{x}{y}\\right)^2",
    "display": true,
    "renderer": "commonhtml",
    "markup": "<mjx-container class=\"MathJax\" jax=\"CHTML\" overflow=\"overflow\" display=\"true\"><mjx-math data-latex=\"\\left(\\frac{x}{y}\\right)^2\" display=\"true\" class=\"TEX-N\"><mjx-msup data-latex=\"\\left(\\frac{x}{y}\\right)^2\"><mjx-mrow data-latex=\"\\left(\\frac{x}{y}\\right)\"><mjx-mo data-latex=\"\\left(\"><mjx-c class=\"mjx-c28 TEX-S3\">(</mjx-c></mjx-mo><mjx-mfrac data-latex=\"\\frac{x}{y}\"><mjx-frac type=\"d\"><mjx-num><mjx-nstrut type=\"d\"></mjx-nstrut><mjx-mi data-latex=\"x\"><mjx-c class=\"mjx-c1D465\">𝑥</mjx-c></mjx-mi></mjx-num><mjx-dbox><mjx-dtable><mjx-line type=\"d\"></mjx-line><mjx-row><mjx-den><mjx-dstrut type=\"d\"></mjx-dstrut><mjx-mi data-latex=\"y\"><mjx-c class=\"mjx-c1D466\">𝑦</mjx-c></mjx-mi></mjx-den></mjx-row></mjx-dtable></mjx-dbox></mjx-frac></mjx-mfrac><mjx-mo data-latex=\"\\right)\"><mjx-c class=\"mjx-c29 TEX-S3\">)</mjx-c></mjx-mo></mjx-mrow><mjx-script style=\"vertical-align: 1.177em;\"><mjx-mn size=\"s\" data-latex=\"2\"><mjx-c class=\"mjx-c32\">2</mjx-c></mjx-mn></mjx-script></mjx-msup></mjx-math></mjx-container>"
  },
  {
    "source": "\\left(\\frac{x}{y}\\right)^2",
    "display": true,
    "renderer": "mathml",
    "markup": "<math class=\"dmail-native-math\" xmlns=\"http://www.w3.org/1998/Math/MathML\" data-latex=\"\\left(\\frac{x}{y}\\right)^2\" display=\"block\">\n  <msup data-latex=\"\\left(\\frac{x}{y}\\right)^2\">\n    <mrow data-mjx-texclass=\"INNER\" data-latex=\"\\left(\\frac{x}{y}\\right)\">\n      <mo data-mjx-texclass=\"OPEN\" data-latex=\"\\left(\">(</mo>\n      <mfrac data-latex=\"\\frac{x}{y}\">\n        <mi data-latex=\"x\">x</mi>\n        <mi data-latex=\"y\">y</mi>\n      </mfrac>\n      <mo data-mjx-texclass=\"CLOSE\" data-latex=\"\\right)\">)</mo>\n    </mrow>\n    <mn data-latex=\"2\">2</mn>\n  </msup>\n</math>"
  },
  {
    "source": "\\mathbf{A}+\\mathbb{R}+\\mathrm{sin}(x)",
    "display": true,
    "renderer": "commonhtml",
    "markup": "<mjx-container class=\"MathJax\" jax=\"CHTML\" overflow=\"overflow\" display=\"true\"><mjx-math data-latex=\"\\mathbf{A}+\\mathbb{R}+\\mathrm{sin}(x)\" display=\"true\" class=\"TEX-N\"><mjx-TeXAtom data-latex=\"\\mathbf{A}\" texclass=\"ORD\"><mjx-mi data-latex=\"A\"><mjx-c class=\"mjx-c1D400\">𝐀</mjx-c></mjx-mi></mjx-TeXAtom><mjx-mo space=\"3\" data-latex=\"+\"><mjx-c class=\"mjx-c2B\">+</mjx-c></mjx-mo><mjx-TeXAtom space=\"3\" data-latex=\"\\mathbb{R}\" texclass=\"ORD\"><mjx-mi data-latex=\"R\"><mjx-c class=\"mjx-c211D\">ℝ</mjx-c></mjx-mi></mjx-TeXAtom><mjx-mo space=\"3\" data-latex=\"+\"><mjx-c class=\"mjx-c2B\">+</mjx-c></mjx-mo><mjx-TeXAtom space=\"3\" data-latex=\"\\mathrm{sin}\" texclass=\"ORD\"><mjx-mi data-latex=\"sin\"><mjx-c class=\"mjx-c73\" noic=\"true\" style=\"padding-top: 0.669em;\">s</mjx-c><mjx-c class=\"mjx-c69\" noic=\"true\" style=\"padding-top: 0.669em;\">i</mjx-c><mjx-c class=\"mjx-c6E\" style=\"padding-top: 0.669em;\">n</mjx-c></mjx-mi></mjx-TeXAtom><mjx-mo data-latex=\"(\"><mjx-c class=\"mjx-c28\">(</mjx-c></mjx-mo><mjx-mi data-latex=\"x\"><mjx-c class=\"mjx-c1D465\">𝑥</mjx-c></mjx-mi><mjx-mo data-latex=\")\"><mjx-c class=\"mjx-c29\">)</mjx-c></mjx-mo></mjx-math></mjx-container>"
  },
  {
    "source": "\\mathbf{A}+\\mathbb{R}+\\mathrm{sin}(x)",
    "display": true,
    "renderer": "mathml",
    "markup": "<math class=\"dmail-native-math\" xmlns=\"http://www.w3.org/1998/Math/MathML\" data-latex=\"\\mathbf{A}+\\mathbb{R}+\\mathrm{sin}(x)\" display=\"block\">\n  <mrow data-mjx-texclass=\"ORD\" data-latex=\"\\mathbf{A}\">\n    <mi mathvariant=\"bold\" data-latex=\"A\">A</mi>\n  </mrow>\n  <mo data-latex=\"+\">+</mo>\n  <mrow data-mjx-texclass=\"ORD\" data-latex=\"\\mathbb{R}\">\n    <mi mathvariant=\"double-struck\" data-latex=\"R\">R</mi>\n  </mrow>\n  <mo data-latex=\"+\">+</mo>\n  <mrow data-mjx-texclass=\"ORD\" data-latex=\"\\mathrm{sin}\">\n    <mi data-mjx-auto-op=\"false\" data-latex=\"sin\">sin</mi>\n  </mrow>\n  <mo data-latex=\"(\" stretchy=\"false\">(</mo>\n  <mi data-latex=\"x\">x</mi>\n  <mo data-latex=\")\" stretchy=\"false\">)</mo>\n</math>"
  },
  {
    "source": "\\Sigma \\quad \\sum",
    "display": false,
    "renderer": "commonhtml",
    "markup": "<mjx-container class=\"MathJax\" jax=\"CHTML\" overflow=\"overflow\"><mjx-math data-latex=\"\\Sigma \\quad \\sum\" breakable=\"true\" class=\"TEX-N\"><mjx-mi data-latex=\"\\Sigma\"><mjx-c class=\"mjx-c3A3\">Σ</mjx-c></mjx-mi><mjx-break size=\"0\"> </mjx-break><mjx-mspace data-latex=\"\\quad\" style=\"width: 1em;\"></mjx-mspace><mjx-mo space=\"2\" data-latex=\"\\sum\"><mjx-c class=\"mjx-c2211 TEX-SO\">∑</mjx-c></mjx-mo></mjx-math></mjx-container>"
  },
  {
    "source": "\\Sigma \\quad \\sum",
    "display": false,
    "renderer": "mathml",
    "markup": "<math class=\"dmail-native-math\" xmlns=\"http://www.w3.org/1998/Math/MathML\" data-latex=\"\\Sigma \\quad \\sum\">\n  <mi mathvariant=\"normal\" data-latex=\"\\Sigma\">&#x3A3;</mi>\n  <mspace width=\"1em\" data-latex=\"\\quad\"></mspace>\n  <mo data-latex=\"\\sum\" class=\"dmail-native-operator\">&#x2211;</mo>\n</math>"
  },
  {
    "source": "\\Sigma \\qquad \\sum_{i=1}^n i",
    "display": true,
    "renderer": "commonhtml",
    "markup": "<mjx-container class=\"MathJax\" jax=\"CHTML\" overflow=\"overflow\" display=\"true\"><mjx-math data-latex=\"\\Sigma \\qquad \\sum_{i=1}^n i\" display=\"true\" class=\"TEX-N\"><mjx-mi data-latex=\"\\Sigma\"><mjx-c class=\"mjx-c3A3\">Σ</mjx-c></mjx-mi><mjx-mspace data-latex=\"\\qquad\" style=\"width: 2em;\"></mjx-mspace><mjx-munderover space=\"2\" data-latex=\"\\sum_{i=1}^n\"><mjx-over style=\"padding-bottom: 0.192em; padding-left: 0.51em;\"><mjx-mi size=\"s\" data-latex=\"n\"><mjx-c class=\"mjx-c1D45B\">𝑛</mjx-c></mjx-mi></mjx-over><mjx-box><mjx-munder><mjx-row><mjx-base><mjx-mo data-latex=\"\\sum\"><mjx-c class=\"mjx-c2211 TEX-LO\">∑</mjx-c></mjx-mo></mjx-base></mjx-row><mjx-row><mjx-under style=\"padding-top: 0.167em; padding-left: 0.148em;\"><mjx-TeXAtom size=\"s\" data-latex=\"{i=1}\" texclass=\"ORD\"><mjx-mi data-latex=\"i\"><mjx-c class=\"mjx-c1D456\">𝑖</mjx-c></mjx-mi><mjx-mo data-latex=\"=\"><mjx-c class=\"mjx-c3D\">=</mjx-c></mjx-mo><mjx-mn data-latex=\"1\"><mjx-c class=\"mjx-c31\">1</mjx-c></mjx-mn></mjx-TeXAtom></mjx-under></mjx-row></mjx-munder></mjx-box></mjx-munderover><mjx-mi space=\"2\" data-latex=\"i\"><mjx-c class=\"mjx-c1D456\">𝑖</mjx-c></mjx-mi></mjx-math></mjx-container>"
  },
  {
    "source": "\\Sigma \\qquad \\sum_{i=1}^n i",
    "display": true,
    "renderer": "mathml",
    "markup": "<math class=\"dmail-native-math\" xmlns=\"http://www.w3.org/1998/Math/MathML\" data-latex=\"\\Sigma \\qquad \\sum_{i=1}^n i\" display=\"block\">\n  <mi mathvariant=\"normal\" data-latex=\"\\Sigma\">&#x3A3;</mi>\n  <mspace width=\"2em\" data-latex=\"\\qquad\"></mspace>\n  <munderover data-latex=\"\\sum_{i=1}^n\">\n    <mo data-latex=\"\\sum\" class=\"dmail-native-operator\">&#x2211;</mo>\n    <mrow data-mjx-texclass=\"ORD\" data-latex=\"{i=1}\">\n      <mi data-latex=\"i\">i</mi>\n      <mo data-latex=\"=\">=</mo>\n      <mn data-latex=\"1\">1</mn>\n    </mrow>\n    <mi data-latex=\"n\">n</mi>\n  </munderover>\n  <mi data-latex=\"i\">i</mi>\n</math>"
  }
];

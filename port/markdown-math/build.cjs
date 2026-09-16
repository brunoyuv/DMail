// Rebuild the pinned offline bundle. Install dependencies under ignored .tools/math-render first.
const path = require('node:path'), fs = require('node:fs'), crypto = require('node:crypto');
const root = path.resolve(__dirname, '../..');
const dependencies = path.join(root, '.tools/math-render/node_modules');
const esbuild = require(path.join(dependencies, 'esbuild'));
const fontDir = path.join(dependencies, '@mathjax/mathjax-tex-font/chtml/woff2');
const fonts = Object.fromEntries(fs.readdirSync(fontDir).filter(name => name.endsWith('.woff2')).sort()
  .map(name => [name, 'data:font/woff2;base64,' + fs.readFileSync(path.join(fontDir, name)).toString('base64')]));
const mathmlFontDir = path.join(root, '.tools/math-render/mathml-font');
const fontProof = JSON.parse(fs.readFileSync(path.join(mathmlFontDir, 'provenance.json')));
const digest = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
if (fontProof.adapterSha256 !== digest(path.join(__dirname, 'build-mathml-font.py')) ||
    fontProof.sourceSha256 !== digest(path.join(fontDir, 'mjx-tex-n.woff2')) ||
    fontProof.largeOperatorSourceSha256 !== digest(path.join(fontDir, 'mjx-tex-lo.woff2')) ||
    fontProof.sha256 !== digest(path.join(mathmlFontDir, 'dmail-tex-mathml.woff2'))) {
  throw Error('Run python3 port/markdown-math/build-mathml-font.py before bundling');
}
fonts['dmail-tex-mathml.woff2'] = 'data:font/woff2;base64,' + fs.readFileSync(path.join(mathmlFontDir, 'dmail-tex-mathml.woff2')).toString('base64');
const firaPath = path.join(__dirname, 'fonts/FiraMath-Regular.otf');
const firaHash = '2028cbd3dd4d8c0cf1608520eb4759956a83a67931d7b6d8e7c313520186e35b';
if (digest(firaPath) !== firaHash) throw Error('Fira Math 0.3.4 source hash mismatch');
fonts['FiraMath-Regular.otf'] = 'data:font/otf;base64,' + fs.readFileSync(firaPath).toString('base64');
fs.writeFileSync(path.join(__dirname, 'font-data.js'), '// Generated from MathJax TeX (Apache-2.0) and Fira Math (OFL-1.1); see licenses/mathjax.txt and licenses/firamath.txt.\nexport const fontDataUrls = ' + JSON.stringify(fonts) + ';\n');
const output = 'harmony/entry/src/main/ets/mail/math/vendor/engine.js';
const result = esbuild.buildSync({ absWorkingDir: root, entryPoints: ['port/markdown-math/engine.js'],
  alias: { '#default-font': '@mathjax/mathjax-tex-font/mjs' },
  bundle: true, format: 'esm', platform: 'browser', target: 'es2019', minify: true, legalComments: 'eof',
  nodePaths: [dependencies], outfile: output, metafile: true });
const inputs = Object.keys(result.metafile.inputs).sort();
const hashes = Object.fromEntries(inputs.map(file => [file.replace('.tools/math-render/node_modules/', ''), crypto.createHash('sha256').update(fs.readFileSync(path.join(root, file))).digest('hex')]));
const provenance = { bundle: output, sha256: crypto.createHash('sha256').update(fs.readFileSync(path.join(root, output))).digest('hex'), inputs: hashes };
provenance.fonts = Object.fromEntries(Object.keys(fonts).filter(name => name.startsWith('mjx-')).map(name => [name, crypto.createHash('sha256').update(fs.readFileSync(path.join(fontDir, name))).digest('hex')]));
provenance.mathmlFont = JSON.parse(fs.readFileSync(path.join(mathmlFontDir, 'provenance.json')));
provenance.mathmlFont.adapterSha256 = crypto.createHash('sha256').update(fs.readFileSync(path.join(__dirname, 'build-mathml-font.py'))).digest('hex');
provenance.mathmlPrimaryFont = { source: 'https://mirrors.ctan.org/fonts/firamath.zip',
  file: 'port/markdown-math/fonts/FiraMath-Regular.otf', version: '0.3.4',
  sha256: firaHash, license: 'OFL-1.1', modified: false,
  fallback: 'dmail-tex-mathml.woff2' };
fs.writeFileSync(path.join(__dirname, 'bundle-sources.json'), JSON.stringify(provenance, null, 2) + '\n');

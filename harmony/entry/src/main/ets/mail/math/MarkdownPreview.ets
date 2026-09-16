// MPL-2.0: https://mozilla.org/MPL/2.0/
import { markdownMathPlan, renderMathPlan } from './MarkdownMath';

// Local display only. Sending retains the original Markdown/TeX source.
export async function markdownPreview(text: string, renderer: string = 'mathml'): Promise<string> {
  if (!['commonhtml', 'mathml'].includes(renderer)) { throw new Error('Invalid math renderer'); }
  const html = renderMathPlan(markdownMathPlan(text, '', '', renderer));
  if (html.length > 1024 * 1024) { throw new Error('Preview limit'); }
  return html;
}

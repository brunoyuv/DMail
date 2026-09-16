// MPL-2.0: https://mozilla.org/MPL/2.0/
export class MathSettings {
  renderWhileReading: boolean = false;
  // Legacy storage field; outgoing mail always uses the original source.
  sendFormat: string = 'source';
  renderer?: string = 'mathml';
}
export function normalizeMathSettings(value: MathSettings): MathSettings {
  if (typeof value.renderWhileReading !== 'boolean' || !['source', 'formatted'].includes(value.sendFormat)) {
    throw new Error('Invalid Markdown/math settings');
  }
  const renderer = value.renderer ?? 'mathml';
  if (!['commonhtml', 'mathml'].includes(renderer)) { throw new Error('Invalid math renderer'); }
  return { renderWhileReading: value.renderWhileReading, sendFormat: 'source', renderer };
}

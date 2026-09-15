// Isolated synthetic scrolling observer. Never imported by the shipping app.
export class HtmlScrollPowerState {
  static mode: string = 'baseline011';
  static scene: number = 0;
  static active: boolean = false;
  static documentLoads: number = 0;
  static controllerLoads: number = 0;
  static scrollEvents: number = 0;
  static scrollMaximum: number = 0;
  static htmlLength: number = 0;

  static reset(mode: string): void {
    if (mode !== 'baseline011' && mode !== 'current018' && mode !== 'asyncViewport' &&
      mode !== 'baseline018' && mode !== 'current019') {
      throw new Error('Unknown synthetic renderer');
    }
    ++HtmlScrollPowerState.scene;
    HtmlScrollPowerState.mode = mode;
    HtmlScrollPowerState.active = false;
    HtmlScrollPowerState.documentLoads = 0; HtmlScrollPowerState.controllerLoads = 0;
    HtmlScrollPowerState.scrollEvents = 0; HtmlScrollPowerState.scrollMaximum = 0;
    HtmlScrollPowerState.htmlLength = 0;
  }
  static setActive(scene: number, active: boolean): void {
    if (scene === HtmlScrollPowerState.scene) { HtmlScrollPowerState.active = active; }
  }
  static owns(mode: string, scene: number): boolean {
    return HtmlScrollPowerState.active && mode === HtmlScrollPowerState.mode && scene === HtmlScrollPowerState.scene;
  }
  static recordDocument(mode: string, scene: number): void {
    if (HtmlScrollPowerState.owns(mode, scene)) { ++HtmlScrollPowerState.documentLoads; }
  }
  static recordControllerLoad(mode: string, scene: number): void {
    if (HtmlScrollPowerState.owns(mode, scene)) { ++HtmlScrollPowerState.controllerLoads; }
  }
  static recordScroll(mode: string, scene: number, offset: number): void {
    if (!HtmlScrollPowerState.owns(mode, scene) || !Number.isFinite(offset)) { return; }
    ++HtmlScrollPowerState.scrollEvents;
    HtmlScrollPowerState.scrollMaximum = Math.max(HtmlScrollPowerState.scrollMaximum, offset);
  }
  static loads(): string { return `${HtmlScrollPowerState.controllerLoads},${HtmlScrollPowerState.documentLoads}`; }
  static document(): string {
    const rows: string[] = [];
    for (let index = 1; index <= 1500; index++) {
      rows.push(`<tr><td>Row ${index}</td><td>Synthetic long message 東京 — paragraph ${index}. ` +
        'This generated text has no images, scripts, attachments, or network resources.</td></tr>');
    }
    const html = '<h2>Synthetic scroll power email</h2><p>1500 generated rows, no network resources.</p><table><tbody>' +
      rows.join('') + '</tbody></table><p>End of synthetic long email</p>';
    if (html.length * 3 > 1024 * 1024) { throw new Error('Synthetic document exceeded its byte budget'); }
    HtmlScrollPowerState.htmlLength = html.length;
    return html;
  }
}

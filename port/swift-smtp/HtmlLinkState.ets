// Isolated native-test observer. No browser, mailbox, or network dependency.
export class HtmlLinkState {
  static opened: string[] = [];
  static active: boolean = false;
  static scene: number = 0;
  static longDocument: boolean = false;
  static documentLoads: number = 0;
  static controllerLoads: number = 0;
  static htmlLength: number = 0;
  static scrollEvents: number = 0;
  static scrollMaximum: number = 0;
  static scrollLast: number = 0;
  static scrollMinimum: number = 0;
  static scrollDelta: number = 0;
  static reset(longDocument: boolean = false): void {
    ++HtmlLinkState.scene;
    HtmlLinkState.active = false; HtmlLinkState.opened = []; HtmlLinkState.longDocument = longDocument;
    HtmlLinkState.documentLoads = 0; HtmlLinkState.controllerLoads = 0; HtmlLinkState.htmlLength = 0;
    HtmlLinkState.scrollEvents = 0; HtmlLinkState.scrollMaximum = 0;
    HtmlLinkState.scrollLast = 0; HtmlLinkState.scrollMinimum = 0; HtmlLinkState.scrollDelta = 0;
  }
  static setActive(scene: number, active: boolean): void {
    if (scene === HtmlLinkState.scene) { HtmlLinkState.active = active; }
  }
  static async open(url: string): Promise<void> { HtmlLinkState.opened.push(url); }
  static recordDocument(): void { if (HtmlLinkState.active) { ++HtmlLinkState.documentLoads; } }
  static recordControllerLoad(): void { if (HtmlLinkState.active) { ++HtmlLinkState.controllerLoads; } }
  static recordScroll(scene: number, offset: number, delta: number): void {
    if (scene !== HtmlLinkState.scene || !HtmlLinkState.active || !Number.isFinite(offset)) { return; }
    ++HtmlLinkState.scrollEvents; HtmlLinkState.scrollLast = offset;
    HtmlLinkState.scrollMaximum = Math.max(HtmlLinkState.scrollMaximum, offset);
    HtmlLinkState.scrollMinimum = Math.min(HtmlLinkState.scrollMinimum, offset);
    if (Number.isFinite(delta)) { HtmlLinkState.scrollDelta += delta; }
  }
  static diagnostics(): string {
    return `scene=${HtmlLinkState.scene},active=${HtmlLinkState.active},callbacks=${HtmlLinkState.scrollEvents},` +
      `last=${HtmlLinkState.scrollLast},min=${HtmlLinkState.scrollMinimum},max=${HtmlLinkState.scrollMaximum},delta=${HtmlLinkState.scrollDelta}`;
  }
  static document(): string {
    let html = '<h2>Synthetic link email</h2><p>The reader must remain open after these taps.</p>' +
      '<p><a target="_blank" href="https://links.example.test/page?x=1&amp;y=two#section">Open synthetic website</a></p>' +
      '<p><a href="#local-anchor">Jump inside this email</a></p>' +
      '<p id="local-anchor">Local destination stays in email</p>';
    if (HtmlLinkState.longDocument) {
      const rows: string[] = [];
      for (let index = 1; index <= 1500; index++) {
        rows.push(`<tr><td>Row ${index}</td><td>Synthetic long message 東京 — paragraph ${index}. ` +
          'This generated text has no images, scripts, attachments, or network resources.</td></tr>');
      }
      html = '<h2>Synthetic long email</h2><p>1500 generated rows, no network resources.</p><table><tbody>' +
        rows.join('') + '</tbody></table><p>End of synthetic long email</p>';
    }
    // Every UTF-16 code unit needs at most three UTF-8 bytes in this document.
    if (html.length * 3 > 1024 * 1024) { throw new Error('Synthetic document exceeded its byte budget'); }
    HtmlLinkState.htmlLength = html.length;
    return html;
  }
}

// MPL-2.0: https://mozilla.org/MPL/2.0/
export class CompositionSettings {
  senderName: string = '';
  signature: string = '';
}
export interface CompositionDraft { text: string; senderName: string; compositionApplied: boolean; }

export function normalizeComposition(settings: CompositionSettings): CompositionSettings {
  if (settings.senderName.length > 200 || settings.signature.length > 8000) { throw new Error('Composition settings are too long'); }
  return { senderName: settings.senderName.replace(/[\x00-\x1f\x7f]/g, ' ').trim(),
    signature: settings.signature.replace(/\r\n?/g, '\n').replace(/\x00/g, '') };
}

// Use only at draft creation. Once applied, even an empty signature is a
// snapshot: reopening a saved draft must preserve the user's subsequent edits.
export function applyComposition(draft: CompositionDraft, settings: CompositionSettings): void {
  if (draft.compositionApplied) { return; }
  const values = normalizeComposition(settings);
  draft.senderName = values.senderName;
  if (values.signature.trim() !== '') {
    draft.text = `\n\n${values.signature}${draft.text ? `\n\n${draft.text.replace(/^\n+/, '')}` : ''}`;
  }
  draft.compositionApplied = true;
}

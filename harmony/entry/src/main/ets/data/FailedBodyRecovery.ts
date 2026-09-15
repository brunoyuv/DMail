// MPL-2.0: https://mozilla.org/MPL/2.0/
import { plainTextMailHtml, preparedMailDocument } from '../mail/html/HtmlDocument';
import { PreparedMailDocument } from './PreparedDocumentModel';

const emptyDocument = preparedMailDocument(plainTextMailHtml(''), false, 0)
  .replace('img-src data:;', 'img-src data: https://mail.invalid;');
// 0.1.23's fixed wrapper also hid authored form containers. Recognize that
// exact known wrapper, without scanning or classifying arbitrary message HTML.
const previousEmptyDocument = emptyDocument.replace(
  'iframe,object,embed,input,button,textarea,select,video,audio{display:none!important}',
  'iframe,object,embed,form,input,button,textarea,select,video,audio{display:none!important}');

export function failedEmptyPreparedDocument(document: PreparedMailDocument | null, bodySavedAt: number | null): boolean {
  return document !== null && bodySavedAt !== null && document.bodySavedAt === bodySavedAt &&
    document.pictures.length === 0 && (document.html === emptyDocument || document.html === previousEmptyDocument);
}

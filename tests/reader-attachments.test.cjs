const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const source = fs.readFileSync('harmony/entry/src/main/ets/pages/ConnectedMail.ets', 'utf8');
const methods = ['attachmentPath', 'attachmentAction', 'applyReaderMetadata'].map(name => source.match(new RegExp(`  private (?:async )?${name}\\([\\s\\S]*?\\n  }`))[0]).join('\n');
const compiled = ts.transpileModule(`class Host { ${methods} }; return Host;`, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { resolve, promise }; };
const draftId = '11111111-1111-4111-8111-111111111111';
const fileId = '22222222-2222-4222-8222-222222222222';
function fixture() {
  const state = { cached: new Map(), fetched: [], looked: [], opened: [], saved: [], gate: null, local: [], identities: new Map() };
  const Files = {
    limit: 4 * 1024 * 1024,
    async load(context, account, origin, attachment, download) {
      state.looked.push([account, origin]); if (state.gate) await state.gate.promise;
      if (state.cached.has(origin)) return state.cached.get(origin);
      const data = await download(); assert.equal(data.base64, 'cGRm'); return '/files/new.pdf';
    },
    async open(context, path, type) { state.opened.push({ path, type }); },
    async save(context, path, name) { state.saved.push({ path, name }); }
  };
  class OutgoingFiles { async path(account, draft, attachment) { state.local.push({ account, draft, attachment }); return '/files/local.pdf'; } }
  const uuid = value => /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value);
  const reference = (account, draft, id) => `${account}/${draft}/${id}.bin`;
  const Host = new Function('AttachmentFiles', 'OutgoingAttachmentFiles', 'outgoingUUIDValid', 'outgoingAttachmentReference', 'MailOperations', 'shallowCopyEmail', compiled)(
    Files, OutgoingFiles, uuid, reference, { currentEmailId: (_account, id) => state.identities.get(id) || id }, mail => ({ ...mail }));
  const host = Object.assign(new Host(), { active: true, bodyLoaded: true, generation: 1, account: { id: 'a', serverId: 'server-a' },
    selected: { id: 'archive-uid', cachedSourceId: 'body-origin', cachedAttachmentSourceIds: ['inbox-uid'] }, attachmentBusy: '', attachmentError: '', label: key => key,
    getUIContext: () => ({ getHostContext: () => ({ filesDir: '/files', cacheDir: '/cache' }) }),
    client: { readAttachment: async (...args) => { state.fetched.push(args); return { base64: 'cGRm' }; } }
  });
  const attachment = { id: '2', name: '研究 résumé.pdf', contentType: 'application/pdf', size: 3 };
  return { host, state, attachment };
}
test('Archived PDF finds original cached file offline, without a server request', async () => {
  const f = fixture(); f.host.client = null; f.state.cached.set('inbox-uid', '/files/original.pdf');
  await f.host.attachmentAction(f.attachment, false);
  assert.deepEqual(f.state.opened, [{ path: '/files/original.pdf', type: 'application/pdf' }]);
  assert.deepEqual(f.state.fetched, []); assert.equal(f.host.attachmentError, '');
});
test('Missing cached attachment requests the current server UID exactly once and saves its Unicode name', async () => {
  const f = fixture(); await f.host.attachmentAction(f.attachment, true);
  assert.deepEqual(f.state.fetched, [['server-a', 'archive-uid', '2']]);
  assert.deepEqual(f.state.saved, [{ path: '/files/new.pdf', name: f.attachment.name }]);
});
test('Local Sent attachment opens its owned draft file without incoming transfer cap or server access', async () => {
  const f = fixture(); f.host.client = null; f.host.selected.cachedSourceId = `local_sent_${draftId}`;
  f.attachment.id = fileId; f.attachment.size = 6 * 1024 * 1024;
  await f.host.attachmentAction(f.attachment, false);
  assert.equal(f.state.local[0].attachment.file, `a/${draftId}/${fileId}.bin`);
  assert.equal(f.state.opened[0].path, '/files/local.pdf'); assert.deepEqual(f.state.fetched, []);
});
test('Leaving reader during cache lookup prevents download and external file opening', async () => {
  for (const cached of [true, false]) {
    const f = fixture(); f.state.gate = deferred(); if (cached) f.state.cached.set('body-origin', '/files/body.pdf');
    const opening = f.host.attachmentAction(f.attachment, false);
    f.host.generation++; f.host.selected = { id: 'new-reader' }; f.host.attachmentBusy = 'newer-operation';
    f.state.gate.resolve(); await opening;
    assert.deepEqual(f.state.opened, []); assert.deepEqual(f.state.fetched, []);
    assert.equal(f.host.attachmentBusy, 'newer-operation'); assert.equal(f.host.attachmentError, '');
  }
});
test('Mappingless archive cannot fetch attachment with an invented server ID', async () => {
  const f = fixture(); f.host.selected.id = 'local_archive_synthetic';
  await f.host.attachmentAction(f.attachment, false);
  assert.deepEqual(f.state.fetched, []); assert.equal(f.host.attachmentError, 'attachment_download_error');
});

test('Archiving during attachment lookup retires old busy state without replacing HTML or interrupting a newer attachment', async () => {
  const f=fixture(),oldGate=deferred(),newGate=deferred();
  const oldMail={...f.host.selected,threadId:'archive-uid',mailboxIds:['inbox'],keywords:[],
    subject:'Opened subject',htmlBody:'<p>Opened immutable HTML</p>',textBody:'Opened text',attachments:[f.attachment]};
  const document={html:'Prepared document',pictures:[]};
  Object.assign(f.host,{selected:oldMail,selectedId:oldMail.id,conversation:[oldMail],readerDocument:document});
  f.state.cached.set('body-origin','/files/saved.pdf');f.state.gate=oldGate;
  const oldOpening=f.host.attachmentAction(f.attachment,false);
  assert.equal(f.host.attachmentBusy,'2');f.host.attachmentError='prior-error';
  f.state.identities.set('archive-uid','mapped-uid');
  f.host.applyReaderMetadata({id:'mapped-uid',threadId:'mapped-uid',cachedSourceId:'different-cache-body',
    cachedAttachmentSourceIds:['mapped-uid','archive-uid','body-origin'],keywords:['$seen'],mailboxIds:['archive'],
    maySetSeen:true,maySetKeywords:true,htmlBody:'<p>Different cached HTML</p>'});
  assert.equal(f.host.selectedId,'mapped-uid');assert.equal(f.host.selected.id,'mapped-uid');
  assert.equal(f.host.selected.cachedSourceId,'body-origin');
  assert.equal(f.host.selected.htmlBody,oldMail.htmlBody);assert.equal(f.host.selected.textBody,oldMail.textBody);
  assert.equal(f.host.selected.subject,oldMail.subject);assert.strictEqual(f.host.selected.attachments,oldMail.attachments);
  assert.strictEqual(f.host.readerDocument,document);assert.strictEqual(f.host.conversation[0],f.host.selected);
  assert.equal(f.host.attachmentBusy,'');assert.equal(f.host.attachmentError,'');
  f.state.gate=newGate;
  const newOpening=f.host.attachmentAction(f.attachment,false);
  assert.equal(f.host.attachmentBusy,'2');
  oldGate.resolve();await oldOpening;
  assert.equal(f.host.attachmentBusy,'2','Retired request must not clear its successor');
  assert.deepEqual(f.state.opened,[]);assert.deepEqual(f.state.fetched,[]);
  newGate.resolve();await newOpening;
  assert.deepEqual(f.state.opened,[{path:'/files/saved.pdf',type:'application/pdf'}]);
  assert.equal(f.host.attachmentBusy,'');assert.equal(f.host.attachmentError,'');
});

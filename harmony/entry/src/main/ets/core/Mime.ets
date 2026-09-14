// This Source Code Form is subject to the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { mimeRequest } from 'libthunderbird.so';

export interface MimeHeader { name: string; value: string; }
export interface MimePart {
  contentType: string;
  transferEncoding?: string;
  disposition?: string;
  contentId?: string;
  // Base64 transports the upstream Part.data bytes, before transfer decoding.
  encodedPayloadBase64: string;
  parts: MimePart[];
}
export interface MimeBody {
  headers: MimeHeader[];
  part: MimePart;
  rawValueBase64: string;
  isEmpty: boolean;
}
interface MimeReply { value?: string; body?: MimeBody; error?: string; }

async function request(operation: number, input: string): Promise<MimeReply> {
  const reply = JSON.parse(await mimeRequest(operation, input)) as MimeReply;
  if (reply.error !== undefined) { throw new Error(reply.error); }
  return reply;
}

export async function decodeMimeHeader(input: string): Promise<string> {
  const reply = await request(0, input);
  if (reply.value === undefined) { throw new Error('MIME_RESPONSE'); }
  return reply.value;
}

export async function encodeMimeHeader(input: string): Promise<string> {
  const reply = await request(1, input);
  if (reply.value === undefined) { throw new Error('MIME_RESPONSE'); }
  return reply.value;
}

export async function parseMimeBody(input: string): Promise<MimeBody> {
  const reply = await request(2, input);
  if (reply.body === undefined) { throw new Error('MIME_RESPONSE'); }
  return reply.body;
}

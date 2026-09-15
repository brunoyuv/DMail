// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/

function startsWith(bytes: Uint8Array, signature: number[], offset: number = 0): boolean {
  if (bytes.length < offset + signature.length) { return false; }
  for (let index = 0; index < signature.length; index++) {
    if (bytes[offset + index] !== signature[index]) { return false; }
  }
  return true;
}

// Reject obvious server error pages labelled as common raster images before
// they replace usable cached bytes. This checks signatures, not full decoding.
// Leave other image formats to ArkWeb, including SVG and AVIF: the platform
// image decoder need not support every format that the browser can display.
export function validPictureData(data: ArrayBuffer, mimeType: string): boolean {
  const type = mimeType.split(';')[0].trim().toLowerCase();
  if (data.byteLength === 0 || !/^image\/[a-z0-9.+-]{1,64}$/.test(type)) { return false; }
  const bytes = new Uint8Array(data);
  if (type === 'image/png' || type === 'image/x-png') {
    return startsWith(bytes, [137, 80, 78, 71, 13, 10, 26, 10]);
  }
  if (type === 'image/jpeg' || type === 'image/jpg' || type === 'image/pjpeg') {
    return startsWith(bytes, [255, 216, 255]);
  }
  if (type === 'image/gif') {
    return startsWith(bytes, [71, 73, 70, 56, 55, 97]) || startsWith(bytes, [71, 73, 70, 56, 57, 97]);
  }
  if (type === 'image/webp') {
    return startsWith(bytes, [82, 73, 70, 70]) && startsWith(bytes, [87, 69, 66, 80], 8);
  }
  return true;
}

// Infer familiar raster formats for generic/missing types and correct incorrect
// image labels, as browsers do in an image context. XML images keep their type.
// Explicit non-image responses and unrecognized binary data remain blocked.
export function pictureMimeType(data: ArrayBuffer, declaredType: string): string {
  const type = declaredType.split(';')[0].trim().toLowerCase();
  const imageType = /^image\/[a-z0-9.+-]{1,64}$/.test(type);
  if (type === '' || type === 'application/octet-stream' || (imageType && !type.endsWith('+xml'))) {
    for (const candidate of ['image/png', 'image/jpeg', 'image/gif', 'image/webp']) {
      if (validPictureData(data, candidate)) { return candidate; }
    }
  }
  return validPictureData(data, type) ? type : '';
}

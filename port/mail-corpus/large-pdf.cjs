// A valid, deterministic one-page PDF padded to 2.38 MiB inside its content stream.
module.exports = function makePDF() {
  const target = Math.round(2.38 * 1024 * 1024);
  function build(padding) {
    const stream = 'BT /F1 24 Tf 72 720 Td (Synthetic attachment test) Tj ET\n'+' '.repeat(padding);
    const objects = ['<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Count 1 /Kids [3 0 R] >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
      `<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`];
    let pdf='%PDF-1.4\n', offsets=[];
    objects.forEach((object,i)=>{offsets.push(pdf.length);pdf+=`${i+1} 0 obj\n${object}\nendobj\n`;});
    const start=pdf.length;
    pdf+='xref\n0 6\n0000000000 65535 f \n'+offsets.map(offset=>`${String(offset).padStart(10,'0')} 00000 n \n`).join('');
    pdf+=`trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${start}\n%%EOF\n`;
    return Buffer.from(pdf);
  }
  let padding=target-build(0).length;
  for(let i=0;i<4;i++){const pdf=build(padding);if(pdf.length===target)return pdf;padding+=target-pdf.length;}
  throw Error('PDF fixture length mismatch');
};

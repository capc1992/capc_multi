"""Render every QA PDF page and preserve text/geometry evidence locally.

Install into the project with:
python -m pip install --target .qa-python pypdfium2 pillow pypdf
Run after CAPC_PDF_QA_DIR=output/qa/pdf flutter test test/documents_test.dart.
"""
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.qa-python'))
import pypdfium2 as pdfium
from PIL import Image, ImageDraw
from pypdf import PdfReader

source = ROOT / 'output' / 'qa' / 'pdf'
target = ROOT / 'output' / 'qa' / 'rendered'
target.mkdir(parents=True, exist_ok=True)
results = []
for filename in sorted(source.glob('*.pdf')):
    reader = PdfReader(filename)
    document = pdfium.PdfDocument(filename)
    texts = []
    thumbs = []
    page_info = []
    for i, page in enumerate(document):
        width, height = page.get_size()
        image = page.render(scale=1.5).to_pil()
        image.save(target / f'{filename.stem}-{i+1:03d}.png')
        text = reader.pages[i].extract_text()
        if not text.strip():
            raise AssertionError(f'Página vacía: {filename.name} {i+1}')
        if f'Página{i+1}de{len(document)}' not in ''.join(text.split()):
            raise AssertionError(f'Pie ausente: {filename.name} {i+1}')
        texts.append(text)
        page_info.append({'page': i+1, 'width_pt': width, 'height_pt': height, 'characters': len(text)})
        image.thumbnail((360, 480))
        thumb = Image.new('RGB', (380, 515), '#dae2e0')
        thumb.paste(image, ((380-image.width)//2, 25))
        ImageDraw.Draw(thumb).text((12, 5), f'{filename.name} - {i+1}', fill='#173a36')
        thumbs.append(thumb)
        page.close()
    columns = min(4, len(thumbs))
    rows = (len(thumbs)+columns-1)//columns
    sheet = Image.new('RGB', (columns*380, rows*515), '#dae2e0')
    for i, thumb in enumerate(thumbs):
        sheet.paste(thumb, ((i % columns)*380, (i//columns)*515))
    sheet.save(target / f'{filename.stem}-overview.png')
    (target / f'{filename.stem}.txt').write_text('\n\n'.join(texts), encoding='utf-8')
    results.append({'document': filename.name, 'pages': page_info})
    document.close()
if not results:
    raise AssertionError('No hay PDF para verificar.')
(target / 'verification.json').write_text(json.dumps(results, indent=2, ensure_ascii=False), encoding='utf-8')
print(json.dumps([{'document': r['document'], 'pages': len(r['pages'])} for r in results], ensure_ascii=False))

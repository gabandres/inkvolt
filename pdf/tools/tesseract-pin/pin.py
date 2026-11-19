"""Pins Inkvolt PDF's optional Tesseract download (roadmap 2.2): writes pdf/src/InkvoltPdf.Core/TesseractCatalog.cs.

    python -I pdf/tools/tesseract-pin/pin.py WORKDIR [--installer URL SHA256] [--tessdata COMMIT]

WORKDIR is an empty folder of your own for the downloads (about 400 MB). The installer is the Tesseract project's own
Windows build (tesseract-ocr/tesseract's GitHub release, built and signed by UB Mannheim); its SHA-256 is the one GitHub
shows for the asset. The script reads the installer's solid LZMA stream (NSIS), finds tesseract.exe and the DLLs it
loads (its import table, followed), and pins each one's place in the stream, size and SHA-256, so the app takes exactly
these files out of exactly this installer and never runs it. Language data comes from tesseract-ocr/tessdata_fast at one
commit, each file's size and SHA-256 pinned.
"""
import hashlib, json, lzma, os, struct, sys, urllib.request

INSTALLER = ('https://github.com/tesseract-ocr/tesseract/releases/download/5.5.3/tesseract-ocr-w64-setup-5.5.3.20260724.exe',
             'bee9e3434bd94fd65387d9be28cd467a41f61b1275383b55b0f59a1331270ae4', '5.5.3.20260724')
TESSDATA = '87416418657359cb625c412a48b6e1d6d41c29bd'

# Tesseract's code -> (BCP-47 tag, English name). Left out: osd and equ (not languages), frk (empty), enm and frm (Middle
# English and French), deu_latf, the *_old and *_vert variants.
LANGUAGES = {
    'afr': ('af', 'Afrikaans'), 'amh': ('am', 'Amharic'), 'ara': ('ar', 'Arabic'), 'asm': ('as', 'Assamese'),
    'aze': ('az-Latn', 'Azerbaijani (Latin)'), 'aze_cyrl': ('az-Cyrl', 'Azerbaijani (Cyrillic)'), 'bel': ('be', 'Belarusian'),
    'ben': ('bn', 'Bangla'), 'bod': ('bo', 'Tibetan'), 'bos': ('bs', 'Bosnian'), 'bre': ('br', 'Breton'),
    'bul': ('bg', 'Bulgarian'), 'cat': ('ca', 'Catalan'), 'ceb': ('ceb', 'Cebuano'), 'ces': ('cs', 'Czech'),
    'chi_sim': ('zh-Hans', 'Chinese (Simplified)'), 'chi_tra': ('zh-Hant', 'Chinese (Traditional)'), 'chr': ('chr', 'Cherokee'),
    'cos': ('co', 'Corsican'), 'cym': ('cy', 'Welsh'), 'dan': ('da', 'Danish'), 'deu': ('de', 'German'), 'div': ('dv', 'Divehi'),
    'dzo': ('dz', 'Dzongkha'), 'ell': ('el', 'Greek'), 'eng': ('en', 'English'), 'epo': ('eo', 'Esperanto'),
    'est': ('et', 'Estonian'), 'eus': ('eu', 'Basque'), 'fao': ('fo', 'Faroese'), 'fas': ('fa', 'Persian'),
    'fil': ('fil', 'Filipino'), 'fin': ('fi', 'Finnish'), 'fra': ('fr', 'French'), 'fry': ('fy', 'Western Frisian'),
    'gla': ('gd', 'Scottish Gaelic'), 'gle': ('ga', 'Irish'), 'glg': ('gl', 'Galician'), 'grc': ('grc', 'Ancient Greek'),
    'guj': ('gu', 'Gujarati'), 'hat': ('ht', 'Haitian Creole'), 'heb': ('he', 'Hebrew'), 'hin': ('hi', 'Hindi'),
    'hrv': ('hr', 'Croatian'), 'hun': ('hu', 'Hungarian'), 'hye': ('hy', 'Armenian'), 'iku': ('iu', 'Inuktitut'),
    'ind': ('id', 'Indonesian'), 'isl': ('is', 'Icelandic'), 'ita': ('it', 'Italian'), 'jav': ('jv', 'Javanese'),
    'jpn': ('ja', 'Japanese'), 'kan': ('kn', 'Kannada'), 'kat': ('ka', 'Georgian'), 'kaz': ('kk', 'Kazakh'),
    'khm': ('km', 'Khmer'), 'kir': ('ky', 'Kyrgyz'), 'kmr': ('kmr', 'Northern Kurdish'), 'kor': ('ko', 'Korean'),
    'lao': ('lo', 'Lao'), 'lat': ('la', 'Latin'), 'lav': ('lv', 'Latvian'), 'lit': ('lt', 'Lithuanian'),
    'ltz': ('lb', 'Luxembourgish'), 'mal': ('ml', 'Malayalam'), 'mar': ('mr', 'Marathi'), 'mkd': ('mk', 'Macedonian'),
    'mlt': ('mt', 'Maltese'), 'mon': ('mn', 'Mongolian'), 'mri': ('mi', 'Maori'), 'msa': ('ms', 'Malay'),
    'mya': ('my', 'Burmese'), 'nep': ('ne', 'Nepali'), 'nld': ('nl', 'Dutch'), 'nor': ('nb', 'Norwegian'),
    'oci': ('oc', 'Occitan'), 'ori': ('or', 'Odia'), 'pan': ('pa', 'Punjabi'), 'pol': ('pl', 'Polish'),
    'por': ('pt', 'Portuguese'), 'pus': ('ps', 'Pashto'), 'que': ('qu', 'Quechua'), 'ron': ('ro', 'Romanian'),
    'rus': ('ru', 'Russian'), 'san': ('sa', 'Sanskrit'), 'sin': ('si', 'Sinhala'), 'slk': ('sk', 'Slovak'),
    'slv': ('sl', 'Slovenian'), 'snd': ('sd', 'Sindhi'), 'spa': ('es', 'Spanish'), 'sqi': ('sq', 'Albanian'),
    'srp': ('sr-Cyrl', 'Serbian (Cyrillic)'), 'srp_latn': ('sr-Latn', 'Serbian (Latin)'), 'sun': ('su', 'Sundanese'),
    'swa': ('sw', 'Swahili'), 'swe': ('sv', 'Swedish'), 'syr': ('syr', 'Syriac'), 'tam': ('ta', 'Tamil'),
    'tat': ('tt', 'Tatar'), 'tel': ('te', 'Telugu'), 'tgk': ('tg', 'Tajik'), 'tha': ('th', 'Thai'),
    'tir': ('ti', 'Tigrinya'), 'ton': ('to', 'Tongan'), 'tur': ('tr', 'Turkish'), 'uig': ('ug', 'Uyghur'),
    'ukr': ('uk', 'Ukrainian'), 'urd': ('ur', 'Urdu'), 'uzb': ('uz-Latn', 'Uzbek (Latin)'), 'uzb_cyrl': ('uz-Cyrl', 'Uzbek (Cyrillic)'),
    'vie': ('vi', 'Vietnamese'), 'yid': ('yi', 'Yiddish'), 'yor': ('yo', 'Yoruba'),
}

def fetch(url, path):
    if not os.path.exists(path):
        urllib.request.urlretrieve(url, path)
    return open(path, 'rb').read()


def nsis(installer):
    at = installer.find(b'\xEF\xBE\xAD\xDENullsoftInst') - 4
    if at < 0: sys.exit('not an NSIS installer')
    start = at + 28
    props, dict_size = installer[start], struct.unpack_from('<I', installer, start + 1)[0]
    lc, lp, pb = props % 9, props // 9 % 5, props // 45
    dec = lzma.LZMADecompressor(lzma.FORMAT_RAW, filters=[{'id': lzma.FILTER_LZMA1, 'dict_size': dict_size, 'lc': lc, 'lp': lp, 'pb': pb}])
    solid = dec.decompress(installer[start + 5:])
    if not dec.eof: sys.exit('the LZMA stream has no end')
    return start, props, dict_size, solid


def files_in(solid):
    """{name: (absolute offset of the data, size)} for the installer's files in $INSTDIR (Unicode NSIS 3)."""
    hl = struct.unpack_from('<I', solid, 0)[0]
    h, base = solid[4:4 + hl], 4 + hl
    blocks = [struct.unpack_from('<II', h, 4 + 8 * k) for k in range(8)]
    (ent_off, ent_n), str_off = blocks[2], blocks[3][0]

    def string(o):
        p, out = str_off + o * 2, []
        while (c := struct.unpack_from('<H', h, p)[0]) != 0:
            p += 2
            if c in (1, 2, 3, 4):
                v = struct.unpack_from('<H', h, p)[0]; p += 2
                n = (v & 0x7F) | ((v >> 8 & 0x7F) << 7) if c in (1, 3) else v
                out.append(chr(v) if c == 4 else '$%s(%d)' % ({1: 'LANG', 2: 'SHELL', 3: 'VAR'}[c], n))
            else:
                out.append(chr(c))
        return ''.join(out)

    found, outpath = {}, ''
    for k in range(ent_n):
        which, *p = struct.unpack_from('<7i', h, ent_off + 28 * k)
        if which == 11 and p[1]: outpath = string(p[0])            # SetOutPath
        if which == 20:                                              # File
            name = string(p[1])
            o = base + p[2]
            size = struct.unpack_from('<I', solid, o)[0] & 0x7FFFFFFF
            if not outpath.startswith('$VAR(21)'): continue  # not under $INSTDIR: the installer's own plug-ins
            key = (outpath[len('$VAR(21)'):].lstrip('\\') + '\\' + name).lstrip('\\')
            found.setdefault(key, (o + 4, size))
    return found


def imports(pe):
    e = struct.unpack_from('<I', pe, 0x3C)[0]
    nsec, optsz = struct.unpack_from('<H', pe, e + 6)[0], struct.unpack_from('<H', pe, e + 20)[0]
    opt = e + 24
    dd = opt + (112 if struct.unpack_from('<H', pe, opt)[0] == 0x20B else 96)
    rva = struct.unpack_from('<I', pe, dd + 8)[0]
    secs = [struct.unpack_from('<IIII', pe, opt + optsz + 40 * k + 8) for k in range(nsec)]

    def off(r):
        return next(r - va + raw for vs, va, rs, raw in secs if va <= r < va + max(vs, rs))
    out, p = [], off(rva)
    while (name := struct.unpack_from('<IIIII', pe, p)[3]) != 0:
        q = off(name)
        out.append(pe[q:pe.index(b'\0', q)].decode())
        p += 20
    return out


def main():
    work = sys.argv[1]
    url, sha, version = INSTALLER
    if '--installer' in sys.argv:
        i = sys.argv.index('--installer'); url, sha = sys.argv[i + 1], sys.argv[i + 2]
        version = url.rsplit('-', 1)[-1].removesuffix('.exe')
    commit = sys.argv[sys.argv.index('--tessdata') + 1] if '--tessdata' in sys.argv else TESSDATA
    installer = fetch(url, os.path.join(work, 'tesseract-setup.bin'))
    if hashlib.sha256(installer).hexdigest() != sha: sys.exit('the installer is not the one pinned')
    start, props, dict_size, solid = nsis(installer)
    files = files_in(solid)
    lower = {k.lower(): k for k in files}
    need, todo = [], ['tesseract.exe']
    while todo:
        n = todo.pop()
        if n.lower() not in lower or lower[n.lower()] in need: continue  # a Windows DLL
        need.append(lower[n.lower()])
        o, s = files[lower[n.lower()]]
        todo += imports(solid[o:o + s])
    pinned = sorted(need, key=lambda n: files[n][0]) + ['doc\\LICENSE']

    rows = []
    for n in pinned:
        o, s = files[n]
        rows.append('        new("%s", %d, %d, "%s"),' % (n.split('\\')[-1], o, s, hashlib.sha256(solid[o:o + s]).hexdigest()))
    tree = json.load(urllib.request.urlopen('https://api.github.com/repos/tesseract-ocr/tessdata_fast/git/trees/' + commit))
    sizes = {t['path'][:-12]: t['size'] for t in tree['tree'] if t['path'].endswith('.traineddata')}
    langs = []
    for code, (tag, name) in sorted(LANGUAGES.items(), key=lambda kv: kv[1][1]):
        data = fetch('https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/%s/%s.traineddata' % (commit, code),
                     os.path.join(work, code + '.traineddata'))
        if len(data) != sizes[code]: sys.exit(code + ': not the size GitHub lists')
        langs.append('        new("%s", "%s", "%s", %d, "%s"),' % (code, tag, name, len(data), hashlib.sha256(data).hexdigest()))

    out = os.path.join(os.path.dirname(__file__), '..', '..', 'src', 'InkvoltPdf.Core', 'TesseractCatalog.cs')
    with open(out, 'w', encoding='utf-8', newline='\n') as f:
        f.write('''// Written by pdf/tools/tesseract-pin/pin.py; run it again to pin another release rather than editing this file.

namespace InkvoltPdf.Core;

public static partial class TesseractCatalog
{
    /// <summary>Tesseract's version as its Windows installer names it.</summary>
    public const string Version = "%s";

    /// <summary>The installer: tesseract-ocr/tesseract's GitHub release, built and signed by UB Mannheim.</summary>
    public static readonly Uri InstallerUrl = new("%s");

    public const long InstallerSize = %d;

    public const string InstallerSha256 = "%s";

    /// <summary>Where the installer's solid LZMA stream starts (after NSIS's first header), its properties byte and dictionary size.</summary>
    public const long StreamOffset = %d;

    public const byte StreamProperties = %d;

    public const uint StreamDictionary = %d;

    /// <summary>tesseract.exe, the DLLs it loads, and the licence: each one's place in the decompressed stream, size and SHA-256.</summary>
    public static readonly EngineFile[] EngineFiles =
    [
%s
    ];

    /// <summary>The tessdata_fast commit the language data is taken from.</summary>
    public const string LanguageCommit = "%s";

    /// <summary>Tesseract's languages (code, BCP-47 tag, English name, size, SHA-256), by English name.</summary>
    public static readonly TesseractLanguage[] Languages =
    [
%s
    ];
}
''' % (version, url, len(installer), sha, start, props, dict_size, '\n'.join(rows), commit, '\n'.join(langs)))
    print('wrote', os.path.normpath(out), len(rows), 'engine files,', len(langs), 'languages')


main()

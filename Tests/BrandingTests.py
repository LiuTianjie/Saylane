"""Brand names change; installed identities, data and published URLs must not."""
from pathlib import Path
from html.parser import HTMLParser
import plistlib

root = Path(__file__).resolve().parents[1]
def read(path):
    return (root / path).read_text()

info = plistlib.loads((root / 'Sources/Info.plist').read_bytes())
assert info['CFBundleDisplayName'] == 'Saylane'
assert info['InputMethodServerControllerClass'] == 'SaylaneInputController'
assert info['InputMethodServerDelegateClass'] == 'SaylaneInputController'
assert info['TISInputSourceID'] == 'com.rtranslate.inputmethod.rtranslate'
assert '@objc(SaylaneInputController)' in read('Sources/IME/SaylaneInputController.swift')
assert 'PRODUCT_NAME: Saylane' in read('project.yml')
assert 'PRODUCT_BUNDLE_IDENTIFIER: com.rtranslate.inputmethod.rtranslate' in read('project.yml')
assert 'com.rtranslate.final-polish' in read('Sources/Services/PolishKeychain.swift')
assert '"RTranslate/ASRModels"' in read('Sources/Models/SpeechModel.swift')
for path in ('Sources/IME/Pinyin/PinyinLexicon.swift', 'Sources/IME/Pinyin/PinyinLanguageModel.swift'):
    assert '"RTranslate", isDirectory: true' in read(path)
for path in ('scripts/pkg/preinstall', 'scripts/uninstall.sh'):
    text = read(path)
    assert '/Library/Input Methods/Saylane.app' in text
    assert '/Library/Input Methods/RTranslate.app' in text
    assert 'Refusing' in text
assert 'Contents/MacOS/Saylane' in read('scripts/pkg/postinstall')
assert 'Sources/Saylane.entitlements' in read('scripts/package.sh')

class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.telemetry = 0
        self.in_head = False
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == 'head':
            self.in_head = True
        if tag == 'script' and a.get('src') == 'https://vibecafe.ai/telemetry/v1.js':
            assert self.in_head and 'defer' in a
            assert a['data-vc-auth-key'] == 'vc_web_QiyGrUq2rzni6P87THnMkoUvRykblZjuu6GFoQs_d7c'
            self.telemetry += 1
        for key in ('src', 'href'):
            value = a.get(key, '')
            if value.startswith('./'):
                assert (root / 'website' / value.split('?')[0]).is_file(), value
    def handle_endtag(self, tag):
        if tag == 'head':
            self.in_head = False

html = read('website/index.html')
page = Page()
page.feed(html)
assert page.telemetry == 1
assert '<h1>Saylane</h1>' in html
assert html.count('class="brand-name">Saylane</span>') == 2
assert 'https://github.com/LiuTianjie/Saylane/releases/download/v0.2.53/Saylane-0.2.53.pkg' in html
print('PASS: Saylane branding, stable identity/storage, upgrade paths, published links and single telemetry script')

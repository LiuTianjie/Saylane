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
keychain = read('Sources/Services/PolishKeychain.swift')
assert 'legacyService = "com.rtranslate.final-polish"' in keychain, 'old keychain items must still be readable'
assert 'service = "com.saylane.final-polish"' in keychain
directories = read('Sources/Core/AppDirectories.swift')
assert 'legacyProductName = "RTranslate"' in directories, 'existing RTranslate/ data must migrate or stay readable'
assert 'productName = "Saylane"' in directories
assert 'AppDirectories.asrModels' in read('Sources/Models/SpeechModel.swift')
assert 'AppDirectories.diagnostics' in read('Sources/Support/InputDiagnostics.swift')
assert 'AppDirectories.glossaryFile' in read('Sources/Services/DictationGlossaryRemote.swift')
assert 'AppDirectories.rime' in read('Sources/IME/Rime/RimeRuntime.swift')
assert 'UserDefaults.standard' not in read('Sources/AppModel.swift'), 'preferences go through PreferencesStore'
for swift in (root / 'Sources').rglob('*.swift'):
    if swift.name in ('PreferencesStore.swift',):
        continue
    assert 'UserDefaults.standard' not in swift.read_text(), f'{swift} bypasses PreferencesStore'
    assert '@AppStorage' not in swift.read_text(), f'{swift} bypasses PreferencesStore'
preinstall = read('scripts/pkg/preinstall')
postinstall = read('scripts/pkg/postinstall')
uninstall = read('scripts/uninstall.sh')
lifecycle = preinstall + postinstall + uninstall
assert '/Library/Input Methods/Saylane.app' in lifecycle
assert '/Library/Input Methods/RTranslate.app' in lifecycle
assert 'Refusing' in lifecycle or 'Preserved unexpected bundle' in lifecycle
assert '/Library/Input Methods/RTranslate.app' not in preinstall, 'legacy copies are removed only after payload publication'
assert 'Contents/MacOS/Saylane' in read('scripts/pkg/postinstall')
assert 'Sources/Saylane.entitlements' in read('scripts/package.sh')
settings = read('Sources/Services/SettingsController.swift')
assert 'setActivationPolicy(.regular)' not in settings
assert 'setActivationPolicy(.accessory)' in settings
assert not (root / 'Sources/Services/SetupController.swift').exists()
assert not (root / 'Sources/Views/SetupView.swift').exists()
permissions = read('Sources/Views/PermissionsSettingsView.swift')
assert '去开通' in permissions
assert '系统设置' in permissions
controller = read('Sources/IME/SaylaneInputController.swift')
assert 'overrideKeyboard(withKeyboardNamed: latinKeyboardLayout)' in controller
assert 'NSEvent.EventTypeMask([.keyDown, .flagsChanged])' in controller
assert '.leftMouseDown' not in controller
assert '.keyUp' not in controller

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
assert 'https://github.com/LiuTianjie/Saylane/releases/download/v0.2.75/Saylane-0.2.75.pkg' in html
print('PASS: Saylane branding, stable identity/storage, upgrade paths, published links and single telemetry script')

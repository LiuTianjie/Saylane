"""Brand names change; installed identities, data and published URLs must not."""
from pathlib import Path
from html.parser import HTMLParser
import plistlib

root = Path(__file__).resolve().parents[1]
def read(path):
    return (root / path).read_text()

ime = plistlib.loads((root / 'Sources/IME/Info.plist').read_bytes())
app = plistlib.loads((root / 'Sources/App/Info.plist').read_bytes())
project = read('project.yml')

# The input method keeps the identity users have enabled in System Settings.
assert ime['CFBundleDisplayName'] == 'Saylane' and app['CFBundleDisplayName'] == 'Saylane'
assert ime['InputMethodServerControllerClass'] == 'SaylaneInputController'
assert ime['InputMethodServerDelegateClass'] == 'SaylaneInputController'
assert ime['TISInputSourceID'] == 'com.rtranslate.inputmethod.rtranslate'
assert ime['InputMethodConnectionName'] == '$(PRODUCT_BUNDLE_IDENTIFIER)_Connection', \
    'macOS derives the connection name from the bundle identifier; any other value is refused'
assert '@objc(SaylaneInputController)' in read('Sources/IME/SaylaneInputController.swift')
assert 'PRODUCT_NAME: SaylaneIME' in project and 'PRODUCT_NAME: Saylane\n' in project
assert 'PRODUCT_BUNDLE_IDENTIFIER: com.rtranslate.inputmethod.rtranslate' in project
assert 'PRODUCT_BUNDLE_IDENTIFIER: com.rtranslate.saylane' in project

# Two processes with separate jobs (docs/DESIGN_0.3.md). The input method is a
# background-only process that asks for nothing; everything that needs a
# permission, a window or a model is the main program's.
assert ime['LSBackgroundOnly'] is True and 'LSUIElement' not in ime
assert app['LSUIElement'] is True and 'LSBackgroundOnly' not in app
assert not [key for key in ime if key.endswith('UsageDescription')], 'the input method requests no permission'
assert {'NSMicrophoneUsageDescription', 'NSSpeechRecognitionUsageDescription', 'NSScreenCaptureUsageDescription'} <= set(app)
assert not [key for key in app if key.startswith('InputMethod') or key.startswith('ts') or key == 'ComponentInputModeDict'], \
    'the main program is not an input method'
ime_target = project[project.index('  SaylaneIME:'):project.index('  Saylane:\n')]
assert 'MLXASR' not in ime_target and 'Vendor/FunASR' not in ime_target and 'CODE_SIGN_ENTITLEMENTS' not in ime_target
forbidden = ('import AVFoundation', 'import AVFAudio', 'import Speech', 'import ScreenCaptureKit', 'import Translation',
             'import CoreML', 'AppModel', 'AXIsProcessTrusted', 'CGEvent.tapCreate', 'URLSession')
for swift in (root / 'Sources/IME').rglob('*.swift'):
    text = swift.read_text()
    for word in forbidden:
        assert word not in text, f'{swift.name}: {word} belongs to the main program'
for swift in list((root / 'Sources').rglob('*.swift')):
    if 'Sources/IME/' in str(swift) or 'Sources/Shared/' in str(swift):
        continue
    text = swift.read_text()
    assert 'import InputMethodKit' not in text, f'{swift}: InputMethodKit belongs to the input method'
# The language model: the reader plugin ships with the input method, the model
# never does, and the input method does not fetch anything itself.
assert 'Vendor/Rime/Runtime/lib/rime-plugins/librime-octagram.dylib' in ime_target and 'subpath: rime-plugins' in ime_target
prepare = read('scripts/prepare-rime.py')
assert "if plugin.name != 'librime-octagram.dylib': plugin.unlink()" in prepare, 'no Lua or prediction plugin ships'
assert "librime-octagram.dylib " in read('scripts/stage-bundles.sh')
assert not list((root / 'Vendor/Rime/Rime').glob('*.gram')), 'no language model is shipped'
model = read('Sources/Services/PinyinLanguageModel.swift')
assert 'static let sha256 = "' in model and 'guard digest == Self.sha256' in model, 'the download is checked against a pinned hash'
main = read('Sources/App/SaylaneMain.swift')
assert 'IMKServer' not in main and '--register-input-source' in main
assert '--register-input-source' not in read('Sources/IME/SaylaneIMEMain.swift'), \
    'the input method is never run as a command: every exit of that process counts against it'

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
# Preferences stay in the input method's domain, so an upgrade keeps them; the
# main program reaches them through the store, the input method reads its own.
assert 'static let defaultsSuite = TestHome.isActive ? "local.saylane.test" : imeBundleID' in read('Sources/Shared/BridgeMessages.swift')
assert 'UserDefaults(suiteName: Bridge.defaultsSuite)' in read('Sources/App/AppModel.swift')
# A self-test of the input method runs with the product's own bundle identifier:
# in a test home it must use the test domain, never the installed product's.
assert 'TestHome.isActive\n        ? UserDefaults(suiteName: Bridge.defaultsSuite) ?? .standard : .standard' in read('Sources/IME/IMEHost.swift')
for script in ('test-ime.sh', 'test-duo.sh', 'test-ui.sh'):
    text = read('scripts/' + script)
    assert 'source scripts/test-home.sh' in text and 'assert_real_preferences_untouched "$REAL_BEFORE"' in text, script
for swift in (root / 'Sources').rglob('*.swift'):
    if swift.name in ('PreferencesStore.swift', 'IMEHost.swift'):
        continue
    assert 'UserDefaults.standard' not in swift.read_text(), f'{swift} bypasses PreferencesStore'
    assert '@AppStorage' not in swift.read_text(), f'{swift} bypasses PreferencesStore'
preinstall = read('scripts/pkg/preinstall')
postinstall = read('scripts/pkg/postinstall')
uninstall = read('scripts/uninstall.sh')
lifecycle = preinstall + postinstall + uninstall
assert '/Library/Input Methods/Saylane.app' in lifecycle and '/Applications/Saylane.app' in lifecycle
assert '/Library/Input Methods/RTranslate.app' in lifecycle
assert 'Refusing' in lifecycle or 'Preserved unexpected bundle' in lifecycle
assert 'RTranslate.app' not in preinstall, 'legacy copies are removed only after payload publication'
assert "APP='/Applications/Saylane.app'" in postinstall and 'APP_BIN="$APP/Contents/MacOS/Saylane"' in postinstall
assert 'Sources/App/Saylane.entitlements' in read('scripts/stage-bundles.sh')
settings = read('Sources/Services/SettingsController.swift')
assert 'setActivationPolicy(.regular)' not in settings
assert 'setActivationPolicy(.accessory)' in settings
assert not (root / 'Sources/Services/SetupController.swift').exists()
assert not (root / 'Sources/Views/SetupView.swift').exists()
permissions = read('Sources/Views/SetupChecklistView.swift')
assert '打开系统设置' in permissions
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
print('PASS: Saylane branding, stable identity/storage, two processes with separate jobs, upgrade paths, published links and single telemetry script')

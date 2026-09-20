import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location('benchmark', Path(__file__).resolve().parents[1] / 'scripts/benchmark-asr.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
assert module.distance('今天开会', '明天开会') == 1
assert module.distance('你好', '你好啊') == 1
assert module.distance('你好', '好') == 1
assert module.score('打开 React Native。', '打开react native')['exact_match']
assert module.score('打开 React Native', '打开 React', ['React Native'])['term_hits'] == 0
assert not module.term_present('AI', 'chair')
assert not module.term_present('C++', 'C language')
assert module.term_present('React Native', '修改ReactNative组件')
assert module.score('', '凭空识别')['false_speech']
assert module.percentile([1, 2, 8], .95) == 8
assert module.percentile([], .95) is None
summary = module.summarize([
    {'score': module.score('你好', '您好'), 'setupMS': 10, 'finalizeMS': 20},
    {'score': module.score('', '凭空识别'), 'setupMS': 20, 'finalizeMS': 30},
    {'error': 'failed'},
])
assert summary['character_error_rate'] == .5
assert summary['silent_false_speech'] == 1 and summary['failures'] == 1
assert summary['firstHypothesisMS']['n'] == 0
print('PASS: corpus scoring, term recall, silent controls, missing timings and latency percentiles')

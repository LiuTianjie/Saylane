"""Generate a reviewable evidence page; predictions are diagnostic, not translations."""
import base64, io, json, html
from pathlib import Path
from PIL import Image
root=Path('build/font-weight')
sections=[];scores={}
for name in ['open-source','native','paper','x','chat']:
 p=root/(name+'.json')
 if not p.exists():continue
 result=json.loads(p.read_text());im=Image.open(result['image']);rows=[]
 labels=json.loads((root/'native.labels.json').read_text()) if name=='native' else None
 confident=correct=wrong=0;falsebold=0
 for i,row in enumerate(result['rows']):
  crop=im.crop(row['box']);buf=io.BytesIO();crop.save(buf,format='PNG')
  expected=('bold' if labels[i]['bold'] else 'regular') if labels else 'regular' if name=='open-source' else None
  decision=row['decision'];p=row['bold_probability']
  if expected:
   if decision!='uncertain':
    confident+=1;correct+=int(decision==expected);wrong+=int(decision!=expected)
   falsebold+=int(expected=='regular' and decision=='bold')
  color='#b42318' if expected and decision not in [expected,'uncertain'] else '#067647' if decision!='uncertain' else '#946200'
  rows.append('<tr><td><img src="data:image/png;base64,'+base64.b64encode(buf.getvalue()).decode()+'"></td><td>'+html.escape(row['text'])+'</td><td style="color:'+color+'">'+decision+'</td><td>'+f'{p:.3f}'+'</td><td>'+(expected or '未标注')+'</td></tr>')
 if labels or name=='open-source':scores[name]={'rows':len(result['rows']),'confident':confident,'correct_confident':correct,'wrong_confident':wrong,'false_bold':falsebold}
 sections.append('<h2>'+name+'</h2><p>软最大分数不是经过校准的可信概率；灰区保留不确定。图片均为原图局部，未修改字重。</p><table><tr><th>原图文字</th><th>OCR</th><th>预测</th><th>粗体分数</th><th>测试标签</th></tr>'+''.join(rows)+'</table>')
(root/'review.html').write_text('<!doctype html><meta charset="utf-8"><title>字体属性模型实测</title><style>body{font:15px system-ui;margin:32px;background:#fafafa;color:#222}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ddd;padding:12px;text-align:left}img{max-width:480px;max-height:64px}h2{margin-top:48px}</style><h1>字体属性小模型 · 原图对照</h1>'+''.join(sections))
(root/'evaluation-summary.json').write_text(json.dumps(scores,indent=2))
print(json.dumps(scores,indent=2))

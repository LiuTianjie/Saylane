"""Offline prototype only. No app integration and no screenshot training data.
Run with a project-local Python 3.12 venv containing torch, coremltools, Pillow, numpy.
"""
import argparse, json, random, time, re
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import torch
from torch import nn

SEED = 173
random.seed(SEED); np.random.seed(SEED); torch.manual_seed(SEED)
torch.set_num_threads(4)
OUT = Path('build/font-weight'); OUT.mkdir(parents=True, exist_ok=True)
TEXTS = [
 'The quick brown fox jumps over the lazy dog.',
 'A new application makes everyday work easier.',
 'Read the article and check the original source.',
 'The next meeting begins at 9:30 on Thursday.',
 'Small details matter when designing a useful interface.',
 'Learning and research require careful experiments.',
 'Please review these changes before the next release.',
 'A practical guide to building reliable software.',
 '1234567890 abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ',
 'Support independent projects and their contributors.',
]
TEST_TEXTS = ['Fresh evidence should change our assumptions.', '42 readers saved this message yesterday.',
              'Download the report and continue your investigation.']
CJK = ['这是一段用于测试文字粗细的普通中文内容。', '请阅读完整信息，然后选择需要使用的功能。',
       '软件开发需要认真验证，不能仅凭猜测作出结论。']

class WeightNet(nn.Module):
 def __init__(self):
  super().__init__()
  self.features = nn.Sequential(nn.Conv2d(1,12,3,padding=1),nn.ReLU(),nn.MaxPool2d(2),
   nn.Conv2d(12,24,3,padding=1),nn.ReLU(),nn.MaxPool2d(2),
   nn.Conv2d(24,32,3,padding=1),nn.ReLU(),nn.AdaptiveAvgPool2d((2,4)))
  self.head=nn.Sequential(nn.Flatten(),nn.Linear(256,32),nn.ReLU(),nn.Linear(32,2))
 def forward(self,x): return self.head(self.features(x))

def faces():
 base=Path('/System/Library/Fonts/Supplemental')
 train=[]; held=[]
 for name in ['Arial','Times New Roman','Courier New','Tahoma','Trebuchet MS','Georgia','Verdana']:
  target=held if name in ['Georgia','Verdana'] else train
  for bold in [0,1]:
   for italic in [False,True]:
    suffix=(' Bold' if bold else '')+(' Italic' if italic else '')
    p=base/(name+suffix+'.ttf')
    if p.exists(): target.append((str(p),0,bold,False))
 p='/System/Library/Fonts/Helvetica.ttc'
 train.extend([(p,0,0,False),(p,1,1,False),(p,2,0,False),(p,3,1,False)])
 p='/System/Library/Fonts/Avenir Next.ttc'
 held.extend([(p,7,0,False),(p,0,1,False)])
 ping=next(Path('/System/Library/AssetsV2/com_apple_MobileAsset_Font8').glob('*/AssetData/PingFang.ttc'))
 train.extend([(str(ping),3,0,True),(str(ping),11,1,True)])
 return train,held

def patches(ink, offsets=(0.0,0.5,1.0)):
 # Normalize glyph height without squashing width. White = ink, black = background.
 a=np.asarray(ink)
 ys,xs=np.where(a>50)
 if len(xs)<8: return []
 ink=ink.crop((int(xs.min()),int(ys.min()),int(xs.max()+1),int(ys.max()+1)))
 width=max(1,round(ink.width*24/ink.height))
 ink=ink.resize((width,24),Image.Resampling.BILINEAR)
 out=[]
 for frac in offsets:
  left=round(max(0,width-128)*frac)
  strip=ink.crop((left,0,min(width,left+128),24))
  canvas=Image.new('L',(128,32)); canvas.paste(strip,(0,4))
  out.append(np.asarray(canvas,dtype=np.float32)[None]/255)
 return out

def sample(face,texts):
 path,index,label,cjk=face
 text=random.choice(CJK if cjk else texts)
 size=random.randint(13,48)
 font=ImageFont.truetype(path,size,index=index)
 box=font.getbbox(text)
 img=Image.new('L',(box[2]-box[0]+12,box[3]-box[1]+12))
 ImageDraw.Draw(img).text((6-box[0],6-box[1]),text,font=font,fill=255)
 if random.random()<0.55: img=img.filter(ImageFilter.GaussianBlur(random.uniform(0,0.65)))
 if random.random()<0.4:
  scale=random.uniform(.65,1.3)
  img=img.resize((max(1,int(img.width*scale)),max(1,int(img.height*scale))),Image.Resampling.BILINEAR)
 arr=patches(img,(random.random(),))[0]
 arr=np.clip(arr*random.uniform(.65,1.0)+np.random.normal(0,.015,arr.shape),0,1)
 return arr.astype('float32'),label

def dataset(fonts,count,texts):
 data=[sample(random.choice(fonts),texts) for _ in range(count)]
 return torch.tensor(np.stack([x for x,y in data])),torch.tensor([y for x,y in data])

def metrics(model,x,y):
 with torch.no_grad(): p=torch.cat([model(b).softmax(1) for b in x.split(128)])
 pred=p.argmax(1); certain=p.max(1).values>=.9
 return dict(accuracy=float((pred==y).float().mean()),confident_fraction=float(certain.float().mean()),
  confident_accuracy=float((pred[certain]==y[certain]).float().mean()) if certain.any() else None,
  regular_false_bold=float((pred[y==0]==1).float().mean()),count=len(y))

def from_crop(crop):
 a=np.array(crop.convert('L'),dtype=np.float32)
 border=np.concatenate([a[0],a[-1],a[:,0],a[:,-1]])
 paper=np.median(border);d=np.abs(a-paper);contrast=np.percentile(d,98)
 return Image.fromarray(np.uint8(np.clip(d/max(contrast,1),0,1)*255))

def native_dataset(split):
 root=OUT/'native-training'; manifest=json.loads((root/'manifest.json').read_text())
 data=[]
 for row in manifest:
  if row['split']!=split:continue
  im=Image.open(root/row['file']).convert('RGB')
  if split=='train' and random.random()<.35:im=im.filter(ImageFilter.GaussianBlur(random.uniform(0,.6)))
  if split=='train' and random.random()<.3:
   scale=random.uniform(.7,1.2);im=im.resize((max(1,int(im.width*scale)),max(1,int(im.height*scale))),Image.Resampling.BILINEAR)
  data.append((patches(from_crop(im),(random.random(),))[0],row['bold']))
 return torch.tensor(np.stack([x for x,y in data])),torch.tensor([y for x,y in data])

def train(native=False):
 trainfaces,holdfaces=faces()
 print('Generating training data',flush=True)
 if native:
  x,y=native_dataset('train');vx,vy=native_dataset('validation');hx,hy=native_dataset('holdout')
 else:
  x,y=dataset(trainfaces,8000,TEXTS)
  vx,vy=dataset(trainfaces,1200,TEST_TEXTS)
  hx,hy=dataset(holdfaces,2000,TEST_TEXTS)
 model=WeightNet(); opt=torch.optim.Adam(model.parameters(),lr=.002)
 best=0
 for epoch in range(12):
  model.train(); order=torch.randperm(len(y))
  for ids in order.split(128):
   opt.zero_grad(); loss=nn.functional.cross_entropy(model(x[ids]),y[ids]); loss.backward(); opt.step()
  model.eval(); m=metrics(model,vx,vy)
  print(epoch+1,m,flush=True)
  if m['accuracy']>best:
   best=m['accuracy']; torch.save(model.state_dict(),OUT/'weight.pt')
 model.load_state_dict(torch.load(OUT/'weight.pt',weights_only=True)); model.eval()
 report={'native_training':native,'seed':SEED,'parameters':sum(p.numel() for p in model.parameters()),
  'validation_new_text':metrics(model,vx,vy),'held_out_font_families':metrics(model,hx,hy),
  'train_faces':trainfaces,'holdout_faces':holdfaces,
  'limitations':['Native CoreText rendering.' if native else 'Synthetic Pillow rendering, not native CoreText.', 'Chinese has only one font family; no Chinese family generalization claim.',
   'Binary regular/bold only; medium and mixed-weight text are not trained classes.']}
 if native:
  manifest=json.loads((OUT/'native-training'/'manifest.json').read_text())
  report['train_faces']=sorted({r['font'] for r in manifest if r['split']=='train'})
  report['holdout_faces']=sorted({r['font'] for r in manifest if r['split']=='holdout'})
  report['train_count']=sum(r['split']=='train' for r in manifest)
 (OUT/'training.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
 print(json.dumps(report,ensure_ascii=False),flush=True)
 traced=torch.jit.trace(model,torch.zeros(1,1,32,128)); traced.save(str(OUT/'weight-traced.pt'))
 import coremltools as ct
 ml=ct.convert(traced,inputs=[ct.TensorType(name='ink',shape=(1,1,32,128))],
  outputs=[ct.TensorType(name='logits')],minimum_deployment_target=ct.target.macOS13)
 ml.save(str(OUT/'FontWeight.mlpackage'))
 # Check actual Core ML execution agrees with training framework before native timing.
 errors=[]
 for a in vx[:30]:
  native=ml.predict({'ink':a[None].numpy()})['logits']
  with torch.no_grad(): expected=model(a[None]).numpy()
  errors.append(float(np.max(np.abs(native-expected))))
 (OUT/'conversion.json').write_text(json.dumps({'max_logit_error':max(errors)},indent=2))

def evaluate(imagepath,ocrpath,label):
 model=WeightNet(); model.load_state_dict(torch.load(OUT/'weight.pt',weights_only=True)); model.eval()
 im=Image.open(imagepath).convert('RGB'); output=[]; allpatch=[]; counts=[]
 for line in Path(ocrpath).read_text().splitlines():
  coords,text=line.split('\t',1); x,y,w,h=map(float,re.findall(r'[-+]?\d*\.?\d+(?:e[-+]?\d+)?',coords))
  box=(max(0,int(x*im.width)-2),max(0,int((1-y-h)*im.height)-2),min(im.width,int((x+w)*im.width)+3),min(im.height,int((1-y)*im.height)+3))
  ink=from_crop(im.crop(box))
  pp=patches(ink); allpatch+=pp;counts.append(len(pp))
  output.append({'text':text,'box':box,'patches':len(pp)})
 start=time.perf_counter()
 with torch.no_grad(): probs=model(torch.tensor(np.stack(allpatch))).softmax(1)[:,1].numpy()
 elapsed=(time.perf_counter()-start)*1000
 offset=0
 for row,n in zip(output,counts):
  p=float(np.median(probs[offset:offset+n])) if n else .5;offset+=n
  row.update(bold_probability=p,decision='bold' if p>=.9 else 'regular' if p<=.1 else 'uncertain')
 result={'image':imagepath,'batch_inference_ms':elapsed,'rows':output}
 (OUT/(label+'.json')).write_text(json.dumps(result,ensure_ascii=False,indent=2))
 np.save(OUT/(label+'-patches.npy'),np.stack(allpatch))
 # Raw float input also consumed by the independent Swift/Core ML runtime test.
 np.stack(allpatch).astype('float32').tofile(OUT/(label+'-patches.f32'))
 print(label,round(elapsed,2),'ms',[(r['text'][:40],round(r['bold_probability'],3)) for r in output],flush=True)

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('mode',choices=['train','train-native','eval']);p.add_argument('args',nargs='*');a=p.parse_args()
 if a.mode in ['train','train-native']:train(a.mode=='train-native')
 else:evaluate(*a.args)

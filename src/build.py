"""Збирає index.html з шаблону й даних. Запуск: python3 src/data.py && python3 src/build.py"""
import json,re,os
here=os.path.dirname(os.path.abspath(__file__)); root=os.path.dirname(here)
t=open(os.path.join(here,"template.html")).read()
data=json.load(open(os.path.join(here,"data.json")))
logo=open(os.path.join(here,"logo.svg")).read()
logo=re.sub(r'\s(width|height)="[^"]*"','',logo,count=2)
logo=logo.replace('xmlns:c2pa="http://c2pa.org/manifest"','').replace('id="g"','id="ayrupLogoGrad"').replace('url(#g)','url(#ayrupLogoGrad)')
logo=re.sub(r'(\d+\.\d)\d+',r'\1',logo).replace('<svg ','<svg role="img" aria-label="ayrup" ',1)
out=t.replace("__LOGO__",logo).replace("__DATA__",json.dumps(data,ensure_ascii=False)).replace("__CONFIG_TAG__",'<script src="config.js"></script>')
open(os.path.join(root,"index.html"),"w").write(out)
print("index.html зібрано")

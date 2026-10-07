import os,re
from pathlib import Path
p=Path(__file__).resolve().parents[1]/'ios/project.yml'
b=os.environ.get('APP_BUNDLE_ID','vn.nguyenban.nbwebmap').strip()
if not re.fullmatch(r'[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)+',b):raise SystemExit('Invalid Bundle ID')
s=p.read_text().replace('vn.nguyenban.nbwebmap.Broadcast',b+'.Broadcast').replace('PRODUCT_BUNDLE_IDENTIFIER: vn.nguyenban.nbwebmap\n','PRODUCT_BUNDLE_IDENTIFIER: '+b+'\n')
p.write_text(s)

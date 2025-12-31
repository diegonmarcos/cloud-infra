#!/usr/bin/env python3
"""Auto: folders -> menu -> HTML"""
import os, shutil, markdown

DOCS, DIST = "docs", "dist"

def title(path):
    for l in open(path):
        if l.startswith('# '): return l[2:].strip()
    return os.path.basename(path).replace('.md','').title()

def tree(d):
    t = {'f':[], 'd':{}}
    for i in sorted(os.listdir(d)):
        p = f"{d}/{i}"
        if os.path.isdir(p): t['d'][i] = tree(p)
        elif i.endswith('.md'): t['f'].append((os.path.relpath(p,DOCS).replace('.md','.html'), title(p), i=='index.md'))
    return t

def menu(t, cur, pre, dep=0):
    o = []
    for p,n,idx in sorted(t['f'], key=lambda x:(not x[2],x[1])):
        if not dep or not idx: o.append(f'<li><a href="{pre}{p}"{"style=\"font-weight:bold\""if p==cur else""}>{n}</a></li>')
    for k,s in sorted(t['d'].items()):
        ix = next(((p,n) for p,n,i in s['f'] if i), None)
        n,h = (ix[1],f'{pre}{ix[0]}') if ix else (k.title(),'#')
        o.append(f'<li><a href="{h}"><b>{n}</b></a>')
        c = menu(s,cur,pre,dep+1)
        if c: o.append(f'<ul>{c}</ul>')
        o.append('</li>')
    return '\n'.join(o)

def build():
    shutil.rmtree(DIST,ignore_errors=True); os.makedirs(DIST)
    t = tree(DOCS)
    for r,_,fs in os.walk(DOCS):
        for f in [x for x in fs if x.endswith('.md')]:
            s,rel = f"{r}/{f}", os.path.relpath(f"{r}/{f}",DOCS).replace('.md','.html')
            os.makedirs(os.path.dirname(f"{DIST}/{rel}") or DIST, exist_ok=True)
            open(f"{DIST}/{rel}",'w').write(f'''<!DOCTYPE html><html><head><meta charset="utf-8"><title>{title(s)}</title></head>
<body><div style="display:flex"><nav style="width:220px;padding:20px;background:#f5f5f5"><ul>
{menu(t,rel,'../'*rel.count('/'))}</ul></nav>
<main style="padding:20px">{markdown.markdown(open(s).read(),extensions=['tables'])}</main></div></body></html>''')
            print(f'  {rel}')
    print('\nDone!')

if __name__=="__main__": build()

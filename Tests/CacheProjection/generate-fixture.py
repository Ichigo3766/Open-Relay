"""Generate an invented plain history; never read an existing conversation."""
from pathlib import Path
import argparse,json
p=argparse.ArgumentParser()
p.add_argument("messages",type=int)
p.add_argument("output",type=Path)
a=p.parse_args()
repo=Path(__file__).resolve().parents[2]
out=a.output.resolve()
if a.messages<=0 or a.messages%2:raise SystemExit("Use a positive even message count.")
if out==repo or repo in out.parents:raise SystemExit("Keep generated fixtures outside the checkout.")
nodes={};previous=None
for n in range(a.messages//2):
 uid,aid=f'invented-kite-user-{n}',f'invented-kite-assistant-{n}'
 if previous:nodes[previous]["childrenIds"]=[uid]
 nodes[uid]={"id":uid,"role":"user","content":f"Invent a fictional paper tower display {n}.","parentId":previous,"childrenIds":[aid],"models":["invented-model"],"timestamp":1700000000+n*2}
 nodes[aid]={"id":aid,"role":"assistant","content":f"Fictional kite display {n} uses cardboard tower {n%137}.\n\nAn imagined turquoise ticket machine records a paper sample.","done":True,"parentId":uid,"childrenIds":[],"model":"invented-model","timestamp":1700000001+n*2}
 previous=aid
data={"id":"invented-kite-chat","title":"Invented kite museum","chat":{"history":{"messages":nodes,"currentId":previous},"messages":list(nodes.values()),"models":["invented-model"]}}
out.parent.mkdir(parents=True,exist_ok=True)
out.write_text(json.dumps(data,separators=(",",":")))

"""Write a freshly invented chat for the completion-policy benchmark."""
from pathlib import Path
import argparse
import json

p = argparse.ArgumentParser()
p.add_argument("output", type=Path)
p.add_argument("--messages", type=int, default=100_000)
a = p.parse_args()
if a.messages < 1:
    p.error("--messages must be positive")
fixture = a.output.resolve()
root = Path(__file__).resolve().parents[2]
if fixture == root or root in fixture.parents:
    raise SystemExit("Write synthetic fixtures outside the checkout.")
nodes = {}
flat = []
for i in range(a.messages):
    node = {
        "id": f"node-{i:06d}",
        "role": "assistant" if i % 2 else "user",
        "content": f"Invented telescope exhibit item {i:06d}. A cardboard star is on the table.",
        "done": True,
        "parentId": f"node-{i - 1:06d}" if i else None,
        "childrenIds": [f"node-{i + 1:06d}"] if i < a.messages - 1 else [],
        "model": "fixture-model",
        "timestamp": 1_700_000_000 + i,
        "files": [], "sources": [], "statusHistory": [], "annotations": [],
        "metrics": {"tokens": 12}, "info": {"fixture": True},
    }
    nodes[node["id"]] = node
    flat.append(node)
fixture.write_text(json.dumps({"history": {"messages": nodes, "currentId": f"node-{a.messages - 1:06d}"},
                               "messages": flat}, separators=(",", ":")))

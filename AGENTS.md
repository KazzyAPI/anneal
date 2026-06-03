
<!-- harness:guidance -->
## Harness protocol

This repo uses a self-improving harness (`./harness.sh`). Follow it every session:

1. **At session start**, run `./harness.sh start` to see the lesson index (counts
   and tags) — it is intentionally small to protect your context.
2. **Before working on an area**, pull only what's relevant:
   `./harness.sh recall "<topic / file / error>"`
   Do not load the whole knowledge base; retrieve on demand.
3. **When you make a mistake caught by tests, lint, or review**, immediately run:
   `./harness.sh learn --title "..." --fix "..." --problem "..." --tags a,b --evidence "test or command"`
   Record the lesson in one shot and move on — do not loop burning context.
4. **At session end**, run `./harness.sh reflect` to propose consolidated rules.
   Proposed changes are suggestions; the human approves them via `harness review`.
<!-- /harness:guidance -->

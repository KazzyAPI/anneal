
<!-- harness:guidance -->
## Harness protocol

This repo uses a self-improving harness (`./harness.sh`). Follow it every session:

1. **At session start**, hooks inject the lesson index automatically. If hooks are
   not wired, run `./harness.sh start` manually.
2. **Before working on an area**, pull only what's relevant:
   `./harness.sh recall "<topic / file / error>"`
   Do not load the whole knowledge base; retrieve on demand.
3. **When you make a mistake caught by tests, lint, or review**, immediately run:
   `./harness.sh learn --title "..." --fix "..." --problem "..." --tags a,b --evidence "test or command"`
   Record the lesson in one shot and move on — do not loop burning context.
4. **At session end**, hooks run `./harness.sh reflect` automatically. Review
   proposals with `./harness.sh review` — the human approves changes.
<!-- /harness:guidance -->

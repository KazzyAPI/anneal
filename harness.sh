#!/usr/bin/env bash
#
# harness — a self-improving harness for Cursor & Claude Code agents.
#
# Model: wrapper + coach + gardener.
#   wrapper  : `start` injects accumulated knowledge so every session starts smarter.
#   coach    : `learn` persists a mistake+fix in one shot so the agent moves on
#              without chewing context re-deriving the same lesson.
#   gardener : `reflect`/`review`/`apply` propose & (with approval) apply updates
#              to AGENTS.md, git-committed so they can be rolled back.
#
# Storage lives in ./.harness/ and is meant to be version-controlled.
# Dependencies: bash, awk, sort, git. No jq, no network — portable by design.
#
set -euo pipefail

HARNESS_VERSION="0.1.0"
# Where `upgrade` pulls the latest script from. Override with HARNESS_REMOTE.
HARNESS_REMOTE="${HARNESS_REMOTE:-https://github.com/KazzyAPI/anneal/releases/latest/download/harness.sh}"

TAB="$(printf '\t')"

# ---------------------------------------------------------------------------
# Locate the harness root (.harness/ in this repo, searching upward).
# ---------------------------------------------------------------------------
find_root() {
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -d "$dir/.harness" ]; then printf '%s\n' "$dir"; return 0; fi
    dir="$(dirname "$dir")"
  done
  return 1
}

REPO_ROOT="$(find_root || true)"
HARNESS_DIR="${REPO_ROOT:+$REPO_ROOT/.harness}"

DB="${HARNESS_DIR:-}/harness.db"
LEARNINGS_TSV="${HARNESS_DIR:-}/learnings.tsv"   # legacy store, auto-imported once
LEARNINGS_MD="${HARNESS_DIR:-}/LEARNINGS.md"
SESSIONS_DIR="${HARNESS_DIR:-}/sessions"
PROPOSALS_DIR="${HARNESS_DIR:-}/proposals"
APPLIED_DIR="${HARNESS_DIR:-}/applied"
CONFIG_FILE="${HARNESS_DIR:-}/config.sh"
CURRENT_SESSION_FILE="${HARNESS_DIR:-}/.current-session"

# Defaults (overridable in .harness/config.sh).
DIGEST_LIMIT=20      # entries written to LEARNINGS.md
RECALL_LIMIT=5       # entries returned by `recall`
START_TOP=3          # most-reinforced lessons shown in the `start` index
AGENTS_FILE="AGENTS.md"

# ---------------------------------------------------------------------------
# Output helpers.
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_DIM='\033[2m'; C_BOLD='\033[1m'; C_GRN='\033[32m'; C_YLW='\033[33m'; C_RED='\033[31m'; C_RST='\033[0m'
else
  C_DIM=''; C_BOLD=''; C_GRN=''; C_YLW=''; C_RED=''; C_RST=''
fi
say()  { printf '%b\n' "$*"; }
info() { printf '%b\n' "${C_DIM}$*${C_RST}"; }
ok()   { printf '%b\n' "${C_GRN}$*${C_RST}"; }
warn() { printf '%b\n' "${C_YLW}$*${C_RST}" >&2; }
die()  { printf '%b\n' "${C_RED}error:${C_RST} $*" >&2; exit 1; }

need_root() { [ -n "$HARNESS_DIR" ] && [ -d "$HARNESS_DIR" ] || die "no .harness/ found. Run: harness init"; }

load_config() { [ -f "$CONFIG_FILE" ] && # shellcheck disable=SC1090
  . "$CONFIG_FILE" || true; }

gen_id()  { printf '%s-%s' "$(date +%Y%m%d%H%M%S)" "$(( RANDOM % 9000 + 1000 ))"; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Resolve the absolute path of this script, following symlinks portably
# (macOS has no `readlink -f`).
resolve_self() {
  local src="$0"
  case "$src" in */*) ;; *) src="$(command -v "$src" 2>/dev/null || echo "$src")";; esac
  while [ -h "$src" ]; do
    local dir; dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in /*) ;; *) src="$dir/$src";; esac
  done
  printf '%s/%s\n' "$(cd -P "$(dirname "$src")" && pwd)" "$(basename "$src")"
}

# Download $1 to $2 using whichever of curl/wget is present.
fetch() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
  else die "need curl or wget to fetch $1"; fi
}

# Directory containing harness.sh (source checkout or global install path).
harness_source_root() { dirname "$(resolve_self)"; }

# Decode base64 stdin to stdout (portable via python3).
b64_decode() {
  python3 -c "import sys,base64; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))"
}

# Resolve templates/: source checkout dir, or extract embedded bundle on first use.
harness_templates_dir() {
  local src; src="$(harness_source_root)"
  if [ "${HARNESS_BUNDLED:-0}" = "1" ] && [ -n "${HARNESS_TAR_B64:-}" ]; then
    local cache="$src/.harness-templates-cache"
    if [ ! -f "$cache/.extracted" ]; then
      mkdir -p "$cache"
      printf '%s' "$HARNESS_TAR_B64" | b64_decode | tar -xzf - -C "$cache"
      touch "$cache/.extracted"
    fi
    printf '%s\n' "$cache"
    return 0
  fi
  if [ -d "$src/templates" ]; then
    printf '%s/templates\n' "$src"
    return 0
  fi
  die "templates not found beside harness.sh — reinstall from a release or use a source checkout"
}

# Collapse tabs/newlines so a value stays a single field.
clean() { printf '%s' "$1" | tr '\t\n' '  '; }

# --- SQLite layer ----------------------------------------------------------
need_sqlite() { command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 is required (ships with macOS; 'apt install sqlite3' on Linux)."; }

# Escape a value for single-quoted SQL literals.
sql_quote() { printf "%s" "$1" | sed "s/'/''/g"; }

# Run SQL against the harness DB.
db() { sqlite3 "$DB" "$@"; }

# Create schema if absent: source-of-truth table + FTS5 external-content index.
ensure_db() {
  need_sqlite
  db <<'SQL'
CREATE TABLE IF NOT EXISTS learnings (
  rid        INTEGER PRIMARY KEY AUTOINCREMENT,
  id         TEXT,
  ts         TEXT,
  session    TEXT,
  reinforced INTEGER DEFAULT 1,
  norm       TEXT UNIQUE,
  tags       TEXT,
  evidence   TEXT,
  title      TEXT,
  problem    TEXT,
  fix        TEXT
);
CREATE VIRTUAL TABLE IF NOT EXISTS learnings_fts USING fts5(
  title, problem, fix, tags,
  content='learnings', content_rowid='rid'
);
CREATE TRIGGER IF NOT EXISTS learnings_ai AFTER INSERT ON learnings BEGIN
  INSERT INTO learnings_fts(rowid,title,problem,fix,tags)
    VALUES (new.rid,new.title,new.problem,new.fix,new.tags);
END;
CREATE TRIGGER IF NOT EXISTS learnings_ad AFTER DELETE ON learnings BEGIN
  INSERT INTO learnings_fts(learnings_fts,rowid,title,problem,fix,tags)
    VALUES ('delete',old.rid,old.title,old.problem,old.fix,old.tags);
END;
CREATE TRIGGER IF NOT EXISTS learnings_au AFTER UPDATE ON learnings BEGIN
  INSERT INTO learnings_fts(learnings_fts,rowid,title,problem,fix,tags)
    VALUES ('delete',old.rid,old.title,old.problem,old.fix,old.tags);
  INSERT INTO learnings_fts(rowid,title,problem,fix,tags)
    VALUES (new.rid,new.title,new.problem,new.fix,new.tags);
END;
SQL
  migrate_tsv
}

# One-time import of a legacy learnings.tsv into the DB.
migrate_tsv() {
  [ -s "$LEARNINGS_TSV" ] || return 0
  local n; n="$(db "SELECT COUNT(*) FROM learnings;")"
  [ "${n:-0}" -eq 0 ] || return 0
  while IFS="$TAB" read -r id ts session reinforced norm tags evidence title problem fix; do
    [ -n "$norm" ] || continue
    db "INSERT OR IGNORE INTO learnings(id,ts,session,reinforced,norm,tags,evidence,title,problem,fix)
        VALUES('$(sql_quote "$id")','$(sql_quote "$ts")','$(sql_quote "$session")',
               ${reinforced:-1},'$(sql_quote "$norm")','$(sql_quote "$tags")',
               '$(sql_quote "$evidence")','$(sql_quote "$title")','$(sql_quote "$problem")','$(sql_quote "$fix")');"
  done < "$LEARNINGS_TSV"
  mv "$LEARNINGS_TSV" "$LEARNINGS_TSV.imported" 2>/dev/null || true
  info "Imported legacy learnings.tsv into harness.db"
}

# Turn free text into a safe FTS5 OR-query: alnum tokens, each quoted.
fts_query() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9' ' ' \
    | awk '{ for(i=1;i<=NF;i++){ printf "%s\"%s\"", (i>1?" OR ":""), $i } }'
}

# Session id: env override, else persisted, else freshly minted.
session_id() {
  if [ -n "${HARNESS_SESSION_ID:-}" ]; then printf '%s\n' "$HARNESS_SESSION_ID"; return; fi
  if [ -f "$CURRENT_SESSION_FILE" ]; then cat "$CURRENT_SESSION_FILE"; return; fi
  local sid; sid="$(gen_id)"
  printf '%s\n' "$sid" > "$CURRENT_SESSION_FILE"
  printf '%s\n' "$sid"
}

# ---------------------------------------------------------------------------
# init — scaffold .harness/ and teach the agent how to use it.
# ---------------------------------------------------------------------------
cmd_init() {
  local root="$PWD"
  REPO_ROOT="$root"; HARNESS_DIR="$root/.harness"
  DB="$HARNESS_DIR/harness.db"
  LEARNINGS_TSV="$HARNESS_DIR/learnings.tsv"
  LEARNINGS_MD="$HARNESS_DIR/LEARNINGS.md"
  SESSIONS_DIR="$HARNESS_DIR/sessions"
  PROPOSALS_DIR="$HARNESS_DIR/proposals"
  APPLIED_DIR="$HARNESS_DIR/applied"
  CONFIG_FILE="$HARNESS_DIR/config.sh"
  CURRENT_SESSION_FILE="$HARNESS_DIR/.current-session"

  mkdir -p "$HARNESS_DIR" "$SESSIONS_DIR" "$PROPOSALS_DIR" "$APPLIED_DIR"

  if [ ! -f "$CONFIG_FILE" ]; then
    cp "$(harness_templates_dir)/config.sh" "$CONFIG_FILE"
  fi
  load_config
  ensure_db

  local agents="$root/${AGENTS_FILE}"
  if ! grep -q "harness:guidance" "$agents" 2>/dev/null; then
    cat "$(harness_templates_dir)/agents-guidance.md" >> "$agents"
    ok "Added harness protocol to ${AGENTS_FILE}"
  fi

  cmd_digest >/dev/null 2>&1 || true
  ok "Initialized harness in $HARNESS_DIR"
  info "Next: ./harness.sh wire    then ./harness.sh doctor"
}

# ---------------------------------------------------------------------------
# wire — install enforcement hooks (Cursor + Claude Code) + always-on rule.
# AGENTS.md is guidance; hooks make start/reflect automatic. learn/recall
# still rely on postToolUse injection + the alwaysApply rule.
# ---------------------------------------------------------------------------
cmd_wire() {
  local root="${REPO_ROOT:-$PWD}"
  [ -f "$root/harness.sh" ] || die "wire: harness.sh not found in $root (run from project root or harness init first)"
  command -v python3 >/dev/null 2>&1 || die "wire: python3 is required for hook scripts"

  local tpl; tpl="$(harness_templates_dir)"
  mkdir -p "$root/.cursor/hooks" "$root/.cursor/rules" "$root/.claude"
  cp "$tpl/cursor/hooks.json" "$root/.cursor/hooks.json"
  cp -R "$tpl/cursor/hooks/." "$root/.cursor/hooks/"
  cp "$tpl/cursor/rules/harness-enforce.mdc" "$root/.cursor/rules/"
  cp "$tpl/claude/settings.json" "$root/.claude/settings.json"
  chmod +x "$root/.cursor/hooks/"*.sh "$root/.cursor/hooks/harness_hook.py" 2>/dev/null || true

  ok "Wired harness enforcement hooks"
  info "  Cursor:  .cursor/hooks.json + alwaysApply rule"
  info "  Claude:  .claude/settings.json"
  info "  Restart Cursor / Claude Code if hooks do not load immediately."
  warn "Hooks enforce start + reflect automatically. learn/recall still need agent compliance (injected on shell failures + alwaysApply rule)."
}

# ---------------------------------------------------------------------------
# learn — record a mistake+fix, de-duplicated by normalized title.
# ---------------------------------------------------------------------------
cmd_learn() {
  need_root; load_config
  local title="" problem="" fix="" tags="" evidence=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --title)    title="$2"; shift 2;;
      --problem)  problem="$2"; shift 2;;
      --fix)      fix="$2"; shift 2;;
      --tags)     tags="$2"; shift 2;;
      --evidence) evidence="$2"; shift 2;;
      *) die "learn: unknown arg '$1'";;
    esac
  done
  [ -n "$title" ] || die "learn: --title is required"
  [ -n "$fix" ]   || die "learn: --fix is required"

  ensure_db
  local norm; norm="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | sed 's/^ *//;s/ *$//')"
  norm="$(clean "$norm")"
  local sid; sid="$(session_id)"
  local ts; ts="$(now_iso)"
  title="$(clean "$title")"; problem="$(clean "$problem")"; fix="$(clean "$fix")"
  tags="$(clean "$tags")"; evidence="$(clean "$evidence")"

  local exists; exists="$(db "SELECT COUNT(*) FROM learnings WHERE norm='$(sql_quote "$norm")';")"
  if [ "${exists:-0}" -gt 0 ]; then
    # Reinforce: bump count, refresh timestamp and fix.
    db "UPDATE learnings SET reinforced = reinforced + 1, ts='$(sql_quote "$ts")',
           fix='$(sql_quote "$fix")' WHERE norm='$(sql_quote "$norm")';"
    ok "Reinforced existing learning: $title"
  else
    local id; id="$(gen_id)"
    db "INSERT INTO learnings(id,ts,session,reinforced,norm,tags,evidence,title,problem,fix)
        VALUES('$(sql_quote "$id")','$(sql_quote "$ts")','$(sql_quote "$sid")',1,
               '$(sql_quote "$norm")','$(sql_quote "$tags")','$(sql_quote "$evidence")',
               '$(sql_quote "$title")','$(sql_quote "$problem")','$(sql_quote "$fix")');"
    ok "Learned: $title"
  fi

  record_event "$sid" "learn" "$title"
  cmd_digest >/dev/null
}

# ---------------------------------------------------------------------------
# note / events — freeform session log (tab-separated: ts, kind, msg).
# ---------------------------------------------------------------------------
record_event() {
  local sid="$1" kind="$2" msg="$3"
  mkdir -p "$SESSIONS_DIR"
  printf '%s\t%s\t%s\n' "$(now_iso)" "$kind" "$(clean "$msg")" >> "$SESSIONS_DIR/$sid.tsv"
}
cmd_note() {
  need_root
  local msg="${*:-}"; [ -n "$msg" ] || die "note: provide a message"
  record_event "$(session_id)" "note" "$msg"
  ok "Noted."
}

# ---------------------------------------------------------------------------
# digest — regenerate LEARNINGS.md (human + agent readable).
# ---------------------------------------------------------------------------
cmd_digest() {
  need_root; load_config; ensure_db
  local count; count="$(db "SELECT COUNT(*) FROM learnings;")"
  # Tab-separated rows, most reinforced first, capped at DIGEST_LIMIT.
  local rows; rows="$(db -separator "$TAB" \
    "SELECT title, problem, fix, tags, reinforced, evidence
       FROM learnings ORDER BY reinforced DESC, ts DESC LIMIT $DIGEST_LIMIT;")"
  {
    echo "# Harness learnings"
    echo
    echo "_${count} learning(s). Generated $(now_iso). Most reinforced first._"
    echo
    printf '%s\n' "$rows" | awk -F"$TAB" '
      length($0)==0 { next }
      {
        printf "## %s", $1
        if (length($4)>0) printf "  `%s`", $4
        if ($5+0>1)       printf "  (x%s)", $5
        printf "\n"
        if (length($2)>0) printf "- problem: %s\n", $2
        printf "- fix: %s\n", $3
        if (length($6)>0) printf "- evidence: %s\n", $6
        printf "\n"
      }'
  } > "$LEARNINGS_MD"
  return 0
}

# ---------------------------------------------------------------------------
# start — print a CONSTANT-SIZE index, not the whole knowledge base.
# This is what keeps context flat as learnings grow into the thousands:
# the agent sees what exists and how to query it, then pulls with `recall`.
# ---------------------------------------------------------------------------
cmd_start() {
  need_root; load_config; ensure_db
  local sid; sid="$(gen_id)"
  printf '%s\n' "$sid" > "$CURRENT_SESSION_FILE"
  cmd_digest >/dev/null   # keep LEARNINGS.md fresh for human browsing

  local count; count="$(db "SELECT COUNT(*) FROM learnings;")"
  say "${C_BOLD}== harness: session $sid ==${C_RST}"
  say "${count} lesson(s) on file. Retrieve with: harness recall \"<topic>\""

  if [ "${count:-0}" -gt 0 ]; then
    # Tag index: every tag with a count, so the agent knows what's queryable.
    local tagidx; tagidx="$(db -separator '|' "
      WITH RECURSIVE split(tag, rest) AS (
        SELECT '', tags||',' FROM learnings WHERE tags<>''
        UNION ALL
        SELECT substr(rest,1,instr(rest,',')-1), substr(rest,instr(rest,',')+1) FROM split WHERE rest<>''
      )
      SELECT trim(tag) t, COUNT(*) c FROM split WHERE trim(tag)<>'' GROUP BY t ORDER BY c DESC, t LIMIT 25;")"
    if [ -n "$tagidx" ]; then
      say ""
      say "Tags: $(printf '%s' "$tagidx" | awk -F'|' '{printf "%s%s(%s)", (NR>1?", ":""), $1, $2}')"
    fi
    say ""
    say "Most reinforced:"
    db -separator "$TAB" "SELECT title, reinforced FROM learnings ORDER BY reinforced DESC, ts DESC LIMIT $START_TOP;" \
      | awk -F"$TAB" 'length($0)>0 {printf "  - %s%s\n", $1, ($2+0>1?"  (x"$2")":"")}'
  fi

  local pending=0; pending="$(ls -1 "$PROPOSALS_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')" || true
  if [ "${pending:-0}" -gt 0 ]; then warn "($pending proposal(s) awaiting review — run: harness review)"; fi
  info "Before working on an area, run: harness recall \"<topic>\"   Record lessons with: harness learn"
}

# ---------------------------------------------------------------------------
# recall — retrieve only the lessons relevant to a topic (FTS5 + reinforcement).
# This is the on-demand counterpart to a lean `start`: the agent pulls a few
# entries when it needs them instead of loading everything up front.
# ---------------------------------------------------------------------------
cmd_recall() {
  need_root; load_config; ensure_db
  local terms="${*:-}"; [ -n "$terms" ] || die "recall: usage: harness recall \"<topic>\""
  local limit="${RECALL_LIMIT:-5}"
  local q; q="$(fts_query "$terms")"
  [ -n "$q" ] || die "recall: no searchable terms in '$terms'"

  # bm25 (lower = better) minus a small reinforcement boost.
  local rows; rows="$(db -separator "$TAB" "
    SELECT l.title, l.fix, l.tags, l.reinforced, l.evidence
      FROM learnings_fts f JOIN learnings l ON l.rid = f.rowid
     WHERE learnings_fts MATCH '$(sql_quote "$q")'
     ORDER BY bm25(learnings_fts) - (l.reinforced * 0.2)
     LIMIT $limit;" 2>/dev/null)" || true

  if [ -z "$rows" ]; then
    info "No lessons match \"$terms\" yet."
    return 0
  fi
  say "${C_BOLD}Relevant lessons for \"$terms\":${C_RST}"
  printf '%s\n' "$rows" | awk -F"$TAB" '
    length($0)==0 { next }
    {
      printf "## %s", $1
      if (length($3)>0) printf "  `%s`", $3
      if ($4+0>1)       printf "  (x%s)", $4
      printf "\n- fix: %s\n", $2
      if (length($5)>0) printf "- evidence: %s\n", $5
      printf "\n"
    }'
}

# ---------------------------------------------------------------------------
# watch — run a command; on failure, log it as a learning candidate.
# ---------------------------------------------------------------------------
cmd_watch() {
  need_root
  [ "${1:-}" = "--" ] && shift
  [ $# -gt 0 ] || die "watch: usage: harness watch -- <command>"
  local sid; sid="$(session_id)"
  local rc=0
  "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then
    record_event "$sid" "failure" "cmd: $* (exit $rc)"
    warn "Command failed (exit $rc). Once fixed, capture the lesson:"
    info "  harness learn --title \"...\" --fix \"...\" --evidence \"$*\""
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# eval — run a test command, auto-log failures, detect failing->passing recovery.
# This is the "went well vs failed" signal: a recovery is the moment a lesson
# was learned, so the harness prompts you to capture it.
# ---------------------------------------------------------------------------
cmd_eval() {
  need_root
  [ "${1:-}" = "--" ] && shift
  [ $# -gt 0 ] || die "eval: usage: harness eval -- <test command>"
  local sid; sid="$(session_id)"
  local state="$HARNESS_DIR/.eval-state"
  local failfile="$HARNESS_DIR/last-failure.txt"
  local prev="pass"; [ -f "$state" ] && prev="$(cat "$state")"

  local tmp; tmp="$(mktemp)"
  local rc=0
  set +e +o pipefail
  "$@" 2>&1 | tee "$tmp"
  rc=${PIPESTATUS[0]}
  set -e -o pipefail

  if [ "$rc" -ne 0 ]; then
    tail -n 20 "$tmp" > "$failfile"
    record_event "$sid" "failure" "eval: $* (exit $rc)"
    printf 'fail\n' > "$state"
    warn ""
    warn "Tests FAILED (exit $rc). Once you fix it, capture the lesson in one shot:"
    info "  harness learn --title \"...\" --fix \"...\" --evidence \"$*\""
  else
    if [ "$prev" = "fail" ]; then
      record_event "$sid" "recovery" "eval: $* now passing"
      ok ""
      ok "Tests RECOVERED (failing -> passing). That fix is a lesson worth keeping:"
      info "  harness learn --title \"...\" --fix \"what made it pass\" --evidence \"$*\""
      [ -s "$failfile" ] && info "  (prior failure saved in .harness/last-failure.txt)"
    else
      ok "Tests pass."
    fi
    printf 'pass\n' > "$state"
  fi
  rm -f "$tmp"
  return "$rc"
}

# ---------------------------------------------------------------------------
# reflect — summarize the session and write a proposal (suggest, not apply).
# ---------------------------------------------------------------------------
cmd_reflect() {
  need_root; load_config; ensure_db
  local sid; sid="$(session_id)"
  local slog="$SESSIONS_DIR/$sid.tsv"
  local learned failures recoveries
  learned="$(db "SELECT COUNT(*) FROM learnings WHERE session='$(sql_quote "$sid")';" 2>/dev/null || echo 0)"
  failures=0; recoveries=0
  if [ -f "$slog" ]; then
    failures="$(awk -F"$TAB" '$2=="failure"{c++} END{print c+0}' "$slog" 2>/dev/null || echo 0)"
    recoveries="$(awk -F"$TAB" '$2=="recovery"{c++} END{print c+0}' "$slog" 2>/dev/null || echo 0)"
  fi

  if [ "${learned:-0}" -eq 0 ] && [ "${failures:-0}" -eq 0 ]; then
    info "Nothing to reflect on for session $sid."
    return 0
  fi

  local pid; pid="$(gen_id)"
  local pfile="$PROPOSALS_DIR/$pid.md"
  {
    echo "# Proposal $pid"
    echo "_session $sid · $(now_iso)_"
    echo
    echo "## Session signals"
    echo "- new learnings: $learned"
    echo "- failures observed: $failures"
    echo "- recoveries (failing -> passing): $recoveries"
    echo
    echo "## Suggested rule additions for ${AGENTS_FILE}"
    echo "_Review and edit, then approve with: harness apply ${pid}_"
    echo
    db -separator "$TAB" "SELECT CASE WHEN problem<>'' THEN problem ELSE title END, fix
         FROM learnings WHERE session='$(sql_quote "$sid")';" 2>/dev/null \
      | awk -F"$TAB" 'length($0)>0 {printf "- When %s, %s.\n", $1, $2}' || true
  } > "$pfile"
  ok "Wrote proposal: $pfile"
  info "Review with: harness review    Apply with: harness apply $pid"
}

# ---------------------------------------------------------------------------
# review — list pending proposals.
# ---------------------------------------------------------------------------
cmd_review() {
  need_root
  local found=0
  for f in "$PROPOSALS_DIR"/*.md; do
    [ -e "$f" ] || continue
    found=1
    say "${C_BOLD}-- $(basename "$f" .md) --${C_RST}"
    cat "$f"; echo
  done
  if [ "$found" -eq 0 ]; then info "No pending proposals."; fi
}

# ---------------------------------------------------------------------------
# apply — append an approved proposal to AGENTS.md, git-committed for rollback.
# ---------------------------------------------------------------------------
cmd_apply() {
  need_root; load_config
  local pid="${1:-}"; [ -n "$pid" ] || die "apply: provide a proposal id"
  local pfile="$PROPOSALS_DIR/$pid.md"
  [ -f "$pfile" ] || die "apply: no such proposal: $pid"
  command -v git >/dev/null 2>&1 || die "apply: git is required for safe apply/rollback"
  ( cd "$REPO_ROOT" && git rev-parse --git-dir >/dev/null 2>&1 ) || die "apply: not a git repo"

  local before; before="$( cd "$REPO_ROOT" && git rev-parse HEAD 2>/dev/null || echo "" )"
  local agents="$REPO_ROOT/$AGENTS_FILE"
  {
    echo
    echo "<!-- harness:applied $pid -->"
    sed -n '/## Suggested rule additions/,$p' "$pfile" | sed '1,2d'
    echo "<!-- /harness:applied $pid -->"
  } >> "$agents"

  ( cd "$REPO_ROOT" \
    && git add "$AGENTS_FILE" \
    && git commit -q -m "harness: apply proposal $pid" -m "[harness/auto]" )
  local after; after="$( cd "$REPO_ROOT" && git rev-parse HEAD )"

  printf 'pid=%s\nbefore=%s\nafter=%s\nts=%s\n' \
    "$pid" "$before" "$after" "$(now_iso)" > "$APPLIED_DIR/$pid.env"
  mv "$pfile" "$PROPOSALS_DIR/.$pid.applied" 2>/dev/null || true
  ok "Applied proposal $pid (commit $after). Rollback: harness rollback"
}

# ---------------------------------------------------------------------------
# rollback — revert the most recent harness-applied commit.
# ---------------------------------------------------------------------------
cmd_rollback() {
  need_root
  command -v git >/dev/null 2>&1 || die "rollback: git is required"
  local latest; latest="$(ls -t "$APPLIED_DIR"/*.env 2>/dev/null | head -n1 || true)"
  [ -n "$latest" ] || die "rollback: nothing applied yet"
  # shellcheck disable=SC1090
  . "$latest"
  ( cd "$REPO_ROOT" && git revert --no-edit "$after" )
  rm -f "$latest"
  ok "Reverted harness apply $pid."
}

# ---------------------------------------------------------------------------
# doctor — environment + wiring checks.
# ---------------------------------------------------------------------------
cmd_doctor() {
  local issues=0
  command -v awk     >/dev/null 2>&1 && ok "awk present"     || { warn "awk missing"; issues=1; }
  command -v git     >/dev/null 2>&1 && ok "git present"     || { warn "git missing"; issues=1; }
  if command -v sqlite3 >/dev/null 2>&1; then
    if sqlite3 ":memory:" "CREATE VIRTUAL TABLE t USING fts5(x);" >/dev/null 2>&1; then
      ok "sqlite3 present (FTS5 enabled)"
    else
      warn "sqlite3 present but FTS5 missing — recall search will be degraded"; issues=1
    fi
  else
    warn "sqlite3 missing (ships with macOS; 'apt install sqlite3' on Linux)"; issues=1
  fi
  if [ -n "$HARNESS_DIR" ] && [ -d "$HARNESS_DIR" ]; then
    ok "harness initialized at $HARNESS_DIR"
  else
    warn "no .harness/ found — run: harness init"; issues=1
  fi
  if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/$AGENTS_FILE" ] && grep -q "harness:guidance" "$REPO_ROOT/$AGENTS_FILE" 2>/dev/null; then
    ok "agent guidance present in $AGENTS_FILE"
  else
    info "agent guidance not found in $AGENTS_FILE (re-run init to add)"
  fi
  if [ -f "${REPO_ROOT:-}/.cursor/hooks.json" ] && grep -q "harness-session-start" "${REPO_ROOT}/.cursor/hooks.json" 2>/dev/null; then
    ok "Cursor hooks wired (.cursor/hooks.json)"
  else
    info "Cursor hooks not wired — run: harness wire"
  fi
  if [ -f "${REPO_ROOT:-}/.cursor/rules/harness-enforce.mdc" ]; then
    ok "alwaysApply harness rule present"
  else
    info "alwaysApply rule missing — run: harness wire"
  fi
  if [ -f "${REPO_ROOT:-}/.claude/settings.json" ] && grep -q "harness-claude" "${REPO_ROOT}/.claude/settings.json" 2>/dev/null; then
    ok "Claude Code hooks wired (.claude/settings.json)"
  else
    info "Claude hooks not wired — run: harness wire"
  fi
  command -v python3 >/dev/null 2>&1 && ok "python3 present (hooks)" || { warn "python3 missing — hooks need it"; issues=1; }
  [ "$issues" -eq 0 ] && ok "All good." || warn "Some checks need attention."
}

# ---------------------------------------------------------------------------
# version / upgrade — self-update from HARNESS_REMOTE.
# ---------------------------------------------------------------------------
cmd_version() { printf 'harness %s\n' "$HARNESS_VERSION"; }

cmd_upgrade() {
  local self; self="$(resolve_self)"
  [ -w "$self" ] || die "upgrade: $self is not writable (try with sudo, or reinstall)"
  local tmp; tmp="$(mktemp)"
  info "Fetching latest from $HARNESS_REMOTE ..."
  fetch "$HARNESS_REMOTE" "$tmp" || die "upgrade: download failed"
  # Sanity-check the payload before overwriting ourselves.
  head -n1 "$tmp" | grep -q '^#!' || { rm -f "$tmp"; die "upgrade: downloaded file is not a script"; }
  grep -q 'HARNESS_VERSION=' "$tmp" || { rm -f "$tmp"; die "upgrade: downloaded file is not harness.sh"; }
  local new; new="$(awk -F'"' '/^HARNESS_VERSION=/{print $2; exit}' "$tmp")"
  if [ "$new" = "$HARNESS_VERSION" ]; then
    rm -f "$tmp"; ok "Already up to date (v$HARNESS_VERSION)."; return 0
  fi
  chmod +x "$tmp"; cat "$tmp" > "$self"; rm -f "$tmp"
  ok "Upgraded harness: v$HARNESS_VERSION -> v$new"
}

usage() {
  cat <<'EOF'
harness — self-improving harness for Cursor & Claude Code agents

Usage: harness <command> [args]

Lifecycle
  init                 Scaffold .harness/ and add agent guidance to AGENTS.md
  wire                 Install Cursor + Claude hooks and alwaysApply rule (enforcement)
  start                Print a small lesson index (run at session start)
  reflect              Summarize the session, write a proposal (suggest changes)

Coaching
  recall <topic>       Retrieve only the lessons relevant to a topic (FTS5 search)
  learn  --title T --fix F [--problem P] [--tags a,b] [--evidence E]
                       Record a mistake+fix (de-duped; reinforces if seen before)
  note   <message>     Log a freeform session event
  watch  -- <cmd>      Run a command; on failure, log a learning candidate
  eval   -- <cmd>      Run tests; auto-log failures, detect failing->passing recovery

Gardening
  review               List pending proposals
  apply  <id>          Append an approved proposal to AGENTS.md (git-committed)
  rollback             Revert the most recent harness apply

Utilities
  digest               Regenerate .harness/LEARNINGS.md
  doctor               Check environment and wiring

Maintenance
  upgrade              Update harness.sh in place from HARNESS_REMOTE
  version              Print the harness version
EOF
}

main() {
  local cmd="${1:-}"; [ $# -gt 0 ] && shift || true
  case "$cmd" in
    init)     cmd_init "$@";;
    wire)     cmd_wire "$@";;
    start)    cmd_start "$@";;
    recall)   cmd_recall "$@";;
    learn)    cmd_learn "$@";;
    note)     cmd_note "$@";;
    watch)    cmd_watch "$@";;
    eval)     cmd_eval "$@";;
    reflect)  cmd_reflect "$@";;
    review)   cmd_review "$@";;
    apply)    cmd_apply "$@";;
    rollback) cmd_rollback "$@";;
    digest)   cmd_digest "$@";;
    doctor)   cmd_doctor "$@";;
    upgrade)  cmd_upgrade "$@";;
    version|--version|-v) cmd_version "$@";;
    ""|-h|--help|help) usage;;
    *) die "unknown command '$cmd' (try: harness help)";;
  esac
}
main "$@"

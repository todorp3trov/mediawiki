#!/usr/bin/env bash
#
# bd-run.sh — headless-Claude driver loop for the beads issue tracker.
#
#   bd ready --json  →  risk-class gate  →  claude -p (implement)  →  verify  →  bd close
#
# This is the "option (b)" executor discussed for the TS/Node-engine epic: it keeps
# the bd dependency graph and the repo's verify gates IN the loop, which the
# GitHub-shaped OSS runners (OpenHands, Claude Code Action) would lose. beads ships
# the queue/context/templating; it does NOT ship an executor — this is that ~glue.
#
# It deliberately REFUSES to auto-implement decision-gated issues (spikes, the
# cutover MILESTONE gates, the incremental-counter story). Those are research /
# human-judgement work, not implement-and-merge, and are listed for a human.
#
# SAFETY: the implementing agent runs with --permission-mode acceptEdits by default,
# i.e. it edits files in the working tree WITHOUT prompting. It never pushes and
# never runs `git` mutating commands (the prompt forbids it); review the diff and
# push yourself. Run on a clean branch you can throw away.
#
# Usage:
#   scripts/bd-run.sh                 # implement the single next ready (non-gated) issue
#   scripts/bd-run.sh --all           # drain the ready queue, one issue at a time
#   scripts/bd-run.sh <id> [<id>...]  # implement specific issue(s) (still gated unless --force)
#   scripts/bd-run.sh --list          # show ready issues + the gate decision for each
#   scripts/bd-run.sh --dry-run ...   # print what would happen; spawn no agent, change no state
#
# Common flags:
#   --all                 drain the whole ready queue instead of just the first issue
#   --force               implement even a gated issue (you take responsibility)
#   --dry-run             no agent, no bd mutations — just show the plan
#   --list                list ready issues with gate decisions and exit
#   --close-unverified    close issues even when no verify command is configured
#   -h | --help           this help
#
# Environment overrides:
#   BD_RUN_MODEL          --model passed to claude (alias or full id). Default: claude's own default.
#   BD_RUN_PERMISSION     --permission-mode. Default: acceptEdits. (bypassPermissions also runs bash unattended.)
#   BD_RUN_MAX_TURNS      --max-turns cap for the agent. Default: 200.
#   BD_RUN_VERIFY_CMD     shell command that must exit 0 for an issue to be closed.
#                         Default: empty → issues are left in_progress for human review, NOT closed.
#                         e.g. export BD_RUN_VERIFY_CMD='composer phpunit:unit && npm run --silent jest'
#   BD_RUN_SKIP_LABELS    space-separated labels that force a skip. Default: "spike".
#   BD_RUN_SKIP_TITLE_RE  ERE matched against the title to force a skip.
#                         Default: 'SPIKE|decision-gated|Cutover: MILESTONE'
#   BD_RUN_SKIP_IDS       space-separated explicit issue ids to always skip.
#   BD_RUN_CLAUDE_BIN     path to the claude binary. Default: claude on PATH.
#   BD_RUN_LOG_DIR        where per-run logs go. Default: .bd-run-logs (gitignored advised).
#
set -euo pipefail

# ---- config (env-overridable) ----------------------------------------------
MODEL="${BD_RUN_MODEL:-}"
PERMISSION="${BD_RUN_PERMISSION:-acceptEdits}"
MAX_TURNS="${BD_RUN_MAX_TURNS:-200}"
VERIFY_CMD="${BD_RUN_VERIFY_CMD:-}"
SKIP_LABELS="${BD_RUN_SKIP_LABELS:-spike}"
SKIP_TITLE_RE="${BD_RUN_SKIP_TITLE_RE:-SPIKE|decision-gated|Cutover: MILESTONE}"
SKIP_IDS="${BD_RUN_SKIP_IDS:-}"
CLAUDE_BIN="${BD_RUN_CLAUDE_BIN:-claude}"
LOG_DIR="${BD_RUN_LOG_DIR:-.bd-run-logs}"

# ---- arg parsing -----------------------------------------------------------
MODE="single"      # single | all | ids | list
FORCE=0
DRY_RUN=0
CLOSE_UNVERIFIED=0
IDS=()

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#$//' | sed '$d'; }

while [[ $# -gt 0 ]]; do
	case "$1" in
		--all)              MODE="all" ;;
		--list)             MODE="list" ;;
		--force)            FORCE=1 ;;
		--dry-run)          DRY_RUN=1 ;;
		--close-unverified) CLOSE_UNVERIFIED=1 ;;
		-h|--help)          usage; exit 0 ;;
		--*)                echo "bd-run: unknown flag: $1" >&2; exit 2 ;;
		*)                  MODE="ids"; IDS+=("$1") ;;
	esac
	shift
done

# ---- preflight -------------------------------------------------------------
for bin in bd jq "$CLAUDE_BIN"; do
	command -v "$bin" >/dev/null 2>&1 || { echo "bd-run: required tool not found: $bin" >&2; exit 1; }
done

c_red()   { printf '\033[31m%s\033[0m' "$1"; }
c_grn()   { printf '\033[32m%s\033[0m' "$1"; }
c_yel()   { printf '\033[33m%s\033[0m' "$1"; }
c_dim()   { printf '\033[2m%s\033[0m'  "$1"; }
log()     { printf '%s\n' "$*"; }

# ---- gate: should this issue be implemented by an agent? -------------------
# Echoes a human-readable skip reason on stdout if gated, nothing if clear.
gate_reason() {
	local id="$1" title="$2" labels_json="$3"
	for sid in $SKIP_IDS; do
		[[ "$id" == "$sid" ]] && { echo "explicit BD_RUN_SKIP_IDS"; return; }
	done
	for lbl in $SKIP_LABELS; do
		if jq -e --arg l "$lbl" 'index($l) != null' <<<"$labels_json" >/dev/null 2>&1; then
			echo "label '$lbl'"; return
		fi
	done
	if [[ -n "$SKIP_TITLE_RE" ]] && grep -Eq "$SKIP_TITLE_RE" <<<"$title"; then
		echo "title matches /$SKIP_TITLE_RE/"; return
	fi
}

# ---- build the implementation prompt from the issue's bd fields ------------
build_prompt() {
	# $1 = issue json object
	local j="$1"
	jq -r '
		"You are implementing a single issue from the beads (bd) tracker for this repository.\n" +
		"Work ONLY within the scope below. Read the repo'\''s CLAUDE.md and the nearest AGENTS.md\n" +
		"before editing, and follow its conventions (DI, hooks, DB query builders, i18n, tabs).\n\n" +
		"=== ISSUE " + .id + " ===\n" +
		"Title: " + .title + "\n\n" +
		"Description / scope (IN / OUT):\n" + (.description // "(none)") + "\n\n" +
		"Design notes (code-verified):\n" + (.design // "(none)") + "\n\n" +
		"Acceptance criteria:\n" + (.acceptance_criteria // "(none)") + "\n\n" +
		"Implementation notes / tests:\n" + (.notes // "(none)") + "\n\n" +
		"=== RULES ===\n" +
		"1. Implement the IN scope; respect every OUT exclusion — do not widen the slice.\n" +
		"2. Write the tests named in the notes/acceptance criteria. Make them pass.\n" +
		"3. Match surrounding code style; regenerate anything generated (autoload, schema) if you touch its inputs.\n" +
		"4. Do NOT run any mutating git command (no add/commit/push/checkout/reset). Leave changes in the working tree.\n" +
		"5. Do NOT close, claim, or modify the bd issue — the driver loop owns issue state.\n" +
		"6. If the scope is actually a spike/research/decision task rather than implementable code,\n" +
		"   STOP and say so plainly instead of guessing — do not fabricate an implementation.\n" +
		"7. End your final message with exactly one line: either\n" +
		"     BD_RESULT: done — <one-line summary of what you implemented>\n" +
		"   or\n" +
		"     BD_RESULT: blocked — <one-line reason>\n"
	' <<<"$j"
}

# ---- run one issue end-to-end ----------------------------------------------
run_issue() {
	local id="$1"
	local j title labels reason
	j="$(bd show "$id" --json 2>/dev/null | jq -c '.[0] // empty')"
	if [[ -z "$j" ]]; then
		log "$(c_red "✗ $id") — not found"; return 1
	fi
	title="$(jq -r '.title' <<<"$j")"
	labels="$(jq -c '.labels // []' <<<"$j")"
	reason="$(gate_reason "$id" "$title" "$labels")"

	if [[ -n "$reason" && $FORCE -eq 0 ]]; then
		log "$(c_yel "⏭ skip   $id") $(c_dim "[gated: $reason]") $title"
		log "         $(c_dim "decision-gated — left for a human. Use --force to override.")"
		return 0
	fi
	[[ -n "$reason" && $FORCE -eq 1 ]] && log "$(c_yel "⚠ forcing gated issue $id [$reason]")"

	log "$(c_grn "▶ $id") $title"

	if [[ $DRY_RUN -eq 1 ]]; then
		log "         $(c_dim "[dry-run] would: claim → claude -p (model=${MODEL:-default}, perm=$PERMISSION) → verify → close")"
		return 0
	fi

	mkdir -p "$LOG_DIR"
	local stamp logfile prompt
	stamp="$(date +%Y%m%d-%H%M%S)"
	logfile="$LOG_DIR/${id}-${stamp}.log"
	prompt="$(build_prompt "$j")"

	bd update "$id" --claim >/dev/null 2>&1 || true

	# Spawn the implementing agent headlessly; prompt via stdin to dodge ARG_MAX/escaping.
	local claude_args=( -p --permission-mode "$PERMISSION" --max-turns "$MAX_TURNS" )
	[[ -n "$MODEL" ]] && claude_args+=( --model "$MODEL" )
	log "         $(c_dim "agent running… (log: $logfile)")"
	set +e
	printf '%s' "$prompt" | "$CLAUDE_BIN" "${claude_args[@]}" >"$logfile" 2>&1
	local agent_rc=$?
	set -e

	if [[ $agent_rc -ne 0 ]]; then
		log "         $(c_red "agent exited $agent_rc") — left in_progress, see $logfile"
		bd update "$id" --notes "bd-run: agent failed (exit $agent_rc) at $stamp; see $logfile" >/dev/null 2>&1 || true
		return 1
	fi
	if grep -q '^BD_RESULT: blocked' "$logfile"; then
		local why; why="$(grep -m1 '^BD_RESULT: blocked' "$logfile")"
		log "         $(c_yel "agent reported blocked") — left in_progress"
		log "         $(c_dim "$why")"
		bd update "$id" --notes "bd-run: $why ($stamp); see $logfile" >/dev/null 2>&1 || true
		return 1
	fi

	# ---- verify gate ----
	if [[ -n "$VERIFY_CMD" ]]; then
		log "         $(c_dim "verifying: $VERIFY_CMD")"
		set +e
		( eval "$VERIFY_CMD" ) >>"$logfile" 2>&1
		local verify_rc=$?
		set -e
		if [[ $verify_rc -ne 0 ]]; then
			log "         $(c_red "verify failed (exit $verify_rc)") — left in_progress, see $logfile"
			bd update "$id" --notes "bd-run: verify failed (exit $verify_rc) at $stamp; see $logfile" >/dev/null 2>&1 || true
			return 1
		fi
		log "         $(c_grn "verify passed") → closing"
		bd close "$id" --reason "bd-run: implemented + verified ($stamp)" >/dev/null 2>&1 || true
		return 0
	fi

	# No verify command configured.
	if [[ $CLOSE_UNVERIFIED -eq 1 ]]; then
		log "         $(c_yel "no verify cmd; --close-unverified set") → closing"
		bd close "$id" --reason "bd-run: implemented, UNVERIFIED ($stamp)" >/dev/null 2>&1 || true
		return 0
	fi
	log "         $(c_yel "implemented, NOT verified") — left in_progress for human review"
	log "         $(c_dim "set BD_RUN_VERIFY_CMD to auto-close, or --close-unverified to skip the gate")"
	bd update "$id" --notes "bd-run: implemented but unverified ($stamp); needs human review; see $logfile" >/dev/null 2>&1 || true
	return 0
}

# ---- modes -----------------------------------------------------------------
ready_ids() { bd ready --json 2>/dev/null | jq -r '.[] | select(.issue_type != "epic") | .id'; }

case "$MODE" in
	list)
		printf '%-12s %-9s %s\n' "ID" "GATE" "TITLE"
		bd ready --json 2>/dev/null | jq -c '.[] | select(.issue_type != "epic")' | while read -r j; do
			id="$(jq -r '.id' <<<"$j")"; title="$(jq -r '.title' <<<"$j")"
			labels="$(jq -c '.labels // []' <<<"$j")"
			reason="$(gate_reason "$id" "$title" "$labels")"
			if [[ -n "$reason" ]]; then
				printf '%-12s %s %s %s\n' "$id" "$(c_yel "SKIP   ")" "$title" "$(c_dim "[$reason]")"
			else
				printf '%-12s %s %s\n' "$id" "$(c_grn "READY  ")" "$title"
			fi
		done
		;;
	ids)
		rc=0
		for id in "${IDS[@]}"; do run_issue "$id" || rc=1; done
		exit $rc
		;;
	single)
		first="$(ready_ids | head -n1)"
		[[ -z "$first" ]] && { log "bd-run: no ready issues."; exit 0; }
		run_issue "$first"
		;;
	all)
		# Re-query each pass: closing an issue may unblock new ready work.
		processed=""
		while true; do
			next=""
			while read -r id; do
				[[ -z "$id" ]] && continue
				case " $processed " in *" $id "*) continue ;; esac
				next="$id"; break
			done < <(ready_ids)
			[[ -z "$next" ]] && break
			processed="$processed $next"
			run_issue "$next" || true
		done
		log "$(c_dim "bd-run: ready queue drained.")"
		;;
esac

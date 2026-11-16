#!/usr/bin/env bash
# ops-notify.sh <project> <kind> <title> [body]
#
# One sender for every ops message.
# Never fails the caller: always exits 0; problems go to notify.log.
#
#   project  a key from topics.env, whose rows are "name: <thread id | general> <emoji>"
#   kind     deploy_ok | deploy_fail | error | warn | recovered | start |
#            server | disk | ram | site | cert | backup_ok | backup_fail | pulse
#   title    main line (deploy_ok: commit subject; deploy_fail: failed step;
#            error: "Class: short message"; backup_ok: size; ...)
#   body     optional second line / context (shown in italics for error/warn)
#
# Optional environment:
#   OPS_SHA        commit sha (shortened to 7)       -> deploy_ok / deploy_fail
#   OPS_RUN_URL    link to the CI run                -> deploy_fail
#   OPS_THREAD     override the topic (number or "general")
#   OPS_PREVIEW=1  prefix the message with "🧪 ПРЕВЬЮ"
#   OPS_SILENT=1   force a silent message (routine kinds are silent anyway)
#   OPS_DRYRUN=1   print the message instead of sending (no token needed)
#   OPS_TEST=1     really send (silently, into the project's real topic), wait
#                  OPS_TEST_TTL seconds (8), then deleteMessage it. The message id is
#                  kept in memory only. Exit code 3 if the send or the delete failed.
#   OPS_TOPICS_FILE, OPS_MONITOR_ENV, OPS_LOG_DIR  path overrides (tests)
#
# Secrets: TG_LOG_BOT_TOKEN / TG_LOG_CHAT_ID come from the environment, or are
# READ (not sourced) from an env file. The token goes to curl through `-K -` on
# stdin, so it never appears in argv / `ps` and never in the log.

: "${OPS_LOCALE:=C.UTF-8}"
export LC_ALL="$OPS_LOCALE"

OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPICS_FILE="${OPS_TOPICS_FILE:-$OPS_DIR/topics.env}"
MONITOR_ENV="${OPS_MONITOR_ENV:-$HOME/heylark/monitor.env}"
LOG_DIR="${OPS_LOG_DIR:-$HOME/heylark/ops}"
LOG="$LOG_DIR/notify.log"
LOG_MAX_BYTES=262144   # rotate at 256 KiB, keep notify.log.1 .. .3
MAX_TITLE=1200
MAX_BODY=2000          # title+body+template stay well under Telegram's 4096

rotate_log() {
  local size
  [ -f "$LOG" ] || return 0
  size=$({ wc -c < "$LOG"; } 2>/dev/null | tr -d ' ')
  [ "${size:-0}" -gt "$LOG_MAX_BYTES" ] || return 0
  mv -f "$LOG.2" "$LOG.3" 2>/dev/null
  mv -f "$LOG.1" "$LOG.2" 2>/dev/null
  mv -f "$LOG" "$LOG.1" 2>/dev/null
}

log() {
  [ -n "${OPS_DRYRUN:-}" ] && return 0     # a dry run leaves no trace
  mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  rotate_log
  { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; } 2>/dev/null
  return 0
}

# --- text helpers -----------------------------------------------------------
esc() { # HTML-escape (sed, not ${//}: bash 5.2 treats & in replacements specially)
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

trunc() { # trunc <escaped text> <max chars>; never leaves half an HTML entity
  local s="$1" n="$2"
  if [ "${#s}" -gt "$n" ]; then
    s="${s:0:$n}"
    s=$(printf '%s' "$s" | sed -E 's/&[a-z#0-9]{0,6}$//')
    s="${s}…"
  fi
  printf '%s' "$s"
}

field() { # field <escaped> <max>  -> escape + truncate in the right order
  trunc "$(esc "$1")" "$2"
}

env_value() { # env_value NAME -> value of NAME from the env file (parsed, never executed)
  grep -E "^[[:space:]]*(export[[:space:]]+)?$1=" "$MONITOR_ENV" 2>/dev/null | tail -1 \
    | sed -E "s/^[^=]*=//; s/^[\"']//; s/[\"']\$//"
}

topic_row() { # topic_row <name> -> "<thread> <emoji>" or empty
  awk -v p="$1" '{ sub(/#.*/, "") } $1 == p ":" { print $2, $3; exit }' "$TOPICS_FILE" 2>/dev/null
}

# --- args -------------------------------------------------------------------
if [ "$#" -lt 3 ]; then
  echo "usage: ops-notify.sh <project> <kind> <title> [body]" >&2
  log "bad-usage argc=$#"
  exit 0
fi
PROJECT="$1"; KIND="$2"; TITLE_RAW="$3"; BODY_RAW="${4:-}"

# --- kind table -------------------------------------------------------------
SILENT=0
case "$KIND" in
  deploy_ok)    KE="✅"; WORD="deployed"; SILENT=1 ;;
  deploy_fail)  KE="❌"; WORD="deploy failed" ;;
  error)        KE="🔴"; WORD="error" ;;
  warn)         KE="🟠"; WORD="warning" ;;
  recovered)    KE="🟢"; WORD="recovered"; SILENT=1 ;;
  start)        KE="🚀"; WORD="started"; SILENT=1 ;;
  server)       KE="🖥"; WORD="server" ;;
  disk)         KE="💽"; WORD="disk" ;;
  ram)          KE="🧠"; WORD="RAM" ;;
  site)         KE="🌐"; WORD="site" ;;
  cert)         KE="🔐"; WORD="certificate" ;;
  backup_ok)    KE="💾"; WORD="backup ok"; SILENT=1 ;;
  backup_fail)  KE="🔴"; WORD="backup failed" ;;
  pulse)        KE="💓"; WORD="pulse"; SILENT=1 ;;
  *)            KE="🟠"; WORD="$KIND"; log "unknown-kind project=$PROJECT kind=$KIND" ;;
esac
[ -n "${OPS_SILENT:-}" ] && SILENT=1
[ -n "${OPS_TEST:-}" ] && SILENT=1      # a test message never makes a sound

# --- routing ----------------------------------------------------------------
ROW="$(topic_row "$PROJECT")"
if [ -z "$ROW" ] && [ -z "${OPS_TOPIC:-}" ]; then
  log "unknown-project project=$PROJECT (routed to server)"
  ROW="$(topic_row server)"
fi
THREAD="${ROW%% *}"
PEMOJI="$(printf '%s' "$ROW" | awk '{print $2}')"
# OPS_TOPIC=<topics.env key>: keep the project's label/emoji but post into another
# topic.
if [ -n "${OPS_TOPIC:-}" ]; then
  TROW="$(topic_row "$OPS_TOPIC")"
  if [ -n "$TROW" ]; then THREAD="${TROW%% *}"; else log "unknown-topic OPS_TOPIC=$OPS_TOPIC"; fi
fi
[ -n "${OPS_THREAD:-}" ] && THREAD="$OPS_THREAD"
case "$THREAD" in ''|*[!0-9]*) THREAD="" ;; esac   # "general"/anything else: omit the field

LABEL="$(esc "$PROJECT")"
if [ -n "$PEMOJI" ] && [ "$PROJECT" != "server" ]; then LABEL="$PEMOJI $LABEL"; fi
LABEL="<b>$LABEL</b>"

TITLE="$(field "$TITLE_RAW" "$MAX_TITLE")"
BODY="$(field "$BODY_RAW" "$MAX_BODY")"
SHA="$(printf '%s' "${OPS_SHA:-}" | cut -c1-7)"
SHA="$(esc "$SHA")"

# --- message ----------------------------------------------------------------
NL=$'\n'
case "$KIND" in
  deploy_ok)
    MSG="$KE $LABEL deployed"
    [ -n "$TITLE" ] && MSG+="$NL$TITLE"
    [ -n "$SHA" ] && MSG+="$NL<code>$SHA</code>"
    [ -n "$BODY" ] && MSG+="$NL$BODY"
    ;;
  deploy_fail)
    MSG="$KE $LABEL deploy failed"
    STEP="шаг: ${TITLE:-?}"
    [ -n "$SHA" ] && STEP+=" · <code>$SHA</code>"
    MSG+="$NL$STEP"
    if [ -n "${OPS_RUN_URL:-}" ]; then
      URL="$(printf '%s' "$OPS_RUN_URL" | sed -e 's/&/\&amp;/g' -e 's/"/%22/g' -e 's/</%3C/g' -e 's/>/%3E/g')"
      MSG+="$NL<a href=\"$URL\">открыть run</a>"
    fi
    [ -n "$BODY" ] && MSG+="$NL<i>$BODY</i>"
    ;;
  backup_ok)
    MSG="$KE backup ok: $LABEL"
    [ -n "$TITLE" ] && MSG+=" · $TITLE"
    [ -n "$BODY" ] && MSG+="$NL$BODY"
    ;;
  backup_fail)
    MSG="$KE backup failed: $LABEL"
    [ -n "$TITLE" ] && MSG+="$NL<i>$TITLE</i>"
    [ -n "$BODY" ] && MSG+="$NL$BODY"
    ;;
  error|warn|recovered)
    MSG="$KE $LABEL · $WORD"
    [ -n "$TITLE" ] && MSG+="$NL$TITLE"
    [ -n "$BODY" ] && MSG+="$NL<i>$BODY</i>"
    ;;
  *)
    MSG="$KE $LABEL · $WORD"
    [ -n "$TITLE" ] && MSG+="$NL$TITLE"
    [ -n "$BODY" ] && MSG+="$NL$BODY"
    ;;
esac
if [ -n "${OPS_PREVIEW:-}" ]; then
  MSG="🧪 <b>ПРЕВЬЮ</b>$NL$MSG"
fi
# final guard on the assembled text (tags are ours and short; cut after a newline)
if [ "${#MSG}" -gt 3500 ]; then MSG="${MSG:0:3490}…"; fi

# --- dry run ----------------------------------------------------------------
if [ -n "${OPS_DRYRUN:-}" ]; then
  printf 'DRYRUN thread=%s silent=%s chars=%s\n%s\n' "${THREAD:-general(omitted)}" "$SILENT" "${#MSG}" "$MSG"
  exit 0
fi

# --- send -------------------------------------------------------------------
# env wins (GitHub Actions passes repo secrets this way); otherwise both are
# read from the env file.
TOKEN="${TG_LOG_BOT_TOKEN:-$(env_value TG_LOG_BOT_TOKEN)}"
CHAT="${TG_LOG_CHAT_ID:-$(env_value TG_LOG_CHAT_ID)}"
if [ -z "$TOKEN" ] || [ -z "$CHAT" ]; then
  log "skip project=$PROJECT kind=$KIND reason=no-token-or-chat-in-monitor.env"
  exit 0
fi

TMP="$(mktemp 2>/dev/null)" || { log "skip project=$PROJECT kind=$KIND reason=mktemp-failed"; exit 0; }
trap 'rm -f "$TMP"' EXIT

ARGS=(-sS -m 15 -K - -o "$TMP" -w '%{http_code}'
      -d "chat_id=$CHAT" -d "parse_mode=HTML" -d "disable_web_page_preview=true"
      --data-urlencode "text=$MSG")
[ -n "$THREAD" ] && ARGS+=(-d "message_thread_id=$THREAD")
[ "$SILENT" = 1 ] && ARGS+=(-d "disable_notification=true")

attempt() {
  # token reaches curl via stdin config only
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TOKEN" | curl "${ARGS[@]}" 2>/dev/null
}

CODE="$(attempt)"; CODE="${CODE:-000}"
if [ "$CODE" = 429 ] || [ "${CODE#5}" != "$CODE" ] || [ "$CODE" = 000 ]; then
  WAIT="$(grep -oE '"retry_after":[0-9]+' "$TMP" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
  WAIT="${WAIT:-2}"; [ "$WAIT" -gt 10 ] && WAIT=10
  sleep "$WAIT"
  CODE="$(attempt)"; CODE="${CODE:-000}"
fi

RC=0
if [ "$CODE" = 200 ] && grep -q '"ok":true' "$TMP" 2>/dev/null; then
  log "ok project=$PROJECT kind=$KIND thread=${THREAD:-general} http=$CODE"
  if [ -n "${OPS_TEST:-}" ]; then
    # Test mode: the message_id lives only in this variable (never logged, never written to
    # disk); after OPS_TEST_TTL seconds the message is deleted again, so tests leave no litter.
    MID="$(grep -oE '"message_id":[0-9]+' "$TMP" | head -1 | grep -oE '[0-9]+')"
    TTL="${OPS_TEST_TTL:-8}"
    printf 'OPS_TEST: sent to thread=%s silent=1; text:\n%s\n' "${THREAD:-general(omitted)}" "$MSG"
    sleep "$TTL"
    DEL="$(mktemp 2>/dev/null)"
    DCODE="$(printf 'url = "https://api.telegram.org/bot%s/deleteMessage"\n' "$TOKEN" \
             | curl -sS -m 15 -K - -o "$DEL" -w '%{http_code}' -d "chat_id=$CHAT" -d "message_id=$MID" 2>/dev/null)"
    if [ -n "$MID" ] && [ "${DCODE:-000}" = 200 ] && grep -q '"ok":true' "$DEL" 2>/dev/null; then
      echo "OPS_TEST: deleted after ${TTL}s: ok"; log "test-deleted project=$PROJECT kind=$KIND thread=${THREAD:-general}"
    else
      echo "OPS_TEST: DELETE FAILED (http=${DCODE:-000}): the message is still in thread ${THREAD:-general}" >&2
      log "FAIL test-delete project=$PROJECT kind=$KIND thread=${THREAD:-general} http=${DCODE:-000}"; RC=3
    fi
    rm -f "$DEL"
  fi
else
  DESC="$(grep -oE '"description":"[^"]*"' "$TMP" 2>/dev/null | head -1 | cut -c1-160)"
  log "FAIL project=$PROJECT kind=$KIND thread=${THREAD:-general} http=$CODE ${DESC}"
  [ -n "${OPS_TEST:-}" ] && { echo "OPS_TEST: SEND FAILED http=$CODE ${DESC}" >&2; RC=3; }
fi
# production callers always get 0 (never break a deploy); only OPS_TEST reports failures
exit "$RC"

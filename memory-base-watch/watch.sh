#!/usr/bin/env bash
# Posts an urgent YUI signal when a memory_base_* container dies with a failure exit code
# or turns unhealthy. Logs are not watched: these containers log almost no errors
# (measured 2026-10-23, 7 days: 0/1/9 lines), container state is the signal.
# A die with exit 0 or 143 (SIGTERM: docker stop, compose up/down, docker restart) is a
# deliberate stop and is skipped; a crash restarted by a restart policy still shows its die.
# YUI_SIGNALS_URL reaches the Mac through the reverse tunnel 15001 -> 8770.
set -u
URL=${YUI_SIGNALS_URL:-http://127.0.0.1:15001/signals}
HOST=$(hostname)

docker events --filter type=container --format "{{json .}}" | while read -r ev; do
  name=$(jq -r ".Actor.Attributes.name // empty" <<<"$ev")
  [[ $name == memory_base_* ]] || continue
  status=$(jq -r ".status // .Action" <<<"$ev")
  code=$(jq -r ".Actor.Attributes.exitCode // empty" <<<"$ev")
  case $status in
    die) [[ $code == 0 || $code == 143 ]] && continue; what="died with exit code $code" ;;
    "health_status: unhealthy") what="turned unhealthy" ;;
    *) continue ;;
  esac
  ms=$(( $(jq -r ".timeNano" <<<"$ev") / 1000000 ))
  body=$(jq -nc --arg c "$name" --arg w "$what" --arg s "$status" --arg x "$code" --arg h "$HOST" --argjson ms "$ms" \
    "{signals: [{source: \"docker_container\", host: \$h, container: \$c, event: \$s, exit_code: \$x, summary: (\$c + \" \" + \$w)}],
      envelope: {source: \"dev43-docker\", event_type: \"container_failure\", delivery: \"urgent\",
                 event_id: (\$c + \":\" + \$s + \":\" + (\$ms|tostring)), label: (\$h + \" · \" + \$c), occurred_at: \$ms}}")
  # ponytail: no retry; a failed POST (YUI closed) is only logged. Add a queue if a missed one ever matters.
  if curl -sf -m 10 -H "Content-Type: application/json" -d "$body" "$URL" >/dev/null; then
    echo "sent: $name $what"
  else
    echo "post failed: $name $what"
  fi
done

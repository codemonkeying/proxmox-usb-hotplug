#!/bin/bash
# vm-event-handler <event> <state>
# Installed INSIDE the guest. Invoked by the host event-relay via the qemu guest
# agent (runs as root). Finds the BUILT-IN panel dynamically (never a pinned
# connector name) and toggles it: lid closed -> built-in off; open -> built-in on.
#
# Built-in detection (robust to display changes / connector renumbering):
#   X11 + NVIDIA : the connected output whose `ConnectorType:` is `Panel`
#                  (xrandr --verbose) — the "built-in screen".
#   Wayland      : the connected output named eDP* (kscreen-doctor / wlr-randr).
# If no built-in panel is connected, it does NOTHING (safe — never touches externals).
LOG=/var/log/vm-event-handler.log
exec >>"$LOG" 2>&1
event="${1:-}"; state="${2:-}"
echo "[$(date '+%F %T')] event='$event' state='$state'"
[ "$event" = "lid" ] || { echo "  ignored (not lid)"; exit 0; }
want=off; [ "$state" = "open" ] && want=on

# Active graphical session on seat0 (user + type).
suid=""; suser=""; stype=""
for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
  info="$(loginctl show-session "$s" -p Active -p Seat -p Type -p User -p Name 2>/dev/null)"
  [ "$(sed -n 's/^Active=//p' <<<"$info")" = "yes" ]   || continue
  [ "$(sed -n 's/^Seat=//p'   <<<"$info")" = "seat0" ]  || continue
  stype="$(sed -n 's/^Type=//p' <<<"$info")"; suid="$(sed -n 's/^User=//p' <<<"$info")"; suser="$(sed -n 's/^Name=//p' <<<"$info")"
  break
done
[ -z "$suid" ] && { echo "  no active seat0 session — not firing"; exit 0; }
rt="/run/user/$suid"
echo "  session: user=$suser uid=$suid type=$stype want=$want"
as_user(){ sudo -u "$suser" env XDG_RUNTIME_DIR="$rt" "$@"; }

if [ "$stype" = "wayland" ]; then
  panel=""
  if command -v kscreen-doctor >/dev/null 2>&1; then
    panel="$(as_user WAYLAND_DISPLAY=wayland-0 kscreen-doctor -o 2>/dev/null | grep -oiE 'eDP[-0-9]*' | head -1)"
    if [ -n "$panel" ]; then
      echo "  wayland/kde built-in: $panel -> $want"
      [ "$want" = off ] && as_user WAYLAND_DISPLAY=wayland-0 kscreen-doctor "output.$panel.disable" \
                        || as_user WAYLAND_DISPLAY=wayland-0 kscreen-doctor "output.$panel.enable"
      echo "  done (rc=$?)"; exit 0
    fi
  fi
  echo "  wayland: no connected built-in (eDP*) — not firing"; exit 0
fi

# X11 (NVIDIA): built-in = connected output with ConnectorType: Panel.
panel="$(as_user DISPLAY=:0 xrandr --verbose 2>/dev/null | awk '
  /^[A-Za-z0-9_-]+ (connected|disconnected)/ { out=$1; st=$2 }
  /ConnectorType:/ { if (out!="" && st=="connected" && !(out in seen)) { seen[out]=1; ctype[out]=$2 } }
  END { for (o in ctype) if (ctype[o]=="Panel") { print o; break } }
')"
if [ -z "$panel" ]; then echo "  x11: no connected built-in (ConnectorType: Panel) — not firing"; exit 0; fi

if [ "$want" = off ]; then
  echo "  x11 built-in: $panel -> off"
  as_user DISPLAY=:0 xrandr --output "$panel" --off
else
  # On open, EXTEND the panel below a connected external (not mirror) — bare
  # --auto mirrors at 0+0 and, with mixed resolutions, KDE clips the external.
  # Anchor = first connected output whose ConnectorType is NOT Panel.
  ext="$(as_user DISPLAY=:0 xrandr --verbose 2>/dev/null | awk '
    /^[A-Za-z0-9_-]+ (connected|disconnected)/ { out=$1; st=$2 }
    /ConnectorType:/ { if (out!="" && st=="connected" && !(out in seen)) { seen[out]=1; ct[out]=$2 } }
    END { for (o in ct) if (ct[o]!="Panel") { print o; break } }
  ')"
  echo "  x11 built-in: $panel -> on (extend below external: ${ext:-none})"
  if [ -n "$ext" ]; then as_user DISPLAY=:0 xrandr --output "$panel" --auto --below "$ext"
  else                   as_user DISPLAY=:0 xrandr --output "$panel" --auto; fi
fi
echo "  done (rc=$?)"

#!/usr/bin/env bash
# Regenerates the README screenshots in docs/screenshots using Pulse's --demo mode
# (generated artwork, fictional track, no audio capture, user settings untouched).
#
#   ./scripts/build_app.sh && ./scripts/screenshots/capture.sh
#
# Notes: quits a running Pulse while capturing and relaunches it at the end. A generated
# wallpaper window briefly covers the top-right of the screen; the menu bar strip around the
# capsule is repainted with that wallpaper, so other apps' icons never appear in the images.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/dist/Pulse.app"
OUT="$ROOT/docs/screenshots"
TOOLS="$ROOT/.build/screenshot-tools"
WORK="$TOOLS/work"
mkdir -p "$OUT" "$TOOLS" "$WORK"

# Capture region (top-left screen coords) around the status item area.
RX=1700; RY=0; RW=700; RH=820
MENU_BAR=59   # menu bar height + its bottom hairline

for tool in backdrop compose list_windows make_gif; do
    if [[ ! -x "$TOOLS/$tool" || "$ROOT/scripts/screenshots/$tool.swift" -nt "$TOOLS/$tool" ]]; then
        swiftc -O "$ROOT/scripts/screenshots/$tool.swift" -o "$TOOLS/$tool"
    fi
done

settings() { # size background tintBars tintGlass style
    printf '{"equalizerStyle":"%s","onlyWhenMusicPlaying":true,"hidePillWhenStopped":false,"sensitivity":1.0,"pillSize":"%s","tintBarsWithArtwork":%s,"pillBackground":"%s","tintGlassWithArtwork":%s}' \
        "${5:-island}" "$1" "$3" "$2" "$4"
}

capsule_size() { # -> "w h" for a pill size
    case "$1" in
        compact) echo "64 24" ;;
        regular) echo "76 28" ;;
        large)   echo "90 32" ;;
    esac
}

quit_pulse() {
    pkill -x Pulse 2>/dev/null || true
    for _ in $(seq 50); do pgrep -x Pulse >/dev/null || return 0; sleep 0.1; done
    pkill -9 -x Pulse 2>/dev/null || true
    sleep 0.5
}

launch() { # args...
    quit_pulse
    local since; since="$(date '+%Y-%m-%d %H:%M:%S')"
    open "$APP" --args --demo "$@"
    for _ in $(seq 50); do pgrep -x Pulse >/dev/null && break; sleep 0.1; done
    sleep 2.5
    # Status item window frame logged by the app: "(x, yBottom, w, h)".
    ITEM_FRAME="$(/usr/bin/log show --start "$since" --style compact \
        --predicate 'subsystem == "dev.pulsebar.app"' 2>/dev/null \
        | grep 'status item frame' | tail -1 | sed -E 's/.*\(([^)]*)\).*/\1/' | tr -d ' ')"
    IFS=',' read -r ITEM_X _ ITEM_W ITEM_H <<<"$ITEM_FRAME"
    ITEM_X=${ITEM_X%.*}; ITEM_W=${ITEM_W%.*}; ITEM_H=${ITEM_H%.*}
}

capsule_rect() { # size -> sets CAP_X CAP_Y CAP_W CAP_H in capture coords
    read -r CAP_W CAP_H <<<"$(capsule_size "$1")"
    CAP_X=$(( ITEM_X - RX + (ITEM_W - CAP_W) / 2 ))
    CAP_Y=$(( (ITEM_H - CAP_H) / 2 ))
}

pill_shot() { # name size background tintBars tintGlass palette [style]
    local name=$1 size=$2
    launch --demo-still --demo-palette "$6" --demo-settings "$(settings "$size" "$3" "$4" "$5" "${7:-island}")"
    capsule_rect "$size"
    screencapture -x -R "$RX,$RY,$RW,$RH" "$WORK/$name.png"
    local cx=$(( CAP_X - 26 )) cw=$(( CAP_W + 52 ))
    "$TOOLS/compose" "$WORK/$name.png" "$WORK/wall.png" "$OUT/$name.png" \
        "$MENU_BAR" "$CAP_X" "$CAP_Y" "$CAP_W" "$CAP_H" "$cx" 6 "$cw" $(( ITEM_H - 12 )) 10
}

menu_shot() { # name expanded|collapsed palette
    "$TOOLS/backdrop" "$RX" "$RY" "$RW" "$RH" 12 "$WORK/wall.png" &
    local backdrop_pid=$!
    sleep 0.5
    launch --demo-still --demo-palette "$3" --demo-"$2" --show-menu \
        --demo-settings "$(settings regular glass true false)"
    capsule_rect regular
    local pid; pid="$(pgrep -x Pulse)"
    # Popover = the tall window owned by Pulse; wait until it has opened and settled.
    local px= py= pw= ph=
    for _ in $(seq 40); do
        read -r _ px py pw ph _ <<<"$("$TOOLS/list_windows" "$pid" | sort -k5 -n | tail -1)"
        [[ -n "${ph:-}" && "$ph" -ge 100 ]] && break
        sleep 0.2
    done
    sleep 1.0
    read -r _ px py pw ph _ <<<"$("$TOOLS/list_windows" "$pid" | sort -k5 -n | tail -1)"
    echo "  popover: x=$px y=$py w=$pw h=$ph" >&2
    if [[ -z "${ph:-}" || "$ph" -lt 100 ]]; then
        echo "menu did not open" >&2; exit 1
    fi
    screencapture -x -R "$RX,$RY,$RW,$RH" "$WORK/$1.png"
    wait "$backdrop_pid" 2>/dev/null || true
    local left=$(( px - RX - 44 )) width=$(( pw + 88 )) height=$(( py + ph + 44 ))
    "$TOOLS/compose" "$WORK/$1.png" "$WORK/wall.png" "$OUT/$1.png" \
        "$MENU_BAR" "$CAP_X" "$CAP_Y" "$CAP_W" "$CAP_H" "$left" 0 "$width" "$height" 18
}

pill_gif() { # name size palette frames
    launch --demo-palette "$3" --demo-settings "$(settings "$2" glass true false)"
    capsule_rect "$2"
    local cx=$(( CAP_X - 26 )) cw=$(( CAP_W + 52 ))
    local i
    for i in $(seq -w 1 "$4"); do
        screencapture -x -R "$RX,$RY,$RW,$(( ITEM_H + 2 ))" "$WORK/gif_$i.png"
        sleep 0.03
    done
    for i in $(seq -w 1 "$4"); do
        "$TOOLS/compose" "$WORK/gif_$i.png" "$WORK/wall.png" "$WORK/gif_c_$i.png" \
            "$MENU_BAR" "$CAP_X" "$CAP_Y" "$CAP_W" "$CAP_H" "$cx" 6 "$cw" $(( ITEM_H - 12 )) 10 >/dev/null
    done
    "$TOOLS/make_gif" "$OUT/$1.gif" 0.08 "$WORK"/gif_c_*.png
}

STEP="${1:-all}"

if [[ $STEP == all || $STEP == menus ]]; then
    echo "Menus..."
    menu_shot menu expanded 0          # also writes the wallpaper used below
    menu_shot menu-collapsed collapsed 1
fi

if [[ $STEP == all || $STEP == pills ]]; then
    echo "Sizes..."
    pill_shot size-s compact glass true false 0
    pill_shot size-m regular glass true false 0
    pill_shot size-l large glass true false 0

    echo "Backgrounds..."
    pill_shot bg-glass regular glass true false 1
    pill_shot bg-clear regular clearGlass true false 1
    pill_shot bg-dark regular solid true false 1

    echo "Colors..."
    pill_shot color-bars regular glass true false 2
    pill_shot color-both regular glass true true 0
    pill_shot color-off regular glass false false 1
fi

if [[ $STEP == all || $STEP == gif ]]; then
    echo "Animation..."
    pill_gif pulse large 0 36
fi

quit_pulse
open "$APP"
echo "Done: $OUT"

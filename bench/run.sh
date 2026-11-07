#!/bin/sh
# run.sh [util ...] - compare our utilities with the GNU originals using poop.
# See bench/README.md.
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
POOP=${POOP:-$root/../poop/zig-out/bin/poop}
WORK=${WORK:-${TMPDIR:-/tmp}/util-unix-bench}
DURATION=${DURATION:-1000}
OPT=${OPT:-ReleaseFast}
export LC_ALL=C

[ -x "$POOP" ] || { echo "poop not found at $POOP (set POOP=)" >&2; exit 2; }
mkdir -p "$WORK/raw" "$WORK/data" "$WORK/out"
(cd "$root" && zig build "-Doptimize=$OPT" --prefix "$WORK/ours") || exit 2
sh "$here/gen.sh" "$WORK/data" || exit 2
D=$WORK/data

subst() {
    printf '%s' "$1" | sed -e "s#@TEXT#$D/text.txt#g" -e "s#@CSV#$D/csv.txt#g" \
        -e "s#@SMALL#$D/small.txt#g" -e "s#@WORK#$WORK#g"
}

printf '| util | args | wall | cycles | instr | rss |\n|---|---|---|---|---|---|\n'
seen=" "
grep -v '^#' "$here/cases.txt" | while IFS='|' read -r util mode args; do
    if [ $# -gt 0 ]; then case " $* " in *" $util "*) ;; *) continue ;; esac; fi
    args=$(subst "$args")
    gnu=/usr/bin/$util; ours=$WORK/ours/bin/$util
    case $mode in
        f) c1="$gnu $args"; c2="$ours $args" ;;
        s) f=${args%% *}; rest=${args#"$f"}; c1="sh $here/stdin.sh $gnu $f$rest"; c2="sh $here/stdin.sh $ours $f$rest" ;;
        y) c1="sh $here/yes.sh $gnu"; c2="sh $here/yes.sh $ours" ;;
    esac
    out=$WORK/raw/$util-$(printf '%s' "$args" | tr -c 'A-Za-z0-9' '_' | cut -c1-40).txt
    "$POOP" -f -d "$DURATION" --color never "$c1" "$c2" < /dev/null > "$out" 2>&1
    rm -rf "$WORK/out"; mkdir -p "$WORK/out" # pieces from the case just run
    row=$(python3 "$here/summarize.py" < "$out")
    shown=$(printf '%s' "$args" | sed "s#$D/##g; s#$WORK/##g")
    printf '| %s | %s | %s |\n' "$util" "${shown:-(none)}" "$(printf '%s' "$row" | sed 's/\t/ | /g')"
done

printf '\nStripped binary sizes (bytes), ours / GNU:\n\n| util | ours | GNU | ratio |\n|---|---|---|---|\n'
grep -v '^#' "$here/cases.txt" | cut -d'|' -f1 | sort -u | while read -r util; do
    if [ $# -gt 0 ]; then case " $* " in *" $util "*) ;; *) continue ;; esac; fi
    o=$(stat -L -c %s "$WORK/ours/bin/$util"); g=$(stat -L -c %s "/usr/bin/$util")
    printf '| %s | %s | %s | %s |\n' "$util" "$o" "$g" "$(awk -v o="$o" -v g="$g" 'BEGIN { printf "%.2f", o / g }')"
done

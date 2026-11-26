#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# test_sh.sh - differential tests of `sh` against dash, bash --posix, bash as
# sh, busybox ash, yash and (subset B) FreeBSD sh. See shcmp.sh for the rules.
# Every snippet in the first section is POSIX (shellcheck -s dash clean of
# SC1xxx/SC3xxx; test_sh_lint.sh checks that). Deliberately non-POSIX or
# erroneous snippets live in the clearly marked EXEMPT section at the end.
UTIL="sh"
. "$(dirname "$0")/shcmp.sh"

# cx: like c, for cases that are deliberately erroneous or non-POSIX (syntax
# errors, operators POSIX does not define, odd-but-legal forms shellcheck
# flags). They are run like any case but excluded from the shellcheck hygiene
# check; test_sh_lint.sh lists them as exempt.
cx() { c "$@"; }
if [ -n "${SHCMP_DUMP:-}" ]; then
    SHCMP_N=0
    # tools/sh-gold.py reads the snippets from here; the .meta file has the
    # description, the flags and the note of the case (tab separated)
    c() { SHCMP_N=$((SHCMP_N + 1)); printf '%s\n' "$2" > "$SHCMP_DUMP/${SHCMP_EXEMPT:+x_}case$SHCMP_N.sh"; printf '%s\t%s\t%s\n' "$1" "${3:-}" "${4:-}" > "$SHCMP_DUMP/${SHCMP_EXEMPT:+x_}case$SHCMP_N.meta"; }
    cx() { SHCMP_N=$((SHCMP_N + 1)); printf '%s\n' "$2" > "$SHCMP_DUMP/x_case$SHCMP_N.sh"; printf '%s\t%s\t%s\n' "$1" "${3:-}" "${4:-}" > "$SHCMP_DUMP/x_case$SHCMP_N.meta"; }
fi

# ---- quoting ----
c "single quotes" "echo 'a  b \$x'" B
c "double quotes keep spaces" 'echo "a  b"' B
c "backslash outside quotes" 'echo a\ b\\c' B
c "backslash in double quotes" 'printf "%s\n" "a\$b\"c\\d\e"' B
c "backslash newline joins" 'echo a\
b' B
c "double quote and param" 'x=1; echo "[$x]" '"'"'[$x]'"'" B
cx "adjacent quoting" 'echo "a"b'"'c'"'d' B
c "empty quotes make an argument" 'set -- "" ""; echo $#' B
c "empty unquoted var vanishes" 'x=; set -- $x; echo $#' B
c "quoted empty var stays" 'x=; set -- "$x"; echo $#' B
c "single quote inside dq" "echo \"it's\"" B
c "dq inside sq" "echo '\"x\"'" B
c "newline in single quotes" "echo 'a
b'" B
c "comment" 'echo a # not this
echo b' B
c "hash inside word" 'echo a#b' B
c "backslash before newline in dq" 'echo "a\
b"' B
c "tab preserved" "echo 'a	b'" B
c "dollar at end" 'echo a$' B
c "dollar before space" 'echo $ x' B
c "quoted glob" 'echo "*" '"'"'?'"'" B

# ---- parameter expansion ----
c "plain param" 'x=hello; echo $x ${x}' B
c "param followed by text" 'x=a; echo ${x}b $xb' B
c "default unset" 'echo ${u-def} ${u:-def}' B
c "default empty" 'u=; echo "[${u-def}] [${u:-def}]"' B
c "default set" 'u=v; echo ${u-def} ${u:-def}' B
c "assign default" 'echo ${u=a}; echo $u; v=; echo ${v:=b}; echo $v' B
c "assign default no colon on empty" 'v=; echo "[${v=b}]"; echo "[$v]"' B
c "alternate" 'u=1; echo ${u+alt} ${u:+alt} ${n+alt}x ${n:+alt}y' B
c "alternate empty" 'u=; echo "[${u+alt}] [${u:+alt}]"' B
c "error if unset" 'echo ${u?boom}; echo not reached' B
c "error if unset colon" 'u=; echo ${u:?empty}; echo not reached' B
c "error default message" 'echo ${u?}' B
c "length" 'x=hello; echo ${#x}; y=; echo ${#y}; echo ${#undefined}' B
c "length of positional" 'set -- abc defg; echo ${#1} ${#2} ${#}' B
c "trim suffix small" 'x=file.tar.gz; echo ${x%.*}' B
c "trim suffix large" 'x=file.tar.gz; echo ${x%%.*}' B
c "trim prefix small" 'x=a/b/c; echo ${x#*/}' B
c "trim prefix large" 'x=a/b/c; echo ${x##*/}' B
c "trim no match" 'x=abc; echo ${x#z} ${x%z}' B
c "trim with question mark" 'x=abcd; echo ${x#??} ${x%??}' B
c "trim with bracket" 'x=abc123; echo ${x%%[0-9]*} ${x##*[a-z]}' B
c "trim with quoted pattern" 'x="a*b"; p="*"; echo ${x#"$p"} ${x#$p}' B
c "trim with pattern var" 'x=foobar; p=foo; echo ${x#$p}' B
c "trim unset" 'echo "[${u#x}]"' B
c "nested expansion in default" 'a=1; echo ${u:-${a}x}' B
c "default containing space unquoted splits" 'set -- ${u:-a b}; echo $#' B
c "default containing space quoted" 'set -- "${u:-a b}"; echo $#' B
c "positional params" 'set -- a b c; echo $1 $2 $3 $# ${3}' B
cx "positional above nine" 'set -- 1 2 3 4 5 6 7 8 9 10 11; echo ${10} ${11} $10' B
c "dollar at quoted" 'set -- "a b" c; for i in "$@"; do echo "[$i]"; done' B
c "dollar star quoted" 'set -- "a b" c; for i in "$*"; do echo "[$i]"; done' B
c "dollar at unquoted" 'set -- "a b" c; for i in $@; do echo "[$i]"; done' B
c "star with IFS" 'set -- a b c; IFS=:; echo "$*"; echo $*' B
c "star with empty IFS" 'set -- a b c; IFS=; echo "$*"' B
c "dollar at with no params" 'set --; echo "[$@]" "[$*]"; set -- ""; echo $#' B
c "dollar at prefix and suffix" 'set -- a b; echo "x$@y"' B
c "dollar at empty param" 'set -- a "" b; echo $#; for i in "$@"; do echo "[$i]"; done' B
c "dollar question" 'true; echo $?; false; echo $?' B
c "dollar dollar is a number" 'case $$ in *[!0-9]*) echo bad;; *) echo ok;; esac' B
c "dollar dash default" 'echo "[$-]"' B
c "dollar bang unset" 'echo "[$!]"' B
c "dollar zero from -c" 'sh -c "echo \${0##*/}"' B
c "dollar hash" 'set -- a b; echo $#; set --; echo $#' B
c "special var in default" 'echo ${1-none} ${#-x}' B
c "undefined with set -u" 'set -u; echo $u; echo after' B
c "set -u with default" 'set -u; echo ${u-ok}' B
c "set -u with special" 'set -u; echo $# "$@" "$*"' B
c "set -u positional" 'set -u; echo $1' B
c "param followed by colon" 'x=a; echo $x:b' B
c "name chars" 'a_1=ok; echo $a_1' B
c "braces required for digits" 'x=1; set -- A; echo $1x ${1}x' B
c "assignment prefix visible only to command" 'x=1 sh -c "echo \$x" ; echo "[$x]"' B
c "multiple assignments" 'a=1 b=2; echo $a $b' B
c "assignment uses previous" 'a=1 b=$a; echo $b' B
c "assignment with quotes" 'a="x y"; b='"'"'p q'"'"'; echo "$a" "$b"' B
c "assignment no field splitting" 'a="x y"; b=$a; echo "$b"' B
c "assignment with glob not expanded" 'a=*; echo "$a"' B
c "export visible to children" 'export z=1; sh -c "echo \$z"' B
c "export unset var" 'export z; sh -c "echo [\$z]"; z=2; sh -c "echo \$z"' B
c "unexported not visible" 'z=1; sh -c "echo [\$z]"' B

# ---- tilde ----
c "tilde alone" 'HOME=/h; echo ~' B
c "tilde slash" 'HOME=/h; echo ~/x' B
c "tilde quoted" 'HOME=/h; echo "~" ~"" '"'"'~'"'" B
c "tilde in assignment" 'HOME=/h; a=~/x:~/y; echo $a' B
c "tilde in arg after equals not expanded" 'HOME=/h; echo a=~' B
c "tilde unknown user" 'echo ~nosuchuserxyz' B
c "tilde root" 'echo ~root' B
c "tilde in middle" 'HOME=/h; echo a~' B

# ---- command substitution ----
c "cmdsub dollar paren" 'echo $(echo hi)' B
c "cmdsub backquote" 'echo `echo hi`' B
c "cmdsub strips trailing newlines" 'x=$(printf "a\n\n\n"); echo "[$x]"' B
c "cmdsub keeps inner newlines" 'x=$(printf "a\nb"); echo "$x"' B
c "cmdsub field splitting" 'set -- $(echo a b  c); echo $#' B
c "cmdsub quoted no splitting" 'set -- "$(echo a b  c)"; echo $#' B
c "cmdsub nested" 'echo $(echo $(echo deep))' B
c "cmdsub backquote nested escaped" 'echo `echo \`echo deep\``' B
c "cmdsub status" 'x=$(exit 3); echo $?' B
c "cmdsub status in assignment with command" 'x=$(exit 3) true; echo $?' B
c "cmdsub subshell isolation" 'x=1; y=$(x=2; echo $x); echo $x $y' B
c "cmdsub with case paren" 'echo $(case a in a) echo yes;; esac)' B
c "cmdsub with quotes inside" 'echo "$(echo "a b")"' B
c "cmdsub backquote backslash" 'echo `echo a\\b`' B
c "cmdsub empty" 'echo "[$()]"' B
c "cmdsub multiple commands" 'echo $(echo a; echo b)' B
c "cmdsub in redirection target" 'echo x > $(echo f); cat f' B
c "cmdsub with pipe" 'echo $(echo abc | tr a-c A-C)' B
c "cmdsub and exit trap is separate" 'echo $(trap "echo T" EXIT; echo body)' B

# ---- arithmetic ----
c "arith basic" 'echo $((1+2)) $((7-2)) $((3*4)) $((9/2)) $((9%4))' B
c "arith precedence" 'echo $((2+3*4)) $(((2+3)*4)) $((2*3+4))' B
c "arith unary" 'echo $((-3)) $((+3)) $((!0)) $((!5)) $((~0))' B
c "arith comparison" 'echo $((1<2)) $((2<=2)) $((3>4)) $((4>=4)) $((1==1)) $((1!=1))' B
c "arith logical" 'echo $((1&&0)) $((1||0)) $((0||0)) $((2&&3))' B
c "arith bitwise" 'echo $((5&3)) $((5|3)) $((5^3)) $((1<<4)) $((256>>2))' B
c "arith ternary" 'echo $((1?2:3)) $((0?2:3)) $((1?2?3:4:5))' B
c "arith variables" 'x=5; y=3; echo $((x+y)) $((x*y)) $((x-y))' B
c "arith dollar variables" 'x=5; echo $(($x+1))' B
c "arith assignment" 'echo $((x=5)); echo $x; echo $((x+=2)); echo $x' B
c "arith assignment ops" 'x=10; echo $((x-=3)) $((x*=2)) $((x/=7)) $((x%=3)) $((x<<=2)) $((x>>=1))' B
c "arith chain assign" 'echo $((a=b=3)) $a $b' B
c "arith octal and hex" 'echo $((010)) $((0x10)) $((0X1f))' B
c "arith division truncates" 'echo $((-7/2)) $((7/-2)) $((-7%3))' B
c "arith unset var is zero" 'echo $((undefinedvar+1))' B
c "arith empty var is zero" 'x=; echo $((x+1))' B
c "arith var holding number" 'x=0x10; echo $((x+1))' B
c "arith division by zero" 'echo $((1/0)); echo after' B
c "arith modulo by zero" 'echo $((1%0)); echo after' B
cx "arith missing operand" 'echo $((1+)); echo after' B
c "arith bad octal" 'echo $((08)); echo after' B
cx "arith unmatched paren" 'echo $((1+(2)); echo after' B
cx "arith trailing garbage" 'echo $((1 2)); echo after' B
c "arith short circuit" 'echo $((0&&1/0)) $((1||1/0))' B
c "arith nested" 'echo $(( $((1+1)) * 3 ))' B
c "arith with spaces" 'echo $(( 1 + 2 ))' B
c "arith in quotes" 'echo "$((1+2))"' B
c "arith large" 'echo $((9223372036854775807)) $((9223372036854775807+1))' B
c "arith negative shift" 'echo $((1<<63))' B
c "arith ternary short circuit" 'echo $((1?5:1/0))' B
c "arith var with expression" 'x="1+2"; echo $((x)); echo after' B
c "arith in for" 'i=0; while [ $i -lt 3 ]; do echo $i; i=$((i+1)); done' B
c "arith paren cmdsub ambiguity" 'echo $( (echo a) )' B
c "arith comma not allowed" 'echo $((1,2)); echo after' B
cx "arith exponent not allowed" 'echo $((2**3)); echo after' B

# ---- field splitting ----
c "default IFS" 'x="a  b	c"; set -- $x; echo $#' B
c "IFS colon" 'IFS=:; x=a:b::c; set -- $x; echo $#; for i in $x; do echo "[$i]"; done' B
c "IFS colon trailing" 'IFS=:; x=a:b:; set -- $x; echo $#' B
c "IFS colon leading" 'IFS=:; x=:a; set -- $x; echo $#' B
c "IFS whitespace and non-whitespace" 'IFS=": "; x="a : b"; set -- $x; echo $#; for i in "$@"; do echo "[$i]"; done' B
c "IFS empty" 'IFS=; x="a b"; set -- $x; echo $#' B
c "IFS unset" 'unset IFS; x="a b"; set -- $x; echo $#' B
c "IFS does not split literals" 'IFS=x; set -- axb; echo $#' B
c "IFS splits expansion in word with literal" 'IFS=:; x=a:b; set -- 1${x}2; echo $# "$@"' B
c "IFS newline" 'IFS="
"; x="a b
c d"; set -- $x; echo $#' B
c "IFS in read" 'IFS=:; echo "a:b:c" | { read x y; echo "$x|$y"; }' B
c "split in for" 'x="1 2 3"; for i in $x; do echo "<$i>"; done' B
c "split of quoted part" 'x="a b"; set -- "$x"c; echo $#' B
c "split empty quoted adjacent" 'x=; set -- $x""; echo $#' B
c "IFS tab" 'IFS="	"; x="a b	c"; set -- $x; echo $#' B

# ---- pathname expansion ----
c "glob star" 'touch a b c; echo *' B
c "glob question" 'touch a1 a2 b1; echo a?' B
c "glob bracket" 'touch a1 a2 b1; echo [ab]1' B
c "glob range" 'touch a1 b1 c1; echo [a-b]1' B
c "glob negation" 'touch a1 b1 c1; echo [!a]1' B
cx "glob caret negation" 'touch a1 b1 c1; echo [^a]1' BP "POSIX leaves [^...] unspecified (XCU 2.14.1); bash, yash, busybox and FreeBSD sh negate, dash takes ^ literally."
c "glob no match literal" 'echo nomatch*' B
c "glob dotfiles hidden" 'touch .h v; echo *' B
c "glob dot explicit" 'touch .h v; echo .h*' B
c "glob in subdir" 'mkdir d; touch d/x d/y; echo d/*' B
c "glob dir wildcard" 'mkdir d1 d2; touch d1/f d2/f; echo */f' B
c "glob trailing slash" 'mkdir d; touch f; echo */' B
c "glob quoted not expanded" 'touch a b; echo "*" '"'"'*'"'"' \*' B
c "glob from variable" 'touch a b; x="*"; echo $x; echo "$x"' B
c "glob set -f" 'touch a b; set -f; echo *; set +f; echo *' B
c "glob sorted" 'touch b a c B A; echo *' B
c "glob class" 'touch a1 b2 c; echo [[:alpha:]][[:digit:]]' B
c "glob bracket close first" 'touch ]x ax; echo []]x' B
c "glob in assignment not expanded" 'touch a; v=*; echo $v' B
c "glob escaped bracket" 'touch a b "[a]"; echo \[a\]' B
c "glob in case not filename" 'touch x; case x in *) echo any;; esac' B
c "glob dotdot" 'mkdir d; cd d; touch ../f; echo ../f*' B
c "glob dot-star matches dot and dotdot" 'touch .h v; echo .*' B
c "glob dot-question-star matches dotdot" 'touch .h v; echo .?*' B
c "glob dot bracket" 'touch .h v; echo .[.]*' B
c "glob dot-star in a subdirectory" 'mkdir d; touch d/.h; echo d/.*' B
c "glob star still hides dot and dotdot" 'touch .h v; echo *' B
c "glob absolute" 'echo /de*' B

# ---- redirections ----
c "output redirect" 'echo hi > f; cat f' B
c "append redirect" 'echo a > f; echo b >> f; cat f' B
c "input redirect" 'echo in > f; cat < f' B
c "redirect order stderr" '{ echo out; echo err >&2; } > f 2>&1; cat f' B
c "redirect order swap" '{ echo out; echo err >&2; } 2>&1 > f; echo ---; cat f' B
c "dup to stdout" 'echo hi >&1' B
c "dup stderr to stdout" 'echo err >&2 2>&1' B
c "close fd" 'echo hi >&-; echo "rc=$?"' e
c "fd 3 output" 'echo hi 3>f >&3; cat f' B
c "exec persistent redirect" 'exec 3>f; echo a >&3; echo b >&3; exec 3>&-; cat f' B
c "exec input redirect" 'echo x > f; exec 3<f; read a <&3; echo $a' B
c "read write redirect" 'echo abc > f; exec 3<>f; read x <&3; echo $x' B
c "noclobber" 'echo a > f; set -C; echo b > f; echo "rc=$?"; cat f' B
c "noclobber override" 'echo a > f; set -C; echo b >| f; cat f' B
c "noclobber append ok" 'echo a > f; set -C; echo b >> f; cat f' B
c "redirect to dev null" 'echo gone > /dev/null; echo ok' B
c "redirect missing input" 'cat < nosuchfile; echo "rc=$?"' B
c "redirect failure skips command" 'echo x > /nonexistent/f; echo "rc=$?"' B
c "redirect on compound" '{ echo a; echo b; } > f; cat f' B
c "redirect on subshell" '(echo a; echo b) > f; cat f' B
c "redirect on if" 'if true; then echo y; fi > f; cat f' B
c "redirect on while" 'i=0; while [ $i -lt 2 ]; do echo $i; i=$((i+1)); done > f; cat f' B
c "redirect on function call" 'f() { echo in; }; f > g; cat g' B
c "redirect on function definition" 'f() { echo in; } > g; f; cat g' B
c "redirect restored after builtin" 'echo a > f; echo b; cat f' B
c "redirect word expansion" 'n=file; echo z > $n; cat file' B
c "redirect with fd var like text" 'echo hi 2>/dev/null' B
cx "redirect two-digit fd" 'exec 10>f; echo a >&10; exec 10>&-; cat f' Pe
c "redirect closed input" 'exec <&-; cat; echo "rc=$?"' B
c "stderr to file" 'echo e >&2 2> f; cat f' B
c "input from heredoc to fd 3" 'cat <&3 3<<EOF
x
EOF' B
c "redirect before command" '> f echo hi; cat f' B
c "redirect only creates file" '> f; ls f' B
c "redirect only truncates" 'echo a > f; > f; wc -c < f' B
c "redirect two outputs last wins" 'echo a > f > g; cat g; wc -c < f' B
c "dup input" 'echo x > f; cat 3<&0 < f' B
c "redirect append creates" 'echo a >> new; cat new' B

# ---- here-documents ----
c "heredoc basic" 'cat <<EOF
line1
line2
EOF' B
c "heredoc expands" 'x=v; cat <<EOF
x=$x $((1+2)) $(echo c)
EOF' B
c "heredoc quoted delimiter" 'x=v; cat <<"EOF"
x=$x $((1+2)) $(echo c)
EOF' B
c "heredoc single quoted delimiter" 'x=v; cat <<'"'"'EOF'"'"'
$x
EOF' B
c "heredoc backslash delimiter" 'x=v; cat <<\EOF
$x
EOF' B
c "heredoc strip tabs" 'cat <<-EOF
	one
		two
	EOF' B
c "heredoc dash keeps spaces" 'cat <<-EOF
  keep
EOF' B
c "heredoc backslash escapes" 'x=v; cat <<EOF
\$x \\ \` \a
EOF' B
c "heredoc backslash newline" 'cat <<EOF
a\
b
EOF' B
c "heredoc two in one command" 'cat <<A; cat <<B
first
A
second
B' B
c "heredoc in pipeline" 'cat <<EOF | tr a-z A-Z
hello
EOF' B
c "heredoc in function" 'f() { cat <<EOF
in $1
EOF
}; f arg' B
c "heredoc with quotes in body" 'cat <<EOF
"dq" '"'"'sq'"'"'
EOF' B
cx "heredoc empty" 'cat <<EOF
EOF
echo done' B
c "heredoc fd 3" 'cat 3<<EOF >&2 <&3
x
EOF' B
c "heredoc in cmdsub" 'x=$(cat <<EOF
inner
EOF
); echo "$x"' B
c "heredoc delimiter with spaces in body" 'cat <<EOF
EOF
EOF' B
c "heredoc param default" 'cat <<EOF
${u:-default} ${#u}
EOF' B
c "heredoc to while read" 'while read l; do echo "[$l]"; done <<EOF
a b
c
EOF' B
c "heredoc cmdsub backquote" 'cat <<EOF
`echo bq`
EOF' B

# ---- pipelines and lists ----
c "pipeline status is last" 'false | true; echo $?; true | false; echo $?' B
c "pipeline negate" '! true; echo $?; ! false; echo $?' B
c "pipeline negate pipeline" '! true | false; echo $?' B
c "pipeline three stages" 'echo abc | tr a-c A-C | tr A B' B
c "pipeline subshell variable" 'echo x | { read v; echo $v; }; echo "[$v]"' B
c "pipeline each in subshell" 'x=1; true | x=2; echo $x' B
c "and or" 'true && echo a; false && echo b; false || echo c; true || echo d' B
c "and or chain" 'false || false || echo x; true && false || echo y' B
c "and or precedence left assoc" 'true || echo a && echo b' B
c "and or status" 'false && true; echo $?; true && false; echo $?' B
c "semicolon list" 'echo a; echo b; echo c' B
c "newline list" 'echo a
echo b' B
cx "background and wait" 'echo bg & wait; echo done' B
c "background status wait" '(exit 5) & wait $!; echo $?' B
c "dollar bang" 'true & echo $! | grep -q "^[0-9]" && echo ok; wait' B
cx "background no stdin" 'echo data | { cat & wait; echo done; }' B
c "pipeline with compound" 'for i in 1 2; do echo $i; done | wc -l' B
c "pipeline with while" 'printf "a\nb\n" | while read l; do echo "<$l>"; done' B
c "pipeline stage exit" 'sh -c "exit 3" | cat; echo $?' B
c "subshell status" '(exit 3); echo $?' B
c "subshell no leak" '(x=1); echo "[$x]"' B
c "subshell cd no leak" 'd=$(pwd); (cd /); [ "$(pwd)" = "$d" ] && echo same' B
c "group no subshell" '{ x=1; }; echo $x' B
c "group list" '{ echo a; echo b; }' B
c "subshell nested" '( ( echo deep ) )' B
c "subshell exit does not exit parent" '(exit 1); echo alive' B
c "subshell in pipeline" '(echo a; echo b) | sort -r' B
c "empty subshell parts" '( : ); echo $?' B
c "bang with and" '! false && echo yes' B

# ---- control flow ----
c "if then" 'if true; then echo y; fi' B
c "if else" 'if false; then echo y; else echo n; fi' B
c "if elif" 'if false; then echo 1; elif true; then echo 2; else echo 3; fi' B
c "if elif else fallthrough" 'if false; then echo 1; elif false; then echo 2; else echo 3; fi' B
c "if status when nothing runs" 'if false; then echo 1; fi; echo $?' B
c "if cond list" 'if echo c; true; then echo t; fi' B
c "if multi line" 'if true
then
  echo y
fi' B
c "while" 'i=0; while [ $i -lt 3 ]; do echo $i; i=$((i+1)); done' B
c "until" 'i=0; until [ $i -ge 3 ]; do echo $i; i=$((i+1)); done' B
c "while status" 'while false; do :; done; echo $?' B
c "while break status" 'while true; do break; done; echo $?' B
c "for list" 'for i in a b c; do echo $i; done' B
c "for no in uses positional" 'set -- x y; for i; do echo $i; done' B
c "for empty list" 'for i in; do echo $i; done; echo $?' B
c "for expansion" 'for i in $(echo 1 2) 3; do echo $i; done' B
c "for glob" 'touch a b; for f in *; do echo $f; done' B
c "for var persists" 'for i in 1 2 3; do :; done; echo $i' B
c "for with newline do" 'for i in a b
do
  echo $i
done' B
c "break" 'for i in 1 2 3; do if [ $i = 2 ]; then break; fi; echo $i; done' B
c "continue" 'for i in 1 2 3; do if [ $i = 2 ]; then continue; fi; echo $i; done' B
c "break 2" 'for i in 1 2; do for j in a b; do echo $i$j; break 2; done; done' B
c "continue 2" 'for i in 1 2; do for j in a b; do echo $i$j; continue 2; done; done' B
cx "break more than depth" 'for i in 1 2; do break 5; echo no; done; echo done' B
c "break outside loop" 'break; echo after' B
c "break zero is an error" 'for i in 1; do break 0; done; echo after' B
c "continue in while" 'i=0; while [ $i -lt 4 ]; do i=$((i+1)); [ $i = 2 ] && continue; echo $i; done' B
c "case match" 'case abc in a*) echo yes;; *) echo no;; esac' B
c "case no match" 'case abc in x*) echo yes;; esac; echo $?' B
c "case multiple patterns" 'case b in a|b|c) echo hit;; esac' B
c "case default last" 'case z in a) echo a;; *) echo default;; esac' B
c "case first match wins" 'case a in a) echo 1;; a) echo 2;; esac' B
c "case quoted pattern" 'case "a*" in "a*") echo lit;; esac; case abc in "a*") echo no;; *) echo glob-off;; esac' B
c "case variable pattern" 'p="a*"; case abc in $p) echo yes;; esac' B
c "case bracket" 'case x in [a-z]) echo lower;; esac' B
c "case with newline" 'case a in
a)
  echo a
  ;;
esac' B
c "case optional leading paren" 'case a in (a) echo p;; esac' B
cx "case last without terminator" 'case a in a) echo x esac' B
c "case empty body" 'case a in a) ;; esac; echo $?' B
c "case word expansion" 'x=hello; case "$x" in hel*) echo h;; esac' B
c "case status of body" 'case a in a) false;; esac; echo $?' B
c "case pattern with slash" 'case a/b in */b) echo ok;; esac' B
c "case dollar star" 'set -- a b; case "$*" in "a b") echo ok;; esac' B

# ---- functions ----
c "function call" 'f() { echo hi; }; f' B
c "function args" 'f() { echo $1 $2 $#; }; f a b c' B
c "function positional restored" 'set -- x; f() { echo $1; }; f y; echo $1' B
c "function return status" 'f() { return 3; }; f; echo $?' B
c "return 256 keeps 256 in the status" 'f() { return 256; }; f; echo $?' B
c "return 300 keeps 300 in the status" 'f() { return 300; }; f; echo $?; [ $? -eq 300 ] && echo big; true; echo $?' B
c "return above 255 masks in a subshell" 'f() { return 300; }; (f); echo $?' B
c "return above 255 masks in exit" 'f() { return 300; }; f; exit' B
c "return above 255 is seen by the EXIT trap" 'trap "echo T\$?" EXIT; f() { return 300; }; f; exit' B
c "return above 255 in dot" 'echo "return 300" > s; . ./s; echo $?' B
c "function default status is last" 'f() { false; }; f; echo $?' B
c "function return no arg" 'f() { false; return; }; f; echo $?' B
c "function recursion" 'f() { if [ $1 -gt 0 ]; then echo $1; f $(($1-1)); fi; }; f 3' B
c "function shares variables" 'f() { x=2; }; x=1; f; echo $x' B
c "function redefine" 'f() { echo 1; }; f() { echo 2; }; f' B
c "function with redirect" 'f() { echo in; }; f > g; cat g' B
c "function calls function" 'a() { b; }; b() { echo b; }; a' B
cx "function body compound if" 'f() if true; then echo y; fi; f' B
c "function return in loop" 'f() { for i in 1 2 3; do if [ $i = 2 ]; then return 7; fi; done; }; f; echo $?' B
c "function and special builtin name" 'f() { echo mine; }; f' B
c "function dollar zero" 'sh -c "f() { echo \${0##*/}; }; f"' B
c "function unset" 'f() { echo hi; }; unset -f f; f; echo "rc=$?"' B
c "function in pipeline" 'f() { cat; }; echo x | f' B
c "function overrides regular builtin" 'echo() { printf "mine\n"; }; echo hi' B
c "function precedence over external" 'true() { echo shadow; }; true' B
c "function cannot override special builtin" 'eval() { echo shadow; }; eval echo real' Pe
c "function assignment prefix" 'f() { echo "[$x]"; }; x=1 f; echo "[$x]"' B
c "function exit in subshell" 'f() { exit 4; }; (f); echo $?' B
c "function with command substitution" 'f() { echo r; }; x=$(f); echo $x' B
c "return at top level of dot" 'echo "echo a; return 3; echo b" > s; . ./s; echo $?' B
c "function local-like via subshell" 'f() ( x=2; echo $x ); x=1; f; echo $x' B

# ---- set -e ----
c "errexit basic" 'set -e; false; echo not reached' B
c "errexit true" 'set -e; true; echo reached' B
c "errexit: a failed redirection of a subshell" 'set -e; (:) > /; echo not reached' B
c "errexit: a failed redirection of a group" 'set -e; { :; } > /; echo not reached' B
c "an unknown -o name is reported before the script is opened" 'sh -o nosuchoption nosuchfile 2>/dev/null; echo $?' B
c "errexit in if cond" 'set -e; if false; then :; fi; echo reached' B
c "errexit and list left" 'set -e; false && echo x; echo reached' B
c "errexit and list right" 'set -e; true && false; echo not reached' B
c "errexit or list" 'set -e; false || echo recovered; echo reached' B
c "errexit negated" 'set -e; ! false; echo reached' B
c "errexit negated true" 'set -e; ! true; echo reached' B
c "errexit while cond" 'set -e; while false; do :; done; echo reached' B
c "errexit in function" 'set -e; f() { false; echo in; }; f; echo not reached' B
c "errexit function in if" 'set -e; f() { false; echo in; }; if f; then echo t; fi; echo reached' B
c "errexit subshell" 'set -e; (false; echo in); echo not reached' B
c "errexit pipeline last" 'set -e; false | true; echo reached' B
c "errexit pipeline fails last" 'set -e; true | false; echo not reached' B
c "errexit command substitution" 'set -e; x=$(false); echo "reached [$x]"' B
c "errexit assignment cmdsub" 'set -e; x=$(false) ; echo not reached' B
c "errexit compound" 'set -e; { false; echo in; }; echo not reached' B
c "errexit for body" 'set -e; for i in 1 2; do false; echo in; done; echo not reached' B
c "errexit case" 'set -e; case a in a) false;; esac; echo not reached' B
c "errexit trap exit" 'set -e; trap "echo bye" EXIT; false; echo no' B
c "errexit set +e" 'set -e; set +e; false; echo reached' B
c "errexit with return" 'set -e; f() { return 1; }; f; echo not reached' B
c "errexit eval" 'set -e; eval false; echo not reached' B
c "errexit dot" 'set -e; echo false > s; . ./s; echo not reached' B
c "errexit status propagates" 'set -e; (exit 5); echo no' B
c "errexit not for list not last" 'set -e; false && true || true; echo reached' B

# ---- other set options ----
c "set -x trace" 'set -x; echo hi' e
c "set -x assignment" 'set -x; x=1; echo $x' e
c "set -x plus" 'set -x; set +x; echo hi' B
c "set -n" 'echo before; set -n; echo not run' B
c "set -v" 'printf "set -v\necho hi\n" > s; sh s 2>&1' B
c "set -f" 'touch a; set -f; echo *' B
c "set -u" 'set -u; echo $nothing; echo after' B
c "set -a" 'set -a; x=1; sh -c "echo \$x"' B
c "set -C" 'set -C; echo a > f; echo b > f; echo $?' B
c "set -o names" 'set -o | grep -c -E "^(errexit|nounset|noglob|verbose|xtrace) "' e
c "set -o noglob" 'touch a; set -o noglob; echo *' B
c "set -o errexit" 'set -o errexit; false; echo no' B
c "set -o nounset" 'set -o nounset; echo $x; echo no' B
c "set +o prints commands" 'set +o | grep -c -E "^set [-+]o (errexit|nounset|noglob|verbose|xtrace)$"' e
c "dollar dash reflects options" 'set -f; echo $-' e
c "set -e then dollar dash" 'set -e; echo $-' e
c "set positional" 'set -- a b c; echo $#; set a; echo $#; echo $1' B
c "set dash dash clears" 'set -- a b; set --; echo $#' B
c "set no args prints vars" 'x=1; set | grep "^x="' B
c "set -- with dash arg" 'set -- -x y; echo $1 $2' B
c "set option then positional" 'set -f -- a b; echo $#' B
c "shift" 'set -- a b c; shift; echo $1 $#' B
c "shift n" 'set -- a b c d; shift 2; echo $1 $#' B
c "shift zero" 'set -- a b; shift 0; echo $#' B
c "shift too many" 'set -- a; shift 2; echo after' B
c "shift all" 'set -- a b; shift 2; echo $#' B

# ---- trap ----
c "trap exit" 'trap "echo bye" EXIT; echo hi' B
c "trap exit on exit command" 'trap "echo bye" EXIT; exit 3' B
c "trap exit status kept" 'trap "echo bye" EXIT; (exit 4)' B
c "trap exit in subshell separate" 'trap "echo outer" EXIT; (trap "echo inner" EXIT; true); echo main' B
c "trap exit not inherited by subshell" 'trap "echo T" EXIT; (echo sub); echo main' B
cx "trap reset" 'trap "echo x" EXIT; trap - EXIT; echo done' B
cx "trap ignore" 'trap "" EXIT; echo done' B
c "trap signal" 'trap "echo got" USR1; kill -USR1 $$; echo after' B
c "trap signal number" 'trap "echo got" 10; kill -10 $$; echo after' B
c "trap multiple signals" 'trap "echo s" USR1 USR2; kill -USR2 $$; echo after' B
c "trap ignore signal" 'trap "" USR1; kill -USR1 $$; echo survived' B
c "trap reset signal kills" 'trap "echo x" USR1; trap - USR1; (kill -USR1 $$; echo no) ; echo "rc=$?"' e
c "trap in function" 'f() { trap "echo in-f" EXIT; }; f; echo main' B
c "trap with quotes" 'trap "echo \"a b\"" EXIT' B
c "trap shows" 'trap "echo hi" INT; trap' B
c "trap exit status of handler" 'trap "exit 9" EXIT; exit 1' B
c "trap runs after command" 'trap "echo trapped" USR1; kill -USR1 $$; echo next' B
cx "trap with wait" '(sleep 1; kill -USR1 $$) & trap "echo got" USR1; wait; echo done' B
c "trap dollar question in handler" 'trap "echo [\$?]" EXIT; false' B
c "trap bad signal" 'trap "echo x" NOSUCHSIG; echo "rc=$?"' e
c "trap EXIT zero" 'trap "echo z" 0; echo main' B
cx "trap numeric reset" 'trap "echo x" EXIT; trap 0; echo done' B
c "trap in subshell reset" 'trap "echo parent" USR1; (trap; echo in) ' BP "POSIX.1-2024 trap: a subshell reports the parent's traps; dash and FreeBSD sh print nothing (deviation recorded in docs/posix-shell-differences.md)."

# With SIGCHLD ignored the kernel reaps children itself; the shell must not let
# that lose their statuses. IGN_CHLD starts the rest of its line that way.
IGN_CHLD="python3 -I -c 'import os,signal,sys; signal.signal(signal.SIGCHLD,signal.SIG_IGN); os.execvp(sys.argv[1],sys.argv[1:])'"
c "trap ignore CHLD keeps statuses" 'trap "" CHLD; false; echo $?; sh -c "exit 3" && echo no; echo $?; (exit 5) & wait $!; echo $?; x=$(exit 4); echo $?' e
c "inherited ignored CHLD keeps statuses" "$IGN_CHLD sh -c 'false; echo \$?; sh -c \"exit 3\" && echo no; echo \$?; (exit 5) & wait \$!; echo \$?; x=\$(exit 4); echo \$?'" e
c "inherited ignored CHLD keeps statuses with set -m" "$IGN_CHLD sh -c 'set -m; false; echo \$?; false && echo no; sh -c \"exit 3\"; echo \$?' 2>/dev/null" e
c "inherited ignored CHLD reaches programs" "$IGN_CHLD sh -c 'grep SigIgn /proc/self/status; (grep SigIgn /proc/self/status; :); exec grep SigIgn /proc/self/status' | cut -c 20" eP "POSIX leaves a signal ignored on entry ignored in programs run; dash resets SIGCHLD, bash, busybox and yash pass it on."

# ---- assignments before a command see one another (CONF-01) ----
c "prefix assignment sees earlier, program" 'unset d; d=/tmp/x l=$d/log sh -c "echo \$l"; echo "${d-unset}"'
c "prefix assignment sees new value" 'a=old; a=new b=$a env | grep "^b="; echo $a'
c "prefix assignment sees earlier, command substitution" 'unset a; a=1 b=$(printenv a || echo none) env | grep "^b="'
c "prefix assignment sees earlier, function" 'f() { echo "$b $a"; }; a=old; a=new b=$a f; echo "$a ${b-unset}"'
c "prefix assignment sees earlier, regular builtin" 'a=old; a=new b=$a command eval "echo \$b"; echo "$a ${b-unset}"'
c "prefix assignment sees earlier, special builtin" 'a=old; a=new b=$a :; echo "$a $b"'
c "prefix assignment sees earlier, eval" 'a=new b=$a eval "echo \$b"'
c "prefix assignment sees earlier arithmetic" 'n=1; n=$((n+1)) m=$n env | grep "^[mn]=" | sort; echo $n'
c "prefix assignment colon-default sees earlier" 'a=; a=1 b=${a:-empty} env | grep "^b="'
c "prefix assignment changed by a later expansion" 'unset a; a=1 b=$((a=5)) c=$a env | grep "^[abc]=" | sort; echo "${a-unset}"'
c "prefix assignment sees earlier under set -u" 'set -u; unset d; d=/new f=$d/file env | grep "^f="'

# ---- aliases keep expanding however many have been used (SHL-02) ----
c "alias used hundreds of times" 'echo "alias say=echo" > s; i=0; while [ $i -lt 300 ]; do echo "say $i"; i=$((i+1)); done >> s; . ./s | tail -3'
c "alias of an alias used hundreds of times" '{ echo "alias say=echo"; echo "alias hi=\"say hi \""; i=0; while [ $i -lt 300 ]; do echo "hi $i"; i=$((i+1)); done; } > s; sh s | tail -3'
c "long alias values used many times" '{ echo "alias say=\"echo $(printf %09000d 7)\""; i=0; while [ $i -lt 40 ]; do echo "say $i; say $i"; i=$((i+1)); done; } > s; . ./s | cksum'

c "alias use does not disturb an earlier tilde name" 'printf "%s\n" "alias a=:" "alias b=\"echo zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\"" "{ a; echo ~root; b; b; }" > s; sh s'

# ---- backslash-newline is removed by the scanner (SHL-03) ----
c "continuation: quote in a backquoted comment" 'cat > s <<'\''END_OF_SCRIPT'\''
x=`# it'\''s a comment`
printf '\''%s\n'\'' '\''keep\
this'\''
END_OF_SCRIPT
sh s; echo "= $?"; sh < s; echo "= $?"'
c "continuation: shift in arithmetic" 'cat > s <<'\''END_OF_SCRIPT'\''
echo $((1<<2))
FOO=bar
echo $FO\
O
true &\
& echo and
END_OF_SCRIPT
sh s; echo "= $?"; sh < s; echo "= $?"'
c "continuation: inside operators" 'cat > s <<'\''END_OF_SCRIPT'\''
true &\
& echo a |\
| echo no
echo b >\
> f; cat f
case x in x) echo c ;\
; esac
cat <\
<E
body
E
cat <\
<\
-E
	body2
	E
echo d 2\
>\
&1
END_OF_SCRIPT
sh s; echo "= $?"; sh < s; echo "= $?"'
c "continuation: inside parameter expansions" 'cat > s <<'\''END_OF_SCRIPT'\''
ab=VAL; set -- one two three four five six seven eight nine ten
echo $\
ab $a\
b ${\
ab} ${a\
b} ${ab\
} $\
1 $\
{10} ${1\
0} ${#\
ab} ${#a\
b}
echo ${u:\
-d} ${ab#\
#V} ${ab#\
} ${ab%\
%L} ${u\
-e} $\
# $\
?
END_OF_SCRIPT
sh s; echo "= $?"; sh < s; echo "= $?"'
c "continuation: inside command and arithmetic substitution" 'cat > s <<'\''END_OF_SCRIPT'\''
echo $\
(echo sub) $\
((1+2)) $(\
(2+3)) $((4+4)\
) $((1\
<\
<4))
END_OF_SCRIPT
sh s; echo "= $?"; sh < s; echo "= $?"'
c "continuation: line numbers" 'cat > s <<'\''END_OF_SCRIPT'\''
echo \
  $LINENO
echo a\
b $LINENO
echo $\
LINENO
echo $LINENO
END_OF_SCRIPT
sh s; echo "= $?"; sh < s; echo "= $?"' P "dash has no LINENO."
c "continuation: kept in quoted text" 'cat > s <<'\''END_OF_SCRIPT'\''
printf '\''%s\n'\'' '\''a\
b'\'' "c\
d" e\\
echo f # comment \
echo g
cat <<'\''E'\''
h\
i
E
cat <<E
j\
k
E
END_OF_SCRIPT
sh s; echo "= $?"; sh < s; echo "= $?"'
c "continuation: quoted here-document delimiter with a blank" 'cat > s <<'\''END_OF_SCRIPT'\''
cat <<'\''a b'\''
$x \
in
a b
cat <<\
  EOF2
z
EOF2
echo after $((1<<2)) ok\
ay
END_OF_SCRIPT
sh s; echo "= $?"; sh < s; echo "= $?"'
c "continuation: at the very end" 'cat > s <<'\''END_OF_SCRIPT'\''
echo end \

END_OF_SCRIPT
sh s; echo "= $?"; sh < s; echo "= $?"' e
c "continuation: dollar-single-quotes keep it" 'printf "%s\\n" "x=\$'\''a\\'\''b'\''" "y='\''keep\\" "this'\''" "printf \"%s\\\\n\" \"\$x\" \"\$y\"" > s; sh s' Pe "dash has no dollar-single-quotes (POSIX.1-2024)."

# ---- pipes with a standard descriptor closed (SHX-02) ----
c "pipeline with stdin closed" 'exec <&-; echo hi | cat; echo st=$?'
c "command substitution with stdout closed" 'exec >&-; x=$(echo hi); echo "x=[$x]" >&2'
c "pipeline with stdin and stdout closed" 'exec <&- >&-; x=$(echo a | cat | cat); echo "x=[$x]" >&2'
c "pipeline with all three closed" 'exec 4>log <&- >&- 2>&-; x=$(echo a | cat); echo "x=[$x]" >&4; exec 4>&-; cat log >/dev/null; { read l < log; case $l in "x=[a]") exit 0;; esac; exit 1; }'
c "here-document and redirection with stdin closed" 'exec <&-; cat <<E
doc
E
echo file > f; cat < f; read a < f; echo $a; x=$(cat <<E
in-subst
E
); echo $x'

# ---- getopts when the argument list changes (SHX-03) ----
c "getopts: operands change inside a group" 'getopts ab o -ab; echo "$o"; getopts ab o -x 2>/dev/null; echo "$o $?"' Pe "dash keeps its place in the old argument; bash and ours start the new one."
c "getopts: function call changes the arguments" 'f() { getopts ab o; echo "$o"; }; f -ab; f -a; echo end'
c "getopts: shift inside a group" 'set -- -ab -b; getopts ab o; echo "$o"; shift 2; getopts ab o; echo "$o $?"; echo end' e
c "getopts: new argument shorter than the place in the old one" 'getopts abc o -abc; getopts abc o x >/dev/null 2>&1; getopts abc o -- >/dev/null 2>&1; echo alive'

# ---- a function from eval, dot or a trap outlives its source text (MEM-01) ----
c "tilde in a function defined by dot and eval" '{ echo "f() { echo ~root/x; }"; printf "# %070000d\n" 0; } > big.sh; . ./big.sh; f; big=$(printf "%070000d" 0); eval ": $big; g() { p=a:~root; echo \$p ~root; }"; g'

# ---- values stay usable while the word beside them assigns them (MEM-04) ----
c "trim a variable that the pattern assigns" 'x=hello; echo "[${x#$((x=1))}]"; p=/usr/local/lib; echo "${p%/$((p=0))}" $p; y=abcabc; echo ${y##*$((y=7))} ${y%%b*$((y=8))}'
c "default and alternate words that assign the variable" 'x=abc; echo "${x+$((x=2))}" $x; y=; echo "${y:-$((y=3))}" $y; z=long-value; echo "${z%"${z:=other}"}|$z"'

c "jobs: one finished job named twice" 'true & sleep 0.3; jobs %1 %1 >/dev/null 2>&1; echo alive; sleep 0 & sleep 0.3; jobs %% %1 >/dev/null 2>&1; echo end' e

c "redirection that assigns PATH after the command was found" 'mkdir d; cd d; ls -d / >/dev/null; ls -d / >f$((PATH=5)); echo $?; cat f5' Pe "dash looks the command up again under the new PATH; bash and busybox run the one found."

# ---- a temporary PATH does not stay remembered (SHX-01) ----
EVIL='mkdir evil; printf "#!/bin/sh\necho FROM-TEMPORARY-PATH\n" > evil/ls; chmod +x evil/ls; '
c "temporary PATH for one command is forgotten" "$EVIL"'PATH=$PWD/evil ls; ls -d /'
c "local PATH is forgotten" "$EVIL"'f() { local PATH=$PWD/evil; ls; }; f; ls -d /'
c "temporary PATH after one that ran a builtin" "$EVIL"'PATH=$PWD/evil true; PATH=$PWD/evil ls; ls -d /'
c "PATH changed inside a function called with a temporary PATH" "$EVIL"'f() { PATH=$PWD/evil; ls; }; PATH=$PATH f; ls -d /'

# ---- a script without #! starts as a new shell (SHX-04) ----
NOBANG='nobang() { cat > "$1"; chmod +x "$1"; }; '
c "script without #!: set -e works though the caller ignores errors" "$NOBANG"'printf "set -e\nfalse\necho SHOULD-NOT-PRINT\n" | nobang s; if ./s; then echo yes; else echo no; fi; ./s || echo "or $?"; ! ./s; echo $?'
c "script without #!: loop depth is its own" "$NOBANG"'echo "break; echo after-break" | nobang s; for i in 1 2; do ./s 2>/dev/null; echo $i; done' e
c "script without #!: variables, exports and OPTIND" "$NOBANG"'echo "echo \$# \${OPTIND-unset} \${V-unset} \${U-unset} \$E" | nobang s; U=1; export E=e; V=v ./s a b; getopts a o -a; ./s; (exec ./s z)'
c "script without #!: no functions or aliases" "$NOBANG"'echo "f 2>/dev/null; echo \$?" | nobang s; f() { echo f; }; alias g=echo; ./s' e
c "script without #!: ignored signal stays ignored, traps do not carry over" "$NOBANG"'echo "kill -USR1 \$\$; echo alive; trap" | nobang s; trap "" USR1; ./s; trap "echo caught" USR1; ./s; echo $?' eP "dash lists no trap for a signal ignored on entry"

# ---- eval / dot / exec / command / type ----
c "eval simple" 'eval echo hi' B
c "eval concatenates args" 'eval "echo" "a" "b"' B
c "eval with variable" 'x=y; eval "$x=5"; echo $y' B
c "eval quoting" 'eval "echo '"'"'a b'"'"'"' B
c "eval empty" 'eval; echo $?' B
c "eval status" 'eval "false"; echo $?' B
c "eval sees functions" 'f() { echo f; }; eval f' B
c "eval double expansion" 'x=\$y; y=v; eval echo $x' B
c "eval syntax error" 'eval "if"; echo after' B
c "eval multiple commands" 'eval "echo a; echo b"' B
c "eval assigns persist" 'eval "x=5"; echo $x' B
c "eval in function return" 'f() { eval "return 4"; echo no; }; f; echo $?' B
c "dot sources" 'echo "x=sourced" > s; . ./s; echo $x' B
c "dot with args" 'echo "echo \$1 \$#" > s; . ./s a b' Pe
c "dot restores args" 'echo "echo in" > s; set -- p q; . ./s a; echo $1' B
c "dot searches PATH" 'mkdir bin; echo "echo found" > bin/s; PATH=bin:$PATH; . s' B
c "dot missing file" '. ./nosuch; echo after' B
c "dot status" 'echo "false" > s; . ./s; echo $?' B
c "dot defines function" 'echo "f() { echo fn; }" > s; . ./s; f' B
c "dot return" 'echo "return 5" > s; . ./s; echo $?' B
c "exec replaces" 'exec echo replaced; echo no' B
c "exec status" 'sh -c "exec sh -c \"exit 6\""; echo $?' B
c "exec not found" 'exec nosuchcmd; echo after' B
c "exec redirect only" 'exec 3>f; echo x >&3; cat f' B
c "exec with assignment" 'x=1 exec sh -c "echo \$x"' B
c "command bypasses function" 'echo() { printf "fn\n"; }; command echo real' B
c "command -v external" 'command -v ls >/dev/null; echo $?' B
c "command -v builtin" 'command -v cd' B
c "command -v function" 'f() { :; }; command -v f' B
c "command -v missing" 'command -v nosuchcmd; echo $?' B
c "command exec" 'command exec echo hi' B
c "command special builtin error does not exit" 'command shift 5; echo after' B
c "command -p" 'PATH=/nonexistent; command -p cat /dev/null; echo $?' B
c "command not found status" 'command nosuchcmd; echo $?' B
c "type builtin" 'type cd' B
c "type function" 'f() { :; }; type f' B
c "type missing" 'type nosuchcmd; echo $?' B
c "type keyword" 'type if' B
c "type external found" 'type ls >/dev/null; echo $?' B
c "colon" ': foo bar; echo $?' B
c "true false" 'true; echo $?; false; echo $?' B
c "special builtin assign persists" 'x=1 :; echo $x' B
c "regular builtin assign does not persist" 'x=1 true; echo "[$x]"' B
c "special builtin assign eval persists" 'x=1 eval :; echo $x' B
c "special builtin redirect error exits" ': > /nonexistent/f; echo after' B
c "regular builtin redirect error continues" 'true > /nonexistent/f; echo after' B
c "special builtin set error exits" 'set -Z; echo after' B
c "special builtin unset readonly exits" 'readonly r=1; unset r; echo after' B
c "special builtin export readonly exits" 'readonly r=1; export r=2; echo after' B
c "special builtin shift error exits" 'shift 3; echo after' B
c "special builtin exit bad number" 'exit abc; echo after' B
c "special builtin break bad number" 'while true; do break x; done; echo after' B
c "special builtin return bad number" 'f() { return x; }; f; echo after' B
c "special builtin eval error exits" 'eval "("; echo after' B
c "special builtin dot missing exits" '. /nonexistent; echo after' B
c "readonly assign error exits" 'readonly r=1; r=2; echo after' B
c "readonly in command prefix" 'readonly r=1; r=2 true; echo after' B
c "readonly for var" 'readonly i=1; for i in a; do :; done; echo after' B
c "readonly value kept" 'readonly r=1; (r=2) 2>/dev/null; echo $r' B
c "unset var" 'x=1; unset x; echo "[$x]"' B
c "unset function and var" 'x=1; f() { :; }; unset x f; echo "[$x]"; f 2>/dev/null; echo $?' B
c "unset nonexistent" 'unset nothing; echo $?' B
c "export list" 'export ee=1; export -p | grep " ee="' B
c "readonly list" 'readonly rr=1; readonly -p | grep " rr="' B
c "export with value" 'export a=1 b=2; sh -c "echo \$a \$b"' B
c "export bad name" 'export 1x=3; echo after' B

# ---- command lookup and exit statuses ----
c "not found status" 'nosuchcmd; echo $?' B
c "not found message" 'nosuchcmd' B
c "not found path" './nosuchcmd; echo $?' B
c "not executable status" 'echo "echo hi" > s; ./s; echo $?' B
c "exec permission denied" 'echo "echo hi" > s; chmod 644 s; ./s; echo $?' B
c "directory is not executable" 'mkdir d; ./d; echo $?' B
c "script without shebang runs" 'printf "echo ran \$1\n" > s; chmod +x s; ./s arg; echo $?' B
c "script with shebang" 'printf "#!/bin/sh\necho ran\n" > s; chmod +x s; ./s' B
c "path search order" 'mkdir a b; printf "#!/bin/sh\necho a\n" > a/p; printf "#!/bin/sh\necho b\n" > b/p; chmod +x a/p b/p; PATH=b:a:$PATH; p' B
c "path with empty component" 'printf "#!/bin/sh\necho local\n" > p; chmod +x p; PATH=:$PATH p' B
c "command with slash skips path" 'mkdir d; printf "#!/bin/sh\necho in-d\n" > d/p; chmod +x d/p; d/p' B
c "exit status of killed" 'sh -c "kill -9 \$\$"; echo $?' e
c "exit status 255" 'sh -c "exit 255"; echo $?' B
c "exit status wraps" 'sh -c "exit 256"; echo $?' B
c "exit bare uses last" 'false; exit' B
c "exit n" 'exit 7' B
c "exit large" 'exit 300' B
c "exit negative" 'exit -1' B
c "status of assignment only" 'x=$(exit 4); echo $?' B
c "status of redirect only" '> f; echo $?' B
c "dollar question after pipeline" 'true | false; echo $?' B
c "dollar question in subshell" '(false; echo $?)' B
c "dollar question preserved by echo" 'false; echo $?; echo $?' B

# ---- builtins: echo printf read test getopts cd pwd ----
c "echo basic" 'echo a b  c' B
c "echo no args" 'echo' B
c "echo -n" 'echo -n a; echo b' B
c "echo escapes" 'echo "a\tb\\c"' e
cx "echo dash e is literal" 'echo -e a' e
c "echo dollar paren" 'echo "$(echo a)b"' B
c "printf string" 'printf "%s\n" hello' B
cx "printf has no options" 'printf -v x %s 1 2>/dev/null; echo $?; printf -- "%s\n" y' B
cx "printf -5 is an illegal option" 'printf -5 x 2>/dev/null; echo $?' B
c "printf multiple args reuse format" 'printf "%s\n" a b c' B
c "printf int" 'printf "%d\n" 42 -7 0' B
c "printf hex octal" 'printf "%x %X %o\n" 255 255 8' B
c "printf width" 'printf "[%5s][%-5s][%05d]\n" ab cd 42' B
c "printf precision" 'printf "%.3s|%.2d\n" abcdef 5' B
c "printf char" 'printf "%c\n" xyz' B
c "printf percent" 'printf "100%%\n"' B
c "printf escapes" 'printf "a\tb\n"' B
c "printf octal escape" 'printf "\101\n"' B
c "printf missing args" 'printf "%s|%d|\n"' B
c "printf extra args" 'printf "x\n" a b' B
c "printf %b" 'printf "%b\n" "a\tb"' B
c "printf no newline" 'printf abc; echo' B
c "printf bad number" 'printf "%d\n" abc; echo "rc=$?"' e
c "printf numeric prefix" 'printf "%d\n" 12abc; echo "rc=$?"' e
c "printf char code" "printf '%d\n' \"'A\"" B
c "printf star width" 'printf "%*d\n" 5 3' B
c "printf plus flag" 'printf "%+d % d\n" 5 5' B
c "printf unsigned" 'printf "%u\n" 3' B
c "read basic" 'echo "a b c" | { read x y; echo "$x|$y"; }' B
c "read one var gets line" 'echo "  a b  " | { read x; echo "[$x]"; }' B
c "read -r" 'printf "%s\n" "a\\\\b" | { read -r x; printf "%s\n" "$x"; }' B
c "read backslash" 'printf "%s\n" "a\\\\b" | { read x; printf "%s\n" "$x"; }' B
c "read continuation" 'printf "a\\\\\nb\n" | { read x; echo "$x"; }' B
c "read eof status" 'printf "" | { read x; echo "rc=$?"; }' B
c "read partial line" 'printf "abc" | { read x; echo "rc=$? $x"; }' B
c "read multiple lines" 'printf "1\n2\n" | { read a; read b; echo $a $b; }' B
c "read extra fields to last" 'echo "a b c d" | { read x y; echo "$y"; }' B
c "read fewer fields" 'echo "a" | { read x y z; echo "[$x][$y][$z]"; }' B
c "read IFS colon" 'echo "a:b:c" | { IFS=: read x y; echo "$x $y"; }' B
c "read from file" 'echo data > f; read x < f; echo $x' B
c "read loop" 'printf "a\nb\nc\n" | while read l; do echo "[$l]"; done' B
c "read empty line" 'echo | { read x; echo "[$x]"; }' B
c "read tab fields" 'printf "a\tb\n" | { read x y; echo "$x-$y"; }' B
c "read leading IFS trimmed" 'echo "   x" | { read v; echo "[$v]"; }' B
c "read does not overread" 'printf "a\nb\n" | { read x; cat; }' B
c "test string" 'test a = a; echo $?; test a = b; echo $?; test a != b; echo $?' B
c "test -n -z" 'test -n x; echo $?; test -z ""; echo $?; test -n ""; echo $?' B
c "test single arg" 'test x; echo $?; test ""; echo $?' B
c "test no arg" 'test; echo $?' B
c "test integers" 'test 1 -eq 1; echo $?; test 1 -ne 1; echo $?; test 2 -gt 1; echo $?; test 1 -ge 2; echo $?; test 1 -lt 2; echo $?; test 3 -le 2; echo $?' B
c "test files" 'touch f; mkdir d; test -f f; echo $?; test -d d; echo $?; test -e f; echo $?; test -e nothing; echo $?' B
c "test -s -r -w -x" 'echo a > f; test -s f; echo $?; test -r f; echo $?; test -w f; echo $?; test -x f; echo $?; chmod +x f; test -x f; echo $?' B
c "test not" 'test ! a = b; echo $?; test ! -f nothing; echo $?' B
c "test and or" 'test 1 -eq 1 -a 2 -eq 2; echo $?; test 1 -eq 2 -o 2 -eq 2; echo $?; test 1 -eq 2 -a 2 -eq 2; echo $?' B
c "test parens" 'test \( 1 -eq 1 \); echo $?; test \( 1 -eq 2 -o 1 -eq 1 \) -a 3 -eq 3; echo $?' B
c "test bracket" '[ a = a ]; echo $?; [ 1 -lt 2 ]; echo $?' B
cx "test bracket missing close" '[ a = a; echo $?' e
c "test bad integer" '[ x -eq 1 ]; echo $?' e
cx "test unary operators as strings" '[ -f ]; echo $?; [ -n ]; echo $?' B
c "test two args not" '[ ! x ]; echo $?; [ ! "" ]; echo $?' B
c "test symlink" 'touch f; ln -s f l; [ -L l ]; echo $?; [ -L f ]; echo $?; [ -h l ]; echo $?' B
c "test -nt -ot -ef" 'touch a; sleep 1; touch b; [ b -nt a ]; echo $?; [ a -ot b ]; echo $?; ln a c; [ a -ef c ]; echo $?' B
c "test string with spaces" '[ "a b" = "a b" ]; echo $?' B
c "test empty var needs quotes" 'x=; [ "$x" = "" ]; echo $?' B
cx "test special chars" '[ "(" = "(" ]; echo $?; [ "!" = "!" ]; echo $?' B
c "test -t" '[ -t 0 ]; echo $?' B
c "test -p -S -b -c" 'mkfifo p; [ -p p ]; echo $?; [ -c /dev/null ]; echo $?; [ -b /dev/null ]; echo $?' B
c "test -ef nonexistent" '[ nothing -ef nothing ]; echo $?' B
c "getopts basic" 'set -- -a -b x; while getopts ab: o; do echo "$o $OPTARG $OPTIND"; done' B
c "getopts grouped" 'set -- -ab; while getopts ab o; do echo "$o $OPTIND"; done' B
c "getopts arg attached" 'set -- -bval; while getopts b: o; do echo "$o $OPTARG"; done' B
c "getopts unknown" 'set -- -z; getopts a o; echo "$o"' e
c "getopts silent unknown" 'set -- -z; getopts :a o; echo "$o $OPTARG"' B
c "getopts silent missing arg" 'set -- -b; getopts :b: o; echo "$o $OPTARG"' B
c "getopts missing arg" 'set -- -b; getopts b: o; echo "$o"' e
c "getopts stops at operand" 'set -- -a x -b; while getopts ab o; do echo $o; done; echo $OPTIND' B
c "getopts double dash" 'set -- -a -- -b; while getopts ab o; do echo $o; done; echo $OPTIND' B
c "getopts explicit args" 'getopts a o -a; echo $o $OPTIND' B
c "getopts in function" 'f() { while getopts x: o; do echo "$o=$OPTARG"; done; }; f -x 1 -x 2' B
c "getopts status end" 'set -- a; getopts a o; echo $?' B
c "getopts OPTIND reset" 'set -- -a; getopts a o; OPTIND=1; getopts a o; echo $o' B
c "cd and pwd" 'mkdir d; cd d; pwd | sed "s#.*/##"' B
c "cd dot dot" 'mkdir -p a/b; p=$(pwd); cd a/b; cd ../..; if [ "$(pwd)" = "$p" ]; then echo back; else echo elsewhere; fi' B
c "cd empty operand is a no-op" 'mkdir d; cd d; cd ""; echo $?; pwd | sed "s#.*/##"' B
c "cd with a read-only OLDPWD fails" 'mkdir d; p=$(pwd); readonly OLDPWD; cd d 2>/dev/null; echo $?; if [ "$(pwd)" = "$p" ]; then echo stayed; else echo moved; fi' B
c "glob directory order uses the slash" 'mkdir a a.b a-b; touch a/f a.b/f a-b/f; echo */f; echo */' B
c "glob dot-star slash order" 'mkdir .h; echo .*/' B
c "cd dash prints" 'mkdir -p x/d; cd x; cd d; cd - > ../../out; echo $?; sed "s#.*/##" ../out' B
c "cd nonexistent" 'cd /nonexistent; echo "rc=$?"' B
c "cd file" 'touch f; cd f; echo "rc=$?"' e
c "cd sets PWD" 'mkdir d; cd d; case $PWD in */d) echo ok;; esac' B
c "cd sets OLDPWD" 'p=$PWD; mkdir d; cd d; [ "$OLDPWD" = "$p" ] && echo ok' B
c "cd HOME" 'HOME=/; cd; pwd' B
c "cd logical symlink" 'mkdir d; ln -s d l; cd l; case $PWD in */l) echo logical;; esac; pwd -P | sed "s#.*/##"' B
c "cd -P physical" 'mkdir d; ln -s d l; cd -P l; case $PWD in */d) echo physical;; esac' B
c "pwd -L -P" 'mkdir d; ln -s d l; cd l; pwd -L | sed "s#.*/##"; pwd -P | sed "s#.*/##"' B
c "cd CDPATH" 'mkdir -p base/sub; CDPATH=base; cd sub > /dev/null; pwd | sed "s#.*/##"' e
c "cd relative stays" 'mkdir d; cd ./d; pwd | sed "s#.*/##"' B
c "cd too many args" 'cd / /tmp; echo "rc=$?"' e
c "umask set and get" 'umask 027; umask' B
c "umask symbolic" 'umask 022; umask -S' B
c "umask affects files" 'umask 077; touch f; ls -l f | cut -c1-10' B
c "wait for pid" 'sh -c "exit 3" & wait $!; echo $?' B
c "wait all" 'sleep 0 & sleep 0 & wait; echo $?' B
c "wait unknown pid" 'wait 99999; echo $?' B
c "kill 0 self-check" 'kill -0 $$; echo $?' B
c "kill signal name" 'sh -c "kill -s TERM \$\$"; echo $?' e
c "kill -l numbers" 'kill -l 15' e
# 999999999 is above any pid_max (Linux caps it at 4194304): these snippets run
# unsandboxed, so they must never name a process that could exist.
c "kill nonexistent" 'kill 999999999 2>/dev/null; echo $?' B
c "kill bad signal" 'kill -s NOSUCH 999999999 2>/dev/null; echo $?' B
c "hash" 'hash ls; echo $?' B
c "hash -r" 'hash -r; echo $?' B
c "alias" 'alias x="echo aliased"; eval x' B
c "alias in next command" 'alias x="echo aliased"
x' B
c "unalias" 'alias x=y; unalias x; alias x; echo $?' e
c "alias not defined" 'alias nosuch; echo $?' e
c "times" 'times | wc -l' B
c "ulimit -n" 'ulimit -n | grep -c "^[0-9]"' B
c "ulimit -f counts 512-byte blocks" '(ulimit -f 7; grep "file size" /proc/self/limits | tr -s " " | cut -d" " -f4)' B
c "ulimit -S -H: the last one wins" '(ulimit -S -H -t 100 2>/dev/null; echo $?; ulimit -H -S -t 100; echo $?; ulimit -t; ulimit -H -t)' B
c "ulimit -H below the soft limit fails" '(ulimit -H -t 100 2>/dev/null; echo $?; ulimit -t)' B
c "ulimit -f unlimited or number" 'ulimit -f | grep -c .' B
c "umask bad" 'umask 999; echo "rc=$?"' e
c "umask symbolic assignment" 'umask 022; umask u=rwx,g=rx,o=; umask; umask -S' BP
c "umask symbolic add and remove" 'umask 077; umask g+rx; umask; umask o+w; umask; umask a-w; umask' B
c "umask symbolic copy" 'umask 022; umask g=u; umask; umask o=g; umask' B
c "umask symbolic bad mode" 'umask q=r; echo "rc=$?"' Be
c "umask -S sets" 'umask -S u=rwx,g=,o=; umask' B
cx "trap -l is accepted" 'trap -l > /dev/null; echo "rc=$?"' Pe "POSIX.1-2024 adds trap -l; dash rejects the option (status 2)."
c "trap in a subshell sees the parent" 'trap "echo bye" EXIT; trap "echo usr" USR1; (trap | sort)' BP "POSIX.1-2024: the subshell reports the parent's traps."
c "trap in command substitution" 'trap "echo a" USR1; x=$(trap); echo "$x"' BP
c "alias ending in a blank expands the next word" 'alias a="echo "
alias b="echo c"
a b' B
c "alias ending in a blank, twice" 'alias a="echo "
alias b=hello
a b b' B
c "alias without a trailing blank" 'alias a="echo"
alias b=hello
a b' B
c "alias blank chain" 'alias a="b "
alias b="echo "
alias c=X
a c c' B
c "alias blank reaches only the next word" 'alias a="echo "
alias b=B
alias c=C
a b c' B
c "alias to nothing on a line of its own" 'alias a=
a
echo y' B
c "alias to nothing ends a pipeline into the next line" 'alias a=
echo foo | a
cat' B
c "alias to a blank before a newline in a pipeline" 'alias b=" "
echo ok | b
cat' B
cx "alias value starting with a redirection after a redirection" 'alias e=" >&- c >/dev/null " c=" echo "
</dev/null e not_printed; echo done' B
c "alias to a here-document operand" 'alias c=" cat << " e=" \END "
c e
here
END' B
c "alias to parentheses on separate lines" "alias l='
(
' r='
)
'
a=A
l echo subshell; a=B; r
echo \$a" B
c "alias to case keywords and ;;" "alias c='case a in a) :' e='
 esac </dev/null | cat -' eb='
 echo B;; '
c X; echo A; e
c X; eb e" B
cx "alias in a case pattern only after a blank" "alias a=b c='case a in '
c a) echo 1-1;; a) echo 1-2;; esac" B
c "alias to ( of a case pattern" "alias c='case a in ' p=' #comment

 (a) echo A; esac'
c p" B
c "alias to | and ) of a case pattern" "alias c='case a in x ' p=' |a) echo A; esac'
c p
alias c='case a in a ' p=' ) echo A; esac'
c p" B
cx "alias to ;;" "alias s=';;'
case a in
    (b) s
    (a) echo A
esac" B
c "alias to the parentheses of a function definition" "alias f='f ' p='()'
f p
{ echo F; }
f
alias g='g( ' q=')'
g q
{ echo G; }
\\g" B
c "alias to the command of a function definition" "alias f='f() ' g=
f g
{ echo F; }
\\f" B
c "alias ending with a blank, nested" "alias c=cat e='echo '
e c c cat
alias c='cat '
e c c cat
alias echo='e x x ' x=.
echo echo
alias x='x . '
echo echo" B
c "alias names joined by line continuations" "alias echo='\\
echo\\
 ' foo='\\
bar\\
' bar=X
echo           \\
foo" B
c "bare exit in a signal trap uses the status of the interrupted command" 'trap "(exit 2); exit" INT
(exit 1)
kill -INT $$' E "POSIX 2.14: the status is that of the last command before the trap action (the kill, 0); FreeBSD sh differs."
c "redirections are performed before assignments are expanded" 'rm -f f2
a=$(cat f2) 3>|$(echo f2) true; echo $?' E "POSIX 2.9.1 (dash); FreeBSD sh expands the assignment first."
c "redirection with assignment on a function and a builtin" 'f() { echo "in f $a"; }
a=2 f >f4; cat f4
a=3 >f5 sh -c "echo \$a"; cat f5' B
c "wait accepts --" 'wait --; echo $?
: &
wait -- $!; echo $?' B
c "command -v quotes an alias value" "alias aa=echo\\ \\'\\\"\\'
cmd=\$(command -v aa)
alias aa=echo\\ bad
eval \"\$cmd\"
[ \"\$(eval aa)\" = \\\" ] && echo same" B
c "command eval of a syntax error does not exit the shell" 'command eval \) 2>/dev/null; echo "after $?"' B
c "a function name is a trap action, not a signal" 'term() { echo got; }; trap term TERM; kill -TERM $$; echo after' B
c "wait for a pipeline job gives the pipefail status" 'set -o pipefail
(exit 42) | : &
wait %+; echo $?' BPe "Issue 8 pipefail; some builds of dash do not have it."
c "background subshell of one command is that command" '(sleep 1)& sleep 0.2; cat /proc/$!/comm; kill $!' B
c "NUL bytes in a script are ignored" 'printf "echo a\0b\n\0echo c\n" > f; . ./f' B
c "a redirection that opens the fd it names is undone" 'touch f; { :; } 3<f; echo x >&3 2>/dev/null; echo $?' B
c "slashes in a globbed path are kept" 'cd /; set -- /etc//pa[s]swd /./et[c]//; echo "$@"' B
cx "alias chain through the for variable and the word list" "alias FOR1='for '
alias FOR2='FOR1 '
alias eye1='i '
alias eye2='eye1 '
alias IN='in '
alias onetwo='\$one \"2\" '
one=1
FOR2 eye2 IN onetwo 3; do echo \$i; done" B
cx "alias for do after the for variable is not applied" "alias forx='for x ' do=';'
set 1
forx do echo \$x; done" B
c "alias in a command substitution in a here-document" 'alias echo_="echo [ "
cat <<EOF
$(echo_ ])
`echo_ ]`
EOF' B
c "trap with a lone condition name resets it" 'trap "echo hi" EXIT; trap EXIT; echo finished' B
c "printf %u and %d at the integer limits" 'for fmt in "%u\n" "%d\n"; do
  printf "$fmt" 18446744073709551615 2>/dev/null; echo status=$?
  printf "$fmt" 18446744073709551616 2>/dev/null; echo status=$?
  printf "$fmt" -18446744073709551615 2>/dev/null; echo status=$?
  printf "$fmt" -18446744073709551616 2>/dev/null; echo status=$?
done' B
c "printf with an invalid directive fails" 'printf "%z" 42 2>/dev/null; [ $? -ne 0 ] && echo failed' B
cx "a number above 9 before a redirection is a word" 'echo hi 99>&1; echo hi 100>/dev/null; echo ok' B
c "duplicating a descriptor onto itself is a no-op" ': 3>&3; echo $?' B
c "a non-digit descriptor operand ends the shell" 'echo one 1>&/nonexistent-filename__; echo not reached' B
c "a duplicated descriptor above 9 ends the shell" 'echo a >&99; echo not reached' B
c "jobs -p prints one process group leader per job" 'sleep 0.1 &
sleep 0.1 | cat &
jobs -p > tmp.txt
wc -l < tmp.txt | tr -d " "; wait' B
c "hash lists the commands remembered by running them" 'whoami > /dev/null; hash | sed "s,.*/,,"; hash -r; hash; echo end' B
c "pwd after the directory was removed prints the logical name" 'mkdir pwdgone; cd pwdgone; rmdir ../pwdgone; pwd | sed "s,.*/,,"; echo status=$?' B
c "cd - without OLDPWD stays put" 'unset OLDPWD; cd - > /dev/null; echo status=$?' E "POSIX leaves it unspecified; dash stays in the current directory, FreeBSD sh fails."
c "OLDPWD is exported by cd" 'cd /; cd /tmp; env | grep OLDPWD' B
c "a builtin that cannot write its output fails" 'type echo > /dev/full 2>/dev/null; echo status=$?' E "dash 1, FreeBSD sh 2; POSIX only asks for non-zero."
c "sh +c is read as -c" 'sh +c "echo hi"' B
cx "heredoc ended by end of input" 'cat <<EOF
abc' B
cx "heredoc ended by end of input after newline" 'cat <<EOF
abc
' B
cx "heredoc end of input, two bodies" 'cat <<EOF; cat <<EOG
one
EOF
two' B
c "printf %f" 'printf "%f %.2f %10.3f|%-10.1f|\n" 3.14159 2.5 1.0005 7' e
c "printf %e" 'printf "%e %.0e %.3E\n" 12345.678 5 0.000123456' e
c "printf %g" 'printf "%g %g %g %.3g %G\n" 100000 1000000 0.0001 3.14159 1e-10' e
c "printf %a" 'printf "%a %A %.2a\n" 1 0.5 3.14159' e
c "printf float rounding" 'printf "%.0f %.0f %.0f %.0f %.1f %.2f\n" 0.5 1.5 2.5 3.5 0.25 1.005' e
c "printf float flags" 'printf "%+f|% f|%08.3f|%-8.2f|%#.0f\n" 1.5 1.5 -1.5 1.5 3' e
c "printf float huge and tiny" 'printf "%f\n%e\n%.20g\n" 1e30 1e-300 0.1' e
c "printf float non-number" 'printf "%f\n" abc; echo "rc=$?"' e
c "printf float partial" 'printf "%f\n" 1.5x; echo "rc=$?"' e
c "printf float char code" "printf '%f\\n' \"'A\"" e
c "printf float inf nan" 'printf "%f %e %g %F\n" inf -inf nan INF' e
c "printf float hex input" 'printf "%f %f\n" 0x10 0x1p-2' e
c "printf float missing argument" 'printf "%f|%e|%g\n"' e

# ---- lexical and grammar corner cases ----
c "semicolon after brace group" '{ echo a; }; echo b' B
c "brace needs space" '{ echo a; } ' B
cx "keyword as argument" 'echo if then fi while' B
c "keyword quoted not keyword" '"if" 2>/dev/null; echo $?' B
c "assignment-looking after command" 'echo a=b' B
cx "assignment with space is command" 'x= echo hi' B
c "empty assignment" 'x=; echo "[$x]"' B
c "assignment before redirect" 'x=1 > f; echo $x; ls f' B
c "number before redirect" 'echo 2>f; ls f' B
c "word with digits before redirect" 'echo a2 > f; cat f' B
c "line continuation in command" 'echo a \
b' B
c "semicolon-less end of line in group" '{
echo a
}' B
c "newline after and-or" 'true &&
echo yes' B
c "newline after pipe" 'echo abc |
tr a-c A-C' B
c "comment after command" 'echo a # c' B
c "comment between commands" 'echo a
# comment
echo b' B
c "empty command line" '
' B
c "only comment" '# nothing' B
cx "unmatched quote" "echo 'abc" e
cx "unmatched dquote" 'echo "abc' e
cx "unexpected paren" 'echo )' e
cx "unexpected fi" 'fi' e
cx "unexpected then" 'then' e
cx "unexpected semicolon" '; echo a' e
cx "unexpected double semicolon" ';; echo a' e
cx "missing fi" 'if true; then echo a' e
cx "missing done" 'while true; do echo a' e
cx "missing esac" 'case a in a) echo x' e
cx "missing brace" '{ echo a' e
cx "missing paren" '( echo a' e
cx "missing then" 'if true; echo a; fi' e
cx "missing do" 'for i in a; echo $i; done' e
cx "bad for variable" 'for 1x in a; do :; done' e
cx "bad function name" '1f() { :; }' e
c "bad substitution" 'echo ${x!}' e
cx "empty if body" 'if true; then fi' e
cx "empty while cond" 'while do :; done' e
cx "redirect without word" 'echo >' e
cx "pipe at end" 'echo a |' e
cx "and at end" 'true &&' e
cx "syntax error stops earlier output kept" 'echo before
fi
echo after' e
cx "heredoc unterminated" 'cat <<EOF
body' Pe
c "bang in middle" 'echo a ! b' B
c "function keyword absent" 'f () { echo ok; }; f' B
cx "case esac as word" 'case esac in esac) echo ok;; esac' B
cx "for in with keywords" 'for i in then do done; do echo $i; done' B
c "nested quotes in cmdsub" 'echo "$(echo "x y" | tr " " "-")"' B
cx "dollar paren paren ambiguity" 'echo $((echo a); (echo b))' e
c "background list" 'true & false & wait' B
c "redirect from cmdsub arg" 'echo $(cat < /dev/null)x' B
c "line number in error" 'echo a
nosuchcmd2' B
c "lineno" 'echo $LINENO' Pe
c "ifs default restored" 'IFS=:; unset IFS; set -- a:b; echo $#' B
c "variable named like keyword" 'if=1; echo $if' B
c "function named like builtin external" 'ls() { echo shadow; }; ls' B
c "tilde after colon assignment only" 'HOME=/h; a=x:~; echo $a' B
c "long pipeline" 'echo x | cat | cat | cat | cat' B
c "many args" 'set -- 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; echo $#; shift 15; echo $1' B
c "big output through pipe" 'i=0; while [ $i -lt 2000 ]; do echo line$i; i=$((i+1)); done | wc -l' B
c "big heredoc" 'cat <<EOF | wc -l
1
2
3
4
5
EOF' B
c "quoted here-doc preserves backslash" 'cat <<"E"
a\nb\\c
E' B
c "exit in cmdsub does not exit" 'x=$(exit 2); echo "alive $?"' B
c "variable in redirection fd" 'echo a >&2 2>/dev/null; echo b' B
c "sh -c nested" 'sh -c "echo nested \$0 \$1" name arg' B
c "sh -c exit status" 'sh -c "exit 5"; echo $?' B
c "sh -s from stdin" 'echo "echo from-stdin" | sh -s' B
c "sh script file" 'echo "echo file \$1" > s; sh s arg' B
c "sh -e" 'sh -e -c "false; echo no"; echo $?' B
c "sh -u" 'sh -u -c "echo \$x"; echo $?' e
c "sh -x" 'sh -x -c "echo x" 2>&1' e
c "sh -n" 'sh -n -c "echo no"; echo $?' B
c "sh -f" 'touch a; sh -f -c "echo *"' B
c "sh -o noglob" 'touch a; sh -o noglob -c "echo *"' B
c "sh +e" 'sh +e -c "false; echo yes"' B
c "sh -c no args" 'sh -c' e
c "sh script missing" 'sh nosuchscript; echo $?' eP "XCU sh, EXIT STATUS: 127 when the command_file cannot be found; dash exits 2."
c "sh -- operand" 'echo "echo ok" > s; sh -- s' B
c "sh -c with dollar zero" 'sh -c "echo \$0" myname' B

# ---- gold-standard audit (tools/sh-gold.sh): cases found by comparing with the dash/FreeBSD agreement ----
c "length of \$# is \${##}" 'set -- 1 2 3 4 5 6 7 8 9 10 11 12; echo ${##}' B "Both dash and FreeBSD sh read \${##} as the length of \$#; POSIX leaves it ambiguous."
c "length of special parameters" 'set -- a; x=$-; echo ${#?} ${#-} ${#x}; [ "${#-}" = "${#x}" ] && echo same' B
c "local without value keeps the value" 'b=g; f() { local b; echo "[$b]"; b=x; }; f; echo "$b"' B "local is not POSIX; dash and FreeBSD sh keep the value."
c "local assignment is not split" 'w="@ @"; f() { local v=$w; echo "[$v]"; }; f' B "local is not POSIX; dash and FreeBSD sh treat v=\$w like an assignment."
c "local - restores options" 'f() { local -; set -a; case $- in *a*) echo in;; esac; }; f; case $- in *a*) echo leaked;; esac' B "local is not POSIX; dash and FreeBSD sh restore the options."
c "command readonly assignment not split" 'x="a b"; \command readonly d=$x; echo "$d"; command command readonly e=$x; echo "$e"' B
c "unset drops the export attribute" 'export U; U=u; unset U; U=new; env | grep -c "^U="' B "POSIX: unset removes the variable; the later assignment creates an unexported one."
c "dollar-at in assignment joins with IFS" 'IFS=:; set -- x "y z"; s=$@; echo "$s"; v="[$@]"; echo "$v"' B "POSIX leaves the separator unspecified (XCU 2.5.2); dash and FreeBSD sh use the first IFS character."
c "null test of dollar-at" 'set -- ""; echo ${@:-m}; set -- "" ""; IFS=; echo "${*:-n}"' B
cx "suffix trim on dollar-at" 'set -- 1a 2a 3a; printf "[%s]" ${@%a}; echo; set -- Q R; printf "[%s]" "${@#Q}"; echo' B "POSIX leaves \${@%pat} unspecified (XCU 2.6.2); dash, FreeBSD sh and busybox ash trim the joined string, bash and yash trim every parameter."
c "tilde after colon in word of default" 'HOME=/h; x=~:${u-~:~}; echo $x; x=${u-a:~}; echo $x; echo ${u-a:~}' B "XCU 2.6.1: tilde expansion applies to the word of \${x-word} and, in an assignment, after colons."
c "command hash is remembered" 'mkdir one two; echo "echo two" > two/mycmd; chmod +x two/mycmd; PATH=one:two:$PATH; mycmd; echo "echo one" > one/mycmd; chmod +x one/mycmd; mycmd; hash -r; mycmd; rm one/mycmd two/mycmd; mycmd 2>/dev/null; echo $?' B "XCU hash: the location found by the first search is remembered until PATH changes or hash -r."
c "hash lists remembered commands" 'cat /dev/null; hash | wc -l | tr -d " "; hash -r; hash | wc -l | tr -d " "' B
c "test -t with a huge number" 'test -t 12345678910; echo $?' B
c "test -t with a non-number" '[ -t x ] 2>/dev/null; echo $?' Be
cx "test with -a and -o as operands" '[ -a -a ]; echo $?; [ -a -a -a ]; echo $?; [ -o -o ]; echo $?; [ -a -a -a -a -a ]; echo $?' B "Undefined by POSIX (XCU test: -a and -o are binary primaries); dash and FreeBSD sh agree."
c "kill -l with a number" 'kill -l 0 2>/dev/null; echo $?; kill -l 128 2>/dev/null; echo $?; kill -l 130' Be
cx "umask numeric and bad forms" 'umask 0124; umask -rwx 2>/dev/null; echo $?; umask; umask 1234567; umask' Be "A numeric mask keeps its permission bits; a mode starting with - is an option error."
c "ulimit extra operand" 'ulimit 1 2 2>/dev/null; echo $?' Be
c "ulimit -a combined with -f" 'ulimit -f -a >/dev/null; echo $?' B
c "getopts with a bad variable name" 'set -- -c foo -h; getopts "hc:" opt- 2>/dev/null; echo "$? [$OPTARG] $OPTIND"' B
c "trap -- takes -l as action" 'trap -- -l USR1; trap' B "XCU 2.14 trap and XBD 12.2 guideline 10: -- ends the options."
c "ENOEXEC script runs in a new shell" 'printf "echo hello \$BLAH\n" > snork; chmod +x snork; BLAH=123; ./snork; BLAH=123 ./snork; BLAH=123 exec ./snork' B "XCU 2.9.1.1: an ENOEXEC file is run by a new shell, which sees only the environment."
c "dot of a directory" 'mkdir d; . ./d; echo $?' B
c "PS4 expansion error is ignored" 'PS4="+ \$(( 1 / 0 )) "; set -x; echo one; echo status=$?' Be
c "pwd of a removed directory" 'mkdir z; cd z; rmdir ../z; pwd >/dev/null 2>&1; echo $?' B
c "glob keeps repeated slashes" 'mkdir -p d; : > d/f; echo ./d//f* .//d/f* d//[f]' B "XCU 2.14.3: slashes in the pattern are matched by slashes; the result keeps the pathname as written."
c "arithmetic variable overflow is an error" 'x=9223372036854775808; (echo $((x))) 2>/dev/null; echo $?; y=-9223372036854775808; echo $((y))' Be "Undefined by POSIX; dash and FreeBSD sh refuse a variable whose value does not fit."
c "command eval syntax error does not exit" 'command eval "( )" 2>/dev/null; echo a$?; command eval "echo hi; )" 2>/dev/null; echo b$?' Be "XCU 2.14: command removes the special properties of eval."
c "errexit applies inside command substitution in a condition" 'set -e; if echo $(echo 1; false; echo 2); then echo A; fi; echo end' B "XCU 2.14 set -e: the -e setting applies to each subshell environment separately."

c "empty quoted field survives an adjacent split expansion" 'set -- a ""; s=" "; set -- "$@"$s; echo $#' B "POSIX 2.6.5: a quoted empty string is a field; dash alone loses it for an empty \$e."
cx "length of dollar-at is the joined length" 'set -- abc de; echo ${#@} ${#*}' B "POSIX leaves \${#@} unspecified (XCU 2.6.2); dash and FreeBSD sh give the length of the joined parameters."
c "null test of two empty parameters" 'set -- "" ""; echo "[${@:-m}]"; set -- ""; echo "[${@:-m}]"' B
c "ulimit -a with an operand" 'ulimit -a 42 >/dev/null 2>&1; echo $?' Be
c "scripts: NUL bytes are ignored" 'printf "echo a\0b\n" > s; . ./s' B "POSIX leaves a script with NUL bytes undefined; dash and FreeBSD sh ignore them."

# ---- EXEMPT section: not POSIX on purpose -----------------------------------
# These probe behaviour POSIX leaves undefined or that bash/ksh scripts rely
# on; they are excluded from the shellcheck hygiene check (shellcheck -s dash
# rightly flags them) and compare only against references where it matters.

# ---- script on standard input is run incrementally (compared with dash only) ----
stdin_case() {
    desc="$1"; input="$2"; shift 2
    shcmp_inner_sh "$OURS"
    printf '%s' "$input" | (cd "$TEST_TMP" && ulimit -f 2000 && PATH="$TEST_TMP/inner:$PATH" timeout -s KILL 20 "$OURS" "$@") > "$TEST_TMP/si.ours" 2>&1; ro=$?
    shcmp_inner_sh /usr/bin/dash
    printf '%s' "$input" | (cd "$TEST_TMP" && PATH="$TEST_TMP/inner:$PATH" /usr/bin/dash "$@") > "$TEST_TMP/si.dash" 2>&1; rd=$?
    sed -e 's#^[^: ]*: [0-9]*: #sh: #' "$TEST_TMP/si.ours" > "$TEST_TMP/si.o2"
    sed -e 's#^[^: ]*: [0-9]*: #sh: #' "$TEST_TMP/si.dash" > "$TEST_TMP/si.d2"
    if [ "$ro" = "$rd" ] && cmp -s "$TEST_TMP/si.o2" "$TEST_TMP/si.d2"; then
        PASS=$((PASS + 1)); printf 'PASS stdin: %s\n' "$desc"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL stdin: %s (ours rc=%s dash rc=%s)\n' "$desc" "$ro" "$rd"
        diff "$TEST_TMP/si.d2" "$TEST_TMP/si.o2" | head -5
    fi
}
if [ -x /usr/bin/dash ] && [ -z "${SHCMP_DUMP:-}" ]; then
    stdin_case "cat in the script sees the buffered rest" 'echo a; cat; echo b
echo c
'
    stdin_case "read consumes nothing already buffered" 'read x
hello
echo got $x
'
    stdin_case "commands before a syntax error run" 'echo one
echo )
echo two
'
    stdin_case "positional parameters with -s" 'echo $# $1 $2; set -- x; echo $1
' -s p q
    stdin_case "function and alias definitions persist" 'alias hi="echo hello"
hi
f() { echo in f; }
f
'
    stdin_case "if spanning lines" 'if true
then echo yes
else echo no
fi
echo done
'
    stdin_case "heredoc in stdin script" 'cat <<EOF
body $((1+1))
EOF
echo after
'
    stdin_case "no trailing newline" 'echo last'
    # alias text left over when a command ends is not script input
    stdin_case "alias with a newline runs once" 'alias two="echo one
echo two"
two
echo three
echo four
'
    stdin_case "alias with a newline does not expand itself again" 'alias echo="echo A
echo B"
echo C
echo done
'
    stdin_case "nested aliases with newlines" 'alias inner="echo i1
echo i2"
alias outer="echo o1
inner
echo o2"
outer
echo end
'
    stdin_case "compound command that starts inside an alias" 'alias c="echo pre
if true; then"
c
  echo body
fi
echo tail
'
    stdin_case "exit status" 'echo x
exit 7
echo not reached
'
    big=$(i=0; while [ $i -lt 3000 ]; do echo "echo line$i"; i=$((i + 1)); done)
    stdin_case "script larger than the read buffer" "$big
"
    stdin_case "cat after the buffer is exhausted" "$big
cat
echo end
"
fi

# ---- a script that cannot be read in full is not run as if it had ended (QUAL-01) ----
if [ -z "${SHCMP_DUMP:-}" ]; then
    desc="unreadable script on standard input is an error"
    err=$("$OURS" < / 2>&1); rc=$?
    case "$rc $err" in
    0\ *) FAIL=$((FAIL + 1)); printf 'FAIL %s: exit 0\n' "$desc" ;;
    *"error reading the script"*) PASS=$((PASS + 1)); printf 'PASS %s\n' "$desc" ;;
    *) FAIL=$((FAIL + 1)); printf 'FAIL %s: rc=%s %s\n' "$desc" "$rc" "$err" ;;
    esac

    desc="failed allocations never run part of a script"
    if strace -o /dev/null -f -e inject=mmap:error=ENOMEM:when=1000 true 2>/dev/null; then
        # one command longer than a read buffer, then another
        { printf 'echo would-delete /srv/data/'; head -c 9000 /dev/zero | tr '\0' a
          printf '/tmp-only\necho second-command\n'; } > "$TEST_TMP/oom.sh"
        bad=""; n=1
        while [ $n -le 40 ]; do
            out=$(strace -o /dev/null -f -e inject=mmap,mremap:error=ENOMEM:when=$n "$OURS" < "$TEST_TMP/oom.sh" 2>/dev/null); rc=$?
            # whatever was printed must be whole commands; success needs both
            part=$(printf '%s\n' "$out" | grep 'would-delete' | grep -cv '/tmp-only$')
            whole=$(printf '%s\n' "$out" | grep -c '/tmp-only$\|^second-command$')
            if [ "$part" != 0 ] || { [ $rc = 0 ] && [ "$whole" != 2 ]; }; then bad="$bad $n(rc=$rc)"; fi
            n=$((n + 1))
        done
        if [ -z "$bad" ]; then PASS=$((PASS + 1)); printf 'PASS %s\n' "$desc"
        else FAIL=$((FAIL + 1)); printf 'FAIL %s: at injection%s\n' "$desc" "$bad"; fi
    else
        skip_case "$desc (strace cannot inject here)"
    fi
fi

SHCMP_EXEMPT=1
c "exempt: local variable" 'f() { local x=1; echo $x; }; f; echo "[$x]"' e "POSIX has no local; dash, bash, busybox, yash all accept it."
c "exempt: echo -e" 'echo -e "a\tb"' e "XSI echo interprets escapes; -e is an option in bash and literal in dash."
c "exempt: double bracket" '[[ a = a ]] && echo yes' e "Not POSIX; dash rejects it."
c "exempt: array" 'a=(1 2 3); echo ${a[1]}' e "Not POSIX."
c "dollar single quote" 'echo $'"'"'a\tb\101\x41'"'" P "POSIX.1-2024 XCU 2.2.4 defines it; dash 0.5.12 prints a literal."
c "exempt: double equals in test" '[ a == a ]; echo $?' Pe "Not POSIX; dash accepts it."
c "exempt: function keyword" 'function f { echo hi; }; f' e "Not POSIX."
c "exempt: source builtin" 'echo "echo s" > s; source ./s' e "Not POSIX; dot is the standard spelling."
c "exempt: string replace" 'x=abc; echo ${x/b/X}' e "Not POSIX."
c "exempt: substring" 'x=abcdef; echo ${x:1:2}' e "Not POSIX."
c "exempt: process substitution" 'cat <(echo hi)' e "Not POSIX."
c "pipefail first stage fails" 'set -o pipefail; false | true; echo $?' Pe "POSIX.1-2024 (Issue 8) adds pipefail; dash 0.5.12 has the name but no effect."
c "pipefail last stage fails" 'set -o pipefail; true | false; echo $?' Pe "Issue 8."
c "pipefail all succeed" 'set -o pipefail; true | true; echo $?' Pe "Issue 8."
c "pipefail reports rightmost failure" 'set -o pipefail; sh -c "exit 3" | sh -c "exit 4" | true; echo $?' Pe "Issue 8: the status is that of the last (rightmost) command that failed."
c "pipefail off again" 'set -o pipefail; set +o pipefail; false | true; echo $?' Pe "Issue 8."
c "pipefail with errexit" 'set -e; set -o pipefail; false | true; echo not reached' Pe "Issue 8."
c "pipefail with negation" 'set -o pipefail; ! false | true; echo $?' Pe "Issue 8."
c "exempt: here-string" 'cat <<< hi' e "Not POSIX."
c "exempt: ampersand redirect" 'echo hi &> f; cat f' e "Not POSIX."
c "exempt: dollar RANDOM" 'echo ${RANDOM:+set}' e "Not POSIX."
unset SHCMP_EXEMPT

[ -n "${SHCMP_DUMP:-}" ] || print_summary

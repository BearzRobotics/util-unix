#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# test_sh.sh - differential tests of `sh` against dash, bash --posix, bash as
# sh, busybox ash, yash and (subset B) FreeBSD sh. See shcmp.sh for the rules.
# Every snippet in the first section is POSIX (shellcheck -s dash clean of
# SC1xxx/SC3xxx; test_sh_lint.sh checks that). Deliberately non-POSIX or
# erroneous snippets live in the clearly marked EXEMPT section at the end.
UTIL="sh"
. "$(dirname "$0")/shcmp.sh"

if [ -n "${SHCMP_DUMP:-}" ]; then
    SHCMP_N=0
    c() { SHCMP_N=$((SHCMP_N + 1)); printf '%s\n' "$2" > "$SHCMP_DUMP/${SHCMP_EXEMPT:+x_}case$SHCMP_N.sh"; }
fi

# ---- quoting ----
c "single quotes" "echo 'a  b \$x'" B
c "double quotes keep spaces" 'echo "a  b"' B
c "backslash outside quotes" 'echo a\ b\\c' B
c "backslash in double quotes" 'echo "a\$b\"c\\d\e"' B
c "backslash newline joins" 'echo a\
b' B
c "double quote and param" 'x=1; echo "[$x]" '"'"'[$x]'"'" B
c "adjacent quoting" 'echo "a"b'"'c'"'d' B
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
c "positional above nine" 'set -- 1 2 3 4 5 6 7 8 9 10 11; echo ${10} ${11} $10' B
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
c "dollar zero from -c" 'echo $0' B
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
c "arith missing operand" 'echo $((1+)); echo after' B
c "arith bad octal" 'echo $((08)); echo after' B
c "arith unmatched paren" 'echo $((1+(2)); echo after' B
c "arith trailing garbage" 'echo $((1 2)); echo after' B
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
c "arith exponent not allowed" 'echo $((2**3)); echo after' B

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
c "glob caret negation" 'touch a1 b1 c1; echo [^a]1' B
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
c "redirect two-digit fd" 'exec 10>f; echo a >&10; exec 10>&-; cat f' Pe
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
c "heredoc empty" 'cat <<EOF
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
c "background and wait" 'echo bg & wait; echo done' B
c "background status wait" '(exit 5) & wait $!; echo $?' B
c "dollar bang" 'true & echo $! | grep -q "^[0-9]" && echo ok; wait' B
c "background no stdin" 'cat & wait; echo done' B
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
c "break more than depth" 'for i in 1 2; do break 5; echo no; done; echo done' B
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
c "case last without terminator" 'case a in a) echo x esac' B
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
c "function default status is last" 'f() { false; }; f; echo $?' B
c "function return no arg" 'f() { false; return; }; f; echo $?' B
c "function recursion" 'f() { if [ $1 -gt 0 ]; then echo $1; f $(($1-1)); fi; }; f 3' B
c "function shares variables" 'f() { x=2; }; x=1; f; echo $x' B
c "function redefine" 'f() { echo 1; }; f() { echo 2; }; f' B
c "function with redirect" 'f() { echo in; }; f > g; cat g' B
c "function calls function" 'a() { b; }; b() { echo b; }; a' B
c "function body compound if" 'f() if true; then echo y; fi; f' B
c "function return in loop" 'f() { for i in 1 2 3; do if [ $i = 2 ]; then return 7; fi; done; }; f; echo $?' B
c "function and special builtin name" 'f() { echo mine; }; f' B
c "function dollar zero" 'f() { echo $0; }; f' B
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
c "set -v" 'set -v; echo hi' e
c "set -f" 'touch a; set -f; echo *' B
c "set -u" 'set -u; echo $nothing; echo after' B
c "set -a" 'set -a; x=1; sh -c "echo \$x"' B
c "set -C" 'set -C; echo a > f; echo b > f; echo $?' B
c "set -o names" 'set -o | grep -c .' e
c "set -o noglob" 'touch a; set -o noglob; echo *' B
c "set -o errexit" 'set -o errexit; false; echo no' B
c "set -o nounset" 'set -o nounset; echo $x; echo no' B
c "set +o prints commands" 'set +o | grep -c "set"' e
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
c "trap reset" 'trap "echo x" EXIT; trap - EXIT; echo done' B
c "trap ignore" 'trap "" EXIT; echo done' B
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
c "trap with wait" '(sleep 1; kill -USR1 $$) & trap "echo got" USR1; wait; echo done' B
c "trap dollar question in handler" 'trap "echo [\$?]" EXIT; false' B
c "trap bad signal" 'trap "echo x" NOSUCHSIG; echo "rc=$?"' e
c "trap EXIT zero" 'trap "echo z" 0; echo main' B
c "trap numeric reset" 'trap "echo x" EXIT; trap 0; echo done' B
c "trap in subshell reset" 'trap "echo parent" USR1; (trap; echo in) ' B

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
c "command -p" 'command -p echo hi' B
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
c "echo dash e is literal" 'echo -e a' e
c "echo dollar paren" 'echo "$(echo a)b"' B
c "printf string" 'printf "%s\n" hello' B
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
c "read -r" 'echo "a\\b" | { read -r x; echo "$x"; }' B
c "read backslash" 'echo "a\\b" | { read x; echo "$x"; }' B
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
c "test bracket missing close" '[ a = a; echo $?' e
c "test bad integer" '[ x -eq 1 ]; echo $?' e
c "test unary operators as strings" '[ -f ]; echo $?; [ -n ]; echo $?' B
c "test two args not" '[ ! x ]; echo $?; [ ! "" ]; echo $?' B
c "test symlink" 'touch f; ln -s f l; [ -L l ]; echo $?; [ -L f ]; echo $?; [ -h l ]; echo $?' B
c "test -nt -ot -ef" 'touch a; sleep 1; touch b; [ b -nt a ]; echo $?; [ a -ot b ]; echo $?; ln a c; [ a -ef c ]; echo $?' B
c "test string with spaces" '[ "a b" = "a b" ]; echo $?' B
c "test empty var needs quotes" 'x=; [ "$x" = "" ]; echo $?' B
c "test special chars" '[ "(" = "(" ]; echo $?; [ "!" = "!" ]; echo $?' B
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
c "cd dot dot" 'mkdir -p a/b; cd a/b; cd ../..; pwd | sed "s#.*/##" | grep -c .' B
c "cd dash prints" 'mkdir d; cd d; cd - >/dev/null; echo $?' B
c "cd nonexistent" 'cd /nonexistent; echo "rc=$?"' B
c "cd file" 'touch f; cd f; echo "rc=$?"' e
c "cd sets PWD" 'mkdir d; cd d; case $PWD in */d) echo ok;; esac' B
c "cd sets OLDPWD" 'p=$PWD; mkdir d; cd d; [ "$OLDPWD" = "$p" ] && echo ok' B
c "cd HOME" 'HOME=/; cd; pwd' B
c "cd logical symlink" 'mkdir d; ln -s d l; cd l; case $PWD in */l) echo logical;; esac; pwd -P | grep -c d' B
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
c "kill nonexistent" 'kill 99999 2>/dev/null; echo $?' B
c "kill bad signal" 'kill -s NOSUCH 1 2>/dev/null; echo $?' B
c "hash" 'hash ls; echo $?' B
c "hash -r" 'hash -r; echo $?' B
c "alias" 'alias x="echo aliased"; eval x' B
c "alias in next command" 'alias x="echo aliased"
x' B
c "unalias" 'alias x=y; unalias x; alias x; echo $?' e
c "alias not defined" 'alias nosuch; echo $?' e
c "times" 'times | wc -l' B
c "ulimit -n" 'ulimit -n | grep -c "^[0-9]"' B
c "ulimit -f unlimited or number" 'ulimit -f | grep -c .' B
c "umask bad" 'umask 999; echo "rc=$?"' e

# ---- lexical and grammar corner cases ----
c "semicolon after brace group" '{ echo a; }; echo b' B
c "brace needs space" '{ echo a; } ' B
c "keyword as argument" 'echo if then fi while' B
c "keyword quoted not keyword" '"if" 2>/dev/null; echo $?' B
c "assignment-looking after command" 'echo a=b' B
c "assignment with space is command" 'x= echo hi' B
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
c "unmatched quote" "echo 'abc" e
c "unmatched dquote" 'echo "abc' e
c "unexpected paren" 'echo )' e
c "unexpected fi" 'fi' e
c "unexpected then" 'then' e
c "unexpected semicolon" '; echo a' e
c "unexpected double semicolon" ';; echo a' e
c "missing fi" 'if true; then echo a' e
c "missing done" 'while true; do echo a' e
c "missing esac" 'case a in a) echo x' e
c "missing brace" '{ echo a' e
c "missing paren" '( echo a' e
c "missing then" 'if true; echo a; fi' e
c "missing do" 'for i in a; echo $i; done' e
c "bad for variable" 'for 1x in a; do :; done' e
c "bad function name" '1f() { :; }' e
c "bad substitution" 'echo ${x!}' e
c "empty if body" 'if true; then fi' e
c "empty while cond" 'while do :; done' e
c "redirect without word" 'echo >' e
c "pipe at end" 'echo a |' e
c "and at end" 'true &&' e
c "syntax error stops earlier output kept" 'echo before
fi
echo after' e
c "heredoc unterminated" 'cat <<EOF
body' e
c "bang in middle" 'echo a ! b' B
c "function keyword absent" 'f () { echo ok; }; f' B
c "case esac as word" 'case esac in esac) echo ok;; esac' B
c "for in with keywords" 'for i in then do done; do echo $i; done' B
c "nested quotes in cmdsub" 'echo "$(echo "x y" | tr " " "-")"' B
c "dollar paren paren ambiguity" 'echo $((echo a); (echo b))' e
c "background list" 'true & false & wait' B
c "redirect from cmdsub arg" 'echo $(cat < /dev/null)x' B
c "line number in error" 'echo a
nosuchcmd2' B
c "lineno" 'echo $LINENO' e
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
c "sh script missing" 'sh nosuchscript; echo $?' e
c "sh -- operand" 'echo "echo ok" > s; sh -- s' B
c "sh -c with dollar zero" 'sh -c "echo \$0" myname' B

# ---- EXEMPT section: not POSIX on purpose -----------------------------------
# These probe behaviour POSIX leaves undefined or that bash/ksh scripts rely
# on; they are excluded from the shellcheck hygiene check (shellcheck -s dash
# rightly flags them) and compare only against references where it matters.
SHCMP_EXEMPT=1
c "exempt: local variable" 'f() { local x=1; echo $x; }; f; echo "[$x]"' e "POSIX has no local; dash, bash, busybox, yash all accept it."
c "exempt: echo -e" 'echo -e "a\tb"' e "XSI echo interprets escapes; -e is an option in bash and literal in dash."
c "exempt: double bracket" '[[ a = a ]] && echo yes' e "Not POSIX; dash rejects it."
c "exempt: array" 'a=(1 2 3); echo ${a[1]}' e "Not POSIX."
c "exempt: dollar single quote" 'echo $'"'"'a\tb'"'" e "POSIX.1-2024 does not require it (Austin Group 249 adds it); dash prints a literal."
c "exempt: double equals in test" '[ a == a ]; echo $?' Pe "Not POSIX; dash accepts it."
c "exempt: function keyword" 'function f { echo hi; }; f' e "Not POSIX."
c "exempt: source builtin" 'echo "echo s" > s; source ./s' e "Not POSIX; dot is the standard spelling."
c "exempt: string replace" 'x=abc; echo ${x/b/X}' e "Not POSIX."
c "exempt: substring" 'x=abcdef; echo ${x:1:2}' e "Not POSIX."
c "exempt: process substitution" 'cat <(echo hi)' e "Not POSIX."
c "exempt: pipefail" 'set -o pipefail; false | true; echo $?' e "POSIX.1-2024 adds pipefail; older shells lack it."
c "exempt: here-string" 'cat <<< hi' e "Not POSIX."
c "exempt: ampersand redirect" 'echo hi &> f; cat f' e "Not POSIX."
c "exempt: dollar RANDOM" 'echo ${RANDOM:+set}' e "Not POSIX."
unset SHCMP_EXEMPT

[ -n "${SHCMP_DUMP:-}" ] || print_summary

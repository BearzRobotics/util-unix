#!/bin/sh
# chmod: differential tests against GNU chmod 9.7 (C locale) using run_tree
# (modes are part of the compared tree).
UTIL="chmod"
. "$(dirname "$0")/testlib.sh"
S='echo A > f; echo B > g; mkdir d; echo C > d/c; chmod 640 f; chmod 600 g; chmod 750 d; chmod 644 d/c; ln -s f sl; ln -s d sd; ln -s nowhere dang; touch x; chmod 4755 x; mkdir sg; chmod 2775 sg; mkdir st; chmod 1777 st'
printf "\n[ Octal modes ]\n"
for m in 0 1 7 70 644 755 600 4755 2755 1777 7777 0644 00644 000644 12345 8 78 9 777777; do
    run_tree "chmod $m f"          "$S" $m f
    run_tree "chmod $m d"          "$S" $m d
done
run_tree "chmod 755 setuid file"   "$S" 755 x
run_tree "chmod 644 setgid dir"    "$S" 644 sg
run_tree "chmod 0644 setgid dir"   "$S" 0644 sg
run_tree "chmod 00644 setgid dir"  "$S" 00644 sg
run_tree "chmod 755 sticky dir"    "$S" 755 st
run_tree "chmod 0755 sticky dir"   "$S" 0755 st
printf "\n[ Symbolic modes ]\n"
for m in u+x g-r o=r a+w +x -x =r =rwx u=rw,g=r,o= u+rw,g+r a=u g=u o=g u-x,g+x u=g+w a-rwx ug+s o+t u+s u-s g+s g-s a+t a-t +X a+X u+X go-w a+rX ug=rwX o-rwx,u+x 'u +x' u+ u= =  +r,-w ugo+x ao+x u=rwxs u+rx,g-w,o=r a=rwxst X u+X+x u+x-x u=r+w, ,u+x u+x, ug,u+x z+x u+z rw 'u=rw g=r'; do
    run_tree "chmod $m f"          "$S" "$m" f
    run_tree "chmod $m d"          "$S" "$m" d
done
run_tree "chmod u+x x (setuid)"    "$S" u+x x
run_tree "chmod u-s x"             "$S" u-s x
run_tree "chmod g-s sg"            "$S" g-s sg
run_tree "chmod =rwx sg"           "$S" =rwx sg
run_tree "chmod -t st"             "$S" -t st
run_tree "chmod u=g on f"          "$S" u=g f
run_tree "chmod a=o on d"          "$S" a=o d
printf "\n[ Umask interplay ]\n"
for um in 000 022 077 027 002; do
    for m in +x +w -r =rw a+w g+w o+r '+rw,-x' =x; do
        TREE_UMASK=$um run_tree "umask $um chmod $m" "$S" $m f
    done
done
printf "\n[ Several files, verbose, quiet ]\n"
run_tree "two files"               "$S" 600 f g
run_tree "missing file"            "$S" 600 nofile
run_tree "missing among good"      "$S" 600 f nofile g
run_tree "-f missing"              "$S" -f 600 nofile
run_tree "-f good"                 "$S" -f 600 f
run_tree "--quiet missing"         "$S" --quiet 600 nofile
run_tree "--silent missing"        "$S" --silent 600 nofile
run_tree "-v change"               "$S" -v 600 f
run_tree "-v no change"            "$S" -v 640 f
run_tree "-v several"              "$S" -v 600 f g d
run_tree "-c change"               "$S" -c 600 f
run_tree "-c no change"            "$S" -c 640 f
run_tree "-c several"              "$S" -c 640 f g d
run_tree "-vc"                     "$S" -vc 600 f
run_tree "-cv"                     "$S" -cv 600 f
run_tree "--verbose"               "$S" --verbose 600 f
run_tree "--changes"               "$S" --changes 600 f
run_tree "-v setuid change"        "$S" -v 4755 f
run_tree "-v sticky"               "$S" -v 1777 f
run_tree "-v sgid"                 "$S" -v 2755 d
run_tree "-v symbolic"             "$S" -v u+x,g-r f
run_tree "-v name with space"      'echo A > "a b"' -v 600 "a b"
run_tree "-v name with quote"      "echo A > \"it's\"" -v 600 "it's"
printf "\n[ Reference ]\n"
run_tree "--reference"             "$S" --reference=g f
run_tree "--reference dir"         "$S" --reference=d f
run_tree "--reference setuid"      "$S" --reference=x f
run_tree "--reference missing"     "$S" --reference=nofile f
run_tree "--reference symlink"     "$S" --reference=sl g
run_tree "--reference several"     "$S" --reference=g f d c 2>/dev/null
run_tree "--reference arg sep"     "$S" --reference g f
run_tree "--reference and mode"    "$S" --reference=g 600 f
run_tree "--reference no files"    "$S" --reference=g
printf "\n[ Recursive ]\n"
R='mkdir -p t/a/b t/c; echo 1 > t/f1; echo 2 > t/a/f2; echo 3 > t/a/b/f3; ln -s ../f1 t/a/sl; ln -s a t/dl; ln -s t tl; chmod 644 t/f1 t/a/f2 t/a/b/f3; chmod 755 t t/a t/a/b t/c'
run_tree "-R 700"                  "$R" -R 700 t
run_tree "-R u+x"                  "$R" -R u+x t
run_tree "-R go-rwx"               "$R" -R go-rwx t
run_tree "-R a+X"                  "$R" -R a+X t
run_tree "-R -v"                   "$R" -Rv 600 t
run_tree "-R -c"                   "$R" -Rc 700 t
run_tree "-R symlink arg default"  "$R" -R 700 tl
run_tree "-R -H symlink arg"       "$R" -RH 700 tl
run_tree "-R -L symlink arg"       "$R" -RL 700 tl
run_tree "-R -P symlink arg"       "$R" -RP 700 tl
run_tree "-R -L tree"              "$R" -RL 700 t
run_tree "-R -P tree"              "$R" -RP 700 t
run_tree "-R -h"                   "$R" -Rh 700 t
run_tree "-R on file"              "$R" -R 700 t/f1
run_tree "-R missing"              "$R" -R 700 nofile
run_tree "--recursive"             "$R" --recursive 700 t
run_tree "-R dangling in tree"     'mkdir t; ln -s nowhere t/dang; touch t/f' -R 700 t
run_tree "-R unreadable subdir"    'mkdir -p t/u; touch t/u/f; chmod 000 t/u' -R 755 t
run_tree "-R --preserve-root /"    "$R" -R --preserve-root 700 /
run_tree "-R --preserve-root /."   "$R" -R --preserve-root 700 /.
run_tree "--preserve-root not rec" "$R" --preserve-root 700 t
printf "\n[ Symbolic links ]\n"
run_tree "symlink arg"             "$S" 600 sl
run_tree "symlink to dir arg"      "$S" 700 sd
run_tree "dangling symlink arg"    "$S" 600 dang
run_tree "-h symlink"              "$S" -h 600 sl
run_tree "-h dangling"             "$S" -h 600 dang
run_tree "--no-dereference"        "$S" --no-dereference 600 sl
run_tree "--dereference"           "$S" --dereference 600 sl
run_tree "-v symlink"              "$S" -v 600 sl
run_tree "-v dangling"             "$S" -v 600 dang
printf "\n[ Option forms and errors ]\n"
run_tree "mode that looks like option -x"   "$S" -x f
run_tree "-w mode"                 "$S" -w f
run_tree "-rwx mode"               "$S" -rwx f
run_tree "-- then mode"            "$S" -- 600 f
run_tree "-- then -x"              "$S" -- -x f
run_tree "mode only"               "$S" 600
run_tree "no operand"              "$S"
run_tree "bad mode"                "$S" 999 f
run_tree "bad mode u+q"            "$S" u+q f
run_tree "empty mode"              "$S" '' f
run_tree "--bogus"                 "$S" --bogus 600 f
run_tree "-y"                      "$S" -y 600 f
run_tree "--reference missing arg" "$S" 600 f --reference
run_tree "permission denied dir"   'mkdir d; touch d/f; chmod 000 d' 600 d/f
run_tree "file owned by root"      "$S" 600 /etc/passwd
run_tree "name with space"         'echo A > "a b"' 600 "a b"
print_summary

\ prelude.f -- everything that can be Forth, on top of 13-ans-primitives.s
\ Rules: comments only on their own lines, or as ( ... ) groups; lines < 250 chars;
\ no ( or backslash inside names or strings (the REPL eats them).

\ ---- control flow ----
: begin here @ ; immediate
: until ' 0branch , , ; immediate
: again ' branch , , ; immediate
: if ' 0branch , here @ 0 , ; immediate
: then here @ swap ! ; immediate
: else ' branch , here @ 0 , swap here @ swap ! ; immediate
: while ' 0branch , here @ 0 , swap ; immediate
: repeat ' branch , , here @ swap ! ; immediate
: do ' xdo , here @ ; immediate
: loop ' xloop , , ; immediate
: +loop ' xplusloop , , ; immediate

\ ---- compiling words ----
: [ 0 state ! ; immediate
: ] 1 state ! ;
: literal ' lit , , ; immediate
: recurse latest @ >cfa , ; immediate

\ ---- defining words ----
: variable create 0 , ;
: constant create , docon latest @ >cfa ! ;
: does> ' xdoes , ; immediate
: align here @ 3 + -4 and here ! ;
: c, here @ c! 1 allot ;
32 constant bl

\ ---- arithmetic ----
: u/mod 0 swap um/mod ;
: /mod over >r 2dup xor >r abs swap abs swap u/mod r> 0< if negate then swap r> 0< if negate then swap ;
: / /mod nip ;
: mod /mod drop ;
: 0> 0 > ;
: move >r 2dup u< if r> cmove> else r> cmove then ;

\ ---- output ----
variable base
10 base !
: decimal 10 base ! ;
: hex 16 base ! ;
: type begin dup while over c@ emit swap 1+ swap 1- repeat 2drop ;
: space 32 emit ;
: spaces begin dup 0> while space 1- repeat drop ;
: cr 13 emit 10 emit ;
: count dup 1+ swap c@ ;
variable hld
: <# pad 128 + hld ! ;
: hold hld @ 1- dup hld ! c! ;
: digit dup 9 > if 7 + then 48 + ;
: ud/mod >r 0 r@ um/mod r> swap >r um/mod r> ;
: # base @ ud/mod rot digit hold ;
: #s begin # 2dup or 0= until ;
: #> 2drop hld @ pad 128 + over - ;
: sign 0< if 45 hold then ;
: u. 0 <# #s #> type space ;
: . dup abs 0 <# #s rot sign #> type space ;

\ ---- strings ----
: s, dup , here @ swap dup allot cmove align ;
: s" 34 parse ' litstring , s, ; immediate
: ." 34 parse ' litstring , s, ' type , ; immediate

\ ---- dictionary ----
: find dup count find-name ?dup if nip dup >cfa swap 4 + c@ 128 and if 1 else -1 then else 0 then ;
: forget parse-name find-name ?dup 0= if abort then dup 0x20000000 u< if abort then dup @ latest ! here ! ;

\ ---- debugging ----
: depth s0 sp@ - 2/ 2/ 1- ;
: .s depth ?dup if 0 do s0 i 1+ cells - @ . loop then ;
: nib 15 and dup 9 > if 7 + then 48 + emit ;
: b. dup 4 rshift nib nib space ;
: w. 28 begin 2dup rshift nib 4 - dup 0< until 2drop space ;
: dump ?dup if 0 do i 15 and 0= if cr dup i + w. then dup i + c@ b. loop then drop ;

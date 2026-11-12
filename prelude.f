\ prelude.f -- Forth words that are still being developed.
\ The former contents of this file now live in flash: 15 words as machine code
\ in src/08-primitives.s, the rest as threads in src/10-forth-words.s.
\ Words typed here (or at the console) are compiled into RAM; the tests load
\ this file before they run. Move a word into flash once it is stable.
\ Rules: comments only on their own lines, or as ( ... ) groups; lines < 250 chars;
\ no ( or backslash inside names or strings (the REPL eats them).

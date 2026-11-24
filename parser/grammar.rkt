#lang brag

; grammar.rkt — the grammar of the SQL on FHIR source language. THIS FILE IS THE DEFINITION:
; LANGUAGE.md prints these rules (tests/language-test.rkt holds the two to the same text) and
; says what each means; parser/lexer.rkt makes the tokens; compile.rkt reads the tree.
;
; Upper-case names are tokens: the keywords, and WORD NUMBER STRING QUOTED BACKTICK ATLIT SYMBOL EQ.
; A `/` before a token drops it from the tree (it is still required in the text).

sof-file    : (view /";")* [view]
view        : [header] [declare] query
header      : /CREATE /VIEW [name] [options] /AS
name        : WORD | BACKTICK
options     : /WITH /"(" option (/"," option)* /")"
option      : WORD /EQ value
value       : STRING | QUOTED | NUMBER | SYMBOL NUMBER | WORD | array | object
array       : /"[" [value (/"," value)*] /"]"
object      : /"{" [member (/"," member)*] /"}"
member      : (WORD | STRING | QUOTED) /":" value
declare     : /DECLARE constant (/"," constant)*
constant    : name [WORD] /EQ literal
literal     : STRING | NUMBER | SYMBOL NUMBER | WORD | ATLIT
query       : /SELECT [items] /FROM WORD [conditions]
conditions  : /WHERE condition (/AND condition)*
condition   : path [description]
items       : item (/"," item)*
item        : column | nested | union
nested      : /"(" select /")"
union       : /"(" select (/UNION /ALL select)+ /")"
select      : /SELECT [items] [source]
source      : /FROM each | /FROM /REPEAT repeat
each        : path [OR NULL]
repeat      : path (/"," path)*
column      : path [/AS name] (type | collection | description | tag)*
type        : /TYPE (WORD (SYMBOL WORD)* | STRING)
collection  : [NOT] COLLECTION
description : /DESCRIPTION STRING
tag         : /TAG STRING /EQ STRING
path        : ptok+ | QUOTED
ptok        : WORD | NUMBER | STRING | BACKTICK | ATLIT | SYMBOL | EQ | group
group       : "(" inner* ")" | "[" inner* "]" | "{" inner* "}"
inner       : ptok | "," | ":"

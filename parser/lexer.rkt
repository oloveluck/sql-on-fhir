#lang racket/base

;;; lexer.rkt — the tokens of the SQL on FHIR source language (LANGUAGE.md, "Lexical structure").
;;;
;;; The language is SQL's clauses with FHIRPath between them. The two do not meet, by one rule:
;;; THE LANGUAGE'S KEYWORDS ARE WRITTEN IN CAPITALS, and FHIRPath's own (`as`, `and`, `or`, `is`,
;;; `in`) are lower case. So `value as Quantity AS quantity` is a path and its column name.
;;;
;;; Data definitions.
;;; A Tok is (tok type text start end line column gap index)
;;;   type   : a keyword's symbol ('SELECT …), one of 'WORD 'NUMBER 'STRING 'QUOTED 'BACKTICK
;;;            'ATLIT 'SYMBOL 'EQ, or a punctuation mark's own string: "(" ")" "[" "]" "{" "}"
;;;            "," ":" ";"
;;;   text   : the token as written (a string with its quotes)
;;;   start, end : its place in the text, as offsets from 0 (end is one past its last character)
;;;   line, column : where it starts; lines from 1, columns from 0 (as brag counts)
;;;   gap    : what stands between it and the token before WHEN BOTH ARE OF ONE PATH: "" when they
;;;            touch, the white space as written, or one space when a line break or a comment came
;;;            between (a path's text is its tokens joined by their gaps: `path-text`)
;;;   index  : its place among the tokens, from 0

(require racket/list racket/string
         (only-in fhir/diagnostic diagnostic loc exn:fail:diagnostic))

(provide (struct-out tok) keywords tokenize path-text keyword-word? string-value quoted-value
         backtick-value number-value)

(struct tok (type text start end line column gap index) #:transparent)

;; keywords : (Listof String)   the reserved words, each written in capitals. A word after a `.` or
;; a `%` is no keyword (an element or a constant of that name); neither is one inside quotes.
(define keywords
  '("CREATE" "VIEW" "WITH" "AS" "DECLARE" "SELECT" "FROM" "REPEAT" "OR" "NULL" "UNION" "ALL"
    "WHERE" "AND" "TYPE" "COLLECTION" "NOT" "DESCRIPTION" "TAG"))
(define (keyword-word? s) (and (member s keywords) #t))

(define punctuation '(#\( #\) #\[ #\] #\{ #\} #\, #\: #\;))
(define symbol-chars (string->list ".+-*/|&~!<>$%^?"))

;; lex-error : source line column position format value … -> raises a lex diagnostic
(define (lex-error source line column position fmt . args)
  (define msg (apply format fmt args))
  (raise (exn:fail:diagnostic msg (current-continuation-marks)
                              (diagnostic 'sql-on-fhir 'lex 'error msg (loc source line (add1 column) (add1 position) 1)))))

;; tokenize : string [source] -> (Vectorof Tok)   raises a lex diagnostic at text that is no token
(define (tokenize text [source #f])
  (define n (string-length text))
  (define (at i) (and (< i n) (string-ref text i)))
  (define (word-char? c) (and c (or (char<=? #\a c #\z) (char<=? #\A c #\Z) (char<=? #\0 c #\9) (char=? c #\_))))
  (define (digit? c) (and c (char<=? #\0 c #\9)))
  ;; closing : i quote line column -> the offset one past the closing quote; a backslash keeps the
  ;; character after it
  (define (closing i quote line column what)
    (let loop ([j (add1 i)])
      (cond [(>= j n) (lex-error source line column i "this ~a does not end: it needs a closing ~a" what quote)]
            [(char=? (at j) #\\) (loop (+ j 2))]
            [(char=? (at j) quote) (add1 j)]
            [else (loop (add1 j))])))
  (let loop ([i 0] [line 1] [column 0] [space ""] [broken? #f] [acc '()])
    ;; emit : type end -> the loop past the token ending at `end`
    (define (emit type end)
      (define t (tok type (substring text i end) i end line column (if broken? " " space) (length acc)))
      (define-values (line* column*)
        (for/fold ([l line] [c column]) ([ch (in-string text i end)])
          (if (char=? ch #\newline) (values (add1 l) 0) (values l (add1 c)))))
      (loop end line* column* "" #f (cons t acc)))
    (define c (at i))
    (cond
      [(not c) (list->vector (reverse acc))]
      [(char=? c #\newline) (loop (add1 i) (add1 line) 0 space #t acc)]
      [(char-whitespace? c) (loop (add1 i) line (add1 column) (string-append space (string c)) broken? acc)]
      ;; comments: `--` and `//` to the end of the line, `/* … */`
      [(or (and (char=? c #\-) (eqv? (at (add1 i)) #\-)) (and (char=? c #\/) (eqv? (at (add1 i)) #\/)))
       (define end (let scan ([j i]) (if (or (>= j n) (char=? (at j) #\newline)) j (scan (add1 j)))))
       (loop end line (+ column (- end i)) space #t acc)]
      [(and (char=? c #\/) (eqv? (at (add1 i)) #\*))
       (define end (let scan ([j (+ i 2)])
                     (cond [(>= j n) (lex-error source line column i "this comment does not end: it needs a closing */")]
                           [(and (char=? (at j) #\*) (eqv? (at (add1 j)) #\/)) (+ j 2)]
                           [else (scan (add1 j))])))
       (define-values (line* column*)
         (for/fold ([l line] [col column]) ([ch (in-string text i end)])
           (if (char=? ch #\newline) (values (add1 l) 0) (values l (add1 col)))))
       (loop end line* column* space #t acc)]
      [(char=? c #\') (emit 'STRING (closing i #\' line column "string"))]
      [(char=? c #\") (emit 'QUOTED (closing i #\" line column "quoted text"))]
      [(char=? c #\`) (emit 'BACKTICK (closing i #\` line column "quoted name"))]
      ;; a FHIRPath date, dateTime or time literal: @2024-01-31, @2024-01-31T09:00:00Z, @T09:00
      [(and (char=? c #\@) (let ([d (at (add1 i))]) (or (digit? d) (eqv? d #\T))))
       (emit 'ATLIT (let scan ([j (add1 i)]) (if (and (at j) (or (digit? (at j)) (memv (at j) '(#\T #\: #\. #\+ #\- #\Z)))) (scan (add1 j)) j)))]
      [(digit? c)
       (define int-end (let scan ([j i]) (if (digit? (at j)) (scan (add1 j)) j)))
       (define frac-end (if (and (eqv? (at int-end) #\.) (digit? (at (add1 int-end))))
                            (let scan ([j (add1 int-end)]) (if (digit? (at j)) (scan (add1 j)) j))
                            int-end))
       (define exp-end
         (let* ([e (at frac-end)] [s (at (add1 frac-end))]
                [digits (and e (memv e '(#\e #\E)) (if (and s (memv s '(#\+ #\-))) (+ frac-end 2) (add1 frac-end)))])
           (if (and digits (digit? (at digits))) (let scan ([j digits]) (if (digit? (at j)) (scan (add1 j)) j)) frac-end)))
       (emit 'NUMBER exp-end)]
      [(word-char? c)
       (define end (let scan ([j i]) (if (word-char? (at j)) (scan (add1 j)) j)))
       (define word (substring text i end))
       (define after-dot? (and (> i 0) (memv (at (sub1 i)) '(#\. #\%))))
       (emit (if (and (keyword-word? word) (not after-dot?)) (string->symbol word) 'WORD) end)]
      [(char=? c #\=) (emit 'EQ (add1 i))]
      [(memv c punctuation) (emit (string c) (add1 i))]
      [(memv c symbol-chars) (emit 'SYMBOL (add1 i))]
      [else (lex-error source line column i "unrecognized text `~a`"
                       (car (string-split (substring text i (min n (+ i 20))) #:trim? #f #px"\\s")))])))

;; path-text : (Vectorof Tok) first-index last-index -> string   a path as its tokens say it: each
;; as written, joined by the gaps between them (comments left out, a line break one space)
(define (path-text toks first last)
  (apply string-append
         (tok-text (vector-ref toks first))
         (for/list ([i (in-range (add1 first) (add1 last))])
           (define t (vector-ref toks i))
           (string-append (tok-gap t) (tok-text t)))))

;; ---- what a token says --------------------------------------------------------------------------
;; string-value : string -> string | #f   a 'STRING (or, among values, a 'QUOTED) token's text as
;; the string it writes: FHIRPath's escapes (\' \" \` \\ \/ \f \n \r \t \uXXXX) and JSON's \b;
;; #f when it holds another
(define (string-value text)
  (define body (substring text 1 (sub1 (string-length text))))
  (let loop ([cs (string->list body)] [acc '()])
    (cond
      [(null? cs) (list->string (reverse acc))]
      [(not (char=? (car cs) #\\)) (loop (cdr cs) (cons (car cs) acc))]
      [(null? (cdr cs)) #f]
      [else
       (define e (cadr cs))
       (define plain (assv e '((#\' . #\') (#\" . #\") (#\` . #\`) (#\\ . #\\) (#\/ . #\/)
                               (#\f . #\page) (#\n . #\newline) (#\r . #\return) (#\t . #\tab) (#\b . #\backspace))))
       (cond [plain (loop (cddr cs) (cons (cdr plain) acc))]
             [(and (char=? e #\u) (>= (length cs) 6) (string->number (list->string (take (cddr cs) 4)) 16))
              => (lambda (code) (loop (list-tail cs 6) (cons (integer->char code) acc)))]
             [else #f])])))

;; quoted-value : string -> string   a 'QUOTED token's text as the path it holds, as is: `\"` is a
;; double quote, `\\` a backslash, and any other backslash stands for itself (FHIRPath's own)
(define (quoted-value text)
  (define body (substring text 1 (sub1 (string-length text))))
  (regexp-replace* #rx"\\\\([\\\\\"])" body "\\1"))

;; backtick-value : string -> string | #f   a 'BACKTICK token's text as the name it quotes
(define (backtick-value text)
  (string-value text))

;; number-value : string -> number   a 'NUMBER token's text as JSON reads it: digits alone an exact
;; integer, anything else a decimal
(define (number-value text)
  (if (regexp-match? #px"^[0-9]+$" text) (string->number text) (exact->inexact (string->number text))))

(module+ test
  (require rackunit (only-in fhir/diagnostic exn:fail:diagnostic? exn:fail:diagnostic-diagnostic
                             diagnostic-message diagnostic-loc loc-line loc-column))
  (define (types s) (for/list ([t (in-vector (tokenize s))]) (tok-type t)))
  (define (texts s) (for/list ([t (in-vector (tokenize s))]) (tok-text t)))
  ;; keywords are the capitalised words; lower case, after a dot or a %, they are words
  (check-equal? (types "SELECT gender FROM Patient") '(SELECT WORD FROM WORD))
  (check-equal? (types "select value as Quantity AS q") '(WORD WORD WORD WORD AS WORD))
  (check-equal? (types "a.TYPE %NULL") '(WORD SYMBOL WORD SYMBOL WORD))
  ;; strings, quoted text and quoted names keep their quotes; a backslash keeps what follows it
  (check-equal? (texts "'it\\'s' \"a \\\" b\" `TYPE`") '("'it\\'s'" "\"a \\\" b\"" "`TYPE`"))
  (check-equal? (types "'x' \"y\" `z` @2024-01-31T09:00:00Z @T09:00 1 2.5 1e-7 =")
                '(STRING QUOTED BACKTICK ATLIT ATLIT NUMBER NUMBER NUMBER EQ))
  (check-equal? (types "name.where(use = 'official')[0], {}: ;")
                '(WORD SYMBOL WORD "(" WORD EQ STRING ")" "[" NUMBER "]" "," "{" "}" ":" ";"))
  ;; comments are no tokens
  (check-equal? (texts "a -- one\n b // two\n /* three\n four */ c") '("a" "b" "c"))
  ;; where a token stands, and the gap before it
  (define ts (tokenize "id,\n  name . family /* c */ .first()"))
  (check-equal? (for/list ([t (in-vector ts)]) (list (tok-line t) (tok-column t))) '((1 0) (1 2) (2 2) (2 7) (2 9) (2 24) (2 25) (2 30) (2 31)))
  (check-equal? (path-text ts 2 8) "name . family .first()")
  (check-equal? (path-text (tokenize "a\n   and b") 0 2) "a and b")
  ;; values
  (check-equal? (string-value "'a\\'b\\n\\u0041'") "a'b\nA")
  (check-false (string-value "'a\\qb'"))
  (check-equal? (quoted-value "\"name.where(family = 'O\\'Brien') \\\"x\\\" \\\\\"") "name.where(family = 'O\\'Brien') \"x\" \\")
  (check-equal? (number-value "12") 12)
  (check-equal? (number-value "1.50") 1.5)
  ;; what is no token: where it starts, and what it is
  (define (lex-error s)
    (with-handlers ([exn:fail:diagnostic? (lambda (e) (define d (exn:fail:diagnostic-diagnostic e))
                                            (list (diagnostic-message d) (loc-line (diagnostic-loc d)) (loc-column (diagnostic-loc d))))])
      (tokenize s) #f))
  (check-equal? (lex-error "SELECT a\nFROM #x") '("unrecognized text `#x`" 2 6))
  (check-equal? (lex-error "SELECT 'abc") '("this string does not end: it needs a closing '" 1 8))
  (check-equal? (lex-error "/* open") '("this comment does not end: it needs a closing */" 1 1)))

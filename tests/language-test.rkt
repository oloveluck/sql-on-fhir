#lang racket/base

;;; language-test.rkt — LANGUAGE.md, the definition of the source language, held to the code, and
;;; the code held to the law the document states.
;;;
;;;   the document: its grammar is parser/grammar.rkt's, rule for rule; its keywords and constant
;;;     types are the lexer's and the compiler's (and the types the IG's definition gives a
;;;     constant); every example compiles to the JSON shown after it and is a view; every error
;;;     example gives the message shown; its table of elements leaves out none of the IG's.
;;;   the law (LANGUAGE.md, section 7): a view decompiled and compiled again is the view — over the
;;;     shared suite's views, the IG's own examples, the document's examples, and views grown at
;;;     random from every shape a select can take.

(require rackunit racket/list racket/string racket/file racket/runtime-path json
         (only-in fhir/package read-package)
         (only-in fhir/diagnostic exn:fail:diagnostic? exn:fail:diagnostic-diagnostic diagnostic-message diagnostic-loc loc-line loc-column)
         (only-in sql-on-fhir/target ig-package)
         (only-in "harness.rkt" suite-files)
         "../features.rkt" "../compile.rkt" "../decompile.rkt" "../sof.rkt"
         (only-in "../parser/lexer.rkt" keywords)
         (only-in "../definition.rkt" read-view)
         (only-in "../operations.rkt" view-rows))

(define-runtime-path document "../LANGUAGE.md")
(define-runtime-path grammar-file "../parser/grammar.rkt")
(define text (file->string document))

;; fenced : (listof (cons tag content))   the document's fenced blocks, in order: what follows the
;; opening ``` on its line, and the lines up to the closing one
(define fenced
  (let loop ([lines (string-split text "\n" #:trim? #f)] [acc '()])
    (cond [(null? lines) (reverse acc)]
          [(regexp-match #px"^```(.*)$" (car lines))
           => (lambda (m)
                (define-values (body rest) (splitf-at (cdr lines) (lambda (l) (not (equal? l "```")))))
                (loop (if (pair? rest) (cdr rest) '())
                      (cons (cons (cadr m) (string-append (string-join body "\n") "\n")) acc)))]
          [else (loop (cdr lines) acc)])))
;; blocks : tag -> (listof string)   the blocks of that kind
(define (blocks tag) (for/list ([b (in-list fenced)] #:when (equal? (car b) tag)) (cdr b)))
;; pairs : tag tag -> (listof (cons string string))   each block of the first kind with the block
;; of the second kind that is the next block after it
(define (pairs first second)
  (for/list ([b (in-list fenced)] [next (in-list (if (pair? fenced) (cdr fenced) '()))]
             #:when (and (equal? (car b) first) (equal? (car next) second)))
    (cons (cdr b) (cdr next))))
(define (words block) (string-split block))

;; ---- the document is the code's -------------------------------------------------------------------
(test-case "the grammar of section 4 is parser/grammar.rkt, rule for rule"
  (define (rules lines) (for/list ([l (in-list lines)] #:unless (regexp-match? #px"^\\s*(;|#lang|$)" l)) (string-normalize-spaces l)))
  (define from-file (rules (map (lambda (l) (regexp-replace* #px"/(?=[\"A-Z(])" l "")) (file->lines grammar-file))))
  (check-equal? (rules (string-split (car (blocks "ebnf")) "\n")) from-file)
  (check-true (> (length from-file) 30)))

(test-case "the keywords and the constant types are the lexer's and the compiler's"
  (define plain (map words (blocks "")))
  (check-true (and (member keywords plain) #t) "section 3.2 lists the lexer's keywords, in its order")
  (check-true (and (member constant-types plain) #t) "section 5.7 lists the compiler's constant types"))

(define-values (_manifest ig-resources ig-examples) (read-package ig-package))
(define definition
  (for/first ([r (in-list ig-resources)] #:when (and (equal? (hash-ref (cdr r) 'resourceType #f) "StructureDefinition") (equal? (hash-ref (cdr r) 'id #f) "ViewDefinition")))
    (cdr r)))

(test-case "the constant types are the ones the IG's definition gives a constant's value"
  (check-equal? (sort constant-types string<?)
                (sort (for*/list ([e (in-list (hash-ref (hash-ref definition 'snapshot) 'element))]
                                  #:when (equal? (hash-ref e 'path) "ViewDefinition.constant.value[x]")
                                  [t (in-list (hash-ref e 'type))])
                        (hash-ref t 'code))
                      string<?)))

(define examples (pairs "sof" "json"))
(test-case "every example compiles to the JSON shown after it, and is a view"
  (check-true (>= (length examples) 12))
  (check-equal? (length examples) (length (blocks "sof")) "an example without its JSON")
  (for ([e (in-list examples)])
    (define compiled (sof->views (car e)))
    (check-equal? compiled (list (string->jsexpr (cdr e)))
                  (format "~a\ncompiles to\n~a" (car e) (jsexpr->string (car compiled))))
    (check-not-exn (lambda () (read-sof (car e))) (car e))
    (check-not-exn (lambda () (view-rows (car compiled) '())) (car e))))

(test-case "every error example gives the message shown"
  (define refused (pairs "sof-refused" "text"))
  (check-true (>= (length refused) 5))
  (for ([r (in-list refused)])
    (check-equal? (with-handlers ([exn:fail:diagnostic?
                                   (lambda (e) (define d (exn:fail:diagnostic-diagnostic e))
                                     (format "~a:~a: ~a" (loc-line (diagnostic-loc d)) (loc-column (diagnostic-loc d)) (diagnostic-message d)))])
                    (read-sof (string-trim (car r) "\n" #:left? #f))
                    "no error")
                  (string-trim (cdr r))
                  (car r))))

(test-case "the text of section 7 is what the decompiler writes for the example of section 1"
  (check-equal? (string-trim (car (blocks "sof-canonical"))) (view->sof (car (sof->views (car (blocks "sof")))))))

(test-case "the table of section 5 says where every element of the IG's ViewDefinition is written"
  ;; an element below the top level, and the ones a statement writes itself, are named in the
  ;; table; every other element of the view itself is the table's last row (WITH)
  (define table (cadr (regexp-match #px"\\| ViewDefinition element \\| written as \\|\n(.*?)\n\n" text)))
  (define named (regexp-match* #px"`([A-Za-z.\\[\\]]+)`" (string-join (map (lambda (row) (car (string-split row "|"))) (string-split table "\n"))) #:match-select cadr))
  (for* ([f (in-list (features-of 'view))] [n (in-list (feature-names f))]
         #:when (or (regexp-match? #rx"[.]" n) (memq (string->symbol n) statement-owned)))
    (check-true (and (member n named) #t) (format "LANGUAGE.md's table does not say where `~a` is written" n)))
  (check-true (regexp-match? #rx"every other element of the view itself" table)))

(test-case "the feature list's rows for the language name its keywords, and no other word in capitals"
  (define said (remove-duplicates (regexp-match* #px"\\b[A-Z]{2,}\\b" (string-join (append-map feature-names (features-of 'source))))))
  (check-equal? (sort said string<?) (sort keywords string<?)))

;; ---- the law --------------------------------------------------------------------------------------
;; as-compiled : ViewDefinition -> ViewDefinition   what compiling gives for it: `resourceType`
;; there, R6's `resourceDefinition` (no element) not
(define (as-compiled v) (hash-set (hash-remove v 'resourceDefinition) 'resourceType "ViewDefinition"))
;; outcome : ViewDefinition -> 'same | 'unwritable | 'refused | (list 'differs text)
(define (outcome v)
  (with-handlers ([exn:fail:unwritable? (lambda (_) 'unwritable)]
                  [exn:fail:diagnostic? (lambda (_) 'refused)])
    (define written (view->sof v))
    (define back (sof->views written))
    (cond [(not (equal? back (list (as-compiled v)))) (list 'differs written)]
          ;; the text is canonical: what comes back is written the same way
          [(not (equal? (view->sof (car back)) written)) (list 'not-canonical written)]
          [else 'same])))
(define (valid? v) (with-handlers ([exn:fail? (lambda (_) #f)]) (view-rows v '()) #t))

(define suite-views
  (for*/list ([f (in-list (suite-files))] [t (in-list (hash-ref (call-with-input-file f read-json) 'tests '()))])
    (hash-ref t 'view)))
(define ig-views (for/list ([e (in-list ig-examples)] #:when (equal? (hash-ref (cdr e) 'resourceType #f) "ViewDefinition")) (cdr e)))

(test-case "the law over the shared suite's views and the IG's examples"
  (define all (append suite-views ig-views))
  (define outcomes (map outcome all))
  (define (count-of o) (count (lambda (x) (equal? x o)) outcomes))
  (printf "  source text: ~a views of the suite and the IG; ~a come back unchanged, ~a have no text, ~a are refused when compiled\n"
          (length all) (count-of 'same) (count-of 'unwritable) (count-of 'refused))
  (check-equal? (list (length suite-views) (length ig-views)) '(144 10))
  ;; every valid view has a text and comes back from it; nothing comes back changed
  (for ([v (in-list all)] [o (in-list outcomes)])
    (check-false (pair? o) (format "~a" o))
    (when (valid? v) (check-eq? o 'same (jsexpr->string v))))
  ;; LANGUAGE.md, section 10, says these numbers
  (check-equal? (list (count-of 'same) (count-of 'unwritable) (count-of 'refused)) '(148 5 1))
  (check-equal? (count valid? all) 146))

(test-case "the law over the document's own examples"
  (for ([e (in-list examples)]) (check-eq? (outcome (car (sof->views (car e)))) 'same (car e))))

;; ---- views grown at random ------------------------------------------------------------------------
;; every shape a select can take: columns or none, nested selects (of columns alone, iterated,
;; with a union), a union or none, at every depth; names that are words, keywords and neither
(define (random-view)
  (define n 0)
  (define (name) (set! n (add1 n)) (list-ref (list (format "c~a" n) (format "c~a" n) (format "TYPE~a" n) (format "odd name ~a" n)) (random 4)))
  (define paths '("id" "gender" "name.family.first()" "value as Quantity" "name.where(use = 'official').given" " id" "telecom.where(system = 'a, b')"))
  (define (column)
    (define p (list-ref paths (random (length paths))))
    (for/fold ([c (hasheq 'path p 'name (if (and (equal? p "id") (zero? (random 2))) (begin (set! n (add1 n)) "id") (name)))])
              ([extra (in-list (list (cons 'collection (zero? (random 2))) (cons 'type "string") (cons 'description "it's \"here\"\n")
                                     (cons 'tag (list (hasheq 'name "k" 'value "v")))))]
               #:when (zero? (random 4)))
      (hash-set c (car extra) (cdr extra))))
  (define (columns) (for/list ([_ (in-range (add1 (random 3)))]) (column)))
  (define (select depth)
    (for/fold ([s (hasheq)])
              ([part (in-list (list (and (zero? (random 3)) (list-ref (list (cons 'forEach "name") (cons 'forEachOrNull "telecom") (cons 'repeat '("item" "answer.item"))) (random 3)))
                                    (and (positive? (random 4)) (cons 'column (columns)))
                                    (and (< depth 3) (zero? (random 2)) (cons 'select (for/list ([_ (in-range (add1 (random 3)))]) (select (add1 depth)))))
                                    (and (< depth 3) (zero? (random 4)) (cons 'unionAll (for/list ([_ (in-range (+ 2 (random 2)))]) (select (add1 depth)))))))]
               #:when part)
      (hash-set s (car part) (cdr part))))
  (for/fold ([v (hasheq 'resourceType "ViewDefinition" 'resource "Patient" 'select (for/list ([_ (in-range (add1 (random 4)))]) (select 0)))])
            ([part (in-list (list (cons 'name "v") (cons 'status "active") (cons 'fhirVersion '("4.0"))
                                  (cons 'where (list (hasheq 'path "active = true") (hasheq 'path "id.exists()" 'description "d")))
                                  (cons 'constant (list (hasheq 'name "a" 'valueString "x") (hasheq 'name "b" 'valueCode "x") (hasheq 'name "c" 'valueDecimal 2)))))]
             #:when (zero? (random 2)))
    (hash-set v (car part) (cdr part))))

(test-case "the law over views grown at random"
  (random-seed 20261124)
  (define outcomes (for/list ([_ (in-range 600)]) (define v (random-view)) (cons v (outcome v))))
  (for ([o (in-list outcomes)])
    (check-eq? (cdr o) 'same (if (pair? (cdr o)) (format "~a\n~a" (jsexpr->string (car o)) (cadr (cdr o))) (jsexpr->string (car o)))))
  (check-true (for/or ([o (in-list outcomes)]) (regexp-match? #rx"UNION ALL" (view->sof (car o))))))

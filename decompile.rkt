#lang racket/base

;;; decompile.rkt — a ViewDefinition as the source text that states it (LANGUAGE.md, "From a
;;; ViewDefinition back to text").
;;;
;;; The law: for a ViewDefinition `v` this module can write,
;;;     (sof->views (view->sof v))  =  (list v)
;;; as JSON, `resourceType` there and R6's `resourceDefinition` (the envelope, no element) left out
;;; of the comparison. So the text is another way to hold the same resource, and nothing is lost by
;;; keeping views as text. tests/language-test.rkt holds the law over the shared suite's views, the
;;; IG's own examples and the guide's.
;;;
;;; The text is written one way: a clause to a line, an item to a line, a nested select indented
;;; inside its parentheses. What it writes is decided by what compiles back:
;;;   - a column whose path is one element's name, and is its name, is that word alone;
;;;   - a path is written bare when its text reads back as itself, else in double quotes;
;;;   - a name that is not a plain word, or is a keyword, is written in backticks;
;;;   - a constant is written without its type when its value says the type;
;;;   - a nested select of columns alone is written without parentheses when it follows a
;;;     parenthesised item (there the run of columns reads back as that nested select).
;;;
;;; What the language has no place for is refused, by name (an `exn:fail:unwritable`): an element's
;;; own id or extensions below the top level, an empty list, a constant without exactly one value.

(require racket/contract racket/list racket/string
         "parser/lexer.rkt"
         (only-in "compile.rkt" statement-owned))

(provide
 (struct-out exn:fail:unwritable)
 (contract-out
  ;; view->sof : ViewDefinition JSON -> the statement that compiles to it (no final newline)
  [view->sof (-> hash? string?)]
  ;; views->sof : several, as one file's text: statements ended by `;`
  [views->sof (-> (listof hash?) string?)]
  ;; bare-path? : can this path be written as it is, outside quotes?
  [bare-path? (-> string? boolean?)]))

(struct exn:fail:unwritable exn:fail:user ())
;; refuse : format value … -> raises exn:fail:unwritable
(define (refuse fmt . args)
  (raise (exn:fail:unwritable (string-append "cannot be written as source text: " (apply format fmt args))
                              (current-continuation-marks))))

;; ---- words, strings, values ---------------------------------------------------------------------
;; plain-word? : string -> boolean   a word the lexer reads as one WORD
(define (plain-word? s)
  (and (regexp-match? #px"^[A-Za-z_][A-Za-z0-9_]*$" s) (not (keyword-word? s))))

;; escaped : string quote-char -> string   the string between quotes of that kind
(define (escaped s quote)
  (apply string-append
         (for/list ([c (in-string s)])
           (cond [(char=? c quote) (string #\\ c)]
                 [(char=? c #\\) "\\\\"]
                 [(char=? c #\newline) "\\n"] [(char=? c #\return) "\\r"] [(char=? c #\tab) "\\t"]
                 [(char=? c #\page) "\\f"] [(char=? c #\backspace) "\\b"]
                 [(char<? c #\space) (format "\\u~a" (string-append (make-string (- 4 (string-length (number->string (char->integer c) 16))) #\0)
                                                                   (number->string (char->integer c) 16)))]
                 [else (string c)]))))
(define (string-text s) (string-append "'" (escaped s #\') "'"))
(define (name-text s) (if (plain-word? s) s (string-append "`" (escaped s #\`) "`")))

;; number-text : number -> string   as the lexer reads it back to the same number
(define (number-text n)
  (define text (if (exact-integer? n) (number->string n) (number->string (exact->inexact n))))
  (cond [(regexp-match? #px"^-?[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$" text) text]
        [else (refuse "the number ~a" n)]))

;; value-text : jsexpr -> string   a WITH (…) value: JSON, strings in single quotes
(define (value-text v)
  (cond [(string? v) (string-text v)]
        [(boolean? v) (if v "true" "false")]
        [(eq? v 'null) "null"]
        [(real? v) (number-text v)]
        [(list? v) (string-append "[" (string-join (map value-text v) ", ") "]")]
        [(hash? v) (string-append "{" (string-join (for/list ([k (in-list (sort (hash-keys v) symbol<?))])
                                                      (format "~a: ~a" (let ([s (symbol->string k)]) (if (plain-word? s) s (string-text s)))
                                                              (value-text (hash-ref v k))))
                                                    ", ")
                                  "}")]
        [else (refuse "the value ~s" v)]))

;; ---- paths --------------------------------------------------------------------------------------
;; bare-path? : string -> boolean   its tokens are a path's (no keyword, brackets closed, a comma only
;; inside them) and, joined again, are the text
(define (bare-path? text)
  (define toks (with-handlers ([exn:fail? (lambda (_) #f)]) (tokenize text)))
  (and toks
       (positive? (vector-length toks))
       (let loop ([ts (vector->list toks)] [open '()])
         (cond [(null? ts) (null? open)]
               [else
                (define type (tok-type (car ts)))
                (cond [(memq type '(WORD NUMBER STRING BACKTICK ATLIT SYMBOL EQ)) (loop (cdr ts) open)]
                      [(member type '("(" "[" "{")) (loop (cdr ts) (cons type open))]
                      [(member type '(")" "]" "}"))
                       (and (pair? open) (equal? (car open) (cdr (assoc type '((")" . "(") ("]" . "[") ("}" . "{")))))
                            (loop (cdr ts) (cdr open)))]
                      [(member type '("," ":")) (and (pair? open) (loop (cdr ts) open))]
                      [else #f])]))
       (equal? (path-text toks 0 (sub1 (vector-length toks))) text)))
(define (path-out p what)
  (unless (string? p) (refuse "~a is ~s, which is no path" what p))
  (if (bare-path? p) p (string-append "\"" (regexp-replace* #rx"[\\\\\"]" p "\\\\&") "\"")))

;; ---- lines --------------------------------------------------------------------------------------
;; A Block is a (Listof String): lines of text.
(define (indented block by) (map (lambda (l) (string-append (make-string by #\space) l)) block))
;; listed : (Listof Block) -> Block   one after another, a comma after each but the last
(define (listed blocks)
  (append* (for/list ([b (in-list blocks)] [i (in-naturals 1)])
             (if (< i (length blocks))
                 (append (drop-right b 1) (list (string-append (last b) ",")))
                 b))))
;; parenthesised : Block -> Block
(define (parenthesised block)
  (define inner (cons (string-append "(" (car block)) (indented (cdr block) 1)))
  (append (drop-right inner 1) (list (string-append (last inner) ")"))))

;; only : hash what symbol … -> void   refuses a key other than these
(define (only h what . keys)
  (for ([k (in-list (sort (hash-keys h) symbol<?))] #:unless (memq k keys))
    (refuse "~a has `~a`, which the language has no place for" what k)))
;; items-at : hash key what -> list   a list element's items; an empty list is refused (the text
;; would read back with no such element)
(define (items-at h key what)
  (define v (hash-ref h key #f))
  (cond [(not v) '()]
        [(and (list? v) (pair? v)) v]
        [else (refuse "~a has `~a` ~s, which is no list of them" what key v)]))

;; ---- a column, a condition, a constant ------------------------------------------------------------
;; column-line : column -> string
(define (column-line c)
  (unless (hash? c) (refuse "a column is ~s" c))
  (only c "a column" 'path 'name 'type 'collection 'description 'tag)
  (define name (hash-ref c 'name #f))
  (unless (string? name) (refuse "a column has no `name`"))
  (define path (path-out (hash-ref c 'path #f) (format "the path of column `~a`" name)))
  (string-append*
   (if (and (equal? path name) (plain-word? name)) name (format "~a AS ~a" path (name-text name)))
   (append (cond [(hash-ref c 'type #f)
                  => (lambda (t)
                       (unless (string? t) (refuse "the type of column `~a` is ~s" name t))
                       (list " TYPE " (if (regexp-match? #px"^[A-Za-z_][A-Za-z0-9_]*([.][A-Za-z_][A-Za-z0-9_]*)*$" t)
                                          (if (for/or ([w (in-list (string-split t "."))] [i (in-naturals)])
                                                (and (keyword-word? w) (zero? i)))
                                              (string-text t)
                                              t)
                                          (string-text t))))]
                 [else '()])
           (case (hash-ref c 'collection 'none) [(#t) '(" COLLECTION")] [(#f) '(" NOT COLLECTION")] [(none) '()]
             [else (refuse "the `collection` of column `~a` is ~s" name (hash-ref c 'collection))])
           (cond [(hash-ref c 'description #f) => (lambda (d) (list " DESCRIPTION " (string-out d "a column's description")))] [else '()])
           (for/list ([t (in-list (items-at c 'tag (format "column `~a`" name)))])
             (only t "a tag" 'name 'value)
             (format " TAG ~a = ~a" (string-out (hash-ref t 'name #f) "a tag's name") (string-out (hash-ref t 'value #f) "a tag's value"))))))
(define (string-out s what)
  (unless (string? s) (refuse "~a is ~s" what s))
  (string-text s))

;; constant-line : constant -> string   `name = value`, with its type when the value does not say it
(define (constant-line c)
  (unless (hash? c) (refuse "a constant is ~s" c))
  (define name (hash-ref c 'name #f))
  (unless (string? name) (refuse "a constant has no `name`"))
  (define keys (remq 'name (hash-keys c)))
  (unless (and (= (length keys) 1) (regexp-match? #rx"^value[A-Z]" (symbol->string (car keys))))
    (refuse "constant `~a` has ~a" name (if (null? keys) "no value" (format "~a beside its name" (sort keys symbol<?)))))
  (define type (let ([t (substring (symbol->string (car keys)) 5)]) (string-append (string-downcase (substring t 0 1)) (substring t 1))))
  (define v (hash-ref c (car keys)))
  (define said (cond [(string? v) "string"] [(boolean? v) "boolean"] [(exact-integer? v) "integer"] [(real? v) "decimal"]
                     [else (refuse "the value of constant `~a` is ~s" name v)]))
  (format "~a~a = ~a" (name-text name) (if (equal? said type) "" (string-append " " type)) (value-text v)))

;; ---- selects ------------------------------------------------------------------------------------
;; A Select is a select element of a ViewDefinition, as JSON.
;; columns-only? : Select -> boolean   nothing but columns
(define (columns-only? s) (and (hash? s) (equal? (hash-keys s) '(column)) (pair? (hash-ref s 'column)) (list? (hash-ref s 'column))))
(define (union-only? s) (and (hash? s) (equal? (hash-keys s) '(unionAll)) (pair? (hash-ref s 'unionAll)) (list? (hash-ref s 'unionAll))))

;; item-blocks : columns selects unions -> (Listof Block)   the items of one SELECT, in the order
;; they read back: own columns, each nested select, the UNION ALL group
(define (item-blocks columns selects unions)
  (append (map (lambda (c) (list (column-line c))) columns)
          (let loop ([selects selects] [after-parenthesis? #f])
            (cond [(null? selects) '()]
                  [(and after-parenthesis? (columns-only? (car selects)))
                   (append (map (lambda (c) (list (column-line c))) (hash-ref (car selects) 'column))
                           (loop (cdr selects) #f))]
                  [else (cons (parenthesised (select-block (car selects))) (loop (cdr selects) #t))]))
          (cond [(null? unions) '()]
                ;; one branch has no UNION ALL to be told by: it would read back as a nested select
                [(null? (cdr unions)) (refuse "a `unionAll` of one select (a nested select says the same)")]
                [else (list (parenthesised (append* (add-between (map select-block unions) '("UNION ALL")))))])))

;; select-block : Select -> Block   SELECT, its items, and what it is taken FROM
(define (select-block s)
  (unless (hash? s) (refuse "a select is ~s" s))
  (only s "a select" 'column 'select 'unionAll 'forEach 'forEachOrNull 'repeat)
  (define iterations (filter (lambda (k) (hash-has-key? s k)) '(forEach forEachOrNull repeat)))
  (when (> (length iterations) 1) (refuse "a select has more than one of forEach, forEachOrNull and repeat"))
  (append (list "SELECT")
          (indented (listed (item-blocks (items-at s 'column "a select") (items-at s 'select "a select") (items-at s 'unionAll "a select"))) 2)
          (cond [(hash-has-key? s 'forEach) (list (format "FROM ~a" (path-out (hash-ref s 'forEach) "a forEach")))]
                [(hash-has-key? s 'forEachOrNull) (list (format "FROM ~a OR NULL" (path-out (hash-ref s 'forEachOrNull) "a forEachOrNull")))]
                [(hash-has-key? s 'repeat)
                 (list (format "FROM REPEAT ~a" (string-join (map (lambda (p) (path-out p "a repeat")) (items-at s 'repeat "a select")) ", ")))]
                [else '()])))

;; ---- the view -----------------------------------------------------------------------------------
;; option-order : the view's other elements in the order they are written (the definition's);
;; any other follows, by name
(define option-order
  '(id url identifier version versionAlgorithmString versionAlgorithmCoding title status experimental date publisher
    contact description useContext jurisdiction purpose copyright copyrightLabel approvalDate lastReviewDate
    effectivePeriod topic author editor reviewer endorser relatedArtifact profile fhirVersion))

(define (view->sof v)
  (unless (equal? (hash-ref v 'resourceType "ViewDefinition") "ViewDefinition")
    (refuse "the resource is a ~a" (hash-ref v 'resourceType)))
  (define resource (hash-ref v 'resource #f))
  (unless (and (string? resource) (plain-word? resource))
    (refuse "~a" (if resource (format "its `resource` is ~s, which names no resource type" resource) "it has no `resource`")))
  (define name (hash-ref v 'name #f))
  (unless (or (not name) (string? name)) (refuse "its `name` is ~s" name))
  (define option-keys
    (let ([keys (remq* (append statement-owned '(resourceDefinition)) (hash-keys v))])
      (append (filter (lambda (k) (memq k keys)) option-order)
              (sort (remq* option-order keys) symbol<?))))
  (define options
    (for/list ([k (in-list option-keys)])
      (unless (plain-word? (symbol->string k)) (refuse "it has `~a`, which is no word" k))
      (format "~a = ~a" k (value-text (hash-ref v k)))))
  ;; the top level reads as a select without a FROM of its own: a first select of columns alone is
  ;; its columns, a last one of a unionAll alone its UNION ALL group
  (define selects (items-at v 'select "the view"))
  (define-values (columns middle unions)
    (let* ([own? (and (pair? selects) (columns-only? (car selects)))]
           [rest (if own? (cdr selects) selects)]
           [group? (and (pair? rest) (union-only? (last rest)))])
      (values (if own? (hash-ref (car selects) 'column) '())
              (if group? (drop-right rest 1) rest)
              (if group? (hash-ref (last rest) 'unionAll) '()))))
  (define wheres
    (for/list ([w (in-list (items-at v 'where "the view"))])
      (unless (hash? w) (refuse "a where is ~s" w))
      (only w "a where" 'path 'description)
      (string-append (path-out (hash-ref w 'path #f) "a where's path")
                     (cond [(hash-ref w 'description #f) => (lambda (d) (string-append " DESCRIPTION " (string-out d "a where's description")))]
                           [else ""]))))
  (define constants (map constant-line (items-at v 'constant "the view")))
  (string-join
   (append
    (if (or name (pair? options))
        (append (list (if name (format "CREATE VIEW ~a" (name-text name)) "CREATE VIEW"))
                (if (pair? options)
                    (let ([lines (listed (map list options))])
                      (define open (cons (string-append "  WITH (" (car lines)) (indented (cdr lines) 8)))
                      (append (drop-right open 1) (list (string-append (last open) ")"))))
                    '())
                (list "AS"))
        '())
    (if (pair? constants)
        (let ([lines (listed (map list constants))])
          (cons (string-append "DECLARE " (car lines)) (indented (cdr lines) 8)))
        '())
    (list "SELECT")
    (indented (listed (item-blocks columns middle unions)) 2)
    (list (format "FROM ~a" resource))
    (if (pair? wheres)
        (cons (string-append "WHERE " (car wheres)) (map (lambda (w) (string-append "  AND " w)) (cdr wheres)))
        '()))
   "\n"))

(define (views->sof vs)
  (string-append* (for/list ([v (in-list vs)]) (string-append (view->sof v) ";\n\n"))))

(module+ test
  (require rackunit (only-in "compile.rkt" sof->views))
  ;; the law, case by case: the text compiles back to the view
  (define (back v) (car (sof->views (view->sof v))))
  (define (view . kvs) (apply hasheq 'resourceType "ViewDefinition" kvs))
  (define (col p [n p] . more) (apply hasheq 'path p 'name n more))
  (define-syntax-rule (check-law v) (check-equal? (back v) v))
  (define simple (view 'resource "Patient" 'select (list (hasheq 'column (list (col "id") (col "getResourceKey()" "key"))))))
  (check-equal? (view->sof simple) "SELECT\n  id,\n  getResourceKey() AS key\nFROM Patient")
  (check-law simple)
  ;; everything a statement says, written one way
  (define full
    (view 'name "bp" 'status "active" 'fhirVersion '("4.0" "5.0") 'experimental #t 'url "http://example.org/ViewDefinition/bp"
          'contact (list (hasheq 'name "A" 'telecom (list (hasheq 'system "url" 'value "http://x"))))
          'resource "Observation"
          'constant (list (hasheq 'name "loinc" 'valueString "http://loinc.org") (hasheq 'name "top" 'valueInteger 3)
                          (hasheq 'name "since" 'valueDate "2020-01-01") (hasheq 'name "rate" 'valueDecimal 1.5)
                          (hasheq 'name "whole" 'valueDecimal 2) (hasheq 'name "on" 'valueBoolean #t) (hasheq 'name "c" 'valueCode "x"))
          'select (list (hasheq 'column (list (col "getResourceKey()" "id") (col "value as Quantity" "ALL" 'type "Quantity")
                                              (col "name.given" "given" 'collection #t 'description "it's every given name"
                                                   'tag (list (hasheq 'name "ansi/type" 'value "VARCHAR")))
                                              (col "id" "id2" 'collection #f 'type "http://hl7.org/fhir/StructureDefinition/id")))
                        (hasheq 'forEachOrNull "component" 'column (list (col "code.text" "what"))
                                'select (list (hasheq 'column (list (col "a")))
                                              (hasheq 'forEach "referenceRange" 'column (list (col "low.value" "low")))
                                              (hasheq 'column (list (col "b"))))
                                'unionAll (list (hasheq 'column (list (col "u"))) (hasheq 'repeat '("item" "answer.item") 'column (list (col "u")))))
                        (hasheq 'column (list (col "status")))
                        (hasheq 'unionAll (list (hasheq 'column (list (col "x"))) (hasheq 'column (list (col "x"))))))
          'where (list (hasheq 'path "code.coding.exists(system = %loinc)" 'description "coded in LOINC") (hasheq 'path "status = 'final'"))))
  (check-law full)
  (check-equal? (view->sof full)
                (string-join
                 '("CREATE VIEW bp"
                   "  WITH (url = 'http://example.org/ViewDefinition/bp',"
                   "        status = 'active',"
                   "        experimental = true,"
                   "        contact = [{name: 'A', telecom: [{system: 'url', value: 'http://x'}]}],"
                   "        fhirVersion = ['4.0', '5.0'])"
                   "AS"
                   "DECLARE loinc = 'http://loinc.org',"
                   "        top = 3,"
                   "        since date = '2020-01-01',"
                   "        rate = 1.5,"
                   "        whole decimal = 2,"
                   "        on = true,"
                   "        c code = 'x'"
                   "SELECT"
                   "  getResourceKey() AS id,"
                   "  value as Quantity AS `ALL` TYPE Quantity,"
                   "  name.given AS given COLLECTION DESCRIPTION 'it\\'s every given name' TAG 'ansi/type' = 'VARCHAR',"
                   "  id AS id2 TYPE 'http://hl7.org/fhir/StructureDefinition/id' NOT COLLECTION,"
                   "  (SELECT"
                   "     code.text AS what,"
                   "     (SELECT"
                   "        a),"
                   "     (SELECT"
                   "        low.value AS low"
                   "      FROM referenceRange),"
                   "     b,"
                   "     (SELECT"
                   "        u"
                   "      UNION ALL"
                   "      SELECT"
                   "        u"
                   "      FROM REPEAT item, answer.item)"
                   "   FROM component OR NULL),"
                   "  status,"
                   "  (SELECT"
                   "     x"
                   "   UNION ALL"
                   "   SELECT"
                   "     x)"
                   "FROM Observation"
                   "WHERE code.coding.exists(system = %loinc) DESCRIPTION 'coded in LOINC'"
                   "  AND status = 'final'")
                 "\n"))
  ;; shapes that read back only when written just so
  (check-law (view 'resource "Patient" 'select (list (hasheq 'column (list (col "a"))) (hasheq 'column (list (col "b"))))))
  (check-law (view 'resource "Patient" 'select (list (hasheq 'unionAll (list (hasheq 'column (list (col "a"))) (hasheq 'column (list (col "a"))))) (hasheq 'column (list (col "b"))))))
  (check-law (view 'resource "Patient" 'select (list (hasheq 'column (list (col "a")) 'unionAll (list (hasheq 'column (list (col "b"))) (hasheq 'forEach "x" 'column (list (col "b"))))))))
  (check-law (view 'resource "Patient" 'select (list (hasheq 'unionAll (list (hasheq 'column (list (col "a"))) (hasheq 'column (list (col "a"))))) (hasheq 'unionAll (list (hasheq 'column (list (col "a"))) (hasheq 'column (list (col "a"))))))))
  (check-law (view 'resource "Patient" 'select (list (hasheq 'forEach "name") (hasheq))))
  (check-law (view 'resource "Patient" 'name "TYPE" 'select (list (hasheq 'column (list (col "TYPE" "TYPE") (col "a" "odd name"))))))
  ;; a path is bare when it reads back as itself; else it is quoted, as it is
  (check-true (bare-path? "name.where(use = 'official').family.first()"))
  (check-true (bare-path? "value as Quantity"))
  (check-false (bare-path? "name.TYPE AS x"))                 ; a keyword of the language
  (check-false (bare-path? " id"))                            ; space before it
  (check-false (bare-path? "a, b"))                           ; a comma outside brackets
  (check-false (bare-path? "name.where(use = 'x'"))           ; a bracket left open
  (check-false (bare-path? "a -- b"))                         ; a comment
  (check-false (bare-path? ""))
  (for ([p (in-list '(" id" "a -- b" "TYPE.code" "name\n  .family" "name.where(family = 'say \"hi\" \\\\ there')"
                      "name.where(family = 'O\\'Brien')" "value as Quantity"))])
    (define text (view->sof (view 'resource "Patient" 'select (list (hasheq 'forEach p)))))
    (check-equal? (hash-ref (car (hash-ref (car (sof->views text)) 'select)) 'forEach) p text))
  ;; a path that is not FHIRPath is written all the same (in quotes), and the compiler refuses it
  (check-equal? (view->sof (view 'resource "Patient" 'select (list (hasheq 'forEach "@@")))) "SELECT\n  (SELECT\n   FROM \"@@\")\nFROM Patient")
  ;; what the language has no place for is refused, by name
  (define (refusal v) (with-handlers ([exn:fail:unwritable? exn-message]) (view->sof v)))
  (check-equal? (refusal (view 'resource "Patient" 'select (list (hasheq 'id "s1" 'column (list (col "id"))))))
                "cannot be written as source text: a select has `id`, which the language has no place for")
  (check-equal? (refusal (view 'resource "Patient" 'select (list (hasheq 'column (list (hasheq 'path "id" 'name "id" 'extension '()))))))
                "cannot be written as source text: a column has `extension`, which the language has no place for")
  (check-equal? (refusal (view 'resource "Patient" 'constant (list (hasheq 'name "c")) 'select (list (hasheq 'column (list (col "id"))))))
                "cannot be written as source text: constant `c` has no value")
  (check-equal? (refusal (view 'select (list (hasheq 'column (list (col "id"))))))
                "cannot be written as source text: it has no `resource`")
  (check-equal? (refusal (view 'resource "Patient" 'select (list (hasheq 'forEach 1))))
                "cannot be written as source text: a forEach is 1, which is no path")
  (check-equal? (refusal (view 'resource "Patient" 'select (list (hasheq 'column '()))))
                "cannot be written as source text: a select has `column` (), which is no list of them")
  (check-equal? (refusal (view 'resource "Patient" 'select (list (hasheq 'unionAll (list (hasheq 'column (list (col "a"))))))))
                "cannot be written as source text: a `unionAll` of one select (a nested select says the same)")
  ;; several views are one file
  (check-equal? (map (lambda (v) (hash-ref v 'resource)) (sof->views (views->sof (list simple full)))) '("Patient" "Observation")))

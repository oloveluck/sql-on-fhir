#lang racket/base

;;; compile.rkt — the SQL on FHIR source language to ViewDefinitions (LANGUAGE.md, "What it means").
;;;
;;;   text -> tokens (parser/lexer.rkt) -> tree (parser/grammar.rkt, brag) -> ViewDefinition JSON
;;;
;;; The ViewDefinition is the intermediate form: what the standard defines, what the engine runs
;;; and what other tools read. This module only translates, and checks what is its own to check —
;;; the text's syntax, that every path is FHIRPath, and the few things the grammar cannot say (a
;;; column's name, where a UNION ALL group may stand). Whether the result is a ViewDefinition by
;;; the IG's definition is definition.rkt's `read-view` (sof.rkt asks both).
;;;
;;; Data definitions.
;;; A Tree is brag's tree for a rule, as a list: (rule-name part …), each part a Tree or a Tok
;;;   (parser/lexer.rkt): the grammar's `/` parts are not in it.
;;; A Compiled is (compiled view loc): a ViewDefinition as JSON and where its statement begins.
;;; A problem of the text is raised as an `exn:fail:diagnostic` (fhir/diagnostic) at its token.

(require racket/contract racket/list racket/match racket/string
         (prefix-in g: "parser/grammar.rkt")
         "parser/lexer.rkt"
         (only-in brag/support token)
         (only-in fhir/diagnostic diagnostic diagnostic? diagnostic-loc diagnostic-message loc loc? loc-position
                  exn:fail:diagnostic exn:fail:diagnostic? exn:fail:diagnostic-diagnostic
                  exn->diagnostic error-position)
         (only-in fhirpath/parser/parse parse-fhirpath))

(provide
 (struct-out compiled)
 (contract-out
  ;; compile-sof : text [source] -> (Listof Compiled)   every statement of the text as a
  ;; ViewDefinition, with where it begins; raises an exn:fail:diagnostic at the first problem
  [compile-sof (->* (string?) (any/c) (listof compiled?))]
  ;; sof->views : text [source] -> (Listof ViewDefinition-JSON)
  [sof->views (->* (string?) (any/c) (listof hash?))]
  ;; constant-types : the primitive types a constant may be declared as (DECLARE name type = value)
  [constant-types (listof string?)]
  ;; statement-owned : the elements a statement writes itself, which WITH (…) therefore may not
  [statement-owned (listof symbol?)]))

(struct compiled (view loc) #:transparent)

;; ---- text -> tree -------------------------------------------------------------------------------
;; parse : text source -> (values Tree (Vectorof Tok))   raises a positioned parse diagnostic
(define (parse text source)
  (define toks (tokenize text source))
  (define by-position (for/hasheqv ([t (in-vector toks)]) (values (add1 (tok-start t)) t)))
  (define (brag-tokens ts)
    (for/list ([t (in-list ts)])
      (token (tok-type t) (tok-text t) #:position (add1 (tok-start t)) #:line (tok-line t) #:column (tok-column t)
             #:span (- (tok-end t) (tok-start t)))))
  (define (thunk ts) (lambda () (if (null? ts) (void) (begin0 (car ts) (set! ts (cdr ts))))))
  (define all (vector->list toks))
  (define last-pos (and (pair? all) (add1 (tok-start (last all)))))
  ;; the input ran out when a copy of the last token, put after it, moves the error onto the copy
  (define (ran-out?)
    (define l (last all))
    (with-handlers ([exn:fail? (lambda (e) (let ([p (error-position e)]) (and p (> p last-pos))))])
      (g:parse-to-datum (thunk (append (brag-tokens all)
                                       (list (token (tok-type l) (tok-text l) #:position (+ last-pos 100000) #:line 1 #:column 0)))))
      #f))
  (define stx
    (with-handlers ([(lambda (e) (and (exn:fail? e) (not (exn:fail:diagnostic? e))))
                     (lambda (e)
                       (define d (exn->diagnostic e 'sql-on-fhir #:source source #:last-position last-pos
                                                  #:unit "statement" #:ran-out? ran-out?))
                       (raise-problem (with-hint d toks)))])
      (g:parse source (thunk (brag-tokens all)))))
  (values (let walk ([s stx])
            (cond [(syntax->list s) => (lambda (parts) (map walk parts))]
                  [(symbol? (syntax-e s)) (syntax-e s)]
                  [else (hash-ref by-position (syntax-position s))]))
          toks))

;; with-hint : diagnostic (Vectorof Tok) -> diagnostic   a parse error at a word that is a keyword in
;; lower case says so: the commonest mistake of someone who knows SQL
(define (with-hint d toks)
  (define at (and (diagnostic-loc d) (loc-position (diagnostic-loc d))))
  (define t (and at (for/first ([t (in-vector toks)] #:when (= (add1 (tok-start t)) at)) t)))
  (define first-word (and (positive? (vector-length toks)) (vector-ref toks 0)))
  (define (lower-keyword? t) (and t (eq? (tok-type t) 'WORD) (keyword-word? (string-upcase (tok-text t)))))
  (define culprit (cond [(lower-keyword? t) t]
                        [(lower-keyword? first-word) first-word]
                        [else (for/first ([x (in-vector toks)] #:when (lower-keyword? x)) x)]))
  (if (and culprit (or (eq? culprit t) (eq? culprit first-word)))
      (struct-copy diagnostic d
                   [message (format "~a (keywords are written in capitals: `~a`; in lower case `~a` is read as part of a path)"
                                    (diagnostic-message d) (string-upcase (tok-text culprit)) (tok-text culprit))])
      d))

;; ---- problems -----------------------------------------------------------------------------------
(define current-source (make-parameter #f))
;; tok-loc : Tok -> loc
(define (tok-loc t)
  (loc (current-source) (tok-line t) (add1 (tok-column t)) (add1 (tok-start t)) (- (tok-end t) (tok-start t))))
(define (raise-problem d)
  (raise (exn:fail:diagnostic (diagnostic-message d) (current-continuation-marks) d)))
;; problem : Tok format value … -> raises a compile diagnostic at the token
(define (problem t fmt . args)
  (raise-problem (diagnostic 'sql-on-fhir 'compile 'error (apply format fmt args) (tok-loc t))))

;; sub : rule-name (Listof (or/c Tree Tok)) -> Tree | #f   the first part that is that rule's tree
(define (sub name parts)
  (findf (lambda (p) (and (pair? p) (eq? (car p) name))) parts))

;; leaves : Tree -> (Listof Tok)   its tokens, in order
(define (leaves tree)
  (cond [(tok? tree) (list tree)]
        [(pair? tree) (append-map leaves (cdr tree))]
        [else '()]))
(define (first-tok tree) (car (leaves tree)))

;; ---- tree -> ViewDefinitions --------------------------------------------------------------------
(define (compile-sof text [source #f])
  (parameterize ([current-source (cond [(path? source) (path->string source)] [else source])])
    (define-values (tree toks) (parse text (current-source)))
    (for/list ([v (in-list (cdr tree))])
      (compiled (view-of v toks) (tok-loc (statement-start toks (first-tok v)))))))

;; statement-start : toks Tok -> Tok   the first token of the statement the token is in (the one
;; after the `;` before it, or the text's first)
(define (statement-start toks t)
  (let loop ([i (tok-index t)])
    (if (or (zero? i) (equal? (tok-type (vector-ref toks (sub1 i))) ";")) (vector-ref toks i) (loop (sub1 i)))))

(define (sof->views text [source #f]) (map compiled-view (compile-sof text source)))

;; statement-owned : the elements the statement itself writes
(define statement-owned '(resourceType name resource constant select where))

;; view-of : (view …) toks -> ViewDefinition JSON
(define (view-of tree toks)
  (define (part name) (sub name (cdr tree)))
  (define header (part 'header))
  (define query (part 'query))
  (define name (and header (sub 'name (cdr header))))
  (define options (if (and header (sub 'options (cdr header))) (options-of (sub 'options (cdr header))) '()))
  (define constants (if (part 'declare) (map constant-of (cdr (part 'declare))) '()))
  (match-define (list 'query query-parts ...) query)
  (define items (sub 'items query-parts))
  (define resource (findf tok? query-parts))
  (define conditions (sub 'conditions query-parts))
  (define-values (columns selects unions) (if items (items-of items toks) (values '() '() '())))
  (define select
    (append (if (pair? columns) (list (hasheq 'column columns)) '())
            selects
            (if (pair? unions) (list (hasheq 'unionAll unions)) '())))
  (for/fold ([v (hasheq 'resourceType "ViewDefinition" 'resource (tok-text resource))])
            ([kv (in-list (append options
                                  (if name (list (cons 'name (name-of name))) '())
                                  (if (pair? constants) (list (cons 'constant constants)) '())
                                  (if (pair? select) (list (cons 'select select)) '())
                                  (if conditions (list (cons 'where (map (lambda (c) (condition-of c toks)) (cdr conditions)))) '())))])
    (hash-set v (car kv) (cdr kv))))

;; name-of : (name Tok) -> string   a word, or a name in backticks (any name: a keyword, say)
(define (name-of tree)
  (define t (cadr tree))
  (if (eq? (tok-type t) 'BACKTICK)
      (or (backtick-value (tok-text t)) (problem t "the name ~a holds an escape there is none of" (tok-text t)))
      (tok-text t)))

;; text-of : Tok -> string   a 'STRING token's string
(define (text-of t)
  (or (string-value (tok-text t))
      (problem t "the string ~a holds an escape there is none of: \\' \\\" \\` \\\\ \\/ \\f \\n \\r \\t \\uXXXX are the escapes" (tok-text t))))

;; ---- WITH ( … ): the view's other elements, as JSON -----------------------------------------------
;; options-of : (options (option WORD value) …) -> (Listof (cons symbol jsexpr))
(define (options-of tree)
  (for/fold ([acc '()] #:result (reverse acc)) ([o (in-list (cdr tree))])
    (match-define (list 'option key value) o)
    (define k (string->symbol (tok-text key)))
    (when (memq k statement-owned)
      (problem key "`~a` is not written in WITH (…): the statement itself says it (~a)" k
               (case k
                 [(name) "CREATE VIEW <name>"] [(resource) "FROM <Resource>"] [(constant) "DECLARE"]
                 [(select) "SELECT"] [(where) "WHERE"] [else "every view is a ViewDefinition"])))
    (when (assq k acc) (problem key "`~a` is given twice" k))
    (cons (cons k (value-of value)) acc)))

;; value-of : (value …) -> jsexpr   JSON, a string in either kind of quotes
(define (value-of tree)
  (match tree
    [(list 'value (? tok? t))
     (case (tok-type t)
       [(STRING QUOTED) (text-of t)]
       [(NUMBER) (number-value (tok-text t))]
       [else (match (tok-text t)
               ["true" #t] ["false" #f] ["null" 'null]
               [w (problem t "`~a` is no value: a string is written in quotes ('~a'); true, false and null are the bare words" w w)])])]
    [(list 'value (? tok? sign) (? tok? n))
     (unless (equal? (tok-text sign) "-") (problem sign "`~a` is no value" (tok-text sign)))
     (- (number-value (tok-text n)))]
    [(list 'value (list 'array values ...)) (map value-of values)]
    [(list 'value (list 'object members ...))
     (for/fold ([h (hasheq)]) ([m (in-list members)])
       (match-define (list 'member key value) m)
       (hash-set h (string->symbol (if (eq? (tok-type key) 'WORD) (tok-text key) (text-of key))) (value-of value)))]))

;; ---- DECLARE: constants -------------------------------------------------------------------------
;; constant-types : the primitive types the IG's definition gives a constant's value
;; (tests/language-test.rkt holds the list to the definition)
(define constant-types
  '("base64Binary" "boolean" "canonical" "code" "date" "dateTime" "decimal" "id" "instant" "integer"
    "integer64" "oid" "string" "positiveInt" "time" "unsignedInt" "uri" "url" "uuid"))
(define (value-key type) (string->symbol (string-append "value" (string-upcase (substring type 0 1)) (substring type 1))))

;; constant-of : (constant (name …) [type-WORD] (literal …)) -> {name, value<Type>}
;; Without a type the literal says it: a string is a string, digits an integer, a number with a
;; fraction a decimal, true and false booleans, @… a date, a dateTime or a time.
(define (constant-of tree)
  (match-define (list 'constant name rest ...) tree)
  (define type (findf tok? rest))
  (define literal (sub 'literal rest))
  (when (and type (not (member (tok-text type) constant-types)))
    (problem type "`~a` is no type a constant takes: ~a" (tok-text type) (string-join constant-types ", ")))
  (define-values (inferred value)
    (match literal
      [(list 'literal (? tok? t))
       (case (tok-type t)
         [(STRING) (values "string" (text-of t))]
         [(NUMBER) (values (if (exact-integer? (number-value (tok-text t))) "integer" "decimal") (number-value (tok-text t)))]
         [(ATLIT) (define text (tok-text t))
                  (cond [(regexp-match? #rx"^@T" text) (values "time" (substring text 2))]
                        [(regexp-match? #rx"T" text) (values "dateTime" (substring text 1))]
                        [else (values "date" (substring text 1))])]
         [else (match (tok-text t)
                 ["true" (values "boolean" #t)] ["false" (values "boolean" #f)]
                 [w (problem t "`~a` is no value: a string is written in quotes ('~a')" w w)])])]
      [(list 'literal (? tok? sign) (? tok? n))
       (unless (equal? (tok-text sign) "-") (problem sign "`~a` is no value" (tok-text sign)))
       (define v (- (number-value (tok-text n))))
       (values (if (exact-integer? v) "integer" "decimal") v)]))
  (hasheq 'name (name-of name) (value-key (if type (tok-text type) inferred)) value))

;; ---- SELECT: the items of a select --------------------------------------------------------------
;; items-of : (items (item …) …) toks -> (values columns selects unions)
;; The items in the order written are the columns of the table in that order:
;;   the columns that come first are the select's own `column`;
;;   after them, a (SELECT …) is a nested select, and a further run of columns is a nested select
;;   of those columns alone;
;;   a (SELECT … UNION ALL SELECT …) group is the select's `unionAll`, and comes last.
(define (items-of tree toks)
  (define items (map cadr (cdr tree)))
  (define (column? i) (eq? (car i) 'column))
  (define-values (own rest) (splitf-at items column?))
  (define-values (selects unions)
    (let loop ([rest rest] [selects '()])
      (cond
        [(null? rest) (values (reverse selects) '())]
        [(column? (car rest))
         (define-values (run more) (splitf-at rest column?))
         (loop more (cons (hasheq 'column (map (lambda (c) (column-of c toks)) run)) selects))]
        [(eq? (caar rest) 'nested) (loop (cdr rest) (cons (select-of (cadar rest) toks) selects))]
        [(pair? (cdr rest))
         (problem (first-tok (cadr rest))
                  "a UNION ALL group comes last in its SELECT: write what follows before it, or wrap the group as (SELECT (… UNION ALL …))")]
        [else (values (reverse selects) (map (lambda (s) (select-of s toks)) (cdar rest)))])))
  (values (map (lambda (c) (column-of c toks)) own) selects unions))

;; select-of : (select [items] [source]) toks -> a select element
(define (select-of tree toks)
  (define items (sub 'items (cdr tree)))
  (define source (sub 'source (cdr tree)))
  (define-values (columns selects unions) (if items (items-of items toks) (values '() '() '())))
  (define iteration
    (match source
      [#f '()]
      [(list 'source (list 'each path)) (list (cons 'forEach (path-of path toks)))]
      [(list 'source (list 'each path _or _null)) (list (cons 'forEachOrNull (path-of path toks)))]
      [(list 'source (list 'repeat paths ...)) (list (cons 'repeat (map (lambda (p) (path-of p toks)) paths)))]))
  (for/fold ([h (hasheq)]) ([kv (in-list (append iteration
                                                  (if (pair? columns) (list (cons 'column columns)) '())
                                                  (if (pair? selects) (list (cons 'select selects)) '())
                                                  (if (pair? unions) (list (cons 'unionAll unions)) '())))])
    (hash-set h (car kv) (cdr kv))))

;; column-of : (column path [name] option …) toks -> a column
;; Without AS the path is one element's name, and that is the column's name.
(define (column-of tree toks)
  (match-define (list 'column path rest ...) tree)
  (define name (sub 'name rest))
  (define text (path-of path toks))
  (define column-name
    (cond [name (name-of name)]
          [(match path [(list 'path (list 'ptok (? tok? t))) (eq? (tok-type t) 'WORD)] [_ #f]) text]
          [else (problem (first-tok path) "this column needs a name: write `~a AS <name>`" text)]))
  (for/fold ([c (hasheq 'path text 'name column-name)]) ([o (in-list rest)] #:unless (eq? (car o) 'name))
    (define-values (key value)
      (match o
        [(list 'type parts ...)
         (values 'type
                 (if (eq? (tok-type (car parts)) 'STRING)
                     (text-of (car parts))
                     (begin (for ([p (in-list parts)] #:when (and (eq? (tok-type p) 'SYMBOL) (not (equal? (tok-text p) "."))))
                              (problem p "`~a` is no part of a type's name: write a type as `dateTime`, `Observation.referenceRange` or a url in quotes" (tok-text p)))
                            (apply string-append (map tok-text parts)))))]
        [(list 'collection _) (values 'collection #t)]
        [(list 'collection _not _) (values 'collection #f)]
        [(list 'description t) (values 'description (text-of t))]
        [(list 'tag n v) (values 'tag (append (hash-ref c 'tag '()) (list (hasheq 'name (text-of n) 'value (text-of v)))))]))
    (when (and (hash-has-key? c key) (not (eq? key 'tag)))
      (problem (first-tok o) "this column says its ~a twice" (if (eq? key 'collection) "COLLECTION" (string-upcase (symbol->string key)))))
    (hash-set c key value)))

;; condition-of : (condition path [description]) toks -> a where
(define (condition-of tree toks)
  (match tree
    [(list 'condition path) (hasheq 'path (path-of path toks))]
    [(list 'condition path (list 'description t)) (hasheq 'path (path-of path toks) 'description (text-of t))]))

;; ---- paths --------------------------------------------------------------------------------------
;; path-of : (path …) toks -> string   the path as written, from its first token to its last
;; (comments are no part of it, a line break is one space); in double quotes, the text between them
;; as it is. It is FHIRPath, or the problem is said at the path.
(define (path-of tree toks)
  (define ts (leaves tree))
  (define text
    (match tree
      [(list 'path (? tok? quoted)) (quoted-value (tok-text quoted))]
      [_ (path-text toks (tok-index (car ts)) (tok-index (last ts)))]))
  (with-handlers ([exn:fail:diagnostic?
                   (lambda (e) (problem (car ts) "the path ~s is not FHIRPath: ~a" text
                                        (diagnostic-message (exn:fail:diagnostic-diagnostic e))))])
    (parse-fhirpath text))
  text)

(module+ test
  (require rackunit (only-in fhir/diagnostic loc-line loc-column))
  (define (one text) (car (sof->views text)))
  ;; the smallest view: a bare query
  (check-equal? (one "SELECT id, gender FROM Patient")
                (hasheq 'resourceType "ViewDefinition" 'resource "Patient"
                        'select (list (hasheq 'column (list (hasheq 'path "id" 'name "id") (hasheq 'path "gender" 'name "gender"))))))
  ;; a name, the view's other elements, constants, conditions
  (check-equal? (one (string-append
                      "CREATE VIEW bp WITH (status = 'active', fhirVersion = ['4.0', \"5.0\"], experimental = true,\n"
                      "                     contact = [{name: 'A', telecom: [{system: 'url', value: 'http://x'}]}])\n"
                      "AS DECLARE loinc = 'http://loinc.org', top integer = 3, since date = '2020-01-01', at = @2024-01-31T09:00:00Z, r = -1.5\n"
                      "SELECT getResourceKey() AS id FROM Observation\n"
                      "WHERE code.coding.exists(system = %loinc) DESCRIPTION 'coded in LOINC' AND status = 'final'"))
                (hasheq 'resourceType "ViewDefinition" 'name "bp" 'status "active" 'fhirVersion '("4.0" "5.0") 'experimental #t
                        'contact (list (hasheq 'name "A" 'telecom (list (hasheq 'system "url" 'value "http://x"))))
                        'resource "Observation"
                        'constant (list (hasheq 'name "loinc" 'valueString "http://loinc.org") (hasheq 'name "top" 'valueInteger 3)
                                        (hasheq 'name "since" 'valueDate "2020-01-01") (hasheq 'name "at" 'valueDateTime "2024-01-31T09:00:00Z")
                                        (hasheq 'name "r" 'valueDecimal -1.5))
                        'select (list (hasheq 'column (list (hasheq 'path "getResourceKey()" 'name "id"))))
                        'where (list (hasheq 'path "code.coding.exists(system = %loinc)" 'description "coded in LOINC")
                                     (hasheq 'path "status = 'final'"))))
  ;; the items of a select, in the order written: own columns, nested selects, a run of columns
  ;; after one, the UNION ALL group last
  (define (selects text) (hash-ref (one text) 'select))
  (define (col p [n p]) (hasheq 'path p 'name n))
  (check-equal? (selects "SELECT id, (SELECT family FROM name), gender FROM Patient")
                (list (hasheq 'column (list (col "id")))
                      (hasheq 'forEach "name" 'column (list (col "family")))
                      (hasheq 'column (list (col "gender")))))
  (check-equal? (selects "SELECT (SELECT id, (SELECT system, value FROM telecom OR NULL), (SELECT use), x FROM contact) FROM Patient")
                (list (hasheq 'forEach "contact" 'column (list (col "id"))
                              'select (list (hasheq 'forEachOrNull "telecom" 'column (list (col "system") (col "value")))
                                            (hasheq 'column (list (col "use")))
                                            (hasheq 'column (list (col "x")))))))
  (check-equal? (selects "SELECT id, (SELECT linkId FROM REPEAT item, answer.item) FROM QuestionnaireResponse")
                (list (hasheq 'column (list (col "id"))) (hasheq 'repeat '("item" "answer.item") 'column (list (col "linkId")))))
  (check-equal? (selects "SELECT id, (SELECT value FROM telecom UNION ALL SELECT value FROM contact.telecom) FROM Patient")
                (list (hasheq 'column (list (col "id")))
                      (hasheq 'unionAll (list (hasheq 'forEach "telecom" 'column (list (col "value")))
                                              (hasheq 'forEach "contact.telecom" 'column (list (col "value")))))))
  (check-equal? (selects "SELECT (SELECT id, (SELECT a UNION ALL SELECT a)) FROM Patient")
                (list (hasheq 'column (list (col "id")) 'unionAll (list (hasheq 'column (list (col "a"))) (hasheq 'column (list (col "a")))))))
  (check-equal? (selects "SELECT (SELECT FROM name) FROM Patient") (list (hasheq 'forEach "name")))
  ;; a column: AS (FHIRPath's own `as` stays in the path), a name in backticks, its options
  (check-equal? (selects (string-append "SELECT value as Quantity AS `ALL` TYPE Quantity,\n"
                                        "  name.given AS given COLLECTION DESCRIPTION 'every given name' TAG 'ansi/type' = 'VARCHAR' TAG 'k' = 'v',\n"
                                        "  id NOT COLLECTION TYPE 'http://hl7.org/fhir/StructureDefinition/id' FROM Observation"))
                (list (hasheq 'column (list (hasheq 'path "value as Quantity" 'name "ALL" 'type "Quantity")
                                            (hasheq 'path "name.given" 'name "given" 'collection #t 'description "every given name"
                                                    'tag (list (hasheq 'name "ansi/type" 'value "VARCHAR") (hasheq 'name "k" 'value "v")))
                                            (hasheq 'path "id" 'name "id" 'collection #f 'type "http://hl7.org/fhir/StructureDefinition/id")))))
  ;; a path: as written, comments out, a line break one space; in double quotes, as it is
  (check-equal? (selects "SELECT name.where(use = 'official') -- the legal name\n   .family.first() AS family, \"gender\" AS g FROM Patient")
                (list (hasheq 'column (list (col "name.where(use = 'official') .family.first()" "family") (col "gender" "g")))))
  ;; several statements
  (check-equal? (map (lambda (v) (hash-ref v 'resource)) (sof->views "SELECT id FROM Patient;\n\nCREATE VIEW o AS SELECT id FROM Observation;"))
                '("Patient" "Observation"))
  (check-equal? (sof->views "  -- nothing\n") '())
  ;; where each statement begins
  (check-equal? (map (lambda (c) (loc-line (compiled-loc c))) (compile-sof "SELECT id FROM Patient;\n\nCREATE VIEW o AS SELECT id FROM Observation")) '(1 3))
  ;; ---- problems, each at its place --------------------------------------------------------------
  (define (refusal text)
    (with-handlers ([exn:fail:diagnostic? (lambda (e) (define d (exn:fail:diagnostic-diagnostic e))
                                            (format "~a:~a: ~a" (loc-line (diagnostic-loc d)) (loc-column (diagnostic-loc d)) (diagnostic-message d)))])
      (sof->views text) #f))
  (check-equal? (refusal "SELECT id FROM") "1:11: the statement ends after `FROM`")
  (check-equal? (refusal "SELECT id,\n  name.family\nFROM Patient") "2:3: this column needs a name: write `name.family AS <name>`")
  (check-equal? (refusal "SELECT id, name. AS n FROM Patient") "1:12: the path \"name.\" is not FHIRPath: the expression ends after `.`")
  (check-equal? (refusal "select id from Patient")
                "1:1: unexpected word `select` (keywords are written in capitals: `SELECT`; in lower case `select` is read as part of a path)")
  (check-equal? (refusal "SELECT id FROM Patient where active")
                "1:24: unexpected word `where` (keywords are written in capitals: `WHERE`; in lower case `where` is read as part of a path)")
  (check-equal? (refusal "SELECT (SELECT a UNION ALL SELECT a), id FROM Patient")
                "1:39: a UNION ALL group comes last in its SELECT: write what follows before it, or wrap the group as (SELECT (… UNION ALL …))")
  (check-equal? (refusal "DECLARE n int = 3 SELECT id FROM Patient")
                (string-append "1:11: `int` is no type a constant takes: " (string-join constant-types ", ")))
  (check-equal? (refusal "CREATE VIEW v WITH (resource = 'Patient') AS SELECT id FROM Patient")
                "1:21: `resource` is not written in WITH (…): the statement itself says it (FROM <Resource>)")
  (check-equal? (refusal "CREATE VIEW v WITH (status = active) AS SELECT id FROM Patient")
                "1:30: `active` is no value: a string is written in quotes ('active'); true, false and null are the bare words")
  (check-equal? (refusal "SELECT id TYPE id TYPE string FROM Patient") "1:24: this column says its TYPE twice")
  (check-equal? (refusal "SELECT id FROM Patient.name") "1:23: unexpected symbol `.`"))

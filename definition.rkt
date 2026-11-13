#lang racket/base

;;; definition.rkt — a view held to the definition of one.
;;;
;;; The definition of a ViewDefinition is the IG's StructureDefinition (spec/, read once): the
;;; generated model parses a view strictly (names, shapes, list or scalar), and what the model does
;;; not hold is read from the definition's snapshot here, as DATA:
;;;   - the elements it requires (min 1) that the view lacks, each named where it is missing;
;;;   - the codes outside a required value set;
;;;   - the definition's own constraints (`sql-name`: a name a database takes; `sql-expressions`: at
;;;     most one of forEach, forEachOrNull and repeat), each a FHIRPath expression evaluated on the
;;;     element it is stated on.
;;;
;;; An Element is the snapshot's JSON for one element (path, min, binding, constraint,
;;; contentReference). A Problem is a string: where, and what is wrong.

(require racket/contract racket/list racket/string racket/runtime-path racket/promise
         (only-in sql-on-fhir/model/types)                  ; registers ViewDefinition over the R6 tower
         (only-in fhir/model/node fhir? fhir-ref)
         (only-in fhir/serialize/from-json from-json)
         (only-in fhir/result/result ok? ok-value err-error validation-error-message)
         (only-in fhir/package read-package)
         (only-in fhir/model/binding binding-expansion)
         (only-in fhirpath/parser/parse parse-fhirpath)
         (only-in fhirpath/eval eval-fhirpath)
         (only-in fhirpath/value item->system))

(provide
 (contract-out
  ;; read-view : ViewDefinition jsexpr -> typed node | (non-empty listof Problem)
  ;; the view as the generated model reads it, when it is one by the definition: the strict parse,
  ;; every required element but `status`, every required binding, the definition's constraints
  [read-view (-> hash? (or/c fhir? (non-empty-listof string?)))]
  ;; definition-url : the canonical of the definition (what a view's `resourceDefinition` names)
  [definition-url (-> string?)]))

;; ---- the definition -----------------------------------------------------------------------------
(define-runtime-path ig-package "spec/hl7.fhir.uv.sql-on-fhir.tgz")
(define definition                        ; the StructureDefinition's JSON
  (delay
    (define-values (_m resources _e)
      (read-package ig-package #:select (lambda (n) (regexp-match? #rx"StructureDefinition-ViewDefinition[.]json$" n))))
    (cdr (car resources))))
(define (definition-url) (hash-ref (force definition) 'url))
(define definition-elements               ; (listof Element)
  (delay (hash-ref (hash-ref (force definition) 'snapshot (hasheq)) 'element '())))

;; definition-children : definition path -> (listof Element)   the elements one step below it
(define (definition-children def)
  (define prefix (string-append def "."))
  (for/list ([e (in-list (force definition-elements))]
             #:when (let ([p (hash-ref e 'path)])
                      (and (string-prefix? p prefix) (not (regexp-match? #rx"[.]" p (string-length prefix))))))
    e))

;; ---- reading a view -----------------------------------------------------------------------------
(define (read-view js0)
  ;; R6 writes a resource that is not in the core specification (an "additional resource", as
  ;; ViewDefinition is) with the canonical of its definition beside `resourceType`; the IG's own
  ;; examples carry it. It names the definition and is no element of it.
  (define named (hash-ref js0 'resourceDefinition #f))
  (define js (hash-set (hash-remove js0 'resourceDefinition) 'resourceType "ViewDefinition"))
  (define r (from-json js))
  (define problems
    (cond
      [(not (equal? (hash-ref js0 'resourceType "ViewDefinition") "ViewDefinition"))
       (list (format "the resource is a ~a" (hash-ref js0 'resourceType)))]
      [(and named (not (and (string? named) (equal? (car (string-split named "|" #:trim? #f)) (definition-url)))))
       (list (format "`resourceDefinition` is ~s: a ViewDefinition's is ~a" named (definition-url)))]
      [(not (ok? r)) (list (validation-error-message (err-error r)))]
      [else (append (definition-problems js (ok-value r)) (binding-problems js))]))
  (if (null? problems) (ok-value r) problems))

;; binding-problems : ViewDefinition jsexpr -> (listof Problem)
;; the codes outside their required value sets (the definition's bindings); a value set without an
;; offline expansion fails open.
(define required-bindings                ; (listof (cons (listof symbol) value-set-url))
  (delay
    (for*/list ([e (in-list (force definition-elements))]
                [b (in-value (hash-ref e 'binding #f))]
                #:when (and (hash? b) (equal? (hash-ref b 'strength #f) "required") (hash-ref b 'valueSet #f)
                            (not (regexp-match? #rx"\\[x\\]" (hash-ref e 'path)))))
      (cons (map string->symbol (cdr (string-split (hash-ref e 'path) ".")))
            (car (string-split (hash-ref b 'valueSet) "|"))))))
(define (binding-problems js)
  (for*/list ([pb (in-list (force required-bindings))]
              [exp (in-value (binding-expansion (cdr pb)))] #:when exp
              [v (in-list (values-at js (car pb)))]
              #:when (and (string? v) (not (hash-ref exp v #f))))
    (format "~s is not in the required value set for ViewDefinition.~a (~a)"
            v (string-join (map symbol->string (car pb)) ".") (cdr pb))))
;; values-at : jsexpr (listof symbol) -> (listof jsexpr)   every value at a path (lists fan out)
(define (values-at v path)
  (cond [(list? v) (append-map (lambda (x) (values-at x path)) v)]
        [(null? path) (list v)]
        [(hash? v) (values-at (hash-ref v (car path) '()) (cdr path))]
        [else '()]))

;; definition-problems : ViewDefinition jsexpr typed-node -> (listof Problem)
;; Structural recursion over the view's JSON beside the definition, the typed node alongside (the
;; constraints' FHIRPath runs on it). At each element of the definition:
;;   - there, with constraints of the definition's own: each item that breaks one, named where it
;;     is (`select[0].column[1].name "first-name"`);
;;   - there, an object: its own elements, below. A contentReference continues at the element it
;;     names (a nested select is a select);
;;   - absent and required (min 1 or more): named where it is missing with what it is. The strict
;;     parse cannot say so: it reads the elements that are there. A choice (`value[x]`) is there
;;     when any of its members is.
(define (definition-problems js node)
  (let below ([obj js] [node node] [def "ViewDefinition"] [shown #f])
    (append*
     (for/list ([e (in-list (definition-children def))])
       (define name (last (string-split (hash-ref e 'path) ".")))
       (define value (member-value obj name))
       (define items (cond [(memq value '(#f null)) '()] [(list? value) value] [else (list value)]))
       (define typed (typed-items node name))
       (define (place i) (format "~a~a~a" (if shown (string-append shown ".") "") name (if (list? value) (format "[~a]" i) "")))
       (cond
         [(pair? items)
          (define continues (cond [(hash-ref e 'contentReference #f) => (lambda (ref) (cadr (regexp-match #rx"#(.*)$" ref)))]
                                  [else (hash-ref e 'path)]))
          (append*
           (for/list ([item (in-list items)] [i (in-naturals)])
             (define typed-item (and (< i (length typed)) (list-ref typed i)))
             (append (for/list ([c (in-list (own-constraints (definition-element continues)))]
                                #:when (and typed-item (broken? c typed-item)))
                       (format "~a~a ~a" (place i) (if (string? item) (format " ~s" item) "") (constraint-words c)))
                     (if (hash? item) (below item typed-item continues (place i)) '()))))]
         [(and (>= (hash-ref e 'min 0) 1) (not (member (hash-ref e 'path) unheld-required)))
          (list (format "~a has no `~a` (~a)" (or shown "the view") name
                        (hash-ref required-words (hash-ref e 'path) (lambda () (hash-ref e 'short "required")))))]
         [else '()])))))
;; `status` is required by the definition (1..1) and NOT held: 33 of the 133 views the shared suite
;; expects to run leave it out, so refusing a view without it would refuse the suite's own
;; (tests/tck-test.rkt counts them).
(define unheld-required '("ViewDefinition.status"))
;; what a required element is, in the words of someone writing a view (else the definition's `short`)
(define required-words
  (hash "ViewDefinition.resource" "the type of resource the view reads, such as \"Patient\""
        "ViewDefinition.select" "the columns of the table"
        "ViewDefinition.select.column.name" "the column's name in the table"
        "ViewDefinition.select.column.path" "the FHIRPath expression that gives the column's value"
        "ViewDefinition.where.path" "the FHIRPath condition a resource must meet"
        "ViewDefinition.constant.name" "the name paths call it by, as %name"
        "ViewDefinition.constant.value[x]" "its value, such as valueString"))
;; definition-element : definition path -> Element | #f
(define (definition-element path)
  (for/first ([e (in-list (force definition-elements))] #:when (equal? (hash-ref e 'path) path)) e))
;; member-value : object element-name -> jsexpr | #f   the element's value; of a choice, its first member's
(define (member-value obj name)
  (cond [(regexp-match #rx"^(.*)\\[x\\]$" name)
         => (lambda (m) (for/first ([(k v) (in-hash obj)] #:when (string-prefix? (symbol->string k) (cadr m))) v))]
        [else (hash-ref obj (string->symbol name) #f)]))
;; typed-items : typed-node|#f element-name -> (listof typed value)   the element's items in the
;; typed node, in the JSON's order (none for a choice: nothing is stated on one)
(define (typed-items node name)
  (define v (if (and (fhir? node) (not (regexp-match? #rx"\\[x\\]$" name))) (fhir-ref node (string->symbol name) '()) '()))
  (cond [(list? v) v] [v (list v)] [else '()]))

;; ---- the definition's constraints ---------------------------------------------------------------
;; A Constraint is the definition's JSON for one (key, severity, human, expression, source).
;; own-constraints : Element|#f -> (listof Constraint)   the errors the definition itself states on
;; the element (those of the types it builds on — ele-1, dom-* — are the base specification's)
(define (own-constraints e)
  (for/list ([c (in-list (if e (hash-ref e 'constraint '()) '()))]
             #:when (and (equal? (hash-ref c 'source #f) (definition-url))
                         (equal? (hash-ref c 'severity #f) "error")
                         (string? (hash-ref c 'expression #f))))
    c))
;; broken? : Constraint typed-value -> boolean   its expression is false on the value. Only a plain
;; false breaks it: an expression that does not evaluate decides nothing.
(define (broken? c v)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (equal? (map item->system (eval-fhirpath (parse-fhirpath (hash-ref c 'expression)) (list v) #:strict? #f))
            '(#f))))
;; constraint-words : Constraint -> string   what breaking it means, for someone writing a view
;; (else the first paragraph of the definition's own words)
(define (constraint-words c)
  (hash-ref constraint-own-words (hash-ref c 'key #f)
            (lambda () (string-normalize-spaces (car (regexp-split #rx"\n[ \t]*\n" (hash-ref c 'human "breaks a rule of the definition")))))))
(define constraint-own-words
  (hash "sql-name" "is not a name a database takes: letters, digits and _ only, starting with a letter"
        "sql-expressions" "has more than one of `forEach`, `forEachOrNull` and `repeat`: a select takes one"))

(module+ test
  (require rackunit)
  (define view (hasheq 'resourceType "ViewDefinition" 'name "patients" 'status "active" 'resource "Patient"
                       'select (list (hasheq 'column (list (hasheq 'name "id" 'path "id"))))))
  (check-true (fhir? (read-view view)))
  (check-equal? (definition-url) "http://hl7.org/fhir/StructureDefinition/ViewDefinition")
  ;; the constraints held are the definition's own, read from it: these two, at these elements
  (check-equal? (for*/list ([e (in-list (force definition-elements))] [c (in-list (own-constraints e))])
                  (list (hash-ref e 'path) (hash-ref c 'key)))
                '(("ViewDefinition.name" "sql-name") ("ViewDefinition.constant.name" "sql-name")
                  ("ViewDefinition.select" "sql-expressions") ("ViewDefinition.select.column.name" "sql-name")))
  ;; sql-name: the view's, a constant's and a column's name, each said where it is, with the name
  (define (column name) (hasheq 'column (list (hasheq 'name name 'path "id"))))
  (check-equal? (read-view (hash-set* view 'name "my patients"
                                      'constant (list (hasheq 'name "_c" 'valueString "x"))
                                      'select (list (column "id") (hasheq 'select (list (column "first-name"))))))
                '("name \"my patients\" is not a name a database takes: letters, digits and _ only, starting with a letter"
                  "constant[0].name \"_c\" is not a name a database takes: letters, digits and _ only, starting with a letter"
                  "select[1].select[0].column[0].name \"first-name\" is not a name a database takes: letters, digits and _ only, starting with a letter"))
  ;; sql-expressions: a select with two of forEach, forEachOrNull and repeat — a nested one and a
  ;; unionAll branch are selects too
  (define (both . more) (apply hasheq 'forEach "name" 'forEachOrNull "name" 'column (list (hasheq 'name "f" 'path "family")) more))
  (check-equal? (read-view (hash-set view 'select (list (both))))
                '("select[0] has more than one of `forEach`, `forEachOrNull` and `repeat`: a select takes one"))
  (check-equal? (read-view (hash-set view 'select (list (hasheq 'unionAll (list (column "f") (hasheq 'repeat '("item") 'forEach "item" 'column (list (hasheq 'name "f" 'path "id"))))))))
                '("select[0].unionAll[1] has more than one of `forEach`, `forEachOrNull` and `repeat`: a select takes one"))
  (check-true (fhir? (read-view (hash-set view 'select (list (hasheq 'forEach "name" 'column (list (hasheq 'name "f" 'path "family"))))))))
  ;; a constraint with no words of ours is said in the definition's, its first paragraph
  (check-equal? (constraint-words (hasheq 'key "sql-new" 'human "Only so\nmany.\n\nBecause."))  "Only so many.")
  ;; R6's `resourceDefinition` names the definition (the IG's examples carry it) and is no element
  (check-true (fhir? (read-view (hash-set view 'resourceDefinition "http://hl7.org/fhir/StructureDefinition/ViewDefinition|3.0.0-ballot"))))
  (check-equal? (read-view (hash-set view 'resourceDefinition "http://hl7.org/fhir/StructureDefinition/Other"))
                '("`resourceDefinition` is \"http://hl7.org/fhir/StructureDefinition/Other\": a ViewDefinition's is http://hl7.org/fhir/StructureDefinition/ViewDefinition"))
  ;; a resource of another type is not read as a view
  (check-equal? (read-view (hasheq 'resourceType "Library" 'status "active")) '("the resource is a Library"))
  ;; required elements, required bindings and the strict parse (operations.rkt's tests run them
  ;; through $sql-run)
  (check-equal? (read-view (hash-remove view 'resource))
                '("the view has no `resource` (the type of resource the view reads, such as \"Patient\")"))
  (check-match (read-view (hash-set view 'status "live")) (list (regexp #rx"\"live\" is not in the required value set")))
  (check-match (read-view (hash-set view 'selct "x")) (list (regexp #rx"unknown field"))))

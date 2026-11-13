#lang racket/base

;;; unread.rkt — what a view reads that the data's read left out.
;;;
;;; A view runs over resources read leniently (`from-json #:lenient? #t`): an element the FHIR
;;; version read does not have (R4's `medicationCodeableConcept` read as R6) and a value that is not
;;; valid FHIR (a dateTime with a time and no zone) are dropped, and the column that reads them is
;;; empty without a word. `fhir/serialize/lenient`'s `lenient-drops` names every such value; most of
;;; them are of no concern to a given view, so only the drops ON A PATH THE VIEW READS are reported,
;;; summed over the resources: one note per dropped element and reason.
;;;
;;; A Step is (cons name variant): an element's name, and the type a choice was narrowed to with
;;;   `ofType(T)` / `as T` ("Quantity") or #f. A dropped JSON key matches a step when it is the name,
;;;   or the name's choice member: `valueQuantity` for (value . "Quantity"), any `value<Type>` for
;;;   (value . #f).
;;; A Chain is a (listof Step): the elements a path walks from the resource, functions left out —
;;;   `name.where(use = 'official').family.first()` is [name family], and its condition [name use].
;;; A Read is (cons resource-jsexpr drops): a resource and the values its read left out — a
;;;   (listof Drop) (fhir/serialize/lenient), or 'unreadable when it could not be read at all.
;;; A drop is RELEVANT to a chain when the two agree step by step for as long as both go: a dropped
;;; `period.start` concerns a view that reads `period.start` or all of `period`, not one that reads
;;; `period.end`.

(require racket/contract racket/list racket/string racket/match
         (only-in fhir/serialize/lenient drops-message)
         (only-in fhirpath/parser/parse parse-fhirpath)
         (only-in fhirpath/parser/ast fp-invoke fp-call fp-index fp-binop fp-unop fp-typeop fp-var fp-extern)
         (only-in fhirpath/analyze analyze)
         (only-in fhirpath/error exn:fp?))

(provide
 (contract-out
  ;; view-chains : ViewDefinition jsexpr -> (listof Chain)   every path of the view (columns under
  ;; their forEach, where clauses, function arguments), as the elements it walks
  [view-chains (-> hash? (listof (listof (cons/c string? (or/c string? #f)))))]
  ;; unread-notes : view reads total version-name -> (listof string)
  ;; one sentence per (element, reason) the reads dropped on a path the view reads; `total` is how
  ;; many resources were read, `version-name` the FHIR version they were read as ("R6")
  [unread-notes (-> hash? (listof (cons/c hash? (or/c list? 'unreadable))) exact-nonnegative-integer? string?
                    (listof string?))]))

;; ---- the view's chains --------------------------------------------------------------------------
;; functions whose argument is evaluated on each item of their input (the others — combine, union,
;; subsetOf … — take theirs from the focus the whole path started at)
(define item-functions '(where select all exists repeat aggregate sort iif trace))

(define (view-chains view)
  (define type (let ([t (hash-ref view 'resource #f)]) (and (string? t) (string->symbol t))))
  (define seen '())
  (define (note! chains) (set! seen (append seen (filter pair? chains))) chains)
  (define (extend chains name) (for/list ([c (in-list chains)]) (append c (list (cons name #f)))))
  (define (narrow chains type-name)                       ; ofType(T), as T: the last step's member
    (for/list ([c (in-list chains)])
      (if (null? c) c (append (drop-right c 1) (list (cons (car (last c)) (capitalized type-name)))))))
  ;; ends : ast (listof Chain) -> (listof Chain)   where the expression's values sit, from the focus
  (define (ends ast focus)
    (match ast
      [(fp-invoke #f (== type)) #:when (equal? focus '(())) focus]       ; `Patient.name`: the resource itself
      [(fp-invoke t n) (extend (if t (ends t focus) focus) (symbol->string n))]
      [(fp-call t (or 'ofType 'as) (list ty)) #:when (type-name ty) (narrow (if t (ends t focus) focus) (type-name ty))]
      [(fp-call t 'extension _) (extend (if t (ends t focus) focus) "extension")]
      [(fp-call t 'getResourceKey '()) (extend (if t (ends t focus) focus) "id")]
      [(fp-call t n args)
       (define base (if t (ends t focus) focus))
       (for ([a (in-list args)]) (note! (ends a (if (memq n item-functions) base focus))))
       base]
      [(fp-index t _) (ends t focus)]
      [(fp-typeop 'as o ty) (narrow (ends o focus) (symbol->string ty))]
      [(fp-typeop _ o _) (ends o focus)]
      [(fp-binop _ l r) (append (ends l focus) (ends r focus))]
      [(fp-unop _ o) (ends o focus)]
      [(fp-var '$this) focus]
      [(fp-extern (or "resource" "rootResource" "context")) '(())]
      [_ '()]))
  (define (path-ends text focus)
    (with-handlers ([exn:fail? (lambda (_) '())]) (ends (parse-fhirpath text) focus)))
  (define (select! sel focus)
    (when (hash? sel)
      (cond
        ;; repeat's paths are followed at every level: all of each element is read
        [(hash-ref sel 'repeat #f)
         => (lambda (paths) (for ([p (in-list (if (list? paths) paths '()))] #:when (string? p)) (note! (path-ends p focus))))]
        [else
         (define each (or (hash-ref sel 'forEach #f) (hash-ref sel 'forEachOrNull #f)))
         (define inner (if (string? each) (path-ends each focus) focus))
         (for ([c (in-list (hash-ref sel 'column '()))] #:when (and (hash? c) (string? (hash-ref c 'path #f))))
           (note! (path-ends (hash-ref c 'path) inner)))
         (for ([s (in-list (append (hash-ref sel 'select '()) (hash-ref sel 'unionAll '())))]) (select! s inner))])))
  (for ([s (in-list (hash-ref view 'select '()))]) (select! s '(())))
  (for ([w (in-list (hash-ref view 'where '()))] #:when (and (hash? w) (string? (hash-ref w 'path #f))))
    (note! (path-ends (hash-ref w 'path) '(()))))
  (remove-duplicates seen))

;; type-name : ast -> string | #f   the type an `ofType` argument names (`Quantity`, `FHIR.Quantity`)
(define (type-name ast)
  (match ast
    [(fp-invoke (or #f (fp-invoke #f _)) n) (symbol->string n)]
    [_ #f]))
(define (capitalized s) (if (string=? s "") s (string-append (string (char-upcase (string-ref s 0))) (substring s 1))))

;; ---- which drops concern the view ---------------------------------------------------------------
;; drop-steps : drop-path -> (listof string)   `name[1]._family` -> ("name" "family")
(define (drop-steps path)
  (for/list ([s (in-list (string-split path "."))])
    (regexp-replace #rx"^_" (regexp-replace* #rx"\\[[0-9]+\\]" s "") "")))
;; drop-element : drop-path -> string   the path without its indexes: `name[1].family` -> name.family
(define (drop-element path) (regexp-replace* #rx"\\[[0-9]+\\]" path ""))

(define (step-match? key step)
  (match-define (cons name variant) step)
  (or (string=? key name)
      (if variant
          (string=? key (string-append name variant))
          (and (> (string-length key) (string-length name)) (string-prefix? key name)
               (char-upper-case? (string-ref key (string-length name)))))))
;; relevant? : (listof string) (listof Chain) -> boolean
(define (relevant? steps chains)
  (and (pair? steps)
       (for/or ([c (in-list chains)])
         (for/and ([k (in-list steps)] [s (in-list c)]) (step-match? k s)))))

;; drop-kind : Drop type-symbol -> 'no-element | 'invalid
;; whether the FHIR version read has the element at all (FHIRPath's static pass over the dropped
;; path decides; anything it cannot say is a value that did not read)
(define (drop-kind d type)
  (define text (string-join (for/list ([s (in-list (drop-steps (car d)))]) (format "`~a`" s)) "."))
  (with-handlers ([exn:fp? (lambda (e) (if (regexp-match? #rx"no element" (exn-message e)) 'no-element 'invalid))]
                  [exn:fail? (lambda (_) 'invalid)])
    (analyze (parse-fhirpath text) type #:strict? #f)
    'invalid))

;; why : Drop type -> string | #f   what is wrong with a value that did not read, when it can be told
(define (why d type)
  (define v (cadr d))
  (cond [(not (string? v)) #f]
        [(regexp-match #rx" is no date: (.*)$" (drops-message (list d) type)) => cadr]
        [(regexp-match? #px"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+$" v) "a time needs a time zone, such as Z or +01:00"]
        [else #f]))

(define (unread-notes view reads total version-name)
  (define type (hash-ref view 'resource ""))
  (define type-symbol (string->symbol type))
  (define chains (view-chains view))
  (define (reference r) (let ([id (hash-ref r 'id #f)]) (if (string? id) (format "~a/~a" type id) "a resource with no id")))
  (define (counted n) (format "~a of ~a ~a resources ~a" n total type (if (= n 1) "holds" "hold")))
  (define unreadable (for/list ([r (in-list reads)] #:when (eq? (cdr r) 'unreadable)) (car r)))
  ;; groups : (element . kind) -> (listof (cons resource Drop)), in the order first met
  (define-values (order groups)
    (for*/fold ([order '()] [groups (hash)])
               ([r (in-list reads)] #:when (list? (cdr r))
                [d (in-list (cdr r))] #:when (relevant? (drop-steps (car d)) chains))
      (define key (cons (drop-element (car d)) (drop-kind d type-symbol)))
      (values (if (hash-has-key? groups key) order (cons key order))
              (hash-update groups key (lambda (l) (append l (list (cons (car r) d)))) '()))))
  (append
   (if (null? unreadable) '()
       (list (format "~a of ~a ~a resources could not be read as FHIR ~a and ~a not in the table (the first: ~a)"
                     (length unreadable) total type version-name (if (= (length unreadable) 1) "is" "are")
                     (reference (car unreadable)))))
   (for/list ([key (in-list (reverse order))])
     (define hits (hash-ref groups key))
     (define n (length (remove-duplicates (map car hits) eq?)))
     (define first-resource (caar hits))
     (define first-drop (cdar hits))
     (match (cdr key)
       ['no-element
        (format "~a `~a`, which was not read: FHIR ~a has no such element (the first: ~a)~a"
                (counted n) (car key) version-name (reference first-resource)
                (if (equal? version-name "R6") "; --fhir-version 4.0.1 reads the data as R4" ""))]
       ['invalid
        (define v (cadr first-drop))
        (define reason (why first-drop type))
        (format "~a a value at `~a` that is not valid FHIR and was not read (the first: ~a~a~a)"
                (counted n) (car key) (reference first-resource)
                (if (or (string? v) (number? v) (boolean? v)) (format ": ~s" v) "")
                (if reason (format " — ~a" reason) ""))]))))

(module+ test
  (require rackunit (only-in fhir/r6/types))
  (define (view type . paths)
    (hasheq 'resource type 'select (list (hasheq 'column (for/list ([p (in-list paths)]) (hasheq 'name "c" 'path p))))))
  ;; chains: functions are left out, their conditions kept under the element they test; ofType
  ;; narrows the choice; the resource type's own name is no step
  (check-equal? (view-chains (view "Patient" "Patient.name.where(use = 'official').family.first()"))
                '((("name" . #f) ("use" . #f)) (("name" . #f) ("family" . #f))))
  (check-equal? (view-chains (view "Observation" "value.ofType(Quantity).value" "effective as dateTime" "getResourceKey()"))
                '((("value" . "Quantity") ("value" . #f)) (("effective" . "DateTime")) (("id" . #f))))
  ;; a column inside a forEach starts at the element it iterates; a where clause is a path too
  (check-equal? (view-chains (hasheq 'resource "Patient" 'where (list (hasheq 'path "active = true"))
                                     'select (list (hasheq 'forEach "name" 'column (list (hasheq 'name "f" 'path "family"))))))
                '((("name" . #f) ("family" . #f)) (("active" . #f))))
  ;; relevance: step by step for as long as both go; a choice member by its type when narrowed
  (define (concerns? drop . paths) (relevant? (drop-steps drop) (view-chains (apply view "Observation" paths))))
  (check-true (concerns? "effectiveDateTime" "effective.ofType(dateTime)"))
  (check-false (concerns? "effectiveDateTime" "effective.ofType(Period).start"))
  (check-true (concerns? "effectivePeriod.start" "effective.ofType(Period).start"))
  (check-false (concerns? "effectivePeriod.start" "effective.ofType(Period).end"))
  (check-true (concerns? "effectivePeriod.start" "effective"))
  (check-true (concerns? "component[2].valueQuantity" "component.value.ofType(Quantity).value"))
  (check-false (concerns? "note[0].time" "id" "status"))
  ;; the notes: one per element and reason, counted over the resources, the first named
  (define meds (view "MedicationRequest" "id" "medication.ofType(CodeableConcept).text"))
  (define (med id) (hasheq 'resourceType "MedicationRequest" 'id id))
  (check-equal? (unread-notes meds (list (cons (med "m1") '(("medicationCodeableConcept" #hasheq((text . "x")))))
                                         (cons (med "m2") '(("medicationCodeableConcept" #hasheq((text . "y"))) ("note[0].time" "2020-01-01T10:00:00"))))
                              5 "R6")
                (list (string-append "2 of 5 MedicationRequest resources hold `medicationCodeableConcept`, which was not read: "
                                     "FHIR R6 has no such element (the first: MedicationRequest/m1); --fhir-version 4.0.1 reads the data as R4")))
  (define obs (view "Observation" "effective.ofType(dateTime)" "issued"))
  (check-equal? (unread-notes obs (list (cons (hasheq 'id "o1") '(("effectiveDateTime" "2019-01-01T08:00:00")))
                                        (cons (hasheq 'id "o2") '(("issued" "2019-02-30T08:00:00Z")))
                                        (cons (hasheq) 'unreadable))
                              3 "R4")
                (list "1 of 3 Observation resources could not be read as FHIR R4 and is not in the table (the first: a resource with no id)"
                      (string-append "1 of 3 Observation resources holds a value at `effectiveDateTime` that is not valid FHIR and was not read "
                                     "(the first: Observation/o1: \"2019-01-01T08:00:00\" — a time needs a time zone, such as Z or +01:00)")
                      (string-append "1 of 3 Observation resources holds a value at `issued` that is not valid FHIR and was not read "
                                     "(the first: Observation/o2: \"2019-02-30T08:00:00Z\" — February 2019 has 28 days)")))
  ;; nothing the view reads was dropped: nothing is said
  (check-equal? (unread-notes (view "Observation" "id" "status") (list (cons (hasheq 'id "o1") '(("effectiveDateTime" "2019-01-01T08:00:00")))) 1 "R6")
                '()))

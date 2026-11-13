#lang racket/base

;;; operations.rkt — the IG's operations as fhir/operation values, defined by the IG's own
;;; OperationDefinitions (generated from the package into model/operations.rkt):
;;;
;;;   ($sql-run view #:_format "csv")                  a ViewDefinition (the subject) over the data
;;;   (apply-operation "$sql-run" #:subjectCanonical url #:resource bundle)
;;;   (~> view ($sql-run #:_format "fhir"))            rows as a Parameters resource
;;;   (view-rows view [resources])                     the rows themselves, as hashes
;;;   ($sql-export #:subject (list view …))            synchronous: the manifest comes back completed
;;;
;;; $sql-run per the OperationDefinition:
;;;   view   : exactly one of subjectResource (inline; the subject), subjectCanonical (url[|version])
;;;            or subjectReference ("ViewDefinition/id"), the latter two from `current-data-source`
;;;   data   : the inline `resource` inputs (Bundles unwrapped), else the data source's resources of
;;;            the view's type; `patient` keeps that patient's resources (and the Patient), `_since`
;;;            those with meta.lastUpdated after it; `_limit` caps the rows
;;;   output : `_format` ndjson (default) | json | csv (`header`, default true) as a Binary; fhir as a
;;;            Parameters (one `row` per row); parquet is not supported
;;; $sql-export runs every `subject` now and returns the completed manifest, one `output` per subject
;;; with its result inline as a Binary (no job store, no polling).

(require racket/contract racket/list racket/string racket/match json net/base64
         fhir/operation fhir/data-source
         (only-in sql-on-fhir/model/types)                  ; registers ViewDefinition over the R6 tower
         (only-in sql-on-fhir/model/operations sql-run-definition sql-export-definition)
         (only-in "view.rkt" eval-view view-columns)
         (only-in fhir/serialize/from-json from-json)
         (only-in fhir/result/result ok? ok-value err-error)
         (only-in fhir/result/result validation-error-message)
         racket/runtime-path racket/promise (only-in fhir/package read-package)
         (only-in fhir/model/binding binding-expansion)
         (only-in fhir/serialize/lenient lenient-drops))

(provide
 (contract-out
  ;; the IG's two operations as fhir/operation values ($sql-run's subject is the ViewDefinition)
  [$sql-run operation?]
  [$sql-export operation?]
  ;; what the lenient read of the data left out, for a caller that wants to say so: while
  ;; `current-read-log` holds a log (`make-read-log`), every resource a view reads is counted
  ;; (`read-log-count`) and each one whose read dropped values is kept with them (`read-log-reads`:
  ;; (cons resource drops), drops a list of fhir/serialize/lenient Drops, or 'unreadable)
  [current-read-log (parameter/c (or/c #f read-log?))]
  [make-read-log (-> read-log?)]
  [read-log? (-> any/c boolean?)]
  [read-log-count (-> read-log? exact-nonnegative-integer?)]
  [read-log-reads (-> read-log? (listof (cons/c hash? (or/c list? 'unreadable))))]
  ;; a ViewDefinition over the data source (or the resources given) -> its rows, each a hash column -> value
  [view-rows (->* (hash?) ((or/c #f (listof hash?))) (listof hash?))]
  ;; the output formats over eval-view's rows (a Row is an ordered (listof (cons column jsexpr)))
  [rows->csv (->* (list? list?) (#:header? boolean?) string?)]
  [rows->ndjson (-> list? string?)]
  [rows->json (-> list? string?)]))

;; ---- the view and its data ----------------------------------------------------------------------
;; typed-view : ViewDefinition jsexpr -> typed node   strict: the generated schema validates it,
;; every element the definition requires is there (but `status`, below) and every code a required
;; binding governs is in its value set (what the #lang form checks)
(define (typed-view js)
  (define r (from-json (hash-set js 'resourceType "ViewDefinition")))
  (unless (ok? r)
    (operation-error "invalid" "not a valid ViewDefinition: ~a" (validation-error-message (err-error r))))
  (define problems (append (required-problems js) (binding-problems js)))
  (when (pair? problems)
    (operation-error "invalid" "not a valid ViewDefinition: ~a" (string-join problems "; ")))
  (ok-value r))

;; The definition of a ViewDefinition is the IG's StructureDefinition: its snapshot's elements, read
;; from spec/ once. An Element is the snapshot's JSON for one element (path, min, binding,
;; contentReference).
(define-runtime-path ig-package "spec/hl7.fhir.uv.sql-on-fhir.tgz")
(define definition-elements               ; (listof Element)
  (delay
    (define-values (_m resources _e)
      (read-package ig-package #:select (lambda (n) (regexp-match? #rx"StructureDefinition-ViewDefinition[.]json$" n))))
    (append* (for/list ([r (in-list resources)]) (hash-ref (hash-ref (cdr r) 'snapshot (hasheq)) 'element '())))))

;; binding-problems : ViewDefinition jsexpr -> (listof string)
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

;; required-problems : ViewDefinition jsexpr -> (listof string)
;; the elements the definition requires (min 1 or more) that the view lacks, each named where it is
;; missing (`select[0].column[1]`) with what it is. The strict parse cannot say so: it reads the
;; elements that are there. Structural recursion over the view's JSON beside the definition: a
;; contentReference continues at the element it names (a nested select is a select), a choice
;; (`value[x]`) is there when any of its members is.
(define (required-problems js)
  (let absent ([obj js] [def "ViewDefinition"] [shown #f])
    (append*
     (for/list ([e (in-list (definition-children def))])
       (define name (last (string-split (hash-ref e 'path) ".")))
       (define value (member-value obj name))
       (define items (cond [(memq value '(#f null)) '()] [(list? value) value] [else (list value)]))
       (cond
         [(pair? items)
          (define below (cond [(hash-ref e 'contentReference #f) => (lambda (ref) (cadr (regexp-match #rx"#(.*)$" ref)))]
                              [else (hash-ref e 'path)]))
          (append* (for/list ([item (in-list items)] [i (in-naturals)] #:when (hash? item))
                     (absent item below (format "~a~a~a" (if shown (string-append shown ".") "") name
                                                (if (list? value) (format "[~a]" i) "")))))]
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
;; definition-children : definition path -> (listof Element)   the elements one step below it
(define (definition-children def)
  (define prefix (string-append def "."))
  (for/list ([e (in-list (force definition-elements))]
             #:when (let ([p (hash-ref e 'path)])
                      (and (string-prefix? p prefix) (not (regexp-match? #rx"[.]" p (string-length prefix))))))
    e))
;; member-value : object element-name -> jsexpr | #f   the element's value; of a choice, its first member's
(define (member-value obj name)
  (cond [(regexp-match #rx"^(.*)\\[x\\]$" name)
         => (lambda (m) (for/first ([(k v) (in-hash obj)] #:when (string-prefix? (symbol->string k) (cadr m))) v))]
        [else (hash-ref obj (string->symbol name) #f)]))
;; values-at : jsexpr (listof symbol) -> (listof jsexpr)   every value at a path (lists fan out)
(define (values-at v path)
  (cond [(list? v) (append-map (lambda (x) (values-at x path)) v)]
        [(null? path) (list v)]
        [(hash? v) (values-at (hash-ref v (car path) '()) (cdr path))]
        [else '()]))
;; typed-resource : resource jsexpr -> typed node | #f   read leniently: an element the tower lacks
;; and a value that does not parse are left out, and noted in the read log when there is one
(define (typed-resource js)
  (define r (from-json js #:lenient? #t))
  (define node (and (ok? r) (ok-value r)))
  (define log (current-read-log))
  (when log
    (set-read-log-count! log (add1 (read-log-count log)))
    (define drops (if node (lenient-drops js node) 'unreadable))
    (unless (null? drops) (set-read-log-entries! log (cons (cons js drops) (read-log-entries log)))))
  node)
;; A ReadLog is (read-log count entries): how many resources were read, and the Reads that lost
;; something, newest first.
(struct read-log (count entries) #:mutable)
(define (make-read-log) (read-log 0 '()))
(define (read-log-reads log) (reverse (read-log-entries log)))
(define current-read-log (make-parameter #f))

;; the view named by the inputs: inline (the subject), by canonical, or by reference
(define (subject-view in)
  (define inline (input in "subjectResource"))
  (define canonical (input in "subjectCanonical"))
  (define reference (input in "subjectReference"))
  (define given (length (filter values (list inline canonical reference))))
  (unless (= given 1)
    (operation-error "invalid" "exactly one of subjectResource, subjectCanonical and subjectReference is needed; got ~a" given))
  (cond
    [inline inline]
    [canonical (or (stored-view-by-url canonical)
                   (operation-error "not-found" "no ViewDefinition with canonical ~a in the data source" canonical))]
    [else
     (define ref (if (hash? reference) (hash-ref reference 'reference "") reference))
     (define m (regexp-match #px"^(?:.*/)?ViewDefinition/([^/]+)$" ref))
     (or (and m ((data-source-read (current-data-source)) "ViewDefinition" (cadr m)))
         (operation-error "not-found" "cannot resolve subjectReference ~a" ref))]))
(define (stored-view-by-url canonical)
  (define parts (string-split canonical "|"))
  (findf (lambda (v) (and (equal? (hash-ref v 'url #f) (car parts))
                          (or (null? (cdr parts)) (equal? (hash-ref v 'version #f) (cadr parts)))))
         ((data-source-all (current-data-source)) "ViewDefinition")))

;; the resources the view runs over (FHIR JSON)
(define (view-data in view)
  (define inline (append-map bundle-resources (hash-ref in "resource" '())))
  (define base (if (pair? inline) inline ((data-source-all (current-data-source)) (hash-ref view 'resource ""))))
  (define patients (for/list ([p (in-list (hash-ref in "patient" '()))])
                     (if (hash? p) (hash-ref p 'reference "") p)))
  (define since (input in "_since"))
  (for/list ([r (in-list base)]
             #:when (or (null? patients)
                        (for/or ([ref (in-list (patient-reference-of r))]) (member ref patients))
                        (and (equal? (hash-ref r 'resourceType #f) "Patient")
                             (member (string-append "Patient/" (hash-ref r 'id "")) patients)))
             #:when (or (not since)
                        (let ([lu (hash-ref (hash-ref r 'meta (hasheq)) 'lastUpdated #f)]) (and lu (string>? lu since)))))
    r))

;; view-rows : view [resources] -> (listof row-hash)   resources default to the current data source's
(define (view-rows view [resources #f])
  (define v (typed-view view))
  (map row->hash (eval-view v (filter-map typed-resource
                                          (or resources ((data-source-all (current-data-source)) (hash-ref view 'resource "")))))))

;; ---- formats ------------------------------------------------------------------------------------
;; A Row is eval-view's ordered (Listof (cons column jsexpr)).
(define (row->hash row) (for/hasheq ([c (in-list row)]) (values (car c) (cdr c))))
(define (rows->json rows) (jsexpr->string (map row->hash rows)))
(define (rows->ndjson rows)
  (string-append (string-join (for/list ([r (in-list rows)]) (jsexpr->string (row->hash r))) "\n")
                 (if (null? rows) "" "\n")))
;; RFC-4180: quote fields containing comma / quote / CR / LF; a quote doubles
(define (csv-field v)
  (define s (cond [(eq? v 'null) ""] [(boolean? v) (if v "true" "false")]
                  [(list? v) (jsexpr->string v)] [else (format "~a" v)]))
  (if (regexp-match? #px"[\",\r\n]" s) (string-append "\"" (string-replace s "\"" "\"\"") "\"") s))
(define (rows->csv cols rows #:header? [header? #t])
  (define lines
    (append (if header? (list (string-join (map symbol->string cols) ",")) '())
            (for/list ([r (in-list rows)])
              (string-join (for/list ([c (in-list cols)]) (csv-field (cond [(assq c r) => cdr] [else 'null]))) ","))))
  (string-append (string-join lines "\r\n") (if (null? lines) "" "\r\n")))
(define (rows->parameters rows)
  (hasheq 'resourceType "Parameters"
          'parameter (for/list ([r (in-list rows)])
                       (hasheq 'name "row" 'part (filter-map cell->part r)))))
(define (cell->part cell)
  (match-define (cons col v) cell)
  (define name (symbol->string col))
  (cond [(eq? v 'null) #f]
        [(boolean? v) (hasheq 'name name 'valueBoolean v)]
        [(exact-integer? v) (hasheq 'name name 'valueInteger v)]
        [(real? v) (hasheq 'name name 'valueDecimal v)]
        [(list? v) (hasheq 'name name 'valueString (jsexpr->string v))]
        [else (hasheq 'name name 'valueString (format "~a" v))]))
(define (binary content-type body)
  (hasheq 'resourceType "Binary" 'contentType content-type
          'data (bytes->string/utf-8 (base64-encode (string->bytes/utf-8 body) #""))))

;; run : view-jsexpr inputs format -> resource   one view, formatted
(define (run view in fmt #:limit [limit #f] #:header? [header? #t])
  (define v (typed-view view))
  ;; a view that fails on the data (a column with several values and no `collection`) is the
  ;; operation's error, an OperationOutcome, not a crash
  (define rows-all
    (with-handlers ([(lambda (e) (and (exn:fail? e) (not (exn:fail:operation? e))))
                     (lambda (e) (operation-error "processing" "~a" (regexp-replace #rx"^eval-view: " (exn-message e) "")))])
      (eval-view v (filter-map typed-resource (view-data in view)))))
  (define rows (if (and (exact-integer? limit) (>= limit 0)) (take rows-all (min limit (length rows-all))) rows-all))
  (match fmt
    ["ndjson" (binary "application/x-ndjson" (rows->ndjson rows))]
    ["json" (binary "application/json" (rows->json rows))]
    ["csv" (binary "text/csv" (rows->csv (view-columns v) rows #:header? header?))]
    ["fhir" (rows->parameters rows)]
    ["parquet" (operation-error "not-supported" "parquet output is not supported")]
    [_ (operation-error "invalid" "unknown _format ~a" fmt)]))

;; ---- the operations -----------------------------------------------------------------------------
(define $sql-run
  (make-operation
   sql-run-definition #:subject "subjectResource"
   (lambda (in _)
     (run (subject-view in) in (input in "_format" "ndjson")
          #:limit (input in "_limit") #:header? (not (eq? (input in "header" #t) #f))))))

(define export-counter (box 0))
(define $sql-export
  (make-operation
   sql-export-definition
   (lambda (in _)
     (define fmt (input in "_format" "ndjson"))
     (define outputs
       (for/list ([s (in-list (hash-ref in "subject" '()))])
         ;; a subject is a ViewDefinition, a Reference to one, a canonical, or a `subject` parameter
         ;; with parts (subjectResource / subjectCanonical / subjectReference)
         (define parts (if (and (hash? s) (hash-ref s 'part #f))
                           (parameters->inputs (hasheq 'parameter (hash-ref s 'part)))
                           (cond [(and (hash? s) (equal? (hash-ref s 'resourceType #f) "ViewDefinition")) (hash "subjectResource" (list s))]
                                 [(hash? s) (hash "subjectReference" (list s))]
                                 [else (hash "subjectCanonical" (list s))])))
         (define view (subject-view parts))
         (hasheq 'name "output"
                 'part (list (hasheq 'name "name" 'valueString (hash-ref view 'name "view"))
                             (hasheq 'name "location" 'valueUri (format "urn:sql-export:~a" (hash-ref view 'name "view")))
                             (hasheq 'name "result" 'resource (run view in (if (equal? fmt "fhir") "ndjson" fmt)))))))
     (set-box! export-counter (add1 (unbox export-counter)))
     (define id (format "export-~a" (unbox export-counter)))
     (hasheq 'resourceType "Parameters"
             'parameter (append (list (hasheq 'name "exportId" 'valueString id)
                                      (hasheq 'name "status" 'valueCode "completed"))
                                (let ([t (input in "clientTrackingId")])
                                  (if t (list (hasheq 'name "clientTrackingId" 'valueString t)) '()))
                                outputs)))))

(for-each register-operation! (list $sql-run $sql-export))

(module+ test
  (require rackunit)
  (define pts (list (hasheq 'resourceType "Patient" 'id "p1" 'gender "female" 'meta (hasheq 'lastUpdated "2026-01-02T00:00:00Z"))
                    (hasheq 'resourceType "Patient" 'id "p2" 'gender "male")))
  (define view (hasheq 'resourceType "ViewDefinition" 'name "patients" 'status "active" 'resource "Patient"
                       'url "http://example.org/ViewDefinition/patients"
                       'select (list (hasheq 'column (list (hasheq 'name "id" 'path "getResourceKey()")
                                                           (hasheq 'name "gender" 'path "gender"))))))
  (define (body b) (bytes->string/utf-8 (base64-decode (string->bytes/utf-8 (hash-ref b 'data)))))
  (parameterize ([current-data-source (resources->data-source (cons view pts))])
    ;; the view as the subject; data from the data source
    (check-equal? (body ($sql-run view #:_format "csv")) "id,gender\r\np1,female\r\np2,male\r\n")
    (check-equal? (body ($sql-run view #:_format "csv" #:header "false")) "p1,female\r\np2,male\r\n")
    (check-equal? (body (~> view ($sql-run))) "{\"gender\":\"female\",\"id\":\"p1\"}\n{\"gender\":\"male\",\"id\":\"p2\"}\n")
    ;; codes outside their required value sets are refused, as the #lang form refuses them
    (check-exn #rx"\"live\" is not in the required value set for ViewDefinition.status" (lambda () (view-rows (hash-set view 'status "live"))))
    (check-exn #rx"\"Patiant\" is not in the required value set for ViewDefinition.resource" (lambda () (view-rows (hash-set view 'resource "Patiant"))))
    ;; an element the definition requires and the view lacks is refused, named where it is missing:
    ;; an OperationOutcome from $sql-run, not `string->symbol: contract violation`
    (check-exn (lambda (e) (and (exn:fail:operation? e)
                                (equal? (exn-message e)
                                        "not a valid ViewDefinition: the view has no `resource` (the type of resource the view reads, such as \"Patient\")")))
               (lambda () ($sql-run (hash-remove view 'resource))))
    (define (with-columns . cs) (hash-set view 'select (list (hasheq 'column cs) (hasheq 'select (list (hasheq 'column cs))))))
    (check-exn #rx"select\\[0\\].column\\[1\\] has no `name` [(]the column's name in the table[)]; select\\[1\\].select\\[0\\].column\\[1\\] has no `name`"
               (lambda () (view-rows (with-columns (hasheq 'name "id" 'path "id") (hasheq 'path "gender")))))
    (check-exn #rx"select\\[0\\].column\\[0\\] has no `path`" (lambda () (view-rows (with-columns (hasheq 'name "id")))))
    (check-exn #rx"the view has no `select` [(]the columns of the table[)]" (lambda () (view-rows (hash-remove view 'select))))
    (check-exn #rx"where\\[0\\] has no `path`" (lambda () (view-rows (hash-set view 'where (list (hasheq))))))
    (check-exn #rx"constant\\[0\\] has no `value\\[x\\]`" (lambda () (view-rows (hash-set view 'constant (list (hasheq 'name "c"))))))
    (check-not-exn (lambda () (view-rows (hash-set view 'constant (list (hasheq 'name "c" 'valueString "x"))))))
    ;; the read log: what the lenient read left out of each resource, counted over those read
    (let ([log (make-read-log)]
          [odd (hasheq 'resourceType "Patient" 'id "p3" 'gender "female" 'birthDate "1990-02-30")])
      (check-equal? (length (parameterize ([current-read-log log]) (view-rows view (append pts (list odd))))) 3)
      (check-equal? (read-log-count log) 3)
      (check-equal? (read-log-reads log) (list (cons odd '(("birthDate" "1990-02-30"))))))
    ;; `status` is required too and is not held: the shared suite's own views leave it out
    (check-equal? (length (view-rows (hash-remove view 'status))) 2)
    ;; by canonical, filtered, limited
    (check-equal? (body (apply-operation "$sql-run" #:subjectCanonical "http://example.org/ViewDefinition/patients"
                                         #:patient "Patient/p2" #:_format "json"))
                  "[{\"gender\":\"male\",\"id\":\"p2\"}]")
    (check-equal? (length (hash-ref ($sql-run view #:_format "fhir" #:_limit "1") 'parameter)) 1)
    (check-equal? (body ($sql-run view #:_since "2026-01-01" #:_format "csv" #:header "false")) "p1,female\r\n")
    ;; inline data overrides the data source
    (check-equal? (view-rows view (list (cadr pts))) (list (hasheq 'id "p2" 'gender "male")))
    (check-exn #rx"exactly one of" (lambda () ($sql-run view #:subjectCanonical "x")))
    (check-exn #rx"not a valid ViewDefinition" (lambda () ($sql-run (hash-set view 'select "oops"))))
    (check-exn #rx"parquet output is not supported" (lambda () ($sql-run view #:_format "parquet")))
    ;; $sql-export: completed at once, one output per subject
    (define manifest ($sql-export #:subject (list view) #:_format "csv"))
    (check-equal? (for/first ([p (in-list (hash-ref manifest 'parameter))] #:when (equal? (hash-ref p 'name) "status"))
                    (hash-ref p 'valueCode))
                  "completed")))

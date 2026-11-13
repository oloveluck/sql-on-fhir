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
;;;            or subjectReference ("ViewDefinition/id"), the latter two from `current-data-source`.
;;;            A ViewDefinition only: a Library (the specification's SQLQuery, SQLView) is
;;;            `not-supported`, and so `parameters` (a Library's) is refused as the definition says.
;;;   data   : the inline `resource` inputs (Bundles unwrapped), else the data source's resources of
;;;            the view's type; `patient` keeps those patients' resources (and the Patients), `group`
;;;            those of the groups' members — either must resolve —, `_since` those whose
;;;            meta.lastUpdated is after it; `_limit` caps the rows. `source` (an external data
;;;            source) is `not-supported`; `context` has nothing to say of a ViewDefinition.
;;;   output : `_format` ndjson (default) | json | csv (`header`, default true) as a Binary; fhir as a
;;;            Parameters (one `row` per row); parquet is not supported
;;; $sql-export runs every `subject` now and returns the completed manifest, one `output` per subject
;;; (named by the subject's `name` part, else the view's name) with its result inline as a Binary
;;; (no job store, no polling); `_format=fhir` is refused, as the definition says.

(require racket/contract racket/list racket/string racket/match json net/base64
         fhir/operation fhir/data-source
         (only-in sql-on-fhir/model/operations sql-run-definition sql-export-definition)
         (only-in "view.rkt" eval-view view-columns exn:fail:view?)
         (only-in "definition.rkt" read-view)
         (only-in fhir/serialize/from-json from-json)
         (only-in fhir/result/result ok? ok-value)
         (only-in fhir/serialize/lenient lenient-drops)
         (only-in fhirpath/temporal-ops parse-fp-datetime moment-compare))

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
;; typed-view : ViewDefinition jsexpr -> typed node   the view as its definition has it
;; (definition.rkt: the strict parse, required elements but `status`, required bindings, the
;; definition's constraints — what the #lang form checks), else the operation's `invalid` error
(define (typed-view js)
  (match (read-view js)
    [(? list? problems) (operation-error "invalid" "not a valid ViewDefinition: ~a" (string-join problems "; "))]
    [node node]))

;; of-type : (listof resource) type-name -> (listof resource)   a view reads the resources of its type
(define (of-type resources type)
  (filter (lambda (r) (equal? (hash-ref r 'resourceType #f) type)) resources))
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

;; subject-view : Inputs -> ViewDefinition jsexpr   the view named by the inputs: inline (the
;; subject), by canonical, or by reference. A Library (the specification's SQLQuery and SQLView) is
;; a subject this implementation does not run.
(define (subject-view in)
  (define inline (input in "subjectResource"))
  (define canonical (input in "subjectCanonical"))
  (define reference (input in "subjectReference"))
  (define given (length (filter values (list inline canonical reference))))
  (unless (= given 1)
    (operation-error "invalid" "exactly one of subjectResource, subjectCanonical and subjectReference is needed; got ~a" given))
  (define view
    (cond
      [inline inline]
      [canonical (or (stored-view-by-url canonical)
                     (operation-error "not-found" "no ViewDefinition with canonical ~a in the data source" canonical))]
      [else
       (define ref (reference-text reference))
       (define m (regexp-match #px"^(?:.*/)?ViewDefinition/([^/]+)$" ref))
       (or (and m ((data-source-read (current-data-source)) "ViewDefinition" (cadr m)))
           (operation-error "not-found" "cannot resolve subjectReference ~a" ref))]))
  (when (equal? (hash-ref view 'resourceType #f) "Library")
    (operation-error "not-supported" "the subject is a Library: a SQLQuery or SQLView is not run, a ViewDefinition is"))
  view)
;; stored-view-by-url : canonical -> ViewDefinition | #f   the data source's view of that url (and
;; version, when the canonical pins one)
(define (stored-view-by-url canonical)
  (define parts (string-split canonical "|"))
  (findf (lambda (v) (and (equal? (hash-ref v 'url #f) (car parts))
                          (or (null? (cdr parts)) (equal? (hash-ref v 'version #f) (cadr parts)))))
         ((data-source-all (current-data-source)) "ViewDefinition")))
;; reference-text : Reference | string -> string   "Patient/p1"
(define (reference-text r) (if (hash? r) (hash-ref r 'reference "") r))

;; refuse-unheld! : Inputs -> void   the inputs the definition names that are refused, not ignored:
;; `parameters` belong to a SQLQuery or SQLView (the definition: rejected for a ViewDefinition),
;; `source` names data this implementation cannot reach
(define (refuse-unheld! in)
  (when (pair? (hash-ref in "parameters" '()))
    (operation-error "invalid" "`parameters` are a SQLQuery's or SQLView's: a ViewDefinition declares none"))
  (when (pair? (hash-ref in "source" '()))
    (operation-error "not-supported" "`source` is not supported: the data is the data source's, or the `resource` inputs")))

;; view-data : Inputs ViewDefinition -> (listof resource)   the resources the view runs over (FHIR
;; JSON, of its type): the inline `resource` inputs, else the data source's; of the `patient`s and of
;; the `group`s' members when given; changed after `_since` when given
(define (view-data in view)
  (define type (hash-ref view 'resource ""))
  (define inline (append-map bundle-resources (hash-ref in "resource" '())))
  (define base (if (pair? inline) (of-type inline type) ((data-source-all (current-data-source)) type)))
  ;; a patient is looked up in the data source; over inline resources the filter is by reference alone
  (define patients (for/list ([p (in-list (hash-ref in "patient" '()))])
                     (if (pair? inline) (reference-text p) (resolved "patient" "Patient" (reference-text p) inline))))
  (define members (append-map (lambda (g) (group-members (resolved "group" "Group" (reference-text g) inline) inline))
                              (hash-ref in "group" '())))
  (define since (input in "_since"))
  (for/list ([r (in-list base)]
             #:when (or (null? (hash-ref in "patient" '())) (of-any? r patients))
             #:when (or (null? (hash-ref in "group" '())) (of-any? r members))
             #:when (or (not since) (changed-after? r since)))
    r))
;; resolved : input-name type reference inline -> reference   the reference, when it names a
;; resource of the type that is there (among the inline resources, else in the data source); the
;; definition: "An unresolvable patient [group] is rejected"
(define (resolved name type ref inline)
  (unless (stored type ref inline)
    (operation-error "invalid" "the ~a ~a does not resolve: there is no such ~a in the data" name ref type))
  ref)
;; stored : type reference inline -> resource | #f
(define (stored type ref inline)
  (define m (regexp-match (pregexp (string-append "^" type "/([^/]+)$")) ref))
  (and m (or (findf (lambda (r) (and (equal? (hash-ref r 'resourceType #f) type) (equal? (hash-ref r 'id #f) (cadr m)))) inline)
             ((data-source-read (current-data-source)) type (cadr m)))))
;; group-members : reference inline -> (listof reference)   the group's members that are active
(define (group-members ref inline)
  (for*/list ([m (in-list (hash-ref (stored "Group" ref inline) 'member '()))]
              #:unless (eq? (hash-ref m 'inactive #f) #t)
              [e (in-value (hash-ref m 'entity #f))]
              #:when (and (hash? e) (string? (hash-ref e 'reference #f))))
    (hash-ref e 'reference)))
;; of-any? : resource (listof reference) -> boolean   the resource is one of them, or names one as
;; its patient
(define (of-any? r refs)
  (or (and (member (format "~a/~a" (hash-ref r 'resourceType "") (hash-ref r 'id "")) refs) #t)
      (for/or ([ref (in-list (patient-reference-of r))]) (and (member ref refs) #t))))
;; changed-after? : resource instant -> boolean   meta.lastUpdated is after it, as instants (a zone
;; offset is no part of the order); what does not compare as instants is compared as text
(define (changed-after? r since)
  (define updated (hash-ref (hash-ref r 'meta (hasheq)) 'lastUpdated #f))
  (and (string? updated)
       (let ([order (let ([a (parse-fp-datetime updated)] [b (parse-fp-datetime since)]) (and a b (moment-compare a b)))])
         (if (memv order '(-1 0 1)) (= order 1) (string>? updated since)))))

;; view-rows : view [resources] -> (listof row-hash)   resources default to the current data source's
(define (view-rows view [resources #f])
  (define v (typed-view view))
  (define type (hash-ref view 'resource ""))
  (map row->hash
       (eval-view v (filter-map typed-resource
                                (if resources (of-type resources type) ((data-source-all (current-data-source)) type))))))

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
  ;; what the engine refuses of the view itself (a path that is not FHIRPath, unionAll branches of
  ;; different columns) is an invalid view; a view that fails on the data (a column with several
  ;; values and no `collection`) is the operation's error — each an OperationOutcome, not a crash
  (define (engine-message e) (regexp-replace #rx"^eval-view: " (exn-message e) ""))
  (define rows-all
    (with-handlers ([exn:fail:view? (lambda (e) (operation-error "invalid" "not a valid ViewDefinition: ~a" (engine-message e)))]
                    [(lambda (e) (and (exn:fail? e) (not (exn:fail:operation? e))))
                     (lambda (e) (operation-error "processing" "~a" (engine-message e)))])
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
;; header? : Inputs -> boolean   `header`, true unless given false. A false given in a Parameters
;; resource arrives as the parameter itself (fhir/operation's `parameters->inputs` takes a
;; parameter's first true value), so that form is read here.
(define (header? in)
  (match (input in "header" #t)
    [#f #f]
    [(hash-table ('valueBoolean #f) _ ...) #f]
    [_ #t]))

(define $sql-run
  (make-operation
   sql-run-definition #:subject "subjectResource"
   (lambda (in _)
     (refuse-unheld! in)
     (run (subject-view in) in (input in "_format" "ndjson") #:limit (input in "_limit") #:header? (header? in)))))

;; subject-inputs : a `subject` repetition -> Inputs   its parts (name, subjectResource |
;; subjectCanonical | subjectReference); applied as a procedure, a subject may be the view itself, a
;; Reference to one, or a canonical
(define (subject-inputs s)
  (cond [(and (hash? s) (hash-ref s 'part #f)) => (lambda (parts) (parameters->inputs (hasheq 'parameter parts)))]
        [(and (hash? s) (hash-has-key? s 'reference)) (hash "subjectReference" (list s))]
        [(hash? s) (hash "subjectResource" (list s))]
        [else (hash "subjectCanonical" (list s))]))

(define export-counter (box 0))
(define $sql-export
  (make-operation
   sql-export-definition
   (lambda (in _)
     (define fmt (input in "_format" "ndjson"))
     (when (equal? fmt "fhir")
       (operation-error "invalid" "_format=fhir is $sql-run's: an export writes files (csv, ndjson or json)"))
     (refuse-unheld! in)
     (define subjects (map subject-inputs (hash-ref in "subject" '())))
     (for-each refuse-unheld! subjects)
     (define views (map subject-view subjects))
     ;; an output is named by its subject's `name`, else the view's own, else a generated one; the
     ;; definition: names are unique across the job
     (define names (for/list ([s (in-list subjects)] [v (in-list views)] [i (in-naturals 1)])
                     (or (input s "name") (hash-ref v 'name #f) (format "view-~a" i))))
     (cond [(check-duplicates names)
            => (lambda (n) (operation-error "invalid" "two subjects would be the output ~s: give one a `name` of its own" n))])
     (define outputs
       (for/list ([v (in-list views)] [name (in-list names)])
         (hasheq 'name "output"
                 'part (list (hasheq 'name "name" 'valueString name)
                             (hasheq 'name "location" 'valueUri (format "urn:sql-export:~a" name))
                             (hasheq 'name "result" 'resource (run v in fmt #:header? (header? in)))))))
     (set-box! export-counter (add1 (unbox export-counter)))
     (define id (format "export-~a" (unbox export-counter)))
     (define (echoed name key) (let ([v (input in name)]) (if v (list (hasheq 'name name key v)) '())))
     (hasheq 'resourceType "Parameters"
             'parameter (append (list (hasheq 'name "exportId" 'valueString id)
                                      (hasheq 'name "status" 'valueCode "completed"))
                                (echoed "clientTrackingId" 'valueString)
                                (echoed "_format" 'valueCode)
                                outputs)))))

(for-each register-operation! (list $sql-run $sql-export))

(module+ test
  (require rackunit (only-in racket/dict keyword-apply/dict))
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
    (define (parameter m name) (for/first ([p (in-list (hash-ref m 'parameter))] #:when (equal? (hash-ref p 'name) name)) p))
    (define (part p name) (for/first ([x (in-list (hash-ref p 'part))] #:when (equal? (hash-ref x 'name) name)) x))
    (check-equal? (hash-ref (parameter manifest "status") 'valueCode) "completed")
    (check-equal? (hash-ref (parameter manifest "_format") 'valueCode) "csv")       ; echoed, as the definition has it
    (check-equal? (hash-ref (part (parameter manifest "output") "name") 'valueString) "patients")
    (check-equal? (body (hash-ref (part (parameter manifest "output") "result") 'resource)) "id,gender\r\np1,female\r\np2,male\r\n")
    ;; `header` is the export's too (it was $sql-run's alone); a subject's `name` part names its output
    (define named ($sql-export #f (hasheq 'resourceType "Parameters"
                                          'parameter (list (hasheq 'name "subject"
                                                                   'part (list (hasheq 'name "name" 'valueString "people")
                                                                               (hasheq 'name "subjectResource" 'resource view)))
                                                           (hasheq 'name "_format" 'valueCode "csv")
                                                           (hasheq 'name "header" 'valueBoolean #f)))))
    (check-equal? (hash-ref (part (parameter named "output") "name") 'valueString) "people")
    (check-equal? (body (hash-ref (part (parameter named "output") "result") 'resource)) "p1,female\r\np2,male\r\n")
    ;; `header: false` in a Parameters resource (a POST's body) is false for $sql-run too
    (check-equal? (body ($sql-run view (hasheq 'resourceType "Parameters"
                                               'parameter (list (hasheq 'name "_format" 'valueCode "csv") (hasheq 'name "header" 'valueBoolean #f)))))
                  "p1,female\r\np2,male\r\n")
    ;; the definition: output names are unique across the job; `_format=fhir` is rejected (it became
    ;; NDJSON without a word); an export needs a subject
    (check-exn #rx"two subjects would be the output \"patients\"" (lambda () ($sql-export #:subject (list view view))))
    (check-exn (lambda (e) (and (exn:fail:operation? e) (regexp-match? #rx"_format=fhir is [$]sql-run's" (exn-message e))))
               (lambda () ($sql-export #:subject (list view) #:_format "fhir")))
    (check-exn #rx"needs input 'subject'" (lambda () ($sql-export)))
    (check-equal? (length (filter (lambda (p) (equal? (hash-ref p 'name) "output"))
                                  (hash-ref ($sql-export #:subject (list view (hash-set view 'name "again"))) 'parameter)))
                  2))
  ;; ---- what the definitions of the operations say, held -------------------------------------------
  (define (code-of thunk) (with-handlers ([exn:fail:operation? (lambda (e) (hash-ref (car (hash-ref (exn:fail:operation-outcome e) 'issue)) 'code))]) (thunk) 'ran))
  (define obs (for/list ([id (in-list '("o1" "o2" "o3"))] [patient (in-list '("p1" "p2" "p3"))])
                (hasheq 'resourceType "Observation" 'id id 'status "final" 'subject (hasheq 'reference (string-append "Patient/" patient)))))
  (define obs-view (hasheq 'resourceType "ViewDefinition" 'status "active" 'resource "Observation"
                           'select (list (hasheq 'column (list (hasheq 'name "id" 'path "id"))))))
  (define group (hasheq 'resourceType "Group" 'id "g" 'member (list (hasheq 'entity (hasheq 'reference "Patient/p1"))
                                                                    (hasheq 'entity (hasheq 'reference "Patient/p2") 'inactive #t)
                                                                    (hasheq 'entity (hasheq 'reference "Patient/p3")))))
  (parameterize ([current-data-source (resources->data-source (append pts obs (list group)))])
    (define (ids . inputs) (map (lambda (r) (hash-ref r 'id)) (string->jsexpr (body (keyword-apply/dict $sql-run (apply hasheq inputs) (list obs-view))))))
    ;; `group`: the resources of the group's active members (it was ignored: every patient's came back)
    (check-equal? (ids '#:_format "json" '#:group "Group/g") '("o1" "o3"))
    (check-equal? (ids '#:_format "json" '#:group "Group/g" '#:patient "Patient/p1") '("o1"))
    ;; a patient or a group that does not resolve is rejected (an unknown patient filtered to nothing)
    (check-exn #rx"the patient Patient/nobody does not resolve" (lambda () ($sql-run obs-view #:patient "Patient/nobody")))
    (check-exn #rx"the group Group/none does not resolve" (lambda () ($sql-run obs-view #:group "Group/none")))
    (check-equal? (code-of (lambda () ($sql-run obs-view #:patient "Patient/nobody"))) "invalid")
    ;; over inline resources a patient filters by reference: the Patient need not be among them
    (check-equal? (length (hash-ref ($sql-run obs-view #:resource (list (car obs) (cadr obs)) #:patient "Patient/p2" #:_format "fhir") 'parameter)) 1)
    ;; `parameters` are a Library's, rejected for a ViewDefinition; `source` and a Library subject
    ;; are said to be unsupported (they were ignored, and a Library read as a broken view)
    (check-equal? (code-of (lambda () ($sql-run obs-view #:parameters (hasheq 'resourceType "Parameters")))) "invalid")
    (check-equal? (code-of (lambda () ($sql-run obs-view #:source "s3://bucket"))) "not-supported")
    (check-equal? (code-of (lambda () ($sql-run (hasheq 'resourceType "Library" 'status "active")))) "not-supported")
    (check-equal? (code-of (lambda () ($sql-export #:subject (list obs-view) #:source "s3://bucket"))) "not-supported")
    ;; `_since` orders instants, whatever their zone offsets: 23:30 at -05:00 is after midnight UTC
    ;; of the next day (as text it sorted before it)
    (define (updated id at) (hasheq 'resourceType "Observation" 'id id 'status "final" 'meta (hasheq 'lastUpdated at)))
    (define (since at . rs) (map (lambda (r) (hash-ref r 'id)) (view-data (hash "resource" rs "_since" (list at)) obs-view)))
    (check-equal? (since "2026-01-02T00:00:00Z" (updated "late" "2026-01-01T23:30:00-05:00") (updated "early" "2026-01-02T05:00:00+10:00")
                         (updated "same" "2026-01-02T00:00:00Z") (hasheq 'resourceType "Observation" 'id "undated"))
                  '("late"))
    ;; a view the engine refuses is an invalid view whatever the data: a path that is not FHIRPath
    ;; (over no data it printed an empty table), unionAll branches that differ, a column name twice
    (define (columns . cs) (hash-set obs-view 'select (list (hasheq 'column cs))))
    (define (refusal v) (with-handlers ([exn:fail:operation? exn-message]) ($sql-run v #:resource (list (hasheq 'resourceType "Patient" 'id "x")))))
    (check-equal? (refusal (columns (hasheq 'name "id" 'path "id.")))
                  "not a valid ViewDefinition: the path \"id.\" is not FHIRPath: the expression ends after `.`")
    (check-equal? (code-of (lambda () ($sql-run (columns (hasheq 'name "id" 'path "id."))))) "invalid")
    (check-equal? (refusal (columns (hasheq 'name "id" 'path "id") (hasheq 'name "id" 'path "status")))
                  "not a valid ViewDefinition: the column name `id` is used twice: the columns of a table are named apart")
    (check-equal? (refusal (hash-set obs-view 'select (list (hasheq 'unionAll (list (hasheq 'column (list (hasheq 'name "a" 'path "id")))
                                                                                    (hasheq 'column (list (hasheq 'name "b" 'path "id"))))))))
                  "not a valid ViewDefinition: unionAll branches disagree on columns: ((a) (b))")
    ;; the definition's own constraints are held (definition.rkt)
    (check-regexp-match #rx"select\\[0\\].column\\[0\\].name \"first-name\" is not a name a database takes"
                        (refusal (columns (hasheq 'name "first-name" 'path "id"))))
    ;; a view reads the resources of its type: the others are not read at all, nor counted
    (let ([log (make-read-log)])
      (check-equal? (length (parameterize ([current-read-log log]) (view-rows obs-view (append pts obs)))) 3)
      (check-equal? (read-log-count log) 3))))

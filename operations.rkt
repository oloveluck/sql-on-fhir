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

(require racket/list racket/string racket/match json net/base64
         fhir/operation fhir/data-source
         (only-in sql-on-fhir/model/types)                  ; registers ViewDefinition over the R6 tower
         (only-in sql-on-fhir/model/operations sql-run-definition sql-export-definition)
         (only-in "view.rkt" eval-view view-columns)
         (only-in fhir/serialize/from-json from-json)
         (only-in fhir/result/result ok? ok-value err-error)
         (only-in fhir/result/result validation-error-message))

(provide $sql-run $sql-export view-rows
         rows->csv rows->ndjson rows->json)

;; ---- the view and its data ----------------------------------------------------------------------
;; typed-view : ViewDefinition jsexpr -> typed node   strict: the generated schema validates it
(define (typed-view js)
  (define r (from-json (hash-set js 'resourceType "ViewDefinition")))
  (if (ok? r) (ok-value r)
      (operation-error "invalid" "not a valid ViewDefinition: ~a" (validation-error-message (err-error r)))))
(define (typed-resource js)
  (define r (from-json js #:lenient? #t))
  (and (ok? r) (ok-value r)))

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
  (define rows-all (eval-view v (filter-map typed-resource (view-data in view))))
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

#lang racket/base

;;; workspace.rkt — what SQL on FHIR offers a workspace (fhir/lang/workspace): a ViewDefinition written
;;; as JSON (`*.view.json`, the form the specification and its test suite use) is an artifact
;;; (canonical `<workspace canonical>/ViewDefinition/<file stem>` unless it names one), checked
;;; against the model generated from the IG; a run is its rows over the data source; an explanation,
;;; what one resource contributes: the rows it alone produces, and whether each `where` holds for it.
;;; A Row is {column: value …} in the view's column order.

(require racket/contract racket/list racket/string racket/match racket/runtime-path racket/file json
         fhir/lang/workspace
         (only-in fhir/diagnostic diagnostic loc exn:fail:diagnostic exn:fail:diagnostic? exn:fail:diagnostic-diagnostic)
         (only-in fhir/operation exn:fail:operation? exn:fail:operation-outcome)
         (only-in fhir/data-source current-data-source data-source-all data-source-read)
         (only-in fhir/result/result ok? ok-value)
         (only-in fhir/serialize/from-json from-json)
         (only-in "view.rkt" view-columns)
         (only-in "operations.rkt" view-rows))

(provide (contract-out [workspace-support ws-support?]
                       ;; guide : the language guide (guide.md) a hub serves to agents (learn://sql-on-fhir)
                       [guide string?]))

(define-runtime-path guide-file "guide.md")
(define guide (file->string guide-file))

(define (path-string p) (if (path? p) (path->string p) p))
(define (fail path msg) (raise (exn:fail:diagnostic msg (current-continuation-marks)
                                                     (diagnostic 'sql-on-fhir 'compile 'error msg (loc (and path (path-string path)) #f #f #f #f)))))

;; view : workspace path|#f text -> ViewDefinition jsexpr   raises a diagnostic when it is not one
(define (view ws path text)
  (define js (with-handlers ([exn:fail? (lambda (e) (fail path (format "not JSON: ~a" (exn-message e))))]) (string->jsexpr text)))
  (unless (and (hash? js) (member (hash-ref js 'resourceType "ViewDefinition") '("ViewDefinition")))
    (fail path "a ViewDefinition is a JSON object with \"resourceType\": \"ViewDefinition\""))
  (define v (let ([v (hash-set js 'resourceType "ViewDefinition")])
              (if (and path (not (hash-has-key? v 'url))) (hash-set v 'url (file-canonical ws "ViewDefinition" path)) v)))
  (with-handlers ([exn:fail:operation? (lambda (e) (fail path (outcome-text (exn:fail:operation-outcome e))))])
    (view-rows v '()))                                   ; the strict parse: the generated model is the validator
  v)
(define (outcome-text oo)
  (string-join (for/list ([i (in-list (hash-ref oo 'issue '()))]) (or (hash-ref i 'diagnostics #f) (hash-ref i 'code ""))) "; "))

(define (artifacts ws files)
  (for/fold ([rs '()] [ds '()] #:result (values (reverse rs) ds)) ([f (in-list files)])
    (with-handlers ([exn:fail:diagnostic? (lambda (e) (values rs (append ds (list (exn:fail:diagnostic-diagnostic e)))))])
      (define v (view ws (car f) (cdr f)))
      (values (cons (if (hash-has-key? v 'id) v (hash-set v 'id (regexp-replace* #rx"[^A-Za-z0-9.-]" (file-stem (car f)) "-"))) rs) ds))))

(define (columns v)
  (map symbol->string (view-columns (ok-value (from-json v)))))
(define (ordered row cols) (for/hasheq ([c (in-list cols)]) (values (string->symbol c) (hash-ref row (string->symbol c) 'null))))

(define (run ws path text opts)
  (define v (view ws path text))
  (define cols (columns v))
  (define rows (map (lambda (r) (ordered r cols)) (view-rows v)))
  (run-result "rows" cols rows
              (hasheq 'rows (length rows) 'resource (hash-ref v 'resource "")
                      'scanned (length ((data-source-all (current-data-source)) (hash-ref v 'resource ""))))))

(define (explain ws path text subject opts)
  (define v (view ws path text))
  (define type (hash-ref v 'resource ""))
  (define id (regexp-replace (pregexp (string-append "^" (regexp-quote type) "/")) subject ""))
  (define r (or ((data-source-read (current-data-source)) type id)
                (error 'sql-on-fhir (format "no ~a/~a in the data source" type id))))
  (define cols (columns v))
  (define wheres (hash-ref v 'where '()))
  (define bare (hash-remove v 'where))
  (hasheq 'resource (format "~a/~a" type id)
          'rows (map (lambda (x) (ordered x cols)) (view-rows v (list r)))
          'rowsWithoutWhere (length (view-rows bare (list r)))
          'where (for/list ([w (in-list wheres)])
                   (hasheq 'path (hash-ref w 'path "")
                           'holds (pair? (view-rows (hash-set bare 'where (list w)) (list r)))))))

(define workspace-support (ws-support "sql-on-fhir" artifacts run explain))

(module+ test
  (require rackunit (only-in fhir/data-source resources->data-source))
  (define-values (ws _) (open-workspace (find-system-path 'temp-dir)))
  (define text (jsexpr->string
                (hasheq 'resourceType "ViewDefinition" 'name "active_patients" 'status "active" 'resource "Patient"
                        'where (list (hasheq 'path "active = true"))
                        'select (list (hasheq 'column (list (hasheq 'name "id" 'path "getResourceKey()")
                                                            (hasheq 'name "family" 'path "name.family.first()")))))))
  (define-values (rs ds) (artifacts ws (list (cons "/tmp/active.view.json" text) (cons "/tmp/bad.view.json" "{\"resource\": 3}"))))
  (check-equal? (hash-ref (car rs) 'url) "http://example.org/workspace/ViewDefinition/active")
  (check-equal? (length ds) 1)
  (define data (list (hasheq 'resourceType "Patient" 'id "a" 'active #t 'name (list (hasheq 'family "Ng")))
                     (hasheq 'resourceType "Patient" 'id "b" 'active #f)))
  (parameterize ([current-data-source (resources->data-source data)])
    (define r (run ws #f text (hasheq)))
    (check-equal? (run-result-columns r) '("id" "family"))
    (check-equal? (run-result-rows r) (list (hasheq 'id "a" 'family "Ng")))
    (check-equal? (hash-ref (run-result-summary r) 'scanned) 2)
    (define e (explain ws #f text "Patient/b" (hasheq)))
    (check-equal? (hash-ref e 'rows) '())
    (check-equal? (hash-ref e 'rowsWithoutWhere) 1)
    (check-equal? (hash-ref (car (hash-ref e 'where)) 'holds) #f)))

#lang racket/base

;;; tck-test.rkt — `raco test` runs the shared suite (every file, floor 144/144) and checks that the
;;; committed model is exactly what the vendored IG package generates, that what `$sql-run`
;;; refuses before it evaluates (operations.rkt's `typed-view`) refuses no view the suite runs, and
;;; that the views the IG itself publishes as examples are views here.

(require rackunit json
         (only-in "harness.rkt" run-suite suite-files)
         (only-in sql-on-fhir/operations view-rows)
         (only-in fhir/codegen/check check-tower)
         (only-in fhir/package read-package)
         (only-in sql-on-fhir/target target-sql-on-fhir ig-package))

(define-values (passed total)
  (for/fold ([p 0] [t 0]) ([f (in-list (suite-files))])
    (define-values (sp st fails) (run-suite f))
    (for ([x (in-list fails)]) (printf "  FAIL ~a: ~a\n" (car x) (cadr x)))
    (values (+ p sp) (+ t st))))
(printf "  SQL on FHIR shared suite: ~a/~a\n" passed total)
(check-true (>= passed 144) "the shared suite regressed")
(check-equal? (check-tower target-sql-on-fhir) '() "the model differs from what spec/ generates: raco sql-on-fhir regen")

;; The suite's views that are expected to run. `$sql-run` checks more than the harness's strict parse
;; (required elements, required bindings): none of it may refuse one of these.
(define runnable-views
  (for*/list ([f (in-list (suite-files))]
              [t (in-list (hash-ref (call-with-input-file f read-json) 'tests '()))]
              #:unless (hash-ref t 'expectError #f))
    (cons (hash-ref t 'title "?") (hash-ref t 'view))))
(for ([v (in-list runnable-views)])
  (check-not-exn (lambda () (view-rows (cdr v) '())) (format "$sql-run refuses a view the suite runs: ~a" (car v))))
;; Why `status` (1..1 in the definition) is not among the required elements held: the suite's own
;; views leave it out. Should this count reach 0, operations.rkt's `unheld-required` can go.
(define without-status (filter (lambda (v) (not (hash-has-key? (cdr v) 'status))) runnable-views))
(printf "  suite views expected to run: ~a, without `status`: ~a\n" (length runnable-views) (length without-status))
(check-true (pair? without-status) "every suite view now carries `status`: it can be required (operations.rkt, unheld-required)")

;; The ViewDefinitions the IG publishes as its examples (the package's example/ folder), as published:
;; each is a view here, and runs. They carry R6's `resourceDefinition` beside `resourceType` (the
;; canonical of the definition of a resource that is not in the core specification), which the
;; strict parse took for an unknown element: all ten were refused.
(define-values (_manifest _resources examples) (read-package ig-package))
(define example-views
  (for/list ([e (in-list examples)] #:when (equal? (hash-ref (cdr e) 'resourceType #f) "ViewDefinition")) e))
(printf "  the IG's example ViewDefinitions: ~a\n" (length example-views))
(check-equal? (length example-views) 10)
(for ([e (in-list example-views)])
  (check-true (hash-has-key? (cdr e) 'resourceDefinition) (format "~a" (car e)))
  (check-equal? (view-rows (cdr e) '()) '() (format "the IG's example ~a is refused" (car e))))

#lang racket/base

;;; tck-test.rkt — `raco test` runs the shared suite (every file, floor 144/144) and checks that the
;;; committed model is exactly what the vendored IG package generates.

(require rackunit racket/runtime-path
         (only-in "harness.rkt" run-suite)
         (only-in fhir/codegen/check check-tower)
         (only-in sql-on-fhir/target target-sql-on-fhir))

(define-runtime-path suite-dir "vendor/sql-on-fhir-tests")

(define-values (passed total)
  (for/fold ([p 0] [t 0]) ([f (in-list (directory-list suite-dir #:build? #t))]
                           #:when (regexp-match? #px"[.]json$" (path->string f))
                           #:unless (regexp-match? #rx"schema" (path->string f)))
    (define-values (sp st fails) (run-suite f))
    (for ([x (in-list fails)]) (printf "  FAIL ~a: ~a\n" (car x) (cadr x)))
    (values (+ p sp) (+ t st))))
(printf "  SQL on FHIR shared suite: ~a/~a\n" passed total)
(check-true (>= passed 144) "the shared suite regressed")
(check-equal? (check-tower target-sql-on-fhir) '() "the model differs from what spec/ generates: raco sql-on-fhir regen")

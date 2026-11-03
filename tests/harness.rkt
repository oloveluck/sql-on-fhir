#lang racket/base

;;; harness.rkt — the shared SQL on FHIR test suite runner (FHIR/sql-on-fhir.js tests/, vendored).
;;;
;;; Each vendored suite file carries { resources, tests: [{ view, expect | expectError |
;;; expectColumns }] }. For every test: parse the view STRICTLY through the model generated from
;;; the IG package (a strict parse failure satisfies expectError — the schema is the
;;; validator), evaluate it over the file's resources with view.rkt, and compare rows
;;; (order-insensitive multiset equality; expectColumns checks declaration order).

(require racket/contract racket/list json
         (only-in sql-on-fhir/model/types)               ; register ViewDefinition + the R6 base
         (only-in sql-on-fhir/view eval-view view-columns)
         (only-in fhir/serialize/from-json from-json)
         (only-in fhir/result/result ok? ok-value))

(provide (contract-out
          ;; run-suite : suite.json path -> (values passed total failures)
          [run-suite (-> path-string? (values exact-nonnegative-integer?
                                              exact-nonnegative-integer?
                                              list?))]))

(define (run-suite path)
  (define suite (call-with-input-file path read-json))
  (define resources (filter-map typed (hash-ref suite 'resources '())))
  (define tests (hash-ref suite 'tests '()))
  (define failures '())
  (define passed 0)
  (for ([t (in-list tests)])
    (define title (hash-ref t 'title "?"))
    (define outcome (run-test t resources))
    (match-outcome outcome
                   (lambda () (set! passed (add1 passed)))
                   (lambda (msg) (set! failures (cons (list title msg) failures)))))
  (values passed (length tests) (reverse failures)))

(define (match-outcome o on-pass on-fail) (if (eq? o 'pass) (on-pass) (on-fail o)))

;; typed : resource jsexpr -> fhir node | #f  (lenient — suite resources may use any profile)
(define (typed js)
  (define r (from-json js #:lenient? #t))
  (and (ok? r) (ok-value r)))

;; run-test : test resources -> 'pass | failure-message
(define (run-test t resources)
  (define view-js (hash-set (hash-ref t 'view) 'resourceType "ViewDefinition"))
  (define expect-error? (hash-ref t 'expectError #f))
  (define vr (from-json view-js))                       ; STRICT: the generated schema validates
  (cond
    [(not (ok? vr)) (if expect-error? 'pass "view rejected by schema but no expectError")]
    [else
     (define view (ok-value vr))
     (define rows-or-exn
       (with-handlers ([exn:fail? (lambda (e) e)])
         (map row->hash (eval-view view resources))))
    (cond
      [(exn? rows-or-exn) (if expect-error? 'pass (format "error: ~a" (exn-message rows-or-exn)))]
      [expect-error? (format "expected an error but evaluated to ~a rows" (length rows-or-exn))]
      [(hash-ref t 'expectColumns #f)
       => (lambda (cols)
            (if (equal? (map string->symbol cols) (view-columns view)) 'pass
                (format "columns ~a != expected ~a" (view-columns view) cols)))]
      [else
       (define expected (map normalize-row (hash-ref t 'expect '())))
       (define actual (map normalize-row rows-or-exn))
       (if (multiset=? actual expected) 'pass
           (format "rows mismatch\n    expected ~v\n    actual   ~v" expected actual))])]))

(define (row->hash row) (for/hasheq ([kv (in-list row)]) (values (car kv) (cdr kv))))

;; normalize-row : row hash -> canonical hash (JSON numbers unified; missing == null per spec)
(define (normalize-row h)
  (for/hasheq ([(k v) (in-hash h)] #:unless (eq? v 'null)) (values k (norm v))))
(define (norm v)
  (cond [(and (number? v) (exact? v) (integer? v)) v]
        [(number? v) (exact->inexact v)]
        [(list? v) (map norm v)]
        [else v]))

;; order-insensitive multiset comparison of row hashes
(define (multiset=? a b)
  (and (= (length a) (length b))
       (let loop ([xs a] [pool b])
         (cond [(null? xs) #t]
               [(member (car xs) pool) => (lambda (m) (loop (cdr xs) (remove (car xs) pool)))]
               [else #f]))))

(module+ test
  (require rackunit racket/runtime-path)
  (define-runtime-path vendor "vendor/sql-on-fhir-tests")
  (define-values (p a fails) (run-suite (build-path vendor "basic.json")))
  (printf "sof basic: ~a/~a\n" p a)
  (for ([f (in-list fails)]) (printf "  FAIL ~a: ~a\n" (car f) (cadr f)))
  (check-true (>= p 8) "most basic tests pass"))

#lang racket/base
;;; `#lang sql-on-fhir` — author ViewDefinitions, checked at compile time against the model generated
;;; from the IG package: the generated `#lang sql-on-fhir/model`, under the package's own name.
;;; One thing is added to it: every path a view writes — a column's or a where's `path`, a
;;; `forEach`, `forEachOrNull` or `repeat` — is read as FHIRPath when the file is, so a path that is
;;; not FHIRPath is a compile error at its string (the model knows a path as a string only).
(require (prefix-in model: sql-on-fhir/model/lang/reader)
         (only-in sql-on-fhir/view path-syntax-problem))
(provide (rename-out [model:read read] [read-checked read-syntax] [model:get-info get-info]))

;; the forms whose strings are paths
(define path-forms '(path forEach forEachOrNull repeat))

;; read-checked : the generated reader's read-syntax, its module's paths held to FHIRPath's syntax
(define (read-checked . args)
  (define module (apply model:read-syntax args))
  (check-paths! module)
  module)

;; check-paths! : syntax -> void   raises a syntax error at the first string of a path form that is
;; not FHIRPath. Structural recursion over the forms as read.
(define (check-paths! stx)
  (define parts (syntax->list stx))
  (when parts
    (when (and (pair? parts) (identifier? (car parts)) (memq (syntax-e (car parts)) path-forms))
      (for ([s (in-list (cdr parts))] #:when (string? (syntax-e s)))
        (define problem (path-syntax-problem (syntax-e s)))
        (when problem (raise-syntax-error 'ViewDefinition problem stx s))))
    (for-each check-paths! parts)))

#lang racket/base
;;; `#lang sql-on-fhir` — a file of views. What follows the `#lang` line is one of two things,
;;; told apart by how it begins:
;;;
;;;   SOURCE TEXT (LANGUAGE.md): `CREATE VIEW … AS SELECT … FROM Patient WHERE …`, the SQL dialect
;;;     with FHIRPath that compiles to ViewDefinitions. It is compiled when the file is read, and
;;;     each view held to what a ViewDefinition is (sof.rkt): a mistake is a compile error at its
;;;     line and column.
;;;   FORMS, beginning with `(`: `(ViewDefinition (name "…") …)`, the forms generated from the IG
;;;     package (`#lang sql-on-fhir/model`), checked against the model when the file is compiled;
;;;     one thing is added to them here: every string of a `path`, `forEach`, `forEachOrNull` or
;;;     `repeat` form is read as FHIRPath, so a path that is not is a compile error at its string.
;;;
;;; Either way the module provides `resources` (the typed views), `(->nodes)` and `(->json)`, and
;;; run as a program prints its views as JSON.
(require (prefix-in model: sql-on-fhir/model/lang/reader)
         racket/port json
         (only-in sql-on-fhir/view path-syntax-problem)
         (only-in sql-on-fhir/sof read-sof source-text?)
         (only-in sql-on-fhir/compile compiled-view)
         (only-in fhir/diagnostic raise-diagnostic exn:fail:diagnostic? exn:fail:diagnostic-diagnostic))
(provide (rename-out [read-either read] [read-syntax-either read-syntax] [model:get-info get-info]))

;; the forms whose strings are paths
(define path-forms '(path forEach forEachOrNull repeat))

;; text-ahead : port -> string   what is left to read, without reading it
(define (text-ahead in) (port->string (peeking-input-port in)))

(define (read-syntax-either src in . more)
  (if (source-text? (text-ahead in))
      (text-module src in)
      (let ([module (apply model:read-syntax src in more)])
        (check-paths! module)
        module)))
(define (read-either in . more)
  (if (source-text? (text-ahead in))
      (syntax->datum (text-module #f in))
      (apply model:read in more)))

;; text-module : source port -> syntax   the module a file of source text is: its views compiled
;; now (a problem is raised at its place in the file), their JSON in the module
(define (text-module src in)
  ;; the text keeps its place in the file: what stood before it becomes blank lines and columns
  (define-values (line column _position) (port-next-location in))
  (define text (string-append (make-string (max 0 (sub1 (or line 1))) #\newline)
                              (make-string (or column 0) #\space)
                              (port->string in)))
  (define views
    (with-handlers ([exn:fail:diagnostic? (lambda (e) (raise-diagnostic (exn:fail:diagnostic-diagnostic e)))])
      (map compiled-view (read-sof text src))))
  (datum->syntax
   #f
   `(module sql-on-fhir-views racket/base
      (require sql-on-fhir/lang/text-module)
      (provide resources ->nodes ->json)
      (define-values (resources ->nodes ->json) (text-module-values ',(map jsexpr->string views)))
      (module+ main (print-views (->json))))))

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

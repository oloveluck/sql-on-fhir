#lang racket/base

;;; sof.rkt — source text as views that ARE views.
;;;
;;; compile.rkt translates the text; this module also holds each result to what a ViewDefinition
;;; is: the IG's definition of one (definition.rkt's `read-view`: the strict parse, required
;;; elements, required codes, the definition's rules) and what the engine refuses before it reads
;;; any data (view.rkt: unionAll branches of different columns, a column name used twice). Every
;;; problem is a diagnostic at the statement it is about, so a `.sof` file is checked as it is read:
;;; by `raco sql-on-fhir run|compile`, and by `#lang sql-on-fhir` when the module is compiled.

(require racket/contract racket/string
         (only-in "compile.rkt" compile-sof compiled compiled? compiled-view compiled-loc)
         (only-in "definition.rkt" read-view)
         (only-in "view.rkt" view-columns exn:fail:view?)
         (only-in fhir/diagnostic diagnostic exn:fail:diagnostic))

(provide
 (contract-out
  ;; read-sof : text [source] -> (Listof Compiled)   each statement's ViewDefinition (JSON) with where
  ;; it begins; raises an exn:fail:diagnostic at the first problem of the text or of a view
  [read-sof (->* (string?) (any/c) (listof compiled?))]
  ;; source-text? : a file's text -> is it the source language (not JSON, not a module of forms)?
  [source-text? (-> string? boolean?)]))

(define (read-sof text [source #f])
  (define all (compile-sof text source))
  (for ([c (in-list all)])
    (define (refuse fmt . args)
      (define msg (apply format fmt args))
      (raise (exn:fail:diagnostic msg (current-continuation-marks) (diagnostic 'sql-on-fhir 'compile 'error msg (compiled-loc c)))))
    (define node (read-view (compiled-view c)))
    (when (list? node) (refuse "not a valid ViewDefinition: ~a" (string-join node "; ")))
    (with-handlers ([exn:fail:view? (lambda (e) (refuse "~a" (regexp-replace #rx"^eval-view: " (exn-message e) "")))])
      (view-columns node)))
  all)

;; source-text? : text -> boolean   what a file holds is told by how it begins: `{` is JSON, `(` a
;; module's forms; anything else (a keyword, a comment) is the source language
(define (source-text? text)
  (define m (regexp-match #px"^(?:\\s+|#lang[^\n]*|--[^\n]*|//[^\n]*|;[^\n]*|/\\*.*?\\*/)*(.)" text))
  (not (and m (member (cadr m) '("{" "(" "[")))))

(module+ test
  (require rackunit (only-in fhir/diagnostic exn:fail:diagnostic? exn:fail:diagnostic-diagnostic diagnostic-message diagnostic-loc loc-line loc-column loc-source))
  (check-equal? (hash-ref (compiled-view (car (read-sof "CREATE VIEW p WITH (status = 'active') AS SELECT id FROM Patient"))) 'name) "p")
  (define (refusal text)
    (with-handlers ([exn:fail:diagnostic? (lambda (e) (define d (exn:fail:diagnostic-diagnostic e))
                                            (format "~a:~a:~a: ~a" (loc-source (diagnostic-loc d)) (loc-line (diagnostic-loc d)) (loc-column (diagnostic-loc d)) (diagnostic-message d)))])
      (read-sof text "v.sof") #f))
  ;; what the definition refuses, at the statement
  (check-equal? (refusal "SELECT id FROM Patient;\n\nSELECT id FROM Patiant")
                "v.sof:3:1: not a valid ViewDefinition: \"Patiant\" is not in the required value set for ViewDefinition.resource (http://hl7.org/fhir/ValueSet/resource-types)")
  (check-regexp-match #rx"^v.sof:1:1: not a valid ViewDefinition: ViewDefinition: unknown field titel"
                      (refusal "CREATE VIEW p WITH (titel = 'x') AS SELECT id FROM Patient"))
  (check-equal? (refusal "CREATE VIEW p AS SELECT id AS `first-name` FROM Patient")
                "v.sof:1:1: not a valid ViewDefinition: select[0].column[0].name \"first-name\" is not a name a database takes: letters, digits and _ only, starting with a letter")
  ;; what the engine refuses before it reads data
  (check-equal? (refusal "SELECT id, gender AS id FROM Patient")
                "v.sof:1:1: the column name `id` is used twice: the columns of a table are named apart")
  (check-equal? (refusal "SELECT (SELECT a UNION ALL SELECT b) FROM Patient")
                "v.sof:1:1: unionAll branches disagree on columns: ((a) (b))")
  (check-equal? (refusal "SELECT FROM Patient") "v.sof:1:1: not a valid ViewDefinition: the view has no `select` (the columns of the table)")
  ;; how a file begins says what it is
  (check-true (source-text? "-- patients\nSELECT id FROM Patient"))
  (check-true (source-text? "#lang sql-on-fhir\n\nCREATE VIEW p AS SELECT id FROM Patient"))
  (check-true (source-text? ""))
  (check-false (source-text? "  {\"resourceType\": \"ViewDefinition\"}"))
  (check-false (source-text? "#lang sql-on-fhir\n;; forms\n(ViewDefinition (status \"active\"))")))

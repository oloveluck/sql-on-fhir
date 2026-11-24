#lang racket/base

;;; text-module.rkt — what a `#lang sql-on-fhir` file of SOURCE TEXT is at run time: the same three
;;; names a file of forms provides (`resources`, `->nodes`, `->json`), over the views its text
;;; compiled to when the file was read (lang/reader.rkt), and their JSON when the file is run.

(require json
         (only-in "../definition.rkt" read-view)
         (only-in fhir/serialize/fhir-json fhir-json->string))

(provide text-module-values print-views)

;; text-module-values : (Listof JSON-text) -> (values nodes ->nodes ->json)
;; the views as typed ViewDefinitions (what `raco sql-on-fhir run` and `eval-view` take), and as JSON
(define (text-module-values json-texts)
  (define views (map string->jsexpr json-texts))
  (define nodes
    (for/list ([v (in-list views)])
      (define node (read-view v))
      (when (list? node) (error 'sql-on-fhir "not a valid ViewDefinition: ~a" (car node)))
      node))
  (values nodes (lambda () nodes) (lambda () views)))

;; print-views : (Listof ViewDefinition-JSON) -> void   each as FHIR writes it, one to a line
(define (print-views views)
  (for ([v (in-list views)]) (displayln (fhir-json->string v))))

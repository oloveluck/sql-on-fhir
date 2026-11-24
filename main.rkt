#lang racket/base

;;; main.rkt — `(require sql-on-fhir)`: the package from a Racket program, in one require.
;;;
;;; Where things are (features.rkt lists all of it, row by row, with the definition to read):
;;;
;;;   features.rkt     what the package does, as one table       raco sql-on-fhir features
;;;   view.rkt         the engine: a view over resources -> rows
;;;   definition.rkt   a view held to the IG's definition of one
;;;   operations.rkt   $sql-run and $sql-export; the output formats; `view-rows`
;;;   unread.rkt       what a view read that the data's read left out
;;;   workspace.rkt    what an agent's workspace gets (artifacts, run, explain, the guide)
;;;   cli.rkt          raco sql-on-fhir
;;;   lang/reader.rkt  #lang sql-on-fhir
;;;   target.rkt       the IG package (spec/) as the source model/ is GENERATED from
;;;
;;; This module loads the view model, which is built over FHIR R6. To read data as R4 or R5, load
;;; that version's types first and keep them, and only then load this module — what cli.rkt's
;;; `load-tower!` does:
;;;   (require fhir/r4/schemas (only-in fhir/model/registry pin-registered-types!))
;;;   (pin-registered-types!)
;;;   (define view-rows (dynamic-require 'sql-on-fhir 'view-rows))

(require "features.rkt" "view.rkt" "definition.rkt" "operations.rkt" "unread.rkt")

(provide
 ;; the IG's operations, and a view's rows
 $sql-run $sql-export view-rows
 ;; the output formats
 rows->csv rows->ndjson rows->json
 ;; what the lenient read of the data left out of what a view read
 current-read-log make-read-log read-log? read-log-count read-log-reads
 view-chains unread-notes
 ;; a view held to its definition
 read-view definition-url
 ;; the engine
 eval-view view-columns (struct-out exn:fail:view) path-syntax-problem rewrite-sof
 ;; what the package does, as data
 features features-of tables states command-usages features->text features->jsexpr
 (struct-out feature) (struct-out table))

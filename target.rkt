#lang racket/base

;;; target.rkt — the IG package as a codegen target (fhir/codegen): the SQL on FHIR IG's ViewDefinition
;;; becomes a generated tower in this package's own collection, `sql-on-fhir/model` — schema, authoring
;;; form, `#lang sql-on-fhir/model`, required-binding terminology, and the package's
;;; OperationDefinitions as data (`model/operations.rkt`). It delegates every core type to the R6
;;; tower (the IG is FHIR 6). `raco sql-on-fhir regen` writes it, `raco sql-on-fhir check` verifies
;;; the committed files match a fresh generation.

(require racket/runtime-path
         (only-in fhir/codegen/target gen-target target-r6))

(provide target-sql-on-fhir ig-package)

(define-runtime-path ig-package "spec/hl7.fhir.uv.sql-on-fhir.tgz")   ; version: spec/SOURCE.txt

(define target-sql-on-fhir
  (gen-target 'sql-on-fhir ig-package "hl7.fhir.uv.sql-on-fhir" "model"
              "https://build.fhir.org/ig/FHIR/sql-on-fhir-v2/"
              '(ViewDefinition) target-r6 '() #t #f "sql-on-fhir"))

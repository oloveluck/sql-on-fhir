#lang racket/base
;;; `#lang sql-on-fhir` — author ViewDefinitions, checked at compile time against the model generated
;;; from the IG package: the generated `#lang sql-on-fhir/model`, under the package's own name.
(require sql-on-fhir/model/lang/reader)
(provide (all-from-out sql-on-fhir/model/lang/reader))

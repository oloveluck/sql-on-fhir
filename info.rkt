#lang info

;; sql-on-fhir — SQL on FHIR for Racket: ViewDefinitions as a generated #lang, the view engine, and
;; the IG's operations ($sql-run, $sql-export) as fhir/operation values.
;;
;; The model and the operations' definitions are GENERATED from the IG package (spec/, pulled from the
;; FHIR package registry, published from HL7's FHIR/sql-on-fhir-v2) by the fhir package's codegen;
;; the conformance suite is the shared test suite from FHIR/sql-on-fhir.js (tests/vendor).

(define collection "sql-on-fhir")
(define version "0.1")
(define pkg-desc "SQL on FHIR for Racket: ViewDefinitions generated from the IG package (#lang sql-on-fhir), a view engine over FHIR data, and the IG's $sql-run / $sql-export operations; raco sql-on-fhir")
(define pkg-authors '(oloveluck))
(define license 'MIT)
(define deps '("base" "fhir" "fhirpath"))
;; fhir-spec: regenerating the model reads the R6 core package (the model delegates to the R6 tower)
(define build-deps '("rackunit-lib" "fhir-spec"))
(define raco-commands
  '(("sql-on-fhir" (submod sql-on-fhir/cli main) "run ViewDefinitions over FHIR data; the shared test suite; regenerate the model from the IG package" #f)))
(define test-omit-paths '("tests/vendor" "spec"))

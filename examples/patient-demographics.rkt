#lang sql-on-fhir

;; A ViewDefinition written in #lang sql-on-fhir: the forms come from the model generated from the
;; IG package, so a misspelled element, a wrong type or a code outside a required value set (status)
;; is a compile error. `racket examples/patient-demographics.rkt` prints its FHIR JSON;
;; `raco sql-on-fhir run examples/patient-demographics.rkt <data>` runs it.

(ViewDefinition
 (name "patient_demographics")
 (status "active")
 (resource "Patient")
 (select (ViewDefinitionSelect
          (column (ViewDefinitionSelectColumn (name "id") (path "getResourceKey()"))
                  (ViewDefinitionSelectColumn (name "gender") (path "gender"))
                  (ViewDefinitionSelectColumn (name "birth_date") (path "birthDate"))))
         (ViewDefinitionSelect
          (forEachOrNull "name.where(use = 'official').first()")
          (column (ViewDefinitionSelectColumn (name "family") (path "family"))))))

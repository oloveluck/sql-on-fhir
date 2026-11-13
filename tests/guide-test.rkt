#lang racket/base

;;; guide-test.rkt — guide.md (the guide agents read: fhir-mcp serves it as learn://sql-on-fhir, the
;;; sql-on-fhir skill points to it) keeps its promises: every ```view block is a ViewDefinition the
;;; generated model accepts, the examples give the rows the text says, and the common problems it
;;; names behave as written.

(require rackunit racket/runtime-path racket/file racket/list racket/string json
         fhir/operation
         (only-in sql-on-fhir/workspace guide)
         (only-in sql-on-fhir/operations view-rows $sql-run))

(define-runtime-path guide-file "../guide.md")
(define text (file->string guide-file))
(define views (map (lambda (b) (string->jsexpr (cadr b))) (regexp-match* #px"```view\n(.*?)```" text #:match-select values)))
(define (view-named n) (findf (lambda (v) (equal? (hash-ref v 'name #f) n)) views))
(define (row . kvs) (for/hasheq ([k (in-list kvs)] [i (in-naturals)] #:when (even? i)) (values k (list-ref kvs (add1 i)))))

;; the data the text describes
(define patients
  (list (hasheq 'resourceType "Patient" 'id "p1" 'gender "female" 'birthDate "1974-12-25")
        (hasheq 'resourceType "Patient" 'id "p2" 'gender "male" 'birthDate "1990-03-01")))
(define (component code v)
  (hasheq 'code (hasheq 'coding (list (hasheq 'system "http://loinc.org" 'code code)))
          'valueQuantity (hasheq 'value v 'unit "mm[Hg]")))
(define panel
  (hasheq 'resourceType "Observation" 'id "o1" 'status "final" 'subject (hasheq 'reference "Patient/p1")
          'code (hasheq 'coding (list (hasheq 'system "http://loinc.org" 'code "85354-9")))
          'effectiveDateTime "2024-03-01T09:00:00Z"
          'component (list (component "8480-6" 152) (component "8462-4" 95))))

(test-case "the guide the workspace serves is this file"
  (check-equal? guide text))

(test-case "every view in the guide is a ViewDefinition"
  (check-true (>= (length views) 2))
  (for ([v (in-list views)]) (check-not-exn (lambda () (view-rows v '())) (hash-ref v 'name ""))))

(test-case "the worked example gives the rows the text shows"
  (check-equal? (view-rows (view-named "patients") patients)
                (list (row 'id "p1" 'gender "female" 'birth_date "1974-12-25")
                      (row 'id "p2" 'gender "male" 'birth_date "1990-03-01")))
  ;; and as CSV, the text's table
  (define csv ($sql-run (view-named "patients") #:resource patients #:_format "csv"))
  (check-equal? (bytes->string/utf-8 ((dynamic-require 'net/base64 'base64-decode) (string->bytes/utf-8 (hash-ref csv 'data))))
                "id,gender,birth_date\r\np1,female,1974-12-25\r\np2,male,1990-03-01\r\n"))

(test-case "the cheat sheet: one row per component, with the Observation's columns"
  (check-equal? (view-rows (view-named "bp_readings") (list panel))
                (list (row 'id "o1" 'patient "p1" 'date "2024-03-01T09:00:00Z" 'code "8480-6" 'value 152)
                      (row 'id "o1" 'patient "p1" 'date "2024-03-01T09:00:00Z" 'code "8462-4" 'value 95))))

(test-case "the common problems behave as the guide says"
  (define (view resource select) (hasheq 'resourceType "ViewDefinition" 'status "active" 'resource resource 'select select))
  ;; an unknown element is refused, naming it
  (check-exn #rx"unknown field selct"
             (lambda () (view-rows (hasheq 'resourceType "ViewDefinition" 'status "active" 'resource "Patient" 'selct '()) '())))
  ;; several values in a column: an error from $sql-run, a list with collection
  (define codes (hasheq 'name "codes" 'path "component.code.coding.code"))
  (check-exn #rx"path yields 2 items without collection=true"
             (lambda () ($sql-run (view "Observation" (list (hasheq 'column (list codes)))) #:resource (list panel) #:_format "json")))
  (check-equal? (view-rows (view "Observation" (list (hasheq 'column (list (hash-set codes 'collection #t))))) (list panel))
                (list (row 'codes '("8480-6" "8462-4"))))
  ;; forEach drops a resource without the element; forEachOrNull keeps it
  (define id (hasheq 'column (list (hasheq 'name "id" 'path "id"))))
  (define family (list (hasheq 'name "family" 'path "family")))
  (check-equal? (view-rows (view "Patient" (list id (hasheq 'forEach "name" 'column family))) patients) '())
  (check-equal? (length (view-rows (view "Patient" (list id (hasheq 'forEachOrNull "name" 'column family))) patients)) 2)
  ;; getReferenceKey reads a relative reference; an absolute url gives null
  (define key (list (hasheq 'column (list (hasheq 'name "p" 'path "subject.getReferenceKey(Patient)")))))
  (check-equal? (view-rows (view "Observation" key) (list (hash-set panel 'subject (hasheq 'reference "http://example.org/fhir/Patient/p1"))))
                (list (row 'p 'null)))
  ;; JSON is checked against the required value sets too, with the message the guide quotes
  (check-exn (regexp (regexp-quote "\"live\" is not in the required value set for ViewDefinition.status"))
             (lambda () (view-rows (hash-set (view "Patient" (list id)) 'status "live") patients)))
  ;; a required element left out is named where it is missing, in the words the guide quotes;
  ;; `status` is the one not held
  (check-true (regexp-match? (regexp-quote "the view has no `resource` (the type of resource the view reads, such as \"Patient\")") text))
  (check-exn (regexp (regexp-quote "the view has no `resource` (the type of resource the view reads, such as \"Patient\")"))
             (lambda () (view-rows (hash-remove (view "Patient" (list id)) 'resource) patients)))
  (define three (list (hasheq 'name "id" 'path "id") (hasheq 'name "gender" 'path "gender") (hasheq 'path "birthDate")))
  (check-exn (regexp (regexp-quote "select[0].column[2] has no `name` "))
             (lambda () (view-rows (view "Patient" (list (hasheq 'column three))) patients)))
  (check-equal? (length (view-rows (hash-remove (view "Patient" (list id)) 'status) patients)) 2)
  ;; read as R6 (this process, like the command line by default), an R4 MedicationRequest's drug is
  ;; not found by a path valid in both versions: an empty column, no message
  (define r4-request (hasheq 'resourceType "MedicationRequest" 'id "m1" 'status "active" 'intent "order"
                             'medicationCodeableConcept (hasheq 'text "metformin 500 mg")))
  (define drug (list (hasheq 'column (list (hasheq 'name "drug" 'path "medication.ofType(CodeableConcept).text")))))
  (check-equal? (view-rows (view "MedicationRequest" drug) (list r4-request)) (list (row 'drug 'null)))
  ;; a value that is not valid FHIR is not read: a time with no time zone
  (define (observed at) (hash-set (hash-remove panel 'component) 'effectiveDateTime at))
  (define date (list (hasheq 'column (list (hasheq 'name "date" 'path "effective.ofType(dateTime)")))))
  (check-equal? (view-rows (view "Observation" date) (list (observed "2021-05-31T00:00:00") (observed "2021-05-31T00:00:00Z")))
                (list (row 'date 'null) (row 'date "2021-05-31T00:00:00Z"))))

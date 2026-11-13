#lang racket/base

;;; cli-test.rkt — the command line as a person runs it: `raco sql-on-fhir run` in a process of its
;;; own (the FHIR version the data is read as belongs to the process: one tower per type name),
;;; over small files written to a temporary directory. What is checked is what the terminal shows:
;;; the rows on stdout, the problems on stderr — each the message alone, never Racket's `context...`
;;; lines or an internal contract violation — and the exit status.

(require rackunit racket/file racket/string racket/system compiler/find-exe)

(define dir (make-temporary-file "sql-on-fhir-cli-~a" 'directory))
;; write! : name line … -> name   a file of the temporary directory
(define (write! name . lines) (display-lines-to-file lines (build-path dir name)) name)
;; run : argument … -> (list exit-status stdout stderr)   `raco sql-on-fhir run <arguments>` there
(define (run . args)
  (define out (open-output-string))
  (define err (open-output-string))
  (define code (parameterize ([current-directory dir] [current-output-port out] [current-error-port err])
                 (apply system*/exit-code (find-exe) "-l-" "raco" "sql-on-fhir" "run" args)))
  (list code (get-output-string out) (get-output-string err)))

(make-directory (build-path dir "patients"))
(void (write! "patients/p1.json" "{\"resourceType\":\"Patient\",\"id\":\"p1\",\"gender\":\"female\"}"))
(define columns "\"select\":[{\"column\":[{\"name\":\"id\",\"path\":\"id\"}]}]}")

(test-case "a view with no `resource` is a view problem, one line (it was `string->symbol: contract violation`)"
  (write! "no-resource.json" (string-append "{\"resourceType\":\"ViewDefinition\",\"status\":\"active\"," columns))
  (check-equal? (run "no-resource.json" "patients")
                (list 1 "" (string-append "sql-on-fhir: not a valid ViewDefinition: the view has no `resource` "
                                          "(the type of resource the view reads, such as \"Patient\")\n")))
  ;; so is any other element the definition requires: a column with no name, with no data at all,
  ;; printed a stack trace
  (write! "no-name.json" "{\"resourceType\":\"ViewDefinition\",\"status\":\"active\",\"resource\":\"Patient\","
          "\"select\":[{\"column\":[{\"path\":\"id\"}]}]}")
  (check-equal? (run "no-name.json")
                (list 1 "" "sql-on-fhir: not a valid ViewDefinition: select[0].column[0] has no `name` (the column's name in the table)\n")))

(define no-status-warning
  "sql-on-fhir: warning: no-status.json:1:1: no `status` (the standard requires it: \"draft\", \"active\", \"retired\" or \"unknown\")\n")
(test-case "a view with no `status` runs (the shared suite's own views leave it out), and is told so"
  (write! "no-status.json" (string-append "{\"resourceType\":\"ViewDefinition\",\"resource\":\"Patient\"," columns))
  ;; the rows and the exit status are those of a view that states one; the warning is on stderr
  (check-equal? (run "no-status.json" "patients" "--format" "csv") (list 0 "id\r\np1\r\n" no-status-warning)))

;; R4 data: a MedicationRequest names its drug in `medicationCodeableConcept`, a choice R5 replaced
;; with one `medication` element of another type
(make-directory (build-path dir "r4"))
(void (write! "r4/m1.json"
              "{\"resourceType\":\"MedicationRequest\",\"id\":\"m1\",\"status\":\"active\",\"intent\":\"order\","
              " \"medicationCodeableConcept\":{\"text\":\"metformin 500 mg\"},\"subject\":{\"reference\":\"Patient/p1\"}}"))
(define (meds path)
  (list "{\"resourceType\":\"ViewDefinition\",\"status\":\"active\",\"resource\":\"MedicationRequest\","
        " \"select\":[{\"column\":[{\"name\":\"id\",\"path\":\"id\"},"
        (format "   {\"name\":\"drug\",\"path\":~s}]}]}" path)))

(test-case "--fhir-version 4.0.1 reads the data as R4"
  (apply write! "meds.json" (meds "medication.ofType(CodeableConcept).text"))
  ;; as R6 (the default) the R4 element is not read, and that is said: the path is valid in both
  ;; versions (R6 has a `medication` of another type), so the empty column came without a word
  (check-equal? (run "meds.json" "r4" "--format" "csv")
                (list 0 "id,drug\r\nm1,\r\n"
                      (string-append "sql-on-fhir: warning: 1 of 1 MedicationRequest resources holds `medicationCodeableConcept`, "
                                     "which was not read: FHIR R6 has no such element (the first: MedicationRequest/m1); "
                                     "--fhir-version 4.0.1 reads the data as R4\n")))
  (check-equal? (run "meds.json" "r4" "--format" "csv" "--fhir-version" "4.0.1") (list 0 "id,drug\r\nm1,metformin 500 mg\r\n" ""))
  ;; a view written as a module runs over R4 data too, and R5 is a version as well
  (write! "meds.sof" "#lang sql-on-fhir"
          "(ViewDefinition (status \"active\") (resource \"MedicationRequest\")"
          " (select (ViewDefinitionSelect (column (ViewDefinitionSelectColumn (name \"drug\")"
          "   (path \"medication.ofType(CodeableConcept).text\"))))))")
  (check-equal? (run "meds.sof" "r4" "--format" "csv" "--fhir-version" "4.0.1") (list 0 "drug\r\nmetformin 500 mg\r\n" ""))
  (check-equal? (run "no-status.json" "patients" "--format" "csv" "--fhir-version" "5.0.0") (list 0 "id\r\np1\r\n" no-status-warning))
  ;; a version there is no tower for is a usage error
  (define unknown (run "meds.json" "r4" "--fhir-version" "3.0.2"))
  (check-equal? (car unknown) 2)
  (check-regexp-match #rx"^raco sql-on-fhir run: --fhir-version takes 4.0.1, 5.0.0 or 6.0.0 [(]got 3.0.2[)]\nusage: " (caddr unknown)))

(test-case "a path to an element the type lacks in the version read is a warning, at its place in the file"
  (apply write! "meds-r4-path.json" (meds "medicationCodeableConcept.text"))
  ;; no data: nothing fails, and the heading alone said nothing of the path
  (check-equal? (run "meds-r4-path.json" "--format" "csv")
                (list 0 "id,drug\r\n"
                      (string-append "sql-on-fhir: warning: meds-r4-path.json:3:26: no element MedicationRequest.medicationCodeableConcept "
                                     "(the data is read as FHIR R6; --fhir-version 4.0.1 reads it as R4)\n")))
  (check-equal? (run "meds-r4-path.json" "r4" "--format" "csv" "--fhir-version" "4.0.1") (list 0 "id,drug\r\nm1,metformin 500 mg\r\n" ""))
  ;; a forEach over such an element gave an empty column and exit 0 over data, without a word
  (write! "each.json" "{\"resourceType\":\"ViewDefinition\",\"status\":\"active\",\"resource\":\"MedicationRequest\","
          " \"select\":[{\"forEachOrNull\":\"medicationCodeableConcept.coding\",\"column\":[{\"name\":\"code\",\"path\":\"code\"}]}]}")
  (check-equal? (run "each.json" "r4" "--format" "csv")
                (list 0 "code\r\n\r\n"
                      (string-append "sql-on-fhir: warning: each.json:2:29: no element MedicationRequest.medicationCodeableConcept "
                                     "(the data is read as FHIR R6; --fhir-version 4.0.1 reads it as R4)\n")))
  ;; over data such a column fails: said once, at its place (not a warning and then the same error)
  (check-equal? (run "meds-r4-path.json" "r4" "--format" "csv")
                (list 1 ""
                      (string-append "sql-on-fhir: meds-r4-path.json:3:26: no element MedicationRequest.medicationCodeableConcept "
                                     "(the data is read as FHIR R6; --fhir-version 4.0.1 reads it as R4)\n")))
  ;; a misspelt element is said with the nearest, in the version asked for
  (apply write! "typo.json" (meds "statuss"))
  (check-equal? (caddr (run "typo.json" "--fhir-version" "4.0.1"))
                "sql-on-fhir: warning: typo.json:3:26: no element MedicationRequest.statuss (did you mean `status`?) (the data is read as FHIR R4)\n"))

(test-case "what a view says of itself: a path that is not FHIRPath, the FHIR versions it is for, its definition"
  ;; a path that does not parse is the view's problem whatever the data: over no data it printed
  ;; the heading alone, exit 0
  (apply write! "bad-path.json" (meds "medication."))
  (define refusal "sql-on-fhir: not a valid ViewDefinition: the path \"medication.\" is not FHIRPath: the expression ends after `.`\n")
  (check-equal? (run "bad-path.json" "--format" "csv") (list 1 "" refusal))
  (check-equal? (run "bad-path.json" "r4" "--format" "csv") (list 1 "" refusal))
  ;; a view that names the FHIR versions it is for (`fhirVersion`), read as another, is told so, with
  ;; the option that reads the data as one of them. R6 writes the canonical of ViewDefinition's
  ;; definition beside `resourceType` (the IG's own examples do): it is no unknown element.
  (write! "for-r4.json" "{\"resourceType\":\"ViewDefinition\","
          " \"resourceDefinition\":\"http://hl7.org/fhir/StructureDefinition/ViewDefinition|3.0.0-ballot\","
          " \"status\":\"active\",\"resource\":\"MedicationRequest\",\"fhirVersion\":[\"4.0\"],"
          " \"select\":[{\"column\":[{\"name\":\"id\",\"path\":\"id\"}]}]}")
  (check-equal? (run "for-r4.json" "r4" "--format" "csv")
                (list 0 "id\r\nm1\r\n"
                      (string-append "sql-on-fhir: warning: for-r4.json:3:51: the view is for FHIR 4.0 (`fhirVersion`) and the data is read as FHIR R6; "
                                     "--fhir-version 4.0.1 reads it as R4\n")))
  (check-equal? (run "for-r4.json" "r4" "--format" "csv" "--fhir-version" "4.0.1") (list 0 "id\r\nm1\r\n" ""))
  ;; the definition's own rules: a column name a database does not take, two iterations in one select
  (write! "names.json" "{\"resourceType\":\"ViewDefinition\",\"status\":\"active\",\"resource\":\"Patient\","
          " \"select\":[{\"forEach\":\"name\",\"forEachOrNull\":\"name\",\"column\":[{\"name\":\"family-name\",\"path\":\"family\"}]}]}")
  (check-equal? (run "names.json" "patients")
                (list 1 "" (string-append "sql-on-fhir: not a valid ViewDefinition: "
                                          "select[0] has more than one of `forEach`, `forEachOrNull` and `repeat`: a select takes one; "
                                          "select[0].column[0].name \"family-name\" is not a name a database takes: "
                                          "letters, digits and _ only, starting with a letter\n"))))

(test-case "a value the view reads that the read left out is said, once for the data; what it does not read is not"
  ;; a dateTime with a time and no zone is not valid FHIR: the lenient read drops it, in any version
  (make-directory (build-path dir "encounters"))
  (for ([id (in-list '("e1" "e2" "e3"))] [start (in-list '("2019-01-01T08:00:00" "2019-01-02T08:00:00" "2019-01-03T08:00:00Z"))])
    (write! (format "encounters/~a.json" id)
            (format "{\"resourceType\":\"Encounter\",\"id\":~s,\"status\":\"finished\",\"class\":{\"code\":\"AMB\"}," id)
            (format " \"period\":{\"start\":~s,\"end\":\"2019-01-04T09:00:00Z\"}}" start)))
  (define (encounters path)
    (list "{\"resourceType\":\"ViewDefinition\",\"status\":\"active\",\"resource\":\"Encounter\","
          (format " \"select\":[{\"column\":[{\"name\":\"id\",\"path\":\"id\"},{\"name\":\"at\",\"path\":~s}]}]}" path)))
  (apply write! "starts.json" (encounters "period.start"))
  (check-equal? (run "starts.json" "encounters" "--format" "csv" "--fhir-version" "4.0.1")
                (list 0 "id,at\r\ne1,\r\ne2,\r\ne3,2019-01-03T08:00:00Z\r\n"
                      (string-append "sql-on-fhir: warning: 2 of 3 Encounter resources hold a value at `period.start` that is not valid FHIR "
                                     "and was not read (the first: Encounter/e1: \"2019-01-01T08:00:00\" — a time needs a time zone, "
                                     "such as Z or +01:00)\n")))
  ;; a view that reads another element of the same period is told nothing: its table lacks nothing
  (apply write! "ends.json" (encounters "period.end"))
  (check-equal? (run "ends.json" "encounters" "--format" "csv" "--fhir-version" "4.0.1")
                (list 0 "id,at\r\ne1,2019-01-04T09:00:00Z\r\ne2,2019-01-04T09:00:00Z\r\ne3,2019-01-04T09:00:00Z\r\n" "")))

(test-case "a #lang sql-on-fhir file that does not compile: the error's message at its line, exit 1"
  (write! "bad.sof" "#lang sql-on-fhir"
          "(ViewDefinition (name \"patients\") (status \"active\") (resource \"Patient\")"
          " (selct (column (name \"id\") (path \"id\"))))")
  (check-equal? (run "bad.sof" "patients")
                (list 1 "" (string-append "sql-on-fhir: bad.sof:3:2: ViewDefinition: unknown field ViewDefinition.selct\n"
                                          "  at: selct\n"
                                          "  in: (selct (column (name \"id\") (path \"id\")))\n")))
  ;; an error positioned in the file keeps its line and column
  (write! "open.sof" "#lang sql-on-fhir" "(ViewDefinition (name \"patients\")")
  (check-equal? (run "open.sof" "patients")
                (list 1 "" "sql-on-fhir: open.sof:2:0: read-syntax: expected a `)` to close `(`\n"))
  ;; a required form left out: the form macros' own source position is not the user's, and is dropped
  (write! "no-resource.sof" "#lang sql-on-fhir" "(ViewDefinition (status \"active\"))")
  (define missing (run "no-resource.sof"))
  (check-equal? (car missing) 1)
  (check-regexp-match #rx"^sql-on-fhir: no-resource.sof:2:0: ViewDefinition: missing required field ViewDefinition[.][a-z]+\n  in: " (caddr missing))
  (check-false (regexp-match? #rx"context[.][.][.]|[.]rkt:" (caddr missing)))
  ;; a module that is no view at all
  (write! "other.rkt" "#lang racket/base")
  (check-equal? (run "other.rkt") (list 1 "" "sql-on-fhir: other.rkt is not a #lang sql-on-fhir module (it provides no views)\n")))

(delete-directory/files dir)

#lang racket/base

;;; features-test.rkt — the feature list (features.rkt) held to what it lists.
;;;
;;; Against the IG package (spec/): every element of the ViewDefinition's definition, every
;;; parameter of the two OperationDefinitions and every output format code is a row, and no row
;;; names one the IG does not have — so a newer IG, once regenerated, fails here until someone
;;; says what is done with what is new. Against the code: every definition a row points to is in
;;; its file; the elements the engine reads and the inputs the operations read are the rows that
;;; say so; `(require sql-on-fhir)` provides what `from-racket` lists. Against the shared suite:
;;; every file a row names is there, and every file is some row's.
;;; (Each module's own tests hold its dispatch tables to the rows: view.rkt, operations.rkt,
;;; cli.rkt, definition.rkt.)

(require rackunit racket/list racket/string racket/file racket/runtime-path
         (only-in fhir/package read-package)
         (only-in sql-on-fhir/target ig-package)
         (only-in sql-on-fhir/model/operations sql-run-definition sql-export-definition)
         (only-in "harness.rkt" suite-files)
         (only-in racket/path file-name-from-path)
         "../features.rkt")

(define-runtime-path package-root "..")

;; names-in : area [keep?] -> (listof string)   every name of the table's rows that keep? keeps, sorted
(define (names-in area [keep? (lambda (f) #t)])
  (sort (append-map feature-names (filter keep? (features-of area))) string<?))
(define (in-state . states) (lambda (f) (and (memq (feature-state f) states) #t)))

;; ---- the IG package -------------------------------------------------------------------------------
(define-values (_manifest resources _examples) (read-package ig-package))
(define (resources-of type) (for/list ([r (in-list resources)] #:when (equal? (hash-ref (cdr r) 'resourceType #f) type)) (cdr r)))
(define (resource type id) (findf (lambda (r) (equal? (hash-ref r 'id #f) id)) (resources-of type)))

;; -- a ViewDefinition's elements: the definition's snapshot, path by path
(define definition (resource "StructureDefinition" "ViewDefinition"))
(define element-paths                    ; below the root, "select.column.name"
  (for*/list ([e (in-list (hash-ref (hash-ref definition 'snapshot) 'element))]
              [m (in-value (regexp-match #rx"^ViewDefinition[.](.*)$" (hash-ref e 'path)))] #:when m)
    (cadr m)))
;; listed-as : element path -> the name a row lists it under. An extension and a modifierExtension
;; are one row each for every level; an inner element's own `id` (FHIR's element id) is no feature.
(define (listed-as path)
  (define steps (string-split path "."))
  (cond [(member (last steps) '("extension" "modifierExtension")) (last steps)]
        [(and (equal? (last steps) "id") (pair? (cdr steps))) #f]
        [else path]))
(check-equal? (sort (remove-duplicates (filter-map listed-as element-paths)) string<?) (names-in 'view)
              "the-view lists the elements of the IG's ViewDefinition, each once")

;; -- the operations' parameters, parts as `subject.name`
(define (parameter-names od use)
  (let loop ([ps (hash-ref od 'parameter)] [prefix ""])
    (append* (for/list ([p (in-list ps)] #:when (equal? (hash-ref p 'use) use))
               (define name (string-append prefix (hash-ref p 'name)))
               (cons name (loop (hash-ref p 'part '()) (string-append name ".")))))))
(define (a-format? name) (regexp-match? #rx"^_format=" name))
(define (parameters area) (filter (lambda (n) (not (a-format? n))) (names-in area (in-state 'yes 'partly 'unused 'refused 'no))))
(check-equal? (parameters 'sql-run) (sort (parameter-names sql-run-definition "in") string<?))
(check-equal? (parameters 'sql-run-answers) (sort (parameter-names sql-run-definition "out") string<?))
(check-equal? (parameters 'sql-export) (sort (parameter-names sql-export-definition "in") string<?))
(check-equal? (parameters 'sql-export-answers) (sort (parameter-names sql-export-definition "out") string<?))
;; what a row calls this package's own is not the IG's
(for ([area (in-list '(sql-run sql-run-answers sql-export sql-export-answers))]
      [od (in-list (list sql-run-definition sql-run-definition sql-export-definition sql-export-definition))]
      [use (in-list '("in" "out" "in" "out"))])
  (for ([n (in-list (names-in area (in-state 'own)))])
    (check-false (member n (parameter-names od use)) (format "~a is the definition's" n))))

;; -- the output formats: the IG's code system; an export's value set leaves one out, and the row
;;    for it says $sql-export refuses it
(define (formats-in area [keep? (lambda (f) #t)])
  (for*/list ([n (in-list (names-in area keep?))] #:when (a-format? n)) (substring n (string-length "_format="))))
(define format-codes
  (sort (map (lambda (c) (hash-ref c 'code)) (hash-ref (resource "CodeSystem" "OutputFormatCodes") 'concept)) string<?))
(define export-codes
  (sort (for*/list ([i (in-list (hash-ref (hash-ref (resource "ValueSet" "ExportOutputFormatCodes") 'compose) 'include))]
                    [c (in-list (hash-ref i 'concept))])
          (hash-ref c 'code))
        string<?))
(check-equal? (formats-in 'sql-run) format-codes)
(check-equal? (formats-in 'sql-export) format-codes)
(check-equal? (formats-in 'sql-export (lambda (f) (equal? (feature-where f) '(operations.rkt $sql-export))))
              (remove* export-codes format-codes))

;; -- the IG's other definitions are spoken of: its profiles and its extension, by name
(define said (string-join (append (append-map feature-names features) (map feature-what features) (map table-title tables))))
(for ([sd (in-list (resources-of "StructureDefinition"))])
  (check-true (string-contains? said (hash-ref sd 'id)) (format "no row speaks of the IG's ~a" (hash-ref sd 'id))))
(for ([od (in-list (list sql-run-definition sql-export-definition))])
  (check-true (string-contains? said (string-append "$" (hash-ref od 'code)))))
(check-equal? (length (resources-of "OperationDefinition")) 2 "the IG has an operation features.rkt has no table for")

;; ---- the code -------------------------------------------------------------------------------------
;; code-of : file -> string   a module's code: without its comments and its tests
(define (code-of file)
  (define text (file->string (build-path package-root file)))
  (define body (car (regexp-split #rx"\n\\(module\\+ test" text)))
  (regexp-replace* #px"(?m:;;.*$)" body ""))

;; -- every definition a row points to is in its file
(for ([f (in-list features)] #:when (feature-where f))
  (define file (symbol->string (car (feature-where f))))
  (define name (symbol->string (cadr (feature-where f))))
  (check-true (file-exists? (build-path package-root file)) (format "~a: no file ~a" (feature-names f) file))
  (check-true (regexp-match? (pregexp (string-append "\\((?:define|struct)\\s+\\(?" (regexp-quote name) "(?=[\\s)])"))
                             (file->string (build-path package-root file)))
              (format "~a: ~a defines no `~a`" (feature-names f) file name)))

;; -- the elements the engine reads are the rows that point into it
(define engine (code-of "view.rkt"))
(define (last-step name) (last (string-split name ".")))
(check-equal? (sort (remove-duplicates (regexp-match* #px"\\((?:pstr|fld|flds) \\w+ '(\\w+)" engine #:match-select cadr)) string<?)
              (sort (remove* '("value[x]")
                             (remove-duplicates
                              (for*/list ([f (in-list (features-of 'view))]
                                          #:when (and (feature-where f) (eq? (car (feature-where f)) 'view.rkt))
                                          [n (in-list (feature-names f))])
                                (last-step n))))
                    string<?))
;; a constant's value is read under each type the definition gives `value[x]`
(define value-types
  (for*/list ([e (in-list (hash-ref (hash-ref definition 'snapshot) 'element))]
              #:when (equal? (hash-ref e 'path) "ViewDefinition.constant.value[x]")
              [t (in-list (hash-ref e 'type))])
    (define code (hash-ref t 'code))
    (string-append "value" (string-upcase (substring code 0 1)) (substring code 1))))
(check-equal? (sort (remove-duplicates (regexp-match* #px"\\bvalue[A-Z][A-Za-z0-9]*" engine)) string<?) (sort value-types string<?))

;; -- the inputs the operations read are the rows that say something is done with them
(define operations (code-of "operations.rkt"))
(for ([area (in-list '(sql-run sql-export))])
  (for* ([f (in-list (features-of area))] [n (in-list (feature-names f))] #:unless (a-format? n))
    (check-equal? (string-contains? operations (format "~s" (last-step n)))
                  (and (memq (feature-state f) '(yes partly refused)) #t)
                  (format "~a ~a: ~a, and operations.rkt ~a" area n (feature-state f)
                          (if (string-contains? operations (format "~s" (last-step n))) "reads it" "does not read it")))))
;; and what $sql-export answers is what the rows say it writes (a name written at one level and
;; not at another — `location` — decides nothing here)
(define answers (features-of 'sql-export-answers))
(define (written? f) (not (eq? (feature-state f) 'no)))
(define (told-apart? n)
  (= 1 (length (remove-duplicates (for*/list ([f (in-list answers)] [m (in-list (feature-names f))] #:when (equal? (last-step m) (last-step n)))
                                    (written? f))))))
(for* ([f (in-list answers)] [n (in-list (feature-names f))] #:when (told-apart? n))
  (check-equal? (string-contains? operations (format "~s" (last-step n))) (written? f)
                (format "$sql-export answers ~a: ~a" n (feature-state f))))

;; -- (require sql-on-fhir) provides what from-racket lists: each name, and the names a struct brings
(define racket-names (names-in 'racket))
(define provided
  (let-values ([(variables syntaxes) (begin (dynamic-require 'sql-on-fhir #f) (module->exports 'sql-on-fhir))])
    (remove-duplicates (for*/list ([phase (in-list (append variables syntaxes))] [e (in-list (cdr phase))]) (symbol->string (car e))))))
(for ([n (in-list racket-names)])
  (check-true (and (member n provided) #t) (format "(require sql-on-fhir) does not provide ~a" n)))
(define (of-a-struct? e)
  (for/or ([s (in-list racket-names)])
    (or (equal? e (string-append s "?")) (equal? e (string-append "struct:" s)) (string-prefix? e (string-append s "-")))))
(for ([e (in-list provided)])
  (check-true (or (and (member e racket-names) #t) (of-a-struct? e)) (format "from-racket has no row for ~a" e)))

;; ---- the shared suite -----------------------------------------------------------------------------
(define suite (for/list ([f (in-list (suite-files))]) (regexp-replace #rx"[.]json$" (path->string (file-name-from-path f)) "")))
(define named (remove-duplicates (map symbol->string (append-map feature-suite features))))
(for ([n (in-list named)]) (check-true (and (member n suite) #t) (format "a row names the suite file ~a: there is none" n)))
(for ([s (in-list suite)]) (check-true (and (member s named) #t) (format "the suite file ~a is no row's" s)))

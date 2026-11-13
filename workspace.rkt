#lang racket/base

;;; workspace.rkt — what SQL on FHIR offers a workspace (fhir/lang/workspace): a ViewDefinition written
;;; as JSON (`*.view.json`, the form the specification and its test suite use) is an artifact
;;; (canonical `<workspace canonical>/ViewDefinition/<file stem>` unless it names one), checked
;;; against the model generated from the IG; a run is its rows over the data source; an explanation,
;;; what one resource contributes: the rows it alone produces, and whether each `where` holds for it.
;;; A Row is {column: value …} in the view's column order.

(require racket/contract racket/list racket/string racket/match racket/runtime-path racket/file json
         fhir/lang/workspace
         (only-in fhir/diagnostic diagnostic diagnostic? loc exn:fail:diagnostic exn:fail:diagnostic? exn:fail:diagnostic-diagnostic)
         (only-in fhir/operation exn:fail:operation? exn:fail:operation-outcome)
         (only-in fhir/data-source current-data-source data-source-all data-source-read)
         (only-in "view.rkt" view-columns rewrite-sof exn:fail:view? exn:fail:view-path)
         (only-in "definition.rkt" read-view)
         (only-in "operations.rkt" view-rows current-read-log make-read-log read-log-count read-log-reads)
         (only-in "unread.rkt" unread-notes)
         (only-in fhirpath/parser/parse parse-fhirpath)
         (only-in fhirpath/analyze analyze)
         (only-in fhirpath/error exn:fp?)
         (only-in fhir/model/registry type-registered?))

(provide (contract-out [workspace-support ws-support?]
                       ;; path-problems : file text view -> the view's paths that name an element its
                       ;; resource type lacks, each at its string in the text (the command line warns with it)
                       [path-problems (-> (or/c path-string? #f) string? hash? (listof diagnostic?))]
                       ;; status-problem : file text view -> a warning when the view states no `status`
                       ;; (the standard requires one; the view still runs), at the view's opening brace
                       [status-problem (-> (or/c path-string? #f) string? hash? (or/c diagnostic? #f))]
                       ;; version-problem : file text view version-name -> a warning when the view names
                       ;; the FHIR versions it is for (`fhirVersion`) and the one the data is read as
                       ;; ("R4", "R6") is none of them, at `fhirVersion`
                       [version-problem (-> (or/c path-string? #f) string? hash? string? (or/c diagnostic? #f))]
                       ;; with-unread : view version-name thunk -> (values result notes)   the thunk's
                       ;; result, and a sentence for each element the view reads that the lenient read
                       ;; of the data left out while it ran (unread.rkt); version-name: "R4", "R6"
                       [with-unread (-> hash? string? (-> any) (values any/c (listof string?)))]
                       ;; guide : the language guide (guide.md) a hub serves to agents (learn://sql-on-fhir)
                       [guide string?]))

(define-runtime-path guide-file "guide.md")
(define guide (file->string guide-file))

(define (path-string p) (if (path? p) (path->string p) p))
;; fail : path|#f message [loc] -> raises a diagnostic   the file's problem, at the file unless a place is given
(define (fail path msg [at (loc (and path (path-string path)) #f #f #f #f)])
  (raise (exn:fail:diagnostic msg (current-continuation-marks) (diagnostic 'sql-on-fhir 'compile 'error msg at))))

;; view : workspace path|#f text -> ViewDefinition jsexpr   raises a diagnostic when it is not one
(define (view ws path text)
  (define js (with-handlers ([exn:fail? (lambda (e) (fail path (format "not JSON: ~a" (exn-message e))))]) (string->jsexpr text)))
  (unless (and (hash? js) (member (hash-ref js 'resourceType "ViewDefinition") '("ViewDefinition")))
    (fail path "a ViewDefinition is a JSON object with \"resourceType\": \"ViewDefinition\""))
  (define v (let ([v (hash-set js 'resourceType "ViewDefinition")])
              (if (and path (not (hash-has-key? v 'url))) (hash-set v 'url (file-canonical ws "ViewDefinition" path)) v)))
  ;; the view over no data: what its definition refuses (the strict parse, required elements, the
  ;; definition's constraints) and what the engine refuses before it reads any (a path that is not
  ;; FHIRPath, said at the path's string in the file; unionAll branches of different columns)
  (with-handlers ([exn:fail:operation? (lambda (e) (fail path (outcome-text (exn:fail:operation-outcome e))))]
                  [exn:fail:view? (lambda (e)
                                    (define msg (regexp-replace #rx"^eval-view: " (exn-message e) ""))
                                    (if (exn:fail:view-path e)
                                        (fail path msg (string-location path text (exn:fail:view-path e)))
                                        (fail path msg)))])
    (view-rows v '()))
  v)
(define (outcome-text oo)
  (string-join (for/list ([i (in-list (hash-ref oo 'issue '()))]) (or (hash-ref i 'diagnostics #f) (hash-ref i 'code ""))) "; "))

(define (artifacts ws files)
  (for/fold ([rs '()] [ds '()] #:result (values (reverse rs) ds)) ([f (in-list files)])
    (with-handlers ([exn:fail:diagnostic? (lambda (e) (values rs (append ds (list (exn:fail:diagnostic-diagnostic e)))))])
      (define v (view ws (car f) (cdr f)))
      (values (cons (if (hash-has-key? v 'id) v (hash-set v 'id (regexp-replace* #rx"[^A-Za-z0-9.-]" (file-stem (car f)) "-"))) rs)
              (append ds
                      (filter values (list (status-problem (car f) (cdr f) v)
                                           (version-problem (car f) (cdr f) v (version-name ws))))
                      (path-problems (car f) (cdr f) v))))))

;; status-problem : path text ViewDefinition -> diagnostic | #f
;; The definition requires `status` (1..1) and a view without one still runs — the shared suite's own
;; views leave it out — so it is said, as a warning, where the view begins.
(define status-values "\"draft\", \"active\", \"retired\" or \"unknown\"")
(define (status-problem file text v)
  (and (not (hash-has-key? v 'status))
       (diagnostic 'sql-on-fhir 'compile 'warning
                   (format "no `status` (the standard requires it: ~a)" status-values)
                   (text-location file text (regexp-match-positions #rx"{" text)))))

;; version-problem : path text ViewDefinition version-name -> diagnostic | #f
;; A view may name the FHIR versions of the resources it is for (`fhirVersion`: "4.0", "5.0.0"). When
;; the data is read as none of them, its paths are read against another version's elements: said, as
;; a warning, at `fhirVersion`.
(define (version-problem file text v read-as)
  (define stated (let ([vs (hash-ref v 'fhirVersion '())]) (filter string? (if (list? vs) vs (list vs)))))
  (and (pair? stated)
       (not (member read-as (map release-name stated)))
       (diagnostic 'sql-on-fhir 'compile 'warning
                   (format "the view is for FHIR ~a (`fhirVersion`) and the data is read as FHIR ~a" (string-join stated ", ") read-as)
                   (text-location file text (regexp-match-positions #rx"\"?fhirVersion" text)))))
;; release-name : FHIR version -> string   "4.0.1", "4.0" -> "R4"; "6.0.0-ballot3" -> "R6"
(define (release-name version) (format "R~a" (car (string-split version "."))))

;; version-name : workspace -> string   the FHIR version its data is read as: "R4", "R5"
(define (version-name ws) (release-name (ws-config-fhir-version (workspace-config ws))))
;; with-unread : ViewDefinition version-name (-> X) -> (values X (listof string))
(define (with-unread v version-name thunk)
  (define log (make-read-log))
  (define result (parameterize ([current-read-log log]) (thunk)))
  (values result (unread-notes v (read-log-reads log) (read-log-count log) version-name)))

;; path-problems : path text ViewDefinition -> diagnostics   every column, forEach and where path
;; checked against the view's resource type (FHIRPath's static analysis, not strict about choice
;; members), each problem at the path's string in the file. Only an element the type does not have
;; is reported ("no element Observation.effectiveDateTme (did you mean …)"): it is decided; anything
;; the analysis cannot follow is left to run time.
(define (path-problems file text v)
  (define type (let ([r (hash-ref v 'resource #f)]) (and (string? r) (string->symbol r))))
  (define (check path prefix)
    (define full (if (null? prefix) path (string-append (string-join (reverse prefix) ".") "." path)))
    (with-handlers ([exn:fp? (lambda (e)
                               (if (regexp-match? #rx"no element" (exn-message e))
                                   (list (diagnostic 'sql-on-fhir 'compile 'error
                                                     (regexp-replace #rx"^fhirpath: " (exn-message e) "")
                                                     (string-location file text path)))
                                   '()))]
                    [exn:fail? (lambda (_) '())])
      (analyze (rewrite-sof (parse-fhirpath full)) type #:strict? #f)
      '()))
  (define (walk sel prefix)
    (if (hash-ref sel 'repeat #f) '() (walk* sel prefix)))    ; repeat's paths follow each level: unchecked
  (define (walk* sel prefix)
    (define each (or (hash-ref sel 'forEach #f) (hash-ref sel 'forEachOrNull #f)))
    (define inner (if (string? each) (cons each prefix) prefix))
    (define each-problems (if (string? each) (check each prefix) '()))
    (if (pair? each-problems)
        each-problems                       ; what is inside a forEach that names no element only repeats it
        (append (append* (for/list ([c (in-list (hash-ref sel 'column '()))] #:when (string? (hash-ref c 'path #f)))
                           (check (hash-ref c 'path) inner)))
                (append* (for/list ([s (in-list (hash-ref sel 'select '()))]) (walk s inner)))
                (append* (for/list ([s (in-list (hash-ref sel 'unionAll '()))]) (walk s inner))))))
  (if (and type (type-registered? type))
      (remove-duplicates
       (append (append* (for/list ([s (in-list (hash-ref v 'select '()))]) (walk s '())))
               (append* (for/list ([w (in-list (hash-ref v 'where '()))] #:when (string? (hash-ref w 'path #f)))
                          (check (hash-ref w 'path) '())))))
      '()))

;; string-location : file text string -> loc   where the JSON string "<s>" first appears (the file
;; itself when it does not)
(define (string-location file text s)
  (text-location file text (regexp-match-positions (regexp-quote (jsexpr->string s)) text)))
;; text-location : file text match-positions|#f -> loc   the match's line and column in the text
(define (text-location file text m)
  (cond
    [(not m) (loc (and file (path-string file)) #f #f #f #f)]
    [else
     (define pos (caar m))
     (define line (add1 (for/sum ([c (in-string text 0 pos)]) (if (char=? c #\newline) 1 0))))
     (define col (- pos (let loop ([i (sub1 pos)]) (cond [(< i 0) -1] [(char=? (string-ref text i) #\newline) i] [else (loop (sub1 i))]))))
     (loc (and file (path-string file)) line col pos (- (cdar m) pos))]))

;; columns : ViewDefinition jsexpr (one `view` accepted) -> (listof string)   its column names, in order
(define (columns v) (map symbol->string (view-columns (read-view v))))
(define (ordered row cols) (for/hasheq ([c (in-list cols)]) (values (string->symbol c) (hash-ref row (string->symbol c) 'null))))

(define (run ws path text opts)
  (define v (view ws path text))
  (define cols (columns v))
  ;; what the view reads that the data's read left out is said with the rows (`unread`)
  (define-values (all unread) (with-unread v (version-name ws) (lambda () (view-rows v))))
  (define rows (map (lambda (r) (ordered r cols)) all))
  (define summary
    (hasheq 'rows (length rows) 'resource (hash-ref v 'resource "")
            'scanned (length ((data-source-all (current-data-source)) (hash-ref v 'resource "")))))
  (run-result "rows" cols rows (if (null? unread) summary (hash-set summary 'unread unread))))

(define (explain ws path text subject opts)
  (define v (view ws path text))
  (define type (hash-ref v 'resource ""))
  (define id (regexp-replace (pregexp (string-append "^" (regexp-quote type) "/")) subject ""))
  (define r (or ((data-source-read (current-data-source)) type id)
                (error 'sql-on-fhir (format "no ~a/~a in the data source" type id))))
  (define cols (columns v))
  (define wheres (hash-ref v 'where '()))
  (define bare (hash-remove v 'where))
  (hasheq 'resource (format "~a/~a" type id)
          'rows (map (lambda (x) (ordered x cols)) (view-rows v (list r)))
          'rowsWithoutWhere (length (view-rows bare (list r)))
          'where (for/list ([w (in-list wheres)])
                   (hasheq 'path (hash-ref w 'path "")
                           'holds (pair? (view-rows (hash-set bare 'where (list w)) (list r)))))))

(define workspace-support (ws-support "sql-on-fhir" artifacts run explain))

(module+ test
  (require rackunit (only-in fhir/data-source resources->data-source) (only-in fhir/diagnostic diagnostic-loc diagnostic-message diagnostic-severity loc-line loc-column))
  (define-values (ws _) (open-workspace (find-system-path 'temp-dir)))
  (define text (jsexpr->string
                (hasheq 'resourceType "ViewDefinition" 'name "active_patients" 'status "active" 'resource "Patient"
                        'where (list (hasheq 'path "active = true"))
                        'select (list (hasheq 'column (list (hasheq 'name "id" 'path "getResourceKey()")
                                                            (hasheq 'name "family" 'path "name.family.first()")))))))
  (define-values (rs ds) (artifacts ws (list (cons "/tmp/active.view.json" text) (cons "/tmp/bad.view.json" "{\"resource\": 3}"))))
  (check-equal? (hash-ref (car rs) 'url) "http://example.org/workspace/ViewDefinition/active")
  (check-equal? (length ds) 1)
  ;; a view that states no `status` is still an artifact, with a warning where it begins
  (let-values ([(rs ds) (artifacts ws (list (cons "/tmp/nostatus.view.json" "\n {\"resource\": \"Patient\", \"select\": [{\"column\": [{\"name\": \"id\", \"path\": \"id\"}]}]}")))])
    (check-equal? (length rs) 1)
    (check-equal? (map (lambda (d) (list (diagnostic-severity d) (loc-line (diagnostic-loc d)) (loc-column (diagnostic-loc d)) (diagnostic-message d))) ds)
                  '((warning 2 2 "no `status` (the standard requires it: \"draft\", \"active\", \"retired\" or \"unknown\")"))))
  (define data (list (hasheq 'resourceType "Patient" 'id "a" 'active #t 'name (list (hasheq 'family "Ng")))
                     (hasheq 'resourceType "Patient" 'id "b" 'active #f)))
  (parameterize ([current-data-source (resources->data-source data)])
    (define r (run ws #f text (hasheq)))
    (check-equal? (run-result-columns r) '("id" "family"))
    (check-equal? (run-result-rows r) (list (hasheq 'id "a" 'family "Ng")))
    (check-equal? (hash-ref (run-result-summary r) 'scanned) 2)
    (check-false (hash-has-key? (run-result-summary r) 'unread))
    ;; a value the view reads that the data's read left out is named with the rows
    (parameterize ([current-data-source (resources->data-source
                                         (list (hasheq 'resourceType "Patient" 'id "c" 'active #t 'name (list (hasheq 'family 7)))))])
      (define r (run ws #f text (hasheq)))
      (check-equal? (run-result-rows r) (list (hasheq 'id "c" 'family 'null)))
      (check-equal? (hash-ref (run-result-summary r) 'unread)
                    '("1 of 1 Patient resources holds a value at `name.family` that is not valid FHIR and was not read (the first: Patient/c: 7)")))
    (define e (explain ws #f text "Patient/b" (hasheq)))
    (check-equal? (hash-ref e 'rows) '())
    (check-equal? (hash-ref e 'rowsWithoutWhere) 1)
    (check-equal? (hash-ref (car (hash-ref e 'where)) 'holds) #f))
  ;; a path to an element the type does not have is an error at its string in the file (inside a
  ;; forEach, against the element it iterates); functions and getReferenceKey(T) are not
  (define typos (string-append
                 "{\"resource\": \"Patient\", \"status\": \"active\",\n"
                 " \"where\": [{\"path\": \"activ = true\"}],\n"
                 " \"select\": [{\"column\": [{\"name\": \"org\", \"path\": \"managingOrganization.getReferenceKey(Organization)\"}]},\n"
                 "  {\"forEach\": \"name\", \"column\": [{\"name\": \"f\", \"path\": \"famly\"}]}]}"))
  (define-values (_rs tds) (artifacts ws (list (cons "/tmp/typos.view.json" typos))))
  (check-equal? (sort (map (lambda (d) (list (loc-line (diagnostic-loc d)) (diagnostic-message d))) tds)
                      < #:key car)
                '((2 "no element Patient.activ (did you mean `active`?)")
                  (4 "no element HumanName.famly (did you mean `family`?)")))
  ;; a path that is not FHIRPath is the view's problem whatever the data (it ran, over no data, to an
  ;; empty table), at the path's string in the file; so is a column name used twice
  (define (problems text)
    (let-values ([(rs ds) (artifacts ws (list (cons "/tmp/v.view.json" text)))])
      (map (lambda (d) (list (diagnostic-severity d) (loc-line (diagnostic-loc d)) (loc-column (diagnostic-loc d)) (diagnostic-message d))) ds)))
  (check-equal? (problems "{\"resource\": \"Patient\", \"status\": \"active\",\n \"select\": [{\"column\": [{\"name\": \"id\", \"path\": \"id.\"}]}]}")
                '((error 2 48 "the path \"id.\" is not FHIRPath: the expression ends after `.`")))
  (check-equal? (problems "{\"resource\": \"Patient\", \"status\": \"active\", \"select\": [{\"column\": [{\"name\": \"id\", \"path\": \"id\"}, {\"name\": \"id\", \"path\": \"gender\"}]}]}")
                '((error #f #f "the column name `id` is used twice: the columns of a table are named apart")))
  ;; a view that names the FHIR versions it is for, read as another: a warning at `fhirVersion`
  (define for-r4 "{\"resource\": \"Patient\", \"status\": \"active\",\n \"fhirVersion\": [\"4.0\", \"4.3.0\"], \"select\": [{\"column\": [{\"name\": \"id\", \"path\": \"id\"}]}]}")
  (check-equal? (let ([d (version-problem "/tmp/v.view.json" for-r4 (string->jsexpr for-r4) "R6")])
                  (list (diagnostic-severity d) (loc-line (diagnostic-loc d)) (loc-column (diagnostic-loc d)) (diagnostic-message d)))
                '(warning 2 2 "the view is for FHIR 4.0, 4.3.0 (`fhirVersion`) and the data is read as FHIR R6"))
  (check-false (version-problem "/tmp/v.view.json" for-r4 (string->jsexpr for-r4) "R4"))
  (check-false (version-problem "/tmp/v.view.json" text (string->jsexpr text) "R4"))          ; it names none
  ;; among a workspace file's problems, against the version the workspace reads its data as
  (check-equal? (map cadddr (problems (regexp-replace #rx"\\[\"4.0\", \"4.3.0\"\\]" for-r4 (if (equal? (version-name ws) "R6") "[\"5.0\"]" "[\"6.0\"]"))))
                (list (format "the view is for FHIR ~a (`fhirVersion`) and the data is read as FHIR ~a"
                              (if (equal? (version-name ws) "R6") "5.0" "6.0") (version-name ws))))
  (check-equal? (problems (regexp-replace #rx"\\[\"4.0\", \"4.3.0\"\\]" for-r4 (format "[~s]" (ws-config-fhir-version (workspace-config ws))))) '())
  ;; R6's `resourceDefinition` beside `resourceType` (the IG's examples carry it) is no unknown element
  (parameterize ([current-data-source (resources->data-source data)])
    (check-equal? (run-result-columns
                   (run ws #f (jsexpr->string (hash-set (string->jsexpr text) 'resourceDefinition "http://hl7.org/fhir/StructureDefinition/ViewDefinition|3.0.0-ballot")) (hasheq)))
                  '("id" "family")))
  ;; a forEach over an element the type lacks is ONE problem, at the forEach: the columns inside it
  ;; are not each blamed for it
  (define each (string-append
                "{\"resource\": \"Patient\", \"status\": \"active\",\n"
                " \"select\": [{\"forEach\": \"nmae\",\n"
                "   \"column\": [{\"name\": \"f\", \"path\": \"family\"}, {\"name\": \"g\", \"path\": \"given.first()\"}]}]}"))
  (check-equal? (map (lambda (d) (list (loc-line (diagnostic-loc d)) (diagnostic-message d)))
                     (path-problems "/tmp/each.view.json" each (string->jsexpr each)))
                '((2 "no element Patient.nmae (did you mean `name`?)"))))

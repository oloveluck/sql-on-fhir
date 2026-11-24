#lang racket/base

;;; cli.rkt — `raco sql-on-fhir <command>`.
;;;
;;;   raco sql-on-fhir run <view.json | view.rkt> [<data>] [--format ndjson|json|csv|fhir] [--fhir-version 4.0.1|5.0.0|6.0.0]
;;;       run a ViewDefinition ($sql-run) over FHIR data: a directory of JSON files, a Bundle or a
;;;       resource; the view as source text (a .sof file: the first view it states), as JSON, or as
;;;       a #lang sql-on-fhir module. The data is read as FHIR R6 (the
;;;       version the view model is built over) unless --fhir-version names another; a path to an
;;;       element the resource type lacks in that version is a warning on stderr; so are a view that
;;;       states no `status`, and data the view reads that the read left out (an element that
;;;       version does not have, a value that is not valid FHIR), and a view that names the FHIR
;;;       versions it is for (`fhirVersion`) when the data is read as another.
;;;   raco sql-on-fhir compile <file.sof> [-o <dir>]
;;;       source text (LANGUAGE.md) to the ViewDefinitions it states, as FHIR JSON: on standard
;;;       output, or each in a file of <dir> named by the view
;;;   raco sql-on-fhir decompile <view.json>…
;;;       ViewDefinitions as the source text that states them
;;;   raco sql-on-fhir features [<table>] [--json]
;;;       everything the package does, as a list (features.rkt): a ViewDefinition's elements, what a
;;;       path may call, the two operations' parameters, what refuses a view, the commands, the
;;;       Racket API — each with what is done with it and the definition that does it
;;;   raco sql-on-fhir tck [-v]        the shared test suite (FHIR/sql-on-fhir.js tests, vendored)
;;;   raco sql-on-fhir regen | check   regenerate the model from spec/ | verify it is up to date
;;;   raco sql-on-fhir fetch [--version V] [--tests-commit SHA]
;;;       pull the IG package from the FHIR package registry and the test suite from GitHub

(require racket/list racket/file racket/port racket/string racket/runtime-path (for-syntax racket/base) json net/url net/base64
         fhir/subcommands fhir/operation fhir/data-source
         (only-in "features.rkt" command-usages features features-of tables table-area features->text features->jsexpr)
         (only-in fhir/serialize/to-json node->jsexpr)
         (only-in fhir/model/registry pin-registered-types!)
         (only-in fhir/diagnostic diagnostic-message diagnostic-loc loc-line loc-column
                  exn:fail:diagnostic? exn:fail:diagnostic-diagnostic)
         (only-in fhir/serialize/fhir-json fhir-json->string))

;; here : -> path   the package's source directory, where `fetch` writes the IG package and the test
;; suite. A development command's destination, not a file the tools read at run time, so it is not a
;; runtime path (a standalone build would otherwise try to carry the whole repository with it).
(define (here)
  (define src (variable-reference->module-source (#%variable-reference)))
  (unless (path? src) (raise-user-error 'sql-on-fhir "fetch works in a source checkout of sql-on-fhir"))
  (let-values ([(dir _name _dir?) (split-path src)]) dir))

;; usages : (listof (list command usage-line))   the commands, as features.rkt lists them (its rows
;; that are usage lines)
(define usages (command-usages))

(define (opt args name default)
  (let ([m (member name args)]) (if (and m (pair? (cdr m))) (cadr m) default)))
(define (positional args)
  (let loop ([as args])
    (cond [(null? as) '()]
          [(regexp-match? #rx"^--" (car as)) (loop (if (pair? (cdr as)) (cddr as) '()))]
          [else (cons (car as) (loop (cdr as)))])))

;; ---- run ----------------------------------------------------------------------------------------
;; The view model is built over R6, and a process holds one type per name (fhir/model/registry). To
;; read the data as another FHIR version, that version's tower is loaded FIRST and pinned: the view
;; model, loaded after it, adds ViewDefinition and replaces none of its types. So the engine (and a
;; view written as a module, which brings the model with it) is loaded by name once `run` knows the
;; version. The module-path indexes are what lets a standalone build carry these modules.
(define-runtime-module-path-index operations-module 'sql-on-fhir/operations)
(define-runtime-module-path-index workspace-module 'sql-on-fhir/workspace)
(define-runtime-module-path-index sof-module 'sql-on-fhir/sof)
(define-runtime-module-path-index compile-module 'sql-on-fhir/compile)
(define-runtime-module-path-index decompile-module 'sql-on-fhir/decompile)
(define-runtime-module-path-index r4-tower 'fhir/r4/schemas)
(define-runtime-module-path-index r5-tower 'fhir/r5/schemas)
;; fhir-versions : (listof (list --fhir-version-value name tower|#f))   #f: R6, the view model's own
(define fhir-versions (list (list "4.0.1" "R4" r4-tower) (list "5.0.0" "R5" r5-tower) (list "6.0.0" "R6" #f)))
(define default-fhir-version "6.0.0")

;; load-tower! : module-path-index | #f -> void   the data's tower, kept against the view model's
(define (load-tower! tower)
  (when tower
    (dynamic-require tower #f)
    (pin-registered-types!)))

;; fail : format-string value … -> exits 1   one problem with the input, on stderr
(define (fail fmt . args)
  (eprintf "sql-on-fhir: ~a\n" (apply format fmt args))
  (exit 1))

;; read-view : path -> (values ViewDefinition-jsexpr loc|#f)   the view a file holds, and, for source
;; text, where its statement begins: a `#lang sql-on-fhir` module (whatever its extension: `.rkt`,
;; `.sof`) by its first view; source text (LANGUAGE.md) by its first statement; else the file as
;; JSON. A module that does not compile or run, text that does not compile and unreadable JSON are
;; each the error's own message, exit 1.
(define (read-view f)
  (cond
    [(module-file? f)
     (define rs (with-handlers ([exn:fail? (lambda (e) (fail "~a" (module-error-text f e)))])
                  (dynamic-require (path->complete-path f) 'resources
                                   (lambda () (fail "~a is not a #lang sql-on-fhir module (it provides no views)" f)))))
     (define views (if (list? rs) rs (list rs)))
     (when (null? views) (fail "~a defines no ViewDefinition" f))
     (values (node->jsexpr (car views)) #f)]
    [((dynamic-require sof-module 'source-text?) (file->string f))
     (define views (source-views f))
     (when (null? views) (fail "~a states no view" f))
     (values ((dynamic-require compile-module 'compiled-view) (car views))
             ((dynamic-require compile-module 'compiled-loc) (car views)))]
    [else
     (values (with-handlers ([exn:fail:read? (lambda (e) (fail "~a is not JSON: ~a" f (exn-message e)))])
               (call-with-input-file f read-json))
             #f)]))
;; source-views : path -> (listof Compiled)   a file of source text as its views, each held to what a
;; ViewDefinition is (sof.rkt); a problem is `file:line:col: message`, exit 1
(define (source-views f) (source-views* f (file->string f)))
;; module-file? : path -> boolean   a `.rkt` file, or one that starts with a #lang line
(define (module-file? f)
  (or (regexp-match? #rx"[.]rkt$" f)
      (regexp-match? #px"^\\s*#lang " (call-with-input-file f (lambda (in) (or (read-string 64 in) ""))))))
;; module-error-text : path exn -> string   what went wrong in a view module, as its own message:
;; `file:line:col: message` when the error is positioned in the file (a read error is), else
;; `file: message`. A position elsewhere (the form macros' own source) is dropped: it is not the
;; user's. Racket's `context...` lines are never part of the message.
(define (module-error-text f e)
  (define locs (if (exn:srclocs? e) ((exn:srclocs-accessor e) e) '()))
  (define here (simplify-path (path->complete-path f)))
  (define in-file?
    (for/or ([l (in-list locs)])
      (let ([src (srcloc-source l)])
        (and (or (path? src) (string? src)) (equal? (simplify-path (path->complete-path src)) here)))))
  (define positioned (and (pair? locs) (regexp-match #px"^[^\n]*?:([0-9]+):([0-9]+): (.*)$" (exn-message e))))
  (cond [(and positioned in-file?) (format "~a:~a:~a: ~a" f (cadr positioned) (caddr positioned) (cadddr positioned))]
        [positioned (format "~a: ~a" f (cadddr positioned))]
        [else (format "~a: ~a" f (exn-message e))]))

(define (read-data f)
  (cond [(not f) empty-data-source]
        [(directory-exists? f) (directory->data-source f)]
        [else (resources->data-source (list (call-with-input-file f read-json)))]))

;; A Warning is (cons message line): a static problem's own message, and the line the terminal shows.
;; located : path diagnostic [suffix] -> Warning   `file:line:col: message` and what the command adds
(define (located f d [suffix ""])
  (define l (diagnostic-loc d))
  (cons (diagnostic-message d)
        (format "~a~a: ~a~a" f (if (and l (loc-line l)) (format ":~a:~a" (loc-line l) (loc-column l)) "") (diagnostic-message d) suffix)))

;; path-warnings : path text ViewDefinition version-name -> (listof Warning)
;; every column, forEach and where path that names an element the view's resource type does not have
;; in the FHIR version the data is read as (the workspace support's static check), each at its place
;; in the file. Such a path gives no value, or fails once a resource is read: without this, a view
;; over no data, or a forEach over such an element, printed an empty table and said nothing.
;; The check is advice: a view it cannot follow is left to the run.
(define (path-warnings f text view version-name)
  (define path-problems (dynamic-require workspace-module 'path-problems))
  (for/list ([d (in-list (with-handlers ([exn:fail? (lambda (_) '())]) (path-problems f text view)))])
    (located f d (format " (the data is read as FHIR ~a~a)" version-name
                         (if (equal? version-name "R6") "; --fhir-version 4.0.1 reads it as R4" "")))))

;; status-warnings : path text ViewDefinition loc|#f -> (listof Warning)   a view that states no
;; `status`: the standard requires one, and the view runs all the same (the shared suite's own views
;; do). For source text it is said where the statement begins, with how to write it.
(define (status-warnings f text view at)
  (define d ((dynamic-require workspace-module 'status-problem) f text view))
  (cond [(not d) '()]
        [at (list (cons (diagnostic-message d)
                        (format "~a:~a:~a: ~a: CREATE VIEW <name> WITH (status = 'active') AS …" f (loc-line at) (loc-column at) (diagnostic-message d))))]
        [else (list (located f d))]))

;; version-warnings : path text ViewDefinition version-name -> (listof Warning)   a view that names
;; the FHIR versions it is for (`fhirVersion`), read as another; with the option that reads the data
;; as one of them, when there is one
(define (version-warnings f text view version-name)
  (define version-problem (dynamic-require workspace-module 'version-problem))
  (define d (version-problem f text view version-name))
  (define fitting (for/first ([v (in-list fhir-versions)] #:unless (version-problem f text view (cadr v))) v))
  (if d
      (list (located f d (if fitting (format "; --fhir-version ~a reads it as ~a" (car fitting) (cadr fitting)) "")))
      '()))

;; unread-warnings : (listof string) (listof Warning) ViewDefinition -> (listof Warning)
;; what the view reads that the data's read left out (workspace.rkt's `with-unread`), without the
;; elements a path warning has already named as missing from the version read
(define (unread-warnings notes path-warnings view)
  (for/list ([n (in-list notes)]
             #:unless (for/or ([w (in-list path-warnings)])
                        (let ([m (regexp-match #rx"^no element ([A-Za-z0-9]+)[.]([A-Za-z0-9_]+)" (car w))])
                          (and m (equal? (cadr m) (hash-ref view 'resource #f))
                               (regexp-match? (regexp (string-append "`" (regexp-quote (caddr m)) "[.`]")) n)))))
    (cons n n)))

(define (cmd-run args)
  (define ps (positional args))
  (when (null? ps) (usage-error "sql-on-fhir" usages "run"))
  (require-files! "sql-on-fhir" usages "run" (list (car ps)))
  (define version
    (or (assoc (opt args "--fhir-version" default-fhir-version) fhir-versions)
        (usage-error "sql-on-fhir" usages "run"
                     (format "--fhir-version takes 4.0.1, 5.0.0 or 6.0.0 (got ~a)" (opt args "--fhir-version" #f)))))
  (load-tower! (caddr version))
  (define $sql-run (dynamic-require operations-module '$sql-run))
  (define-values (view statement) (read-view (car ps)))
  (define text (file->string (car ps)))
  (define with-unread (dynamic-require workspace-module 'with-unread))
  (define paths (path-warnings (car ps) text view (cadr version)))
  (define warnings (append (if (module-file? (car ps)) '() (status-warnings (car ps) text view statement))
                           (version-warnings (car ps) text view (cadr version))
                           paths))
  (define (warn! ws) (for ([w (in-list ws)]) (eprintf "sql-on-fhir: warning: ~a\n" (cdr w))))
  (define-values (result unread)
    (parameterize ([current-data-source (read-data (and (pair? (cdr ps)) (cadr ps)))])
     (with-unread view (cadr version) (lambda ()
      (with-handlers ([exn:fail:operation?
                       (lambda (e)
                         ;; a failure the static check foresaw is said once, at its place in the file
                         (define-values (foreseen others)
                           (partition (lambda (w) (string-contains? (exn-message e) (car w))) warnings))
                         (warn! others)
                         (when (null? foreseen) (fail "~a" (exn-message e)))
                         (for ([w (in-list foreseen)]) (eprintf "sql-on-fhir: ~a\n" (cdr w)))
                         (exit 1))])
        ($sql-run view #:_format (opt args "--format" "ndjson")))))))
  (warn! (append warnings (unread-warnings unread paths view)))
  (if (equal? (hash-ref result 'resourceType) "Binary")
      (void (write-bytes (base64-decode (string->bytes/utf-8 (hash-ref result 'data)))))
      (displayln (jsexpr->string result))))

;; ---- compile, decompile -------------------------------------------------------------------------
;; cmd-compile : args -> void   a file of source text as the ViewDefinitions it states: FHIR JSON on
;; standard output, one view after another; with -o <dir>, each written to <dir>/<name>.view.json
;; (the view's name, else the file's with the statement's number)
(define (cmd-compile args)
  (define ps (positional (let ([m (member "-o" args)]) (if (and m (pair? (cdr m))) (append (takef args (lambda (a) (not (equal? a "-o")))) (cddr m)) args))))
  (when (null? ps) (usage-error "sql-on-fhir" usages "compile"))
  (require-files! "sql-on-fhir" usages "compile" ps)
  (define out (opt args "-o" #f))
  (define compiled-view (dynamic-require compile-module 'compiled-view))
  (for ([f (in-list ps)])
    (define views
      (if (module-file? f)
          (map node->jsexpr
               (with-handlers ([exn:fail? (lambda (e) (fail "~a" (module-error-text f e)))])
                 (dynamic-require (path->complete-path f) 'resources
                                  (lambda () (fail "~a is not a #lang sql-on-fhir module (it provides no views)" f)))))
          (map compiled-view (source-views f))))
    (define stem (regexp-replace #rx"[.][^.]*$" (let-values ([(_d name _?) (split-path f)]) (path->string name)) ""))
    (for ([v (in-list views)] [i (in-naturals 1)])
      (define json (fhir-json->string v #:indent 2))
      (cond [out
             (make-directory* out)
             (define name (format "~a.view.json" (or (hash-ref v 'name #f) (if (= (length views) 1) stem (format "~a-~a" stem i)))))
             (call-with-output-file (build-path out name) #:exists 'truncate (lambda (o) (write-string json o) (newline o)))
             (printf "~a\n" (path->string (build-path out name)))]
            [else (displayln json)]))))
;; source-views* : path text -> (listof Compiled)
(define (source-views* f text)
  (with-handlers ([exn:fail:diagnostic?
                   (lambda (e)
                     (define d (exn:fail:diagnostic-diagnostic e))
                     (define l (diagnostic-loc d))
                     (fail "~a~a: ~a" f (if (and l (loc-line l)) (format ":~a:~a" (loc-line l) (loc-column l)) "") (diagnostic-message d)))])
    ((dynamic-require sof-module 'read-sof) text f)))

;; cmd-decompile : args -> void   ViewDefinitions (JSON files) as the source text that states them;
;; several are one text, each statement ended by `;`
(define (cmd-decompile args)
  (define ps (positional args))
  (when (null? ps) (usage-error "sql-on-fhir" usages "decompile"))
  (require-files! "sql-on-fhir" usages "decompile" ps)
  (define unwritable? (dynamic-require decompile-module 'exn:fail:unwritable?))
  (define views
    (for/list ([f (in-list ps)])
      (define v (with-handlers ([exn:fail:read? (lambda (e) (fail "~a is not JSON: ~a" f (exn-message e)))])
                  (call-with-input-file f read-json)))
      (unless (hash? v) (fail "~a holds no ViewDefinition" f))
      (cons f v)))
  (define (text-of f v)
    (with-handlers ([unwritable? (lambda (e) (fail "~a ~a" f (exn-message e)))])
      ((dynamic-require decompile-module 'view->sof) v)))
  (if (= (length views) 1)
      (displayln (text-of (caar views) (cdar views)))
      (for ([fv (in-list views)]) (printf "~a;\n\n" (text-of (car fv) (cdr fv))))))

;; ---- features -----------------------------------------------------------------------------------
;; cmd-features : args -> void   the feature list (features.rkt), or one of its tables by name; as
;; text, or with --json as a list of objects
(define (cmd-features args)
  (define names (filter (lambda (a) (not (regexp-match? #rx"^--" a))) args))
  (define areas (map (lambda (t) (symbol->string (table-area t))) tables))
  (for ([n (in-list names)] #:unless (member n areas))
    (usage-error "sql-on-fhir" usages "features" (format "no table ~a: the tables are ~a" n (string-join areas ", "))))
  (define rows (if (null? names) features (append-map (lambda (n) (features-of (string->symbol n))) names)))
  (if (member "--json" args)
      (displayln (jsexpr->string (features->jsexpr rows)))
      (display (features->text rows))))

;; ---- the shared suite ---------------------------------------------------------------------------
;; cmd-tck : args -> void   tests/run.rkt's report, against its floor
(define (cmd-tck args)
  (parameterize ([current-command-line-arguments (list->vector args)])
    (dynamic-require '(submod sql-on-fhir/tests/run main) #f)))

;; ---- codegen ------------------------------------------------------------------------------------
(define (target) (dynamic-require 'sql-on-fhir/target 'target-sql-on-fhir))
(define (cmd-regen _) ((dynamic-require 'fhir/codegen/gen 'generate-tower) (target)))
(define (cmd-check _)
  (define drift ((dynamic-require 'fhir/codegen/check 'check-tower) (target)))
  (cond [(null? drift) (printf "check: the model is up to date with spec/.\n")]
        [else (eprintf "check: ~a generated file(s) differ — run `raco sql-on-fhir regen`:\n" (length drift))
              (for ([f (in-list drift)]) (eprintf "  ~a\n" f))
              (exit 1)]))

;; ---- fetch --------------------------------------------------------------------------------------
;; the IG package from the registry (published from HL7's FHIR/sql-on-fhir-v2), the shared tests from
;; FHIR/sql-on-fhir.js at a commit or branch (default: main)
(define (download url)
  (call/input-url (string->url url) (lambda (u) (get-pure-port u #:redirections 5)) port->bytes))
(define (cmd-fetch args)
  (define version (opt args "--version" "3.0.0-ballot"))
  (define commit (opt args "--tests-commit" "main"))
  (define pkg (download (format "https://packages2.fhir.org/packages/hl7.fhir.uv.sql-on-fhir/~a" version)))
  (call-with-output-file (build-path (here) "spec" "hl7.fhir.uv.sql-on-fhir.tgz") #:exists 'truncate
    (lambda (o) (write-bytes pkg o)))
  (printf "spec/hl7.fhir.uv.sql-on-fhir.tgz: hl7.fhir.uv.sql-on-fhir#~a (~a bytes) — update spec/SOURCE.txt, then raco sql-on-fhir regen\n"
          version (bytes-length pkg))
  ;; the tests directory, file by file, through the GitHub contents API
  (define listing (bytes->jsexpr (download (format "https://api.github.com/repos/FHIR/sql-on-fhir.js/contents/tests?ref=~a" commit))))
  (define dest (build-path (here) "tests" "vendor" "sql-on-fhir-tests"))
  (define n
    (for/sum ([f (in-list listing)] #:when (regexp-match? #rx"[.]json$" (hash-ref f 'name "")))
      (call-with-output-file (build-path dest (hash-ref f 'name)) #:exists 'truncate
        (lambda (o) (write-bytes (download (hash-ref f 'download_url)) o)))
      1))
  (printf "tests/vendor/sql-on-fhir-tests: ~a files from FHIR/sql-on-fhir.js@~a — update its SOURCE.txt, then raco sql-on-fhir tck\n" n commit))

;; handlers : (hash command -> (args -> any))   one to a command of `usages`
(define handlers
  (hash "run" cmd-run "compile" cmd-compile "decompile" cmd-decompile "features" cmd-features "tck" cmd-tck
        "regen" cmd-regen "check" cmd-check "fetch" cmd-fetch))

(module+ test
  (require rackunit (only-in "features.rkt" feature-names feature-state))
  ;; every command features.rkt lists has its handler, and there is no other
  (check-equal? (sort (map car usages) string<?) (sort (hash-keys handlers) string<?))
  ;; the options `run` takes are the ones its rows say: the FHIR versions there is a tower for, and
  ;; the formats $sql-run writes
  (define (option-values name)
    (for*/first ([f (in-list (features-of 'run))] [n (in-list (feature-names f))]
                 [m (in-value (regexp-match (pregexp (string-append "^" name " (.*)$")) n))] #:when m)
      (string-split (cadr m) "|")))
  (check-equal? (option-values "--fhir-version") (map car fhir-versions))
  (check-equal? (sort (option-values "--format") string<?)
                (sort (for*/list ([f (in-list (features-of 'sql-run))] #:when (eq? (feature-state f) 'yes)
                                  [n (in-list (feature-names f))] [m (in-value (regexp-match #rx"^_format=(.*)$" n))] #:when m)
                        (cadr m))
                      string<?))
  (for ([o (in-list '("--format ndjson|json|csv|fhir" "--fhir-version 4.0.1|5.0.0|6.0.0"))])
    (check-true (string-contains? (cadr (assoc "run" usages)) (string-append "[" o "]")) o))
  ;; `features`: every table, one table, as JSON; a table there is not is a usage error
  (define (printed . args) (let ([o (open-output-string)]) (parameterize ([current-output-port o]) (cmd-features args)) (get-output-string o)))
  (check-equal? (printed) (features->text features))
  (check-equal? (printed "path") (features->text (features-of 'path)))
  (check-equal? (string->jsexpr (printed "path" "--json")) (features->jsexpr (features-of 'path)))
  ;; (tests/cli-test.rkt runs the command itself, in a process of its own)
  (define (positioned-exn msg source)
    (exn:fail:read msg (current-continuation-marks) (list (srcloc source 2 0 19 1))))
  ;; an error positioned in the view's file keeps its position; one positioned elsewhere loses it
  (define here-file (path->complete-path "v.sof"))
  (check-equal? (module-error-text "v.sof" (positioned-exn "v.sof:2:0: read-syntax: expected a `)`" here-file))
                "v.sof:2:0: read-syntax: expected a `)`")
  (check-equal? (module-error-text "v.sof" (positioned-exn "/x/kit.rkt:23:25: ViewDefinition: missing required field\n  in: (ViewDefinition)"
                                                           (string->path "/x/kit.rkt")))
                "v.sof: ViewDefinition: missing required field\n  in: (ViewDefinition)")
  (check-equal? (module-error-text "v.sof" (exn:fail "car: contract violation at 12:30:45: x" (current-continuation-marks)))
                "v.sof: car: contract violation at 12:30:45: x")
  ;; options take a value and are no positional argument
  (check-equal? (positional '("v.json" "--fhir-version" "4.0.1" "data" "--format" "csv")) '("v.json" "data"))
  (check-equal? (map car fhir-versions) '("4.0.1" "5.0.0" "6.0.0"))
  (check-true (and (assoc default-fhir-version fhir-versions) #t)))

(module+ main
  (run-subcommands
   "sql-on-fhir" usages
   handlers
   (vector->list (current-command-line-arguments))))

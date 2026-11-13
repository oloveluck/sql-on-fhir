#lang racket/base

;;; cli.rkt — `raco sql-on-fhir <command>`.
;;;
;;;   raco sql-on-fhir run <view.json | view.rkt> [<data>] [--format ndjson|json|csv|fhir] [--fhir-version 4.0.1|5.0.0|6.0.0]
;;;       run a ViewDefinition ($sql-run) over FHIR data: a directory of JSON files, a Bundle or a
;;;       resource; the view as JSON or a #lang sql-on-fhir module. The data is read as FHIR R6 (the
;;;       version the view model is built over) unless --fhir-version names another; a path to an
;;;       element the resource type lacks in that version is a warning on stderr; so are a view that
;;;       states no `status`, and data the view reads that the read left out (an element that
;;;       version does not have, a value that is not valid FHIR).
;;;   raco sql-on-fhir tck [-v]        the shared test suite (FHIR/sql-on-fhir.js tests, vendored)
;;;   raco sql-on-fhir regen | check   regenerate the model from spec/ | verify it is up to date
;;;   raco sql-on-fhir fetch [--version V] [--tests-commit SHA]
;;;       pull the IG package from the FHIR package registry and the test suite from GitHub

(require racket/list racket/file racket/port racket/string racket/runtime-path (for-syntax racket/base) json net/url net/base64
         fhir/subcommands fhir/operation fhir/data-source
         (only-in fhir/serialize/to-json node->jsexpr)
         (only-in fhir/model/registry pin-registered-types!)
         (only-in fhir/diagnostic diagnostic-message diagnostic-loc loc-line loc-column))

;; here : -> path   the package's source directory, where `fetch` writes the IG package and the test
;; suite. A development command's destination, not a file the tools read at run time, so it is not a
;; runtime path (a standalone build would otherwise try to carry the whole repository with it).
(define (here)
  (define src (variable-reference->module-source (#%variable-reference)))
  (unless (path? src) (raise-user-error 'sql-on-fhir "fetch works in a source checkout of sql-on-fhir"))
  (let-values ([(dir _name _dir?) (split-path src)]) dir))

(define usages
  '(("run"   "raco sql-on-fhir run <view.json | view.rkt> [<data dir | bundle.json | resource.json>] [--format ndjson|json|csv|fhir] [--fhir-version 4.0.1|5.0.0|6.0.0]")
    ("tck"   "raco sql-on-fhir tck [-v]")
    ("regen" "raco sql-on-fhir regen")
    ("check" "raco sql-on-fhir check")
    ("fetch" "raco sql-on-fhir fetch [--version 3.0.0-ballot] [--tests-commit <sha>]")))

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

;; read-view : path -> ViewDefinition jsexpr   a `#lang sql-on-fhir` module (whatever its extension:
;; `.rkt`, `.sof`) by its first view, else the file as JSON; a module that does not compile or run
;; and unreadable JSON are each the error's own message, exit 1
(define (read-view f)
  (cond
    [(module-file? f)
     (define rs (with-handlers ([exn:fail? (lambda (e) (fail "~a" (module-error-text f e)))])
                  (dynamic-require (path->complete-path f) 'resources
                                   (lambda () (fail "~a is not a #lang sql-on-fhir module (it provides no views)" f)))))
     (define views (if (list? rs) rs (list rs)))
     (when (null? views) (fail "~a defines no ViewDefinition" f))
     (node->jsexpr (car views))]
    [else
     (with-handlers ([exn:fail:read? (lambda (e) (fail "~a is not JSON: ~a" f (exn-message e)))])
       (call-with-input-file f read-json))]))
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
  (define in-file?
    (for/or ([l (in-list locs)])
      (let ([src (srcloc-source l)])
        (and (path? src) (equal? (simplify-path src) (simplify-path (path->complete-path f)))))))
  (define positioned (and (pair? locs) (regexp-match #px"^[^\n]*?:[0-9]+:[0-9]+: (.*)$" (exn-message e))))
  (cond [(and positioned in-file?) (exn-message e)]
        [positioned (format "~a: ~a" f (cadr positioned))]
        [else (format "~a: ~a" f (exn-message e))]))

(define (read-data f)
  (cond [(not f) empty-data-source]
        [(directory-exists? f) (directory->data-source f)]
        [else (resources->data-source (list (call-with-input-file f read-json)))]))

;; A Warning is (cons message line): a static problem's own message, and the line the terminal shows.
;; path-warnings : path ViewDefinition version-name -> (listof Warning)
;; every column, forEach and where path that names an element the view's resource type does not have
;; in the FHIR version the data is read as (the workspace support's static check), each at its place
;; in the file. Such a path gives no value, or fails once a resource is read: without this, a view
;; over no data, or a forEach over such an element, printed an empty table and said nothing.
;; The check is advice: a view it cannot follow is left to the run.
(define (path-warnings f view version-name)
  (define path-problems (dynamic-require workspace-module 'path-problems))
  (for/list ([d (in-list (with-handlers ([exn:fail? (lambda (_) '())]) (path-problems f (file->string f) view)))])
    (define l (diagnostic-loc d))
    (cons (diagnostic-message d)
          (format "~a~a: ~a (the data is read as FHIR ~a~a)"
                  f (if (and l (loc-line l)) (format ":~a:~a" (loc-line l) (loc-column l)) "")
                  (diagnostic-message d) version-name
                  (if (equal? version-name "R6") "; --fhir-version 4.0.1 reads it as R4" "")))))

;; status-warnings : path ViewDefinition -> (listof Warning)   a JSON view that states no `status`:
;; the standard requires one, and the view runs all the same (the shared suite's own views do)
(define (status-warnings f view)
  (define d ((dynamic-require workspace-module 'status-problem) f (file->string f) view))
  (define l (and d (diagnostic-loc d)))
  (if d
      (list (cons (diagnostic-message d)
                  (format "~a~a: ~a" f (if (and l (loc-line l)) (format ":~a:~a" (loc-line l) (loc-column l)) "")
                          (diagnostic-message d))))
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
  (define view (read-view (car ps)))
  (define with-unread (dynamic-require workspace-module 'with-unread))
  (define paths (path-warnings (car ps) view (cadr version)))
  (define warnings (append (if (module-file? (car ps)) '() (status-warnings (car ps) view)) paths))
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

(module+ test
  (require rackunit)
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
   (hash "run" cmd-run
         "tck" (lambda (args)
                 (parameterize ([current-command-line-arguments (list->vector args)])
                   (dynamic-require '(submod sql-on-fhir/tests/run main) #f)))
         "regen" cmd-regen "check" cmd-check "fetch" cmd-fetch)
   (vector->list (current-command-line-arguments))))

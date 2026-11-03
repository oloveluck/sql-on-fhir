#lang racket/base

;;; cli.rkt — `raco sql-on-fhir <command>`.
;;;
;;;   raco sql-on-fhir run <view.json | view.rkt> [<data>] [--format ndjson|json|csv|fhir]
;;;       run a ViewDefinition ($sql-run) over FHIR data: a directory of JSON files, a Bundle or a
;;;       resource; the view as JSON or a #lang sql-on-fhir module
;;;   raco sql-on-fhir tck [-v]        the shared test suite (FHIR/sql-on-fhir.js tests, vendored)
;;;   raco sql-on-fhir regen | check   regenerate the model from spec/ | verify it is up to date
;;;   raco sql-on-fhir fetch [--version V] [--tests-commit SHA]
;;;       pull the IG package from the FHIR package registry and the test suite from GitHub

(require racket/list racket/file racket/port racket/runtime-path json net/url net/base64
         fhir/subcommands fhir/operation fhir/data-source
         (only-in fhir/serialize/to-json node->jsexpr)
         (only-in sql-on-fhir/operations $sql-run))

(define-runtime-path here ".")

(define usages
  '(("run"   "raco sql-on-fhir run <view.json | view.rkt> [<data dir | bundle.json | resource.json>] [--format ndjson|json|csv|fhir]")
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
(define (read-view f)
  (if (regexp-match? #rx"[.]rkt$" f)
      (let ([rs (dynamic-require (path->complete-path f) 'resources)])
        (node->jsexpr (if (list? rs) (car rs) rs)))
      (call-with-input-file f read-json)))
(define (read-data f)
  (cond [(not f) empty-data-source]
        [(directory-exists? f) (directory->data-source f)]
        [else (resources->data-source (list (call-with-input-file f read-json)))]))
(define (cmd-run args)
  (define ps (positional args))
  (when (null? ps) (usage-error "sql-on-fhir" usages "run"))
  (require-files! "sql-on-fhir" usages "run" (list (car ps)))
  (define result
    (parameterize ([current-data-source (read-data (and (pair? (cdr ps)) (cadr ps)))])
      (with-handlers ([exn:fail:operation? (lambda (e) (eprintf "sql-on-fhir: ~a\n" (exn-message e)) (exit 1))])
        ($sql-run (read-view (car ps)) #:_format (opt args "--format" "ndjson")))))
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
  (call-with-output-file (build-path here "spec" "hl7.fhir.uv.sql-on-fhir.tgz") #:exists 'truncate
    (lambda (o) (write-bytes pkg o)))
  (printf "spec/hl7.fhir.uv.sql-on-fhir.tgz: hl7.fhir.uv.sql-on-fhir#~a (~a bytes) — update spec/SOURCE.txt, then raco sql-on-fhir regen\n"
          version (bytes-length pkg))
  ;; the tests directory, file by file, through the GitHub contents API
  (define listing (bytes->jsexpr (download (format "https://api.github.com/repos/FHIR/sql-on-fhir.js/contents/tests?ref=~a" commit))))
  (define dest (build-path here "tests" "vendor" "sql-on-fhir-tests"))
  (define n
    (for/sum ([f (in-list listing)] #:when (regexp-match? #rx"[.]json$" (hash-ref f 'name "")))
      (call-with-output-file (build-path dest (hash-ref f 'name)) #:exists 'truncate
        (lambda (o) (write-bytes (download (hash-ref f 'download_url)) o)))
      1))
  (printf "tests/vendor/sql-on-fhir-tests: ~a files from FHIR/sql-on-fhir.js@~a — update its SOURCE.txt, then raco sql-on-fhir tck\n" n commit))

(module+ main
  (run-subcommands
   "sql-on-fhir" usages
   (hash "run" cmd-run
         "tck" (lambda (args)
                 (parameterize ([current-command-line-arguments (list->vector args)])
                   (dynamic-require '(submod sql-on-fhir/tests/run main) #f)))
         "regen" cmd-regen "check" cmd-check "fetch" cmd-fetch)
   (vector->list (current-command-line-arguments))))

#lang racket/base

;;; docs-test.rkt — the manual (scribblings/sql-on-fhir.scrbl) builds: it reads, expands and renders, and no
;;; cross-reference to this package's own definitions is broken. (Rendered alone, without the
;;; installation's documentation index, links into Racket's own manuals are unresolved; those are
;;; not counted.) A manual that failed to read went unnoticed once; this is the guard.

(require rackunit racket/runtime-path racket/file racket/port racket/string
         (only-in scribble/render render)
         (only-in scribble/html-render render-mixin))

(define-runtime-path manual "../scribblings/sql-on-fhir.scrbl")

(test-case "the manual renders, with every cross-reference to sql-on-fhir resolved"
  (define dest (make-temporary-directory))
  (define warnings
    (with-output-to-string
      (lambda ()
        (parameterize ([current-error-port (current-output-port)])
          (render (list (dynamic-require manual 'doc)) (list "sql-on-fhir") #:dest-dir dest #:render-mixin render-mixin
                  #:warn-undefined? #t)))))
  (check-true (file-exists? (build-path dest "sql-on-fhir.html")))
  ;; each undefined tag is a line " (kind tag)": this manual's own are its sections (a plain tag) and
  ;; sql-on-fhir's bindings; the rest point into Racket's manuals, unresolved only because this one is
  ;; rendered alone
  (define (own? l) (or (regexp-match? #px"^ \\(part \"" l) (regexp-match? #px"^ \\(dep \\(\\(lib \"sql-on-fhir/" l)))
  (define own (filter own? (string-split warnings "\n")))
  (check-equal? own '() (format "broken references in the manual:\n~a" (string-join own "\n")))
  (delete-directory/files dest))

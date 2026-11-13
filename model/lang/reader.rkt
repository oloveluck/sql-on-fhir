#lang s-exp syntax/module-reader

;;; GENERATED — reader: wrap each top form as (fhir-resource-form <form>); the module
;;; language sql-on-fhir/model/main (via fhir/kernel/kit) builds it to a typed node. Forms are read as
;;; syntax, so a mistake in one is reported at its place in the file.

sql-on-fhir/model/main
#:read        lang-read
#:read-syntax lang-read-syntax
#:whole-body-readers? #t

(define (lang-read-syntax src in)
  (let loop ([acc '()])
    (define form (read-syntax src in))
    (if (eof-object? form)
        (reverse acc)
        (loop (cons (datum->syntax #f (list 'fhir-resource-form form) form) acc)))))

(define (lang-read in)
  (map syntax->datum (lang-read-syntax #f in)))

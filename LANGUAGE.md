# The SQL on FHIR source language

This document defines the text form of a SQL on FHIR view that this package reads: a small SQL
dialect whose expressions are FHIRPath, kept in `.sof` files.

**What it is for.** The SQL on FHIR standard defines a view as a FHIR resource, a *ViewDefinition*,
written as JSON. That JSON is what the standard's tools exchange and what this package's engine
runs. It is a tree of objects and lists, and nobody would choose to write one by hand. The source
language is the form a person or an agent writes; the ViewDefinition is the intermediate form it
compiles to.

```
patients.sof  --compile-->  ViewDefinition (JSON)  --run-->  rows
              <-decompile--
```

**Its standing.** The language is this package's own. The standard has no text form, and nothing
here changes what a ViewDefinition is or means: a statement means exactly the ViewDefinition it
compiles to, and that resource is held to the standard's definition of one. This document is the
definition of the language: the grammar in section 4 is the grammar the parser is built from, and
every example below is compiled by the package's tests and compared with the JSON beside it
(section 10 says how the document is held).

Language version 1 (2026-11-24). It compiles to ViewDefinitions of SQL on FHIR 3.0.0-ballot.

## 1. An example

```sof
-- one row for each way of reaching a patient; a patient with none keeps one row
CREATE VIEW patient_contacts
  WITH (status = 'active', title = 'How to reach each patient')
AS
SELECT
  getResourceKey() AS patient_id,
  name.where(use = 'official').family.first() AS family,
  (SELECT system, value FROM telecom OR NULL)
FROM Patient
WHERE active = true
```

It reads as SQL does: the columns, where the rows come from, which of them to keep. Each column is
a FHIRPath expression over a Patient, with the name it has in the table after `AS`; a column that
is just an element (`system`) is named by it. The parenthesised `SELECT` makes a row for each
`telecom` of the patient. The statement compiles to this ViewDefinition:

```json
{"resourceType": "ViewDefinition",
 "name": "patient_contacts",
 "status": "active",
 "title": "How to reach each patient",
 "resource": "Patient",
 "select": [{"column": [{"name": "patient_id", "path": "getResourceKey()"},
                        {"name": "family", "path": "name.where(use = 'official').family.first()"}]},
            {"forEachOrNull": "telecom",
             "column": [{"name": "system", "path": "system"}, {"name": "value", "path": "value"}]}],
 "where": [{"path": "active = true"}]}
```

## 2. Three rules

Everything else in this document follows from three rules.

1. **Keywords are written in capitals.** `SELECT`, `FROM`, `AS`, `WHERE` and the other words of
   section 3.2 are the language's only when written so. FHIRPath's own words are lower case (`as`,
   `and`, `or`, `is`, `in`, `where`), so the two never meet: in `value as Quantity AS quantity` the
   first `as` is FHIRPath's type operator and the second names the column.
2. **Between the keywords stands FHIRPath, as it is.** A path is not parsed into anything else and
   has no syntax of this language inside it: what is written is what the ViewDefinition's `path`,
   `forEach` or `where` holds (section 6).
3. **The text and the resource say the same thing, both ways.** Each statement compiles to exactly
   one ViewDefinition; a ViewDefinition decompiles to exactly one text; and compiling that text
   gives the ViewDefinition back, element for element (section 7).

## 3. Lexical structure

A source text is a sequence of characters (in a file, UTF-8). It is read as the tokens below; white
space separates tokens and is otherwise without meaning, except inside a path (section 6).

### 3.1 Comments

`--` and `//` begin a comment that ends with the line. `/*` begins a comment that ends at the next
`*/`. A comment may stand wherever white space may, and counts as white space.

### 3.2 Keywords

```
CREATE VIEW WITH AS DECLARE SELECT FROM REPEAT OR NULL UNION ALL WHERE AND TYPE COLLECTION
NOT DESCRIPTION TAG
```

A keyword is one of these words written in capitals, standing by itself. The same letters are an
ordinary word when they directly follow a `.` or a `%` (`code.TYPE`, `%NULL`: an element and a
constant of that name), and are no token at all inside quotes. A keyword cannot be part of a bare
path (section 6.3 says how such a path is written).

### 3.3 Words, numbers and literals

| token | written | examples |
|---|---|---|
| word | a letter or `_`, then letters, digits and `_`; not a keyword | `gender`, `Patient`, `birth_date` |
| number | digits, optionally a fraction, optionally an exponent | `3`, `1.50`, `2e-3` |
| string | between single quotes | `'final'`, `'it\'s'` |
| quoted name | between backticks | `` `TYPE` ``, `` `first name` `` |
| quoted text | between double quotes | `"name.family"` |
| date literal | `@` and a FHIRPath date, dateTime or time | `@2024-01-31`, `@2024-01-31T09:00:00Z`, `@T09:00` |
| symbol | one of `. + - * / | & ~ ! < > $ % ^ ?` | |
| `=` | | |
| punctuation | `( ) [ ] { } , : ;` | |

**Strings** are written as FHIRPath writes them. A backslash escapes the next character: `\'`,
`\"`, `` \` ``, `\\`, `\/`, `\f`, `\n`, `\r`, `\t`, and `\uXXXX` for a character by its code (four
hexadecimal digits); `\b` is also read. Any other escape is an error.

**Quoted names** take the same escapes. They are how a name that is not a word, or is a keyword, is
written (a column called `TYPE`).

**Quoted text** holds a path exactly as it is (section 6.3): inside it `\"` is a double quote and
`\\` a backslash, and every other character, a backslash included, stands for itself. Among the
values of `WITH (…)` quoted text is a string, with a string's escapes.

## 4. Grammar

This is the grammar the parser is generated from (`parser/grammar.rkt`). Names in capitals are
tokens: the keywords, and `WORD`, `NUMBER`, `STRING`, `QUOTED` (quoted text), `BACKTICK` (a quoted
name), `ATLIT` (a date literal), `SYMBOL` and `EQ` (`=`). `[x]` is optional, `x*` any number,
`x+` one or more, `|` a choice.

```ebnf
sof-file    : (view ";")* [view]
view        : [header] [declare] query
header      : CREATE VIEW [name] [options] AS
name        : WORD | BACKTICK
options     : WITH "(" option ("," option)* ")"
option      : WORD EQ value
value       : STRING | QUOTED | NUMBER | SYMBOL NUMBER | WORD | array | object
array       : "[" [value ("," value)*] "]"
object      : "{" [member ("," member)*] "}"
member      : (WORD | STRING | QUOTED) ":" value
declare     : DECLARE constant ("," constant)*
constant    : name [WORD] EQ literal
literal     : STRING | NUMBER | SYMBOL NUMBER | WORD | ATLIT
query       : SELECT [items] FROM WORD [conditions]
conditions  : WHERE condition (AND condition)*
condition   : path [description]
items       : item ("," item)*
item        : column | nested | union
nested      : "(" select ")"
union       : "(" select (UNION ALL select)+ ")"
select      : SELECT [items] [source]
source      : FROM each | FROM REPEAT repeat
each        : path [OR NULL]
repeat      : path ("," path)*
column      : path [AS name] (type | collection | description | tag)*
type        : TYPE (WORD (SYMBOL WORD)* | STRING)
collection  : [NOT] COLLECTION
description : DESCRIPTION STRING
tag         : TAG STRING EQ STRING
path        : ptok+ | QUOTED
ptok        : WORD | NUMBER | STRING | BACKTICK | ATLIT | SYMBOL | EQ | group
group       : "(" inner* ")" | "[" inner* "]" | "{" inner* "}"
inner       : ptok | "," | ":"
```

Four things the grammar leaves open are settled when a statement is compiled:

- a `column` without `AS` must be a single word (section 5.2);
- a `union` must be the last item of its `SELECT` (section 5.5);
- the `WORD` giving a constant's type must be one of the nineteen types of section 5.7;
- a `value` that is a `WORD` must be `true`, `false` or `null`, and a `SYMBOL` before a number
  must be `-`.

## 5. What a statement means

A source text is any number of statements, separated by `;` (a `;` after the last is allowed). Each
statement is one view and compiles to one ViewDefinition. This table says where each element of a
ViewDefinition is written; the sections after it give the detail.

| ViewDefinition element | written as |
|---|---|
| `resource` | `FROM Patient`, after the outermost `SELECT` |
| `select` | `SELECT` and its items |
| `select.column`, `select.column.path`, `select.column.name` | an item: `path AS name`, or an element's name alone |
| `select.column.type` | `TYPE dateTime` after the column |
| `select.column.collection` | `COLLECTION` after the column (`NOT COLLECTION` for an explicit false) |
| `select.column.description` | `DESCRIPTION 'text'` after the column |
| `select.column.tag`, `select.column.tag.name`, `select.column.tag.value` | `TAG 'name' = 'value'` after the column, once for each tag |
| `select.select` | an item: `(SELECT …)` |
| `select.forEach` | `FROM path` in a parenthesised `SELECT` |
| `select.forEachOrNull` | `FROM path OR NULL` |
| `select.repeat` | `FROM REPEAT path, path` |
| `select.unionAll` | an item: `(SELECT … UNION ALL SELECT …)` |
| `where`, `where.path` | `WHERE path AND path` |
| `where.description` | `DESCRIPTION 'text'` after the condition |
| `constant`, `constant.name`, `constant.value[x]` | `DECLARE name = value` or `DECLARE name type = value` |
| `name` | `CREATE VIEW name` |
| every other element of the view itself (`status`, `url`, `title`, `fhirVersion`, `profile`, …) | `WITH (element = value)` after `CREATE VIEW` |

`resourceType` is not written: every statement is a ViewDefinition.

### 5.1 The query

The smallest statement is a query: what to select, and the resource type the view reads.

```sof
SELECT id, gender FROM Patient
```

```json
{"resourceType": "ViewDefinition",
 "resource": "Patient",
 "select": [{"column": [{"name": "id", "path": "id"}, {"name": "gender", "path": "gender"}]}]}
```

### 5.2 Columns

An item of a `SELECT` that is not in parentheses is a column: a path, and after `AS` the column's
name. A path that is a single word may stand without `AS`; the word is then both the path and the
name. Any other path needs `AS`.

After the name a column may say, in any order and each at most once (a `TAG` any number of times):
its `TYPE` (a type's name, a dotted element id such as `Observation.referenceRange`, or a url in
single quotes), `COLLECTION` (the column holds every value of its path, as a list), a
`DESCRIPTION`, and `TAG`s.

```sof
SELECT
  id,
  birthDate AS birth_date TYPE date DESCRIPTION 'as recorded',
  name.given AS given_names COLLECTION,
  gender TAG 'ansi/type' = 'CHARACTER VARYING'
FROM Patient
```

```json
{"resourceType": "ViewDefinition",
 "resource": "Patient",
 "select": [{"column": [{"name": "id", "path": "id"},
                        {"name": "birth_date",
                         "path": "birthDate",
                         "description": "as recorded",
                         "type": "date"},
                        {"name": "given_names", "path": "name.given", "collection": true},
                        {"name": "gender",
                         "path": "gender",
                         "tag": [{"name": "ansi/type", "value": "CHARACTER VARYING"}]}]}]}
```

### 5.3 A row for each item: `FROM` in a nested `SELECT`

An item in parentheses is a nested select. Its `FROM` says what its rows are made over:

| `FROM` | rows | ViewDefinition |
|---|---|---|
| none | one, over the same item as the enclosing select | no `forEach` |
| `FROM path` | one for each item of the path; none, no row | `forEach` |
| `FROM path OR NULL` | the same, but none gives one row of nulls | `forEachOrNull` |
| `FROM REPEAT path, path` | one for each item reached by following the paths to any depth | `repeat` |

Paths inside a nested select are relative to the item it is over. Nested selects nest.

```sof
SELECT
  id,
  (SELECT
     relationship.text AS relationship,
     (SELECT system, value FROM telecom OR NULL)
   FROM contact)
FROM Patient
```

```json
{"resourceType": "ViewDefinition",
 "resource": "Patient",
 "select": [{"column": [{"name": "id", "path": "id"}]},
            {"select": [{"forEachOrNull": "telecom",
                         "column": [{"name": "system", "path": "system"},
                                    {"name": "value", "path": "value"}]}],
             "forEach": "contact",
             "column": [{"name": "relationship", "path": "relationship.text"}]}]}
```

```sof
SELECT id, (SELECT linkId, text FROM REPEAT item, answer.item) FROM QuestionnaireResponse
```

```json
{"resourceType": "ViewDefinition",
 "resource": "QuestionnaireResponse",
 "select": [{"column": [{"name": "id", "path": "id"}]},
            {"repeat": ["item", "answer.item"],
             "column": [{"name": "linkId", "path": "linkId"}, {"name": "text", "path": "text"}]}]}
```

### 5.4 The order of items is the order of columns

The columns of the table are the items in the order written, left to right, whatever their kind.
A ViewDefinition's select holds its own columns first, then its nested selects, then its
`unionAll`; so the items compile like this:

1. The columns that come first are the select's own `column`.
2. After them, each `(SELECT …)` is one entry of the select's `select`.
3. After the first parenthesised item, a further run of columns is one entry of `select` too: a
   nested select of those columns alone.
4. A `UNION ALL` group is the select's `unionAll`, and is its last item (section 5.5).

The outermost `SELECT` has no select element of its own: a ViewDefinition's `select` is a list. Its
items compile by the same four steps, and the list is what they give, in order: its own columns as
one select of columns, then each nested select, then its `UNION ALL` group as one select.

```sof
SELECT id, (SELECT family FROM name), gender, birthDate FROM Patient
```

```json
{"resourceType": "ViewDefinition",
 "resource": "Patient",
 "select": [{"column": [{"name": "id", "path": "id"}]},
            {"forEach": "name", "column": [{"name": "family", "path": "family"}]},
            {"column": [{"name": "gender", "path": "gender"},
                        {"name": "birthDate", "path": "birthDate"}]}]}
```

Two runs of columns that touch are one run. To keep them as two selects, parenthesise the second;
a parenthesised `SELECT` without a `FROM` changes no rows.

```sof
SELECT id, (SELECT gender) FROM Patient
```

```json
{"resourceType": "ViewDefinition",
 "resource": "Patient",
 "select": [{"column": [{"name": "id", "path": "id"}]},
            {"column": [{"name": "gender", "path": "gender"}]}]}
```

### 5.5 `UNION ALL`

A parenthesised group of two or more selects joined by `UNION ALL` gives the rows of each, one
select after another. The selects name the same columns in the same order. The group is the
`unionAll` of the select it is an item of, and stands last among its items.

```sof
SELECT
  id,
  (SELECT system, value FROM telecom
   UNION ALL
   SELECT system, value FROM contact.telecom)
FROM Patient
```

```json
{"resourceType": "ViewDefinition",
 "resource": "Patient",
 "select": [{"column": [{"name": "id", "path": "id"}]},
            {"unionAll": [{"forEach": "telecom",
                           "column": [{"name": "system", "path": "system"},
                                      {"name": "value", "path": "value"}]},
                          {"forEach": "contact.telecom",
                           "column": [{"name": "system", "path": "system"},
                                      {"name": "value", "path": "value"}]}]}]}
```

A select of the group may itself hold anything a select may. For a group that is not last, or is
one of two, give it a select of its own: `(SELECT (… UNION ALL …))`.

### 5.6 `WHERE`

`WHERE` is followed by one or more conditions separated by `AND`; a resource is kept when every one
is true of it. Each condition is one entry of the ViewDefinition's `where`, and may be followed by
a `DESCRIPTION`. `AND` in capitals separates conditions; FHIRPath's lower-case `and` stays inside
one.

```sof
SELECT id FROM Observation
WHERE status = 'final' and value.exists() DESCRIPTION 'a finished reading'
  AND code.coding.exists(system = 'http://loinc.org')
```

```json
{"resourceType": "ViewDefinition",
 "resource": "Observation",
 "select": [{"column": [{"name": "id", "path": "id"}]}],
 "where": [{"path": "status = 'final' and value.exists()", "description": "a finished reading"},
           {"path": "code.coding.exists(system = 'http://loinc.org')"}]}
```

### 5.7 `DECLARE`: constants

`DECLARE` comes before `SELECT` and names values once; a path reads one as `%name`. A constant is
a name, optionally a type, `=` and a value. The types are the nineteen the standard allows:

```
base64Binary boolean canonical code date dateTime decimal id instant integer integer64 oid
string positiveInt time unsignedInt uri url uuid
```

Without a type the value says it:

| value | type | example |
|---|---|---|
| a string | `string` | `'http://loinc.org'` |
| digits | `integer` | `3` |
| a number with a fraction or an exponent | `decimal` | `2.5` |
| `true`, `false` | `boolean` | |
| a date literal | `date`, `dateTime` or `time`, by its form | `@2024-01-31` |

With a type, the value is written as that type is in FHIR JSON: a string for `code`, `date`, `uri`
and the like, a number for the numeric types.

```sof
DECLARE loinc = 'http://loinc.org',
        systolic code = '8480-6',
        since = @2024-01-01,
        ceiling decimal = 300
SELECT id
FROM Observation
WHERE code.coding.exists(system = %loinc and code = %systolic)
```

```json
{"resourceType": "ViewDefinition",
 "resource": "Observation",
 "constant": [{"name": "loinc", "valueString": "http://loinc.org"},
              {"name": "systolic", "valueCode": "8480-6"},
              {"name": "since", "valueDate": "2024-01-01"},
              {"name": "ceiling", "valueDecimal": 300}],
 "select": [{"column": [{"name": "id", "path": "id"}]}],
 "where": [{"path": "code.coding.exists(system = %loinc and code = %systolic)"}]}
```

### 5.8 `CREATE VIEW`: the name and the view's other elements

A statement may begin `CREATE VIEW`, the view's name, optionally `WITH (…)`, and `AS`. The name
is the ViewDefinition's `name`; a view without one is written `CREATE VIEW WITH (…) AS`, or as a
bare query when it has no other element either.

`WITH (…)` holds every other element of the view, by its name in the ViewDefinition: `status`,
`url`, `version`, `title`, `description`, `fhirVersion`, `profile`, `experimental`, `publisher`
and the rest. A value is JSON, with two conveniences: a string may be in single quotes, and an
object's keys need no quotes. So a list is `['4.0', '5.0']` and a complex element is written as
its JSON. The elements a statement writes itself (`name`, `resource`, `constant`, `select`,
`where`) are not accepted in `WITH`.

```sof
CREATE VIEW blood_pressures
  WITH (url = 'http://example.org/ViewDefinition/blood_pressures',
        status = 'draft',
        experimental = true,
        fhirVersion = ['4.0', '5.0'],
        contact = [{name: 'Data team', telecom: [{system: 'email', value: 'data@example.org'}]}])
AS
SELECT id FROM Observation
```

```json
{"resourceType": "ViewDefinition",
 "name": "blood_pressures",
 "url": "http://example.org/ViewDefinition/blood_pressures",
 "status": "draft",
 "experimental": true,
 "fhirVersion": ["4.0", "5.0"],
 "contact": [{"name": "Data team", "telecom": [{"value": "data@example.org", "system": "email"}]}],
 "resource": "Observation",
 "select": [{"column": [{"name": "id", "path": "id"}]}]}
```

## 6. Paths

### 6.1 What a path is

A path is the text of a FHIRPath expression. It stands in four places: a column, a condition of
`WHERE`, and after `FROM` in a nested select (once, or several times after `REPEAT`). The language
does not interpret it; it must be FHIRPath (a path that does not parse is an error, at the path),
and the standard's two functions `getResourceKey()` and `getReferenceKey()` and its `%rowIndex`
are available in it because the engine provides them.

### 6.2 Where a bare path ends

A path written without quotes runs from its first token to the last token before the one that
ends it: a keyword, a `,` or `)` that is not inside the path's own brackets, a `;`, or the end of
the text. Brackets `( )`, `[ ]` and `{ }` inside a path must balance.

The path the ViewDefinition holds is that text as written, with two adjustments: comments are
left out, and a line break (with the white space around it) counts as one space. So a long
expression can be laid out over several lines and commented:

```sof
SELECT
  name.where(use = 'official')   -- the legal name
      .family.first() AS family
FROM Patient
```

```json
{"resourceType": "ViewDefinition",
 "resource": "Patient",
 "select": [{"column": [{"name": "family", "path": "name.where(use = 'official') .family.first()"}]}]}
```

### 6.3 A path in double quotes

A path may instead be written in double quotes, and is then taken exactly as it is (section 3.3).
No element or type of FHIR is spelt like a keyword of this language, so a path seldom needs this.
It is there for exactness: a path that holds a comment of its own, a line break, or a word in
capitals that is a keyword here can still be written, so every ViewDefinition has a text.

```sof
SELECT "gender /* administrative */" AS gender FROM Patient
```

```json
{"resourceType": "ViewDefinition",
 "resource": "Patient",
 "select": [{"column": [{"name": "gender", "path": "gender /* administrative */"}]}]}
```

## 7. From a ViewDefinition back to text

Decompiling writes a ViewDefinition as a statement. **The law:** compiling the text a
ViewDefinition decompiles to gives that ViewDefinition back, equal as JSON. (`resourceType` is
always there after compiling; FHIR R6's `resourceDefinition`, which is not an element, is not
kept.) The text is another way to hold the same resource.

The decompiler writes one form, a clause and an item to a line, and chooses between ways of
writing by what compiles back:

- a column whose path is a single word that is also its name is written as that word;
- a path is written bare when its text, read as a bare path, is itself; otherwise in double quotes;
- a name that is not a word, or is spelt like a keyword, is written in backticks;
- a constant is written without its type when its value says it;
- a nested select of columns alone is written without parentheses when it follows a
  parenthesised item, and in parentheses otherwise (section 5.4);
- `WITH` lists the view's other elements in the order the standard's definition has them.

This is what the decompiler writes for the ViewDefinition of section 1:

```sof-canonical
CREATE VIEW patient_contacts
  WITH (title = 'How to reach each patient',
        status = 'active')
AS
SELECT
  getResourceKey() AS patient_id,
  name.where(use = 'official').family.first() AS family,
  (SELECT
     system,
     value
   FROM telecom OR NULL)
FROM Patient
WHERE active = true
```

## 8. What the language cannot say

A ViewDefinition holding one of these has no text, and decompiling it is refused with the reason:

- an `id`, `extension` or `modifierExtension` of a select, a column, a condition or a constant
  (those of the view itself are written in `WITH`);
- an empty list where a list is given (`"column": []`);
- a `unionAll` of a single select (a nested select says the same);
- a select with more than one of `forEach`, `forEachOrNull` and `repeat`, a constant without
  exactly one value, a view without a `resource`: none of these is a ViewDefinition by the
  standard's definition either.

Three more limits are worth knowing. A file's statements are independent: there is no way for one
view to refer to another. A statement says nothing about data, so `run` takes the data from its
arguments. And the language has only the ViewDefinition's own vocabulary: no `JOIN`, `GROUP BY` or
`ORDER BY`, because a ViewDefinition has none (those belong to the SQL that queries the tables
views make).

## 9. Errors

A problem is reported with the file, the line and the column where it is, and a message that says
what to write. There are three kinds.

**The text is not a statement.** The parser says the token it did not expect, or after which
token the statement ended.

```sof-refused
SELECT id, gender FROM
```
```text
1:19: the statement ends after `FROM`
```

A keyword written in lower case is the commonest of these, and is said:

```sof-refused
select id from Patient
```
```text
1:1: unexpected word `select` (keywords are written in capitals: `SELECT`; in lower case `select` is read as part of a path)
```

**A statement cannot be compiled.** The four things of section 4, and a path that is not FHIRPath.

```sof-refused
SELECT id,
  name.family
FROM Patient
```
```text
2:3: this column needs a name: write `name.family AS <name>`
```

```sof-refused
SELECT id, name.family. AS family FROM Patient
```
```text
1:12: the path "name.family." is not FHIRPath: the expression ends after `.`
```

**The result is not a ViewDefinition.** What compiles is held to the standard's definition of a
view, and to what the engine can tell without data; the problem is reported at the statement.

```sof-refused
SELECT id FROM Patient;

SELECT id AS `patient-id` FROM Patient
```
```text
3:1: not a valid ViewDefinition: select[0].column[0].name "patient-id" is not a name a database takes: letters, digits and _ only, starting with a letter
```

## 10. Files, commands, and how this document is held

**Files.** A source text is kept in a file ending `.sof`. What a file holds is told by how it
begins: `{` is a ViewDefinition as JSON; anything else is source text. A first line
`#lang sql-on-fhir` makes the file a Racket module as well, which provides its views
(`resources`, `(->json)`) and prints them as JSON when run.

**Commands.**

```
sql-on-fhir run patients.sof data/ --format csv   # compile the first view and run it
sql-on-fhir compile patients.sof                  # the ViewDefinitions, as FHIR JSON
sql-on-fhir compile patients.sof -o views/        # each written to views/<name>.view.json
sql-on-fhir decompile patients.view.json          # a ViewDefinition as source text
```

**From Racket.** `(require sql-on-fhir)`: `sof->views` (text to ViewDefinitions), `read-sof` (the
same, each checked as a view, with where it begins), `view->sof` and `views->sof` (back to text).

**How this document is held.** `tests/language-test.rkt` fails when:

- the grammar of section 4 is not, rule for rule, the grammar in `parser/grammar.rkt`;
- the keywords of section 3.2 or the types of section 5.7 are not the lexer's and the compiler's,
  or the types are not the ones the standard's definition gives a constant;
- an example of this document does not compile to the JSON shown after it, is not a valid view, or
  an error example does not give the message shown;
- the table of section 5 leaves out an element of the standard's ViewDefinition;
- the law of section 7 fails on a view of the standard's shared test suite, on one of the
  standard's own example views, on an example of this document, or on one of 600 views grown at
  random from every shape a select can take. Of the suite's 144 views and the standard's 10
  examples, 148 have a text and come back from it unchanged, among them every one that is a view
  by the standard's definition. The other 6 are views the suite expects to be refused: 5 have no
  text (no `resource`, a `forEach` that is a number, a constant without a value), and one has a
  path that is not FHIRPath, which the compiler refuses.

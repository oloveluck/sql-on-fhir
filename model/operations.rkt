#lang racket/base
;;; GENERATED — DO NOT EDIT (verified by raco sql-on-fhir check).
;; The package's OperationDefinitions as data + scaffold constructors: each
;; <code>-operation takes ONLY the handler `(in req) -> node` and yields the
;; operation-entry list for build-app's #:operations (levels/targets from the OD).
(require json (only-in fhir/kernel/operation-entry operation-entry))
(provide operation-definitions
         sql-export-definition sql-export-operation
         sql-run-definition sql-run-operation)
(define sql-export-definition
  (string->jsexpr
   "{
  \"code\": \"sql-export\",
  \"contact\": [
    {
      \"name\": \"HL7 International / FHIR Infrastructure\",
      \"telecom\": [
        {
          \"system\": \"url\",
          \"value\": \"http://www.hl7.org/Special/committees/fiwg\"
        }
      ]
    }
  ],
  \"date\": \"2026-08-14T02:49:31+10:00\",
  \"description\": \"Export one or more ViewDefinitions, SQLQuery Libraries and SQLView Libraries as a single asynchronous job, using the FHIR Asynchronous Interaction Request Pattern.\",
  \"extension\": [
    {
      \"url\": \"http://hl7.org/fhir/StructureDefinition/structuredefinition-wg\",
      \"valueCode\": \"fhir\"
    },
    {
      \"_valueInteger\": {
        \"extension\": [
          {
            \"url\": \"http://hl7.org/fhir/StructureDefinition/structuredefinition-conformance-derivedFrom\",
            \"valueCanonical\": \"http://hl7.org/fhir/uv/sql-on-fhir/ImplementationGuide/hl7.fhir.uv.sql-on-fhir\"
          }
        ]
      },
      \"url\": \"http://hl7.org/fhir/StructureDefinition/structuredefinition-fmm\",
      \"valueInteger\": 2
    },
    {
      \"_valueCode\": {
        \"extension\": [
          {
            \"url\": \"http://hl7.org/fhir/StructureDefinition/structuredefinition-conformance-derivedFrom\",
            \"valueCanonical\": \"http://hl7.org/fhir/uv/sql-on-fhir/ImplementationGuide/hl7.fhir.uv.sql-on-fhir\"
          }
        ]
      },
      \"url\": \"http://hl7.org/fhir/StructureDefinition/structuredefinition-standards-status\",
      \"valueCode\": \"trial-use\"
    }
  ],
  \"id\": \"SQLExport\",
  \"identifier\": [
    {
      \"system\": \"urn:ietf:rfc:3986\",
      \"value\": \"urn:oid:2.16.840.1.113883.4.642.40.77.33.5\"
    }
  ],
  \"instance\": false,
  \"jurisdiction\": [
    {
      \"coding\": [
        {
          \"code\": \"001\",
          \"display\": \"World\",
          \"system\": \"http://unstats.un.org/unsd/methods/m49/m49.htm\"
        }
      ]
    }
  ],
  \"kind\": \"operation\",
  \"name\": \"SQLExport\",
  \"parameter\": [
    {
      \"documentation\": \"One or more artifacts to export, in any mixture of ViewDefinitions, SQLQuery Libraries and SQLView Libraries. Each repetition names a single subject and produces exactly one output entry in the manifest. A request supplying no subject is rejected with 400 Bad Request, as is a request in which two repetitions would produce the same output name.\",
      \"max\": \"*\",
      \"min\": 1,
      \"name\": \"subject\",
      \"part\": [
        {
          \"documentation\": \"Name for this subject's output entry in the manifest. Where it is omitted the server uses the subject's own name element, and where the subject declares none, a server-generated identifier. Output names are unique across the job.\",
          \"max\": \"1\",
          \"min\": 0,
          \"name\": \"name\",
          \"type\": \"string\",
          \"use\": \"in\"
        },
        {
          \"documentation\": \"Canonical URL of the ViewDefinition, SQLQuery Library or SQLView Library to export, optionally with a |version suffix pinning a version. Exactly one of subjectCanonical, subjectReference and subjectResource is supplied in each repetition.\",
          \"max\": \"1\",
          \"min\": 0,
          \"name\": \"subjectCanonical\",
          \"targetProfile\": [
            \"http://hl7.org/fhir/StructureDefinition/ViewDefinition\",
            \"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLQuery\",
            \"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLView\"
          ],
          \"type\": \"canonical\",
          \"use\": \"in\"
        },
        {
          \"documentation\": \"Literal location of the subject to export: a relative URL on this server, or an absolute URL. Not a canonical URL; use subjectCanonical for that. Exactly one of subjectCanonical, subjectReference and subjectResource is supplied in each repetition.\",
          \"max\": \"1\",
          \"min\": 0,
          \"name\": \"subjectReference\",
          \"targetProfile\": [
            \"http://hl7.org/fhir/StructureDefinition/ViewDefinition\",
            \"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLQuery\",
            \"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLView\"
          ],
          \"type\": \"Reference\",
          \"use\": \"in\"
        },
        {
          \"documentation\": \"Inline ViewDefinition, SQLQuery Library or SQLView Library to export. Exactly one of subjectCanonical, subjectReference and subjectResource is supplied in each repetition. The declared type is CanonicalResource because ViewDefinition is a logical model rather than a FHIR resource; see Common Operation Behavior (operations-common.html#declared-type).\",
          \"max\": \"1\",
          \"min\": 0,
          \"name\": \"subjectResource\",
          \"targetProfile\": [
            \"http://hl7.org/fhir/StructureDefinition/ViewDefinition\",
            \"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLQuery\",
            \"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLView\"
          ],
          \"type\": \"CanonicalResource\",
          \"use\": \"in\"
        },
        {
          \"documentation\": \"Input parameter values for this subject, bound by name to the parameters the Library declares (Library.parameter.name). Permitted only where this repetition's subject is a SQLQuery or SQLView; supplying it where the subject is a ViewDefinition is rejected with 400 Bad Request, because a ViewDefinition declares no parameters.\",
          \"max\": \"1\",
          \"min\": 0,
          \"name\": \"parameters\",
          \"type\": \"Parameters\",
          \"use\": \"in\"
        }
      ],
      \"use\": \"in\"
    },
    {
      \"documentation\": \"Supporting artifacts the server cannot itself resolve, supplied inline and matched by canonical URL against the dependencies in the subjects' transitive relatedArtifact graphs. Applies to the job as a whole rather than to one subject, so an artifact several subjects depend on is supplied once. Accepts inline resources only; there is no context by canonical URL, because a URL is exactly what the server has already failed to resolve. A context entry produces no output entry. See Common Operation Behavior (operations-common.html#context).\",
      \"max\": \"*\",
      \"min\": 0,
      \"name\": \"context\",
      \"targetProfile\": [
        \"http://hl7.org/fhir/StructureDefinition/ViewDefinition\",
        \"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLView\"
      ],
      \"type\": \"CanonicalResource\",
      \"use\": \"in\"
    },
    {
      \"documentation\": \"Client-provided tracking identifier for the export job, echoed in the manifest.\",
      \"max\": \"1\",
      \"min\": 0,
      \"name\": \"clientTrackingId\",
      \"type\": \"string\",
      \"use\": \"in\"
    },
    {
      \"binding\": {
        \"strength\": \"extensible\",
        \"valueSet\": \"http://hl7.org/fhir/uv/sql-on-fhir/ValueSet/ExportOutputFormatCodes\"
      },
      \"documentation\": \"Output format for the exported files (csv, ndjson, parquet, json). Optional; if omitted, the server uses ndjson irrespective of Accept. Requesting fhir is rejected with 400 Bad Request, because an export produces flat files. See Common Operation Behavior (operations-common.html).\",
      \"max\": \"1\",
      \"min\": 0,
      \"name\": \"_format\",
      \"type\": \"code\",
      \"use\": \"in\"
    },
    {
      \"documentation\": \"Include CSV headers (default true). Applies only when csv output is requested.\",
      \"max\": \"1\",
      \"min\": 0,
      \"name\": \"header\",
      \"type\": \"boolean\",
      \"use\": \"in\"
    },
    {
      \"documentation\": \"Restrict the FHIR resources feeding every subject in the job, before projection, to the supplied patient(s). Where a subject is a SQLQuery or SQLView, that means before the SQL executes. An unresolvable patient is rejected with 400 Bad Request. See Common Operation Behavior (operations-common.html#patient-filter).\",
      \"max\": \"*\",
      \"min\": 0,
      \"name\": \"patient\",
      \"type\": \"Reference\",
      \"use\": \"in\"
    },
    {
      \"documentation\": \"Restrict the FHIR resources feeding every subject in the job, before projection, to members of the supplied group(s). Where a subject is a SQLQuery or SQLView, that means before the SQL executes. An unresolvable group is rejected with 400 Bad Request. See Common Operation Behavior (operations-common.html#group-filter).\",
      \"max\": \"*\",
      \"min\": 0,
      \"name\": \"group\",
      \"type\": \"Reference\",
      \"use\": \"in\"
    },
    {
      \"documentation\": \"Include only resources whose state changed after this instant. See Common Operation Behavior (operations-common.html#since-filter).\",
      \"max\": \"1\",
      \"min\": 0,
      \"name\": \"_since\",
      \"type\": \"instant\",
      \"use\": \"in\"
    },
    {
      \"documentation\": \"External data source to read from instead of the server's own data (for example a URI or bucket name). Where a subject is a SQLQuery or SQLView, this is where the ViewDefinition tables the query selects from are found.\",
      \"max\": \"1\",
      \"min\": 0,
      \"name\": \"source\",
      \"type\": \"string\",
      \"use\": \"in\"
    },
    {
      \"documentation\": \"Server-generated identifier assigned to the export job.\",
      \"max\": \"1\",
      \"min\": 1,
      \"name\": \"exportId\",
      \"type\": \"string\",
      \"use\": \"out\"
    },
    {
      \"documentation\": \"Echoed client tracking identifier when provided.\",
      \"max\": \"1\",
      \"min\": 0,
      \"name\": \"clientTrackingId\",
      \"type\": \"string\",
      \"use\": \"out\"
    },
    {
      \"binding\": {
        \"strength\": \"required\",
        \"valueSet\": \"http://hl7.org/fhir/uv/sql-on-fhir/ValueSet/ExportStatusCodes\"
      },
      \"documentation\": \"Status of the export (accepted, in-progress, completed, cancelled, failed).\",
      \"max\": \"1\",
      \"min\": 1,
      \"name\": \"status\",
      \"type\": \"code\",
      \"use\": \"out\"
    },
    {
      \"documentation\": \"URL to poll for export status updates.\",
      \"max\": \"1\",
      \"min\": 1,
      \"name\": \"location\",
      \"type\": \"uri\",
      \"use\": \"out\"
    },
    {
      \"documentation\": \"Optional URL for cancelling the export.\",
      \"max\": \"1\",
      \"min\": 0,
      \"name\": \"cancelUrl\",
      \"type\": \"uri\",
      \"use\": \"out\"
    },
    {
      \"binding\": {
        \"strength\": \"extensible\",
        \"valueSet\": \"http://hl7.org/fhir/uv/sql-on-fhir/ValueSet/ExportOutputFormatCodes\"
      },
      \"documentation\": \"Format of the exported files (echoed from input if supplied).\",
      \"max\": \"1\",
      \"min\": 0,
      \"name\": \"_format\",
      \"type\": \"code\",
      \"use\": \"out\"
    },
    {
      \"documentation\": \"Timestamp when the export job began.\",
      \"max\": \"1\",
      \"min\": 0,
      \"name\": \"exportStartTime\",
      \"type\": \"instant\",
      \"use\": \"out\"
    },
    {
      \"documentation\": \"Timestamp when the export job completed.\",
      \"max\": \"1\",
      \"min\": 0,
      \"name\": \"exportEndTime\",
      \"type\": \"instant\",
      \"use\": \"out\"
    },
    {
      \"documentation\": \"Duration of the export in seconds.\",
      \"max\": \"1\",
      \"min\": 0,
      \"name\": \"exportDuration\",
      \"type\": \"integer\",
      \"use\": \"out\"
    },
    {
      \"documentation\": \"Estimated seconds remaining until completion. Interim polling responses only.\",
      \"max\": \"1\",
      \"min\": 0,
      \"name\": \"estimatedTimeRemaining\",
      \"type\": \"integer\",
      \"use\": \"out\"
    },
    {
      \"documentation\": \"Output information for each exported subject. Exactly one entry per subject repetition, and none for a context entry. Neither manifest order nor computation order is guaranteed; clients correlate entries by name.\",
      \"max\": \"*\",
      \"min\": 0,
      \"name\": \"output\",
      \"part\": [
        {
          \"documentation\": \"Name assigned to this subject's output, derived from subject.name, else the subject's own name element, else a server-generated identifier.\",
          \"max\": \"1\",
          \"min\": 1,
          \"name\": \"name\",
          \"type\": \"string\",
          \"use\": \"out\"
        },
        {
          \"documentation\": \"Download URL(s) for the exported file(s).\",
          \"max\": \"*\",
          \"min\": 1,
          \"name\": \"location\",
          \"type\": \"uri\",
          \"use\": \"out\"
        }
      ],
      \"use\": \"out\"
    }
  ],
  \"publisher\": \"HL7 International / FHIR Infrastructure\",
  \"resourceType\": \"OperationDefinition\",
  \"status\": \"active\",
  \"system\": true,
  \"text\": {
    \"div\": \"<div xmlns=\\\"http://www.w3.org/1999/xhtml\\\"><p class=\\\"res-header-id\\\"><b>Generated Narrative: OperationDefinition SQLExport</b></p><a name=\\\"SQLExport\\\"> </a><a name=\\\"hcSQLExport\\\"> </a><p>URL: [base]/$sql-export</p><h3>Parameters</h3><table class=\\\"grid\\\"><tr><td><b>Use</b></td><td><b>Name</b></td><td><b>Scope</b></td><td><b>Cardinality</b></td><td><b>Type</b></td><td><b>Binding</b></td><td><b>Documentation</b></td></tr><tr><td>IN</td><td>subject</td><td/><td>1..*</td><td/><td/><td><div><p>One or more artifacts to export, in any mixture of ViewDefinitions, SQLQuery Libraries and SQLView Libraries. Each repetition names a single subject and produces exactly one output entry in the manifest. A request supplying no subject is rejected with 400 Bad Request, as is a request in which two repetitions would produce the same output name.</p>\\n</div></td></tr><tr><td>IN</td><td>subject.name</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#string\\\">string</a></td><td/><td><div><p>Name for this subject's output entry in the manifest. Where it is omitted the server uses the subject's own name element, and where the subject declares none, a server-generated identifier. Output names are unique across the job.</p>\\n</div></td></tr><tr><td>IN</td><td>subject.subjectCanonical</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#canonical\\\">canonical</a> (<a href=\\\"StructureDefinition-ViewDefinition.html\\\" title=\\\"http://hl7.org/fhir/StructureDefinition/ViewDefinition\\\">View Definition</a>, <a href=\\\"StructureDefinition-SQLQuery.html\\\" title=\\\"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLQuery\\\">SQL Query Library</a>, <a href=\\\"StructureDefinition-SQLView.html\\\" title=\\\"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLView\\\">SQL View Library</a>)</td><td/><td><div><p>Canonical URL of the ViewDefinition, SQLQuery Library or SQLView Library to export, optionally with a |version suffix pinning a version. Exactly one of subjectCanonical, subjectReference and subjectResource is supplied in each repetition.</p>\\n</div></td></tr><tr><td>IN</td><td>subject.subjectReference</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/references.html#Reference\\\">Reference</a> (<a href=\\\"StructureDefinition-ViewDefinition.html\\\" title=\\\"http://hl7.org/fhir/StructureDefinition/ViewDefinition\\\">View Definition</a>, <a href=\\\"StructureDefinition-SQLQuery.html\\\" title=\\\"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLQuery\\\">SQL Query Library</a>, <a href=\\\"StructureDefinition-SQLView.html\\\" title=\\\"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLView\\\">SQL View Library</a>)</td><td/><td><div><p>Literal location of the subject to export: a relative URL on this server, or an absolute URL. Not a canonical URL; use subjectCanonical for that. Exactly one of subjectCanonical, subjectReference and subjectResource is supplied in each repetition.</p>\\n</div></td></tr><tr><td>IN</td><td>subject.subjectResource</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/canonicalresource.html\\\">CanonicalResource</a> (<a href=\\\"StructureDefinition-ViewDefinition.html\\\" title=\\\"http://hl7.org/fhir/StructureDefinition/ViewDefinition\\\">View Definition</a>, <a href=\\\"StructureDefinition-SQLQuery.html\\\" title=\\\"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLQuery\\\">SQL Query Library</a>, <a href=\\\"StructureDefinition-SQLView.html\\\" title=\\\"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLView\\\">SQL View Library</a>)</td><td/><td><div><p>Inline ViewDefinition, SQLQuery Library or SQLView Library to export. Exactly one of subjectCanonical, subjectReference and subjectResource is supplied in each repetition. The declared type is CanonicalResource because ViewDefinition is a logical model rather than a FHIR resource; see Common Operation Behavior (operations-common.html#declared-type).</p>\\n</div></td></tr><tr><td>IN</td><td>subject.parameters</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/parameters.html\\\">Parameters</a></td><td/><td><div><p>Input parameter values for this subject, bound by name to the parameters the Library declares (Library.parameter.name). Permitted only where this repetition's subject is a SQLQuery or SQLView; supplying it where the subject is a ViewDefinition is rejected with 400 Bad Request, because a ViewDefinition declares no parameters.</p>\\n</div></td></tr><tr><td>IN</td><td>context</td><td/><td>0..*</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/canonicalresource.html\\\">CanonicalResource</a> (<a href=\\\"StructureDefinition-ViewDefinition.html\\\" title=\\\"http://hl7.org/fhir/StructureDefinition/ViewDefinition\\\">View Definition</a>, <a href=\\\"StructureDefinition-SQLView.html\\\" title=\\\"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLView\\\">SQL View Library</a>)</td><td/><td><div><p>Supporting artifacts the server cannot itself resolve, supplied inline and matched by canonical URL against the dependencies in the subjects' transitive relatedArtifact graphs. Applies to the job as a whole rather than to one subject, so an artifact several subjects depend on is supplied once. Accepts inline resources only; there is no context by canonical URL, because a URL is exactly what the server has already failed to resolve. A context entry produces no output entry. See Common Operation Behavior (operations-common.html#context).</p>\\n</div></td></tr><tr><td>IN</td><td>clientTrackingId</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#string\\\">string</a></td><td/><td><div><p>Client-provided tracking identifier for the export job, echoed in the manifest.</p>\\n</div></td></tr><tr><td>IN</td><td>_format</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#code\\\">code</a></td><td><a href=\\\"ValueSet-ExportOutputFormatCodes.html\\\">Export Output Format Codes</a> (Extensible)</td><td><div><p>Output format for the exported files (csv, ndjson, parquet, json). Optional; if omitted, the server uses ndjson irrespective of Accept. Requesting fhir is rejected with 400 Bad Request, because an export produces flat files. See Common Operation Behavior (operations-common.html).</p>\\n</div></td></tr><tr><td>IN</td><td>header</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#boolean\\\">boolean</a></td><td/><td><div><p>Include CSV headers (default true). Applies only when csv output is requested.</p>\\n</div></td></tr><tr><td>IN</td><td>patient</td><td/><td>0..*</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/references.html#Reference\\\">Reference</a></td><td/><td><div><p>Restrict the FHIR resources feeding every subject in the job, before projection, to the supplied patient(s). Where a subject is a SQLQuery or SQLView, that means before the SQL executes. An unresolvable patient is rejected with 400 Bad Request. See Common Operation Behavior (operations-common.html#patient-filter).</p>\\n</div></td></tr><tr><td>IN</td><td>group</td><td/><td>0..*</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/references.html#Reference\\\">Reference</a></td><td/><td><div><p>Restrict the FHIR resources feeding every subject in the job, before projection, to members of the supplied group(s). Where a subject is a SQLQuery or SQLView, that means before the SQL executes. An unresolvable group is rejected with 400 Bad Request. See Common Operation Behavior (operations-common.html#group-filter).</p>\\n</div></td></tr><tr><td>IN</td><td>_since</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#instant\\\">instant</a></td><td/><td><div><p>Include only resources whose state changed after this instant. See Common Operation Behavior (operations-common.html#since-filter).</p>\\n</div></td></tr><tr><td>IN</td><td>source</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#string\\\">string</a></td><td/><td><div><p>External data source to read from instead of the server's own data (for example a URI or bucket name). Where a subject is a SQLQuery or SQLView, this is where the ViewDefinition tables the query selects from are found.</p>\\n</div></td></tr><tr><td>OUT</td><td>exportId</td><td/><td>1..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#string\\\">string</a></td><td/><td><div><p>Server-generated identifier assigned to the export job.</p>\\n</div></td></tr><tr><td>OUT</td><td>clientTrackingId</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#string\\\">string</a></td><td/><td><div><p>Echoed client tracking identifier when provided.</p>\\n</div></td></tr><tr><td>OUT</td><td>status</td><td/><td>1..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#code\\\">code</a></td><td><a href=\\\"ValueSet-ExportStatusCodes.html\\\">Export Status Codes</a> (Required)</td><td><div><p>Status of the export (accepted, in-progress, completed, cancelled, failed).</p>\\n</div></td></tr><tr><td>OUT</td><td>location</td><td/><td>1..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#uri\\\">uri</a></td><td/><td><div><p>URL to poll for export status updates.</p>\\n</div></td></tr><tr><td>OUT</td><td>cancelUrl</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#uri\\\">uri</a></td><td/><td><div><p>Optional URL for cancelling the export.</p>\\n</div></td></tr><tr><td>OUT</td><td>_format</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#code\\\">code</a></td><td><a href=\\\"ValueSet-ExportOutputFormatCodes.html\\\">Export Output Format Codes</a> (Extensible)</td><td><div><p>Format of the exported files (echoed from input if supplied).</p>\\n</div></td></tr><tr><td>OUT</td><td>exportStartTime</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#instant\\\">instant</a></td><td/><td><div><p>Timestamp when the export job began.</p>\\n</div></td></tr><tr><td>OUT</td><td>exportEndTime</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#instant\\\">instant</a></td><td/><td><div><p>Timestamp when the export job completed.</p>\\n</div></td></tr><tr><td>OUT</td><td>exportDuration</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#integer\\\">integer</a></td><td/><td><div><p>Duration of the export in seconds.</p>\\n</div></td></tr><tr><td>OUT</td><td>estimatedTimeRemaining</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#integer\\\">integer</a></td><td/><td><div><p>Estimated seconds remaining until completion. Interim polling responses only.</p>\\n</div></td></tr><tr><td>OUT</td><td>output</td><td/><td>0..*</td><td/><td/><td><div><p>Output information for each exported subject. Exactly one entry per subject repetition, and none for a context entry. Neither manifest order nor computation order is guaranteed; clients correlate entries by name.</p>\\n</div></td></tr><tr><td>OUT</td><td>output.name</td><td/><td>1..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#string\\\">string</a></td><td/><td><div><p>Name assigned to this subject's output, derived from subject.name, else the subject's own name element, else a server-generated identifier.</p>\\n</div></td></tr><tr><td>OUT</td><td>output.location</td><td/><td>1..*</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#uri\\\">uri</a></td><td/><td><div><p>Download URL(s) for the exported file(s).</p>\\n</div></td></tr></table></div>\",
    \"status\": \"generated\"
  },
  \"title\": \"SQL Export\",
  \"type\": false,
  \"url\": \"http://hl7.org/fhir/uv/sql-on-fhir/OperationDefinition/SQLExport\",
  \"version\": \"3.0.0-ballot\",
  \"versionAlgorithmString\": \"semver\"
}"))
(define (sql-export-operation handler)
  (define code "sql-export")
  (list (operation-entry 'system code #f handler)))
(define sql-run-definition
  (string->jsexpr
   "{
  \"code\": \"sql-run\",
  \"contact\": [
    {
      \"name\": \"HL7 International / FHIR Infrastructure\",
      \"telecom\": [
        {
          \"system\": \"url\",
          \"value\": \"http://www.hl7.org/Special/committees/fiwg\"
        }
      ]
    }
  ],
  \"date\": \"2026-08-14T02:49:31+10:00\",
  \"description\": \"Execute a ViewDefinition, SQLQuery Library or SQLView Library and return the result in the requested output format.\",
  \"extension\": [
    {
      \"url\": \"http://hl7.org/fhir/StructureDefinition/structuredefinition-wg\",
      \"valueCode\": \"fhir\"
    },
    {
      \"_valueInteger\": {
        \"extension\": [
          {
            \"url\": \"http://hl7.org/fhir/StructureDefinition/structuredefinition-conformance-derivedFrom\",
            \"valueCanonical\": \"http://hl7.org/fhir/uv/sql-on-fhir/ImplementationGuide/hl7.fhir.uv.sql-on-fhir\"
          }
        ]
      },
      \"url\": \"http://hl7.org/fhir/StructureDefinition/structuredefinition-fmm\",
      \"valueInteger\": 2
    },
    {
      \"_valueCode\": {
        \"extension\": [
          {
            \"url\": \"http://hl7.org/fhir/StructureDefinition/structuredefinition-conformance-derivedFrom\",
            \"valueCanonical\": \"http://hl7.org/fhir/uv/sql-on-fhir/ImplementationGuide/hl7.fhir.uv.sql-on-fhir\"
          }
        ]
      },
      \"url\": \"http://hl7.org/fhir/StructureDefinition/structuredefinition-standards-status\",
      \"valueCode\": \"trial-use\"
    }
  ],
  \"id\": \"SQLRun\",
  \"identifier\": [
    {
      \"system\": \"urn:ietf:rfc:3986\",
      \"value\": \"urn:oid:2.16.840.1.113883.4.642.40.77.33.6\"
    }
  ],
  \"instance\": false,
  \"jurisdiction\": [
    {
      \"coding\": [
        {
          \"code\": \"001\",
          \"display\": \"World\",
          \"system\": \"http://unstats.un.org/unsd/methods/m49/m49.htm\"
        }
      ]
    }
  ],
  \"kind\": \"operation\",
  \"name\": \"SQLRun\",
  \"parameter\": [
    {
      \"documentation\": \"Canonical URL of the ViewDefinition, SQLQuery Library or SQLView Library to execute, optionally with a |version suffix pinning a version. Exactly one of subjectCanonical, subjectReference and subjectResource is supplied; supplying none, or more than one, is rejected with 400 Bad Request.\",
      \"max\": \"1\",
      \"min\": 0,
      \"name\": \"subjectCanonical\",
      \"targetProfile\": [
        \"http://hl7.org/fhir/StructureDefinition/ViewDefinition\",
        \"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLQuery\",
        \"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLView\"
      ],
      \"type\": \"canonical\",
      \"use\": \"in\"
    },
    {
      \"documentation\": \"Literal location of the subject to execute: a relative URL on this server, or an absolute URL. Not a canonical URL; use subjectCanonical for that. Exactly one of subjectCanonical, subjectReference and subjectResource is supplied; supplying none, or more than one, is rejected with 400 Bad Request.\",
      \"max\": \"1\",
      \"min\": 0,
      \"name\": \"subjectReference\",
      \"targetProfile\": [
        \"http://hl7.org/fhir/StructureDefinition/ViewDefinition\",
        \"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLQuery\",
        \"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLView\"
      ],
      \"type\": \"Reference\",
      \"use\": \"in\"
    },
    {
      \"documentation\": \"Inline ViewDefinition, SQLQuery Library or SQLView Library to execute. Exactly one of subjectCanonical, subjectReference and subjectResource is supplied; supplying none, or more than one, is rejected with 400 Bad Request. Carries a resource, so it requires POST. The declared type is CanonicalResource because ViewDefinition is a logical model rather than a FHIR resource; see Common Operation Behavior (operations-common.html#declared-type).\",
      \"max\": \"1\",
      \"min\": 0,
      \"name\": \"subjectResource\",
      \"targetProfile\": [
        \"http://hl7.org/fhir/StructureDefinition/ViewDefinition\",
        \"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLQuery\",
        \"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLView\"
      ],
      \"type\": \"CanonicalResource\",
      \"use\": \"in\"
    },
    {
      \"documentation\": \"Input parameter values for the subject, bound by name to the parameters the Library declares (Library.parameter.name), using the value[x] type matching each declared type. Permitted only where the subject is a SQLQuery or SQLView; supplying it where the subject is a ViewDefinition is rejected with 400 Bad Request, because a ViewDefinition declares no parameters. Carries a resource, so it requires POST.\",
      \"max\": \"1\",
      \"min\": 0,
      \"name\": \"parameters\",
      \"type\": \"Parameters\",
      \"use\": \"in\"
    },
    {
      \"documentation\": \"Supporting artifacts the server cannot itself resolve, supplied inline and matched by canonical URL against the dependencies in the subject's transitive relatedArtifact graph. Accepts inline resources only; there is no context by canonical URL, because a URL is exactly what the server has already failed to resolve. Carries a resource, so it requires POST. See Common Operation Behavior (operations-common.html#context).\",
      \"max\": \"*\",
      \"min\": 0,
      \"name\": \"context\",
      \"targetProfile\": [
        \"http://hl7.org/fhir/StructureDefinition/ViewDefinition\",
        \"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLView\"
      ],
      \"type\": \"CanonicalResource\",
      \"use\": \"in\"
    },
    {
      \"documentation\": \"FHIR resources to transform instead of using server data. Repeatable. A Bundle supplied here is unwrapped: the view runs against each Bundle.entry[*].resource rather than against the Bundle itself. Permitted only where the subject is a ViewDefinition; supplying it where the subject is a SQLQuery or SQLView is rejected with 400 Bad Request, because how inline resources reach each dependency view is not specified. Carries a resource, so it requires POST. See OperationDefinition-SQLRun notes (Resource parameter and Bundle inputs).\",
      \"max\": \"*\",
      \"min\": 0,
      \"name\": \"resource\",
      \"type\": \"Resource\",
      \"use\": \"in\"
    },
    {
      \"binding\": {
        \"strength\": \"extensible\",
        \"valueSet\": \"http://hl7.org/fhir/uv/sql-on-fhir/ValueSet/OutputFormatCodes\"
      },
      \"documentation\": \"Output format for the result (json, ndjson, csv, parquet, fhir). Use fhir to return results as a FHIR Parameters resource. Optional; if omitted, the server returns ndjson by default. See Common Operation Behavior (operations-common.html).\",
      \"max\": \"1\",
      \"min\": 0,
      \"name\": \"_format\",
      \"type\": \"code\",
      \"use\": \"in\"
    },
    {
      \"documentation\": \"Include CSV headers (default true). Applies only when csv output is requested.\",
      \"max\": \"1\",
      \"min\": 0,
      \"name\": \"header\",
      \"type\": \"boolean\",
      \"use\": \"in\"
    },
    {
      \"documentation\": \"Restrict the FHIR resources feeding the view, before projection, to the supplied patient(s). Where the subject is a SQLQuery or SQLView, that means before the SQL executes. An unresolvable patient is rejected with 400 Bad Request. See Common Operation Behavior (operations-common.html#patient-filter).\",
      \"max\": \"*\",
      \"min\": 0,
      \"name\": \"patient\",
      \"type\": \"Reference\",
      \"use\": \"in\"
    },
    {
      \"documentation\": \"Restrict the FHIR resources feeding the view, before projection, to members of the supplied group(s). Where the subject is a SQLQuery or SQLView, that means before the SQL executes. An unresolvable group is rejected with 400 Bad Request. See Common Operation Behavior (operations-common.html#group-filter).\",
      \"max\": \"*\",
      \"min\": 0,
      \"name\": \"group\",
      \"type\": \"Reference\",
      \"use\": \"in\"
    },
    {
      \"documentation\": \"Include only resources whose state changed after this instant. See Common Operation Behavior (operations-common.html#since-filter).\",
      \"max\": \"1\",
      \"min\": 0,
      \"name\": \"_since\",
      \"type\": \"instant\",
      \"use\": \"in\"
    },
    {
      \"documentation\": \"External data source to read from instead of the server's own data (for example a URI or bucket name). Where the subject is a SQLQuery or SQLView, this is where the ViewDefinition tables the query selects from are found.\",
      \"max\": \"1\",
      \"min\": 0,
      \"name\": \"source\",
      \"type\": \"string\",
      \"use\": \"in\"
    },
    {
      \"documentation\": \"Maximum number of rows to return.\",
      \"max\": \"1\",
      \"min\": 0,
      \"name\": \"_limit\",
      \"type\": \"integer\",
      \"use\": \"in\"
    },
    {
      \"documentation\": \"Result rows in the requested output format, returned as a raw binary stream in the format's native media type, not a serialized Binary resource envelope. When _format=fhir is requested, the response is a Parameters resource instead. See Common Operation Behavior (operations-common.html).\",
      \"max\": \"1\",
      \"min\": 1,
      \"name\": \"return\",
      \"type\": \"Binary\",
      \"use\": \"out\"
    }
  ],
  \"publisher\": \"HL7 International / FHIR Infrastructure\",
  \"resourceType\": \"OperationDefinition\",
  \"status\": \"active\",
  \"system\": true,
  \"text\": {
    \"div\": \"<div xmlns=\\\"http://www.w3.org/1999/xhtml\\\"><p class=\\\"res-header-id\\\"><b>Generated Narrative: OperationDefinition SQLRun</b></p><a name=\\\"SQLRun\\\"> </a><a name=\\\"hcSQLRun\\\"> </a><p>URL: [base]/$sql-run</p><h3>Parameters</h3><table class=\\\"grid\\\"><tr><td><b>Use</b></td><td><b>Name</b></td><td><b>Scope</b></td><td><b>Cardinality</b></td><td><b>Type</b></td><td><b>Binding</b></td><td><b>Documentation</b></td></tr><tr><td>IN</td><td>subjectCanonical</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#canonical\\\">canonical</a> (<a href=\\\"StructureDefinition-ViewDefinition.html\\\" title=\\\"http://hl7.org/fhir/StructureDefinition/ViewDefinition\\\">View Definition</a>, <a href=\\\"StructureDefinition-SQLQuery.html\\\" title=\\\"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLQuery\\\">SQL Query Library</a>, <a href=\\\"StructureDefinition-SQLView.html\\\" title=\\\"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLView\\\">SQL View Library</a>)</td><td/><td><div><p>Canonical URL of the ViewDefinition, SQLQuery Library or SQLView Library to execute, optionally with a |version suffix pinning a version. Exactly one of subjectCanonical, subjectReference and subjectResource is supplied; supplying none, or more than one, is rejected with 400 Bad Request.</p>\\n</div></td></tr><tr><td>IN</td><td>subjectReference</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/references.html#Reference\\\">Reference</a> (<a href=\\\"StructureDefinition-ViewDefinition.html\\\" title=\\\"http://hl7.org/fhir/StructureDefinition/ViewDefinition\\\">View Definition</a>, <a href=\\\"StructureDefinition-SQLQuery.html\\\" title=\\\"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLQuery\\\">SQL Query Library</a>, <a href=\\\"StructureDefinition-SQLView.html\\\" title=\\\"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLView\\\">SQL View Library</a>)</td><td/><td><div><p>Literal location of the subject to execute: a relative URL on this server, or an absolute URL. Not a canonical URL; use subjectCanonical for that. Exactly one of subjectCanonical, subjectReference and subjectResource is supplied; supplying none, or more than one, is rejected with 400 Bad Request.</p>\\n</div></td></tr><tr><td>IN</td><td>subjectResource</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/canonicalresource.html\\\">CanonicalResource</a> (<a href=\\\"StructureDefinition-ViewDefinition.html\\\" title=\\\"http://hl7.org/fhir/StructureDefinition/ViewDefinition\\\">View Definition</a>, <a href=\\\"StructureDefinition-SQLQuery.html\\\" title=\\\"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLQuery\\\">SQL Query Library</a>, <a href=\\\"StructureDefinition-SQLView.html\\\" title=\\\"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLView\\\">SQL View Library</a>)</td><td/><td><div><p>Inline ViewDefinition, SQLQuery Library or SQLView Library to execute. Exactly one of subjectCanonical, subjectReference and subjectResource is supplied; supplying none, or more than one, is rejected with 400 Bad Request. Carries a resource, so it requires POST. The declared type is CanonicalResource because ViewDefinition is a logical model rather than a FHIR resource; see Common Operation Behavior (operations-common.html#declared-type).</p>\\n</div></td></tr><tr><td>IN</td><td>parameters</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/parameters.html\\\">Parameters</a></td><td/><td><div><p>Input parameter values for the subject, bound by name to the parameters the Library declares (Library.parameter.name), using the value[x] type matching each declared type. Permitted only where the subject is a SQLQuery or SQLView; supplying it where the subject is a ViewDefinition is rejected with 400 Bad Request, because a ViewDefinition declares no parameters. Carries a resource, so it requires POST.</p>\\n</div></td></tr><tr><td>IN</td><td>context</td><td/><td>0..*</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/canonicalresource.html\\\">CanonicalResource</a> (<a href=\\\"StructureDefinition-ViewDefinition.html\\\" title=\\\"http://hl7.org/fhir/StructureDefinition/ViewDefinition\\\">View Definition</a>, <a href=\\\"StructureDefinition-SQLView.html\\\" title=\\\"http://hl7.org/fhir/uv/sql-on-fhir/StructureDefinition/SQLView\\\">SQL View Library</a>)</td><td/><td><div><p>Supporting artifacts the server cannot itself resolve, supplied inline and matched by canonical URL against the dependencies in the subject's transitive relatedArtifact graph. Accepts inline resources only; there is no context by canonical URL, because a URL is exactly what the server has already failed to resolve. Carries a resource, so it requires POST. See Common Operation Behavior (operations-common.html#context).</p>\\n</div></td></tr><tr><td>IN</td><td>resource</td><td/><td>0..*</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/resource.html\\\">Resource</a></td><td/><td><div><p>FHIR resources to transform instead of using server data. Repeatable. A Bundle supplied here is unwrapped: the view runs against each Bundle.entry[*].resource rather than against the Bundle itself. Permitted only where the subject is a ViewDefinition; supplying it where the subject is a SQLQuery or SQLView is rejected with 400 Bad Request, because how inline resources reach each dependency view is not specified. Carries a resource, so it requires POST. See OperationDefinition-SQLRun notes (Resource parameter and Bundle inputs).</p>\\n</div></td></tr><tr><td>IN</td><td>_format</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#code\\\">code</a></td><td><a href=\\\"ValueSet-OutputFormatCodes.html\\\">Output Format Codes</a> (Extensible)</td><td><div><p>Output format for the result (json, ndjson, csv, parquet, fhir). Use fhir to return results as a FHIR Parameters resource. Optional; if omitted, the server returns ndjson by default. See Common Operation Behavior (operations-common.html).</p>\\n</div></td></tr><tr><td>IN</td><td>header</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#boolean\\\">boolean</a></td><td/><td><div><p>Include CSV headers (default true). Applies only when csv output is requested.</p>\\n</div></td></tr><tr><td>IN</td><td>patient</td><td/><td>0..*</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/references.html#Reference\\\">Reference</a></td><td/><td><div><p>Restrict the FHIR resources feeding the view, before projection, to the supplied patient(s). Where the subject is a SQLQuery or SQLView, that means before the SQL executes. An unresolvable patient is rejected with 400 Bad Request. See Common Operation Behavior (operations-common.html#patient-filter).</p>\\n</div></td></tr><tr><td>IN</td><td>group</td><td/><td>0..*</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/references.html#Reference\\\">Reference</a></td><td/><td><div><p>Restrict the FHIR resources feeding the view, before projection, to members of the supplied group(s). Where the subject is a SQLQuery or SQLView, that means before the SQL executes. An unresolvable group is rejected with 400 Bad Request. See Common Operation Behavior (operations-common.html#group-filter).</p>\\n</div></td></tr><tr><td>IN</td><td>_since</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#instant\\\">instant</a></td><td/><td><div><p>Include only resources whose state changed after this instant. See Common Operation Behavior (operations-common.html#since-filter).</p>\\n</div></td></tr><tr><td>IN</td><td>source</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#string\\\">string</a></td><td/><td><div><p>External data source to read from instead of the server's own data (for example a URI or bucket name). Where the subject is a SQLQuery or SQLView, this is where the ViewDefinition tables the query selects from are found.</p>\\n</div></td></tr><tr><td>IN</td><td>_limit</td><td/><td>0..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/datatypes.html#integer\\\">integer</a></td><td/><td><div><p>Maximum number of rows to return.</p>\\n</div></td></tr><tr><td>OUT</td><td>return</td><td/><td>1..1</td><td><a href=\\\"http://hl7.org/fhir/6.0.0-ballot5/binary.html\\\">Binary</a></td><td/><td><div><p>Result rows in the requested output format, returned as a raw binary stream in the format's native media type, not a serialized Binary resource envelope. When _format=fhir is requested, the response is a Parameters resource instead. See Common Operation Behavior (operations-common.html).</p>\\n</div></td></tr></table></div>\",
    \"status\": \"generated\"
  },
  \"title\": \"SQL Run\",
  \"type\": false,
  \"url\": \"http://hl7.org/fhir/uv/sql-on-fhir/OperationDefinition/SQLRun\",
  \"version\": \"3.0.0-ballot\",
  \"versionAlgorithmString\": \"semver\"
}"))
(define (sql-run-operation handler)
  (define code "sql-run")
  (list (operation-entry 'system code #f handler)))
(define operation-definitions
  (list sql-export-definition sql-run-definition))

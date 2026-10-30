# Local MCP App page adapter

This adapter uses the observed MCP App JSON-RPC methods and protocol version
`2026-01-26` in an isolated, network-disabled WKWebView. A separate native
public-JSON resolver now implements the source channel/release contract.
The preview does not yet load remote MCP App releases or publish resources,
and these local checks do not prove compatibility with a cloud tool provider.

Artifact events may carry an optional **local event field** `pageProjection`:

```json
{
  "schemaVersion": 1,
  "revision": {"message_sequence": 7, "part_index": 2},
  "toolInput": {"prompt": "original text"},
  "toolResult": {"summary": "result summary", "items": []}
}
```

The local field name and schema are ClipSlots' artifact event adapter. The
notification names, parameter shapes, sequence comparison, recursive removal
of `media_ref` / `poster_ref`, and use of the result's text `summary` follow the
frozen source host evidence. The original provider call IDs, native execution
messages, tool journal and immutable App reply HTTP bytes remain independent.

The native host supplies the conversation UUID and originating run ID when
accepting the event. These identities cannot come from page parameters.
Projection changes to the same HTML resource must retain that native owner.
Another conversation or run cannot replace them by sending a larger sequence.
The native panel shows projected input and results only in their original
conversation. The HTML artifact itself retains its existing project visibility.

Both sequence fields are nonnegative safe JSON integers, at most
`9007199254740991`. Order compares `message_sequence` first, then `part_index`.
Updates with equal or lower order do not replace the current projection or
write another snapshot. The HTML resource revision is a separate identity:
advancing it clears the old projection; a new resource may start at sequence
zero. Deleting the resource clears the projection and its native owner.

After `ui/notifications/initialized`, the host sends:

- `ui/notifications/tool-input` with `arguments`.
- `ui/notifications/tool-result`, when a result exists, with MCP text content
  and `structuredContent`. A persisted native widget object may be included
  as `_meta["tapnow/widgetState"]`.

Later source data changes use `tapnow/updateData` with `toolInput`,
`toolResult` and `revision`. A missing result is explicit `null`; it never
inherits a previous message's result. Duplicate initialization does not
replay the initial notifications.

The local projection envelope has a 32 KiB UTF-8 encoded budget, at most 8192
value nodes and depth 32. Native notifications have a 72 KiB encoded budget.
An invalid or oversized projection fails before loading the page. A notification
that exceeds its budget fails the resource visibly instead of truncating text.
These are local host budgets, not claimed source provider limits.

A projected MCP resource starts its 15-second initialization deadline on load,
including a page that never sends `ui/initialize`. Discovery or initialize also
starts the deadline for a legacy resource using JSON-RPC. Plain private-bridge
HTML retains its existing navigation-ready behavior. Discovery retries use the
observed 800 ms interval.

Blocked subresources, navigation failures, timeout and WebContent termination
put the instance in a failed state and cancel outstanding native requests.
Both JSON-RPC and the private tool bridge reject further requests. A late
initialized notification cannot restore readiness. Explicit WebKit reload
recreates the in-memory document, rotates nonce and request caches, and
reinitializes from current native data. Detach removes authority and cancels
timers; asynchronous notifications check the destination document's nonce.

The source controller returns native asynchronous `running` and `completion`
promises. Its wrapper exposes only `reply_id`, `run_id` and `deduped` in the
JSON-RPC response. The local adapter uses native observation streams for those
promises; it does not serialize a Promise or use acceptance as stream activity.

Only a validated SSE frame for the pinned gateway binding and run resolves
activity. Local phase publication, HTTP headers, acceptance receipts and status
readback do not resolve it. A repeated valid replay frame may prove activity,
but duplicate, malformed or foreign frames cannot alter persisted output.
The page receives `tapnow/updateData` with the exact reply ID and
`reply_run_status: "running"` once. Stream completion sends that same notification
with `"completed"` for a proven completed run, plus `tapnow/appReplyStatus`
with `status: "applied"`. Other outcomes retain `"failed"`, `"waiting"` or
`"unknown"`; cancellation or an unproven transport failure never implies success.

The source wrapper was also inspected in the separately identified shipped
bundle `2026.10.29.40868239083.1`. Its static consumer maps `"applied"` to
`"completed"` for run status, retains the completion outcome for reply status,
and derives `conversation_run_active` from the owning conversation's loading
state. This identity is separate from the earlier S23 source bundle.
The local page receives the current native conversation activity on initialization
and changes, including completion of an observed reply run.

The native submission owner performs HTTP once. Concurrent requests and new
RPC IDs for the same immutable reply wait on or reuse its original Promise.
Reusing a reply ID with changed submission bytes or another origin is rejected.
Failed Promises leave the cache; the durable acceptance ledger still prevents
automatic resubmission of an attempted unknown reply.
`tapnow/getAppReplyRunStatus` returns the source string status: `"running"`,
`"waiting"`, `"inactive"` for a known terminal run, or `"unknown"`.
Detailed acceptance and phase fields remain in native recovery records.

Each observer pins native page identity, origin, run, runtime epoch and document
nonce. Close, reload, permission loss, resource failure or conversation replacement
ends observation. Late completion cannot notify a new document or another
conversation. The native run may finish after a page closes; page disposal does
not turn that completion into a new submission.

An artifact event may additionally declare `pageResourceURI`, with the source
grammar `ui://tapnow/<lowercase-name>@v<digits>`. This optional local event
field requires a valid projection and native conversation owner. It does not
add cloud tool permissions. Existing snapshots omit it safely. A same-revision
resource identity conflict is rejected; advancing or deleting content clears
the old identity. The panel only uses the declared identity in its owning
conversation, and ready metadata does not invent a release hash.

Tracked local presentation sends `tapnow/presentationState` after tool input
and result. Changes are deduplicated, reload replays current state, and host
context uses `inline` / `fullscreen`. Native size notifications require a
finite positive number. The panel applies source default policies, including
picker height 520 and previs/animatic auto-expansion, with bounded native
geometry. Expanding and collapsing preserve the same mounted WebKit document
and draft. Resource failure revokes layout and shortcut delivery.

Ready expanded previs pages can receive `tapnow/presentationShortcut`.
The local DOM key bridge excludes synthetic events, editable controls, marked
text signals, modified keys and repeated Enter. Escape calls native collapse.
These guards and offscreen lifecycle checks do not prove system IME or
foreground keyboard behavior.

The separate resolver validates channel/release schemas and identities and
the eight-character widget build identifier; the identifier is not a content
SHA digest. It filters CSP domains using the frozen source allowlist.
Channel TTL is 60 seconds; transient errors retry after 5 seconds; 404 uses
channel TTL. Successful releases retain infinite TTL with a native bounded
entry cache. Concurrent and prefetch requests share work, while cancelled
consumers cannot apply a late result or cancel a peer. Public JSON requests
omit cookies and credentials, reject redirects, and enforce timeout and body
limits. Explicit loopback access is available to local HTTP tests.

Remote release loading/CSP enforcement and full foreground presentation,
system IME, source visual parity and actual provider business verification
remain separate unaccepted work.

# LibreChat Code Execution Environment Specification

This document describes the API contract and runtime requirements for a code execution service that is fully
compatible with [LibreChat](https://librechat.ai)'s **Run Code** tool.
It also explains how the code execution "sessions" are tied to a chat discussion in LibreChat's database and
how input/output files—images, CSVs, audio, etc.—are handled and rendered.

## 1. Architecture Overview

LibreChat communicates with a remote sandbox via a REST API.  Each execution takes place in an isolated
environment identified by a `session_id`.  The `session_id` links all file operations for a chat message and is
stored in the message's metadata inside the conversation record.  Files created in a session may be attached to
messages and referenced in later runs.

```
User message ──► LibreChat ──► Code Execution API ──► sandbox
                                     ▲
                                     └── files & stdout/stderr
```

### Working directory

* Runtime starts in `/mnt/data` with read‑only base filesystem.
* Programs may create new files anywhere under `/mnt/data`.
* Outbound network access **must be disabled**.
* Resource limits (CPU, RAM, wall‑clock) must be enforced per run.

## 2. API Contract

All endpoints require header `X-API-Key` with a token issued by the sandbox service.  LibreChat provides the
value through `LIBRECHAT_CODE_API_KEY` or a user‑supplied key.  The base URL defaults to
`https://code.librechat.ai` but can be overridden with `LIBRECHAT_CODE_BASEURL`.

### 2.1 `POST /exec`
Run code within the sandbox.

**Request body**
```json
{
  "lang": "py",                  // one of: py, js, ts, c, cpp, java, php, rs, go, d, f90, r
  "code": "print('hi')",          // user code
  "args": "--flag",              // optional runtime args
  "session_id": "<id>",          // optional existing session to reuse uploaded files
  "files": [ {"id":"<fileId>", "name": "input.txt"} ] // optional previously uploaded files
}
```

**Response body**
```json
{
  "stdout": "hello\n",
  "stderr": "",
  "session_id": "<id>",
  "files": [ {"name":"plot.png","size":24567} ]
}
```
* `session_id` is newly created when omitted in the request.
* `files` lists artifacts generated during execution located under `/mnt/data`.

### 2.2 `POST /upload`
Upload a user file so that subsequent executions can consume it.

* Content type: `multipart/form-data`
* Fields:
  * `file` – binary payload.
  * `entity_id` – optional identifier to associate the upload with an existing message.
* Response:
```json
{
  "message": "success",
  "session_id": "<id>",
  "files": [ {"fileId":"<fid>", "filename":"data.csv"} ]
}
```
* LibreChat records `session_id/fileId` as the file identifier in message attachments.

### 2.3 `GET /files/{session_id}`
List files for a session.  Optional query `detail=full|summary`.
The result informs LibreChat of existing artifacts when resuming a session.

### 2.4 `GET /download/{session_id}/{fileId}`
Download an artifact as binary.  LibreChat proxies this through its own `/api/files/code/download/...` route so
that files can be served to the client or persisted in its own storage.

## 3. Session ↔ Conversation linkage

1. When a user invokes the **Run Code** tool, the returned `session_id` is stored with the assistant message in
   LibreChat's database (e.g. `message.code_session_id`).
2. Output files are processed via the server's `processCodeOutput` routine which:
   * Converts image outputs to the configured format and saves them to the main file store so that they persist
     beyond the sandbox's 24‑hour TTL.
   * Records file metadata (`file_id`, `filename`, `session_id/fileId`) on the message document.
   * Non‑image files are left in the sandbox and referenced through the `/api/files/code/download/...` proxy.
3. On subsequent executions in the same conversation, LibreChat re‑uploads previous attachments (if the sandbox
   has expired) and passes the resulting `session_id/fileId` pairs in the `files` array so the runtime can access
   them.

Sessions should be garbage‑collected roughly 24 hours after creation.  Conversations will continue to hold
references, but downloading a file after expiry will fail.

## 4. File handling and rendering

LibreChat inspects file extensions to decide how to present results:

| Type            | Behaviour in UI |
|-----------------|-----------------|
| Images (`.png`, `.jpg`, etc.) | Displayed inline within the chat; also persisted to LibreChat's own file store for permanent access. |
| CSV / TSV       | Previewed as an interactive table with option to download the raw file. |
| JSON / text     | Rendered in a code block; download link provided. |
| PDFs            | Shown via in‑browser viewer where supported, otherwise offered as download. |
| Audio (`.mp3`, `.wav`, …) | Embedded `<audio>` player allows immediate playback.  LibreChat may also offer to attach the audio as input to subsequent model calls if the selected model accepts audio. |
| Other binaries  | Download link only. |

Uploaded input files follow the same detection logic so users can preview what was supplied to the sandbox.

## 5. Extended media capabilities

The code environment can generate diverse media types.  LibreChat can optionally
utilize them beyond simple download links:

* **Images** – Used as inline chat content or as references for vision‑capable models.
* **Audio** – When the active model supports audio input, LibreChat may suggest using generated audio as a
  follow‑up prompt attachment.  Otherwise the user can simply play the file.
* **Data files (CSV, XLSX)** – Can be offered as context to later prompts or opened in a built‑in preview.
* **Arbitrary binaries** – Users can download and manage them manually.

## 6. Security & Isolation

* Sandbox must run each `exec` call in a fresh process or container.
* Disallow outbound networking and limit inbound traffic to the API layer.
* Enforce per‑run limits (CPU, RAM, file system quota, execution time) to prevent abuse.
* Clean up processes and temporary files after execution or session expiry.

## 7. Lifecycle of a typical run

1. User writes a message and activates **Run Code**.
2. LibreChat uploads any user‑supplied files (`POST /upload`).
3. LibreChat calls `POST /exec` with code, referencing uploaded files and the current `session_id` if any.
4. Sandbox executes and returns `stdout`, `stderr`, and file metadata.
5. LibreChat stores the `session_id` and persists any image outputs; other files remain in the sandbox and can be
   downloaded through LibreChat's proxy.
6. The assistant message displays `stdout` plus rendered attachments.
7. Subsequent runs in the same conversation reuse the `session_id` so previous files remain available.

---
A service implementing the above interface and behaviour can replace LibreChat's hosted code execution API,
allowing self‑hosted or custom sandboxes to integrate seamlessly.

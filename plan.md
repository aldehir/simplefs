# simplefs — network filesystem over TCP, in Zig

A FUSE filesystem where a **server** exports a local directory over TCP and a
**client** on another machine mounts it. All operations (read + write) go over
the wire, so changes are bidirectional by nature: writes on the mount land in
the served directory, and changes in the served directory are visible on the
mount (subject to cache timeouts, see Caching).

```
[local]  simplefs serve ~/shared --listen 0.0.0.0:7070
             ^
             | TCP (later: tunneled through ssh)
             v
[remote] simplefs mount local-host:7070 /mnt/shared
```

Note on "over sshfs": sshfs is itself a FUSE-over-sftp filesystem, so this
would replace it rather than layer on it. What you likely want is running the
transport over ssh — the design keeps the transport pluggable (TCP now, stdio
later) so the client can eventually spawn `ssh host simplefs serve --stdio`
exactly the way sshfs spawns sftp.

## Environment

- Zig 0.16.0 (new `std.Io` reader/writer API applies)
- fuse3 runtime + `fusermount3` installed; `fuse3-devel` is **not**

## Key decision: raw /dev/fuse, no libfuse

Speak the FUSE kernel wire protocol directly from Zig instead of binding
libfuse:

- No C dependency → a single static binary you can `scp` to any remote box
  (important since the client runs on remote machines)
- `fuse3-devel` isn't installed anyway; only `fusermount3` (setuid mount
  helper, present in the base fuse3 package) is needed at runtime
- The protocol is stable and well-documented (`linux/fuse.h`); Zig makes the
  struct layout easy

Cost: we own INIT negotiation, FORGET tracking, and interrupt handling
ourselves. Fallback if this drags: install `fuse3-devel` and bind the libfuse
low-level API via `@cImport`.

## Components

```
src/
  main.zig          CLI: serve | mount
  proto.zig         wire protocol: message framing, opcodes, (de)serialization
  server.zig        TCP listener, executes ops against the exported dir
  client.zig        connects to server, issues requests, matches responses
  fuse/
    kernel.zig      FUSE kernel ABI structs/opcodes (from linux/fuse.h)
    session.zig     mount via fusermount3, /dev/fuse read/dispatch/reply loop
  fs.zig            client-side glue: FUSE request -> proto request -> reply
build.zig
```

## Wire protocol (proto.zig)

Binary, length-prefixed frames, request/response with IDs so responses can
return out of order later (start strictly serial, design allows async):

```
frame  := len:u32 | id:u64 | opcode:u16 | body
```

Handle-based, mirroring FUSE lowlevel semantics (not path-based — avoids
rename races and maps 1:1 onto FUSE requests):

- Identity: server-assigned `node_id:u64` (server keeps node table mapping
  node_id -> O_PATH fd or path); root = 1
- Ops (v1): `HELLO` (version handshake), `LOOKUP`, `GETATTR`, `SETATTR`,
  `READDIR`, `OPEN`, `CREATE`, `READ`, `WRITE`, `RELEASE`, `FLUSH`, `FSYNC`,
  `MKDIR`, `UNLINK`, `RMDIR`, `RENAME`, `SYMLINK`, `READLINK`, `STATFS`,
  `FORGET`
- Errors: negative errno in a status field, passed through to FUSE verbatim

## Server

- `std.net` TCP listener, one connection = one mount session (v1: single
  client; multi-client later)
- Node table: `node_id -> O_PATH fd`. Using O_PATH fds (openat/fstatat
  relative to them) keeps operations race-free and confines everything to the
  export root — never resolve client-supplied absolute paths
- Open-file table: `fh -> fd` for READ/WRITE/RELEASE
- v1 loop: read frame -> execute syscall -> reply. No threads needed until
  perf work

## Client (FUSE side)

- `session.zig`: fork/exec `fusermount3 -o rw,fsname=simplefs /mnt/point`,
  receive the /dev/fuse fd over the unix socket (`_FUSE_COMMFD` protocol),
  then loop: read kernel request -> dispatch -> write reply
- INIT: negotiate protocol 7.31+, conservative flags (no writeback cache in
  v1)
- Each FUSE op maps to one proto op; node_ids and fhs from the server are
  passed to the kernel as-is (no client-side table needed)
- FORGET is forwarded so the server can drop node-table entries

## Caching / bidirectionality

- v1: `entry_timeout = attr_timeout = 0`, direct_io off but no writeback
  cache. Correctness first: every lookup/getattr hits the server, so local
  edits on the server side are visible on next access
- Later: small timeouts (~1s) for perf, then inotify on the server pushing
  `NOTIFY_INVAL_ENTRY`/`NOTIFY_INVAL_INODE` to the client for real coherence

## Security

- v1 has **no auth or encryption** — bind to 127.0.0.1 by default and treat
  the ssh transport (M6) as the real security story
- Server never escapes the export root (O_PATH + `openat`, reject `..`
  in names — names in the protocol are single path components, never paths)

## Milestones

1. **Protocol + server, no FUSE.** proto.zig + server.zig + a `simplefs dbg`
   command that does lookup/readdir/read over TCP. Testable with plain Zig
   tests against a tmp dir.
2. **Read-only mount.** fuse/kernel.zig, fuse/session.zig (mount, INIT,
   request loop). Implement LOOKUP/GETATTR/READDIR/OPEN/READ/RELEASE/FORGET/
   STATFS. `ls`, `cat`, `find` work on the mount.
3. **Writes.** WRITE/CREATE/MKDIR/UNLINK/RMDIR/RENAME/SETATTR/SYMLINK/
   READLINK/FSYNC/FLUSH. `cp`, `vim`, `git clone` into the mount work.
4. **Robustness.** Clean unmount on ^C/server death (errors -> ENOTCONN, not
   hang), FUSE_INTERRUPT handling, large-file READ/WRITE chunking against
   max_write, permission bits/uid mapping (v1: single-user, map everything to
   the mounting uid).
5. **Integration tests.** Script that serves a tmp dir, mounts on loopback,
   runs a torture script (concurrent writes both sides, rename storms),
   diffs the trees.
6. **ssh transport.** `--stdio` mode on the server; client gains
   `simplefs mount user@host:/dir /mnt` which spawns
   `ssh user@host simplefs serve /dir --stdio`. TCP and stdio share one
   transport interface.
7. **Perf (later).** Attr/entry timeouts, readahead, parallel in-flight
   requests (the id field already allows it), inotify-based invalidation.

## Risks

- FUSE kernel ABI fiddliness (padding, version drift) — mitigate by pinning
  minimum protocol 7.31 and testing on this kernel (6.14) first
- fusermount3 fd-passing handshake is under-documented — crib from libfuse
  source (`lib/mount.c`)
- Zig 0.16 std.Io churn — isolate socket/file IO behind thin helpers

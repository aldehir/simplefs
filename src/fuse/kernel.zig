const std = @import("std");

pub const kernel_version = 7;
pub const kernel_minor_version = 31;

pub const Opcode = enum(u32) {
    lookup = 1,
    forget = 2,
    getattr = 3,
    setattr = 4,
    readlink = 5,
    symlink = 6,
    mknod = 8,
    mkdir = 9,
    unlink = 10,
    rmdir = 11,
    rename = 12,
    link = 13,
    open = 14,
    read = 15,
    write = 16,
    statfs = 17,
    release = 18,
    fsync = 20,
    setxattr = 21,
    getxattr = 22,
    listxattr = 23,
    removexattr = 24,
    flush = 25,
    init = 26,
    opendir = 27,
    readdir = 28,
    releasedir = 29,
    fsyncdir = 30,
    getlk = 31,
    setlk = 32,
    setlkw = 33,
    access = 34,
    create = 35,
    interrupt = 36,
    bmap = 37,
    destroy = 38,
    ioctl = 39,
    poll = 40,
    notify_reply = 41,
    batch_forget = 42,
    fallocate = 43,
    readdirplus = 44,
    rename2 = 45,
    lseek = 46,
    copy_file_range = 47,
    setupmapping = 48,
    removemapping = 49,
    syncfs = 50,
    tmpfile = 51,
    statx = 52,
    _,
};

pub const InHeader = extern struct {
    len: u32,
    opcode: u32,
    unique: u64,
    nodeid: u64,
    uid: u32,
    gid: u32,
    pid: u32,
    total_extlen: u16,
    padding: u16,
};

pub const OutHeader = extern struct {
    len: u32,
    @"error": i32,
    unique: u64,
};

pub const Attr = extern struct {
    ino: u64,
    size: u64,
    blocks: u64,
    atime: u64,
    mtime: u64,
    ctime: u64,
    atimensec: u32,
    mtimensec: u32,
    ctimensec: u32,
    mode: u32,
    nlink: u32,
    uid: u32,
    gid: u32,
    rdev: u32,
    blksize: u32,
    flags: u32,
};

pub const EntryOut = extern struct {
    nodeid: u64,
    generation: u64,
    entry_valid: u64,
    attr_valid: u64,
    entry_valid_nsec: u32,
    attr_valid_nsec: u32,
    attr: Attr,
};

pub const ForgetIn = extern struct {
    nlookup: u64,
};

pub const ForgetOne = extern struct {
    nodeid: u64,
    nlookup: u64,
};

pub const BatchForgetIn = extern struct {
    count: u32,
    dummy: u32,
};

pub const GetattrIn = extern struct {
    getattr_flags: u32,
    dummy: u32,
    fh: u64,
};

pub const AttrOut = extern struct {
    attr_valid: u64,
    attr_valid_nsec: u32,
    dummy: u32,
    attr: Attr,
};

pub const MknodIn = extern struct {
    mode: u32,
    rdev: u32,
    umask: u32,
    padding: u32,
};

pub const MkdirIn = extern struct {
    mode: u32,
    umask: u32,
};

pub const RenameIn = extern struct {
    newdir: u64,
};

pub const Rename2In = extern struct {
    newdir: u64,
    flags: u32,
    padding: u32,
};

pub const SetattrIn = extern struct {
    valid: u32,
    padding: u32,
    fh: u64,
    size: u64,
    lock_owner: u64,
    atime: u64,
    mtime: u64,
    ctime: u64,
    atimensec: u32,
    mtimensec: u32,
    ctimensec: u32,
    mode: u32,
    unused4: u32,
    uid: u32,
    gid: u32,
    unused5: u32,
};

pub const fattr_mode: u32 = 1 << 0;
pub const fattr_uid: u32 = 1 << 1;
pub const fattr_gid: u32 = 1 << 2;
pub const fattr_size: u32 = 1 << 3;
pub const fattr_atime: u32 = 1 << 4;
pub const fattr_mtime: u32 = 1 << 5;
pub const fattr_fh: u32 = 1 << 6;
pub const fattr_atime_now: u32 = 1 << 7;
pub const fattr_mtime_now: u32 = 1 << 8;
pub const fattr_lockowner: u32 = 1 << 9;
pub const fattr_ctime: u32 = 1 << 10;

pub const OpenIn = extern struct {
    flags: u32,
    open_flags: u32,
};

pub const CreateIn = extern struct {
    flags: u32,
    mode: u32,
    umask: u32,
    open_flags: u32,
};

pub const OpenOut = extern struct {
    fh: u64,
    open_flags: u32,
    backing_id: i32,
};

pub const fopen_direct_io: u32 = 1 << 0;
pub const fopen_keep_cache: u32 = 1 << 1;

pub const ReleaseIn = extern struct {
    fh: u64,
    flags: u32,
    release_flags: u32,
    lock_owner: u64,
};

pub const FlushIn = extern struct {
    fh: u64,
    unused: u32,
    padding: u32,
    lock_owner: u64,
};

pub const ReadIn = extern struct {
    fh: u64,
    offset: u64,
    size: u32,
    read_flags: u32,
    lock_owner: u64,
    flags: u32,
    padding: u32,
};

pub const WriteIn = extern struct {
    fh: u64,
    offset: u64,
    size: u32,
    write_flags: u32,
    lock_owner: u64,
    flags: u32,
    padding: u32,
};

pub const WriteOut = extern struct {
    size: u32,
    padding: u32,
};

pub const Kstatfs = extern struct {
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    bsize: u32,
    namelen: u32,
    frsize: u32,
    padding: u32,
    spare: [6]u32,
};

pub const StatfsOut = extern struct {
    st: Kstatfs,
};

pub const FsyncIn = extern struct {
    fh: u64,
    fsync_flags: u32,
    padding: u32,
};

pub const AccessIn = extern struct {
    mask: u32,
    padding: u32,
};

pub const InitIn = extern struct {
    major: u32,
    minor: u32,
    max_readahead: u32,
    flags: u32,
    flags2: u32,
    unused: [11]u32,
};

pub const InitOut = extern struct {
    major: u32,
    minor: u32,
    max_readahead: u32,
    flags: u32,
    max_background: u16,
    congestion_threshold: u16,
    max_write: u32,
    time_gran: u32,
    max_pages: u16,
    map_alignment: u16,
    flags2: u32,
    max_stack_depth: u32,
    unused: [6]u32,
};

pub const init_async_read: u32 = 1 << 0;
pub const init_atomic_o_trunc: u32 = 1 << 3;
pub const init_big_writes: u32 = 1 << 5;
pub const init_dont_mask: u32 = 1 << 6;
pub const init_parallel_dirops: u32 = 1 << 18;
pub const init_max_pages: u32 = 1 << 22;

pub const InterruptIn = extern struct {
    unique: u64,
};

pub const Dirent = extern struct {
    ino: u64,
    off: u64,
    namelen: u32,
    type: u32,
};

pub const LseekIn = extern struct {
    fh: u64,
    offset: u64,
    whence: u32,
    padding: u32,
};

pub const LseekOut = extern struct {
    offset: u64,
};

pub fn direntAlign(x: usize) usize {
    return (x + 7) & ~@as(usize, 7);
}

test "abi sizes" {
    try std.testing.expectEqual(40, @sizeOf(InHeader));
    try std.testing.expectEqual(16, @sizeOf(OutHeader));
    try std.testing.expectEqual(88, @sizeOf(Attr));
    try std.testing.expectEqual(128, @sizeOf(EntryOut));
    try std.testing.expectEqual(104, @sizeOf(AttrOut));
    try std.testing.expectEqual(64, @sizeOf(InitOut));
    try std.testing.expectEqual(64, @sizeOf(InitIn));
    try std.testing.expectEqual(88, @sizeOf(SetattrIn));
    try std.testing.expectEqual(40, @sizeOf(ReadIn));
    try std.testing.expectEqual(40, @sizeOf(WriteIn));
    try std.testing.expectEqual(80, @sizeOf(StatfsOut));
    try std.testing.expectEqual(24, @sizeOf(Dirent));
}

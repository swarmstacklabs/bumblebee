## Zig Interfaces Guide: Database Implementations

This guide shows a safe Zig pattern for runtime interfaces when you need one selected implementation, for example:

- SQLite database
- PostgreSQL database
- in-memory test database
- mock database
- different storage backends

The goal:

```zig
const db = try sqlite.create(allocator, "app.db");
defer db.destroy();

try db.exec("CREATE TABLE users (id INTEGER)");
```

Application code depends only on:

```zig
*Db
```

not on

```zig
SQLiteDb
PostgresDb
MemoryDb
```

### Interface definition

```zig
pub const Db = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        exec: *const fn (*Db, []const u8) anyerror!void,
        queryOneInt: *const fn (*Db, []const u8) anyerror!i64,
        destroy: *const fn (*Db) void,
    };

    pub fn exec(self: *Db, sql: []const u8) !void {
        return self.vtable.exec(self, sql);
    }

    pub fn queryOneInt(self: *Db, sql: []const u8) !i64 {
        return self.vtable.queryOneInt(self, sql);
    }

    pub fn destroy(self: *Db) void {
        return self.vtable.destroy(self);
    }
};
```

#### SQLite implementation

```zig
const std = @import("std");
const Db = @import("db.zig").Db;

const SQLiteDb = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    interface: Db,

    const vtable = Db.VTable{
        .exec = exec,
        .queryOneInt = queryOneInt,
        .destroy = destroy,
    };

    pub fn create(
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !*Db {
        const self = try allocator.create(SQLiteDb);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .path = path,
            .interface = .{
                .vtable = &vtable,
            },
        };

        return &self.interface;
    }

    fn fromDb(db: *Db) *SQLiteDb {
        return @fieldParentPtr("interface", db);
    }

    fn exec(db: *Db, sql: []const u8) !void {
        const self = fromDb(db);
        std.debug.print("[sqlite:{s}] exec: {s}\n", .{ self.path, sql });
    }

    fn queryOneInt(db: *Db, sql: []const u8) !i64 {
        const self = fromDb(db);
        std.debug.print("[sqlite:{s}] query: {s}\n", .{ self.path, sql });
        return 42;
    }

    fn destroy(db: *Db) void {
        const self = fromDb(db);
        self.allocator.destroy(self);
    }
};

pub const create = SQLiteDb.create;
```

#### PostgreSQL implementation

```zig
const std = @import("std");
const Db = @import("db.zig").Db;

const PostgresDb = struct {
    allocator: std.mem.Allocator,
    conn_string: []const u8,
    interface: Db,

    const vtable = Db.VTable{
        .exec = exec,
        .queryOneInt = queryOneInt,
        .destroy = destroy,
    };

    pub fn create(
        allocator: std.mem.Allocator,
        conn_string: []const u8,
    ) !*Db {
        const self = try allocator.create(PostgresDb);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .conn_string = conn_string,
            .interface = .{
                .vtable = &vtable,
            },
        };

        return &self.interface;
    }

    fn fromDb(db: *Db) *PostgresDb {
        return @fieldParentPtr("interface", db);
    }

    fn exec(db: *Db, sql: []const u8) !void {
        const self = fromDb(db);
        std.debug.print("[postgres:{s}] exec: {s}\n", .{ self.conn_string, sql });
    }

    fn queryOneInt(db: *Db, sql: []const u8) !i64 {
        const self = fromDb(db);
        std.debug.print("[postgres:{s}] query: {s}\n", .{ self.conn_string, sql });
        return 100;
    }

    fn destroy(db: *Db) void {
        const self = fromDb(db);
        self.allocator.destroy(self);
    }
};

pub const create = PostgresDb.create;
```

### Application code

```zig
const std = @import("std");
const Db = @import("db.zig").Db;
const sqlite = @import("sqlite.zig");
const postgres = @import("postgres.zig");

fn runMigrations(db: *Db) !void {
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS users (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL
        \\)
    );

    const count = try db.queryOneInt("SELECT COUNT(*) FROM users");
    std.debug.print("users count = {d}\n", .{count});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const db = try sqlite.create(allocator, "app.db");
    defer db.destroy();

    try runMigrations(db);
}
```

To switch implementation:

```zig
const db = try postgres.create(
    allocator,
    "postgres://localhost/mydb",
);
```

Nothing else changes.

### Why this is safe

Avoid:

```zig
pub fn init(...) SQLiteDb
```

because it allows accidental copies:

```zig
var a = SQLiteDb.init(...);
var b = a; // dangerous
```

The embedded interface points back to the parent object:

```zig
interface: Db
```

and implementation functions recover the real type using:

```zig
@fieldParentPtr("interface", db)
```

This pattern makes it stable by:

```zig
const self = try allocator.create(SQLiteDb);
return &self.interface;
```

User code never sees SQLiteDb, only *Db.

### Recommended rule

For runtime interfaces with embedded interface fields:

```zig
interface: Db
```

prefer:

```zig
pub fn create(...) !*Db
```

and avoid:

```zig
pub fn init(...) ConcreteDb
```

### Singleton pattern

If your application should have only one active database, create an app container.

app.zig

```zig
const std = @import("std");
const Db = @import("db.zig").Db;
const sqlite = @import("sqlite.zig");

pub const App = struct {
    allocator: std.mem.Allocator,
    db: *Db,

    pub fn init(allocator: std.mem.Allocator) !App {
        const db = try sqlite.create(allocator, "app.db");

        return .{
            .allocator = allocator,
            .db = db,
        };
    }

    pub fn deinit(self: *App) void {
        self.db.destroy();
    }
};
```
Usage:

```zig
var app = try App.init(allocator);
defer app.deinit();

try app.db.exec("SELECT 1");
```
This gives you a practical singleton:

```
app.db
```

You still avoid globals, and tests can inject another implementation.

### Test implementation


```zig
const std = @import("std");
const Db = @import("db.zig").Db;

const MemoryDb = struct {
    allocator: std.mem.Allocator,
    interface: Db,
    exec_count: usize,

    const vtable = Db.VTable{
        .exec = exec,
        .queryOneInt = queryOneInt,
        .destroy = destroy,
    };

    pub fn create(allocator: std.mem.Allocator) !*Db {
        const self = try allocator.create(MemoryDb);

        self.* = .{
            .allocator = allocator,
            .interface = .{
                .vtable = &vtable,
            },
            .exec_count = 0,
        };

        return &self.interface;
    }

    fn fromDb(db: *Db) *MemoryDb {
        return @fieldParentPtr("interface", db);
    }

    fn exec(db: *Db, sql: []const u8) !void {
        _ = sql;
        const self = fromDb(db);
        self.exec_count += 1;
    }

    fn queryOneInt(db: *Db, sql: []const u8) !i64 {
        _ = db;
        _ = sql;
        return 0;
    }

    fn destroy(db: *Db) void {
        const self = fromDb(db);
        self.allocator.destroy(self);
    }
};

pub const create = MemoryDb.create;
```
Test code can use:

```zig
const db = try memory.create(allocator);
defer db.destroy();

try runMigrations(db);
```

### When to use this pattern

Use it when:

- implementation is selected at runtime
- you need plugins or backends
- you need test mocks
- you need long-lived services
- you want sqlite, postgres, memory, etc. behind one API

Avoid it when:

- implementation is known at compile time
- generic anytype is enough
- no runtime dispatch is needed

For compile-time polymorphism, use:

```zig
fn runMigrations(db: anytype) !void {
    try db.exec("...");
}
```

For runtime polymorphism, use:

```zig
fn runMigrations(db: *Db) !void {
    try db.exec("...");
}
```

### Final recommended layout

```
src/
  main.zig
  app.zig
  db.zig
  db/
    sqlite.zig
    postgres.zig
    memory.zig
```

Main rule:

```
db.zig defines interface
db/sqlite.zig hides SQLiteDb
db/postgres.zig hides PostgresDb
app.zig owns the singleton instance
business logic receives *Db
```

## Improvement plan for this codebase

Use the interface pattern above only where runtime substitution or isolated tests will clearly help. Do not convert pure helpers, parsers, routers, or middleware just to make them look uniform.

### Phase 1: Introduce a database interface

Current code exposes SQLite through `storage.Database` and `*sqlite3`. `storage.App` owns the raw SQLite handle, and repositories prepare SQLite statements directly.

Target layout:

```
src/
  db.zig
  db/
    sqlite.zig
    memory.zig
  storage.zig
  app.zig
```

Plan:

- define `Db` in `src/db.zig`
- move SQLite ownership and migration logic into `src/db/sqlite.zig`
- make `App` own `db: *Db`
- keep `sqlite.create(allocator, path) !*Db`
- add `memory.create(allocator) !*Db` for tests
- update repository constructors to receive `*Db` or a narrow query/executor interface

Start with a small database vtable:

```zig
pub const Db = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        exec: *const fn (*Db, []const u8) anyerror!void,
        prepare: *const fn (*Db, []const u8) anyerror!Statement,
        changes: *const fn (*Db) i64,
        destroy: *const fn (*Db) void,
    };
};
```

Adjust the exact methods while migrating repositories. Prefer a small stable interface over exposing every SQLite operation.

### Phase 2: Decouple repositories from SQLite

Repositories currently depend on concrete SQLite statements. Migrate them incrementally:

- `device_repository.zig`
- `gateways_repository.zig`
- `networks_repository.zig`
- `connectors_repository.zig`
- `events_repository.zig`
- `users_repository.zig`
- LoRaWAN state and metrics repositories

Recommended order:

1. Move shared statement helpers behind the database module.
2. Convert one CRUD repository first, preferably `device_repository.zig`.
3. Add memory-backed or fake tests for that repository.
4. Repeat for the remaining repositories.

Do not rewrite `crud_repository.Interface` first. It already provides compile-time adapter behavior. Fix the storage dependency underneath it before changing the public repository shape.

### Phase 3: Add connector publisher interfaces

`connectors.zig` currently switches on connector kind and opens a TCP stream per publish.

Introduce a `Publisher` interface if connectors need mocks, retries, long-lived connections, or plugin-like runtime behavior:

```zig
pub const Publisher = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        publish: *const fn (*Publisher, []const u8) anyerror!void,
        destroy: *const fn (*Publisher) void,
    };
};
```

Target layout:

```
src/
  connectors.zig
  connectors/
    publisher.zig
    mqtt.zig
    ws.zig
    rabbitmq.zig
    kafka.zig
```

Keep the existing `Kind` parsing and config validation. Only replace the dispatch and lifecycle boundary.

### Phase 4: Add transport interfaces only when tests need them

UDP and HTTP transports are concrete POSIX wrappers. They are good interface candidates, but lower priority than storage.

Consider a `DatagramTransport` only if UDP tests are hard to write without real sockets:

```zig
pub const DatagramTransport = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        fd: *const fn (*DatagramTransport) std.posix.socket_t,
        recvFrom: *const fn (*DatagramTransport, []u8) anyerror!?Datagram,
        sendTo: *const fn (*DatagramTransport, *const std.posix.sockaddr.in, std.posix.socklen_t, []const u8) anyerror!void,
        destroy: *const fn (*DatagramTransport) void,
    };
};
```

This would let `udp.Server` depend on transport behavior instead of `udp_transport.Socket`.

### Phase 5: Keep pure modules concrete

Do not add runtime interfaces to:

- LoRaWAN codec and packet parsing
- HTTP and LoRa routers
- middleware chains
- JSON encoding helpers
- small repository query builders

Use plain functions or `anytype` for those. Runtime interfaces should be reserved for long-lived services, selected implementations, external resources, and test doubles.

### Success criteria

The refactor is useful when:

- application code no longer imports SQLite C types
- tests can run repository or service behavior without a real SQLite database
- connectors can be tested without opening network sockets
- `App` remains the singleton owner of long-lived services
- concrete implementations stay hidden behind module-level `create(...) !*Interface` functions

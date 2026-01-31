const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;
const Stack = List;
const assert = std.debug.assert;

const zsmath = @import("zsmath");
const Vector2I = zsmath.Vector2I;

//ui involves going up and down a context tree
//want a struct that is "what you want this context to be"
//and a struct that is an explicit context, pos and size all decided

//Need to make a growing one
pub fn Queue(comptime T: type) type {
    return struct {
        data: []T,
        capacity: usize,
        head: usize,
        tail: usize,
        count: usize,

        const Self = @This();

        pub const empty = blk: {
            const empty_data: []T = undefined;
            empty_data.len = 0;
            const value = Self{
                .data = empty_data,
                .capacity = 0,
                .head = 0,
                .tail = 0,
                .count = 0,
            };
            break :blk value;
        };

        pub fn init(capacity: usize, alloc: Allocator) !Self {
            return Self{
                .data = try alloc.alloc(T, capacity),
                .capacity = capacity,
                .head = 0,
                .tail = 0,
                .count = 0,
            };
        }

        pub fn fromSlice(slice: []T, head: u32, tail: u32) Self {
            return Self{
                .data = slice,
                .capacity = slice.len,
                .head = head,
                .tail = tail,
                .count = tail - head,
            };
        }

        pub fn getItems(self: *Self) []T {
            return self.data[self.head..self.tail];
        }

        pub fn isFull(self: *Self) bool {
            return self.count == self.capacity;
        }

        pub fn hadRoomFor(self: *Self, no: u16) bool {
            return self.count + no <= self.capacity;
        }

        pub fn isEmpty(self: *Self) bool {
            return self.count == 0;
        }

        pub fn resize(self: *Self, capacity: usize, alloc: Allocator) !void {
            const new_data = try alloc.alloc(T, capacity);
            if (self.count > 0) {
                const old_data = self.data;
                @memcpy(old_data[self.head..self.tail], new_data[self.head..self.tail]);
                alloc.free(old_data);
            }
            self.data = new_data;
            self.capacity = capacity;
        }

        const init_capacity = @as(comptime_int, @max(1, std.atomic.cache_line / @sizeOf(T)));

        pub fn compNewCapacity(self: *Self, need: usize) usize {
            var new = self.capacity;
            while (new < need) {
                new +|= new / 2 + init_capacity;
            }
            return new;
        }

        pub fn grow(self: *Self, min_amount: usize, alloc: Allocator) !void {
            const new_capacity = self.compNewCapacity(self.capacity + min_amount);
            try self.resize(new_capacity, alloc);
        }

        pub fn enqueue(self: *Self, t: T, alloc: Allocator) !void {
            if (self.isFull()) try self.grow(1, alloc);
            self.data[self.tail] = t;
            self.tail = (self.tail + 1) % self.capacity;
            self.count += 1;
        }

        pub fn enqueueSlice(
            self: *Self,
            alloc: Allocator,
            items: []T,
        ) !void {
            if (items.len == 0) return;
            if (!self.hasRoomFor(items.len)) {
                try self.grow(
                    self.capacity - self.count - items.len,
                    alloc,
                );
            }
            @memcpy(self.data[self.tail..(self.tail + items.len)], items);
            self.tail = (self.tail + items.len) % self.capacity;
            self.count += items.len;
        }

        pub fn dequeue(self: *Self) ?T {
            if (self.isEmpty()) return null;
            const val = self.data[self.head];
            self.head = (self.head + 1) % self.capacity;
            self.count += -1;
            return val;
        }
    };
}

pub const Context = struct {
    pub const invalid = Context{
        .index = (1 << 32) - 1,
    };

    index: u32,

    pub fn init(index: u32) Context {
        assert(index != invalid.index);
        return Context{
            .index = index,
        };
    }

    pub inline fn isValid(self: Context) bool {
        return self.index != comptime invalid.index;
    }
};

pub const InternalContextDataFlags = packed struct {
    valid: bool,
};

pub fn InternalContextData(ContextDataType: type) type {
    return struct {
        const Self = @This();

        pub const empty = Self{
            .context = undefined,
            .parent = .invalid,
            .no_children = 0,
            .child_no = 0,
            .flags = .{
                .valid = false,
            },
        };

        pub const emptyValid = Self{
            .context = undefined,
            .parent = .invalid,
            .no_children = 0,
            .child_no = 0,
            .flags = .{
                .valid = true,
            },
        };

        context: ContextDataType,
        parent: Context,
        no_children: usize,
        child_no: usize,
        flags: InternalContextDataFlags,
    };
}

const ChildNodeRef = struct {
    parent: Context,
    child_no: u32,

    pub inline fn init(parent: Context, child_no: u32) ChildNodeRef {
        return ChildNodeRef{
            .parent = parent,
            .child_no = child_no,
        };
    }
};

pub fn UI(Texture: type) type {
    return struct {
        pub const ContextDataType = ContextData(Texture);

        no_nodes: u32,
        nodes_limit: u32,
        comps: std.MultiArrayList(InternalContextData(ContextDataType)),
        no_leafs: u32,
        root: Context,

        const Self = @This();

        pub fn init(ui: *Self) void {
            ui.no_nodes = 0;
            ui.nodes_limit = 0;
            ui.no_leafs = 0;
            ui.root = .invalid;
            ui.comps = .empty;
        }

        pub fn clear(ui: *Self) void {
            ui.no_nodes = 0;
            ui.nodes_limit = 0;
            ui.no_leafs = 0;
            ui.comps.clearRetainingCapacity();
        }

        pub fn deinit(ui: *Self, alloc: Allocator) void {
            ui.comps.deinit(alloc);
        }

        fn getContextRef(ui: *Self, alloc: Allocator) !Context {
            if (ui.no_nodes == ui.nodes_limit) {
                try ui.comps.append(alloc, .emptyValid);
                ui.nodes_limit += 1;
                ui.no_nodes += 1;
                return Context.init(ui.nodes_limit - 1);
            }
            for (ui.comps.items(.flags)[0..ui.nodes_limit], 0..) |flags, index| {
                if (!flags.valid) {
                    ui.no_nodes += 1;
                    return Context.init(@intCast(index));
                }
            }
            unreachable;
        }

        pub fn addContext(ui: *Self, parent: Context, child: ContextDataType, alloc: Allocator) !Context {
            const context = try ui.getContextRef(alloc);
            const comps = ui.comps;
            comps.items(.context)[context.index] = child;
            comps.items(.parent)[context.index] = parent;
            ui.no_leafs += 1;
            const parent_no_children = comps.items(.no_children)[parent.index];
            comps.items(.child_no)[context.index] = parent_no_children;
            if (parent_no_children == 0) ui.no_leafs -= 1;
            comps.items(.no_children)[parent.index] += 1;
            return context;
        }

        pub fn addRoot(ui: *Self, data: ContextDataType, alloc: Allocator) !Context {
            const context = try ui.getContextRef(alloc);
            const comps = ui.comps;
            comps.items(.context)[context.index] = data;
            comps.items(.parent)[context.index] = .invalid;
            comps.items(.child_no)[context.index] = 0;
            ui.no_leafs += 1;
            ui.root = context;
            return context;
        }

        pub fn findLeafNodes(ui: *Self, buffer: []Context) []Context {
            assert(buffer.len >= ui.no_leafs);
            var leaf_no: usize = 0;
            for (ui.comps.items(.no_children)[0..ui.nodes_limit], 0..) |no_children, index| {
                if (no_children > 0) continue;
                buffer[leaf_no] = Context.init(index);
                leaf_no += 1;
            }
            assert(ui.no_leafs == leaf_no);
            const leafs = buffer[0..leaf_no];
            return leafs;
        }

        const ChildMapType = std.AutoArrayHashMapUnmanaged(ChildNodeRef, Context);

        pub fn createChildMap(ui: *Self, alloc: Allocator) !ChildMapType {
            var map: ChildMapType = .empty;
            const parents: []Context = ui.comps.items(.parent)[0..ui.nodes_limit];
            const child_nos = ui.comps.items(.child_no)[0..ui.nodes_limit];
            for (parents, child_nos, 0..) |parent, child_no, index| {
                if (!parent.isValid()) continue;
                try map.put(
                    alloc,
                    ChildNodeRef.init(parent, @intCast(child_no)),
                    Context.init(@intCast(index)),
                );
            }
            return map;
        }

        pub fn createNodeList(ui: *Self, childMap: ChildMapType, alloc: Allocator) !std.ArrayListUnmanaged(Context) {
            var list: std.ArrayListUnmanaged(Context) = .empty;
            try list.append(alloc, ui.root);
            var node_ptr: usize = 0;
            const no_childrens = ui.comps.items(.no_children);
            while (node_ptr < ui.no_nodes) : (node_ptr += 1) {
                const node = list.items[node_ptr];
                const no_children = no_childrens[node.index];
                for (0..no_children) |child_no| {
                    const child = childMap.get(.{
                        .parent = node,
                        .child_no = @intCast(child_no),
                    }).?;
                    try list.append(alloc, child);
                }
            }
            return list;
        }

        pub fn computeSizes(ui: *Self, leaf_nodes: []Context, trans_allc: Allocator) void {
            const queue: Queue(Context) = .empty;
            queue.enqueueSlice(trans_allc, leaf_nodes);
            defer trans_allc.free(queue.data);

            //WRONG! parents of more than one child get added to the list multiple times
            //so contribute to their parents size multiple times
            const parents: []Context = ui.comps.items(.parents)[0..ui.nodes_limit];
            while (queue.count > 0) {
                const node = queue.dequeue().?;
                const parent = parents[node.index];
                if (!parent.isValid()) continue;
                queue.enqueue(parent, trans_allc);
            }
        }
    };
}

test "compiles" {
    var ui: UI(void) = undefined;
    const allc = std.testing.allocator;
    ui.init();
    defer ui.deinit(allc);
    _ = try ui.addRoot(
        .{
            .x = 0,
            .y = 0,
            .width = AxisSize{
                .fixed = 100,
            },
            .height = AxisSize{ .fixed = 50 },
            .tex = {},
        },
        allc,
    );
    _ = try ui.addContext(
        ui.root,
        .{
            .x = 10,
            .y = 10,
            .width = AxisSize{ .fixed = 20 },
            .height = AxisSize{ .fixed = 30 },
            .tex = {},
        },
        allc,
    );
    var child_map = try ui.createChildMap(allc);
    defer child_map.deinit(allc);
    var nodes = try ui.createNodeList(child_map, allc);
    defer nodes.deinit(allc);
    try std.testing.expect(nodes.items.len == 2);
    try std.testing.expect(ui.comps.items(.context)[nodes.items[0].index].x == 0);
    try std.testing.expect(ui.comps.items(.context)[nodes.items[1].index].x == 10);
}

pub const Children = struct { nodes: []Context };

pub fn ContextData(Texture: type) type {
    return struct {
        x: u32,
        y: u32,
        width: AxisSize,
        height: AxisSize,
        tex: Texture,
    };
}

pub const AxisSizeType = enum {
    grow,
    fixed,
};

pub const AxisSize = union(AxisSizeType) {
    grow: void,
    fixed: u32,
};

fn reversedCopy(contexts: []Context, allc: Allocator) []Context {
    const reversed_copy = allc.alloc(Context, contexts.len);
    for (contexts, 0..) |cntx, index| {
        reversed_copy[contexts.len - index - 1] = cntx;
    }
    return reversed_copy;
}

//is in hierarchical order
pub fn toList(self: Context, allc: Allocator) []Context {
    const list: std.ArrayListUnmanaged(Context) = .clear;
    list.append(allc, self);
    var ptr: u32 = 0;
    var node: Context = undefined;
    while (ptr < list.items.len) {
        node = list.items[ptr];
        list.appendSlice(allc, node.children);
        ptr += 1;
    }
}

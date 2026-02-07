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
    pass_up_interacts: bool, //so if it want's things under it to detect interactions
    pass_down_interacts: bool, //whether it has a descendant that needs ui detection
    interactable: bool,
};

pub fn InternalContextData(ContextDataType: type, IDType: type) type {
    return struct {
        const Self = @This();

        pub const empty = Self{
            .context = undefined,
            .name = null,
            .parent = .invalid,
            .no_children = 0,
            .child_no = 0,
            .flags = .{
                .valid = false,
                .pass_up_interacts = false,
                .pass_down_interacts = false,
                .interactable = false,
            },
        };

        pub const emptyValid = Self{
            .context = undefined,
            .name = null,
            .parent = .invalid,
            .no_children = 0,
            .child_no = 0,
            .flags = .{
                .valid = true,
                .pass_up_interacts = false,
                .pass_down_interacts = false,
                .interactable = false,
            },
        };

        context: ContextDataType,
        name: ?IDType = null,
        parent: Context,
        no_children: u32,
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

//want to detect "clicks" an abstraction of button clicks

pub const NamedContextData = struct {
    context: Context,
    clicked: bool,

    pub fn init(context: Context) NamedContextData {
        return NamedContextData{
            .context = context,
            .clicked = false,
        };
    }
};

pub fn UI(Texture: type, ID: type) type {
    return struct {
        pub const ContextDataType = ContextData(Texture);

        no_nodes: u32,
        nodes_limit: u32,
        comps: std.MultiArrayList(InternalContextData(ContextDataType, ID)),
        name_to_context: std.AutoArrayHashMapUnmanaged(ID, Context),
        name_to_clicked: std.AutoArrayHashMapUnmanaged(ID, bool),

        no_leafs: u32,
        root: Context,

        const Self = @This();

        pub fn init(ui: *Self) void {
            ui.no_nodes = 0;
            ui.nodes_limit = 0;
            ui.no_leafs = 0;
            ui.root = .invalid;
            ui.comps = .empty;
            ui.name_to_context = .empty;
            ui.name_to_clicked = .empty;
        }

        pub fn clear(ui: *Self) void {
            ui.no_nodes = 0;
            ui.nodes_limit = 0;
            ui.no_leafs = 0;
            ui.comps.clearRetainingCapacity();
            ui.name_to_context.clearRetainingCapacity();
        }

        pub fn deinit(ui: *Self, alloc: Allocator) void {
            ui.comps.deinit(alloc);
            ui.name_to_clicked.deinit(alloc);
            ui.name_to_context.deinit(alloc);
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

        //This is all wrong
        //the model is break everything in to contexts
        //and each contexts just places it's children in order left-to-right or top-to-bottom, wrapping them around
        //so to create a button 70% of the way down the middle of the screen
        //take the screen context, make it lay it's child cntxs top-to-bottom
        //add one child whose width is % it's parents
        //add a second chid cntx
        //and in that child cntx add a child node that is the button.
        pub fn computePrimaryAxisPositions(ui: *Self, nodes: []Context, child_map: ChildMapType, axis: Axis, trans_allc: Allocator) !void {
            const contexts: []ContextDataType = ui.comps.items(.context);
            const no_childrens: []u32 = ui.comps.items(.no_children);
            //works out primary positions of all it's child nodes
            for (nodes) |parent| {
                const no_children = no_childrens[parent.index];
                if (no_children == 0) continue;
                const parent_context = contexts[parent.index];

                const children = try trans_allc.alloc(Context, no_children);
                defer trans_allc.free(children);
                const length = parent_context.getAxisSize(axis);
                var empty_space = parent_context.getAxisSize(axis).fixed;
                //asserting the size is explicit for every node now
                //hmmmmm maybe instead should keep the contexts in child order
                //but they move towards their wanted alignment
                var no_moving_cntxs: u32 = 0;
                const Moving = struct {
                    wanted_pos: u32,
                    cur_pos: u32,
                    moving: bool,
                };
                const wanted_moving: []Moving = try trans_allc.alloc(Moving, no_children);
                defer trans_allc.free(wanted_moving);
                for (0..no_children) |child_no| {
                    const child = child_map.get(.init(parent, @intCast(child_no))).?;
                    const child_context = &contexts[child.index];
                    children[child_no] = child;
                    empty_space -= child_context.getAxisSize(axis).fixed;
                    switch (child_context.getAxisPos(axis)) {
                        .fixed => |pos| {
                            wanted_moving[child_no].cur_pos = pos;
                            wanted_moving[child_no].wanted_pos = pos;
                            wanted_moving[child_no].moving = false;
                        },
                        .aligned => |percent| {
                            child_context.setPosOnAxis(axis, @divTrunc(length.fixed * percent.percent, 100));
                            wanted_moving[child_no].cur_pos = @divTrunc(length.fixed * @as(u32, @intCast(child_no)), no_children);
                            wanted_moving[child_no].wanted_pos = @divTrunc(length.fixed * percent.percent, 100);
                            wanted_moving[child_no].moving = true;
                            no_moving_cntxs += 1;
                        },
                    }
                }
                assert(empty_space >= 0);

                //idea for a momentum based alignment resolution alg
                //seems quite nice
                //my problem with it is explicitness and deviation from the user's wants
                //if it's not exactly what the user wants maybe it's best to ditch it
                //but could allow the option for this solution

                //each context has velocity towards where it wants to be, maybe momentum based so can use the size of the ui element as well
                //so if another context comes colliding, then they will reach equilibrium

                //move the end cntx in to position
                contexts[no_children - 1].setPosOnAxis(
                    axis,
                    parent_context.getAxisPos(axis).fixed +
                        parent_context.getAxisSize(axis).fixed -
                        contexts[no_children - 1].getAxisSize(axis).fixed,
                );
                wanted_moving[no_children - 1].cur_pos = contexts[no_children - 1].getAxisPos(axis).fixed;

                var cur_index: u32 = 0;
                var dirc: i32 = undefined;
                var cntr: u32 = 0;
                //how it's currently written this should just check and make sure the alignments work
                //but can be extended with a "train-carriage" concept to move cntxs in to an equilibrium state
                while (no_moving_cntxs > 0) {
                    assert(cntr < no_children * 5);
                    cntr += 1;
                    const want_move: *Moving = &wanted_moving[cur_index];

                    if (!want_move.moving) {
                        cur_index += 1;
                        cur_index %= no_children;
                        continue;
                    }

                    const move: i32 =
                        @as(i32, @intCast(want_move.wanted_pos)) -
                        @as(i32, @intCast(want_move.cur_pos));
                    dirc = if (move >= 0) 1 else -1;

                    const next_index = blk: {
                        if (move == 0) {
                            want_move.moving = false;
                            no_moving_cntxs -= 1;
                            continue;
                        } else if (move > 0) {
                            if (cur_index == no_children - 1) {
                                want_move.moving = false;
                                no_moving_cntxs -= 1;
                                continue;
                            }
                            break :blk cur_index + 1;
                        } else {
                            if (cur_index == 0) {
                                want_move.moving = false;
                                no_moving_cntxs -= 1;
                                continue;
                            }
                            break :blk cur_index - 1;
                        }
                    };
                    const next_move = &wanted_moving[next_index];
                    const node: *ContextDataType = &contexts[cur_index];
                    const next_node: *ContextDataType = &contexts[next_index];

                    if (dirc == 1) {
                        const gap: i32 =
                            @as(i32, @intCast(next_move.cur_pos)) -
                            @as(i32, @intCast(want_move.wanted_pos + node.getAxisSize(axis).fixed));
                        if (gap >= 0) { //nice!
                            want_move.cur_pos = want_move.wanted_pos;
                            want_move.moving = false;
                            no_moving_cntxs -= 1;
                            continue;
                        }

                        want_move.cur_pos = @intCast(@as(i32, @intCast(want_move.wanted_pos)) + gap);
                        //cur_index = next_index;
                        unreachable;

                        //if (!next_move.moving) {
                        //    want_move.moving = false;
                        //    continue;
                        //}
                        //
                        ////we're assuming the situation can be resolved atm
                        //assert(next_move.wanted_pos - next_move.cur_pos >= 0);
                        //continue;
                    }

                    if (dirc == -1) {
                        const gap: i32 =
                            @as(i32, @intCast(want_move.wanted_pos)) -
                            @as(i32, @intCast(next_move.cur_pos + next_node.getAxisSize(axis).fixed));
                        if (gap >= 0) { //nice!
                            want_move.cur_pos = want_move.wanted_pos;
                            want_move.moving = false;
                            no_moving_cntxs -= 1;
                            continue;
                        }
                        want_move.cur_pos = @intCast(@as(i32, @intCast(want_move.wanted_pos)) + gap);
                        //cur_index = next_index;
                        unreachable;

                        //if (!next_move.moving) {
                        //    want_move.moving = false;
                        //    continue;
                        //}
                        ////assuming resolvable atm
                        //assert(next_move.wanted_pos - next_move.cur_pos <= 0);
                        //continue;
                    }
                }
            }
        }

        pub fn nameContext(ui: *Self, context: Context, name: ID, allc: Allocator) !void {
            assert(ui.comps.items(.name)[context.index] == null);
            ui.comps.items(.name)[context.index] = name;
            try ui.name_to_context.put(allc, name, context);
        }

        pub fn makeInteractable(ui: *Self, context: Context, pass_up_interacts: bool) void {
            assert(ui.comps.items(.name)[context.index] != null);
            ui.comps.items(.flags)[context.index].interactable = true;
            ui.comps.items(.flags)[context.index].pass_up_interacts = pass_up_interacts;
        }

        //nvm just gonna iterate through
        fn prepareInteractability(ui: *Self, nodes: []Context) void {
            var node_index: u32 = @intCast(nodes.len);
            const flags: []InternalContextDataFlags = ui.comps.items(.flags);
            const parents: []u32 = ui.comps.items(.parent);
            while (node_index >= 0) : (node_index -= 1) {
                const node = nodes[node_index];
                const flag: *const InternalContextDataFlags = &flags[node.index];
                if (!flag.interactable and !flag.pass_down_interacts) continue;
                flags[parents[node.index]].pass_down_interacts = true;
            }
        }

        pub fn createDepthFirstNodeList(ui: *Self, childMap: ChildMapType, alloc: Allocator) !std.ArrayListUnmanaged(Context) {
            var list: std.ArrayListUnmanaged(Context) = try .initCapacity(alloc, ui.no_nodes);
            const no_childrens = ui.comps.items(.no_children);
            var stack: std.ArrayListUnmanaged(Context) = .empty;
            try stack.append(alloc, ui.root);
            defer stack.deinit(alloc);
            while (stack.items.len > 0) {
                const node = stack.pop().?;
                try list.append(alloc, node);
                const no_children = no_childrens[node.index];
                for (0..no_children) |child_no| {
                    const child = childMap.get(.{
                        .parent = node,
                        .child_no = @intCast(child_no),
                    }).?;
                    try stack.append(alloc, child);
                }
            }
            return list;
        }

        pub fn getContext(ui: *Self, name: ID) Context {
            if (!ui.name_to_cntx.contains(name)) return .invalid;
            return ui.name_to_cntx.get(name);
        }

        pub const InteractedUI = struct {
            interactor_index: u32,
            cntx_name: ID,

            pub fn init(interactor: u32, name: ID) InteractedUI {
                return InteractedUI{
                    .interactor_index = interactor,
                    .cntx_name = name,
                };
            }
        };

        //this could not use depth_first_nodes and instead just deal with the additional hassle of adding popins on the left and shifting child node nums
        //just checks every ui thing against every "click" and does a bounds check
        //
        pub fn processClicks(ui: *Self, depth_first_nodes: []Context, click_positions: []const Vector2I, interacteds_buffer: []InteractedUI) []InteractedUI {
            const flags: []InternalContextDataFlags = ui.comps.items(.flags);
            const data: []ContextDataType = ui.comps.items(.context);
            const names: []?ID = ui.comps.items(.name);
            var no_interactions: u32 = 0;
            for (0..depth_first_nodes.len) |index| {
                const node_index = depth_first_nodes.len - index - 1;
                const flag: *const InternalContextDataFlags = &flags[node_index];
                if (!flag.interactable) continue;
                const node: *const ContextDataType = &data[node_index];
                for (click_positions, 0..) |click, interactor| {
                    if (click.x < node.x.fixed or node.x.fixed + node.width.fixed < click.x) continue;
                    if (click.y < node.y.fixed or node.y.fixed + node.height.fixed < click.y) continue;
                    const name = names[node_index].?; //name should exist, assert it
                    interacteds_buffer[no_interactions] = .init(@intCast(interactor), name);
                    no_interactions += 1;
                }
            }
            return interacteds_buffer[0..no_interactions];
        }

        pub fn prepForIsClicked(ui: *Self, interactions: []InteractedUI, allc: Allocator) !void {
            for (interactions) |interaction| {
                try ui.name_to_clicked.put(allc, interaction.cntx_name, true);
            }
        }

        //call before processing
        pub fn clearInteractions(ui: *Self) void {
            ui.name_to_clicked.clearRetainingCapacity();
        }

        //call around the actual code where the ui context is created
        //but be aware it's asking if it got clicked according to the ui layout of last frame
        pub fn isClicked(ui: *Self, name: ID) bool {
            if (ui.name_to_clicked.get(name)) |clicked| return clicked else return false;
        }
    };
}

test "compiles" {
    //processing
    const Name = enum {
        little_rect,
    };

    const UIType = UI(void, Name);
    var ui: UIType = undefined;
    const allc = std.testing.allocator;
    ui.init();
    defer ui.deinit(allc);

    var loop_count: u32 = 0;
    while (loop_count < 10) : (loop_count += 1) {
        ui.clear();
        _ = try ui.addRoot(
            .{
                .x = .{ .fixed = 0 },
                .y = .{ .fixed = 0 },
                .width = AxisSize{
                    .fixed = 100,
                },
                .height = AxisSize{ .fixed = 50 },
                .tex = {},
            },
            allc,
        );

        //how the actual code looks about the codebase
        try std.testing.expect(loop_count == 0 or ui.isClicked(.little_rect));
        if (ui.isClicked(.little_rect)) {
            //blah blah
        }
        const little_rect = try ui.addContext(
            ui.root,
            .{
                .x = .{ .aligned = .init(50) },
                .y = .{ .fixed = 10 },
                .width = AxisSize{ .fixed = 20 },
                .height = AxisSize{ .fixed = 30 },
                .tex = {},
            },
            allc,
        );
        try ui.nameContext(little_rect, Name.little_rect, allc);
        ui.makeInteractable(little_rect, false);

        //processing
        ui.clearInteractions();
        var child_map = try ui.createChildMap(allc);
        defer child_map.deinit(allc);
        var nodes = try ui.createNodeList(child_map, allc);
        defer nodes.deinit(allc);
        try ui.computePrimaryAxisPositions(nodes.items, child_map, .x, allc);
        var depth_first_nodes = try ui.createDepthFirstNodeList(child_map, allc);
        defer depth_first_nodes.deinit(allc);
        const clicks = [_]Vector2I{.init(55, 15)};
        var interacted_ui_buffer: [1]UIType.InteractedUI = undefined;
        const interacted_ui = ui.processClicks(
            depth_first_nodes.items,
            clicks[0..],
            interacted_ui_buffer[0..1],
        );
        try ui.prepForIsClicked(interacted_ui, allc);

        try std.testing.expect(nodes.items.len == 2);
        try std.testing.expect(ui.comps.items(.context)[nodes.items[0].index].x.fixed == 0);
        try std.testing.expect(ui.comps.items(.context)[nodes.items[1].index].x.fixed == 50);
        try std.testing.expect(interacted_ui.len > 0);
    }
}

pub const Children = struct { nodes: []Context };

pub fn ContextData(Texture: type) type {
    return struct {
        const Self = @This();

        x: AxisPosition,
        y: AxisPosition,
        width: AxisSize,
        height: AxisSize,
        tex: Texture,

        pub fn getAxisPos(context_data: *const Self, axis: Axis) AxisPosition {
            return if (axis == .x) context_data.x else context_data.y;
        }

        pub fn getAxisSize(context_data: *const Self, axis: Axis) AxisSize {
            return if (axis == .x) context_data.width else context_data.height;
        }

        pub fn setPosOnAxis(context_data: *Self, axis: Axis, pos: u32) void {
            if (axis == .x) {
                context_data.x = AxisPosition{ .fixed = pos };
            } else {
                context_data.y = AxisPosition{ .fixed = pos };
            }
        }

        pub fn setSizeOnAxis(context_data: *Self, axis: Axis, size: u32) void {
            if (axis == .x) {
                context_data.width = AxisSize{ .fixed = size };
            } else {
                context_data.height = AxisSize{ .fixed = size };
            }
        }
    };
}

pub const Axis = enum {
    x,
    y,
};

pub const AxisPositionType = enum {
    fixed,
    aligned,
};

pub const AlignmentPercent = struct {
    percent: u7,

    pub fn init(percent: u7) AlignmentPercent {
        assert(percent >= 0 and percent <= 100);
        return AlignmentPercent{
            .percent = percent,
        };
    }
};

pub const AxisPosition = union(AxisPositionType) {
    fixed: u32,
    aligned: AlignmentPercent,
};

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

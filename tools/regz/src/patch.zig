const std = @import("std");
const Allocator = std.mem.Allocator;
const Arch = @import("arch.zig").Arch;

pub const Type = struct {
    pub const Access = enum { read_write, read_only, write_only, write_once, read_write_once };

    pub const Field = struct {
        name: []const u8,
        description: ?[]const u8 = null,
        offset_bits: u8,
        size_bits: u8,
        access: ?Access = null,
    };

    pub const Register = struct {
        name: []const u8,
        description: ?[]const u8 = null,
        offset_bytes: u64,
        size_bits: u8,
        access: Access = .read_write,
        reset_value: ?u64 = null,
        fields: []const Field = &.{},
    };

    pub const EnumField = struct {
        name: []const u8,
        description: ?[]const u8 = null,
        value: u32,
    };

    pub const Enum = struct {
        name: []const u8,
        description: ?[]const u8 = null,
        bitsize: u8,
        fields: []const EnumField = &.{},
    };
};

pub const Patch = union(enum) {
    /// Add a peripheral type and an instance on one existing device. Register
    /// offsets are relative to base_address; field offsets are relative to the
    /// register. Existing peripherals cannot be replaced by this operation.
    add_peripheral: struct {
        device_name: []const u8,
        name: []const u8,
        description: ?[]const u8 = null,
        base_address: u64,
        registers: []const Type.Register,
    },
    override_arch: struct {
        device_name: []const u8,
        arch: Arch,
    },
    set_device_property: struct {
        device_name: []const u8,
        key: []const u8,
        value: []const u8,
        description: ?[]const u8 = null,
    },
    add_enum: struct {
        parent: []const u8,
        @"enum": Type.Enum,
    },
    /// The replaced type MUST be the same size. Bit or Byte size depends on the
    /// context
    set_enum_type: struct {
        of: []const u8,
        to: ?[]const u8,
    },
    /// Rename one expanded register without changing its fields or address.
    /// Offset lookup can disambiguate duplicate names in a vendor description.
    rename_register_at_offset: struct {
        parent: []const u8,
        offset_bytes: u64,
        expected_name: []const u8,
        name: []const u8,
    },
    add_interrupt: struct {
        device_name: []const u8,
        idx: i32,
        name: []const u8,
        description: ?[]const u8 = null,
    },
    /// Creates a new enum type in the specified parent struct and applies it
    /// to all the specified field references. This is a convenience patch that
    /// combines `add_enum` with multiple `set_enum_type` operations.
    add_enum_and_apply: struct {
        parent: []const u8,
        @"enum": Type.Enum,
        apply_to: []const []const u8,
    },

    pub fn from_json_str(allocator: Allocator, json_str: []const u8) !std.json.Parsed(Patch) {
        return std.json.parseFromSlice(Patch, allocator, json_str, .{});
    }
};

/// List for assembling patches in build scripts
pub const PatchList = struct {
    entries: std.array_list.Managed(Patch),

    pub fn append(list: *PatchList, patch: Patch) void {
        list.append(patch) catch @panic("OOM");
    }
};

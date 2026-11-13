const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.usb_ctrl);

pub const descriptor = @import("usb/descriptor.zig");
pub const drivers = struct {
    pub const CDC = @import("usb/drivers/CDC.zig");
    pub const EchoExample = @import("usb/drivers/EchoExample.zig");
    pub const hid = @import("usb/drivers/hid.zig");
};
pub const types = @import("usb/types.zig");

test "usb tests" {
    _ = descriptor;
    _ = drivers.CDC;
    _ = types;
}

pub const ack: []const u8 = "";
pub const nak: ?[]const u8 = null;

// What does this do? It lets you iterate through interfaces and endpoints?
pub const DescriptorAllocator = struct {
    next_ep_num: [2]u8,
    next_itf_num: u8,
    unique_endpoints: bool,
    strings: []const []const u8,

    pub fn init(unique_endpoints: bool) @This() {
        return .{
            .next_ep_num = @splat(1),
            .next_itf_num = 0,
            .unique_endpoints = unique_endpoints,
            .strings = &.{},
        };
    }

    pub fn next_ep(self: *@This(), dir: types.Dir) types.Endpoint {
        const idx: u1 = @backingInt(dir);
        const ret = self.next_ep_num[idx];
        self.next_ep_num[idx] += 1;
        if (self.unique_endpoints)
            self.next_ep_num[idx ^ 1] += 1;
        return .{ .dir = dir, .num = @fromBackingInt(ret) };
    }

    pub fn next_itf(self: *@This()) u8 {
        defer self.next_itf_num += 1;
        return self.next_itf_num;
    }

    pub fn string(self: *@This(), str: []const u8) u8 {
        if (str.len == 0) return 0;
        // deduplicate
        for (self.strings, 1..) |s, i| {
            if (std.mem.eql(u8, s, str))
                return i;
        }

        self.strings = self.strings ++ .{str};
        return @intCast(self.strings.len);
    }

    pub fn string_descriptors(self: @This(), lang: descriptor.String.Language) []const descriptor.String {
        var ret: []const descriptor.String = &.{.from_lang(lang)};
        for (self.strings) |s|
            ret = ret ++ [1]descriptor.String{.from_str(s)};
        return ret;
    }

    pub fn to_const(self: *DescriptorAllocator) DescriptorAllocator {
        defer self.* = undefined;
        return self.*;
    }
};

/// Wraps a Descriptor type. Returned by the `create` method of the Descriptor.
pub fn DescriptorCreateResult(Descriptor: type) type {
    return struct {
        descriptor: Descriptor,
        /// If not null, a slice of this length will be passed
        /// to driver's init function.
        alloc_bytes: ?usize = null,
        /// Null means natural alignment
        alloc_align: ?usize = null,
    };
}

/// USB Device interface
/// Any device implementation used with DeviceController must implement these functions
pub const DeviceInterface = struct {
    pub const VTable = struct {
        ep_writev: *const fn (*DeviceInterface, types.Endpoint.Num, []const []const u8) types.Len,
        ep_readv: *const fn (*DeviceInterface, types.Endpoint.Num, []const []u8) types.Len,
        ep_listen: *const fn (*DeviceInterface, types.Endpoint.Num, types.Len) void,
        ep_open: *const fn (*DeviceInterface, *const descriptor.Endpoint) void,
        set_address: *const fn (*DeviceInterface, u7) void,
    };

    vtable: *const VTable,

    /// Called by drivers to send a packet.
    pub fn ep_writev(self: *@This(), ep_num: types.Endpoint.Num, data: []const []const u8) types.Len {
        return self.vtable.ep_writev(self, ep_num, data);
    }

    /// Send ack on given IN endpoint.
    pub fn ep_ack(self: *@This(), ep_num: types.Endpoint.Num) void {
        assert(0 == self.ep_writev(ep_num, &.{ack}));
    }

    /// Called by drivers to retrieve a received packet.
    /// Must be called exactly once for each packet.
    /// Buffers in `data` must collectively be long enough to fit the whole packet.
    pub fn ep_readv(self: *@This(), ep_num: types.Endpoint.Num, data: []const []u8) types.Len {
        return self.vtable.ep_readv(self, ep_num, data);
    }

    /// Called by drivers to report readiness to receive up to `len` bytes.
    /// After being called it may not be called again until a packet is received.
    pub fn ep_listen(self: *@This(), ep_num: types.Endpoint.Num, len: types.Len) void {
        return self.vtable.ep_listen(self, ep_num, len);
    }

    /// Opens an endpoint according to the descriptor. Note that if the endpoint
    /// direction is IN this may call the controller's `on_buffer` function,
    /// so driver initialization must be done before this function is called
    /// on IN endpoint descriptors.
    ///
    /// The endpoint may have been open before: the host can select a configuration
    /// again without a bus reset, and nothing tells the HAL that a configuration
    /// ended. `ep_open` must leave the endpoint idle, with no packet armed or
    /// pending from before, so that the next `ep_writev` of up to one packet is
    /// taken whole and the next `ep_listen` is accepted, and with its data toggle
    /// at DATA0, which is where the host puts its own toggle when it selects a
    /// configuration (USB 2.0, 9.1.1.5). Drivers rely on this.
    ///
    /// That includes a packet from before that has completed but has not been
    /// reported yet: after `ep_open` returns, the controller's `on_buffer` must
    /// not be called for it. A completion reported while no configuration is
    /// selected is harmless (the controller drops it); one reported after the
    /// endpoint was opened again would reach the new configuration's driver as
    /// if its own packet had completed.
    pub fn ep_open(self: *@This(), desc: *const descriptor.Endpoint) void {
        return self.vtable.ep_open(self, desc);
    }

    /// Immediately sets the device address.
    pub fn set_address(self: *@This(), addr: u7) void {
        return self.vtable.set_address(self, addr);
    }
};

pub fn EndpointHandler(Driver: type) type {
    return fn (*Driver, types.Endpoint.Num) void;
}

pub fn DriverHandlers(Driver: type) type {
    var field_names: []const [:0]const u8 = &.{};

    const info = @typeInfo(Driver.Descriptor).@"struct";
    for (info.field_names, info.field_types) |field_name, field_type| switch (field_type) {
        descriptor.Endpoint => field_names = field_names ++ .{field_name},
        else => {},
    };

    return @Struct(.auto, null, field_names, &@splat(EndpointHandler(Driver)), &@splat(.{}));
}

pub const Config = struct {
    pub const IdStringPair = struct {
        id: u16,
        str: []const u8,
    };

    pub const Configuration = struct {
        name: []const u8 = "",
        attributes: descriptor.Configuration.Attributes,
        max_current_ma: u9,
        Drivers: type,

        /// Generate A struct with a field for each field in Drivers, where the type is the third
        /// arg of the Drivers' Descriptor's 'create' method.
        pub fn Args(self: @This()) type {
            const info = @typeInfo(self.Drivers).@"struct";
            const count = info.field_names.len;
            var field_names: [count][:0]const u8 = undefined;
            var field_types: [count]type = undefined;
            for (info.field_names, info.field_types, 0..) |field_name, field_type, i| {
                // Collect field names
                field_names[i] = field_name;
                // Collect the type info  for the Descriptor.create function parameter
                const param_types = @typeInfo(@TypeOf(field_type.Descriptor.create)).@"fn".param_types;
                // Ensure it takes 3 parameters
                assert(param_types.len == 3);
                // The first must be a DescriptorAllocator
                assert(param_types[0] == *DescriptorAllocator);
                // The second is usb.types.Len
                assert(param_types[1] == types.Len);
                // And save the type of the third
                field_types[i] = param_types[2].?;
            }
            return @Struct(.auto, null, &field_names, &field_types, &@splat(.{}));
        }
    };

    /// Usb specification version.
    bcd_usb: types.Version,
    /// Class, subclass and protocol of this device.
    device_triple: types.ClassSubclassProtocol,
    /// Vendor id and string
    vendor: IdStringPair,
    /// Product id and string.
    product: IdStringPair,
    /// Device version.
    bcd_device: types.Version,
    /// String descriptor 0.
    language: descriptor.String.Language = .English,
    /// Serial number string.
    serial: []const u8,
    /// Largest packet length the hardware supports. Must be a power of 2 and at least 8.
    max_supported_packet_size: types.Len,
    /// Currently only a single configuration is supported.
    configurations: []const Configuration,
    /// Only use either IN or OUT on each endpoint. Useful for debugging.
    /// Realistically, it should only be turned off if you are exhausting
    /// the 15 endpoint limit.
    unique_endpoints: bool = true,

    pub fn DriverArgs(self: @This()) type {
        var field_types: [self.configurations.len]type = undefined;
        for (self.configurations, &field_types) |cfg, *dst|
            dst.* = cfg.Args();
        return @Tuple(&field_types);
    }
};

pub fn validate_controller(T: type) void {
    comptime {
        const info = @typeInfo(T);
        if (info != .pointer or info.pointer.attrs.@"const" or info.pointer.size != .one)
            @compileError("Expected a mutable pointer to the usb controller, got: " ++ @typeName(T));
        const Controller = info.pointer.child;
        _ = Controller;
        // More checks
    }
}

/// USB device controller
///
/// Responds to host requests and dispatches to the appropriate drivers.
/// When this type is build (at comptime), it builds descriptor and handler tables based on the
/// provided config.
pub fn DeviceController(config: Config, driver_args: config.DriverArgs()) type {
    std.debug.assert(config.configurations.len == 1);

    return struct {
        // We only support one configuration
        const config0 = config.configurations[0];
        const driver_info = @typeInfo(config0.Drivers).@"struct";
        const DriverEnum = std.meta.FieldEnum(config0.Drivers);

        /// This parses the drivers' descriptors and creates:
        /// * the configuration descriptor (currently only one configuration is supported)
        /// * table of handlers for endpoints
        /// * table of handlers for interfaces
        const descriptor_parse_result = blk: {
            const max_psize = config.max_supported_packet_size;
            assert(max_psize >= 8);
            assert(std.math.isPowerOfTwo(max_psize));

            var alloc: DescriptorAllocator = .init(config.unique_endpoints);
            const manufacturer_s = alloc.string(config.vendor.str);
            const product_s = alloc.string(config.product.str);
            const serial_s = alloc.string(config.serial);

            const desc_device: descriptor.Device = .{
                .bcd_usb = config.bcd_usb,
                .device_triple = config.device_triple,
                .max_packet_size0 = @min(config.max_supported_packet_size, 64),
                .vendor = .from(config.vendor.id),
                .product = .from(config.product.id),
                .bcd_device = config.bcd_device,
                .manufacturer_s = manufacturer_s,
                .product_s = product_s,
                .serial_s = serial_s,
                .num_configurations = config.configurations.len,
            };
            const configuration_s = alloc.string(config0.name);

            var size = @sizeOf(descriptor.Configuration);
            var field_names: [driver_info.field_names.len][:0]const u8 = undefined;
            var field_types: [driver_info.field_names.len]type = undefined;
            var field_attrs: [driver_info.field_names.len]std.builtin.Type.Struct.FieldAttributes = undefined;
            var ep_handler_types: [2][16]type = @splat(@splat(void));
            var ep_handler_names: [2][16][:0]const u8 = undefined;
            var ep_handler_drivers: [2][16]?usize = @splat(@splat(null));
            var itf_handlers: []const DriverEnum = &.{};
            var driver_alloc_names: []const [:0]const u8 = &.{};
            var driver_alloc_types: []const type = &.{};
            var driver_alloc_attrs: []const std.builtin.Type.Struct.FieldAttributes = &.{};

            for (driver_info.field_names, driver_info.field_types, 0..) |driver_field_name, driver_field_type, drv_id| {
                // Get descriptor type for the current driver
                const Descriptors = driver_field_type.Descriptor;
                // Call the create method on the descriptor, which wraps it with the allow stuff.
                const result = Descriptors.create(&alloc, max_psize, @field(driver_args[0], driver_field_name));
                // Get the descriptor instance from the result.
                const descriptors = result.descriptor;

                // If the driver requests memory, then collect the names, types, and attrs
                if (result.alloc_bytes) |len| {
                    driver_alloc_names = driver_alloc_names ++ &[_][:0]const u8{driver_field_name};
                    driver_alloc_types = driver_alloc_types ++ &[_]type{[len]u8};
                    driver_alloc_attrs = driver_alloc_attrs ++ &[_]std.builtin.Type.Struct.FieldAttributes{.{ .@"align" = result.alloc_align }};
                } else {
                    assert(result.alloc_align == null);
                }

                assert(@alignOf(Descriptors) == 1);
                size += @sizeOf(Descriptors);

                // Collect handler types, names, and drivers, to later be bound to the appropriate
                // endpoints
                const info = @typeInfo(Descriptors).@"struct";
                for (info.field_names, info.field_types, 0..) |field_name, field_type, desc_num| {
                    const desc = @field(descriptors, field_name);

                    // Determine which interface numbers this driver owns. If it is an
                    // InterfaceAssociation, then use the interface count. If it is an Interface,
                    // then the driver owns just that one interface.
                    if (desc_num == 0) {
                        const itf_start, const itf_count = switch (field_type) {
                            descriptor.InterfaceAssociation => .{ desc.first_interface, desc.interface_count },
                            descriptor.Interface => .{ desc.interface_number, 1 },
                            else => |T| @compileError(
                                "Expected first descriptor of driver " ++
                                    @typeName(driver_field_type) ++
                                    " to be of type Interface or InterfaceAssociation descriptor, got: " ++
                                    @typeName(T),
                            ),
                        };
                        if (itf_start != itf_handlers.len)
                            @compileError("interface numbering mismatch");

                        itf_handlers = itf_handlers ++ @as([itf_count]DriverEnum, @splat(@field(DriverEnum, driver_field_name)));
                    }

                    switch (field_type) {
                        // Register handler for endpoints
                        descriptor.Endpoint => {
                            const ep_dir = @backingInt(desc.endpoint.dir);
                            const ep_num = @backingInt(desc.endpoint.num);

                            if (ep_handler_types[ep_dir][ep_num] != void)
                                @compileError(std.fmt.comptimePrint(
                                    "ep{} {t}: multiple handlers: {s} and {s}",
                                    .{ ep_num, desc.endpoint.dir, ep_handler_drivers[ep_dir][ep_num], driver_field_name },
                                ));

                            ep_handler_types[ep_dir][ep_num] = EndpointHandler(driver_field_type);
                            ep_handler_drivers[ep_dir][ep_num] = drv_id;
                            ep_handler_names[ep_dir][ep_num] = field_name;
                        },
                        // Interface association must be first
                        descriptor.InterfaceAssociation => assert(desc_num == 0),
                        else => {},
                    }
                }
                field_names[drv_id] = driver_field_name;
                field_types[drv_id] = Descriptors;
                field_attrs[drv_id] = .{ .default_value_ptr = &descriptors };
            }

            // Finally, bind the handler functions based on the data collected above.
            // Create a tuple with the appropriate types
            const ep_handlers_types: [2]type = .{ @Tuple(&ep_handler_types[0]), @Tuple(&ep_handler_types[1]) };
            var ep_handlers: @Tuple(&ep_handlers_types) = undefined;
            // Iterate over all IN and OUT endpoints and bind the handler for any that are set.
            for (&ep_handler_types, &ep_handler_names, &ep_handler_drivers, 0..) |htypes, hnames, hdrivers, dir| {
                for (&htypes, &hnames, &hdrivers, 0..) |T, name, drv_id, ep| {
                    if (T != void)
                        ep_handlers[dir][ep] = @field(driver_info.field_types[drv_id.?].handlers, name);
                }
            }

            // alloc is invalidated after this point. It will cause a compile
            // error if mutated.
            const const_alloc = alloc.to_const();
            const const_ep_handlers = ep_handlers;

            const DriverConfig = @Struct(.@"extern", null, &field_names, &field_types, &field_attrs);
            const idx_in = @backingInt(types.Dir.in);
            const idx_out = @backingInt(types.Dir.out);
            break :blk .{
                .device_descriptor = desc_device,
                .config_descriptor = extern struct {
                    first: descriptor.Configuration = .{
                        .total_length = .from(size),
                        .num_interfaces = const_alloc.next_itf_num,
                        .configuration_value = 1,
                        .configuration_s = configuration_s,
                        .attributes = config0.attributes,
                        .max_current = .from_ma(config0.max_current_ma),
                    },
                    drv: DriverConfig = .{},
                }{},
                .string_descriptors = const_alloc.string_descriptors(config.language),
                .handlers_itf = itf_handlers,
                .handlers_ep = struct {
                    in: ep_handlers_types[idx_in] = const_ep_handlers[idx_in],
                    out: ep_handlers_types[idx_out] = const_ep_handlers[idx_out],
                }{},
                .drivers_ep = ep_handler_drivers,
                .DriverAlloc = @Struct(
                    .auto,
                    null,
                    driver_alloc_names,
                    driver_alloc_types[0..driver_alloc_attrs.len],
                    driver_alloc_attrs[0..driver_alloc_attrs.len],
                ),
            };
        };

        const config_descriptor = descriptor_parse_result.config_descriptor;
        const device_descriptor = descriptor_parse_result.device_descriptor;
        const string_descriptors = descriptor_parse_result.string_descriptors;
        const handlers_itf = descriptor_parse_result.handlers_itf;
        const handlers_ep = .{
            .han = descriptor_parse_result.handlers_ep,
            .drv = descriptor_parse_result.drivers_ep,
        };
        const DriverAlloc = descriptor_parse_result.DriverAlloc;

        /// If not zero, change the device address at the next opportunity.
        /// Necessary because when the host sets the device address,
        /// the acknowledgement step must use the _old_ address.
        new_address: u8,
        /// 0 - no config set
        cfg_num: u16,
        /// Ep0 data waiting to be sent
        tx_slice: ?[]const u8,
        /// The control read in `tx_slice` ends on a full packet although the host asked for
        /// more, so a zero-length packet has to follow its last one.
        tx_zlp: bool,
        /// Driver state
        driver_data: ?config0.Drivers,
        ///
        driver_alloc: DriverAlloc,

        /// Initial values
        pub const init: @This() = .{
            .new_address = 0,
            .cfg_num = 0,
            .tx_slice = null,
            .tx_zlp = false,
            .driver_data = null,
            .driver_alloc = undefined,
        };

        /// Returns a pointer to the drivers
        /// or null in case host has not yet configured the device.
        pub fn drivers(self: *@This()) ?*config0.Drivers {
            return if (self.driver_data) |*ret| ret else null;
        }

        /// Called by the device implementation when a setup request has been received.
        pub fn on_setup_req(self: *@This(), device_itf: *DeviceInterface, setup: *const types.SetupPacket) void {
            log.debug("on_setup_req", .{});

            // A setup request starts a new control transfer and ends the one before it,
            // finished or not (USB 2.0, 5.5.5). What that one still had to send is dropped:
            // the host may have given up on a control read after its first packets. An address
            // that waits for its status packet is dropped with it: the host did not take that
            // packet and still talks to the address the device has.
            self.tx_slice = null;
            self.tx_zlp = false;
            self.new_address = 0;

            const ret = switch (setup.request_type.recipient) {
                .device => self.process_device_setup(device_itf, setup),
                .interface => self.process_interface_setup(setup),
                else => nak,
            };
            if (ret) |data| {
                if (data.len == 0)
                    device_itf.ep_ack(.ep0)
                else {
                    const limited = data[0..@min(data.len, setup.length.native())];
                    const len = device_itf.ep_writev(.ep0, &.{limited});
                    assert(len <= device_descriptor.max_packet_size0);
                    self.tx_slice = limited[len..];
                    // The host takes a packet shorter than the endpoint's maximum, or the
                    // last byte it asked for, as the end of the data stage (USB 2.0, 5.5.3).
                    // A reply shorter than wLength whose last packet is full gives it
                    // neither, so it is followed by a zero-length packet.
                    self.tx_zlp = limited.len < setup.length.native() and
                        limited.len % device_descriptor.max_packet_size0 == 0;
                }
            }
        }

        /// Called by the device implementation when a packet has been sent or received.
        /// A completion that arrives while no configuration is selected is dropped.
        pub fn on_buffer(self: *@This(), device_itf: *DeviceInterface, comptime ep: types.Endpoint) void {
            log.debug("on_buffer {t} {t}", .{ ep.num, ep.dir });

            const driver_opt = comptime handlers_ep.drv[@backingInt(ep.dir)][@backingInt(ep.num)];
            const handler = comptime @field(handlers_ep.han, @tagName(ep.dir))[@backingInt(ep.num)];

            if (comptime ep == types.Endpoint.in(.ep0)) {
                // We use this opportunity to finish the delayed
                // SetAddress request, if there is one:
                if (self.new_address != 0) {
                    device_itf.set_address(@intCast(self.new_address));
                    self.new_address = 0;
                }

                if (self.tx_slice) |slice| {
                    if (slice.len > 0) {
                        const len = device_itf.ep_writev(.ep0, &.{slice});
                        self.tx_slice = slice[len..];
                    } else if (self.tx_zlp) {
                        // The last packet was full and the host expects more.
                        self.tx_zlp = false;
                        device_itf.ep_ack(.ep0);
                    } else {
                        // Otherwise, we've just finished sending tx_slice.
                        // We expect an ensuing status phase where the host
                        // sends us a zero-byte DATA packet via EP0 OUT.
                        // device_itf.ep_listen(.ep0, 0);
                        self.tx_slice = null;

                        // W could call an ACK phase callback here,
                        // but none of the drivers so far need it.
                    }
                }
            } else if (comptime ep == types.Endpoint.out(.ep0))
                log.warn("Unhandled packet on ep0 Out", .{});

            if (comptime driver_opt) |driver| {
                // No configuration is selected (the host deselected it, or the bus was reset)
                // but a packet armed while one was has completed. The drivers that owned it
                // are gone, so there is nobody to tell.
                if (self.driver_data) |*data|
                    handler(&@field(data, driver_info.field_names[driver]), ep.num)
                else
                    log.debug("{t} {t}: completion without a configuration, dropped", .{ ep.num, ep.dir });
            }
        }

        /// Called by the device implementation on bus reset.
        pub fn on_bus_reset(self: *@This(), device_itf: *DeviceInterface) void {
            log.debug("on_bus_reset", .{});

            self.process_set_config(device_itf, 0);

            // Reset our state.
            self.* = .init;
        }

        // Utility functions

        fn process_device_setup(self: *@This(), device_itf: *DeviceInterface, setup: *const types.SetupPacket) ?[]const u8 {
            switch (setup.request_type.type) {
                .standard => {
                    const request: types.SetupRequest = @fromBackingInt(setup.request);
                    log.debug("Device setup: {any}", .{request});
                    switch (request) {
                        .get_status => {
                            const attr = config_descriptor.first.attributes;
                            const status: types.DeviceStatus = comptime .create(attr.self_powered, false);
                            return std.mem.asBytes(&status);
                        },
                        .set_address => self.new_address = @truncate(setup.value.native()),
                        .set_configuration => self.process_set_config(device_itf, setup.value.native()),
                        .get_descriptor => return get_descriptor(setup.value.native()),
                        .set_feature => {
                            const feature: types.FeatureSelector = @fromBackingInt(@intCast(setup.value.native() >> 8));
                            switch (feature) {
                                .DeviceRemoteWakeup, .EndpointHalt => {},
                                // TODO: https://github.com/ZigEmbeddedGroup/microzig/issues/453
                                .TestMode => return nak,
                                else => return nak,
                            }
                        },
                        else => {
                            log.warn("Unsupported standard request: {}", .{setup.request});
                            return nak;
                        },
                    }
                    return ack;
                },
                else => |t| {
                    log.warn("Unhandled device setup request: {any}", .{t});
                    return nak;
                },
            }
        }

        fn process_interface_setup(self: *@This(), setup: *const types.SetupPacket) ?[]const u8 {
            const itf_num: u8 = @truncate(setup.index.native());
            switch (itf_num) {
                inline else => |itf| if (comptime itf < handlers_itf.len) {
                    const drv = handlers_itf[itf];
                    if (self.driver_data) |*data|
                        return @field(data, @tagName(drv)).class_request(setup);
                    // A host may address an interface before it selects a configuration, or
                    // after it deselected it. There is no interface then.
                    log.debug("Request for interface {} without a configuration", .{itf_num});
                    return nak;
                } else {
                    log.warn("Interface index ({}) out of range ({})", .{ itf_num, handlers_itf.len });
                    return nak;
                },
            }
        }

        // Return the appropriate descriptor type as determined by the top 8 bits of the value.
        fn get_descriptor(value: u16) ?[]const u8 {
            const asBytes = std.mem.asBytes;
            const desc_type: descriptor.Type = @fromBackingInt(@intCast(value >> 8));
            const desc_idx: u8 = @truncate(value);
            log.debug("Request for {any} descriptor {}", .{ desc_type, desc_idx });
            return switch (desc_type) {
                .device => asBytes(&device_descriptor),
                .device_qualifier => asBytes(comptime &device_descriptor.qualifier()),
                .configuration => asBytes(&config_descriptor),
                .string => if (desc_idx < string_descriptors.len)
                    string_descriptors[desc_idx].data
                else {
                    log.warn(
                        "Descriptor index ({}) out of range ({})",
                        .{ desc_idx, string_descriptors.len },
                    );
                    return nak;
                },
                else => nak,
            };
        }

        fn process_set_config(self: *@This(), device_itf: *DeviceInterface, cfg_num: u16) void {
            // A request for the configuration that is already selected is carried out like any
            // other. The host puts its data toggles back at DATA0 whenever it sends
            // SET_CONFIGURATION (USB 2.0, 9.1.1.5 and 9.4.7), same value or not, and on the
            // device's side that happens in `ep_open`. The drivers start over with their
            // endpoints, as they do after any other SET_CONFIGURATION.

            if (self.driver_data) |data_old| {
                _ = data_old;
                // deinitialize drivers
            }

            self.cfg_num = cfg_num;
            if (cfg_num == 0) {
                self.driver_data = null;
                return;
            }

            // We support just one config for now so ignore config index
            self.driver_data = @as(config0.Drivers, undefined);
            inline for (driver_info.field_names) |driver_field_name| {
                const cfg = @field(config_descriptor.drv, driver_field_name);
                const desc_info = @typeInfo(@TypeOf(cfg)).@"struct";

                // Open OUT endpoint first so that the driver can call ep_listen in init
                inline for (desc_info.field_names, desc_info.field_types) |field_name, field_type| {
                    const desc = &@field(cfg, field_name);
                    if (comptime field_type == descriptor.Endpoint and desc.endpoint.dir == .out)
                        device_itf.ep_open(desc);
                }

                const drv = &@field(self.driver_data.?, driver_field_name);
                // Don't pass empty slices around
                if (@hasField(@TypeOf(self.driver_alloc), driver_field_name))
                    drv.init(&cfg, device_itf, &@field(self.driver_alloc, driver_field_name))
                else
                    drv.init(&cfg, device_itf);

                // Open IN endpoint last so that callbacks can happen
                inline for (desc_info.field_names, desc_info.field_types) |field_name, field_type| {
                    const desc = &@field(cfg, field_name);
                    if (comptime field_type == descriptor.Endpoint and desc.endpoint.dir == .in)
                        device_itf.ep_open(desc);
                }
            }
        }
    };
}

/// A device for the tests below: it counts what the controller and the drivers ask of it and
/// takes up to `packet_size` bytes of each write.
const TestDevice = struct {
    interface: DeviceInterface = .{ .vtable = &vtable },
    opened: usize = 0,
    listened: usize = 0,
    written: usize = 0,
    /// The most an endpoint takes in one write, and what the last write was given credit for.
    packet_size: types.Len = 64,
    last_written_len: types.Len = 0,
    /// The address of the last `set_address`, if there was one.
    address: ?u7 = null,

    const vtable: DeviceInterface.VTable = .{
        .ep_writev = ep_writev,
        .ep_readv = ep_readv,
        .ep_listen = ep_listen,
        .ep_open = ep_open,
        .set_address = set_address,
    };

    fn from(itf: *DeviceInterface) *TestDevice {
        return @fieldParentPtr("interface", itf);
    }

    fn ep_writev(itf: *DeviceInterface, _: types.Endpoint.Num, data: []const []const u8) types.Len {
        const dev = from(itf);
        dev.written += 1;
        var len: usize = 0;
        for (data) |chunk| len += chunk.len;
        dev.last_written_len = @intCast(@min(len, dev.packet_size));
        return dev.last_written_len;
    }

    fn ep_readv(_: *DeviceInterface, _: types.Endpoint.Num, _: []const []u8) types.Len {
        return 0;
    }

    fn ep_listen(itf: *DeviceInterface, _: types.Endpoint.Num, _: types.Len) void {
        from(itf).listened += 1;
    }

    fn ep_open(itf: *DeviceInterface, _: *const descriptor.Endpoint) void {
        from(itf).opened += 1;
    }

    fn set_address(itf: *DeviceInterface, address: u7) void {
        from(itf).address = address;
    }
};

fn test_config(Drivers: type) Config {
    return .{
        .bcd_usb = .v2_00,
        .device_triple = .unspecified,
        .vendor = .{ .id = 0x1209, .str = "MicroZig" },
        .product = .{ .id = 0x0001, .str = "test" },
        .bcd_device = .v1_00,
        .serial = "0",
        .max_supported_packet_size = 64,
        .configurations = &.{.{
            .attributes = .{ .self_powered = false },
            .max_current_ma = 50,
            .Drivers = Drivers,
        }},
    };
}

fn test_set_configuration(value: u16) types.SetupPacket {
    return .{
        .request_type = .{ .recipient = .device, .type = .standard, .direction = .out },
        .request = @backingInt(types.SetupRequest.set_configuration),
        .value = .from(value),
        .index = .from(0),
        .length = .from(0),
    };
}

test "the controller configures the echo example driver" {
    const Controller = DeviceController(
        test_config(struct { echo: drivers.EchoExample }),
        .{.{ .echo = "echo" }},
    );
    var dev: TestDevice = .{};
    var ctl: Controller = .init;

    ctl.on_setup_req(&dev.interface, &test_set_configuration(1));
    try std.testing.expect(ctl.drivers() != null);
    // One OUT and one IN endpoint; the driver listens on the OUT endpoint when it starts.
    try std.testing.expectEqual(2, dev.opened);
    try std.testing.expectEqual(1, dev.listened);

    // A received packet is read and the driver listens again.
    const echo = Controller.config_descriptor.drv.echo;
    ctl.on_buffer(&dev.interface, comptime echo.ep_out.endpoint);
    try std.testing.expectEqual(2, dev.listened);
}

test "completions and interface requests without a configuration reach no driver" {
    const Controller = DeviceController(
        test_config(struct { serial: drivers.CDC }),
        .{.{ .serial = .{} }},
    );
    var dev: TestDevice = .{};
    var ctl: Controller = .init;
    const cdc = Controller.config_descriptor.drv.serial;
    const get_line_coding: types.SetupPacket = .{
        .request_type = .{ .recipient = .interface, .type = .class, .direction = .in },
        .request = @backingInt(drivers.CDC.ManagementRequestType.GetLineCoding),
        .value = .from(0),
        .index = .from(cdc.itf_notifi.interface_number),
        .length = .from(7),
    };

    // Before the host selects a configuration.
    ctl.on_setup_req(&dev.interface, &get_line_coding);
    try std.testing.expectEqual(0, dev.written);

    // Configured: the request is answered. (Each SET_CONFIGURATION status is one write too.)
    ctl.on_setup_req(&dev.interface, &test_set_configuration(1));
    try std.testing.expectEqual(1, dev.written);
    ctl.on_setup_req(&dev.interface, &get_line_coding);
    try std.testing.expectEqual(2, dev.written);

    // The host deselects the configuration while packets are still armed on the driver's
    // endpoints. They complete afterwards.
    ctl.on_setup_req(&dev.interface, &test_set_configuration(0));
    try std.testing.expect(ctl.drivers() == null);
    try std.testing.expectEqual(3, dev.written);
    const listened = dev.listened;
    ctl.on_buffer(&dev.interface, comptime cdc.ep_out.endpoint);
    ctl.on_buffer(&dev.interface, comptime cdc.ep_in.endpoint);
    ctl.on_buffer(&dev.interface, comptime cdc.ep_notifi.endpoint);
    ctl.on_setup_req(&dev.interface, &get_line_coding);
    try std.testing.expectEqual(3, dev.written);
    try std.testing.expectEqual(listened, dev.listened);

    // And the same after a bus reset.
    ctl.on_setup_req(&dev.interface, &test_set_configuration(1));
    ctl.on_bus_reset(&dev.interface);
    ctl.on_buffer(&dev.interface, comptime cdc.ep_in.endpoint);
    try std.testing.expect(ctl.drivers() == null);
}

fn test_get_descriptor(value: u16, length: u16) types.SetupPacket {
    return .{
        .request_type = .{ .recipient = .device, .type = .standard, .direction = .in },
        .request = @backingInt(types.SetupRequest.get_descriptor),
        .value = .from(value),
        .index = .from(0),
        .length = .from(length),
    };
}

test "a new setup request drops the rest of an abandoned control read" {
    const Controller = DeviceController(
        test_config(struct { serial: drivers.CDC }),
        .{.{ .serial = .{} }},
    );
    var dev: TestDevice = .{};
    var ctl: Controller = .init;

    // The first packet of the configuration descriptor, which is longer than one packet.
    // The rest waits for the packet to complete.
    try std.testing.expect(@sizeOf(@TypeOf(Controller.config_descriptor)) > 64);
    ctl.on_setup_req(&dev.interface, &test_get_descriptor(0x0200, 255));
    try std.testing.expectEqual(1, dev.written);

    // The host gives up on the transfer and sends a request without a data stage.
    ctl.on_setup_req(&dev.interface, &test_set_configuration(1));
    try std.testing.expectEqual(2, dev.written);

    // Its status packet completes. Nothing more may be written to EP0.
    ctl.on_buffer(&dev.interface, comptime types.Endpoint.in(.ep0));
    try std.testing.expectEqual(2, dev.written);
}

test "a new setup request drops an address whose status packet the host never took" {
    const Controller = DeviceController(
        test_config(struct { echo: drivers.EchoExample }),
        .{.{ .echo = "echo" }},
    );
    const ep0_in = comptime types.Endpoint.in(.ep0);
    const set_address: types.SetupPacket = .{
        .request_type = .{ .recipient = .device, .type = .standard, .direction = .out },
        .request = @backingInt(types.SetupRequest.set_address),
        .value = .from(5),
        .index = .from(0),
        .length = .from(0),
    };

    // The address takes effect when the status packet completes, not before.
    {
        var dev: TestDevice = .{};
        var ctl: Controller = .init;
        ctl.on_setup_req(&dev.interface, &set_address);
        try std.testing.expectEqual(1, dev.written);
        try std.testing.expectEqual(null, dev.address);
        ctl.on_buffer(&dev.interface, ep0_in);
        try std.testing.expectEqual(5, dev.address);
    }

    // The host never takes the status packet and sends its next request to the address the
    // device still has. When a packet of that request completes, the address must not change.
    {
        var dev: TestDevice = .{};
        var ctl: Controller = .init;
        ctl.on_setup_req(&dev.interface, &set_address);
        ctl.on_setup_req(&dev.interface, &test_get_descriptor(0x0100, 18));
        try std.testing.expectEqual(2, dev.written);
        ctl.on_buffer(&dev.interface, ep0_in);
        try std.testing.expectEqual(null, dev.address);
    }
}

test "SET_CONFIGURATION with the current value opens the endpoints again" {
    const Controller = DeviceController(
        test_config(struct { serial: drivers.CDC }),
        .{.{ .serial = .{} }},
    );
    var dev: TestDevice = .{};
    var ctl: Controller = .init;

    // Three endpoints: notification IN, data OUT, data IN. The driver listens once on start.
    ctl.on_setup_req(&dev.interface, &test_set_configuration(1));
    try std.testing.expectEqual(3, dev.opened);
    try std.testing.expectEqual(1, dev.listened);

    // The host selects the same configuration again, which puts its data toggles back at
    // DATA0. Only `ep_open` does that on the device's side, and the driver starts over.
    ctl.on_setup_req(&dev.interface, &test_set_configuration(1));
    try std.testing.expect(ctl.drivers() != null);
    try std.testing.expectEqual(6, dev.opened);
    try std.testing.expectEqual(2, dev.listened);

    // Deselecting twice opens nothing and leaves no driver.
    ctl.on_setup_req(&dev.interface, &test_set_configuration(0));
    ctl.on_setup_req(&dev.interface, &test_set_configuration(0));
    try std.testing.expect(ctl.drivers() == null);
    try std.testing.expectEqual(6, dev.opened);
}

test "a control read that ends on a packet boundary short of wLength ends with a zero-length packet" {
    // EP0 packets of 8 bytes, and a product string of three characters: its descriptor is
    // exactly 8 bytes (2 of header, 2 per UTF-16 code unit).
    const cfg = comptime blk: {
        var c = test_config(struct { echo: drivers.EchoExample });
        c.max_supported_packet_size = 8;
        c.product.str = "abc";
        break :blk c;
    };
    const Controller = DeviceController(cfg, .{.{ .echo = "echo" }});
    const product_string = 0x0300 | @as(u16, Controller.device_descriptor.product_s);
    const ep0_in = comptime types.Endpoint.in(.ep0);
    try std.testing.expectEqual(8, Controller.device_descriptor.max_packet_size0);
    try std.testing.expectEqual(8, Controller.string_descriptors[Controller.device_descriptor.product_s].data.len);

    // The host asks for up to 255 bytes. One full packet carries the whole descriptor, and
    // only a packet shorter than that tells the host that there is no more (USB 2.0, 5.5.3).
    {
        var dev: TestDevice = .{ .packet_size = 8 };
        var ctl: Controller = .init;
        ctl.on_setup_req(&dev.interface, &test_get_descriptor(product_string, 255));
        try std.testing.expectEqual(1, dev.written);
        try std.testing.expectEqual(8, dev.last_written_len);
        ctl.on_buffer(&dev.interface, ep0_in);
        try std.testing.expectEqual(2, dev.written);
        try std.testing.expectEqual(0, dev.last_written_len);
        // The zero-length packet completes: the data stage is over.
        ctl.on_buffer(&dev.interface, ep0_in);
        try std.testing.expectEqual(2, dev.written);
    }

    // The host asks for exactly the 8 bytes: it knows the data stage ends there.
    {
        var dev: TestDevice = .{ .packet_size = 8 };
        var ctl: Controller = .init;
        ctl.on_setup_req(&dev.interface, &test_get_descriptor(product_string, 8));
        try std.testing.expectEqual(1, dev.written);
        ctl.on_buffer(&dev.interface, ep0_in);
        try std.testing.expectEqual(1, dev.written);
    }

    // The 18-byte device descriptor, cut to 16 by wLength: the host got all it asked for.
    {
        var dev: TestDevice = .{ .packet_size = 8 };
        var ctl: Controller = .init;
        ctl.on_setup_req(&dev.interface, &test_get_descriptor(0x0100, 16));
        ctl.on_buffer(&dev.interface, ep0_in);
        try std.testing.expectEqual(2, dev.written);
        try std.testing.expectEqual(8, dev.last_written_len);
        ctl.on_buffer(&dev.interface, ep0_in);
        try std.testing.expectEqual(2, dev.written);
    }

    // A reply that ends on a short packet needs nothing after it: 18 bytes are 8, 8 and 2.
    {
        var dev: TestDevice = .{ .packet_size = 8 };
        var ctl: Controller = .init;
        ctl.on_setup_req(&dev.interface, &test_get_descriptor(0x0100, 255));
        ctl.on_buffer(&dev.interface, ep0_in);
        ctl.on_buffer(&dev.interface, ep0_in);
        try std.testing.expectEqual(3, dev.written);
        try std.testing.expectEqual(2, dev.last_written_len);
        ctl.on_buffer(&dev.interface, ep0_in);
        try std.testing.expectEqual(3, dev.written);
    }
}

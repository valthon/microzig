const std = @import("std");
const configuration = @import("usb/configuration.zig");
const assert = std.debug.assert;
const log = std.log.scoped(.usb_ctrl);

pub const Configuration = configuration.Configuration;
pub const ConfigurationOptions = configuration.Options;
pub const descriptor = @import("usb/descriptor.zig");
pub const drivers = struct {
    pub const CDC = @import("usb/drivers/CDC.zig");
    pub const EchoExample = @import("usb/drivers/EchoExample.zig");
    pub const HID_Interrupt = @import("usb/drivers/HID.zig");
};
pub const HID_report = @import("usb/HID_report.zig");
pub const types = @import("usb/types.zig");
pub const endpoint_buffer = @import("usb/endpoint_buffer.zig");
pub const ControlRequest = @import("usb/ControlRequest.zig");

test "usb tests" {
    _ = descriptor;
    _ = drivers.CDC;
    _ = types;
    _ = endpoint_buffer;
}

pub const ack: []const u8 = "";
pub const nak: ?[]const u8 = null;

/// Helper struct for endpoint allocation for drivers.
/// Also deduplicates static strings.
pub const DescriptorAllocator = struct {
    next_ep_num: [2]u8,
    next_itf_num: u8,
    unique_endpoints: bool,
    strings: []const []const u8,

    pub fn init(unique_endpoints: bool, strings: []const []const u8) @This() {
        return .{
            .next_ep_num = @splat(1),
            .next_itf_num = 0,
            .unique_endpoints = unique_endpoints,
            .strings = strings,
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
        self.strings, const ret = dedup_string(self.strings, str);
        return ret;
    }

    pub fn to_const(self: *DescriptorAllocator) DescriptorAllocator {
        defer self.* = undefined;
        return self.*;
    }
};

/// Device-specific information
pub const DeviceCapabilities = struct {
    max_supported_bcd_usb: types.Version = .v1_00,
    /// Maximum packet size on ep0
    max_packet_size0: types.PacketLength,
    /// Maximum packet size on other endpoints
    max_packet_size: types.PacketLength,
    default_vendor: ?Options.IdStringPair = null,
    default_product: ?Options.IdStringPair = null,
};

/// Wraps a Descriptor type. Returned by the `create` method of the Descriptor.
pub fn DriverInfo(Descriptor: type) type {
    return struct {
        /// If not void, a pointer to a value of this type
        /// will be passed to driver's init function.
        Alloc: type = void,
        /// Field attributes of `Alloc`
        alloc_attrs: std.builtin.Type.Struct.FieldAttributes = .{},
        Runtime: type,
        descriptor: Descriptor,
    };
}

/// USB Device interface
/// Any device implementation used with DeviceController must implement these functions
pub const DeviceInterface = struct {
    pub const VTable = struct {
        ep_writev: *const fn (*DeviceInterface, types.Endpoint.Num, []const []const u8) types.PacketLength,
        ep_readv: *const fn (*DeviceInterface, types.Endpoint.Num, []const []u8) types.PacketLength,
        ep_listen: *const fn (*DeviceInterface, types.Endpoint.Num, types.PacketLength) void,
        ep_open: *const fn (*DeviceInterface, *const descriptor.Endpoint) void,
        /// Disable and disarm all non-control endpoints, discarding old completions.
        /// Called before replacing or deselecting an active configuration.
        ep_close_all: ?*const fn (*DeviceInterface) void = null,
        set_address: *const fn (*DeviceInterface, u7) void,
        /// The device hands the data stage of a control write to the controller, packet by
        /// packet, and leaves the answer to the request until the controller has seen the
        /// data. A device that sets this keeps to the following on endpoint 0:
        ///
        /// * `ep_listen(.ep0, len)`, called while the controller handles a host-to-device
        ///   request with wLength > 0 or one of its packets, lets the next packet of the
        ///   data stage in. Until then the host's packets are not acknowledged.
        /// * When that packet has arrived, the device calls the controller's
        ///   `on_buffer(.out(.ep0))`, and `ep_readv(.ep0, ...)` then returns the packet.
        /// * `ep_ack(.ep0)` accepts the request: the status stage follows.
        /// * If the controller returns from `on_setup_req` or from `on_buffer(.out(.ep0))`
        ///   having called neither, it has refused the request, and the device answers
        ///   the host with STALL.
        ///
        /// Without it the controller accepts such a request when the SETUP packet arrives,
        /// as it always has, and never sees the data: whether the host's packets are
        /// acknowledged then is up to the device.
        control_out_data: bool = false,
    };

    vtable: *const VTable,

    /// Called by drivers to send a packet.
    pub fn ep_writev(self: *@This(), ep_num: types.Endpoint.Num, data: []const []const u8) types.PacketLength {
        return self.vtable.ep_writev(self, ep_num, data);
    }

    /// Send ack on given IN endpoint.
    pub fn ep_ack(self: *@This(), ep_num: types.Endpoint.Num) void {
        assert(0 == self.ep_writev(ep_num, &.{ack}));
    }

    /// Called by drivers to retrieve a received packet.
    /// Must be called exactly once for each packet.
    /// Buffers in `data` must collectively be long enough to fit the whole packet.
    pub fn ep_readv(self: *@This(), ep_num: types.Endpoint.Num, data: []const []u8) types.PacketLength {
        return self.vtable.ep_readv(self, ep_num, data);
    }

    /// Called by drivers to report readiness to receive up to `len` bytes.
    /// After being called it may not be called again until a packet is received.
    pub fn ep_listen(self: *@This(), ep_num: types.Endpoint.Num, len: types.PacketLength) void {
        return self.vtable.ep_listen(self, ep_num, len);
    }

    /// Opens an endpoint according to the descriptor. Note that if the endpoint
    /// direction is IN this may call the controller's `on_buffer` function,
    /// so driver initialization must be done before this function is called
    /// on IN endpoint descriptors.
    ///
    /// The endpoint may have been open before: the host can select a configuration
    /// again without a bus reset. `ep_close_all` closes the old configuration;
    /// `ep_open` must leave the endpoint idle, with no packet armed or
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

pub fn DriverHandlers(Descriptor: type, Runtime: type) type {
    var field_names: []const [:0]const u8 = &.{};

    const info = @typeInfo(Descriptor).@"struct";
    for (info.field_names, info.field_types) |field_name, field_type| switch (field_type) {
        descriptor.Endpoint => field_names = field_names ++ .{field_name},
        else => {},
    };

    return @Struct(.auto, null, field_names, &@splat(EndpointHandler(Runtime)), &@splat(.{}));
}

pub const Options = struct {
    pub const IdStringPair = struct {
        id: u16,
        str: []const u8,
    };

    /// Usb specification version. `null` means highest supported by device.
    bcd_usb: ?types.Version = null,
    /// Class, subclass and protocol of this device.
    device_triple: types.ClassSubclassProtocol,
    /// Vendor id and string. `null` means default provided by device
    vendor: ?IdStringPair = null,
    /// Product id and string. `null` means default provided by device
    product: ?IdStringPair = null,
    /// Device version.
    bcd_device: types.Version,
    /// String descriptor 0.
    language: descriptor.String.Language = .English,
    /// Serial number string.
    serial: []const u8,
    /// Largest packet length the hardware supports. Must be a power of 2 and at least 8.
    device_capabilities: DeviceCapabilities,
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

pub fn validate_device(Device: type) void {
    if (!@hasDecl(Device, "device_capabilities"))
        @compileError("USB device " ++ @typeName(Device) ++ " is missing a device_capabilities declaration.");
    if (@TypeOf(Device.device_capabilities) != DeviceCapabilities)
        @compileError("USB device " ++ @typeName(Device) ++ ".device_capabilities has incorrect type.\n" ++
            "Got: " ++ @typeName(@TypeOf(DeviceCapabilities)) ++ ", expected usb.DeviceCapabilities");
}

/// USB device controller
///
/// Responds to host requests and dispatches to the appropriate drivers.
/// When this type is build (at comptime), it builds descriptor and handler tables based on the
/// provided options.
///
/// A driver may take the data stage of a control write, a host-to-device request with
/// wLength > 0 that its `class_request` accepts. Such a driver declares both of:
///
/// * `pub fn class_data(self: *Driver, setup: *const types.SetupPacket, data: []const u8) bool`.
///   It is given the data when the last packet has arrived, and returns whether the request
///   is still accepted.
/// * `pub const class_data_len`, the longest data stage it takes, in bytes. The controller
///   keeps a buffer of the largest one among its drivers, and a request that announces
///   more than its driver's is refused without a call to `class_data`.
///
/// One without the other is a compile error. `class_data` is called only on a device that
/// hands the data stage over (`DeviceInterface.VTable.control_out_data`). On any other the
/// request has its answer when `class_request` returns, and the driver never sees the data.
pub fn DeviceController(options: Options, Configurations: []const type) type {
    // Currently only a single configuration is supported.
    std.debug.assert(Configurations.len == 1);

    return struct {
        /// This parses the drivers' descriptors and creates:
        /// * the configuration descriptor
        /// * table of handlers for endpoints
        /// * table of handlers for interfaces
        const descriptor_parse_result = blk: {
            const max_psize0 = options.device_capabilities.max_packet_size0;
            const max_psize = options.device_capabilities.max_packet_size;
            if (max_psize0 < 8 or !std.math.isPowerOfTwo(max_psize0) or max_psize < 8 or !std.math.isPowerOfTwo(max_psize))
                @compileError("Maximum packet size must be a power of two and at least 8");

            const vendor = options.vendor orelse
                (options.device_capabilities.default_vendor orelse
                    @compileError("Vendor ID not provided and device does not specify a default."));

            const product = options.product orelse
                (options.device_capabilities.default_product orelse
                    @compileError("Product ID not provided and device does not specify a default."));

            var strings: []const []const u8 = &.{};
            strings, const manufacturer_s = dedup_string(strings, vendor.str);
            strings, const product_s = dedup_string(strings, product.str);
            strings, const serial_s = dedup_string(strings, options.serial);

            const desc_device: descriptor.Device = .{
                .bcd_usb = options.bcd_usb orelse options.device_capabilities.max_supported_bcd_usb,
                .device_triple = options.device_triple,
                .max_packet_size0 = max_psize0,
                .vendor = .from(vendor.id),
                .product = .from(product.id),
                .bcd_device = options.bcd_device,
                .manufacturer_s = manufacturer_s,
                .product_s = product_s,
                .serial_s = serial_s,
                .num_configurations = Configurations.len,
            };

            var configs: @Tuple(Configurations) = undefined;
            for (0..Configurations.len) |i|
                configs[i], strings = Configurations[i].create(options.device_capabilities, strings);

            var desc_string: []const descriptor.String = &.{.from_lang(options.language)};
            for (strings) |s|
                desc_string = desc_string ++ [1]descriptor.String{.from_str(s)};

            break :blk .{
                .device_descriptor = desc_device,
                .string_descriptors = desc_string,
                .configurations = configs,
            };
        };

        const device_descriptor = descriptor_parse_result.device_descriptor;
        const string_descriptors = descriptor_parse_result.string_descriptors;
        const configurations = descriptor_parse_result.configurations;

        const config_descriptor = configurations[0].Descriptor{};
        const endpoint2handler = configurations[0].EndpointHandlers{};

        /// The longest data stage of a control write that any driver takes: the largest
        /// `class_data_len` among the drivers that declare `class_data`, 0 without one.
        const control_out_max = blk: {
            var max: usize = 0;
            for (@typeInfo(configurations[0].RuntimeData).@"struct".field_types) |Driver| {
                const takes_data = @hasDecl(Driver, "class_data");
                if (takes_data != @hasDecl(Driver, "class_data_len")) @compileError(
                    "USB driver " ++ @typeName(Driver) ++
                        " must declare `class_data` and `class_data_len` together (see `DeviceController`)",
                );
                if (takes_data) max = @max(max, Driver.class_data_len);
            }
            break :blk max;
        };

        /// If not zero, change the device address at the next opportunity.
        /// Necessary because when the host sets the device address,
        /// the acknowledgement step must use the _old_ address.
        new_address: u8,
        /// 0 - no config set
        cfg_num: u16,
        /// Ep0 data waiting to be sent
        tx_slice: ?[]const u8,
        /// A full final packet short of wLength needs a terminating zero-length packet.
        tx_zlp: bool,
        /// Driver state
        driver_data: ?configurations[0].RuntimeData,
        /// Additional driver allocations (size is comptime-known)
        driver_alloc: configurations[0].DriverAlloc,

        /// Pending control write, its received length, and its bounded data buffer.
        rx_setup: ?types.SetupPacket,
        rx_len: usize,
        rx_data: [control_out_max]u8,

        /// Initial values
        pub const init: @This() = .{
            .new_address = 0,
            .cfg_num = 0,
            .tx_slice = null,
            .tx_zlp = false,
            .rx_setup = null,
            .rx_len = 0,
            .rx_data = undefined,
            .driver_data = null,
            .driver_alloc = undefined,
        };

        /// Returns a pointer to the drivers
        /// or null in case host has not yet configured the device.
        pub fn drivers(self: *@This()) ?*configurations[0].RuntimeData {
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
            // And so is a control write whose data had not all arrived.
            self.tx_slice = null;
            self.tx_zlp = false;
            self.new_address = 0;
            self.rx_setup = null;

            const ret = switch (setup.request_type.recipient) {
                .device => self.process_device_setup(device_itf, setup),
                .interface => self.process_interface_setup(device_itf, setup),
                else => nak,
            };
            if (ret) |data| {
                if (data.len == 0) {
                    // A driver that takes the data of this request gets it before the host
                    // gets its answer: the first packet is let in, and `on_buffer` goes on
                    // from there.
                    if (self.rx_setup != null)
                        device_itf.ep_listen(.ep0, device_descriptor.max_packet_size0)
                    else
                        device_itf.ep_ack(.ep0);
                } else {
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

            const driver = comptime configurations[0].endpoint2driver[@backingInt(ep.dir)][@backingInt(ep.num)];
            const handler = comptime @field(endpoint2handler, @tagName(ep.dir))[@backingInt(ep.num)];

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
            } else if (comptime ep == types.Endpoint.out(.ep0)) {
                if (self.rx_setup != null)
                    self.control_out_packet(device_itf)
                else
                    log.warn("Unhandled packet on ep0 Out", .{});
            }

            if (comptime driver.len != 0) {
                // No configuration is selected (the host deselected it, or the bus was reset)
                // but a packet armed while one was has completed. The drivers that owned it
                // are gone, so there is nobody to tell.
                if (self.driver_data) |*data|
                    handler(&@field(data, driver), ep.num)
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
                        // One byte: bConfigurationValue of the selected configuration, or 0
                        // while there is none (USB 2.0, 9.4.2). There is only one configuration,
                        // which any SET_CONFIGURATION value other than 0 selects.
                        .get_configuration => return if (self.cfg_num == 0)
                            &.{0}
                        else
                            std.mem.asBytes(&config_descriptor.first.configuration_value),
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

        fn process_interface_setup(self: *@This(), device_itf: *DeviceInterface, setup: *const types.SetupPacket) ?[]const u8 {
            const itf_num: u8 = @truncate(setup.index.native());
            switch (itf_num) {
                inline else => |itf| if (comptime itf < configurations[0].interface2driver.len) {
                    const drv = configurations[0].interface2driver[itf];
                    if (self.driver_data) |*data| {
                        const Driver = @FieldType(configurations[0].RuntimeData, drv);
                        const ret = @field(data, drv).class_request(setup);
                        // The driver accepted a request whose data the host has yet to send,
                        // and it takes such data (`class_data`): the request is answered
                        // when the data is here. Only with a device that hands the data
                        // over; with any other the request is accepted now, unseen.
                        if (comptime @hasDecl(Driver, "class_data")) {
                            const accepted = if (ret) |reply| reply.len == 0 else false;
                            if (accepted and device_itf.vtable.control_out_data and
                                setup.request_type.direction == .out and setup.length.native() != 0)
                            {
                                // More than the driver has room for is refused.
                                if (setup.length.native() > Driver.class_data_len) return nak;
                                self.rx_setup = setup.*;
                                self.rx_len = 0;
                            }
                        }
                        return ret;
                    }
                    // A host may address an interface before it selects a configuration, or
                    // after it deselected it. There is no interface then.
                    log.debug("Request for interface {} without a configuration", .{itf_num});
                    return nak;
                } else {
                    log.warn("Interface index ({}) out of range ({})", .{ itf_num, configurations[0].interface2driver.len });
                    return nak;
                },
            }
        }

        /// A packet of the data stage of the control write in `rx_setup` has arrived. With
        /// the last one the driver is given the data and decides the answer: accepted, the
        /// request gets its status stage, and refused it is left for the device to stall.
        ///
        /// The data stage ends with the last byte of wLength or with a packet shorter than
        /// the endpoint's maximum (USB 2.0, 5.5.3). A host that sends more than wLength
        /// announced is refused without a word to the driver.
        fn control_out_packet(self: *@This(), device_itf: *DeviceInterface) void {
            const setup = self.rx_setup.?;
            const wanted: usize = setup.length.native();
            var packet: [device_descriptor.max_packet_size0]u8 = undefined;
            const len = device_itf.ep_readv(.ep0, &.{&packet});
            if (len > wanted - self.rx_len) {
                log.warn("Control write: more data than wLength ({})", .{wanted});
                self.rx_setup = null;
                return;
            }
            @memcpy(self.rx_data[self.rx_len..][0..len], packet[0..len]);
            self.rx_len += len;
            if (self.rx_len < wanted and len == packet.len) {
                device_itf.ep_listen(.ep0, device_descriptor.max_packet_size0);
                return;
            }
            self.rx_setup = null;
            if (self.control_out_deliver(&setup, self.rx_data[0..self.rx_len]))
                device_itf.ep_ack(.ep0);
        }

        /// Hands the data stage of a control write to the driver of the interface the
        /// request names. Returns whether the driver accepted it.
        fn control_out_deliver(self: *@This(), setup: *const types.SetupPacket, data: []const u8) bool {
            const itf_num: u8 = @truncate(setup.index.native());
            switch (itf_num) {
                inline else => |itf| if (comptime itf < configurations[0].interface2driver.len) {
                    const drv = configurations[0].interface2driver[itf];
                    const Driver = @FieldType(configurations[0].RuntimeData, drv);
                    if (comptime @hasDecl(Driver, "class_data")) {
                        if (self.driver_data) |*drivers_now|
                            return @field(drivers_now, drv).class_data(setup, data);
                    }
                    return false;
                } else return false,
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

            if (self.driver_data) |*data_old| {
                if (device_itf.vtable.ep_close_all) |close| close(device_itf);
                configurations[0].deinit(device_itf, data_old);
            }

            self.cfg_num = cfg_num;
            if (cfg_num == 0)
                self.driver_data = null
            else {
                // We support just one config for now so ignore config index
                self.driver_data = @as(configurations[0].RuntimeData, undefined);
                configurations[0].init(device_itf, &self.driver_data.?, &self.driver_alloc, config_descriptor);
            }
        }
    };
}

fn dedup_string(
    comptime strings: []const []const u8,
    comptime new: []const u8,
) struct { []const []const u8, u8 } {
    if (new.len == 0)
        return .{ strings, 0 };
    // deduplicate
    for (strings, 1..) |s, i| {
        if (std.mem.eql(u8, s, new))
            return .{ strings, i };
    }
    const new_strings = strings ++ .{new};
    return .{ new_strings, @intCast(new_strings.len) };
}

/// A device for the tests below: it counts what the controller and the drivers ask of it and
/// takes up to `packet_size` bytes of each write.
const TestDevice = struct {
    interface: DeviceInterface = .{ .vtable = &vtable },
    opened: usize = 0,
    closed: usize = 0,
    data_armed: bool = false,
    record_endpoint_calls: bool = false,
    endpoint_calls: [32]u8 = undefined,
    endpoint_calls_len: usize = 0,

    control: ControlRequest = .{},
    listened: usize = 0,
    written: usize = 0,
    /// The most an endpoint takes in one write, and what the last write was given credit for.
    packet_size: types.PacketLength = 64,
    last_written_len: types.PacketLength = 0,
    /// The bytes of the last write, as far as it was given credit for them.
    last_written_data: [64]u8 = @splat(0),
    /// The address of the last `set_address`, if there was one.
    address: ?u7 = null,
    /// What the next `ep_readv` returns: the packet the host sent.
    rx_packet: []const u8 = "",

    fn record(dev: *TestDevice, event: u8) void {
        if (!dev.record_endpoint_calls) return;
        dev.endpoint_calls[dev.endpoint_calls_len] = event;
        dev.endpoint_calls_len += 1;
    }

    const vtable: DeviceInterface.VTable = .{
        .ep_writev = ep_writev,
        .ep_readv = ep_readv,
        .ep_listen = ep_listen,
        .ep_open = ep_open,
        .ep_close_all = ep_close_all,
        .set_address = set_address,
    };

    /// The same device, handing the data stage of a control write to the controller.
    const vtable_control_out: DeviceInterface.VTable = .{
        .ep_writev = ep_writev,
        .ep_readv = ep_readv,
        .ep_listen = ep_listen,
        .ep_open = ep_open,
        .ep_close_all = ep_close_all,
        .set_address = set_address,
        .control_out_data = true,
    };

    fn from(itf: *DeviceInterface) *TestDevice {
        return @fieldParentPtr("interface", itf);
    }

    fn ep_writev(itf: *DeviceInterface, ep_num: types.Endpoint.Num, data: []const []const u8) types.PacketLength {
        const dev = from(itf);
        if (ep_num == .ep0) dev.control.reply();
        dev.written += 1;
        var len: usize = 0;
        for (data) |chunk| {
            for (chunk) |byte| {
                if (len < dev.packet_size and len < dev.last_written_data.len)
                    dev.last_written_data[len] = byte;
                len += 1;
            }
        }
        dev.last_written_len = @intCast(@min(len, dev.packet_size));
        return dev.last_written_len;
    }

    fn ep_readv(itf: *DeviceInterface, _: types.Endpoint.Num, data: []const []u8) types.PacketLength {
        const dev = from(itf);
        var rest = dev.rx_packet;
        for (data) |dst| {
            const len = @min(dst.len, rest.len);
            @memcpy(dst[0..len], rest[0..len]);
            rest = rest[len..];
        }
        return @intCast(dev.rx_packet.len - rest.len);
    }

    fn ep_listen(itf: *DeviceInterface, ep_num: types.Endpoint.Num, _: types.PacketLength) void {
        if (ep_num == .ep0) from(itf).control.listen();
        if (ep_num != .ep0) {
            from(itf).record('l');
            from(itf).data_armed = true;
        }
        from(itf).listened += 1;
    }

    fn ep_open(itf: *DeviceInterface, _: *const descriptor.Endpoint) void {
        from(itf).record('o');
        from(itf).opened += 1;
    }

    fn ep_close_all(itf: *DeviceInterface) void {
        from(itf).record('c');
        from(itf).closed += 1;
        from(itf).data_armed = false;
    }

    fn set_address(itf: *DeviceInterface, address: u7) void {
        from(itf).address = address;
    }
};

fn test_options() Options {
    return .{
        .bcd_usb = .v2_00,
        .device_triple = .unspecified,
        .vendor = .{ .id = 0x1209, .str = "MicroZig" },
        .product = .{ .id = 0x0001, .str = "test" },
        .bcd_device = .v1_00,
        .serial = "0",
        .device_capabilities = .{ .max_packet_size0 = 64, .max_packet_size = 64 },
    };
}

fn test_configuration(driver_config: anytype) type {
    return Configuration(.{
        .attributes = .{ .self_powered = false },
        .max_current_ma = 50,
    }, driver_config);
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
        test_options(),
        &.{test_configuration(.{ .echo = drivers.EchoExample{ .itf_string = "echo" } })},
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
        test_options(),
        &.{test_configuration(.{ .serial = drivers.CDC{} })},
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
        test_options(),
        &.{test_configuration(.{ .serial = drivers.CDC{} })},
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
        test_options(),
        &.{test_configuration(.{ .echo = drivers.EchoExample{ .itf_string = "echo" } })},
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

test "a control read that ends on a packet boundary short of wLength ends with a zero-length packet" {
    // EP0 packets of 8 bytes, and a product string of three characters: its descriptor is
    // exactly 8 bytes (2 of header, 2 per UTF-16 code unit).
    const cfg = comptime blk: {
        var c = test_options();
        c.device_capabilities.max_packet_size0 = 8;
        c.device_capabilities.max_packet_size = 8;
        c.product.?.str = "abc";
        break :blk c;
    };
    const Controller = DeviceController(cfg, &.{test_configuration(.{ .echo = drivers.EchoExample{ .itf_string = "echo" } })});
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

test "GET_CONFIGURATION returns the selected configuration, or 0 without one" {
    const Controller = DeviceController(
        test_options(),
        &.{test_configuration(.{ .echo = drivers.EchoExample{ .itf_string = "echo" } })},
    );
    const ep0_in = comptime types.Endpoint.in(.ep0);
    const get_configuration: types.SetupPacket = .{
        .request_type = .{ .recipient = .device, .type = .standard, .direction = .in },
        .request = @backingInt(types.SetupRequest.get_configuration),
        .value = .from(0),
        .index = .from(0),
        .length = .from(1),
    };
    var dev: TestDevice = .{};
    var ctl: Controller = .init;

    // What the host does to the device, and the one byte it then reads back. A request the
    // controller does not answer is stalled by the HAL, and nothing is written for it.
    const steps = [_]struct { set: ?u16, expected: u8 }{
        // Address state: no SET_CONFIGURATION yet.
        .{ .set = null, .expected = 0 },
        .{ .set = 1, .expected = 1 },
        // Back in the Address state.
        .{ .set = 0, .expected = 0 },
    };
    for (steps) |step| {
        if (step.set) |value| ctl.on_setup_req(&dev.interface, &test_set_configuration(value));
        const written = dev.written;
        ctl.on_setup_req(&dev.interface, &get_configuration);
        try std.testing.expectEqual(written + 1, dev.written);
        try std.testing.expectEqualSlices(u8, &.{step.expected}, dev.last_written_data[0..dev.last_written_len]);
        // The byte is all the host asked for: no zero-length packet follows it.
        ctl.on_buffer(&dev.interface, ep0_in);
        try std.testing.expectEqual(written + 1, dev.written);
    }
}

/// A driver for the tests below: one interface without endpoints, which takes up to 20 bytes
/// of data with request 1 and refuses data that starts with 0xFF.
const TestDataDriver = struct {
    pub const Descriptor = extern struct {
        itf: descriptor.Interface,
    };

    pub fn driver_info(_: @This(), comptime _: DeviceCapabilities, alloc: *DescriptorAllocator) DriverInfo(Descriptor) {
        return .{ .Runtime = Runtime, .descriptor = .{ .itf = .{
            .interface_number = alloc.next_itf(),
            .alternate_setting = 0,
            .num_endpoints = 0,
            .interface_triple = .vendor_specific,
            .interface_s = 0,
        } } };
    }
    pub const Runtime = struct {
        pub const handlers: DriverHandlers(Descriptor, @This()) = .{};
        pub const class_data_len = 20;

        data: [class_data_len]u8,
        data_len: ?usize,

        pub fn init(self: *@This(), _: TestDataDriver, _: *const Descriptor, _: *DeviceInterface) void {
            self.* = .{ .data = undefined, .data_len = null };
        }

        pub fn class_request(_: *@This(), setup: *const types.SetupPacket) ?[]const u8 {
            return if (setup.request == 1) ack else nak;
        }

        pub fn class_data(self: *@This(), _: *const types.SetupPacket, data: []const u8) bool {
            if (data.len != 0 and data[0] == 0xFF) return false;
            @memcpy(self.data[0..data.len], data);
            self.data_len = data.len;
            return true;
        }
    };
};

fn test_data_request(request: u8, length: u16) types.SetupPacket {
    return .{
        .request_type = .{ .recipient = .interface, .type = .class, .direction = .out },
        .request = request,
        .value = .from(0),
        .index = .from(0),
        .length = .from(length),
    };
}

test "SET_LINE_CODING reaches the CDC driver on a device that hands over the data stage" {
    const Controller = DeviceController(
        test_options(),
        &.{test_configuration(.{ .serial = drivers.CDC{} })},
    );
    const cdc = Controller.config_descriptor.drv.serial;
    const ep0_out = comptime types.Endpoint.out(.ep0);
    const set_line_coding: types.SetupPacket = .{
        .request_type = .{ .recipient = .interface, .type = .class, .direction = .out },
        .request = @backingInt(drivers.CDC.ManagementRequestType.SetLineCoding),
        .value = .from(0),
        .index = .from(cdc.itf_notifi.interface_number),
        .length = .from(7),
    };
    const get_line_coding: types.SetupPacket = .{
        .request_type = .{ .recipient = .interface, .type = .class, .direction = .in },
        .request = @backingInt(drivers.CDC.ManagementRequestType.GetLineCoding),
        .value = .from(0),
        .index = .from(cdc.itf_notifi.interface_number),
        .length = .from(7),
    };
    // 9600 baud little-endian, 2 stop bits, even parity, 7 data bits.
    const coding = [_]u8{ 0x80, 0x25, 0x00, 0x00, 2, 2, 7 };

    var dev: TestDevice = .{ .interface = .{ .vtable = &TestDevice.vtable_control_out } };
    var ctl: Controller = .init;
    ctl.on_setup_req(&dev.interface, &test_set_configuration(1));
    var written = dev.written;
    var listened = dev.listened;

    // The request is not answered when it arrives: the controller listens for the data.
    ctl.on_setup_req(&dev.interface, &set_line_coding);
    try std.testing.expectEqual(written, dev.written);
    try std.testing.expectEqual(listened + 1, dev.listened);

    // The 7 bytes arrive: the driver has them, and the request gets its status stage.
    dev.rx_packet = &coding;
    ctl.on_buffer(&dev.interface, ep0_out);
    try std.testing.expectEqual(written + 1, dev.written);
    try std.testing.expectEqual(0, dev.last_written_len);
    try std.testing.expectEqual(listened + 1, dev.listened);
    try std.testing.expectEqualSlices(u8, &coding, std.mem.asBytes(&ctl.drivers().?.serial.line_coding));

    // The host reads back what it set.
    ctl.on_setup_req(&dev.interface, &get_line_coding);
    try std.testing.expectEqualSlices(u8, &coding, dev.last_written_data[0..dev.last_written_len]);

    // A data stage of the wrong length is refused: no status stage, and nothing changes.
    written = dev.written;
    listened = dev.listened;
    ctl.on_setup_req(&dev.interface, &set_line_coding);
    dev.rx_packet = &.{ 1, 2, 3 };
    ctl.on_buffer(&dev.interface, ep0_out);
    try std.testing.expectEqual(written, dev.written);
    try std.testing.expectEqualSlices(u8, &coding, std.mem.asBytes(&ctl.drivers().?.serial.line_coding));

    // So is a request that announces more than the structure holds, when it arrives.
    var too_long = set_line_coding;
    too_long.length = .from(8);
    ctl.on_setup_req(&dev.interface, &too_long);
    try std.testing.expectEqual(written, dev.written);
    try std.testing.expectEqual(listened + 1, dev.listened);

    // A packet on EP0 OUT that belongs to no such request is not read.
    dev.rx_packet = &.{ 9, 9, 9, 9, 9, 9, 9 };
    ctl.on_buffer(&dev.interface, ep0_out);
    try std.testing.expectEqual(written, dev.written);
    try std.testing.expectEqualSlices(u8, &coding, std.mem.asBytes(&ctl.drivers().?.serial.line_coding));
}

test "a device that keeps the data stage to itself has SET_LINE_CODING accepted at once" {
    const Controller = DeviceController(
        test_options(),
        &.{test_configuration(.{ .serial = drivers.CDC{} })},
    );
    const cdc = Controller.config_descriptor.drv.serial;
    const set_line_coding: types.SetupPacket = .{
        .request_type = .{ .recipient = .interface, .type = .class, .direction = .out },
        .request = @backingInt(drivers.CDC.ManagementRequestType.SetLineCoding),
        .value = .from(0),
        .index = .from(cdc.itf_notifi.interface_number),
        .length = .from(7),
    };

    var dev: TestDevice = .{};
    var ctl: Controller = .init;
    ctl.on_setup_req(&dev.interface, &test_set_configuration(1));
    const written = dev.written;
    const listened = dev.listened;

    // As before: accepted when the SETUP packet arrives, and nobody listens on EP0.
    ctl.on_setup_req(&dev.interface, &set_line_coding);
    try std.testing.expectEqual(written + 1, dev.written);
    try std.testing.expectEqual(0, dev.last_written_len);
    try std.testing.expectEqual(listened, dev.listened);

    // A packet on EP0 OUT is not read, and the line coding stays what it was.
    dev.rx_packet = &.{ 0x80, 0x25, 0x00, 0x00, 2, 2, 7 };
    ctl.on_buffer(&dev.interface, comptime types.Endpoint.out(.ep0));
    try std.testing.expectEqual(written + 1, dev.written);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&drivers.CDC.LineCoding.init),
        std.mem.asBytes(&ctl.drivers().?.serial.line_coding),
    );
}

test "the data stage of a control write is collected over its packets" {
    // EP0 packets of 8 bytes, and a driver that takes up to 20 bytes.
    const cfg = comptime blk: {
        var c = test_options();
        c.device_capabilities.max_packet_size0 = 8;
        c.device_capabilities.max_packet_size = 8;
        break :blk c;
    };
    const Controller = DeviceController(cfg, &.{test_configuration(.{ .data = TestDataDriver{} })});
    const ep0_out = comptime types.Endpoint.out(.ep0);
    const bytes = [20]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 };

    var dev: TestDevice = .{
        .interface = .{ .vtable = &TestDevice.vtable_control_out },
        .packet_size = 8,
    };
    var ctl: Controller = .init;
    ctl.on_setup_req(&dev.interface, &test_set_configuration(1));
    const driver = &ctl.drivers().?.data;

    // 20 bytes: 8, 8 and 4. The controller listens for each packet and answers after the
    // last, which is the one that carries the last byte of wLength.
    {
        const written = dev.written;
        const listened = dev.listened;
        ctl.on_setup_req(&dev.interface, &test_data_request(1, 20));
        dev.rx_packet = bytes[0..8];
        ctl.on_buffer(&dev.interface, ep0_out);
        dev.rx_packet = bytes[8..16];
        ctl.on_buffer(&dev.interface, ep0_out);
        try std.testing.expectEqual(listened + 3, dev.listened);
        try std.testing.expectEqual(written, dev.written);
        try std.testing.expectEqual(null, driver.data_len);
        dev.rx_packet = bytes[16..20];
        ctl.on_buffer(&dev.interface, ep0_out);
        try std.testing.expectEqual(listened + 3, dev.listened);
        try std.testing.expectEqual(written + 1, dev.written);
        try std.testing.expectEqualSlices(u8, &bytes, driver.data[0..driver.data_len.?]);
    }

    // 16 bytes end on a full packet: wLength says that it was the last.
    {
        const written = dev.written;
        ctl.on_setup_req(&dev.interface, &test_data_request(1, 16));
        dev.rx_packet = bytes[0..8];
        ctl.on_buffer(&dev.interface, ep0_out);
        try std.testing.expectEqual(written, dev.written);
        dev.rx_packet = bytes[8..16];
        ctl.on_buffer(&dev.interface, ep0_out);
        try std.testing.expectEqual(written + 1, dev.written);
        try std.testing.expectEqual(16, driver.data_len);
    }

    // The host sends less than it announced: the short packet ends the data stage.
    {
        const written = dev.written;
        ctl.on_setup_req(&dev.interface, &test_data_request(1, 20));
        dev.rx_packet = bytes[0..8];
        ctl.on_buffer(&dev.interface, ep0_out);
        dev.rx_packet = bytes[8..11];
        ctl.on_buffer(&dev.interface, ep0_out);
        try std.testing.expectEqual(written + 1, dev.written);
        try std.testing.expectEqual(11, driver.data_len);
    }

    // The host sends more than it announced: refused, and the driver is not asked.
    {
        const written = dev.written;
        ctl.on_setup_req(&dev.interface, &test_data_request(1, 4));
        dev.rx_packet = bytes[0..8];
        ctl.on_buffer(&dev.interface, ep0_out);
        try std.testing.expectEqual(written, dev.written);
        try std.testing.expectEqual(11, driver.data_len);
    }

    // Data the driver refuses gets no status stage.
    {
        const written = dev.written;
        ctl.on_setup_req(&dev.interface, &test_data_request(1, 2));
        dev.rx_packet = &.{ 0xFF, 0 };
        ctl.on_buffer(&dev.interface, ep0_out);
        try std.testing.expectEqual(written, dev.written);
        try std.testing.expectEqual(11, driver.data_len);
    }

    // More than the driver takes, a request it does not know, and a request without data:
    // answered when the SETUP packet arrives, and nobody listens on EP0.
    {
        const written = dev.written;
        const listened = dev.listened;
        ctl.on_setup_req(&dev.interface, &test_data_request(1, 21));
        ctl.on_setup_req(&dev.interface, &test_data_request(2, 4));
        try std.testing.expectEqual(written, dev.written);
        ctl.on_setup_req(&dev.interface, &test_data_request(1, 0));
        try std.testing.expectEqual(written + 1, dev.written);
        try std.testing.expectEqual(listened, dev.listened);
    }
}

test "a new setup request drops a control write whose data had not all arrived" {
    const cfg = comptime blk: {
        var c = test_options();
        c.device_capabilities.max_packet_size0 = 8;
        c.device_capabilities.max_packet_size = 8;
        break :blk c;
    };
    const Controller = DeviceController(cfg, &.{test_configuration(.{ .data = TestDataDriver{} })});
    const ep0_out = comptime types.Endpoint.out(.ep0);

    var dev: TestDevice = .{
        .interface = .{ .vtable = &TestDevice.vtable_control_out },
        .packet_size = 8,
    };
    var ctl: Controller = .init;
    ctl.on_setup_req(&dev.interface, &test_set_configuration(1));
    const driver = &ctl.drivers().?.data;

    // The first packet of 20 bytes, then the host gives up and asks for a descriptor.
    ctl.on_setup_req(&dev.interface, &test_data_request(1, 20));
    dev.rx_packet = &.{ 1, 2, 3, 4, 5, 6, 7, 8 };
    ctl.on_buffer(&dev.interface, ep0_out);
    ctl.on_setup_req(&dev.interface, &test_get_descriptor(0x0100, 18));
    const written = dev.written;
    const listened = dev.listened;

    // A packet on EP0 OUT now belongs to nothing: not read, not answered.
    dev.rx_packet = &.{ 9, 10, 11, 12 };
    ctl.on_buffer(&dev.interface, ep0_out);
    try std.testing.expectEqual(written, dev.written);
    try std.testing.expectEqual(listened, dev.listened);
    try std.testing.expectEqual(null, driver.data_len);

    // And the next control write starts from its own first byte.
    ctl.on_setup_req(&dev.interface, &test_data_request(1, 4));
    dev.rx_packet = &.{ 21, 22, 23, 24 };
    ctl.on_buffer(&dev.interface, ep0_out);
    try std.testing.expectEqualSlices(u8, &.{ 21, 22, 23, 24 }, driver.data[0..driver.data_len.?]);
}

test "a bus reset drops a control write whose data had not all arrived" {
    const cfg = comptime blk: {
        var c = test_options();
        c.device_capabilities.max_packet_size0 = 8;
        c.device_capabilities.max_packet_size = 8;
        break :blk c;
    };
    const Controller = DeviceController(cfg, &.{test_configuration(.{ .data = TestDataDriver{} })});
    const ep0_out = comptime types.Endpoint.out(.ep0);

    var dev: TestDevice = .{
        .interface = .{ .vtable = &TestDevice.vtable_control_out },
        .packet_size = 8,
    };
    var ctl: Controller = .init;
    ctl.on_setup_req(&dev.interface, &test_set_configuration(1));

    // The first packet of 20 bytes, then the bus is reset.
    ctl.on_setup_req(&dev.interface, &test_data_request(1, 20));
    dev.rx_packet = &.{ 1, 2, 3, 4, 5, 6, 7, 8 };
    ctl.on_buffer(&dev.interface, ep0_out);
    ctl.on_bus_reset(&dev.interface);
    const written = dev.written;
    const listened = dev.listened;

    // A packet on EP0 OUT now belongs to nothing. It would be the second of three, after
    // which the controller listens for the third: it does not, and it answers nothing.
    dev.rx_packet = &.{ 9, 10, 11, 12, 13, 14, 15, 16 };
    ctl.on_buffer(&dev.interface, ep0_out);
    try std.testing.expectEqual(written, dev.written);
    try std.testing.expectEqual(listened, dev.listened);

    // Configured again, the next control write starts from its own first byte.
    ctl.on_setup_req(&dev.interface, &test_set_configuration(1));
    const driver = &ctl.drivers().?.data;
    try std.testing.expectEqual(null, driver.data_len);
    ctl.on_setup_req(&dev.interface, &test_data_request(1, 4));
    dev.rx_packet = &.{ 21, 22, 23, 24 };
    ctl.on_buffer(&dev.interface, ep0_out);
    try std.testing.expectEqualSlices(u8, &.{ 21, 22, 23, 24 }, driver.data[0..driver.data_len.?]);
}

test "software EP0 delivers a control write before acknowledging it" {
    const Controller = DeviceController(
        test_options(),
        &.{test_configuration(.{ .serial = drivers.CDC{} })},
    );
    var dev: TestDevice = .{ .interface = .{ .vtable = &TestDevice.vtable_control_out } };
    var ctl: Controller = .init;
    ctl.on_setup_req(&dev.interface, &test_set_configuration(1));
    const set_line_coding: types.SetupPacket = .{
        .request_type = @bitCast(@as(u8, 0x21)),
        .request = 0x20,
        .value = .from(0),
        .index = .from(0),
        .length = .from(7),
    };
    dev.control.setup(&set_line_coding);
    const written = dev.written;
    ctl.on_setup_req(&dev.interface, &set_line_coding);
    try std.testing.expect(!dev.control.needs_stall());
    try std.testing.expectEqual(written, dev.written);
    try std.testing.expect(dev.control.out_packet());
    dev.rx_packet = &.{ 0x00, 0xc2, 0x01, 0x00, 0, 0, 8 }; // 115200, 8N1
    ctl.on_buffer(&dev.interface, .out(.ep0));
    try std.testing.expect(!dev.control.needs_stall());
    try std.testing.expect(!dev.control.out_data);
    try std.testing.expectEqual(written + 1, dev.written);
    try std.testing.expectEqual(0, dev.last_written_len);

    // An incomplete line coding is refused after the data callback, rather than ACKed.
    dev.control.setup(&set_line_coding);
    ctl.on_setup_req(&dev.interface, &set_line_coding);
    try std.testing.expect(dev.control.out_packet());
    dev.rx_packet = &.{ 1, 2, 3 };
    ctl.on_buffer(&dev.interface, .out(.ep0));
    try std.testing.expect(dev.control.needs_stall());
}

test "software EP0 stalls unhandled requests and clears the decision at SETUP" {
    const Controller = DeviceController(
        test_options(),
        &.{test_configuration(.{ .serial = drivers.CDC{} })},
    );
    var dev: TestDevice = .{ .interface = .{ .vtable = &TestDevice.vtable_control_out } };
    var ctl: Controller = .init;
    ctl.on_setup_req(&dev.interface, &test_set_configuration(1));
    for ([_]u8{ 0x21, 0xa1 }) |request_type| {
        const unknown: types.SetupPacket = .{
            .request_type = @bitCast(request_type),
            .request = 0xff,
            .value = .from(0),
            .index = .from(0),
            .length = .from(7),
        };
        dev.control.setup(&unknown);
        ctl.on_setup_req(&dev.interface, &unknown);
        try std.testing.expect(dev.control.needs_stall());
        const get = test_get_descriptor(0x0100, 18);
        dev.control.setup(&get);
        ctl.on_setup_req(&dev.interface, &get);
        try std.testing.expect(!dev.control.needs_stall());
        try std.testing.expect(!dev.control.out_packet()); // status OUT
    }
}

test "SET_CONFIGURATION with the current value opens the endpoints again" {
    const Controller = DeviceController(
        test_options(),
        &.{test_configuration(.{ .serial = drivers.CDC{} })},
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

test "reconfiguration and deconfiguration close the old endpoints before reuse" {
    const Controller = DeviceController(
        test_options(),
        &.{test_configuration(.{ .serial = drivers.CDC{} })},
    );
    var dev: TestDevice = .{ .record_endpoint_calls = true };
    var ctl: Controller = .init;
    ctl.on_setup_req(&dev.interface, &test_set_configuration(1));
    try std.testing.expectEqual(0, dev.closed);
    try std.testing.expect(dev.data_armed);
    // OUT opens before init listens, then the two IN endpoints open.
    try std.testing.expectEqualStrings("oloo", dev.endpoint_calls[0..dev.endpoint_calls_len]);
    ctl.on_setup_req(&dev.interface, &test_set_configuration(1));
    try std.testing.expectEqual(1, dev.closed);
    // Closure must precede both reuse (open) and the new driver's listen.
    try std.testing.expectEqualStrings("oloocoloo", dev.endpoint_calls[0..dev.endpoint_calls_len]);
    ctl.on_setup_req(&dev.interface, &test_set_configuration(0));
    try std.testing.expectEqual(2, dev.closed);
    try std.testing.expect(!dev.data_armed);
    try std.testing.expectEqualStrings("oloocolooc", dev.endpoint_calls[0..dev.endpoint_calls_len]);
    ctl.on_setup_req(&dev.interface, &test_set_configuration(0));
    try std.testing.expectEqual(2, dev.closed);
}

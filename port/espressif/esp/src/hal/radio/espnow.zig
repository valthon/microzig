//! ESP-NOW over the pinned vendor blob. One stationary Session, one calling task.
//! Start Wi-Fi before init; deinit before stopping Wi-Fi. Do not call the C ESP-NOW
//! API alongside this wrapper. No allocation in the Zig data path; the vendor
//! driver manages its own buffers. See README for queue and delivery semantics.
const state = @import("espnow_state.zig");
const implementation = @import("espnow_session.zig");
pub const Session = implementation.Driver(@import("espnow_platform.zig")).Session;
pub const Counts = implementation.Counts;
pub const Error = state.Error;
pub const Mac = state.Mac;
pub const Key = state.Key;
pub const Peer = state.Peer;
pub const Frame = state.Frame;
pub const Delivery = state.Delivery;
pub const broadcast = state.broadcast;
pub const max_payload = state.max_payload;
pub const receive_capacity = state.capacity;
pub const payload_limit = state.payload_limit;

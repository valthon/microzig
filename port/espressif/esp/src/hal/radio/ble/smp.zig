//! Allocation-free LE Secure Connections, Core v5.4 Vol 3 Part H §§2–3.
//! One procedure per connection. Legacy/OOB/CTKD/signing are not supported.
const std = @import("std");
pub const crypto = @import("smp_crypto.zig");
pub const bonds = @import("smp_bond.zig");
const Key = crypto.Key;
const Address = crypto.Address;
pub const Error = error{ CryptoFailed, NoBuffer };
pub const IoCapability = enum(u8) { display_only, display_yes_no, keyboard_only, no_input_output, keyboard_display };
/// `.cancel` withdraws the `.compare` or `.input` the hook was last asked and
/// has not answered; see `Config.io_fn`.
pub const IoRequest = union(enum) { compare: u32, display: u32, input, cancel };
/// An IO hook's answer. `.pending` means "not yet": the host keeps exchanging
/// packets and asks again on its next poll.
pub const IoAnswer = union(enum) { pending, accept, reject, passkey: u32 };
pub const Point = struct { x: [32]u8, y: [32]u8 };
pub const KeyPair = struct { public: Point, private: [32]u8 };
pub const Crypto = struct {
    context: ?*anyopaque = null,
    random_fn: *const fn (?*anyopaque, []u8) Error!void,
    key_pair_fn: *const fn (?*anyopaque) Error!KeyPair,
    dh_fn: *const fn (?*anyopaque, [32]u8, Point) Error![32]u8,
};
pub const Config = struct {
    crypto: Crypto,
    io: IoCapability = .no_input_output,
    require_authenticated: bool = false,
    /// The hook must not block and must not call the host. `.display` is a
    /// notification; its answer is ignored. `.compare` and `.input` are asked
    /// again on every host poll until answered `.accept`/`.reject` (compare)
    /// or `.passkey` 0..999999/`.reject` (input). Return `.pending` while the
    /// user decides: the peer may need this side's next PDU before its own
    /// number or passkey is visible (Core v5.4 Vol 3 Part H §§2.3.5.6.2–3).
    /// That PDU is queued before the hook is first asked and transmitted after
    /// it returns, so the hook may display its prompt before the peer has it.
    /// The 30 s SMP timer (§3.4) keeps running meanwhile.
    /// If the procedure ends before an asked request is answered (SMP
    /// timeout, the peer's Pairing Failed, a local abort, an encryption
    /// failure or disconnect), the hook receives one `.cancel` and is not
    /// asked that request again; its answer is ignored. So a request asked
    /// after an answer or a `.cancel` is a new one.
    io_context: ?*anyopaque = null,
    io_fn: ?*const fn (?*anyopaque, IoRequest) IoAnswer = null,
    store: ?bonds.Store = null,
    /// Stable local identity key. Persist it separately from peer bonds.
    irk: ?Key = null,
};
/// `compare`: Numeric Comparison values are computed and the local user's
/// answer is outstanding.
pub const State = enum { idle, response, public_key, confirm, random, compare, dh_check, encryption, distribution, complete, failed, timed_out };
pub const Method = enum { just_works, numeric_comparison, passkey_display, passkey_input };
pub const Failure = enum(u8) {
    passkey_failed = 1,
    authentication_requirements = 3,
    confirm_failed = 4,
    pairing_not_supported = 5,
    key_size = 6,
    command_not_supported = 7,
    unspecified = 8,
    invalid_parameters = 0x0a,
    dhkey_failed = 0x0b,
    numeric_failed = 0x0c,
};
pub const Pdu = struct {
    len: u8,
    bytes: [65]u8,
    pub fn data(self: *const Pdu) []const u8 {
        return self.bytes[0..self.len];
    }
};
pub const Session = struct {
    config: Config,
    central: bool,
    local: Address,
    peer: Address,
    state: State = .idle,
    method: Method = .just_works,
    failure: ?u8 = null,
    deadline: u64 = 0,
    encrypted: bool = false,
    authenticated: bool = false,
    bonded: bool = false,
    pairing_count: u32 = 0,
    request: [7]u8 = @splat(0),
    response: [7]u8 = @splat(0),
    keys: KeyPair = .{ .public = .{ .x = @splat(0), .y = @splat(0) }, .private = @splat(0) },
    remote: Point = .{ .x = @splat(0), .y = @splat(0) },
    dh: [32]u8 = @splat(0),
    nonce: Key = @splat(0),
    peer_nonce: Key = @splat(0),
    confirm: Key = @splat(0),
    derived: crypto.Derived = .{ .mac = @splat(0), .ltk = @splat(0) },
    passkey: u32 = 0,
    round: u5 = 0,
    peer_irk: Key = @splat(0),
    identity: Address = @splat(0),
    received_identity: u2 = 0,
    sent_identity: bool = false,
    start_encryption: bool = false,
    save_bond: bool = false,
    queue: [4]Pdu = undefined,
    queued: u3 = 0,
    /// The comparison or passkey input the IO hook has not answered yet.
    io_request: ?IoRequest = null,
    /// The hook has been asked `io_request`: withdrawing it sends `.cancel`.
    io_asked: bool = false,
    /// The first Passkey Entry confirm waits for the typed passkey.
    confirm_owed: bool = false,
    /// A responder holds the initiator's DHKey Check until its user accepts
    /// the comparison (§2.3.5.6.5 follows stage 1).
    peer_check: ?Key = null,

    pub fn init(config: Config, central: bool, local: Address, peer: Address) Session {
        return .{ .config = config, .central = central, .local = local, .peer = peer, .identity = peer };
    }
    /// The caller owns the returned copy and wipes it after sending: it may
    /// carry the local IRK. The vacated queue slot is wiped here.
    pub fn pop(self: *Session) ?Pdu {
        if (self.queued == 0) return null;
        const pdu = self.queue[0];
        self.queued -= 1;
        std.mem.copyForwards(Pdu, self.queue[0..self.queued], self.queue[1..][0..self.queued]);
        std.crypto.secureZero(u8, &self.queue[self.queued].bytes);
        return pdu;
    }
    fn clear_queue(self: *Session) void {
        for (&self.queue) |*pdu| std.crypto.secureZero(u8, &pdu.bytes);
        self.queued = 0;
    }
    /// Drop every queued PDU except Pairing Failed (Core v5.4 Vol 3 Part H
    /// §3.5.5), which still reports this side's failure to the peer.
    fn keep_failures(self: *Session) void {
        var kept: u3 = 0;
        for (self.queue[0..self.queued]) |pdu| {
            if (pdu.bytes[0] != 5) continue;
            self.queue[kept] = pdu;
            kept += 1;
        }
        for (self.queue[kept..]) |*pdu| std.crypto.secureZero(u8, &pdu.bytes);
        self.queued = kept;
    }
    fn send(self: *Session, data: []const u8) Error!void {
        if (self.queued == self.queue.len) return error.NoBuffer;
        var pdu: Pdu = .{ .len = @intCast(data.len), .bytes = undefined };
        @memcpy(pdu.bytes[0..data.len], data);
        self.queue[self.queued] = pdu;
        self.queued += 1;
    }
    fn send_key(self: *Session, opcode: u8, key: Key) Error!void {
        try self.send(&([1]u8{opcode} ++ crypto.reverse(16, key)));
    }
    pub fn abort(self: *Session, reason: Failure) Error!void {
        self.clear_queue();
        self.erase_secrets();
        self.authenticated = false;
        self.state = .failed;
        self.failure = @backingInt(reason);
        try self.send(&.{ 5, @backingInt(reason) });
    }
    fn erase_secrets(self: *Session) void {
        std.crypto.secureZero(u8, &self.keys.private);
        std.crypto.secureZero(u8, &self.dh);
        std.crypto.secureZero(u8, &self.nonce);
        std.crypto.secureZero(u8, &self.peer_nonce);
        std.crypto.secureZero(u8, &self.derived.mac);
        std.crypto.secureZero(u8, &self.derived.ltk);
        self.passkey = 0;
        self.start_encryption = false;
        self.save_bond = false;
        self.bonded = false;
        self.withdraw_io();
        self.confirm_owed = false;
        if (self.peer_check) |*value| std.crypto.secureZero(u8, value);
        self.peer_check = null;
    }
    fn withdraw_io(self: *Session) void {
        const asked = self.io_asked;
        self.io_request = null;
        self.io_asked = false;
        if (asked) _ = self.config.io_fn.?(self.config.io_context, .cancel);
    }
    pub fn disconnected(self: *Session) void {
        self.erase_secrets();
        self.clear_queue();
        std.crypto.secureZero(u8, &self.peer_irk);
        self.encrypted = false;
        self.authenticated = false;
    }
    /// Timeout poisons this SMP bearer until disconnect, §3.4. No retries.
    pub fn tick(self: *Session, now: u64) void {
        if (self.active() and now >= self.deadline) {
            self.erase_secrets();
            self.clear_queue();
            self.state = .timed_out;
            self.authenticated = false;
        }
    }
    /// Core §3.4: restart the timer when a command is transmitted. The host
    /// supplies the actual time after IO hooks and ACL-credit waits finish.
    pub fn sent(self: *Session, now: u64) void {
        if (self.active()) self.deadline = now + 30_000;
    }
    fn active(self: *const Session) bool {
        return switch (self.state) {
            .idle, .complete, .failed, .timed_out => false,
            else => true,
        };
    }
    fn features(self: *const Session, opcode: u8) [7]u8 {
        const own_identity: u8 = if (self.config.irk != null and self.config.store != null) 2 else 0;
        const peer_identity: u8 = if (self.config.store != null) 2 else 0;
        return .{ opcode, @backingInt(self.config.io), 0, @as(u8, 8) | (if (self.config.store != null) @as(u8, 1) else 0) | (if (self.config.require_authenticated) @as(u8, 4) else 0), 16, if (self.central) own_identity else peer_identity, if (self.central) peer_identity else own_identity };
    }
    pub fn start(self: *Session, now: u64) Error!void {
        if (self.state != .idle or self.encrypted) return;
        self.deadline = now + 30_000;
        if (!self.central) {
            try self.send(&.{ 0x0b, self.features(1)[3] });
            self.state = .response;
            return;
        }
        self.request = self.features(1);
        self.state = .response;
        try self.send(&self.request);
    }
    fn negotiate(self: *Session) Error!bool {
        // Once a fresh exchange starts, the previous key must not satisfy an
        // LTK Request during this procedure. Authentication is granted only
        // after checking the peer's DHKey Check, never from IO negotiation.
        self.bonded = false;
        self.authenticated = false;
        std.crypto.secureZero(u8, &self.derived.ltk);
        const req = self.request;
        const res = self.response;
        if (req[1] > 4 or res[1] > 4 or req[2] > 1 or res[2] > 1 or req[4] > 16 or res[4] > 16 or req[4] < 7 or res[4] < 7 or req[3] & 3 > 1 or res[3] & 3 > 1) {
            try self.abort(.invalid_parameters);
            return false;
        }
        if (req[3] & res[3] & 8 == 0) {
            try self.abort(.pairing_not_supported);
            return false;
        }
        if (req[4] != 16 or res[4] != 16) {
            try self.abort(.key_size);
            return false;
        }
        if (req[2] != 0 or res[2] != 0) {
            try self.abort(.authentication_requirements);
            return false;
        }
        const local_io = @backingInt(self.config.io);
        const remote_io = if (self.central) res[1] else req[1];
        self.method = .just_works;
        if ((req[3] | res[3]) & 4 != 0) {
            if ((local_io == 1 or local_io == 4) and (remote_io == 1 or remote_io == 4)) {
                self.method = .numeric_comparison;
            } else if (local_io == 2 and remote_io != 3) {
                self.method = .passkey_input;
            } else if (local_io != 3 and remote_io == 2) {
                self.method = .passkey_display;
            } else if (local_io == 4 and remote_io == 0) {
                self.method = .passkey_input;
            } else if (local_io == 0 and remote_io == 4) {
                self.method = .passkey_display;
            }
        }
        if (self.config.require_authenticated and self.method == .just_works) {
            try self.abort(.authentication_requirements);
            return false;
        }
        if (self.method != .just_works and self.config.io_fn == null) {
            try self.abort(.authentication_requirements);
            return false;
        }
        if (self.method == .passkey_input) {
            // Asked by poll_io once this feature exchange is queued: a display
            // peer generates its passkey only after it has both features.
            self.io_request = .input;
        } else if (self.method == .passkey_display) {
            var bytes: [4]u8 = undefined;
            // Rejection sampling avoids bias in the six-digit passkey.
            var accepted = false;
            for (0..16) |_| {
                try self.config.crypto.random_fn(self.config.crypto.context, &bytes);
                const value = std.mem.readInt(u32, &bytes, .big);
                if (value >= 4_294_000_000) continue;
                self.passkey = value % 1_000_000;
                accepted = true;
                break;
            }
            if (!accepted) return error.CryptoFailed;
            _ = self.config.io_fn.?(self.config.io_context, .{ .display = self.passkey });
        }
        self.keys = try self.config.crypto.key_pair_fn(self.config.crypto.context);
        self.pairing_count += 1;
        return true;
    }
    fn public_key(self: *Session) Error!void {
        try self.send(&([1]u8{0x0c} ++ crypto.reverse(32, self.keys.public.x) ++ crypto.reverse(32, self.keys.public.y)));
    }
    fn passkey_method(self: *const Session) bool {
        return self.method == .passkey_input or self.method == .passkey_display;
    }
    fn z(self: *const Session) u8 {
        return if (self.passkey_method()) @as(u8, 0x80) | @as(u8, @intCast(self.passkey >> self.round & 1)) else 0;
    }
    fn new_nonce(self: *Session) Error!void {
        try self.config.crypto.random_fn(self.config.crypto.context, &self.nonce);
    }
    fn send_confirm(self: *Session) Error!void {
        try self.send_key(3, crypto.f4(self.keys.public.x, self.remote.x, self.nonce, self.z()));
    }
    /// The first Passkey Entry confirm commits to a passkey bit (§2.3.5.6.3).
    fn passkey_confirm(self: *Session) Error!void {
        if (self.io_request != null) {
            self.confirm_owed = true;
        } else try self.send_confirm();
    }
    fn derive(self: *Session) Error!void {
        const na = if (self.central) self.nonce else self.peer_nonce;
        const nb = if (self.central) self.peer_nonce else self.nonce;
        if (self.method == .numeric_comparison) {
            // §2.3.5.6.2: both sides show the value after the nonce exchange.
            // The responder's Pairing Random is already queued; the answer is
            // collected by poll_io without holding it back.
            const value = crypto.g2(if (self.central) self.keys.public.x else self.remote.x, if (self.central) self.remote.x else self.keys.public.x, na, nb) % 1_000_000;
            self.state = .compare;
            self.io_request = .{ .compare = value };
            return;
        }
        try self.stage2();
    }
    /// Authentication stage 2, §2.3.5.6.5: the LTK and DHKey checks.
    fn stage2(self: *Session) Error!void {
        const na = if (self.central) self.nonce else self.peer_nonce;
        const nb = if (self.central) self.peer_nonce else self.nonce;
        const a = if (self.central) self.local else self.peer;
        const b = if (self.central) self.peer else self.local;
        self.derived = crypto.f5(self.dh, na, nb, a, b);
        std.crypto.secureZero(u8, &self.keys.private);
        std.crypto.secureZero(u8, &self.dh);
        self.state = .dh_check;
        if (self.central) {
            try self.send_key(0x0d, self.check(false));
        } else if (self.peer_check) |value| {
            self.peer_check = null;
            try self.verify_check(value);
        }
    }
    fn verify_check(self: *Session, value: Key) Error!void {
        if (!crypto.equal(value, self.check(true))) return self.abort(.dhkey_failed);
        self.authenticated = self.method != .just_works;
        if (!self.central) try self.send_key(0x0d, self.check(false));
        self.state = .encryption;
        if (self.central) self.start_encryption = true;
    }
    /// True while a comparison or passkey answer is outstanding.
    pub fn awaiting_io(self: *const Session) bool {
        return self.io_request != null;
    }
    /// Ask the IO hook for an outstanding answer. The host calls this on every
    /// poll; `.pending` leaves the procedure waiting. An error aborts the
    /// procedure, as in `receive`.
    pub fn poll_io(self: *Session) Error!void {
        self.answer_io() catch |err| return self.abort_with(err);
    }
    fn abort_with(self: *Session, err: Error) Error!void {
        try self.abort(.unspecified);
        return err;
    }
    fn answer_io(self: *Session) Error!void {
        const request = self.io_request orelse return;
        self.io_asked = true;
        const answer = self.config.io_fn.?(self.config.io_context, request);
        if (answer == .pending) return;
        self.io_request = null;
        self.io_asked = false;
        switch (request) {
            .compare => if (answer == .accept) try self.stage2() else try self.abort(.numeric_failed),
            .input => switch (answer) {
                .passkey => |value| {
                    if (value > 999_999) return self.abort(.passkey_failed);
                    self.passkey = value;
                    if (self.confirm_owed) {
                        self.confirm_owed = false;
                        try self.send_confirm();
                    }
                },
                else => try self.abort(.passkey_failed),
            },
            .display, .cancel => {},
        }
    }
    fn check(self: *const Session, remote: bool) Key {
        const local_first = !remote;
        const feature = if (self.central == local_first) self.request else self.response;
        var r: Key = @splat(0);
        if (self.passkey_method()) std.mem.writeInt(u32, r[12..16], self.passkey, .big);
        return crypto.f6(self.derived.mac, if (local_first) self.nonce else self.peer_nonce, if (local_first) self.peer_nonce else self.nonce, r, .{ feature[3], feature[2], feature[1] }, if (local_first) self.local else self.peer, if (local_first) self.peer else self.local);
    }
    /// An error (no queue space, a crypto failure) aborts the procedure with
    /// Pairing Failed (unspecified reason) before it is returned.
    pub fn receive(self: *Session, data: []const u8, now: u64) Error!void {
        self.receive_pdu(data, now) catch |err| return self.abort_with(err);
        // Ask only after this PDU's replies are queued, so an answer given at
        // once still queues its PDUs behind them.
        try self.poll_io();
    }
    fn receive_pdu(self: *Session, data: []const u8, now: u64) Error!void {
        self.tick(now);
        if (self.state == .timed_out) return;
        if (data.len == 0) return self.fail(.invalid_parameters);
        const op = data[0];
        const expected: usize = switch (op) {
            1, 2 => 7,
            3, 4, 6, 8, 0x0a, 0x0d => 17,
            5, 0x0b, 0x0e => 2,
            7 => 11,
            9 => 8,
            0x0c => 65,
            else => return self.fail(.command_not_supported),
        };
        if (data.len != expected) return self.fail(.invalid_parameters);
        if (op == 5) {
            // No procedure is outstanding: there is nothing for the peer to fail,
            // and a restored or completed key must survive.
            if (self.settled()) return;
            self.clear_queue();
            self.erase_secrets();
            self.failure = data[1];
            self.authenticated = false;
            self.state = .failed;
            return;
        }
        // Both applications may request security at once. The outstanding
        // feature exchange or encryption procedure already owns its keys and
        // requirements; a crossing request must not restart or abort it.
        if (op == 0x0b and self.central and (self.active() or self.state == .complete)) return;
        if (op == 0x0b and self.central and self.state == .idle) {
            if (data[1] & 3 > 1) return self.abort(.invalid_parameters);
            const require_authenticated = self.config.require_authenticated or data[1] & 4 != 0;
            if (self.bonded and (!require_authenticated or self.authenticated)) {
                self.state = .complete;
                self.start_encryption = true;
                return;
            }
            // Carry the peer's MITM requirement into our Pairing Request and
            // method selection. Retire an insufficient key before restarting.
            self.config.require_authenticated = require_authenticated;
            self.erase_secrets();
            self.authenticated = false;
            return self.start(now);
        }
        if (op == 1 and !self.central and (self.state == .idle or self.state == .response)) {
            self.request = data[0..7].*;
            self.response = self.features(2);
            self.response[5] &= self.request[5];
            self.response[6] &= self.request[6];
            if (!try self.negotiate()) return;
            self.deadline = now + 30_000;
            self.state = .public_key;
            try self.send(&self.response);
        } else if (op == 2 and self.central and self.state == .response) {
            self.response = data[0..7].*;
            if (self.response[5] & ~self.request[5] != 0 or self.response[6] & ~self.request[6] != 0) return self.abort(.invalid_parameters);
            if (!try self.negotiate()) return;
            self.state = .public_key;
            try self.public_key();
        } else if (op == 0x0c and self.state == .public_key) {
            self.remote = .{ .x = crypto.reverse(32, data[1..33].*), .y = crypto.reverse(32, data[33..65].*) };
            // §2.3.5.6: reflected public keys are forbidden.
            if (std.mem.eql(u8, &self.remote.x, &self.keys.public.x)) return self.abort(.invalid_parameters);
            // Known Core §2.3.5.6.1 debug key: never grant security using a
            // publicly known private scalar, even if the peer advertises MITM.
            if (std.mem.eql(u8, &self.remote.x, &crypto.hex("20b003d2f297be2c5e2c83a7e9f9a5b9eff49111acf4fddbcc0301480e359de6"))) return self.abort(.authentication_requirements);
            self.dh = self.config.crypto.dh_fn(self.config.crypto.context, self.keys.private, self.remote) catch return self.abort(.invalid_parameters);
            try self.new_nonce();
            self.state = .confirm;
            if (!self.central) try self.public_key();
            if (!self.central and !self.passkey_method()) try self.send_confirm();
            if (self.central and self.passkey_method()) try self.passkey_confirm();
        } else if (op == 3 and self.state == .confirm and !self.confirm_owed) {
            self.confirm = crypto.reverse(16, data[1..17].*);
            self.state = .random;
            if (self.central) try self.send_key(4, self.nonce) else if (self.passkey_method()) try self.passkey_confirm() else return self.abort(.invalid_parameters);
        } else if (op == 4 and !self.confirm_owed and (self.state == .random or (!self.central and self.state == .confirm and !self.passkey_method()))) {
            self.peer_nonce = crypto.reverse(16, data[1..17].*);
            if ((self.central or self.passkey_method()) and !crypto.equal(self.confirm, crypto.f4(self.remote.x, self.keys.public.x, self.peer_nonce, self.z()))) return self.abort(.confirm_failed);
            if (!self.central) try self.send_key(4, self.nonce);
            if (self.passkey_method() and self.round < 19) {
                self.round += 1;
                try self.new_nonce();
                self.state = .confirm;
                if (self.central) try self.send_confirm();
            } else try self.derive();
        } else if (op == 0x0d and self.state == .dh_check) {
            try self.verify_check(crypto.reverse(16, data[1..17].*));
        } else if (op == 0x0d and self.state == .compare and !self.central and self.peer_check == null) {
            // The initiator's user answered first: check it after ours accepts.
            self.peer_check = crypto.reverse(16, data[1..17].*);
        } else if (self.state == .distribution and self.encrypted and (op == 8 or op == 9)) {
            if (!self.wants_peer_identity() or (op == 8 and self.received_identity != 0) or (op == 9 and self.received_identity != 1)) return self.abort(.invalid_parameters);
            if (op == 8) {
                self.peer_irk = crypto.reverse(16, data[1..17].*);
                self.received_identity = 1;
            } else {
                if (data[1] > 1 or (data[1] == 1 and data[7] & 0xc0 != 0xc0)) return self.abort(.invalid_parameters);
                self.identity = [1]u8{data[1]} ++ crypto.reverse(6, data[2..8].*);
                self.received_identity = 2;
            }
            try self.distribute();
        } else if (self.settled()) {
            // One procedure per connection: a completed exchange is not restarted.
            return self.reject(if (op == 1 and !self.central) .pairing_not_supported else .command_not_supported);
        } else return self.abort(.unspecified);
        if (self.active()) self.deadline = now + 30_000;
    }
    /// Idle (possibly holding a restored bond) or complete: no exchange owns
    /// the keys, so an unexpected PDU is refused without failing the session.
    fn settled(self: *const Session) bool {
        return self.state == .idle or self.state == .complete;
    }
    fn fail(self: *Session, reason: Failure) Error!void {
        return if (self.settled()) self.reject(reason) else self.abort(reason);
    }
    /// Answer with Pairing Failed (PDU and reason codes: Core v5.4 Vol 3
    /// Part H §3.5.5). Keeping the session's keys, state and pending bond save
    /// is this design's choice, not a spec requirement. A full queue drops the
    /// reply rather than letting the peer turn it into an abort.
    fn reject(self: *Session, reason: Failure) Error!void {
        if (self.queued == self.queue.len) return;
        try self.send(&.{ 5, @backingInt(reason) });
    }
    fn wants_peer_identity(self: *const Session) bool {
        return self.response[if (self.central) @as(usize, 6) else 5] & 2 != 0;
    }
    fn distribute(self: *Session) Error!void {
        const received = !self.wants_peer_identity() or self.received_identity == 2;
        if (!self.sent_identity and (!self.central or received)) {
            self.sent_identity = true;
            if (self.response[if (self.central) @as(usize, 5) else 6] & 2 != 0) {
                try self.send_key(8, self.config.irk.?);
                try self.send(&([2]u8{ 9, self.local[0] } ++ crypto.reverse(6, self.local[1..7].*)));
            }
        }
        if (received and self.sent_identity) {
            self.state = .complete;
            self.save_bond = self.request[3] & self.response[3] & 1 != 0;
            std.crypto.secureZero(u8, &self.derived.mac);
            std.crypto.secureZero(u8, &self.nonce);
            std.crypto.secureZero(u8, &self.peer_nonce);
            self.passkey = 0;
        }
    }
    /// Called for every controller encryption event on this connection.
    /// `enabled = false` (a failed or disabled encryption, or a failed LE
    /// Enable Encryption command) revokes encryption and fails the session.
    /// Either failure drops queued PDUs other than Pairing Failed: identity
    /// keys are distributed only over the link encrypted with this pairing's
    /// key (§2.4.3.2).
    pub fn encryption_changed(self: *Session, enabled: bool, now: u64) Error!void {
        // An old-key encryption completion racing fresh pairing must not
        // authenticate the new exchange. Accept only a verified new key,
        // cached-key reconnect, or refresh of an already completed link.
        // A peripheral's Security Request can be answered with the cached key
        // instead of Pairing Request. negotiate() retires that key if a fresh
        // pairing starts; a central awaiting Pairing Response cannot use it.
        const cached_key = self.bonded and (self.state == .idle or self.state == .complete or
            (!self.central and self.state == .response));
        const expected = self.state == .encryption or cached_key or
            (self.encrypted and self.state == .complete);
        if (!enabled or !expected) {
            self.encrypted = false;
            self.authenticated = false;
            self.erase_secrets();
            self.keep_failures();
            self.state = .failed;
            return;
        }
        self.encrypted = true;
        if (self.state == .encryption) {
            self.state = .distribution;
            self.deadline = now + 30_000;
            try self.distribute();
        } else if (cached_key) {
            self.state = .complete;
        }
    }
    pub fn bond(self: *const Session) bonds.Bond {
        return .{ .peer = self.peer, .ltk = self.derived.ltk, .identity = self.identity, .irk = self.peer_irk, .authenticated = self.authenticated };
    }
    pub fn restore(self: *Session, saved: bonds.Bond) bool {
        if (self.config.require_authenticated and !saved.authenticated) return false;
        // Repairing a known authenticated peer may not downgrade its security.
        self.config.require_authenticated = self.config.require_authenticated or saved.authenticated;
        self.derived.ltk = saved.ltk;
        self.authenticated = saved.authenticated;
        self.peer_irk = saved.irk;
        self.identity = saved.identity;
        self.bonded = true;
        return true;
    }
};

const TestCrypto = struct {
    counter: u8,
    compared: ?u32 = null,
    const P256 = std.crypto.ecc.P256;
    fn random(ctx: ?*anyopaque, bytes: []u8) Error!void {
        const self: *TestCrypto = @ptrCast(@alignCast(ctx.?));
        self.counter +%= 1;
        @memset(bytes, self.counter);
    }
    fn pair(ctx: ?*anyopaque) Error!KeyPair {
        var scalar: [32]u8 = @splat(0);
        const self: *TestCrypto = @ptrCast(@alignCast(ctx.?));
        scalar[31] = self.counter;
        const p = P256.basePoint.mul(scalar, .big) catch return error.CryptoFailed;
        const encoded = p.toUncompressedSec1();
        return .{ .public = .{ .x = encoded[1..33].*, .y = encoded[33..65].* }, .private = scalar };
    }
    fn dh(_: ?*anyopaque, scalar: [32]u8, peer: Point) Error![32]u8 {
        const p = P256.fromSerializedAffineCoordinates(peer.x, peer.y, .big) catch return error.CryptoFailed;
        const shared = p.mul(scalar, .big) catch return error.CryptoFailed;
        return shared.toUncompressedSec1()[1..33].*;
    }
    fn io(ctx: ?*anyopaque, req: IoRequest) IoAnswer {
        const self: *TestCrypto = @ptrCast(@alignCast(ctx.?));
        return switch (req) {
            .compare => |value| blk: {
                self.compared = value;
                break :blk .accept;
            },
            .input => .{ .passkey = 424242 },
            .display, .cancel => .accept,
        };
    }
    fn config(self: *TestCrypto) Config {
        return .{ .crypto = .{ .context = self, .random_fn = random, .key_pair_fn = pair, .dh_fn = dh }, .io_context = self, .io_fn = io };
    }
};
const TestPair = struct {
    a: Session,
    b: Session,
    fn init(a: Config, b: Config) TestPair {
        const address_a = crypto.hex("00010203040506");
        const address_b = crypto.hex("000708090a0b0c");
        return .{ .a = Session.init(a, true, address_a, address_b), .b = Session.init(b, false, address_b, address_a) };
    }
    fn pump(self: *TestPair, corrupt: ?u8) !void {
        for (0..200) |_| {
            var progressed = false;
            while (self.a.pop()) |pdu| {
                var bytes = pdu;
                if (corrupt == bytes.bytes[0]) bytes.bytes[1] ^= 1;
                try self.b.receive(bytes.data(), 1);
                progressed = true;
            }
            while (self.b.pop()) |pdu| {
                var bytes = pdu;
                if (corrupt == bytes.bytes[0]) bytes.bytes[1] ^= 1;
                try self.a.receive(bytes.data(), 1);
                progressed = true;
            }
            if (!progressed) return;
        }
        return error.DidNotConverge;
    }
};
test "both roles perform Just Works, Numeric Comparison and twenty passkey rounds" {
    inline for (.{ .{ IoCapability.no_input_output, IoCapability.no_input_output }, .{ IoCapability.display_yes_no, IoCapability.keyboard_display }, .{ IoCapability.keyboard_only, IoCapability.keyboard_display }, .{ IoCapability.keyboard_display, IoCapability.keyboard_only } }) |capabilities| {
        var ca: TestCrypto = .{ .counter = 1 };
        var cb: TestCrypto = .{ .counter = 2 };
        var ac = ca.config();
        var bc = cb.config();
        ac.io = capabilities[0];
        bc.io = capabilities[1];
        ac.require_authenticated = ac.io != .no_input_output;
        bc.require_authenticated = bc.io != .no_input_output;
        // Fix the displayed passkey for this transcript; input returns 424242.
        if (ac.io == .keyboard_display and bc.io == .keyboard_only) ac.crypto.random_fn = test_passkey_random;
        if (bc.io == .keyboard_display and ac.io == .keyboard_only) bc.crypto.random_fn = test_passkey_random;
        var pair = TestPair.init(ac, bc);
        try pair.a.start(0);
        try pair.pump(null);
        try std.testing.expectEqual(State.encryption, pair.a.state);
        try std.testing.expectEqual(State.encryption, pair.b.state);
        try std.testing.expectEqualSlices(u8, &pair.a.derived.ltk, &pair.b.derived.ltk);
        try std.testing.expect(!pair.a.encrypted and !pair.b.encrypted);
        try pair.b.encryption_changed(true, 2);
        try pair.a.encryption_changed(true, 2);
        try pair.pump(null);
        try std.testing.expectEqual(State.complete, pair.a.state);
        try std.testing.expectEqual(State.complete, pair.b.state);
        if (pair.a.method == .numeric_comparison) try std.testing.expectEqual(ca.compared.?, cb.compared.?);
        try std.testing.expectEqual(ac.require_authenticated, pair.a.authenticated);
        if (pair.a.passkey_method()) try std.testing.expectEqual(@as(u5, 19), pair.a.round);
    }
}
fn test_passkey_random(ctx: ?*anyopaque, bytes: []u8) Error!void {
    if (bytes.len == 4) {
        std.mem.writeInt(u32, bytes[0..4], 424242, .big);
    } else try TestCrypto.random(ctx, bytes);
}
test "invalid point, confirm mismatch and DHKey check failure abort without encryption" {
    for ([_]u8{ 0x0c, 4, 0x0d }) |opcode| {
        var ca: TestCrypto = .{ .counter = 1 };
        var cb: TestCrypto = .{ .counter = 2 };
        var pair = TestPair.init(ca.config(), cb.config());
        try pair.a.start(0);
        try pair.pump(opcode);
        try std.testing.expectEqual(State.failed, pair.a.state);
        try std.testing.expectEqual(State.failed, pair.b.state);
        try std.testing.expectEqual(@as(?u8, if (opcode == 4) 4 else if (opcode == 0x0c) 0x0a else 0x0b), pair.a.failure);
        try std.testing.expect(!pair.a.encrypted and !pair.b.encrypted);
        try std.testing.expect(std.mem.allEqual(u8, &pair.a.derived.ltk, 0));
    }
}
test "SMP timeout poisons bearer; legacy, OOB and unsupported authentication fail closed" {
    var ca: TestCrypto = .{ .counter = 1 };
    var cb: TestCrypto = .{ .counter = 2 };
    var pair = TestPair.init(ca.config(), cb.config());
    try pair.a.start(0);
    pair.a.tick(30_000);
    try pair.a.receive(&.{ 2, 3, 0, 8, 16, 0, 0 }, 30_001);
    try std.testing.expectEqual(State.timed_out, pair.a.state);
    try std.testing.expectEqual(@as(u3, 0), pair.a.queued);
    var delayed = Session.init(ca.config(), true, pair.a.local, pair.a.peer);
    try delayed.start(0);
    _ = delayed.pop();
    delayed.sent(29_000);
    delayed.tick(30_000);
    try std.testing.expectEqual(State.response, delayed.state);
    delayed.tick(59_000);
    try std.testing.expectEqual(State.timed_out, delayed.state);
    inline for (.{ .{ 0, 0, 5 }, .{ 1, 8, 3 } }) |v| {
        var s = Session.init(cb.config(), false, pair.b.local, pair.b.peer);
        try s.receive(&.{ 1, 3, v[0], v[1], 16, 2, 2 }, 0);
        try std.testing.expectEqual(@as(?u8, v[2]), s.failure);
    }
    var config = cb.config();
    config.require_authenticated = true;
    var s = Session.init(config, false, pair.b.local, pair.b.peer);
    try s.receive(&.{ 1, 3, 0, 8, 16, 2, 2 }, 0);
    try std.testing.expectEqual(@as(?u8, 3), s.failure);
}

const TestStore = struct {
    fn load(_: *anyopaque, _: Address) bonds.Error!?bonds.Bond {
        return null;
    }
    fn save(_: *anyopaque, _: bonds.Bond) bonds.Error!void {}
    fn remove(_: *anyopaque, _: Address) bonds.Error!void {}
    fn interface(context: *anyopaque) bonds.Store {
        return .{ .context = context, .load_fn = load, .save_fn = save, .remove_fn = remove };
    }
};
test "identity distribution waits for encryption, responder first, then marks bonds ready" {
    var ca: TestCrypto = .{ .counter = 1 };
    var cb: TestCrypto = .{ .counter = 2 };
    var ac = ca.config();
    var bc = cb.config();
    ac.store = TestStore.interface(&ca);
    bc.store = TestStore.interface(&cb);
    ac.irk = @splat(0xa1);
    bc.irk = @splat(0xb2);
    var pair = TestPair.init(ac, bc);
    try pair.a.start(0);
    try pair.pump(null);
    try std.testing.expect(!pair.a.save_bond and !pair.b.save_bond);
    try pair.a.encryption_changed(true, 2);
    try std.testing.expectEqual(@as(u3, 0), pair.a.queued);
    try pair.b.encryption_changed(true, 2);
    try std.testing.expectEqual(@as(u3, 2), pair.b.queued);
    try pair.pump(null);
    try std.testing.expect(pair.a.save_bond and pair.b.save_bond);
    try std.testing.expectEqualSlices(u8, &bc.irk.?, &pair.a.bond().irk);
    try std.testing.expectEqualSlices(u8, &ac.irk.?, &pair.b.bond().irk);
    try std.testing.expectEqualSlices(u8, &pair.b.local, &pair.a.bond().identity);
    try std.testing.expectEqualSlices(u8, &pair.a.local, &pair.b.bond().identity);
    var reconnected = Session.init(ac, true, pair.a.local, pair.a.peer);
    try std.testing.expect(reconnected.restore(pair.a.bond()));
    try reconnected.encryption_changed(true, 3);
    try std.testing.expectEqual(State.complete, reconnected.state);
    try std.testing.expectEqual(@as(u32, 0), reconnected.pairing_count);
    var early = Session.init(ac, true, pair.a.local, pair.a.peer);
    try early.receive(&([1]u8{8} ++ @as(Key, @splat(0xff))), 0);
    try std.testing.expectEqual(State.idle, early.state);
    try std.testing.expectEqualSlices(u8, &.{ 5, 7 }, early.pop().?.data());
    try std.testing.expect(!early.save_bond and std.mem.allEqual(u8, &early.peer_irk, 0));
}

test "unexpected SMP PDUs after completion are refused without erasing keys" {
    var source: TestCrypto = .{ .counter = 1 };
    const peer = crypto.hex("00010203040506");
    const saved: bonds.Bond = .{ .peer = peer, .identity = peer, .ltk = @splat(0xab), .authenticated = true };
    for ([_]bool{ false, true }) |central| {
        var session = Session.init(source.config(), central, @splat(0), peer);
        try std.testing.expect(session.restore(saved));
        try session.encryption_changed(true, 0);
        try std.testing.expectEqual(State.complete, session.state);
        session.save_bond = true; // a deferred save must survive as well
        const cases = [_]struct { pdu: []const u8, reply: ?[2]u8 }{
            .{ .pdu = &.{ 1, 3, 0, 8, 16, 0, 0 }, .reply = .{ 5, if (central) 7 else 5 } },
            .{ .pdu = &.{ 0x0b, 0x0d }, .reply = if (central) null else .{ 5, 7 } },
            .{ .pdu = &.{ 0x0e, 1 }, .reply = .{ 5, 7 } },
            .{ .pdu = &([1]u8{8} ++ @as(Key, @splat(0xff))), .reply = .{ 5, 7 } },
            .{ .pdu = &.{ 0x0c, 0 }, .reply = .{ 5, 0x0a } },
            .{ .pdu = &.{0x20}, .reply = .{ 5, 7 } },
            .{ .pdu = &.{}, .reply = .{ 5, 0x0a } },
            .{ .pdu = &.{ 5, 8 }, .reply = null },
        };
        for (cases) |case| {
            try session.receive(case.pdu, 1);
            if (case.reply) |reply| {
                try std.testing.expectEqualSlices(u8, &reply, session.pop().?.data());
            }
            try std.testing.expectEqual(@as(u3, 0), session.queued);
            try std.testing.expectEqual(State.complete, session.state);
            try std.testing.expectEqual(@as(?u8, null), session.failure);
            try std.testing.expect(session.encrypted and session.authenticated and session.bonded and session.save_bond);
            try std.testing.expectEqualSlices(u8, &saved.ltk, &session.derived.ltk);
        }
    }
}

test "a peer's Pairing Failed while a restored bond is idle keeps the bond" {
    var source: TestCrypto = .{ .counter = 1 };
    const peer = crypto.hex("00010203040506");
    const saved: bonds.Bond = .{ .peer = peer, .identity = peer, .ltk = @splat(0xab), .authenticated = true };
    for ([_]bool{ false, true }) |central| {
        var session = Session.init(source.config(), central, @splat(0), peer);
        try std.testing.expect(session.restore(saved));
        try session.receive(&.{ 5, 8 }, 1);
        try std.testing.expectEqual(State.idle, session.state);
        try std.testing.expectEqual(@as(?u8, null), session.failure);
        try std.testing.expectEqual(@as(u3, 0), session.queued);
        try std.testing.expect(session.bonded and session.authenticated);
        try std.testing.expectEqualSlices(u8, &saved.ltk, &session.derived.ltk);
        // The restored key still encrypts the link.
        try session.encryption_changed(true, 2);
        try std.testing.expectEqual(State.complete, session.state);
    }
}

test "fresh pairing retires cached LTK and cannot authenticate before DHKey checks" {
    var ca: TestCrypto = .{ .counter = 1 };
    var cb: TestCrypto = .{ .counter = 2 };
    var ac = ca.config();
    var bc = cb.config();
    ac.io = .display_yes_no;
    bc.io = .display_yes_no;
    ac.require_authenticated = true;
    var pair = TestPair.init(ac, bc);
    const old: bonds.Bond = .{ .peer = pair.a.local, .identity = pair.a.local, .ltk = @splat(0xab), .authenticated = false };
    try std.testing.expect(pair.b.restore(old));
    try pair.a.start(0);
    const request = pair.a.pop().?;
    try pair.b.receive(request.data(), 0);
    try std.testing.expectEqual(Method.numeric_comparison, pair.b.method);
    try std.testing.expect(!pair.b.bonded and !pair.b.authenticated);
    try std.testing.expect(std.mem.allEqual(u8, &pair.b.derived.ltk, 0));
    var premature = pair.b;
    try premature.encryption_changed(true, 1);
    try std.testing.expectEqual(State.failed, premature.state);
    try std.testing.expect(!premature.encrypted and !premature.authenticated);
    try pair.pump(null);
    try std.testing.expect(pair.a.authenticated and pair.b.authenticated);
    var known = Session.init(bc, false, pair.b.local, pair.b.peer);
    var authenticated = old;
    authenticated.authenticated = true;
    try std.testing.expect(known.restore(authenticated));
    try std.testing.expect(known.config.require_authenticated);
}

test "only a bonded peripheral awaiting Security Request completion accepts cached encryption" {
    for ([_]bool{ false, true }) |central| {
        for ([_]bool{ false, true }) |bonded| {
            var source: TestCrypto = .{ .counter = 1 };
            const peer = crypto.hex("00010203040506");
            const saved: bonds.Bond = .{ .peer = peer, .identity = peer, .ltk = @splat(0xab), .authenticated = false };
            var session = Session.init(source.config(), central, @splat(0), peer);
            if (bonded) try std.testing.expect(session.restore(saved));
            try session.start(0);
            const pdu = session.pop().?;
            try std.testing.expectEqual(@as(u8, if (central) 1 else 0x0b), pdu.bytes[0]);
            try std.testing.expectEqual(State.response, session.state);
            try session.encryption_changed(true, 1);
            if (!central and bonded) {
                try std.testing.expectEqual(State.complete, session.state);
                try std.testing.expect(session.encrypted and session.bonded);
                try std.testing.expectEqualSlices(u8, &saved.ltk, &session.derived.ltk);
            } else {
                try std.testing.expectEqual(State.failed, session.state);
                try std.testing.expect(!session.encrypted and !session.authenticated);
                try std.testing.expect(std.mem.allEqual(u8, &session.derived.ltk, 0));
            }
        }
    }
}

test "MITM Security Request upgrades Just Works bond through Numeric Comparison" {
    var ca: TestCrypto = .{ .counter = 1 };
    var cb: TestCrypto = .{ .counter = 2 };
    var ac = ca.config();
    var bc = cb.config();
    ac.io = .display_yes_no;
    bc.io = .display_yes_no;
    bc.require_authenticated = true;
    ac.store = TestStore.interface(&ca);
    bc.store = TestStore.interface(&cb);
    var pair = TestPair.init(ac, bc);
    const old: bonds.Bond = .{ .peer = pair.b.local, .identity = pair.b.local, .ltk = @splat(0xab), .authenticated = false };
    try std.testing.expect(pair.a.restore(old));
    try pair.b.start(0);
    const request = pair.b.pop().?;
    try std.testing.expectEqualSlices(u8, &.{ 0x0b, 0x0d }, request.data());
    try pair.a.receive(request.data(), 0);
    try std.testing.expect(!pair.a.start_encryption and !pair.a.bonded);
    try std.testing.expectEqual(@as(u8, 0x0d), pair.a.request[3]);
    try pair.pump(null);
    try std.testing.expectEqual(Method.numeric_comparison, pair.a.method);
    try std.testing.expectEqual(Method.numeric_comparison, pair.b.method);
    try std.testing.expect(pair.a.authenticated and pair.b.authenticated);
    try std.testing.expectEqual(ca.compared.?, cb.compared.?);
    try std.testing.expect(!crypto.equal(old.ltk, pair.a.derived.ltk));
    try std.testing.expectEqualSlices(u8, &pair.a.derived.ltk, &pair.b.derived.ltk);
    try pair.a.encryption_changed(true, 2);
    try pair.b.encryption_changed(true, 2);
    try pair.pump(null);
    try std.testing.expectEqual(State.complete, pair.a.state);
    try std.testing.expectEqual(State.complete, pair.b.state);
    try std.testing.expect(pair.a.save_bond and pair.b.save_bond);
    // The requested authentication cannot silently fall back to Just Works.
    var unavailable = Session.init(ca.config(), true, pair.a.local, pair.a.peer);
    try std.testing.expect(unavailable.restore(old));
    try unavailable.receive(request.data(), 0);
    _ = unavailable.pop();
    try unavailable.receive(&.{ 2, 3, 0, 8, 16, 0, 0 }, 1);
    try std.testing.expectEqual(State.failed, unavailable.state);
    try std.testing.expectEqual(@as(?u8, 3), unavailable.failure);
    try std.testing.expect(!unavailable.start_encryption and !unavailable.authenticated);
}

test "crossing Security Request preserves outstanding Pairing Request" {
    var ca: TestCrypto = .{ .counter = 1 };
    var cb: TestCrypto = .{ .counter = 2 };
    var ac = ca.config();
    var bc = cb.config();
    ac.io = .display_yes_no;
    bc.io = .display_yes_no;
    ac.require_authenticated = true;
    var pair = TestPair.init(ac, bc);
    try pair.a.start(0);
    try pair.b.start(0);
    const security_request = pair.b.pop().?;
    const deadline = pair.a.deadline;
    const features = pair.a.request;
    try pair.a.receive(security_request.data(), 1);
    try std.testing.expectEqual(State.response, pair.a.state);
    try std.testing.expectEqual(@as(?u8, null), pair.a.failure);
    try std.testing.expectEqual(deadline, pair.a.deadline);
    try std.testing.expectEqualSlices(u8, &features, &pair.a.request);
    try std.testing.expect(pair.a.config.require_authenticated);
    try std.testing.expectEqual(@as(u3, 1), pair.a.queued);
    // Deliver the original feature exchange and check a second request cannot
    // discard the generated private key or alter the negotiated requirements.
    const request = pair.a.pop().?;
    try pair.b.receive(request.data(), 1);
    const response = pair.b.pop().?;
    try pair.a.receive(response.data(), 1);
    const private = pair.a.keys.private;
    try pair.a.receive(&.{ 0x0b, 0x0d }, 2);
    try std.testing.expectEqual(State.public_key, pair.a.state);
    try std.testing.expectEqualSlices(u8, &private, &pair.a.keys.private);
    try std.testing.expectEqualSlices(u8, &features, &pair.a.request);
    try pair.pump(null);
    try std.testing.expectEqual(State.encryption, pair.a.state);
    try std.testing.expectEqual(State.encryption, pair.b.state);
    try std.testing.expect(pair.a.authenticated and pair.b.authenticated);
    try std.testing.expectEqualSlices(u8, &pair.a.derived.ltk, &pair.b.derived.ltk);
    try pair.a.encryption_changed(true, 3);
    try pair.b.encryption_changed(true, 3);
    try pair.pump(null);
    try std.testing.expectEqual(State.complete, pair.a.state);
    try std.testing.expectEqual(State.complete, pair.b.state);
}

test "crossing Security Request preserves cached encryption awaiting completion" {
    var source: TestCrypto = .{ .counter = 1 };
    const peer = crypto.hex("00010203040506");
    const saved: bonds.Bond = .{ .peer = peer, .identity = peer, .ltk = @splat(0xab), .authenticated = true };
    var session = Session.init(source.config(), true, @splat(0), peer);
    try std.testing.expect(session.restore(saved));
    try session.receive(&.{ 0x0b, 0x0d }, 0);
    try std.testing.expectEqual(State.complete, session.state);
    try std.testing.expect(session.start_encryption);
    // Host.secure/service_security has sent LE Enable Encryption; the crossing
    // request arrives before its Encryption Change event.
    session.start_encryption = false;
    try session.receive(&.{ 0x0b, 0x09 }, 1);
    try std.testing.expectEqual(State.complete, session.state);
    try std.testing.expect(!session.start_encryption);
    try std.testing.expectEqual(@as(?u8, null), session.failure);
    try std.testing.expect(session.bonded and session.authenticated);
    try std.testing.expect(session.config.require_authenticated);
    try std.testing.expectEqualSlices(u8, &saved.ltk, &session.derived.ltk);
    try std.testing.expectEqual(@as(u3, 0), session.queued);
    try session.encryption_changed(true, 2);
    try std.testing.expect(session.encrypted and session.authenticated);
    try std.testing.expectEqual(State.complete, session.state);
    try session.receive(&.{ 0x0b, 0x0d }, 3);
    try std.testing.expect(session.encrypted and session.authenticated);
    try std.testing.expectEqualSlices(u8, &saved.ltk, &session.derived.ltk);
}

/// Two users who answer only what they have seen: a comparison is accepted
/// once both numbers are displayed and equal; a passkey is typed only after
/// the other board has displayed it, or, with `known`, a passkey both users
/// agreed on (two keyboards, Core v5.4 Vol 3 Part H §2.3.5.6.3). `.pending`
/// models a user still waiting; `.cancel` takes the prompt down.
const PatientUsers = struct {
    shown: [2]?u32 = .{ null, null },
    asked: [2]u32 = .{ 0, 0 },
    cancelled: [2]u32 = .{ 0, 0 },
    known: [2]?u32 = .{ null, null },
    // A user who has not decided yet, whatever the displays show.
    hold: [2]bool = .{ false, false },
    const User = struct { users: *PatientUsers, index: u1 };
    fn io(ctx: ?*anyopaque, req: IoRequest) IoAnswer {
        const user: *User = @ptrCast(@alignCast(ctx.?));
        const self = user.users;
        const other = self.shown[1 - @as(usize, user.index)];
        switch (req) {
            .display => |value| self.shown[user.index] = value,
            .compare => |value| {
                self.asked[user.index] += 1;
                self.shown[user.index] = value;
                if (self.hold[user.index]) return .pending;
                const peer = other orelse return .pending;
                return if (peer == value) .accept else .reject;
            },
            .input => {
                self.asked[user.index] += 1;
                if (self.hold[user.index]) return .pending;
                const value = self.known[user.index] orelse other orelse return .pending;
                return .{ .passkey = value };
            },
            .cancel => self.cancelled[user.index] += 1,
        }
        return .accept;
    }
};
fn patient_pair(users: *PatientUsers, user_a: *PatientUsers.User, user_b: *PatientUsers.User, ca: *TestCrypto, cb: *TestCrypto, io_a: IoCapability, io_b: IoCapability) TestPair {
    user_a.* = .{ .users = users, .index = 0 };
    user_b.* = .{ .users = users, .index = 1 };
    var ac = ca.config();
    var bc = cb.config();
    ac.io = io_a;
    bc.io = io_b;
    ac.require_authenticated = true;
    bc.require_authenticated = true;
    ac.io_fn = PatientUsers.io;
    bc.io_fn = PatientUsers.io;
    ac.io_context = user_a;
    bc.io_context = user_b;
    return TestPair.init(ac, bc);
}
/// The host polls each session's hook between packets; pump does the same.
fn pump_users(pair: *TestPair) !void {
    for (0..50) |_| {
        try pair.pump(null);
        try pair.a.poll_io();
        try pair.b.poll_io();
        if (!pair.a.awaiting_io() and !pair.b.awaiting_io() and pair.a.queued == 0 and pair.b.queued == 0) return;
    }
    return error.DidNotConverge;
}
test "Numeric Comparison sends the responder's random while its user decides" {
    var users: PatientUsers = .{};
    var user_a: PatientUsers.User = undefined;
    var user_b: PatientUsers.User = undefined;
    var ca: TestCrypto = .{ .counter = 1 };
    var cb: TestCrypto = .{ .counter = 20 };
    var pair = patient_pair(&users, &user_a, &user_b, &ca, &cb, .display_yes_no, .display_yes_no);
    try pair.a.start(0);
    try pump_users(&pair);
    try std.testing.expectEqual(Method.numeric_comparison, pair.b.method);
    try std.testing.expectEqual(State.encryption, pair.a.state);
    try std.testing.expectEqual(State.encryption, pair.b.state);
    try std.testing.expectEqual(users.shown[0].?, users.shown[1].?);
    // The responder's user really waited for the initiator's display.
    try std.testing.expect(users.asked[1] > 1);
    try std.testing.expect(pair.a.authenticated and pair.b.authenticated);
    try std.testing.expectEqualSlices(u8, &pair.a.derived.ltk, &pair.b.derived.ltk);
}
test "Numeric Comparison holds an early DHKey Check until the responder's user accepts" {
    var users: PatientUsers = .{};
    var user_a: PatientUsers.User = undefined;
    var user_b: PatientUsers.User = undefined;
    var ca: TestCrypto = .{ .counter = 1 };
    var cb: TestCrypto = .{ .counter = 20 };
    var pair = patient_pair(&users, &user_a, &user_b, &ca, &cb, .keyboard_display, .display_yes_no);
    users.hold[1] = true;
    try pair.a.start(0);
    try pair.pump(null);
    // Both values are displayed; the initiator's user accepted first.
    try std.testing.expectEqual(State.compare, pair.b.state);
    try std.testing.expectEqual(State.dh_check, pair.a.state);
    try std.testing.expect(pair.b.peer_check != null and !pair.b.authenticated);
    try std.testing.expectEqual(@as(u3, 0), pair.b.queued);
    users.hold[1] = false;
    try pump_users(&pair);
    try std.testing.expectEqual(State.encryption, pair.a.state);
    try std.testing.expectEqual(State.encryption, pair.b.state);
    // A responder rejection after an early check fails both sides.
    var reject_users: PatientUsers = .{};
    var ra: TestCrypto = .{ .counter = 1 };
    var rb: TestCrypto = .{ .counter = 20 };
    var rejected = patient_pair(&reject_users, &user_a, &user_b, &ra, &rb, .keyboard_display, .display_yes_no);
    reject_users.hold[1] = true;
    try rejected.a.start(0);
    try rejected.pump(null);
    try std.testing.expect(rejected.b.peer_check != null);
    reject_users.hold[1] = false;
    reject_users.shown[0] = reject_users.shown[1].? +% 1;
    try rejected.b.poll_io();
    try rejected.pump(null);
    try std.testing.expectEqual(@as(?u8, 0x0c), rejected.b.failure);
    try std.testing.expectEqual(State.failed, rejected.a.state);
}
test "a keyboard peripheral sends its Pairing Response while waiting for the passkey" {
    for ([_]bool{ false, true }) |keyboard_central| {
        var users: PatientUsers = .{};
        var user_a: PatientUsers.User = undefined;
        var user_b: PatientUsers.User = undefined;
        var ca: TestCrypto = .{ .counter = 1 };
        var cb: TestCrypto = .{ .counter = 20 };
        var pair = if (keyboard_central)
            patient_pair(&users, &user_a, &user_b, &ca, &cb, .keyboard_only, .display_only)
        else
            patient_pair(&users, &user_a, &user_b, &ca, &cb, .display_only, .keyboard_only);
        try pair.a.start(0);
        try pump_users(&pair);
        const keyboard = if (keyboard_central) &pair.a else &pair.b;
        try std.testing.expectEqual(Method.passkey_input, keyboard.method);
        try std.testing.expectEqual(State.encryption, pair.a.state);
        try std.testing.expectEqual(State.encryption, pair.b.state);
        // A keyboard peripheral is asked before the central can display.
        if (!keyboard_central) try std.testing.expect(users.asked[1] > 1);
        try std.testing.expectEqual(@as(u5, 19), pair.a.round);
        try std.testing.expect(pair.a.authenticated and pair.b.authenticated);
        try std.testing.expectEqualSlices(u8, &pair.a.derived.ltk, &pair.b.derived.ltk);
    }
}
test "an unanswered passkey keeps the first confirm and refuses the peer's early nonce" {
    var users: PatientUsers = .{};
    var user_a: PatientUsers.User = undefined;
    var user_b: PatientUsers.User = undefined;
    var ca: TestCrypto = .{ .counter = 1 };
    var cb: TestCrypto = .{ .counter = 20 };
    var pair = patient_pair(&users, &user_a, &user_b, &ca, &cb, .display_only, .keyboard_only);
    try pair.a.start(0);
    // Deliver until the central's first confirm arrives at the keyboard
    // peripheral. The central displays its passkey on the Pairing Response;
    // take that display away so the keyboard user cannot answer.
    const request = pair.a.pop().?;
    try pair.b.receive(request.data(), 0);
    const response = pair.b.pop().?;
    try pair.a.receive(response.data(), 0);
    try std.testing.expect(users.shown[0] != null);
    users.shown[0] = null;
    const key_a = pair.a.pop().?;
    try pair.b.receive(key_a.data(), 0);
    const key_b = pair.b.pop().?;
    try pair.a.receive(key_b.data(), 0);
    const confirm_a = pair.a.pop().?;
    try pair.b.receive(confirm_a.data(), 0);
    try std.testing.expect(pair.b.confirm_owed and pair.b.awaiting_io());
    try std.testing.expectEqual(@as(u3, 0), pair.b.queued);
    try pair.b.receive(&([1]u8{4} ++ @as(Key, @splat(7))), 0);
    try std.testing.expectEqual(State.failed, pair.b.state);
    try std.testing.expectEqual(@as(?u8, 8), pair.b.failure);
    try std.testing.expect(!pair.b.awaiting_io() and !pair.b.confirm_owed);
    // The keyboard user's prompt is taken down once.
    try std.testing.expectEqual(@as(u32, 1), users.cancelled[1]);
    try pair.b.poll_io();
    try std.testing.expectEqual(@as(u32, 1), users.cancelled[1]);
}
test "Numeric Comparison waits for the initiator's user after the responder accepts" {
    var users: PatientUsers = .{};
    var user_a: PatientUsers.User = undefined;
    var user_b: PatientUsers.User = undefined;
    var ca: TestCrypto = .{ .counter = 1 };
    var cb: TestCrypto = .{ .counter = 20 };
    var pair = patient_pair(&users, &user_a, &user_b, &ca, &cb, .display_yes_no, .keyboard_display);
    users.hold[0] = true;
    try pair.a.start(0);
    try pair.pump(null);
    try pair.b.poll_io();
    try pair.pump(null);
    // The responder accepted and waits for the initiator's DHKey Check; the
    // initiator has sent nothing since the nonces.
    try std.testing.expectEqual(State.compare, pair.a.state);
    try std.testing.expectEqual(State.dh_check, pair.b.state);
    try std.testing.expect(pair.a.awaiting_io() and !pair.b.awaiting_io());
    try std.testing.expect(!pair.a.authenticated and !pair.b.authenticated);
    try std.testing.expectEqual(@as(u3, 0), pair.a.queued);
    try std.testing.expectEqual(@as(u3, 0), pair.b.queued);
    try pair.a.poll_io();
    try std.testing.expect(pair.a.awaiting_io());
    users.hold[0] = false;
    try pump_users(&pair);
    try std.testing.expectEqual(State.encryption, pair.a.state);
    try std.testing.expectEqual(State.encryption, pair.b.state);
    try std.testing.expect(pair.a.authenticated and pair.b.authenticated);
    try std.testing.expectEqualSlices(u8, &pair.a.derived.ltk, &pair.b.derived.ltk);
    try std.testing.expectEqual(@as(u32, 0), users.cancelled[0] + users.cancelled[1]);
}
test "two keyboards both type the passkey; a mistyped one fails the confirm" {
    for ([_]?u32{ 123456, 222222 }) |central_typed| {
        var users: PatientUsers = .{};
        var user_a: PatientUsers.User = undefined;
        var user_b: PatientUsers.User = undefined;
        var ca: TestCrypto = .{ .counter = 1 };
        var cb: TestCrypto = .{ .counter = 20 };
        var pair = patient_pair(&users, &user_a, &user_b, &ca, &cb, .keyboard_only, .keyboard_only);
        users.known = .{ central_typed, 123456 };
        // The peripheral's user types first, then the central's.
        users.hold[0] = true;
        try pair.a.start(0);
        try pair.pump(null);
        try pair.b.poll_io();
        try std.testing.expectEqual(Method.passkey_input, pair.a.method);
        try std.testing.expectEqual(Method.passkey_input, pair.b.method);
        try std.testing.expect(pair.a.confirm_owed and pair.a.awaiting_io());
        try std.testing.expect(!pair.b.awaiting_io());
        try std.testing.expectEqual(@as(u3, 0), pair.a.queued);
        users.hold[0] = false;
        try pump_users(&pair);
        try std.testing.expectEqual(users.shown, .{ null, null });
        if (central_typed == 123456) {
            try std.testing.expectEqual(State.encryption, pair.a.state);
            try std.testing.expectEqual(State.encryption, pair.b.state);
            try std.testing.expectEqual(@as(u5, 19), pair.a.round);
            try std.testing.expect(pair.a.authenticated and pair.b.authenticated);
            try std.testing.expectEqualSlices(u8, &pair.a.derived.ltk, &pair.b.derived.ltk);
        } else {
            // 123456 and 222222 differ in bit 0: the responder's first check fails.
            try std.testing.expectEqual(@as(?u8, 4), pair.b.failure);
            try std.testing.expectEqual(State.failed, pair.a.state);
            try std.testing.expect(!pair.a.authenticated and !pair.b.authenticated);
        }
    }
}
test "a withdrawn IO request is cancelled once and the next pairing asks again" {
    const Ending = enum { timeout, peer_failed, encryption_failed, disconnected };
    for ([_]Ending{ .timeout, .peer_failed, .encryption_failed, .disconnected }) |ending| {
        var users: PatientUsers = .{};
        var user_a: PatientUsers.User = undefined;
        var user_b: PatientUsers.User = undefined;
        var ca: TestCrypto = .{ .counter = 1 };
        var cb: TestCrypto = .{ .counter = 20 };
        var pair = patient_pair(&users, &user_a, &user_b, &ca, &cb, .display_only, .keyboard_only);
        users.hold[1] = true;
        try pair.a.start(0);
        try pair.pump(null);
        try std.testing.expect(pair.b.awaiting_io() and users.asked[1] != 0);
        const asked = users.asked[1];
        switch (ending) {
            .timeout => pair.b.tick(30_001),
            .peer_failed => try pair.b.receive(&.{ 5, 8 }, 2),
            .encryption_failed => try pair.b.encryption_changed(false, 2),
            .disconnected => pair.b.disconnected(),
        }
        try std.testing.expect(!pair.b.awaiting_io());
        try std.testing.expectEqual(@as(u32, 1), users.cancelled[1]);
        try pair.b.poll_io();
        pair.b.disconnected();
        try std.testing.expectEqual(asked, users.asked[1]);
        try std.testing.expectEqual(@as(u32, 1), users.cancelled[1]);
        // A reconnection pairs again with the same users: the keyboard is
        // asked anew, and an unanswered request on the display side is never
        // cancelled because it was never asked.
        users.hold[1] = false;
        users.shown = .{ null, null }; // the old display went with its connection
        var again = patient_pair(&users, &user_a, &user_b, &ca, &cb, .display_only, .keyboard_only);
        try again.a.start(10);
        try pump_users(&again);
        try std.testing.expectEqual(State.encryption, again.b.state);
        try std.testing.expect(users.asked[1] > asked);
        try std.testing.expectEqual(@as(u32, 1), users.cancelled[1]);
        try std.testing.expectEqual(@as(u32, 0), users.cancelled[0]);
    }
    // A request set but not yet asked is withdrawn without a cancel.
    var users: PatientUsers = .{};
    var user_a: PatientUsers.User = undefined;
    var user_b: PatientUsers.User = undefined;
    var ca: TestCrypto = .{ .counter = 1 };
    var cb: TestCrypto = .{ .counter = 20 };
    var pair = patient_pair(&users, &user_a, &user_b, &ca, &cb, .display_only, .keyboard_only);
    try pair.a.start(0);
    const request = pair.a.pop().?;
    try pair.b.receive_pdu(request.data(), 0);
    try std.testing.expect(pair.b.awaiting_io() and !pair.b.io_asked);
    pair.b.disconnected();
    try std.testing.expectEqual(@as(u32, 0), users.asked[1] + users.cancelled[1]);
}
test "an IO answer whose reply cannot be queued aborts like a receive error" {
    var users: PatientUsers = .{};
    var user_a: PatientUsers.User = undefined;
    var user_b: PatientUsers.User = undefined;
    var ca: TestCrypto = .{ .counter = 1 };
    var cb: TestCrypto = .{ .counter = 20 };
    var pair = patient_pair(&users, &user_a, &user_b, &ca, &cb, .keyboard_display, .display_yes_no);
    users.hold[1] = true;
    try pair.a.start(0);
    try pair.pump(null);
    // The initiator's DHKey Check is held; accepting sends the responder's.
    try std.testing.expect(pair.b.peer_check != null);
    while (pair.b.queued < pair.b.queue.len) try pair.b.send(&.{0x20});
    users.hold[1] = false;
    try std.testing.expectError(error.NoBuffer, pair.b.poll_io());
    try std.testing.expectEqual(State.failed, pair.b.state);
    try std.testing.expectEqual(@as(?u8, 8), pair.b.failure);
    try std.testing.expectEqualSlices(u8, &.{ 5, 8 }, pair.b.pop().?.data());
    try std.testing.expectEqual(@as(u3, 0), pair.b.queued);
}
test "an encryption failure keeps a queued Pairing Failed and drops identity keys" {
    var source: TestCrypto = .{ .counter = 1 };
    var config = source.config();
    config.irk = @splat(0x5a);
    var session = Session.init(config, false, @splat(0), crypto.hex("00010203040506"));
    session.state = .distribution;
    session.encrypted = true;
    try session.send_key(8, config.irk.?);
    try session.send(&.{ 5, 0x0a });
    try session.send(&.{ 9, 0, 1, 2, 3, 4, 5, 6 });
    try session.encryption_changed(false, 1);
    try std.testing.expectEqual(State.failed, session.state);
    try std.testing.expectEqualSlices(u8, &.{ 5, 0x0a }, session.pop().?.data());
    try std.testing.expectEqual(@as(u3, 0), session.queued);
    for (session.queue) |pdu| try std.testing.expect(std.mem.allEqual(u8, &pdu.bytes, 0));
}

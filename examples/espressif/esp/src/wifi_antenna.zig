const microzig = @import("microzig");
const antenna = @import("antenna_options").antenna;

/// Use the same board RF-switch setup as the BLE and 802.15.4 examples.
/// Call before Wi-Fi initialization; bare-chip builds have no board switch.
pub fn apply() void {
    if (microzig.config.has_board) {
        if (@hasDecl(microzig.board, "antenna"))
            microzig.board.antenna.apply(@field(microzig.board.antenna.Selection, @tagName(antenna)));
    }
}

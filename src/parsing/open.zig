
const Parameter = struct {
    type: u8,
    length: u8,
    value: []u8,
};

const OpenMessage = struct {
    version: u8,
    asNumber: u16,
    holdTime:  u16,
    peerRouterId: u32,

    parametes: ?[]Parameter
};

const OpenParsingError = error {
    UnsupportedOptionalParameter,
    ParamLengthsInconsistency
};

pub fn readOpenMessage(r: anytype) !OpenMessage {
    const version = r.readInt(u8, .big);
    const as = r.readInt(u16, .big);
    const holdTime = r.readInt(u16, .big);

    const peerRouterId = r.readInt(u32, .big);

    const paramsLength = r.readInt(u8, .big);

    if (paramsLength == 0) {
        return .{.version = version, .asNumber = as, .holdTime = holdTime, .routerId = peerRouterId};
    }

    var readBytes = 0;
    while (readBytes < paramsLength) {
        const parameterType = r.readInt(u8, .big);
        const parameterValueLength = r.readInt(u8, .big);

        switch (parameterType) {
            else => {
                return OpenParsingError.UnsupportedOptionalParameter;
            }
        }

        readBytes += parameterValueLength;
    }

    if (readBytes != paramsLength) {
        return OpenParsingError.ParamLengthsInconsistency;
    }
}

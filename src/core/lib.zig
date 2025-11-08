pub fn Pair(comptime A: type, comptime B: type) type {
    return struct { A, B };
}

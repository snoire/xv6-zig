pub const Stat = extern struct {
    pub const Type = enum(u8) {
        dir = 1,
        file = 2,
        device = 3,
    };

    /// File system's disk device
    dev: c_int,
    /// Inode number
    ino: c_int,
    /// Type of file
    type: c_short,
    /// Number of links to file
    nlink: c_short,
    /// Size of file in bytes
    size: usize,
};

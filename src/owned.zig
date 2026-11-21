//! What this process opens, owned where it is opened and closed once there: a context or an
//! options struct is lent it (`borrow`), and never closes what it is lent.
const aegis = @import("aegis");

/// A directory this process opened: aegis's `own.Dir`.
pub const OwnedDir = aegis.own.Dir;
/// A file this process opened: aegis's `own.File`.
pub const OwnedFile = aegis.own.File;

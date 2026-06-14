/// Structural layout of the 32-byte Spectrum Packet Header.
/// All offsets are relative to the start of the packet.
pub const Layout = struct {
    num_segments: u32,
    num_profile_words: u32,
    num_centroid_words: u32,
    default_feature_word: u32,
    num_non_default_feature_words: u32,
    num_expansion_words: u32,
    num_noise_info_words: u32,
    num_debug_info_words: u32,

    header_size: usize,
};

pub const CURRENT = Layout{
    .num_segments = 0,
    .num_profile_words = 4,
    .num_centroid_words = 8,
    .default_feature_word = 12,
    .num_non_default_feature_words = 16,
    .num_expansion_words = 20,
    .num_noise_info_words = 24,
    .num_debug_info_words = 28,
    .header_size = 32,
};

// ============================================================================
// SpectrumPacketType enum values — Thermo-defined packet type codes.
// These are the u32 values stored in ScanIndexEntry.packet_type (masked with
// 0xFFFF). Verified from decompiled ThermoFisher.CommonCore.RawFileReader.
// ============================================================================
pub const PacketType = enum(u32) {
    profile_spectrum = 0,
    low_res_spectrum = 1,
    high_res_spectrum = 2,
    profile_index = 3,
    linear_trap_profile = 4,
    standard_accuracy = 5,
    linear_trap_centroid = 13,
    ft_centroid = 20,
    ft_profile = 21,
    high_res_compressed_profile = 22,
    low_res_compressed_profile = 23,
    low_res_spectrum_type = 24,
    _,

    /// Returns true for profile-mode packet types.
    pub fn is_profile(pt: PacketType) bool {
        return pt == .profile_spectrum or
            pt == .linear_trap_profile or
            pt == .ft_profile or
            pt == .high_res_compressed_profile or
            pt == .low_res_compressed_profile;
    }
};

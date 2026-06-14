/// PSI-MS Controlled Vocabulary — comptime lookup tables.
/// Provides zero-cost accession↔name resolution for common MS terms.
const std = @import("std");

pub const CVEntry = struct {
    accession: []const u8,
    name: []const u8,
    category: Category,

    pub const Category = enum {
        spectrum_type,
        scan_attribute,
        instrument_component,
        data_array,
        compression,
        file_format,
        unit,
        activation,
        other,
    };
};

const cv_table = &[_]CVEntry{
    .{ .accession = "MS:1000579", .name = "MS1 spectrum", .category = .spectrum_type },
    .{ .accession = "MS:1000580", .name = "MSn spectrum", .category = .spectrum_type },
    .{ .accession = "MS:1000127", .name = "centroid spectrum", .category = .spectrum_type },
    .{ .accession = "MS:1000128", .name = "profile spectrum", .category = .spectrum_type },
    .{ .accession = "MS:1000511", .name = "ms level", .category = .scan_attribute },
    .{ .accession = "MS:1000016", .name = "scan start time", .category = .scan_attribute },
    .{ .accession = "MS:1000501", .name = "scan window lower limit", .category = .scan_attribute },
    .{ .accession = "MS:1000500", .name = "scan window upper limit", .category = .scan_attribute },
    .{ .accession = "MS:1000504", .name = "base peak m/z", .category = .scan_attribute },
    .{ .accession = "MS:1000505", .name = "base peak intensity", .category = .scan_attribute },
    .{ .accession = "MS:1000285", .name = "total ion current", .category = .scan_attribute },
    .{ .accession = "MS:1000528", .name = "lowest observed m/z", .category = .scan_attribute },
    .{ .accession = "MS:1000527", .name = "highest observed m/z", .category = .scan_attribute },
    .{ .accession = "MS:1000130", .name = "positive scan", .category = .scan_attribute },
    .{ .accession = "MS:1000129", .name = "negative scan", .category = .scan_attribute },
    .{ .accession = "MS:1000512", .name = "filter string", .category = .scan_attribute },
    .{ .accession = "MS:1000927", .name = "ion injection time", .category = .scan_attribute },
    .{ .accession = "MS:1000795", .name = "no combination", .category = .scan_attribute },
    .{ .accession = "MS:1000042", .name = "peak intensity", .category = .scan_attribute },
    .{ .accession = "MS:1001581", .name = "FAIMS compensation voltage", .category = .scan_attribute },
    .{ .accession = "MS:1000810", .name = "ion current chromatogram", .category = .scan_attribute },
    .{ .accession = "MS:1000235", .name = "total ion current chromatogram", .category = .scan_attribute },
    .{ .accession = "MS:1000586", .name = "basepeak chromatogram", .category = .scan_attribute },
    .{ .accession = "MS:1000514", .name = "m/z array", .category = .data_array },
    .{ .accession = "MS:1000515", .name = "intensity array", .category = .data_array },
    .{ .accession = "MS:1000521", .name = "32-bit float", .category = .data_array },
    .{ .accession = "MS:1000523", .name = "64-bit float", .category = .data_array },
    .{ .accession = "MS:1000576", .name = "no compression", .category = .compression },
    .{ .accession = "MS:1000574", .name = "zlib compression", .category = .compression },
    .{ .accession = "MS:1002746", .name = "MS-Numpress linear prediction compression", .category = .compression },
    .{ .accession = "MS:1002747", .name = "MS-Numpress positive integer compression", .category = .compression },
    .{ .accession = "MS:1002748", .name = "MS-Numpress short logged float compression", .category = .compression },
    .{ .accession = "MS:1002749", .name = "MS-Numpress linear prediction compression followed by zlib compression", .category = .compression },
    .{ .accession = "MS:1000584", .name = "mzML format", .category = .file_format },
    .{ .accession = "MS:1000760", .name = "native spectrum identifier format", .category = .file_format },
    .{ .accession = "MS:1000768", .name = "Thermo nativeID format", .category = .file_format },
    .{ .accession = "MS:1000563", .name = "Thermo RAW format", .category = .file_format },
    .{ .accession = "MS:1000569", .name = "SHA-1", .category = .file_format },
    .{ .accession = "MS:1003145", .name = "ThermoRawFileParser", .category = .file_format },
    .{ .accession = "MS:1000031", .name = "instrument model", .category = .instrument_component },
    .{ .accession = "MS:1000483", .name = "Thermo Fisher Scientific instrument model", .category = .instrument_component },
    .{ .accession = "MS:1000494", .name = "Thermo Scientific instrument model", .category = .instrument_component },
    .{ .accession = "MS:1003378", .name = "Orbitrap Astral", .category = .instrument_component },
    .{ .accession = "MS:1003442", .name = "Orbitrap Astral Zoom", .category = .instrument_component },
    .{ .accession = "MS:1001911", .name = "Q Exactive", .category = .instrument_component },
    .{ .accession = "MS:1002523", .name = "Q Exactive HF", .category = .instrument_component },
    .{ .accession = "MS:1002634", .name = "Q Exactive Plus", .category = .instrument_component },
    .{ .accession = "MS:1002877", .name = "Q Exactive HF-X", .category = .instrument_component },
    .{ .accession = "MS:1002993", .name = "Q Exactive Focus", .category = .instrument_component },
    .{ .accession = "MS:1001910", .name = "Orbitrap Elite", .category = .instrument_component },
    .{ .accession = "MS:1002416", .name = "Orbitrap Fusion", .category = .instrument_component },
    .{ .accession = "MS:1002732", .name = "Orbitrap Fusion Lumos", .category = .instrument_component },
    .{ .accession = "MS:1003029", .name = "Orbitrap Eclipse", .category = .instrument_component },
    .{ .accession = "MS:1003028", .name = "Orbitrap Exploris 480", .category = .instrument_component },
    .{ .accession = "MS:1003094", .name = "Orbitrap Exploris 240", .category = .instrument_component },
    .{ .accession = "MS:1003095", .name = "Orbitrap Exploris 120", .category = .instrument_component },
    .{ .accession = "MS:1000448", .name = "LTQ FT", .category = .instrument_component },
    .{ .accession = "MS:1000449", .name = "LTQ Orbitrap", .category = .instrument_component },
    .{ .accession = "MS:1000556", .name = "LTQ Orbitrap XL", .category = .instrument_component },
    .{ .accession = "MS:1000557", .name = "LTQ FT Ultra", .category = .instrument_component },
    .{ .accession = "MS:1001742", .name = "LTQ Orbitrap Velos", .category = .instrument_component },
    .{ .accession = "MS:1000649", .name = "Exactive", .category = .instrument_component },
    .{ .accession = "MS:1002526", .name = "Exactive Plus", .category = .instrument_component },
    .{ .accession = "MS:1002874", .name = "TSQ Altis", .category = .instrument_component },
    .{ .accession = "MS:1002875", .name = "TSQ Quantis", .category = .instrument_component },
    .{ .accession = "MS:1000529", .name = "instrument serial number", .category = .instrument_component },
    .{ .accession = "MS:1000480", .name = "ionization type", .category = .instrument_component },
    .{ .accession = "MS:1000073", .name = "electrospray ionization", .category = .instrument_component },
    .{ .accession = "MS:1000485", .name = "detector type", .category = .instrument_component },
    .{ .accession = "MS:1000026", .name = "detector", .category = .instrument_component },
    .{ .accession = "MS:1000024", .name = "mass analyzer", .category = .instrument_component },
    .{ .accession = "MS:1000083", .name = "radial ejection linear ion trap", .category = .instrument_component },
    .{ .accession = "MS:1000482", .name = "orbitrap mass analyzer", .category = .instrument_component },
    .{ .accession = "MS:1000264", .name = "ion trap", .category = .instrument_component },
    .{ .accession = "MS:1000251", .name = "quadrupole", .category = .instrument_component },
    .{ .accession = "MS:1000021", .name = "quadrupole mass filter", .category = .instrument_component },
    .{ .accession = "MS:1000081", .name = "quadrupole ion trap", .category = .instrument_component },
    .{ .accession = "MS:1000079", .name = "fourier transform ion cyclotron resonance mass spectrometer", .category = .instrument_component },
    .{ .accession = "MS:1000126", .name = "time-of-flight", .category = .instrument_component },
    .{ .accession = "MS:1000029", .name = "source", .category = .instrument_component },
    .{ .accession = "MS:1000278", .name = "nanoelectrospray", .category = .instrument_component },
    .{ .accession = "MS:1000398", .name = "nanospray inlet", .category = .instrument_component },
    .{ .accession = "MS:1000478", .name = "nanospray", .category = .instrument_component },
    .{ .accession = "MS:1000041", .name = "charge state", .category = .other },
    .{ .accession = "MS:1000045", .name = "collision energy", .category = .other },
    .{ .accession = "MS:1000133", .name = "collision-induced dissociation", .category = .activation },
    .{ .accession = "MS:1000422", .name = "beam-type collision-induced dissociation", .category = .activation },
    .{ .accession = "MS:1000598", .name = "electron transfer dissociation", .category = .activation },
    .{ .accession = "MS:1000250", .name = "electron capture dissociation", .category = .activation },
    .{ .accession = "MS:1000827", .name = "isolation window target m/z", .category = .other },
    .{ .accession = "MS:1000828", .name = "isolation window lower offset", .category = .other },
    .{ .accession = "MS:1000829", .name = "isolation window upper offset", .category = .other },
    .{ .accession = "MS:1000744", .name = "selected ion m/z", .category = .other },
    .{ .accession = "MS:1000799", .name = "custom unreleased software tool", .category = .other },
    .{ .accession = "MS:1000544", .name = "Conversion to mzML", .category = .other },
    .{ .accession = "MS:1000035", .name = "peak picking", .category = .other },
    .{ .accession = "MS:1000629", .name = "low intensity data point removal", .category = .other },
    .{ .accession = "UO:0000010", .name = "second", .category = .unit },
    .{ .accession = "UO:0000031", .name = "minute", .category = .unit },
    .{ .accession = "MS:1000040", .name = "m/z", .category = .unit },
    .{ .accession = "MS:1000131", .name = "number of detector counts", .category = .unit },
    .{ .accession = "MS:1000132", .name = "percent collision energy", .category = .unit },
    .{ .accession = "MS:1000818", .name = "electronvolt", .category = .unit },
};

pub fn cv_name(accession: []const u8) []const u8 {
    for (cv_table) |entry| {
        if (std.mem.eql(u8, entry.accession, accession))
            return entry.name;
    }
    return "UNKNOWN";
}

pub fn lookup_accession(name: []const u8) ?[]const u8 {
    for (cv_table) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.accession;
    }
    return null;
}

pub fn cv_category(accession: []const u8) CVEntry.Category {
    for (cv_table) |entry| {
        if (std.mem.eql(u8, entry.accession, accession))
            return entry.category;
    }
    return .other;
}

pub const MS_MS_LEVEL = "MS:1000511";
pub const MS_1_SPECTRUM = "MS:1000579";
pub const MS_MSN_SPECTRUM = "MS:1000580";
pub const MS_MZ_ARRAY = "MS:1000514";
pub const MS_INTENSITY_ARRAY = "MS:1000515";
pub const MS_32_BIT_FLOAT = "MS:1000521";
pub const MS_64_BIT_FLOAT = "MS:1000523";
pub const MS_ZLIB_COMPRESSION = "MS:1000574";
pub const MS_NO_COMPRESSION = "MS:1000576";
pub const MS_NUMPRESS_LINEAR = "MS:1002746";
pub const MS_NUMPRESS_PIC = "MS:1002747";
pub const MS_NUMPRESS_SLOF = "MS:1002748";
pub const MS_NUMPRESS_ZLIB_LINEAR = "MS:1002749";
pub const MS_SCAN_START_TIME = "MS:1000016";
pub const MS_TIC = "MS:1000285";
pub const MS_BASE_PEAK_MZ = "MS:1000504";
pub const MS_BASE_PEAK_INT = "MS:1000505";
pub const MS_LOWEST_MZ = "MS:1000528";
pub const MS_HIGHEST_MZ = "MS:1000527";
pub const MS_CENTROID_SPECTRUM = "MS:1000127";
pub const MS_PROFILE_SPECTRUM = "MS:1000128";
pub const MS_MZML_FORMAT = "MS:1000584";
pub const MS_CHARGE_STATE = "MS:1000041";
pub const MS_COLLISION_ENERGY = "MS:1000045";
pub const MS_CID = "MS:1000133";
pub const MS_HCD = "MS:1000422";
pub const MS_ETD = "MS:1000598";
pub const MS_UNIT_SECOND = "UO:0000010";
pub const MS_UNIT_MINUTE = "UO:0000031";
pub const MS_UNIT_MZ = "MS:1000040";
pub const MS_UNIT_COUNTS = "MS:1000131";
pub const MS_UNIT_ELECTRONVOLT = "MS:1000818";
pub const MS_UNIT_PERCENT = "MS:1000132";
pub const MS_POSITIVE_SCAN = "MS:1000130";
pub const MS_NEGATIVE_SCAN = "MS:1000129";
pub const MS_FILTER_STRING = "MS:1000512";
pub const MS_ION_INJECTION_TIME = "MS:1000927";
pub const MS_NO_COMBINATION = "MS:1000795";
pub const MS_PEAK_INTENSITY = "MS:1000042";
pub const MS_FAIMS_CV = "MS:1001581";
pub const MS_ION_CURRENT_CHROMATOGRAM = "MS:1000810";
pub const MS_TIC_CHROMATOGRAM = "MS:1000235";
pub const MS_BASEPEAK_CHROMATOGRAM = "MS:1000586";
pub const MS_THERMO_NATIVEID = "MS:1000768";
pub const MS_THERMO_RAW_FORMAT = "MS:1000563";
pub const MS_SHA1 = "MS:1000569";
pub const MS_THERMO_RAW_FILE_PARSER = "MS:1003145";
pub const MS_PEAK_PICKING = "MS:1000035";
pub const MS_LOW_INTENSITY_REMOVAL = "MS:1000629";
pub const MS_INSTRUMENT_MODEL = "MS:1000031";
pub const MS_THERMO_FISHER = "MS:1000483";
pub const MS_THERMO_SCIENTIFIC = "MS:1000494";
pub const MS_ORBITRAP_ASTRAL = "MS:1003378";
pub const MS_ORBITRAP_ASTRAL_ZOOM = "MS:1003442";
pub const MS_Q_EXACTIVE = "MS:1001911";
pub const MS_Q_EXACTIVE_HF = "MS:1002523";
pub const MS_Q_EXACTIVE_PLUS = "MS:1002634";
pub const MS_Q_EXACTIVE_HFX = "MS:1002877";
pub const MS_ORBITRAP_ELITE = "MS:1001910";
pub const MS_ORBITRAP_FUSION = "MS:1002416";
pub const MS_ORBITRAP_FUSION_LUMOS = "MS:1002732";
pub const MS_ORBITRAP_ECLIPSE = "MS:1003029";
pub const MS_ORBITRAP_EXPLORIS_480 = "MS:1003028";
pub const MS_ORBITRAP_EXPLORIS_240 = "MS:1003094";
pub const MS_LTQ_ORBITRAP = "MS:1000449";
pub const MS_LTQ_ORBITRAP_VELOS = "MS:1001742";
pub const MS_LTQ_FT = "MS:1000448";
pub const MS_EXACTIVE = "MS:1000649";
pub const MS_TSQ_ALTIS = "MS:1002874";
pub const MS_TSQ_QUANTIS = "MS:1002875";
pub const MS_SERIAL_NUMBER = "MS:1000529";
pub const MS_IONIZATION_TYPE = "MS:1000480";
pub const MS_ESI = "MS:1000073";
pub const MS_DETECTOR_TYPE = "MS:1000485";
pub const MS_DETECTOR = "MS:1000026";
pub const MS_MASS_ANALYZER = "MS:1000024";
pub const MS_LINEAR_ION_TRAP = "MS:1000083";
pub const MS_ORBITRAP_ANALYZER = "MS:1000482";
pub const MS_ION_TRAP = "MS:1000264";
pub const MS_QUADRUPOLE = "MS:1000251";
pub const MS_QUADRUPOLE_FILTER = "MS:1000021";
pub const MS_QUADRUPOLE_ION_TRAP = "MS:1000081";
pub const MS_FTICR = "MS:1000079";
pub const MS_TOF = "MS:1000126";
pub const MS_SOURCE = "MS:1000029";
pub const MS_NANOESI = "MS:1000278";
pub const MS_NANOSPRAY = "MS:1000478";

test "cvName lookup" {
    try std.testing.expectEqualStrings("MS1 spectrum", cv_name("MS:1000579"));
    try std.testing.expectEqualStrings("m/z array", cv_name("MS:1000514"));
    try std.testing.expectEqualStrings("UNKNOWN", cv_name("MS:9999999"));
}

test "lookupAccession runtime" {
    try std.testing.expectEqualStrings("MS:1000579", lookup_accession("MS1 spectrum").?);
    try std.testing.expectEqualStrings("MS:1000514", lookup_accession("m/z array").?);
    try std.testing.expect(lookup_accession("nonexistent") == null);
}

test "cvCategory" {
    try std.testing.expectEqual(CVEntry.Category.spectrum_type, cv_category("MS:1000579"));
    try std.testing.expectEqual(CVEntry.Category.data_array, cv_category("MS:1000514"));
    try std.testing.expectEqual(CVEntry.Category.other, cv_category("MS:9999999"));
}

pub fn map_instrument_model(model: []const u8) ?struct { accession: []const u8, name: []const u8 } {
    // Reject values that are clearly file paths or empty
    if (model.len == 0) return null;
    if (std.mem.indexOf(u8, model, ":\\") != null) return null; // Windows path
    if (std.mem.indexOf(u8, model, "/") != null) return null; // Unix path
    if (std.mem.endsWith(u8, model, ".meth")) return null;
    if (std.mem.endsWith(u8, model, ".raw")) return null;

    // Use stack buffer for lowercasing — model strings are typically <256 chars
    var lower_buf: [256]u8 = undefined;
    const max_len = @min(model.len, lower_buf.len);
    for (model[0..max_len], 0..) |c, i| {
        lower_buf[i] = std.ascii.toLower(c);
    }
    const lower = lower_buf[0..max_len];

    if (std.mem.indexOf(u8, lower, "astral zoom") != null)
        return .{ .accession = MS_ORBITRAP_ASTRAL_ZOOM, .name = "Orbitrap Astral Zoom" };
    if (std.mem.indexOf(u8, lower, "astral") != null)
        return .{ .accession = MS_ORBITRAP_ASTRAL, .name = "Orbitrap Astral" };
    if (std.mem.indexOf(u8, lower, "eclipse") != null)
        return .{ .accession = MS_ORBITRAP_ECLIPSE, .name = "Orbitrap Eclipse" };
    if (std.mem.indexOf(u8, lower, "exploris 480") != null or std.mem.indexOf(u8, lower, "exploris480") != null)
        return .{ .accession = MS_ORBITRAP_EXPLORIS_480, .name = "Orbitrap Exploris 480" };
    if (std.mem.indexOf(u8, lower, "exploris 240") != null or std.mem.indexOf(u8, lower, "exploris240") != null)
        return .{ .accession = MS_ORBITRAP_EXPLORIS_240, .name = "Orbitrap Exploris 240" };
    if (std.mem.indexOf(u8, lower, "exploris 120") != null or std.mem.indexOf(u8, lower, "exploris120") != null)
        return .{ .accession = "MS:1003095", .name = "Orbitrap Exploris 120" };
    if (std.mem.indexOf(u8, lower, "exploris") != null)
        return .{ .accession = MS_ORBITRAP_EXPLORIS_480, .name = "Orbitrap Exploris 480" };
    if (std.mem.indexOf(u8, lower, "fusion lumos") != null or std.mem.indexOf(u8, lower, "fusion_lumos") != null)
        return .{ .accession = MS_ORBITRAP_FUSION_LUMOS, .name = "Orbitrap Fusion Lumos" };
    if (std.mem.indexOf(u8, lower, "fusion") != null)
        return .{ .accession = MS_ORBITRAP_FUSION, .name = "Orbitrap Fusion" };
    if (std.mem.indexOf(u8, lower, "hf-x") != null or std.mem.indexOf(u8, lower, "hfx") != null)
        return .{ .accession = MS_Q_EXACTIVE_HFX, .name = "Q Exactive HF-X" };
    if (std.mem.indexOf(u8, lower, "hf") != null and std.mem.indexOf(u8, lower, "q exactive") != null)
        return .{ .accession = MS_Q_EXACTIVE_HF, .name = "Q Exactive HF" };
    if (std.mem.indexOf(u8, lower, "q exactive plus") != null or std.mem.indexOf(u8, lower, "qexactiveplus") != null)
        return .{ .accession = MS_Q_EXACTIVE_PLUS, .name = "Q Exactive Plus" };
    if (std.mem.indexOf(u8, lower, "q exactive focus") != null)
        return .{ .accession = "MS:1002993", .name = "Q Exactive Focus" };
    if (std.mem.indexOf(u8, lower, "q exactive") != null or std.mem.indexOf(u8, lower, "qexactive") != null)
        return .{ .accession = MS_Q_EXACTIVE, .name = "Q Exactive" };
    if (std.mem.indexOf(u8, lower, "elite") != null)
        return .{ .accession = MS_ORBITRAP_ELITE, .name = "Orbitrap Elite" };
    if (std.mem.indexOf(u8, lower, "exactive plus") != null)
        return .{ .accession = "MS:1002526", .name = "Exactive Plus" };
    if (std.mem.indexOf(u8, lower, "exactive") != null)
        return .{ .accession = MS_EXACTIVE, .name = "Exactive" };
    if (std.mem.indexOf(u8, lower, "ltq orbitrap velos") != null)
        return .{ .accession = MS_LTQ_ORBITRAP_VELOS, .name = "LTQ Orbitrap Velos" };
    if (std.mem.indexOf(u8, lower, "ltq orbitrap xl") != null)
        return .{ .accession = "MS:1000556", .name = "LTQ Orbitrap XL" };
    if (std.mem.indexOf(u8, lower, "ltq orbitrap") != null)
        return .{ .accession = MS_LTQ_ORBITRAP, .name = "LTQ Orbitrap" };
    if (std.mem.indexOf(u8, lower, "ltq ft ultra") != null)
        return .{ .accession = "MS:1000557", .name = "LTQ FT Ultra" };
    if (std.mem.indexOf(u8, lower, "ltq ft") != null)
        return .{ .accession = MS_LTQ_FT, .name = "LTQ FT" };
    if (std.mem.indexOf(u8, lower, "tsq altis") != null)
        return .{ .accession = MS_TSQ_ALTIS, .name = "TSQ Altis" };
    if (std.mem.indexOf(u8, lower, "tsq quantis") != null)
        return .{ .accession = MS_TSQ_QUANTIS, .name = "TSQ Quantis" };
    if (std.mem.indexOf(u8, lower, "tsq") != null)
        return .{ .accession = MS_TSQ_ALTIS, .name = "TSQ Altis" };
    if (std.mem.indexOf(u8, lower, "ltq") != null)
        return .{ .accession = MS_LTQ_ORBITRAP, .name = "LTQ Orbitrap" };

    return null;
}

test "mapInstrumentModel" {
    const result = map_instrument_model("Orbitrap Astral Zoom").?;
    try std.testing.expectEqualStrings("MS:1003442", result.accession);
    try std.testing.expectEqualStrings("Orbitrap Astral Zoom", result.name);

    try std.testing.expect(map_instrument_model("") == null);
    try std.testing.expect(map_instrument_model("C:\\data\\file.raw") == null);
    try std.testing.expect(map_instrument_model("unknown_device") == null);
}

test "comptime constants" {
    try std.testing.expectEqualStrings("MS:1000511", MS_MS_LEVEL);
    try std.testing.expectEqualStrings("MS:1000579", MS_1_SPECTRUM);
}

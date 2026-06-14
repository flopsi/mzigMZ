/// Shared Win32 types, constants, and utilities used across all GUI modules.
const std = @import("std");

pub const HWND = ?*anyopaque;
pub const HINSTANCE = ?*anyopaque;
pub const HDC = ?*anyopaque;
pub const HBRUSH = ?*anyopaque;
pub const HGDIOBJ = ?*anyopaque;
pub const HMENU = ?*anyopaque;
pub const HICON = ?*anyopaque;
pub const HCURSOR = ?*anyopaque;
pub const HFONT = ?*anyopaque;
pub const HPEN = ?*anyopaque;
pub const HBITMAP = ?*anyopaque;
pub const LPCWSTR = [*:0]const u16;
pub const LPWSTR = [*:0]u16;
pub const UINT = u32;
pub const DWORD = u32;
pub const BOOL = i32;
pub const INT = i32;
pub const ATOM = u16;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const LONG = i32;
pub const WORD = u16;
pub const BYTE = u8;
pub const LPARAM_PTR = ?*anyopaque;

pub const POINT = extern struct {
    x: LONG,
    y: LONG,
};

pub const MSG = extern struct {
    hwnd: HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
    lPrivate: DWORD,
};

pub const RECT = extern struct {
    left: LONG,
    top: LONG,
    right: LONG,
    bottom: LONG,
};

pub const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT,
    cbClsExtra: INT,
    cbWndExtra: INT,
    hInstance: HINSTANCE,
    hIcon: HICON,
    hCursor: HCURSOR,
    hbrBackground: HBRUSH,
    lpszMenuName: ?LPCWSTR,
    lpszClassName: LPCWSTR,
    hIconSm: HICON,
};

pub const CREATESTRUCTW = extern struct {
    lpCreateParams: LPARAM_PTR,
    hInstance: HINSTANCE,
    hMenu: HMENU,
    hwndParent: HWND,
    cy: INT,
    cx: INT,
    y: INT,
    x: INT,
    style: LONG,
    lpszName: LPCWSTR,
    lpszClass: LPCWSTR,
    dwExStyle: DWORD,
};

pub const SIZE = extern struct {
    cx: LONG,
    cy: LONG,
};

pub const OPENFILENAMEW = extern struct {
    lStructSize: DWORD,
    hwndOwner: HWND,
    hInstance: HINSTANCE,
    lpstrFilter: ?LPCWSTR,
    lpstrCustomFilter: ?LPWSTR,
    nMaxCustFilter: DWORD,
    nFilterIndex: DWORD,
    lpstrFile: LPWSTR,
    nMaxFile: DWORD,
    lpstrFileTitle: ?LPWSTR,
    nMaxFileTitle: DWORD,
    lpstrInitialDir: ?LPCWSTR,
    lpstrTitle: ?LPCWSTR,
    Flags: DWORD,
    nFileOffset: WORD,
    nFileExtension: WORD,
    lpstrDefExt: ?LPCWSTR,
    lCustData: LPARAM,
    lpfnHook: ?*anyopaque,
    lpTemplateName: ?LPCWSTR,
    pvReserved: ?*anyopaque,
    dwReserved: DWORD,
    FlagsEx: DWORD,
};

// Window styles
pub const WS_OVERLAPPED = 0x00000000;
pub const WS_CAPTION = 0x00C00000;
pub const WS_THICKFRAME = 0x00040000;
pub const WS_SYSMENU = 0x00080000;
pub const WS_MINIMIZEBOX = 0x00020000;
pub const WS_MAXIMIZEBOX = 0x00010000;
pub const WS_OVERLAPPEDWINDOW = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;
pub const WS_VISIBLE = 0x10000000;
pub const WS_CHILD = 0x40000000;
pub const WS_CLIPCHILDREN = 0x02000000;
pub const WS_CLIPSIBLINGS = 0x04000000;
pub const WS_VSCROLL = 0x00200000;
pub const WS_HSCROLL = 0x00100000;
pub const WS_BORDER = 0x00800000;

// Extended window styles
pub const WS_EX_CLIENTEDGE = 0x00000200;

// ShowWindow commands
pub const SW_SHOW = 5;
pub const SW_HIDE = 0;
pub const SW_SHOWDEFAULT = 10;

// Window messages
pub const WM_PAINT = 0x000F;
pub const WM_DESTROY = 0x0002;
pub const WM_SIZE = 0x0005;
pub const WM_CREATE = 0x0001;
pub const WM_CLOSE = 0x0010;
pub const WM_COMMAND = 0x0111;
pub const WM_NOTIFY = 0x004E;
pub const WM_MOUSEWHEEL = 0x020A;
pub const WM_LBUTTONDOWN = 0x0201;
pub const WM_LBUTTONUP = 0x0202;
pub const WM_RBUTTONDOWN = 0x0204;
pub const WM_MOUSEMOVE = 0x0200;
pub const WM_LBUTTONDBLCLK = 0x0203;
pub const WM_KEYDOWN = 0x0100;
pub const WM_SETCURSOR = 0x0020;
pub const WM_ERASEBKGND = 0x0014;
pub const WM_HSCROLL = 0x0114;
pub const WM_VSCROLL = 0x0115;
pub const WM_TIMER = 0x0113;
pub const WM_INITMENUPOPUP = 0x0117;

// Mouse wheel
pub const WHEEL_DELTA = 120;

// Menu flags
pub const MF_STRING = 0x00000000;
pub const MF_POPUP = 0x00000010;
pub const MF_SEPARATOR = 0x00000800;
pub const MF_GRAYED = 0x00000001;
pub const MF_CHECKED = 0x00000008;

// Class styles
pub const CS_HREDRAW = 0x0002;
pub const CS_VREDRAW = 0x0001;
pub const CS_DBLCLKS = 0x0008;

// GDI constants
pub const PS_SOLID = 0;
pub const PS_DASH = 1;
pub const BLACK_PEN = 7;
pub const WHITE_BRUSH = 0;
pub const LTGRAY_BRUSH = 1;
pub const GRAY_BRUSH = 2;
pub const DKGRAY_BRUSH = 3;
pub const BLACK_BRUSH = 4;
pub const TRANSPARENT = 1;
pub const OPAQUE = 2;

// Color
pub const COLOR_WINDOW = 5;
pub const COLOR_BTNFACE = 15;

// Menu constants
pub const MF_ENABLED = 0x00000000;
pub const MF_UNCHECKED = 0x00000000;

// ListView constants
pub const LVS_REPORT = 0x0001;
pub const LVS_SINGLESEL = 0x0004;
pub const LVS_SHOWSELALWAYS = 0x0008;
pub const LVS_NOSORTHEADER = 0x8000;
pub const LVS_OWNERDATA = 0x1000;
pub const LVM_INSERTCOLUMNW = 0x1061;
pub const LVM_INSERTITEMW = 0x104D;
pub const LVM_SETITEMW = 0x104C;
pub const LVM_GETITEMW = 0x104B;
pub const LVM_GETITEMCOUNT = 0x1004;
pub const LVM_GETNEXTITEM = 0x100C;
pub const LVM_ENSUREVISIBLE = 0x1013;
pub const LVM_SETITEMSTATE = 0x102B;
pub const LVM_GETITEMSTATE = 0x102C;
pub const LVM_DELETEALLITEMS = 0x1009;
pub const LVNI_SELECTED = 0x0002;
pub const LVIS_SELECTED = 0x0002;
pub const LVIS_FOCUSED = 0x0001;
pub const LVCF_FMT = 0x0001;
pub const LVCF_WIDTH = 0x0002;
pub const LVCF_TEXT = 0x0004;
pub const LVCF_SUBITEM = 0x0008;
pub const LVCFMT_LEFT = 0x0000;
pub const LVCFMT_RIGHT = 0x0001;
pub const LVCFMT_CENTER = 0x0002;
pub const LVIF_TEXT = 0x0001;
pub const LVIF_PARAM = 0x0004;
pub const LVIF_STATE = 0x0008;
pub const NM_CLICK = 0xFFFFFFFE;
pub const NM_DBLCLK = 0xFFFFFFFD;
pub const NM_RETURN = 0xFFFFFFFC;
pub const LVN_FIRST = 0xFFFFFF9C;
pub const LVN_ITEMCHANGED = LVN_FIRST - 1;
pub const LVN_GETDISPINFO = LVN_FIRST - 77;

// Edit control styles
pub const ES_NUMBER = 0x2000;
pub const ES_AUTOHSCROLL = 0x0080;
pub const WM_GETTEXT = 0x000D;
pub const WM_SETTEXT = 0x000C;
pub const EN_CHANGE = 0x0300;
pub const EN_KILLFOCUS = 0x0200;
pub const BN_CLICKED = 0;
pub const BS_PUSHBUTTON = 0x00000000;
pub const BS_AUTORADIOBUTTON = 0x00000009;

// Status bar
pub const SBARS_SIZEGRIP = 0x0100;
pub const SB_SETTEXTW = 0x040B;
pub const SB_SETPARTS = 0x0404;

// Common controls
pub const ICC_LISTVIEW_CLASSES = 0x00000001;
pub const ICC_BAR_CLASSES = 0x00000004;

pub const INITCOMMONCONTROLSEX = extern struct {
    dwSize: DWORD,
    dwICC: DWORD,
};

// File dialog flags
pub const OFN_EXPLORER = 0x00080000;
pub const OFN_FILEMUSTEXIST = 0x00001000;
pub const OFN_HIDEREADONLY = 0x00000004;
pub const OFN_NOCHANGEDIR = 0x00000008;

// Virtual keys
pub const VK_PRIOR = 0x21;
pub const VK_NEXT = 0x22;
pub const VK_HOME = 0x24;
pub const VK_END = 0x25;
pub const VK_LEFT = 0x25;
pub const VK_UP = 0x26;
pub const VK_RIGHT = 0x27;
pub const VK_DOWN = 0x28;
pub const VK_O = 0x4F;
pub const VK_ADD = 0x6B;
pub const VK_SUBTRACT = 0x6D;
pub const VK_ESCAPE = 0x1B;

// Cursor IDs
pub const IDC_ARROW = 32512;
pub const IDC_SIZEALL = 32646;
pub const IDC_SIZEWE = 32644;
pub const IDC_CROSS = 32515;

// MessageBox
pub const MB_OK = 0x00000000;
pub const MB_OKCANCEL = 0x00000001;
pub const MB_ICONERROR = 0x00000010;
pub const MB_ICONINFORMATION = 0x00000040;
pub const MB_ICONQUESTION = 0x00000020;
pub const IDOK = 1;

// SetWindowPos
pub const HWND_TOP = null;
pub const SWP_FRAMECHANGED = 0x0020;
pub const SWP_NOMOVE = 0x0002;
pub const SWP_NOSIZE = 0x0001;
pub const SWP_NOZORDER = 0x0004;
pub const SWP_SHOWWINDOW = 0x0040;

// GetWindowLong
pub const GWL_STYLE = -16;
pub const GWL_EXSTYLE = -20;
pub const GWL_USERDATA = -21;
pub const GWLP_USERDATA = -21;
pub const GWLP_WNDPROC = -4;

// Scrollbar
pub const SB_HORZ = 0;
pub const SB_VERT = 1;
pub const SB_CTL = 2;
pub const SIF_RANGE = 0x0001;
pub const SIF_PAGE = 0x0002;
pub const SIF_POS = 0x0004;
pub const SIF_ALL = SIF_RANGE | SIF_PAGE | SIF_POS;

pub const SCROLLINFO = extern struct {
    cbSize: UINT,
    fMask: UINT,
    nMin: INT,
    nMax: INT,
    nPage: UINT,
    nPos: INT,
    nTrackPos: INT,
};

// NMHDR
pub const NMHDR = extern struct {
    hwndFrom: HWND,
    idFrom: usize,
    code: UINT,
};

// NMITEMACTIVATE
pub const NMITEMACTIVATE = extern struct {
    hdr: NMHDR,
    iItem: INT,
    iSubItem: INT,
    uNewState: UINT,
    uOldState: UINT,
    uChanged: UINT,
    ptAction: POINT,
    lParam: LPARAM,
    uKeyFlags: UINT,
};

// LVITEMW
pub const LVITEMW = extern struct {
    mask: UINT,
    iItem: INT,
    iSubItem: INT,
    state: UINT,
    stateMask: UINT,
    pszText: ?LPWSTR,
    cchTextMax: INT,
    iImage: INT,
    lParam: LPARAM,
    iIndent: INT,
    iGroupId: INT,
    cColumns: UINT,
    puColumns: ?*UINT,
    piColFmt: ?*INT,
    iGroup: INT,
};

pub const NMLVDISPINFOW = extern struct {
    hdr: NMHDR,
    item: LVITEMW,
};

// LVCOLUMNW
pub const LVCOLUMNW = extern struct {
    mask: UINT,
    fmt: INT,
    cx: INT,
    pszText: ?LPWSTR,
    cchTextMax: INT,
    iSubItem: INT,
    iImage: INT,
    iOrder: INT,
    cxMin: INT,
    cxDefault: INT,
    cxIdeal: INT,
};

// NMCUSTOMDRAW
pub const NMCUSTOMDRAW = extern struct {
    hdr: NMHDR,
    dwDrawStage: DWORD,
    hdc: HDC,
    rc: RECT,
    dwItemSpec: usize,
    uItemState: UINT,
    lItemlParam: LPARAM,
};

// Custom draw stages
pub const CDDS_PREPAINT = 0x00000001;
pub const CDDS_ITEM = 0x00010000;
pub const CDDS_ITEMPREPAINT = CDDS_ITEM | 0x00000001;
pub const CDRF_DODEFAULT = 0x00000000;
pub const CDRF_NOTIFYITEMDRAW = 0x00000020;
pub const CDRF_NEWFONT = 0x00000002;

// Tooltip
pub const CW_USEDEFAULT: INT = -2147483648;

pub const WS_POPUP = 0x80000000;
pub const TTM_ADDTOOLW = 0x0432;
pub const TTM_UPDATETIPTEXTW = 0x0439;
pub const TTM_SETMAXTIPWIDTH = 0x0418;
pub const TTM_SETDELAYTIME = 0x0403;
pub const TTDT_AUTOPOP = 2;
pub const TTF_SUBCLASS = 0x0010;

pub const TOOLINFOW = extern struct {
    cbSize: UINT,
    uFlags: UINT,
    hwnd: HWND,
    uId: UINT,
    rect: RECT,
    hinst: HINSTANCE,
    lpszText: ?LPWSTR,
    lParam: LPARAM,
    lpReserved: ?*anyopaque,
};

// Helper: make RGB color
pub fn rgb(r: u8, g: u8, b: u8) DWORD {
    return @as(DWORD, r) | (@as(DWORD, g) << 8) | (@as(DWORD, b) << 16);
}

// Helper: convert UTF-8 to UTF-16 stack string (compile-time only)
pub fn utf8_to_utf16(comptime text: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(text);
}

pub const Utf8ToUtf16Error = std.mem.Allocator.Error || error{InvalidUtf8};

// Helper: convert UTF-8 to UTF-16 heap-allocated string
pub fn utf8_to_utf16_alloc(allocator: std.mem.Allocator, text: []const u8) Utf8ToUtf16Error![:0]u16 {
    const out = try allocator.alloc(u16, text.len + 1);
    const len = try std.unicode.utf8ToUtf16Le(out, text);
    out[len] = 0;
    return out[0..len :0];
}

pub const Utf8ToUtf16BufError = error{};

// Helper: convert UTF-8 slice to UTF-16 in a provided u16 buffer, returns slice
pub fn utf8_to_utf16_buf(out: []u16, text: []const u8) Utf8ToUtf16BufError![]u16 {
    var i: usize = 0;
    var j: usize = 0;
    while (i < text.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
        if (i + cp_len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i..][0..cp_len]) catch break;
        if (cp < 0x10000) {
            if (j >= out.len) break;
            out[j] = @intCast(cp);
            j += 1;
        } else {
            if (j + 1 >= out.len) break;
            const u = cp - 0x10000;
            out[j] = @intCast(0xD800 + (u >> 10));
            out[j + 1] = @intCast(0xDC00 + (u & 0x3FF));
            j += 2;
        }
        i += cp_len;
    }
    return out[0..j];
}

// Helper: draw UTF-8 text at position
pub fn draw_text_utf8(hdc: HDC, x: INT, y: INT, comptime text: []const u8) void {
    const wide = std.unicode.utf8ToUtf16LeStringLiteral(text);
    _ = TextOutW(hdc, x, y, wide.ptr, @intCast(wide.len));
}

// Helper: get LOWORD/HIWORD from LPARAM
pub fn loword(v: LPARAM) WORD {
    return @intCast(v & 0xFFFF);
}

pub fn hiword(v: LPARAM) WORD {
    return @intCast((v >> 16) & 0xFFFF);
}

pub fn get_x(lParam: LPARAM) INT {
    return @intCast(lParam & 0xFFFF);
}

pub fn get_y(lParam: LPARAM) INT {
    return @intCast((lParam >> 16) & 0xFFFF);
}

// Helper: clamp value
pub fn clamp(v: anytype, min: @TypeOf(v), max: @TypeOf(v)) @TypeOf(v) {
    if (v < min) return min;
    if (v > max) return max;
    return v;
}

/// Nice round number for axis tick spacing (1, 2, 5, 10 × 10^n).
pub fn nice_round(val: f64) f64 {
    if (val <= 0) return 1.0;
    const mag = std.math.pow(f64, 10.0, @floor(@log10(val)));
    const norm = val / mag;
    const nice = if (norm <= 1.0) @as(f64, 1.0) else if (norm <= 2.0) @as(f64, 2.0) else if (norm <= 5.0) @as(f64, 5.0) else @as(f64, 10.0);
    return nice * mag;
}

// Win32 extern functions
pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?LPCWSTR) callconv(.winapi) HINSTANCE;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn MulDiv(nNumber: INT, nNumerator: INT, nDenominator: INT) callconv(.winapi) INT;
pub extern "user32" fn LoadCursorW(hInstance: HINSTANCE, lpCursorName: ?*const anyopaque) callconv(.winapi) HCURSOR;
pub extern "user32" fn LoadCursorA(hInstance: HINSTANCE, lpCursorName: ?*const anyopaque) callconv(.winapi) HCURSOR;

pub extern "kernel32" fn SetCursor(hCursor: HCURSOR) callconv(.winapi) HCURSOR;

pub extern "user32" fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) callconv(.winapi) ATOM;
pub extern "user32" fn CreateWindowExW(dwExStyle: DWORD, lpClassName: LPCWSTR, lpWindowName: LPCWSTR, dwStyle: DWORD, x: INT, y: INT, nWidth: INT, nHeight: INT, hWndParent: HWND, hMenu: HMENU, hInstance: HINSTANCE, lpParam: ?*anyopaque) callconv(.winapi) HWND;
pub extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: INT) callconv(.winapi) BOOL;
pub extern "user32" fn UpdateWindow(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn PostQuitMessage(nExitCode: INT) callconv(.winapi) void;
pub extern "user32" fn PostMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn SendMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.winapi) HDC;
pub extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn InvalidateRect(hWnd: HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn ScreenToClient(hWnd: HWND, lpPoint: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn ClientToScreen(hWnd: HWND, lpPoint: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: LPCWSTR) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowTextW(hWnd: HWND, lpString: LPWSTR, nMaxCount: INT) callconv(.winapi) INT;
pub extern "user32" fn SetWindowPos(hWnd: HWND, hWndInsertAfter: HWND, X: INT, Y: INT, cx: INT, cy: INT, uFlags: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn MoveWindow(hWnd: HWND, X: INT, Y: INT, nWidth: INT, nHeight: INT, bRepaint: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn GetDC(hWnd: HWND) callconv(.winapi) HDC;
pub extern "user32" fn ReleaseDC(hWnd: HWND, hDC: HDC) callconv(.winapi) INT;
pub extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: INT) callconv(.winapi) isize;
pub extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: INT, dwNewLong: isize) callconv(.winapi) isize;
pub extern "user32" fn SetFocus(hWnd: HWND) callconv(.winapi) HWND;
pub extern "user32" fn SetCapture(hWnd: HWND) callconv(.winapi) HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn TrackMouseEvent(lpEventTrack: *anyopaque) callconv(.winapi) BOOL;
pub extern "user32" fn LoadIconW(hInstance: HINSTANCE, lpIconName: LPCWSTR) callconv(.winapi) HICON;
pub extern "user32" fn MessageBoxW(hWnd: HWND, lpText: LPCWSTR, lpCaption: LPCWSTR, uType: UINT) callconv(.winapi) INT;
pub extern "user32" fn AppendMenuW(hMenu: HMENU, uFlags: UINT, uIDNewItem: usize, lpNewItem: ?LPCWSTR) callconv(.winapi) BOOL;
pub extern "user32" fn CreateMenu() callconv(.winapi) HMENU;
pub extern "user32" fn CreatePopupMenu() callconv(.winapi) HMENU;
pub extern "user32" fn DestroyMenu(hMenu: HMENU) callconv(.winapi) BOOL;
pub extern "user32" fn SetMenu(hWnd: HWND, hMenu: HMENU) callconv(.winapi) BOOL;
pub extern "user32" fn DrawMenuBar(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn EnableMenuItem(hMenu: HMENU, uIDEnableItem: UINT, uEnable: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn CheckMenuItem(hMenu: HMENU, uIDCheckItem: UINT, uCheck: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetSubMenu(hMenu: HMENU, nPos: INT) callconv(.winapi) HMENU;
pub extern "user32" fn GetMenuItemID(hMenu: HMENU, nPos: INT) callconv(.winapi) UINT;
pub extern "user32" fn SetScrollInfo(hWnd: HWND, nBar: INT, lpsi: *SCROLLINFO, redraw: BOOL) callconv(.winapi) INT;
pub extern "user32" fn GetScrollInfo(hWnd: HWND, nBar: INT, lpsi: *SCROLLINFO) callconv(.winapi) BOOL;
pub extern "user32" fn SetScrollPos(hWnd: HWND, nBar: INT, nPos: INT, bRedraw: BOOL) callconv(.winapi) INT;
pub extern "user32" fn GetScrollPos(hWnd: HWND, nBar: INT) callconv(.winapi) INT;
pub extern "user32" fn GetKeyState(nVirtKey: INT) callconv(.winapi) INT;
pub extern "user32" fn GetFocus() callconv(.winapi) HWND;
pub extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.winapi) BOOL;

pub extern "gdi32" fn MoveToEx(hdc: HDC, x: INT, y: INT, lppt: ?*POINT) callconv(.winapi) BOOL;
pub extern "gdi32" fn LineTo(hdc: HDC, x: INT, y: INT) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreatePen(iStyle: INT, cWidth: INT, color: DWORD) callconv(.winapi) HGDIOBJ;
pub extern "gdi32" fn SelectObject(hdc: HDC, h: HGDIOBJ) callconv(.winapi) HGDIOBJ;
pub extern "gdi32" fn DeleteObject(ho: HGDIOBJ) callconv(.winapi) BOOL;
pub extern "gdi32" fn GetStockObject(i: INT) callconv(.winapi) HGDIOBJ;
pub extern "gdi32" fn Rectangle(hdc: HDC, left: INT, top: INT, right: INT, bottom: INT) callconv(.winapi) BOOL;
pub extern "gdi32" fn TextOutW(hdc: HDC, x: INT, y: INT, lpString: [*]const u16, c: INT) callconv(.winapi) BOOL;
pub extern "gdi32" fn SetBkMode(hdc: HDC, mode: INT) callconv(.winapi) INT;
pub extern "gdi32" fn SetTextColor(hdc: HDC, color: DWORD) callconv(.winapi) DWORD;
pub extern "gdi32" fn SetBkColor(hdc: HDC, color: DWORD) callconv(.winapi) DWORD;
pub extern "gdi32" fn CreateSolidBrush(color: DWORD) callconv(.winapi) HBRUSH;
pub extern "gdi32" fn CreateFontW(nHeight: INT, nWidth: INT, nEscapement: INT, nOrientation: INT, fnWeight: INT, fdwItalic: DWORD, fdwUnderline: DWORD, fdwStrikeOut: DWORD, fdwCharSet: DWORD, fdwOutputPrecision: DWORD, fdwClipPrecision: DWORD, fdwQuality: DWORD, fdwPitchAndFamily: DWORD, lpszFace: LPCWSTR) callconv(.winapi) HFONT;
pub extern "gdi32" fn Polyline(hdc: HDC, apt: [*]const POINT, cpt: INT) callconv(.winapi) BOOL;
pub extern "gdi32" fn SetPixel(hdc: HDC, x: INT, y: INT, color: DWORD) callconv(.winapi) DWORD;
pub extern "gdi32" fn FillRect(hDC: HDC, lprc: *const RECT, hbr: HBRUSH) callconv(.winapi) INT;
pub extern "gdi32" fn FrameRect(hDC: HDC, lprc: *const RECT, hbr: HBRUSH) callconv(.winapi) INT;
pub extern "gdi32" fn GetTextExtentPoint32W(hdc: HDC, lpString: [*]const u16, c: INT, psizl: *SIZE) callconv(.winapi) BOOL;

pub extern "comdlg32" fn GetOpenFileNameW(lpofn: *OPENFILENAMEW) callconv(.winapi) BOOL;

pub extern "comctl32" fn InitCommonControlsEx(lpInitCtrls: *INITCOMMONCONTROLSEX) callconv(.winapi) BOOL;
pub extern "comctl32" fn CreateStatusWindowW(style: LONG, lpszText: LPCWSTR, hwndParent: HWND, wID: UINT) callconv(.winapi) HWND;

// ListView extended styles
pub const LVS_EX_FULLROWSELECT = 0x00000020;
pub const LVS_EX_GRIDLINES = 0x00000001;

// LVM messages missing from earlier definitions
pub const LVM_SETEXTENDEDLISTVIEWSTYLE = 0x1036;

// DrawText flags
pub const DT_TOP = 0x00000000;
pub const DT_LEFT = 0x00000000;
pub const DT_CENTER = 0x00000001;
pub const DT_RIGHT = 0x00000002;
pub const DT_VCENTER = 0x00000004;
pub const DT_BOTTOM = 0x00000008;
pub const DT_WORDBREAK = 0x00000010;
pub const DT_SINGLELINE = 0x00000020;

// Missing user32 externs
pub extern "user32" fn GetDlgItem(hDlg: HWND, nIDDlgItem: INT) callconv(.winapi) HWND;
pub extern "user32" fn GetParent(hWnd: HWND) callconv(.winapi) HWND;
pub extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn DrawTextW(hDC: HDC, lpchText: LPCWSTR, cchText: INT, lprc: *RECT, format: UINT) callconv(.winapi) INT;

// ListView helper macros
pub fn list_view_set_extended_list_view_style(hwnd: HWND, dwExStyle: DWORD) DWORD {
    return @intCast(SendMessageW(hwnd, LVM_SETEXTENDEDLISTVIEWSTYLE, 0, @intCast(dwExStyle)));
}
pub fn list_view_insert_column(hwnd: HWND, iCol: INT, pcol: *LVCOLUMNW) INT {
    return @intCast(SendMessageW(hwnd, LVM_INSERTCOLUMNW, @intCast(iCol), @intCast(@intFromPtr(pcol))));
}
pub fn list_view_insert_item(hwnd: HWND, pitem: *LVITEMW) INT {
    return @intCast(SendMessageW(hwnd, LVM_INSERTITEMW, 0, @intCast(@intFromPtr(pitem))));
}
pub fn list_view_set_item(hwnd: HWND, pitem: *LVITEMW) BOOL {
    return @intCast(SendMessageW(hwnd, LVM_SETITEMW, 0, @intCast(@intFromPtr(pitem))));
}
pub fn list_view_delete_all_items(hwnd: HWND) BOOL {
    return @intCast(SendMessageW(hwnd, LVM_DELETEALLITEMS, 0, 0));
}
pub fn list_view_set_item_state(hwnd: HWND, i: INT, state: UINT, mask: UINT) BOOL {
    var item: LVITEMW = .{
        .mask = LVIF_STATE,
        .iItem = i,
        .iSubItem = 0,
        .state = state,
        .stateMask = mask,
        .pszText = null,
        .cchTextMax = 0,
        .iImage = 0,
        .lParam = 0,
        .iIndent = 0,
        .iGroupId = 0,
        .cColumns = 0,
        .puColumns = null,
        .piColFmt = null,
        .iGroup = 0,
    };
    return @intCast(SendMessageW(hwnd, LVM_SETITEMSTATE, @intCast(i), @intCast(@intFromPtr(&item))));
}
pub fn list_view_ensure_visible(hwnd: HWND, i: INT, fPartialOK: BOOL) BOOL {
    return @intCast(SendMessageW(hwnd, LVM_ENSUREVISIBLE, @intCast(i), @intCast(fPartialOK)));
}
pub fn list_view_get_next_item(hwnd: HWND, iStart: INT, flags: UINT) INT {
    return @intCast(SendMessageW(hwnd, LVM_GETNEXTITEM, @intCast(iStart), @intCast(flags)));
}

pub fn list_view_get_item(hwnd: HWND, pitem: *LVITEMW) BOOL {
    return @intCast(SendMessageW(hwnd, LVM_GETITEMW, 0, @intCast(@intFromPtr(pitem))));
}
pub fn list_view_set_item_count(hwnd: HWND, cItems: INT) void {
    const LVM_SETITEMCOUNT = 0x102F;
    _ = SendMessageW(hwnd, LVM_SETITEMCOUNT, @intCast(cItems), 0);
}

pub fn list_view_get_top_index(hwnd: HWND) INT {
    const LVM_GETTOPINDEX = 0x1027;
    return @intCast(SendMessageW(hwnd, LVM_GETTOPINDEX, 0, 0));
}

pub fn list_view_get_count_per_page(hwnd: HWND) INT {
    const LVM_GETCOUNTPERPAGE = 0x1028;
    return @intCast(SendMessageW(hwnd, LVM_GETCOUNTPERPAGE, 0, 0));
}

// ---------------------------------------------------------------------------
// Extra helpers added by refactored codebase
// ---------------------------------------------------------------------------

pub fn utf8_to_utf16_z(comptime text: []const u8) [:0]const u16 {
    return utf8_to_utf16(text);
}

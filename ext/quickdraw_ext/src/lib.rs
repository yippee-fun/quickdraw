use std::ffi::{c_char, c_int, c_ulong, c_void};
use std::sync::atomic::{AtomicUsize, Ordering};

type VALUE = usize;

static QNIL: AtomicUsize = AtomicUsize::new(0);

#[repr(C)]
struct Timespec {
    tv_sec: isize,
    tv_nsec: isize,
}

#[repr(C)]
struct Winsize {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
}

extern "C" {
    fn rb_define_module(name: *const c_char) -> VALUE;
    fn rb_define_module_under(outer: VALUE, name: *const c_char) -> VALUE;
    fn rb_define_singleton_method(
        obj: VALUE,
        name: *const c_char,
        func: *const c_void,
        argc: c_int,
    );
    fn rb_eval_string(str: *const c_char) -> VALUE;
    fn rb_ull2inum(val: u64) -> VALUE;
    fn rb_int2inum(val: isize) -> VALUE;
    fn rb_num2int(val: VALUE) -> c_int;
    fn rb_ary_new_capa(capa: isize) -> VALUE;
    fn rb_ary_push(ary: VALUE, elem: VALUE) -> VALUE;

    fn clock_gettime(clk_id: c_int, tp: *mut Timespec) -> c_int;
    fn ioctl(fd: c_int, request: c_ulong, ...) -> c_int;

    #[cfg(target_os = "macos")]
    fn sysctlbyname(
        name: *const c_char,
        oldp: *mut c_void,
        oldlenp: *mut usize,
        newp: *const c_void,
        newlen: usize,
    ) -> c_int;
}

#[cfg(target_os = "macos")]
const CLOCK_MONOTONIC: c_int = 6;
#[cfg(target_os = "linux")]
const CLOCK_MONOTONIC: c_int = 1;

#[cfg(target_os = "macos")]
const CLOCK_PROCESS_CPUTIME_ID: c_int = 12;
#[cfg(target_os = "linux")]
const CLOCK_PROCESS_CPUTIME_ID: c_int = 2;

#[cfg(target_os = "macos")]
const TIOCGWINSZ: c_ulong = 0x4008_7468;
#[cfg(target_os = "linux")]
const TIOCGWINSZ: c_ulong = 0x5413;

#[inline(always)]
fn qnil() -> VALUE {
    QNIL.load(Ordering::Relaxed)
}

#[inline(always)]
fn read_clock_ns(clk_id: c_int) -> u64 {
    let mut ts = Timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    let rc = unsafe { clock_gettime(clk_id, &mut ts) };
    if rc == 0 {
        (ts.tv_sec as u64)
            .wrapping_mul(1_000_000_000)
            .wrapping_add(ts.tv_nsec as u64)
    } else {
        0
    }
}

extern "C" fn monotonic_ns(_self: VALUE) -> VALUE {
    unsafe { rb_ull2inum(read_clock_ns(CLOCK_MONOTONIC)) }
}

extern "C" fn cputime_ns(_self: VALUE) -> VALUE {
    unsafe { rb_ull2inum(read_clock_ns(CLOCK_PROCESS_CPUTIME_ID)) }
}

extern "C" fn measure_snapshot(_self: VALUE) -> VALUE {
    let wall = read_clock_ns(CLOCK_MONOTONIC);
    let cpu = read_clock_ns(CLOCK_PROCESS_CPUTIME_ID);
    unsafe {
        let ary = rb_ary_new_capa(2);
        rb_ary_push(ary, rb_ull2inum(wall));
        rb_ary_push(ary, rb_ull2inum(cpu));
        ary
    }
}

extern "C" fn terminal_width(_self: VALUE, fd_val: VALUE) -> VALUE {
    let fd = unsafe { rb_num2int(fd_val) };
    let mut ws = Winsize {
        ws_row: 0,
        ws_col: 0,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let rc = unsafe { ioctl(fd, TIOCGWINSZ, &mut ws as *mut Winsize) };
    if rc == 0 && ws.ws_col > 0 {
        unsafe { rb_int2inum(ws.ws_col as isize) }
    } else {
        qnil()
    }
}

#[cfg(target_os = "macos")]
fn read_sysctl_i32(name: &[u8]) -> Option<i32> {
    let mut val: i32 = 0;
    let mut size: usize = std::mem::size_of::<i32>();
    let rc = unsafe {
        sysctlbyname(
            name.as_ptr() as *const c_char,
            &mut val as *mut i32 as *mut c_void,
            &mut size,
            std::ptr::null(),
            0,
        )
    };
    if rc == 0 && val > 0 {
        Some(val)
    } else {
        None
    }
}

#[cfg(target_os = "macos")]
extern "C" fn macos_core_levels(_self: VALUE) -> VALUE {
    let perf = read_sysctl_i32(b"hw.perflevel0.logicalcpu\0");
    let eff = read_sysctl_i32(b"hw.perflevel1.logicalcpu\0");
    match (perf, eff) {
        (Some(p), Some(e)) => unsafe {
            let ary = rb_ary_new_capa(2);
            rb_ary_push(ary, rb_int2inum(p as isize));
            rb_ary_push(ary, rb_int2inum(e as isize));
            ary
        },
        _ => qnil(),
    }
}

#[cfg(not(target_os = "macos"))]
extern "C" fn macos_core_levels(_self: VALUE) -> VALUE {
    qnil()
}

#[no_mangle]
pub extern "C" fn Init_quickdraw_ext() {
    unsafe {
        QNIL.store(rb_eval_string(b"nil\0".as_ptr() as *const c_char), Ordering::Relaxed);

        let m_quickdraw = rb_define_module(b"Quickdraw\0".as_ptr() as *const c_char);
        let m_native = rb_define_module_under(m_quickdraw, b"Native\0".as_ptr() as *const c_char);

        rb_define_singleton_method(
            m_native,
            b"monotonic_ns\0".as_ptr() as *const c_char,
            monotonic_ns as *const c_void,
            0,
        );
        rb_define_singleton_method(
            m_native,
            b"cputime_ns\0".as_ptr() as *const c_char,
            cputime_ns as *const c_void,
            0,
        );
        rb_define_singleton_method(
            m_native,
            b"measure_snapshot\0".as_ptr() as *const c_char,
            measure_snapshot as *const c_void,
            0,
        );
        rb_define_singleton_method(
            m_native,
            b"terminal_width\0".as_ptr() as *const c_char,
            terminal_width as *const c_void,
            1,
        );
        rb_define_singleton_method(
            m_native,
            b"macos_core_levels\0".as_ptr() as *const c_char,
            macos_core_levels as *const c_void,
            0,
        );
    }
}

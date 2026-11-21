use std::ffi::{c_char, c_int, c_long, c_ulong, c_void};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, AtomicUsize, Ordering};

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
    fn rb_ull2inum(val: u64) -> VALUE;
    fn rb_int2inum(val: isize) -> VALUE;
    fn rb_num2int(val: VALUE) -> c_int;
    fn rb_ary_new_capa(capa: isize) -> VALUE;
    fn rb_ary_push(ary: VALUE, elem: VALUE) -> VALUE;
    fn rb_ary_store(ary: VALUE, index: isize, value: VALUE);
    fn rb_ary_entry(ary: VALUE, index: isize) -> VALUE;
    fn rb_check_array_type(value: VALUE) -> VALUE;
    fn rb_ll2inum(val: i64) -> VALUE;
    fn rb_num2ull(val: VALUE) -> u64;
    fn rb_num2dbl(val: VALUE) -> f64;
    fn rb_intern(name: *const c_char) -> usize;
    fn rb_id2sym(id: usize) -> VALUE;
    fn rb_gc_stat(key: VALUE) -> usize;
    fn rb_raise(exception: VALUE, format: *const c_char, ...) -> !;
    static rb_eTypeError: VALUE;
    static rb_eArgError: VALUE;

    fn clock_gettime(clk_id: c_int, tp: *mut Timespec) -> c_int;
    fn getrusage(who: c_int, usage: *mut Rusage) -> c_int;
    fn getpid() -> c_int;
    fn poll(fds: *mut PollFd, nfds: Nfds, timeout: c_int) -> c_int;
    fn read(fd: c_int, buffer: *mut c_void, count: usize) -> isize;
    fn write(fd: c_int, buffer: *const c_void, count: usize) -> isize;
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

const RUSAGE_CHILDREN: c_int = -1;
const POLLIN: i16 = 0x1;

#[cfg(target_os = "macos")]
type Nfds = std::ffi::c_uint;
#[cfg(not(target_os = "macos"))]
type Nfds = c_ulong;

#[repr(C)]
struct Timeval {
    tv_sec: c_long,
    #[cfg(target_os = "macos")]
    tv_usec: i32,
    #[cfg(not(target_os = "macos"))]
    tv_usec: c_long,
}

#[repr(C)]
struct Rusage {
    ru_utime: Timeval,
    ru_stime: Timeval,
    rest: [c_long; 14],
}

#[repr(C)]
struct PollFd {
    fd: c_int,
    events: i16,
    revents: i16,
}

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

// Test metrics: [wall ns, CPU ns including waited-for children, GC ns,
// allocated objects], read in one call into an Array the caller owns, so
// nothing is allocated.

const METRICS: usize = 4;

static GC_TIME: AtomicUsize = AtomicUsize::new(0);
static GC_ALLOCATIONS: AtomicUsize = AtomicUsize::new(0);

fn children_cpu_ns() -> u64 {
    let mut usage: Rusage = unsafe { std::mem::zeroed() };
    if unsafe { getrusage(RUSAGE_CHILDREN, &mut usage) } != 0 {
        return 0;
    }
    let seconds = usage.ru_utime.tv_sec as i64 + usage.ru_stime.tv_sec as i64;
    let microseconds = usage.ru_utime.tv_usec as i64 + usage.ru_stime.tv_usec as i64;
    (seconds * 1_000_000_000 + microseconds * 1_000) as u64
}

fn read_metrics() -> [u64; METRICS] {
    unsafe {
        [
            read_clock_ns(CLOCK_MONOTONIC),
            read_clock_ns(CLOCK_PROCESS_CPUTIME_ID) + children_cpu_ns(),
            rb_gc_stat(GC_TIME.load(Ordering::Relaxed)) as u64 * 1_000_000,
            rb_gc_stat(GC_ALLOCATIONS.load(Ordering::Relaxed)) as u64,
        ]
    }
}

unsafe fn check_buffer(buffer: VALUE) {
    if buffer == qnil() || rb_check_array_type(buffer) != buffer {
        rb_raise(rb_eTypeError, b"expected an Array\0".as_ptr() as *const c_char);
    }
}

extern "C" fn metrics_start(_self: VALUE, buffer: VALUE) -> VALUE {
    unsafe {
        check_buffer(buffer);
        for (index, value) in read_metrics().into_iter().enumerate() {
            rb_ary_store(buffer, index as isize, rb_ull2inum(value));
        }
    }
    buffer
}

// Replaces what metrics_start read with how much each has grown since.
extern "C" fn metrics_finish(_self: VALUE, buffer: VALUE) -> VALUE {
    unsafe {
        check_buffer(buffer);
        for (index, value) in read_metrics().into_iter().enumerate() {
            let started = rb_num2ull(rb_ary_entry(buffer, index as isize));
            rb_ary_store(buffer, index as isize, rb_ll2inum(value.wrapping_sub(started) as i64));
        }
    }
    buffer
}

// Deadlines: each slot has a thread that sleeps until the slot's deadline and
// then writes a byte to `fire`. Arming and disarming are atomic stores. The
// thread is only woken (a byte to `wake`) when a deadline is armed that's
// sooner than it planned to wake, so back-to-back tests with the same timeout
// never wake it.

const SLOTS: usize = 8;
const NEVER: u64 = u64::MAX;

struct Slot {
    used: AtomicBool,
    running: AtomicBool,
    closing: AtomicBool,
    pid: AtomicI32,
    deadline: AtomicU64,
    next_wake: AtomicU64,
    fired: AtomicU64,
    opened: AtomicU64,
    wake_reader: AtomicI32,
    wake_writer: AtomicI32,
    fire: AtomicI32,
}

#[allow(clippy::declare_interior_mutable_const)]
const EMPTY_SLOT: Slot = Slot {
    used: AtomicBool::new(false),
    running: AtomicBool::new(false),
    closing: AtomicBool::new(false),
    pid: AtomicI32::new(0),
    deadline: AtomicU64::new(0),
    next_wake: AtomicU64::new(NEVER),
    fired: AtomicU64::new(0),
    opened: AtomicU64::new(0),
    wake_reader: AtomicI32::new(-1),
    wake_writer: AtomicI32::new(-1),
    fire: AtomicI32::new(-1),
};

static DEADLINES: [Slot; SLOTS] = [EMPTY_SLOT; SLOTS];

fn write_byte(fd: c_int) {
    let byte = 1u8;
    unsafe { write(fd, &byte as *const u8 as *const c_void, 1) };
}

fn watch_deadline(slot: &'static Slot) {
    let wake_reader = slot.wake_reader.load(Ordering::SeqCst);
    let fire = slot.fire.load(Ordering::SeqCst);

    while !slot.closing.load(Ordering::SeqCst) {
        // Before reading the deadline, so an arm that this read misses sees
        // NEVER and wakes the thread.
        slot.next_wake.store(NEVER, Ordering::SeqCst);
        let now = read_clock_ns(CLOCK_MONOTONIC);
        let deadline = slot.deadline.load(Ordering::SeqCst);

        let wake = if deadline == 0 {
            NEVER
        } else if deadline > now {
            deadline
        } else {
            if slot.fired.swap(deadline, Ordering::SeqCst) != deadline {
                write_byte(fire);
            }
            NEVER
        };
        slot.next_wake.store(wake, Ordering::SeqCst);

        let timeout = if wake == NEVER {
            -1
        } else {
            ((wake - now) / 1_000_000 + 1).min(c_int::MAX as u64) as c_int
        };
        let mut fd = PollFd {
            fd: wake_reader,
            events: POLLIN,
            revents: 0,
        };
        let ready = unsafe { poll(&mut fd, 1, timeout) };

        if ready < 0 {
            if std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
                break;
            }
        } else if ready > 0 {
            if fd.revents & POLLIN == 0 {
                break;
            }
            let mut buffer = [0u8; 64];
            unsafe { read(wake_reader, buffer.as_mut_ptr() as *mut c_void, buffer.len()) };
        }
    }

    slot.running.store(false, Ordering::SeqCst);
}

// A handle is the slot's index and which opening of it this is, so one kept
// past its close can't reach whoever opened the slot next.
unsafe fn deadline_slot(handle: VALUE) -> &'static Slot {
    let handle = rb_num2ull(handle);
    let slot = &DEADLINES[(handle % SLOTS as u64) as usize];
    if !slot.used.load(Ordering::SeqCst) || slot.opened.load(Ordering::SeqCst) != handle / SLOTS as u64 {
        rb_raise(rb_eArgError, b"not an open deadline\0".as_ptr() as *const c_char);
    }
    slot
}

// Returns the slot, or nil if every slot is taken or its thread can't start.
extern "C" fn deadline_open(_self: VALUE, wake_reader: VALUE, wake_writer: VALUE, fire: VALUE) -> VALUE {
    let (wake_reader, wake_writer, fire) =
        unsafe { (rb_num2int(wake_reader), rb_num2int(wake_writer), rb_num2int(fire)) };
    let pid = unsafe { getpid() };

    for (index, slot) in DEADLINES.iter().enumerate() {
        // A slot opened before a fork has no thread in the fork.
        let stale = slot.used.load(Ordering::SeqCst) && slot.pid.load(Ordering::SeqCst) != pid;
        if !stale
            && slot
                .used
                .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                .is_err()
        {
            continue;
        }

        let opened = slot.opened.fetch_add(1, Ordering::SeqCst) + 1;
        slot.pid.store(pid, Ordering::SeqCst);
        slot.deadline.store(0, Ordering::SeqCst);
        slot.next_wake.store(NEVER, Ordering::SeqCst);
        slot.fired.store(0, Ordering::SeqCst);
        slot.closing.store(false, Ordering::SeqCst);
        slot.wake_reader.store(wake_reader, Ordering::SeqCst);
        slot.wake_writer.store(wake_writer, Ordering::SeqCst);
        slot.fire.store(fire, Ordering::SeqCst);
        slot.running.store(true, Ordering::SeqCst);

        let thread = std::thread::Builder::new()
            .name("quickdraw-deadline".into())
            .stack_size(64 * 1024)
            .spawn(move || watch_deadline(slot));

        return match thread {
            Ok(_) => unsafe { rb_ull2inum(opened * SLOTS as u64 + index as u64) },
            Err(_) => {
                slot.running.store(false, Ordering::SeqCst);
                slot.used.store(false, Ordering::SeqCst);
                qnil()
            }
        };
    }

    qnil()
}

extern "C" fn deadline_arm(_self: VALUE, index: VALUE, seconds: VALUE) -> VALUE {
    let slot = unsafe { deadline_slot(index) };
    let nanoseconds = (unsafe { rb_num2dbl(seconds) } * 1e9) as i64;
    let deadline = (read_clock_ns(CLOCK_MONOTONIC) as i64)
        .saturating_add(nanoseconds)
        .max(1) as u64;

    slot.deadline.store(deadline, Ordering::SeqCst);
    if deadline < slot.next_wake.load(Ordering::SeqCst) {
        write_byte(slot.wake_writer.load(Ordering::SeqCst));
    }
    qnil()
}

fn remaining(deadline: u64) -> VALUE {
    if deadline == 0 {
        qnil()
    } else {
        unsafe { rb_ll2inum(deadline as i64 - read_clock_ns(CLOCK_MONOTONIC) as i64) }
    }
}

// Nanoseconds until the deadline (negative once it has passed), or nil if
// the slot isn't armed.
extern "C" fn deadline_remaining(_self: VALUE, index: VALUE) -> VALUE {
    remaining(unsafe { deadline_slot(index) }.deadline.load(Ordering::SeqCst))
}

extern "C" fn deadline_disarm(_self: VALUE, index: VALUE) -> VALUE {
    remaining(unsafe { deadline_slot(index) }.deadline.swap(0, Ordering::SeqCst))
}

// Stops the slot's thread, so the caller can close its pipes.
extern "C" fn deadline_close(_self: VALUE, index: VALUE) -> VALUE {
    let slot = unsafe { deadline_slot(index) };
    slot.deadline.store(0, Ordering::SeqCst);

    if slot.pid.load(Ordering::SeqCst) == unsafe { getpid() } {
        slot.closing.store(true, Ordering::SeqCst);
        write_byte(slot.wake_writer.load(Ordering::SeqCst));
        while slot.running.load(Ordering::SeqCst) {
            std::thread::sleep(std::time::Duration::from_micros(50));
        }
    }

    slot.used.store(false, Ordering::SeqCst);
    qnil()
}

fn define(module: VALUE, name: &'static [u8], function: *const c_void, arity: c_int) {
    unsafe { rb_define_singleton_method(module, name.as_ptr() as *const c_char, function, arity) };
}

#[no_mangle]
pub extern "C" fn Init_quickdraw_ext() {
    unsafe {
        // Not evaluated from a string, which coverage would report as a file.
        QNIL.store(rb_ary_entry(rb_ary_new_capa(0), 0), Ordering::Relaxed);
        GC_TIME.store(
            rb_id2sym(rb_intern(b"time\0".as_ptr() as *const c_char)),
            Ordering::Relaxed,
        );
        GC_ALLOCATIONS.store(
            rb_id2sym(rb_intern(b"total_allocated_objects\0".as_ptr() as *const c_char)),
            Ordering::Relaxed,
        );

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

        define(m_native, b"metrics_start\0", metrics_start as *const c_void, 1);
        define(m_native, b"metrics_finish\0", metrics_finish as *const c_void, 1);
        define(m_native, b"deadline_open\0", deadline_open as *const c_void, 3);
        define(m_native, b"deadline_arm\0", deadline_arm as *const c_void, 2);
        define(m_native, b"deadline_remaining\0", deadline_remaining as *const c_void, 1);
        define(m_native, b"deadline_disarm\0", deadline_disarm as *const c_void, 1);
        define(m_native, b"deadline_close\0", deadline_close as *const c_void, 1);
    }
}

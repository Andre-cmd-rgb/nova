//! libsystemd's functions, as its headers (sd-bus.h, sd-journal.h) declare them.

#![allow(non_camel_case_types)]

use std::ffi::{c_char, c_int, c_void};

#[repr(C)]
pub struct sd_bus {
    _opaque: [u8; 0],
}
#[repr(C)]
pub struct sd_bus_message {
    _opaque: [u8; 0],
}
#[repr(C)]
pub struct sd_bus_slot {
    _opaque: [u8; 0],
}
#[repr(C)]
pub struct sd_journal {
    _opaque: [u8; 0],
}

/// sd_bus_error: a D-Bus error's name and message, and whether they are the
/// struct's own to free.
#[repr(C)]
pub struct sd_bus_error {
    pub name: *const c_char,
    pub message: *const c_char,
    pub need_free: c_int,
}

impl sd_bus_error {
    pub const NULL: sd_bus_error = sd_bus_error {
        name: std::ptr::null(),
        message: std::ptr::null(),
        need_free: 0,
    };
}

pub type sd_bus_message_handler_t = unsafe extern "C" fn(
    m: *mut sd_bus_message,
    userdata: *mut c_void,
    error: *mut sd_bus_error,
) -> c_int;
pub type sd_bus_destroy_t = unsafe extern "C" fn(userdata: *mut c_void);

pub const SD_BUS_MESSAGE_METHOD_CALL: u8 = 1;
pub const SD_BUS_MESSAGE_SIGNAL: u8 = 4;

pub const SD_JOURNAL_LOCAL_ONLY: c_int = 1;

#[link(name = "systemd")]
extern "C" {
    pub fn sd_bus_open_user(ret: *mut *mut sd_bus) -> c_int;
    pub fn sd_bus_open_system(ret: *mut *mut sd_bus) -> c_int;
    pub fn sd_bus_new(ret: *mut *mut sd_bus) -> c_int;
    pub fn sd_bus_set_address(bus: *mut sd_bus, address: *const c_char) -> c_int;
    pub fn sd_bus_set_bus_client(bus: *mut sd_bus, b: c_int) -> c_int;
    pub fn sd_bus_start(bus: *mut sd_bus) -> c_int;
    pub fn sd_bus_ref(bus: *mut sd_bus) -> *mut sd_bus;
    pub fn sd_bus_unref(bus: *mut sd_bus) -> *mut sd_bus;
    pub fn sd_bus_is_open(bus: *mut sd_bus) -> c_int;
    pub fn sd_bus_get_unique_name(bus: *mut sd_bus, unique: *mut *const c_char) -> c_int;
    pub fn sd_bus_get_fd(bus: *mut sd_bus) -> c_int;
    pub fn sd_bus_get_events(bus: *mut sd_bus) -> c_int;
    pub fn sd_bus_get_timeout(bus: *mut sd_bus, timeout_usec: *mut u64) -> c_int;
    pub fn sd_bus_process(bus: *mut sd_bus, r: *mut *mut sd_bus_message) -> c_int;
    pub fn sd_bus_wait(bus: *mut sd_bus, timeout_usec: u64) -> c_int;
    pub fn sd_bus_flush(bus: *mut sd_bus) -> c_int;
    pub fn sd_bus_call(
        bus: *mut sd_bus,
        m: *mut sd_bus_message,
        usec: u64,
        ret_error: *mut sd_bus_error,
        reply: *mut *mut sd_bus_message,
    ) -> c_int;
    pub fn sd_bus_send(bus: *mut sd_bus, m: *mut sd_bus_message, cookie: *mut u64) -> c_int;
    pub fn sd_bus_add_match(
        bus: *mut sd_bus,
        slot: *mut *mut sd_bus_slot,
        match_: *const c_char,
        callback: sd_bus_message_handler_t,
        userdata: *mut c_void,
    ) -> c_int;
    pub fn sd_bus_add_object(
        bus: *mut sd_bus,
        slot: *mut *mut sd_bus_slot,
        path: *const c_char,
        callback: sd_bus_message_handler_t,
        userdata: *mut c_void,
    ) -> c_int;
    pub fn sd_bus_request_name(bus: *mut sd_bus, name: *const c_char, flags: u64) -> c_int;
    pub fn sd_bus_release_name(bus: *mut sd_bus, name: *const c_char) -> c_int;

    pub fn sd_bus_slot_unref(slot: *mut sd_bus_slot) -> *mut sd_bus_slot;
    pub fn sd_bus_slot_set_destroy_callback(
        slot: *mut sd_bus_slot,
        callback: sd_bus_destroy_t,
    ) -> c_int;

    pub fn sd_bus_message_new_method_call(
        bus: *mut sd_bus,
        m: *mut *mut sd_bus_message,
        destination: *const c_char,
        path: *const c_char,
        interface: *const c_char,
        member: *const c_char,
    ) -> c_int;
    pub fn sd_bus_message_new_signal(
        bus: *mut sd_bus,
        m: *mut *mut sd_bus_message,
        path: *const c_char,
        interface: *const c_char,
        member: *const c_char,
    ) -> c_int;
    pub fn sd_bus_message_new_method_return(
        call: *mut sd_bus_message,
        m: *mut *mut sd_bus_message,
    ) -> c_int;
    pub fn sd_bus_message_new_method_errorf(
        call: *mut sd_bus_message,
        m: *mut *mut sd_bus_message,
        name: *const c_char,
        format: *const c_char,
        ...
    ) -> c_int;
    pub fn sd_bus_message_unref(m: *mut sd_bus_message) -> *mut sd_bus_message;
    pub fn sd_bus_message_get_bus(m: *mut sd_bus_message) -> *mut sd_bus;
    pub fn sd_bus_message_get_type(m: *mut sd_bus_message, type_: *mut u8) -> c_int;
    pub fn sd_bus_message_get_expect_reply(m: *mut sd_bus_message) -> c_int;
    pub fn sd_bus_message_get_sender(m: *mut sd_bus_message) -> *const c_char;
    pub fn sd_bus_message_get_destination(m: *mut sd_bus_message) -> *const c_char;
    pub fn sd_bus_message_get_path(m: *mut sd_bus_message) -> *const c_char;
    pub fn sd_bus_message_get_interface(m: *mut sd_bus_message) -> *const c_char;
    pub fn sd_bus_message_get_member(m: *mut sd_bus_message) -> *const c_char;
    pub fn sd_bus_message_get_signature(m: *mut sd_bus_message, complete: c_int) -> *const c_char;
    pub fn sd_bus_message_set_expect_reply(m: *mut sd_bus_message, b: c_int) -> c_int;
    pub fn sd_bus_message_append_basic(
        m: *mut sd_bus_message,
        type_: c_char,
        p: *const c_void,
    ) -> c_int;
    pub fn sd_bus_message_open_container(
        m: *mut sd_bus_message,
        type_: c_char,
        contents: *const c_char,
    ) -> c_int;
    pub fn sd_bus_message_close_container(m: *mut sd_bus_message) -> c_int;
    pub fn sd_bus_message_read_basic(
        m: *mut sd_bus_message,
        type_: c_char,
        p: *mut c_void,
    ) -> c_int;
    pub fn sd_bus_message_enter_container(
        m: *mut sd_bus_message,
        type_: c_char,
        contents: *const c_char,
    ) -> c_int;
    pub fn sd_bus_message_exit_container(m: *mut sd_bus_message) -> c_int;
    pub fn sd_bus_message_peek_type(
        m: *mut sd_bus_message,
        type_: *mut c_char,
        contents: *mut *const c_char,
    ) -> c_int;
    pub fn sd_bus_message_rewind(m: *mut sd_bus_message, complete: c_int) -> c_int;

    pub fn sd_bus_error_free(e: *mut sd_bus_error);

    pub fn sd_journal_open(ret: *mut *mut sd_journal, flags: c_int) -> c_int;
    pub fn sd_journal_open_directory(
        ret: *mut *mut sd_journal,
        path: *const c_char,
        flags: c_int,
    ) -> c_int;
    pub fn sd_journal_close(j: *mut sd_journal);
    pub fn sd_journal_add_match(j: *mut sd_journal, data: *const c_void, size: usize) -> c_int;
    pub fn sd_journal_add_disjunction(j: *mut sd_journal) -> c_int;
    pub fn sd_journal_add_conjunction(j: *mut sd_journal) -> c_int;
    pub fn sd_journal_flush_matches(j: *mut sd_journal);
    pub fn sd_journal_seek_head(j: *mut sd_journal) -> c_int;
    pub fn sd_journal_seek_tail(j: *mut sd_journal) -> c_int;
    pub fn sd_journal_next(j: *mut sd_journal) -> c_int;
    pub fn sd_journal_previous(j: *mut sd_journal) -> c_int;
    pub fn sd_journal_get_data(
        j: *mut sd_journal,
        field: *const c_char,
        data: *mut *const c_void,
        length: *mut usize,
    ) -> c_int;
    pub fn sd_journal_get_realtime_usec(j: *mut sd_journal, ret: *mut u64) -> c_int;
    pub fn sd_journal_get_fd(j: *mut sd_journal) -> c_int;
    pub fn sd_journal_get_events(j: *mut sd_journal) -> c_int;
    pub fn sd_journal_get_timeout(j: *mut sd_journal, timeout_usec: *mut u64) -> c_int;
    pub fn sd_journal_process(j: *mut sd_journal) -> c_int;
    pub fn sd_journal_wait(j: *mut sd_journal, timeout_usec: u64) -> c_int;
}

// From the C library, which Rust links on this target anyway.
extern "C" {
    pub fn poll(fds: *mut crate::poll::PollFd, nfds: u64, timeout: c_int) -> c_int;
    pub fn fcntl(fd: c_int, cmd: c_int, ...) -> c_int;
    pub fn clock_gettime(clock: c_int, time: *mut Timespec) -> c_int;
}

pub const F_DUPFD_CLOEXEC: c_int = 1030;
pub const CLOCK_MONOTONIC: c_int = 1;

/// x86-64's struct timespec.
#[repr(C)]
pub struct Timespec {
    pub seconds: i64,
    pub nanoseconds: i64,
}

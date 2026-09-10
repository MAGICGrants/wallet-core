use std::cell::RefCell;
use std::ffi::{c_char, CString};

thread_local! {
    static LAST_ERROR: RefCell<Option<String>> = const { RefCell::new(None) };
}

/// Returns the most recent error message (empty string if none), as a freshly
/// allocated C string the caller must free with `openalias_string_free`.
#[no_mangle]
pub unsafe extern "C" fn openalias_last_error_message() -> *mut c_char {
    // Guarded like the other entry points, but deliberately *not* through
    // `ffi_guard`: recording an error here would mean writing to the same
    // thread-local that just panicked, and a panic inside a panic handler is an
    // abort — the exact outcome all of this exists to avoid. A null return is
    // what the Dart side already treats as "no message".
    std::panic::catch_unwind(|| {
        let msg = LAST_ERROR.with(|prev| prev.borrow_mut().take()).unwrap_or_default();
        CString::new(msg).unwrap_or_default().into_raw()
    })
    .unwrap_or(std::ptr::null_mut())
}

/// Takes the last error message, leaving none. The read half of
/// [`set_last_error`], without the C string allocation.
///
/// Exists so a test can assert on what was recorded; the FFI entry point below
/// is the only other reader.
#[cfg(test)]
pub fn take_last_error() -> String {
    LAST_ERROR.with(|prev| prev.borrow_mut().take()).unwrap_or_default()
}

pub fn set_last_error(msg: impl Into<String>) {
    let msg = msg.into();
    log::warn!("openalias error: {msg}");
    LAST_ERROR.with(|prev| *prev.borrow_mut() = Some(msg));
}

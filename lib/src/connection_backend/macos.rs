mod rfcomm;

use std::thread;

use crate::{api::connection, connection_backend::ConnectionBackends};

#[derive(Default)]
pub struct PlatformConnectionBackends;

impl ConnectionBackends for PlatformConnectionBackends {
    type Rfcomm = rfcomm::IOBluetoothRfcommBackend;

    async fn rfcomm(&self) -> connection::Result<Self::Rfcomm> {
        Ok(rfcomm::IOBluetoothRfcommBackend)
    }
}

/// IOBluetooth delivers RFCOMM events through the main thread's run loop, so applications without
/// one of their own (such as the CLI) must run their logic on another thread while the main thread
/// spins the run loop. This runs `f` on a new thread, keeps the main run loop going until `f`
/// returns, then returns `f`'s result. Must be called from the main thread.
pub fn run_with_main_run_loop<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> T {
    /// Stops the main run loop when dropped, so that a panic in `f` doesn't leave the main thread
    /// spinning forever.
    struct StopMainRunLoopOnDrop;
    impl Drop for StopMainRunLoopOnDrop {
        fn drop(&mut self) {
            unsafe { rfcomm::ffi::scq_main_run_loop_stop() };
        }
    }

    let handle = thread::spawn(move || {
        let _guard = StopMainRunLoopOnDrop;
        // The run loop must keep going until everything inside f has been dropped (closing
        // connections), which is why the guard is dropped after f returns.
        f()
    });
    unsafe { rfcomm::ffi::scq_main_run_loop_run() };
    match handle.join() {
        Ok(result) => result,
        Err(panic) => std::panic::resume_unwind(panic),
    }
}

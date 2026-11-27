//! Socket registration and readiness for a runtime that a host drives.
//!
//! See [`crate::runtime::external_io`] for an overview.

use super::ScheduledIo;
use crate::io::{Interest, Ready};
use crate::loom::sync::atomic::{AtomicBool, Ordering};
use crate::loom::sync::Arc;
use std::io;
use std::os::fd::{BorrowedFd, OwnedFd};

/// The host side of a runtime built with
/// [`Builder::build_local_with_external_io`].
///
/// Tokio calls [`register`] for every [`TcpStream`] and [`UdpSocket`] that is
/// created on the runtime, and [`wake`] when the runtime has work to do and
/// the host should call [`LocalRuntime::external_io_tick`] soon. The methods
/// of this trait and of [`ExternalRegistration`] can be called on any thread
/// that creates, converts or drops a socket of the runtime.
///
/// [`Builder::build_local_with_external_io`]: crate::runtime::Builder::build_local_with_external_io
/// [`register`]: ExternalIo::register
/// [`wake`]: ExternalIo::wake
/// [`TcpStream`]: crate::net::TcpStream
/// [`UdpSocket`]: crate::net::UdpSocket
/// [`LocalRuntime::external_io_tick`]: crate::runtime::LocalRuntime::external_io_tick
pub trait ExternalIo: Send + Sync + 'static {
    /// Starts watching a socket for readiness.
    ///
    /// Tokio asks for read and write interest. The host watches `fd` until
    /// Tokio calls [`ExternalRegistration::detach`] or
    /// [`ExternalRegistration::retire`] on the returned registration, and
    /// reports readiness through `sink`. The socket keeps ownership of `fd`
    /// until it is retired.
    ///
    /// An error is returned to the code that created the socket.
    fn register(
        &self,
        fd: BorrowedFd<'_>,
        interest: Interest,
        sink: ExternalReadiness,
    ) -> io::Result<Box<dyn ExternalRegistration>>;

    /// Asks the host to call [`LocalRuntime::external_io_tick`] soon.
    ///
    /// This can be called from any thread, also during a tick, while Tokio
    /// holds internal locks, and after the runtime has shut down. It must not
    /// call back into the runtime: it should only schedule a tick, for example
    /// by writing to an `eventfd` that the host watches.
    ///
    /// Tokio can call this many times before the next tick, for example once
    /// for each task that [`ExternalReadiness::deliver`] wakes outside a tick.
    /// To notify the host only once, coalesce the calls, for example with a
    /// flag that `wake` sets and the host clears before each tick.
    ///
    /// [`LocalRuntime::external_io_tick`]: crate::runtime::LocalRuntime::external_io_tick
    fn wake(&self);
}

/// A socket that [`ExternalIo::register`] registered with the host.
///
/// Tokio calls [`retire`] when the socket is dropped, and [`detach`] when the
/// socket is converted back into a standard library socket, for example with
/// [`TcpStream::into_std`]. If `detach` fails, the conversion fails and the
/// socket is retired when it is dropped.
///
/// [`retire`]: ExternalRegistration::retire
/// [`detach`]: ExternalRegistration::detach
/// [`TcpStream::into_std`]: crate::net::TcpStream::into_std
pub trait ExternalRegistration: Send + Sync + 'static {
    /// Stops watching the socket, which stays open and leaves Tokio.
    ///
    /// Return only once the host has removed its interest in the descriptor.
    /// On error, Tokio keeps the registration and retires it later.
    fn detach(&self) -> io::Result<()>;

    /// Stops watching the socket and takes ownership of its descriptor.
    ///
    /// The host closes `fd`, by dropping it, once it no longer uses the
    /// descriptor or this registration. This can be called on any thread,
    /// also after the runtime has shut down.
    fn retire(self: Box<Self>, fd: OwnedFd);
}

/// Reports the readiness of one registered socket to Tokio.
///
/// Cloning is cheap, and all clones refer to the same registration.
#[derive(Clone)]
pub struct ExternalReadiness {
    inner: Arc<Readiness>,
}

impl std::fmt::Debug for ExternalReadiness {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ExternalReadiness")
            .field("active", &self.inner.active.load(Ordering::Acquire))
            .finish()
    }
}

struct Readiness {
    io: Arc<ScheduledIo>,
    active: AtomicBool,
}

impl ExternalReadiness {
    pub(crate) fn new(io: Arc<ScheduledIo>) -> Self {
        Self {
            inner: Arc::new(Readiness {
                io,
                active: AtomicBool::new(true),
            }),
        }
    }

    /// Reports that the socket is ready for the operations in `ready`, and
    /// wakes the tasks that wait for them.
    ///
    /// Returns `false`, and does nothing, if `ready` is empty, the socket has
    /// been detached or retired, or the runtime has shut down.
    ///
    /// Report an error together with [`Ready::READ_CLOSED`] or
    /// [`Ready::WRITE_CLOSED`], as Mio does: [`Ready::ERROR`] alone wakes no
    /// reader or writer.
    ///
    /// Call this from the host's event dispatch, without holding a lock that
    /// [`ExternalIo::wake`] takes: waking a task can call it.
    pub fn deliver(&self, ready: Ready) -> bool {
        if ready.is_empty()
            || !self.inner.active.load(Ordering::Acquire)
            || !self.inner.io.set_external_readiness(ready)
        {
            return false;
        }
        self.inner.io.wake(ready);
        true
    }

    pub(crate) fn invalidate(&self) {
        self.inner.active.store(false, Ordering::Release);
    }
}

/// The error for an I/O resource that a runtime with external I/O does not
/// support.
pub(crate) fn unsupported() -> io::Error {
    io::Error::new(
        io::ErrorKind::Unsupported,
        "only `TcpStream` and `UdpSocket` are supported with external I/O",
    )
}

/// Fails if the current runtime uses external I/O, which cannot watch child
/// processes. `tokio::process` checks this before it starts a child process,
/// so that a failed spawn leaves no process behind.
#[cfg(feature = "process")]
pub(crate) fn check_process_support() -> io::Result<()> {
    match crate::runtime::Handle::try_current() {
        Ok(handle) if handle.inner.driver().is_external_io() => Err(unsupported()),
        _ => Ok(()),
    }
}

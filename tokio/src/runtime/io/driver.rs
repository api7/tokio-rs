// Signal handling
cfg_signal_internal_and_unix! {
    mod signal;
}
cfg_io_uring! {
    mod uring;
    use uring::UringContext;
    pub(crate) use uring::RegisterResult;
    use crate::sync::OnceCell;
}

use crate::io::interest::Interest;
use crate::io::ready::Ready;
use crate::loom::sync::Mutex;
use crate::runtime::driver;
use crate::runtime::io::registration_set;
use crate::runtime::io::{IoDriverMetrics, RegistrationSet, ScheduledIo};

use crate::loom::sync::Arc;
use mio::event::Source;
use std::fmt;
use std::io;
use std::time::Duration;

#[cfg(all(feature = "external-io-probe", target_os = "linux"))]
use crate::runtime::external_io::{ExternalIo, ExternalReadiness, ExternalRegistration};
#[cfg(all(feature = "external-io-probe", target_os = "linux"))]
use std::os::fd::BorrowedFd;

/// I/O driver, backed by Mio.
pub(crate) struct Driver {
    /// True when an event with the signal token is received
    signal_ready: bool,

    /// Reuse the `mio::Events` value across calls to poll.
    events: mio::Events,

    /// Buffer for polls that do not wait, if
    /// `Builder::max_io_events_per_busy_tick` is set.
    events_busy: Option<mio::Events>,

    /// The system event queue.
    poll: mio::Poll,
}

/// A reference to an I/O driver.
pub(crate) struct Handle {
    backend: Backend,

    /// Tracks all registrations
    registrations: RegistrationSet,

    /// State that should be synchronized
    synced: Mutex<registration_set::Synced>,

    pub(crate) metrics: IoDriverMetrics,

    #[cfg(all(
        tokio_unstable,
        feature = "io-uring",
        feature = "rt",
        feature = "fs",
        target_os = "linux",
    ))]
    pub(crate) uring_context: Mutex<UringContext>,

    #[cfg(all(
        tokio_unstable,
        feature = "io-uring",
        feature = "rt",
        feature = "fs",
        target_os = "linux",
    ))]
    pub(crate) uring_probe: OnceCell<Option<io_uring::Probe>>,
}

enum Backend {
    Mio {
        registry: mio::Registry,
        #[cfg(not(target_os = "wasi"))]
        waker: mio::Waker,
    },
    #[cfg(all(feature = "external-io-probe", target_os = "linux"))]
    External(std::sync::Arc<dyn ExternalIo>),
}

#[derive(Debug)]
pub(crate) struct ReadyEvent {
    pub(super) tick: u16,
    pub(crate) ready: Ready,
    pub(super) is_shutdown: bool,
}

cfg_net_unix!(
    impl ReadyEvent {
        pub(crate) fn with_ready(&self, ready: Ready) -> Self {
            Self {
                ready,
                tick: self.tick,
                is_shutdown: self.is_shutdown,
            }
        }
    }
);

#[derive(Debug, Eq, PartialEq, Clone, Copy)]
pub(super) enum Direction {
    Read,
    Write,
}

pub(super) enum Tick {
    Set,
    Clear(u16),
}

const TOKEN_WAKEUP: mio::Token = mio::Token(0);
const TOKEN_SIGNAL: mio::Token = mio::Token(1);

fn _assert_kinds() {
    fn _assert<T: Send + Sync>() {}

    _assert::<Handle>();
}

// ===== impl Driver =====

impl Driver {
    /// Creates a new event loop, returning any error that happened during the
    /// creation.
    pub(crate) fn new(nevents: usize, nevents_busy: Option<usize>) -> io::Result<(Driver, Handle)> {
        let poll = mio::Poll::new()?;
        #[cfg(not(target_os = "wasi"))]
        let waker = mio::Waker::new(poll.registry(), TOKEN_WAKEUP)?;
        let registry = poll.registry().try_clone()?;

        let driver = Driver {
            signal_ready: false,
            events: mio::Events::with_capacity(nevents),
            events_busy: nevents_busy.map(mio::Events::with_capacity),
            poll,
        };

        let handle = Handle::new(Backend::Mio {
            registry,
            #[cfg(not(target_os = "wasi"))]
            waker,
        });

        Ok((driver, handle))
    }
}

impl Handle {
    fn new(backend: Backend) -> Self {
        let (registrations, synced) = RegistrationSet::new();
        Self {
            backend,
            registrations,
            synced: Mutex::new(synced),
            metrics: IoDriverMetrics::default(),
            #[cfg(all(
                tokio_unstable,
                feature = "io-uring",
                feature = "rt",
                feature = "fs",
                target_os = "linux",
            ))]
            uring_context: Mutex::new(UringContext::new()),
            #[cfg(all(
                tokio_unstable,
                feature = "io-uring",
                feature = "rt",
                feature = "fs",
                target_os = "linux",
            ))]
            uring_probe: OnceCell::new(),
        }
    }

    fn mio_registry(&self) -> io::Result<&mio::Registry> {
        match &self.backend {
            Backend::Mio { registry, .. } => Ok(registry),
            #[cfg(all(feature = "external-io-probe", target_os = "linux"))]
            Backend::External(_) => Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "only `TcpStream` and `UdpSocket` are supported with external I/O",
            )),
        }
    }

    pub(crate) fn shutdown(&self) {
        let ios = self.registrations.shutdown(&mut self.synced.lock());

        // `shutdown()` must be called without holding the lock.
        for io in ios {
            io.shutdown();
        }
    }

    #[cfg(all(feature = "external-io-probe", target_os = "linux"))]
    pub(crate) fn new_external(backend: std::sync::Arc<dyn ExternalIo>) -> Self {
        Self::new(Backend::External(backend))
    }

    #[cfg(all(feature = "external-io-probe", target_os = "linux"))]
    pub(crate) fn is_external(&self) -> bool {
        matches!(self.backend, Backend::External(_))
    }

    #[cfg(all(feature = "external-io-probe", target_os = "linux"))]
    pub(super) fn add_external(
        &self,
        fd: BorrowedFd<'_>,
        interest: Interest,
    ) -> io::Result<(
        Arc<ScheduledIo>,
        ExternalReadiness,
        Box<dyn ExternalRegistration>,
    )> {
        let Backend::External(backend) = &self.backend else {
            unreachable!("external registration requires external backend");
        };
        let io = self.registrations.allocate(&mut self.synced.lock())?;
        let sink = ExternalReadiness::new(io.clone());
        let watch = match backend.register(fd, interest, sink.clone()) {
            Ok(watch) => watch,
            Err(error) => {
                sink.invalidate();
                // SAFETY: this call owns the newly allocated registration.
                unsafe {
                    self.registrations
                        .remove_external(&mut self.synced.lock(), &io)
                };
                return Err(error);
            }
        };
        self.metrics.incr_fd_count();
        Ok((io, sink, watch))
    }

    /// The caller must own `registration` and remove it only once.
    #[cfg(all(feature = "external-io-probe", target_os = "linux"))]
    pub(super) unsafe fn remove_external(&self, registration: &Arc<ScheduledIo>) {
        // SAFETY: the caller owns the one external registration being removed.
        unsafe {
            self.registrations
                .remove_external(&mut self.synced.lock(), registration);
        }
        self.metrics.dec_fd_count();
    }
}

impl Driver {
    pub(crate) fn park(&mut self, rt_handle: &driver::Handle) {
        let handle = rt_handle.io();
        self.turn(handle, None);
    }

    pub(crate) fn park_timeout(&mut self, rt_handle: &driver::Handle, duration: Duration) {
        let handle = rt_handle.io();
        self.turn(handle, Some(duration));
    }

    pub(crate) fn shutdown(&mut self, rt_handle: &driver::Handle) {
        rt_handle.io().shutdown();
    }

    fn turn(&mut self, handle: &Handle, max_wait: Option<Duration>) {
        debug_assert!(!handle.registrations.is_shutdown(&handle.synced.lock()));

        handle.release_pending_registrations();

        // A poll that does not wait takes the busy batch. Events it leaves
        // behind stay queued in the kernel, so the next poll returns them.
        let events = match (&mut self.events_busy, max_wait) {
            (Some(busy), Some(wait)) if wait.is_zero() => busy,
            _ => &mut self.events,
        };

        // Block waiting for an event to happen, peeling out how many events
        // happened.
        match self.poll.poll(events, max_wait) {
            Ok(()) => {}
            Err(ref e) if e.kind() == io::ErrorKind::Interrupted => {}
            #[cfg(target_os = "wasi")]
            Err(e) if e.kind() == io::ErrorKind::InvalidInput => {
                // In case of wasm32_wasi this error happens, when trying to poll without subscriptions
                // just return from the park, as there would be nothing, which wakes us up.
            }
            Err(e) => panic!("unexpected error when polling the I/O driver: {e:?}"),
        }

        // Process all the events that came in, dispatching appropriately
        let mut ready_count = 0;
        for event in events.iter() {
            let token = event.token();

            if token == TOKEN_WAKEUP {
                // Nothing to do, the event is used to unblock the I/O driver
            } else if token == TOKEN_SIGNAL {
                self.signal_ready = true;
            } else {
                let ready = Ready::from_mio(event);

                // Safety: we ensure that the pointers used as tokens are not freed
                // until they are both deregistered from mio **and** we know the I/O
                // driver is not concurrently polling. The I/O driver holds ownership of
                // an `Arc<ScheduledIo>` so we can safely cast this to a ref.
                unsafe { dispatch_event(token, ready) };

                ready_count += 1;
            }
        }

        #[cfg(all(
            tokio_unstable,
            feature = "io-uring",
            feature = "rt",
            feature = "fs",
            target_os = "linux",
        ))]
        {
            let mut guard = handle.get_uring().lock();
            let ctx = &mut *guard;
            ctx.dispatch_completions();

            // There might be some cases where the CQ overflows, so we need to flush
            // the remaining buffered CQEs.
            while ctx
                .uring
                .as_mut()
                .is_some_and(|uring| uring.submission().cq_overflow())
            {
                ctx.submit()
                    .expect("failed to flush io_uring completion queue overflow");
                ctx.dispatch_completions();
            }
        }

        handle.metrics.incr_ready_count_by(ready_count);
    }
}

impl fmt::Debug for Driver {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Driver")
    }
}

impl Handle {
    /// Forces a reactor blocked in a call to `turn` to wakeup, or otherwise
    /// makes the next call to `turn` return immediately.
    ///
    /// This method is intended to be used in situations where a notification
    /// needs to otherwise be sent to the main reactor. If the reactor is
    /// currently blocked inside of `turn` then it will wake up and soon return
    /// after this method has been called. If the reactor is not currently
    /// blocked in `turn`, then the next call to `turn` will not block and
    /// return immediately.
    pub(crate) fn unpark(&self) {
        match &self.backend {
            Backend::Mio {
                #[cfg(not(target_os = "wasi"))]
                waker,
                ..
            } => {
                #[cfg(not(target_os = "wasi"))]
                waker.wake().expect("failed to wake I/O driver");
            }
            #[cfg(all(feature = "external-io-probe", target_os = "linux"))]
            Backend::External(backend) => backend.wake(),
        }
    }

    /// Registers an I/O resource with the reactor for a given `mio::Ready` state.
    ///
    /// The registration token is returned.
    pub(super) fn add_source(
        &self,
        source: &mut impl mio::event::Source,
        interest: Interest,
    ) -> io::Result<Arc<ScheduledIo>> {
        let registry = self.mio_registry()?;
        let scheduled_io = self.registrations.allocate(&mut self.synced.lock())?;
        let token = scheduled_io.token();

        // we should remove the `scheduled_io` from the `registrations` set if registering
        // the `source` with the OS fails. Otherwise it will leak the `scheduled_io`.
        if let Err(e) = registry.register(source, token, interest.to_mio()) {
            // safety: `scheduled_io` is part of the `registrations` set.
            unsafe {
                self.registrations
                    .remove(&mut self.synced.lock(), &scheduled_io)
            };

            return Err(e);
        }

        // TODO: move this logic to `RegistrationSet` and use a `CountedLinkedList`
        self.metrics.incr_fd_count();

        Ok(scheduled_io)
    }

    /// Deregisters an I/O resource from the reactor.
    pub(super) fn deregister_source(
        &self,
        registration: &Arc<ScheduledIo>,
        source: &mut impl Source,
    ) -> io::Result<()> {
        // Deregister the source with the OS poller **first**.
        //
        // If `deregister` fails (for example, because the caller closed the raw
        // file descriptor before dropping `AsyncFd`), we must NOT release the
        // `ScheduledIo` registration. On Linux, if the file descriptor was
        // duplicated before the original fd number was closed, the open file
        // description remains registered in epoll with the `ScheduledIo` token
        // pointer even though `EPOLL_CTL_DEL` fails with `EBADF`.
        self.mio_registry()?.deregister(source)?;

        if self
            .registrations
            .deregister(&mut self.synced.lock(), registration)
        {
            self.unpark();
        }

        self.metrics.dec_fd_count();

        Ok(())
    }

    fn release_pending_registrations(&self) {
        if self.registrations.needs_release() {
            self.registrations.release(&mut self.synced.lock());
        }
    }
}

/// Dispatches an event received from the poller to the corresponding `ScheduledIo`.
///
/// # Safety
///
/// `token` must have been obtained from `ScheduledIo::token()`, and that
/// `ScheduledIo` must remain alive throughout this call. The I/O driver ensures
/// that pending registrations are not freed until after event dispatch completes.
pub(super) unsafe fn dispatch_event(token: mio::Token, ready: Ready) {
    let ptr = super::EXPOSE_IO.from_exposed_addr(token.0);

    // SAFETY: the caller guarantees that the token refers to a live `ScheduledIo`.
    let io: &ScheduledIo = unsafe { &*ptr };

    io.set_readiness(Tick::Set, |curr| curr | ready);
    io.wake(ready);
}

impl fmt::Debug for Handle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Handle")
    }
}

impl Direction {
    pub(super) fn mask(self) -> Ready {
        match self {
            Direction::Read => Ready::READABLE | Ready::READ_CLOSED,
            Direction::Write => Ready::WRITABLE | Ready::WRITE_CLOSED,
        }
    }
}

#[cfg(all(test, unix, feature = "net", not(loom), not(miri)))]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn busy_turn_takes_busy_batch() {
        let (mut driver, handle) = Driver::new(16, Some(2)).unwrap();
        let mut sources = Vec::new();
        for _ in 0..5 {
            let (mut rx, mut tx) = mio::net::UnixStream::pair().unwrap();
            tx.write_all(b"x").unwrap();
            let reg = handle.add_source(&mut rx, Interest::READABLE).unwrap();
            sources.push((rx, tx, reg));
        }

        // A poll that does not wait takes the busy batch.
        driver.turn(&handle, Some(Duration::ZERO));
        assert_eq!(driver.events_busy.as_ref().unwrap().iter().count(), 2);

        // The rest stays queued for the next poll, which takes the main batch.
        driver.turn(&handle, Some(Duration::from_millis(100)));
        assert_eq!(driver.events.iter().count(), 3);

        for (mut rx, _tx, reg) in sources {
            handle.deregister_source(&reg, &mut rx).unwrap();
        }
        handle.release_pending_registrations();
    }
}

#![warn(rust_2018_idioms)]
#![cfg(all(feature = "external-io-probe", target_os = "linux"))]

//! Tests for a `LocalRuntime` whose I/O and timers a host event loop drives
//! through `tokio::runtime::external_io`. The host here is a separate Mio
//! poll loop, like the event loop of a server that embeds Tokio.

use std::cell::Cell;
use std::collections::HashMap;
use std::future::Future;
use std::io::{self, Read, Write};
use std::net::{
    SocketAddr, TcpListener as StdTcpListener, TcpStream as StdTcpStream, UdpSocket as StdUdpSocket,
};
use std::os::fd::{AsRawFd, BorrowedFd, OwnedFd, RawFd};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering::SeqCst};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use mio::unix::SourceFd;
use mio::{Events, Poll, Registry, Token, Waker};
use tokio::io::{Interest, Ready};
use tokio::net::{TcpListener, TcpStream, UdpSocket};
use tokio::runtime::external_io::{ExternalIo, ExternalReadiness, ExternalRegistration};
use tokio::runtime::{Builder, LocalRuntime};

/// The token of the `Waker` that `ExternalIo::wake` uses.
const WAKE_TOKEN: Token = Token(usize::MAX);

/// A Mio poll loop that drives a runtime, as a host server would.
#[derive(Clone)]
struct Host(Arc<HostState>);

struct HostState {
    poll: Mutex<Poll>,
    registry: Registry,
    waker: Waker,
    next_token: AtomicUsize,
    sinks: Mutex<HashMap<Token, ExternalReadiness>>,
    last_sink: Mutex<Option<ExternalReadiness>>,
    fail_register: AtomicBool,
    fail_detach: AtomicBool,
    counts: Counts,
}

#[derive(Default)]
struct Counts {
    registered: AtomicUsize,
    detached: AtomicUsize,
    retired: AtomicUsize,
    wakes: AtomicUsize,
}

impl Host {
    fn new() -> Host {
        let poll = Poll::new().unwrap();
        let registry = poll.registry().try_clone().unwrap();
        let waker = Waker::new(&registry, WAKE_TOKEN).unwrap();
        Host(Arc::new(HostState {
            poll: Mutex::new(poll),
            registry,
            waker,
            next_token: AtomicUsize::new(0),
            sinks: Mutex::default(),
            last_sink: Mutex::default(),
            fail_register: AtomicBool::new(false),
            fail_detach: AtomicBool::new(false),
            counts: Counts::default(),
        }))
    }

    fn runtime(&self) -> LocalRuntime {
        Builder::new_current_thread()
            .build_local_with_external_io(Arc::new(self.clone()))
            .unwrap()
    }

    /// Runs `future` as a local task until it completes, and returns its
    /// output.
    fn run<F>(&self, rt: &mut LocalRuntime, future: F) -> F::Output
    where
        F: Future + 'static,
        F::Output: 'static,
    {
        let task = rt.spawn_local(future);
        self.run_until(rt, || task.is_finished());
        match futures::executor::block_on(task) {
            Ok(output) => output,
            Err(error) => std::panic::resume_unwind(error.into_panic()),
        }
    }

    /// Ticks `rt` and dispatches socket readiness until `done` returns `true`.
    fn run_until(&self, rt: &mut LocalRuntime, mut done: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let next = rt.external_io_tick(64);
            if done() {
                return;
            }
            assert!(Instant::now() < deadline, "the runtime made no progress");
            let limit = Duration::from_millis(100);
            self.dispatch(next.unwrap_or(limit).min(limit));
        }
    }

    /// Waits up to `timeout` for events, and delivers socket readiness to
    /// Tokio.
    fn dispatch(&self, timeout: Duration) {
        let mut events = Events::with_capacity(16);
        if let Err(error) = self.0.poll.lock().unwrap().poll(&mut events, Some(timeout)) {
            assert_eq!(error.kind(), io::ErrorKind::Interrupted, "{error}");
            return;
        }
        for event in &events {
            // Deliver outside the lock, as waking a task can call `wake`. The
            // waker's own events have no sink.
            let sink = self.0.sinks.lock().unwrap().get(&event.token()).cloned();
            if let Some(sink) = sink {
                sink.deliver(ready_of(event));
            }
        }
    }

    fn last_sink(&self) -> ExternalReadiness {
        self.0.last_sink.lock().unwrap().clone().unwrap()
    }

    /// Returns how many sockets were registered, detached and retired.
    fn counts(&self) -> (usize, usize, usize) {
        let counts = &self.0.counts;
        (
            counts.registered.load(SeqCst),
            counts.detached.load(SeqCst),
            counts.retired.load(SeqCst),
        )
    }

    fn wakes(&self) -> usize {
        self.0.counts.wakes.load(SeqCst)
    }
}

impl ExternalIo for Host {
    fn register(
        &self,
        fd: BorrowedFd<'_>,
        interest: Interest,
        sink: ExternalReadiness,
    ) -> io::Result<Box<dyn ExternalRegistration>> {
        assert!(interest.is_readable() && interest.is_writable());
        if self.0.fail_register.load(SeqCst) {
            return Err(io::Error::other("the host refused the socket"));
        }

        let token = Token(self.0.next_token.fetch_add(1, SeqCst));
        // Store the sink first, so that the first event finds it.
        self.0.sinks.lock().unwrap().insert(token, sink.clone());
        let interests = mio::Interest::READABLE | mio::Interest::WRITABLE;
        let raw_fd = fd.as_raw_fd();
        if let Err(error) = self
            .0
            .registry
            .register(&mut SourceFd(&raw_fd), token, interests)
        {
            self.0.sinks.lock().unwrap().remove(&token);
            return Err(error);
        }
        *self.0.last_sink.lock().unwrap() = Some(sink);
        self.0.counts.registered.fetch_add(1, SeqCst);

        Ok(Box::new(Registration {
            host: self.clone(),
            fd: fd.as_raw_fd(),
            token,
        }))
    }

    fn wake(&self) {
        self.0.counts.wakes.fetch_add(1, SeqCst);
        self.0.waker.wake().unwrap();
    }
}

struct Registration {
    host: Host,
    fd: RawFd,
    token: Token,
}

impl Registration {
    fn remove(&self, fd: RawFd) -> io::Result<()> {
        self.host.0.registry.deregister(&mut SourceFd(&fd))?;
        self.host.0.sinks.lock().unwrap().remove(&self.token);
        Ok(())
    }
}

impl ExternalRegistration for Registration {
    fn detach(&self) -> io::Result<()> {
        if self.host.0.fail_detach.load(SeqCst) {
            return Err(io::Error::other("the host cannot detach the socket"));
        }
        self.remove(self.fd)?;
        self.host.0.counts.detached.fetch_add(1, SeqCst);
        Ok(())
    }

    fn retire(self: Box<Self>, fd: OwnedFd) {
        assert_eq!(fd.as_raw_fd(), self.fd);
        self.remove(fd.as_raw_fd()).unwrap();
        self.host.0.counts.retired.fetch_add(1, SeqCst);
        // Dropping `fd` closes the socket.
    }
}

fn ready_of(event: &mio::event::Event) -> Ready {
    let mut ready = Ready::EMPTY;
    for (is_set, flag) in [
        (event.is_readable(), Ready::READABLE),
        (event.is_writable(), Ready::WRITABLE),
        (event.is_read_closed(), Ready::READ_CLOSED),
        (event.is_write_closed(), Ready::WRITE_CLOSED),
        (event.is_error(), Ready::ERROR),
    ] {
        if is_set {
            ready |= flag;
        }
    }
    ready
}

/// Accepts one connection and echoes `len` bytes back.
fn echo_peer(len: usize) -> (SocketAddr, thread::JoinHandle<()>) {
    let listener = StdTcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let peer = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut data = vec![0; len];
        stream.read_exact(&mut data).unwrap();
        stream.write_all(&data).unwrap();
    });
    (addr, peer)
}

async fn write_all(stream: &TcpStream, data: &[u8]) {
    let mut written = 0;
    while written < data.len() {
        stream.writable().await.unwrap();
        match stream.try_write(&data[written..]) {
            Ok(n) => written += n,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
            Err(error) => panic!("write failed: {error}"),
        }
    }
}

async fn read_exact(stream: &TcpStream, buf: &mut [u8]) {
    let mut read = 0;
    while read < buf.len() {
        stream.readable().await.unwrap();
        match stream.try_read(&mut buf[read..]) {
            Ok(0) => panic!("the peer closed the connection"),
            Ok(n) => read += n,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
            Err(error) => panic!("read failed: {error}"),
        }
    }
}

#[test]
fn tcp_stream_round_trip() {
    let host = Host::new();
    let mut rt = host.runtime();
    let (addr, peer) = echo_peer(5);

    let reply = host.run(&mut rt, async move {
        let stream = TcpStream::connect(addr).await.unwrap();
        write_all(&stream, b"hello").await;
        let mut reply = [0; 5];
        read_exact(&stream, &mut reply).await;
        reply
    });
    peer.join().unwrap();

    assert_eq!(&reply, b"hello");
    // The task dropped the stream, which retired it.
    assert_eq!(host.counts(), (1, 0, 1));
    assert!(!host.last_sink().deliver(Ready::READABLE));
}

#[test]
fn udp_socket_round_trip() {
    let host = Host::new();
    let mut rt = host.runtime();
    let peer = StdUdpSocket::bind("127.0.0.1:0").unwrap();
    peer.set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let peer_addr = peer.local_addr().unwrap();
    let peer = thread::spawn(move || {
        let mut buf = [0; 16];
        let (n, from) = peer.recv_from(&mut buf).unwrap();
        peer.send_to(&buf[..n], from).unwrap();
    });

    let reply = host.run(&mut rt, async move {
        let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        socket.send_to(b"ping", peer_addr).await.unwrap();
        let mut buf = [0; 16];
        let (n, from) = socket.recv_from(&mut buf).await.unwrap();
        assert_eq!(from, peer_addr);
        buf[..n].to_vec()
    });
    peer.join().unwrap();

    assert_eq!(reply, b"ping");
    assert_eq!(host.counts(), (1, 0, 1));
}

#[test]
fn into_std_detaches_the_socket() {
    let host = Host::new();
    let mut rt = host.runtime();
    let (addr, peer) = echo_peer(2);
    let stream = StdTcpStream::connect(addr).unwrap();
    stream.set_nonblocking(true).unwrap();

    let mut stream = host.run(&mut rt, async move {
        let stream = TcpStream::from_std(stream).unwrap();
        write_all(&stream, b"a").await;
        stream.into_std().unwrap()
    });
    assert_eq!(host.counts(), (1, 1, 0));
    assert!(!host.last_sink().deliver(Ready::READABLE));

    // The socket left Tokio, and it is still open.
    stream.set_nonblocking(false).unwrap();
    stream.write_all(b"b").unwrap();
    let mut reply = [0; 2];
    stream.read_exact(&mut reply).unwrap();
    assert_eq!(&reply, b"ab");
    peer.join().unwrap();
}

#[test]
fn a_failed_detach_retires_the_socket_on_drop() {
    let host = Host::new();
    let mut rt = host.runtime();
    // The connection waits in the backlog; nothing needs to accept it.
    let listener = StdTcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    host.0.fail_detach.store(true, SeqCst);

    let error = host.run(&mut rt, async move {
        let stream = TcpStream::connect(addr).await.unwrap();
        stream.into_std().unwrap_err()
    });

    assert_eq!(error.to_string(), "the host cannot detach the socket");
    assert_eq!(host.counts(), (1, 0, 1));
}

#[test]
fn a_failed_registration_is_returned() {
    let host = Host::new();
    let mut rt = host.runtime();
    let listener = StdTcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    host.0.fail_register.store(true, SeqCst);

    let error = host.run(&mut rt, async move {
        TcpStream::connect(addr).await.unwrap_err()
    });

    assert_eq!(error.to_string(), "the host refused the socket");
    assert_eq!(host.counts(), (0, 0, 0));
}

#[test]
fn listeners_are_not_supported() {
    let host = Host::new();
    let mut rt = host.runtime();

    let error = host.run(&mut rt, async {
        TcpListener::bind("127.0.0.1:0").await.unwrap_err()
    });

    assert_eq!(error.kind(), io::ErrorKind::Unsupported);
    assert_eq!(host.counts(), (0, 0, 0));
}

#[test]
fn ticks_report_the_next_timer() {
    let host = Host::new();
    let mut rt = host.runtime();
    let start = Instant::now();
    let task = rt.spawn_local(async { tokio::time::sleep(Duration::from_millis(50)).await });

    let delay = rt.external_io_tick(64).expect("the task set a timer");
    // Timers round their deadline up to the next millisecond.
    assert!(
        delay > Duration::ZERO && delay <= Duration::from_millis(51),
        "{delay:?}"
    );

    host.run_until(&mut rt, || task.is_finished());
    assert!(start.elapsed() >= Duration::from_millis(50));
    // No timer and no task is left.
    assert_eq!(rt.external_io_tick(64), None);
}

#[test]
fn ticks_run_at_most_max_tasks() {
    let host = Host::new();
    let mut rt = host.runtime();
    let runs = Rc::new(Cell::new(0));
    for _ in 0..3 {
        let runs = runs.clone();
        rt.spawn_local(async move { runs.set(runs.get() + 1) });
    }

    assert_eq!(rt.external_io_tick(1), Some(Duration::ZERO));
    assert_eq!(runs.get(), 1);
    assert_eq!(rt.external_io_tick(1), Some(Duration::ZERO));
    assert_eq!(runs.get(), 2);
    assert_eq!(rt.external_io_tick(1), None);
    assert_eq!(runs.get(), 3);
}

#[test]
fn spawning_from_another_thread_wakes_the_host() {
    let host = Host::new();
    let mut rt = host.runtime();
    assert_eq!(rt.external_io_tick(64), None);
    let wakes = host.wakes();

    let done = Arc::new(AtomicBool::new(false));
    let handle = rt.handle().clone();
    let flag = done.clone();
    thread::spawn(move || {
        handle.spawn(async move { flag.store(true, SeqCst) });
    })
    .join()
    .unwrap();

    assert!(host.wakes() > wakes);
    host.run_until(&mut rt, || done.load(SeqCst));
}

#[test]
fn dropping_the_runtime_retires_its_sockets() {
    let host = Host::new();
    let mut rt = host.runtime();
    let listener = StdTcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let connected = Rc::new(Cell::new(false));
    let flag = connected.clone();
    rt.spawn_local(async move {
        let _stream = TcpStream::connect(addr).await.unwrap();
        flag.set(true);
        std::future::pending::<()>().await;
    });

    host.run_until(&mut rt, || connected.get());
    assert_eq!(host.counts(), (1, 0, 0));
    drop(rt);
    assert_eq!(host.counts(), (1, 0, 1));
}

#[test]
fn readiness_is_delivered_again_after_would_block() {
    // Enough data to fill the socket buffers, so that both directions hit
    // `WouldBlock` and wait for the host to report the next edge.
    const LEN: usize = 16 << 20;
    let host = Host::new();
    let mut rt = host.runtime();
    let (addr, peer) = echo_peer(LEN);
    let data: Vec<u8> = (0..LEN).map(|i| i as u8).collect();
    let sent = data.clone();

    let reply = host.run(&mut rt, async move {
        let stream = TcpStream::connect(addr).await.unwrap();
        write_all(&stream, &sent).await;
        let mut reply = vec![0; LEN];
        read_exact(&stream, &mut reply).await;
        reply
    });
    peer.join().unwrap();

    assert!(reply == data);
}

#[test]
fn sockets_that_outlive_the_runtime_ignore_readiness() {
    let host = Host::new();
    let mut rt = host.runtime();
    let listener = StdTcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let stream = host.run(
        &mut rt,
        async move { TcpStream::connect(addr).await.unwrap() },
    );

    drop(rt);
    assert!(!host.last_sink().deliver(Ready::READABLE));
    assert_eq!(host.counts(), (1, 0, 0));
    drop(stream);
    assert_eq!(host.counts(), (1, 0, 1));
}

#[test]
#[should_panic(expected = "cannot wait by itself")]
fn block_on_panics_instead_of_waiting() {
    let host = Host::new();
    let rt = host.runtime();
    rt.block_on(async { tokio::time::sleep(Duration::from_millis(10)).await });
}

#[test]
#[should_panic(expected = "requires a runtime built with")]
fn ticking_a_native_runtime_panics() {
    let mut rt = Builder::new_current_thread()
        .build_local(Default::default())
        .unwrap();
    let _ = rt.external_io_tick(1);
}

#[test]
fn unsupported_builders_are_rejected() {
    #[cfg(feature = "rt-multi-thread")]
    {
        let error = Builder::new_multi_thread()
            .build_local_with_external_io(Arc::new(Host::new()))
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
    }
    #[cfg(feature = "test-util")]
    {
        let error = Builder::new_current_thread()
            .start_paused(true)
            .build_local_with_external_io(Arc::new(Host::new()))
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
    }
}

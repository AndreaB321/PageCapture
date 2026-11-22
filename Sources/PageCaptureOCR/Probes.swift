#if DEBUG
import Foundation

/// Test probes, debug builds only (release builds must not contain them). Each prints one line
/// on stdout and exits 0:
/// - `--probe-read <path>`: reads the file; prints `allowed` or the errno name (e.g. `EPERM`).
/// - `--probe-net <port>`: connects to 127.0.0.1:<port> over TCP; prints `allowed` or the errno name.
/// - `--probe-sleep <seconds>`: sleeps, then prints `slept`.
/// - `--probe-exec`: runs `/usr/bin/true` with `posix_spawn` and waits for it; prints `allowed` or the errno name.
/// - `--probe-fork`: forks a child that exits at once and waits for it; prints `allowed` or the errno name.
func runProbe(_ probe: String, _ arguments: [String]) -> Never {
    switch (probe, arguments.count) {
    case ("--probe-exec", 0):
        var child: pid_t = 0
        let spawned = posix_spawn(&child, "/usr/bin/true", nil, nil, [strdup("true"), nil], nil)
        guard spawned == 0 else { report(spawned) }
        var status: Int32 = 0
        waitpid(child, &status, 0)
        report(0)
    case ("--probe-fork", 0):
        // Swift marks `fork()` unavailable; the child only calls `_exit`.
        typealias Fork = @convention(c) () -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fork") else { break } // RTLD_DEFAULT
        let child = unsafeBitCast(symbol, to: Fork.self)()
        if child == 0 { _exit(0) }
        guard child > 0 else { report(errno) }
        var status: Int32 = 0
        waitpid(child, &status, 0)
        report(0)
    case ("--probe-read", 1):
        let descriptor = open(arguments[0], O_RDONLY)
        var byte: UInt8 = 0
        if descriptor < 0 || read(descriptor, &byte, 1) < 0 {
            report(errno)
        } else {
            report(0)
        }
    case ("--probe-net", 1):
        guard let port = UInt16(arguments[0]) else { break }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { report(errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        report(connected == 0 ? 0 : errno)
    case ("--probe-sleep", 1):
        guard let seconds = UInt32(arguments[0]) else { break }
        sleep(seconds)
        print("slept")
        exit(0)
    default:
        break
    }
    FileHandle.standardError.write(Data("pagecapture-ocr: bad probe\n".utf8))
    exit(2)
}

private func report(_ error: Int32) -> Never {
    let names = [EPERM: "EPERM", EACCES: "EACCES", ENOENT: "ENOENT", ECONNREFUSED: "ECONNREFUSED"]
    print(error == 0 ? "allowed" : names[error] ?? "errno \(error)")
    exit(0)
}
#endif

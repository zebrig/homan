import Darwin
import Foundation

final class ManagedASRInterprocessLockHandle: @unchecked Sendable {
    private let mutex = NSLock()
    private var fileDescriptor: Int32?

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    func unlock() {
        mutex.lock()
        guard let fileDescriptor else {
            mutex.unlock()
            return
        }
        self.fileDescriptor = nil
        mutex.unlock()
        _ = flock(fileDescriptor, LOCK_UN)
        _ = close(fileDescriptor)
    }

    deinit {
        unlock()
    }
}

enum ManagedASRInterprocessLock {
    static func acquire(
        at lockURL: URL,
        fileManager: FileManager = .default
    ) async throws -> ManagedASRInterprocessLockHandle {
        try fileManager.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError(path: lockURL.path) }

        do {
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                guard code == EWOULDBLOCK || code == EAGAIN else {
                    throw posixError(code: code, path: lockURL.path)
                }
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
            return ManagedASRInterprocessLockHandle(fileDescriptor: descriptor)
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    private static func posixError(code: Int32 = errno, path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSFilePathErrorKey: path,
                NSLocalizedDescriptionKey: String(cString: strerror(code)),
            ]
        )
    }
}
